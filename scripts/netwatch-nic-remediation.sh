#!/usr/bin/env bash
#
# netwatch-nic-remediation.sh - Intel e1000e NIC hang remediation
#
# Applies the documented workaround for the Intel I217/I218/I219 TSO/offload
# hardware erratum, which manifests as:
#
#   e1000e <pci-addr> <iface>: Detected Hardware Unit Hang:
#
# repeating every ~2 seconds until the host is rebooted. On affected silicon the
# TX descriptor ring wedges while the kernel stays alive, so the host keeps
# running but loses all network connectivity.
#
# This script changes NOTHING unless explicitly invoked with --apply-offloads.
# Run --status first to inspect the current state.
#
# Usage:
#   ./netwatch-nic-remediation.sh --status
#   ./netwatch-nic-remediation.sh --apply-offloads [--iface eno1]
#   ./netwatch-nic-remediation.sh --revert-offloads [--iface eno1]
#
# License: MIT
#

set -Eeuo pipefail

# Absolute PATH for deterministic binary resolution
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
INTERFACES_FILE="${INTERFACES_FILE:-/etc/network/interfaces}"
BACKUP_DIR="${BACKUP_DIR:-/var/lib/netwatch-agent}"

# The offload set disabled by the documented workaround. Order matters only for
# readability; ethtool applies them as a single request.
OFFLOAD_ARGS="gso off gro off tso off tx off rx off rxvlan off txvlan off sg off"

# Marker so the post-up hook can be found and removed idempotently
HOOK_MARKER="# netwatch: e1000e TSO/offload hang workaround"

#
# Utility functions
#

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Resolve ethtool, which lives in /usr/sbin on Debian but /sbin elsewhere
resolve_ethtool() {
  if [[ -x /usr/sbin/ethtool ]]; then
    echo "/usr/sbin/ethtool"
  elif [[ -x /sbin/ethtool ]]; then
    echo "/sbin/ethtool"
  elif [[ -x /usr/bin/ethtool ]]; then
    echo "/usr/bin/ethtool"
  else
    return 1
  fi
}

#
# Detect the physical NIC carrying the default route.
#
# On Proxmox the default route points at a bridge (vmbr0), but offload settings
# are a property of the physical port enslaved to it - setting them on the
# bridge has no effect on the hardware. This resolves through the bridge to the
# enslaved physical interface.
#
detect_iface() {
  local route_dev
  route_dev=$(/sbin/ip route show default 2>/dev/null \
    | /usr/bin/awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')

  if [[ -z "$route_dev" ]]; then
    return 1
  fi

  # If the default route device is a bridge, descend to its enslaved port
  if [[ -d "/sys/class/net/$route_dev/bridge" ]]; then
    local port
    for port in "/sys/class/net/$route_dev/brif/"*; do
      [[ -e "$port" ]] || continue
      local name
      name=$(/usr/bin/basename "$port")
      # Skip virtual guest interfaces; we want the physical uplink
      case "$name" in
        veth*|tap*|fwln*|fwpr*|vnet*) continue ;;
      esac
      # A physical device has a real driver symlink under /sys
      if [[ -e "/sys/class/net/$name/device" ]]; then
        echo "$name"
        return 0
      fi
    done
    return 1
  fi

  echo "$route_dev"
}

#
# Report the current offload, driver, and hang-history state.
#
show_status() {
  local iface="$1"
  local ethtool_bin="$2"

  echo
  echo "=============================================="
  echo " NIC Remediation Status"
  echo "=============================================="
  echo "Interface:  $iface"

  if [[ ! -e "/sys/class/net/$iface" ]]; then
    log_error "Interface does not exist: $iface"
    return 1
  fi

  local driver="unknown"
  if [[ -L "/sys/class/net/$iface/device/driver" ]]; then
    driver=$(/usr/bin/basename "$(/usr/bin/readlink -f "/sys/class/net/$iface/device/driver")")
  fi
  echo "Driver:     $driver"
  echo "Link state: $(/bin/cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"

  if [[ "$driver" != "e1000e" ]]; then
    log_warn "Driver is '$driver', not 'e1000e' - this workaround targets e1000e"
  fi

  echo
  echo "--- Offload state (all should be 'off' once applied) ---"
  "$ethtool_bin" -k "$iface" 2>/dev/null \
    | /bin/grep -E 'tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|scatter-gather:|rx-vlan-offload|tx-vlan-offload|tx-checksumming|rx-checksumming' \
    | /bin/sed 's/^/  /' || echo "  (unavailable)"

  echo
  echo "--- Hang-class error counters ---"
  "$ethtool_bin" -S "$iface" 2>/dev/null \
    | /bin/grep -E 'tx_timeout_count|tx_restart_queue|rx_missed_errors|rx_crc_errors|rx_long_length_errors' \
    | /bin/sed 's/^/  /' || echo "  (unavailable)"

  echo
  echo "--- Hardware Unit Hang events ---"
  local hang_current hang_all
  hang_current=$(/usr/bin/journalctl -k -b 0 --no-pager 2>/dev/null \
    | /bin/grep -c 'Detected Hardware Unit Hang' || true)
  hang_all=$(/usr/bin/journalctl -k --no-pager 2>/dev/null \
    | /bin/grep -c 'Detected Hardware Unit Hang' || true)
  echo "  current boot:    ${hang_current:-0}"
  echo "  all saved boots: ${hang_all:-0}"

  echo
  echo "--- Persistence ($INTERFACES_FILE) ---"
  if /bin/grep -qF "$HOOK_MARKER" "$INTERFACES_FILE" 2>/dev/null; then
    log_info "post-up hook is INSTALLED"
    /bin/grep -A1 -F "$HOOK_MARKER" "$INTERFACES_FILE" | /bin/sed 's/^/  /'
  else
    log_warn "post-up hook is NOT installed (settings will be lost on link-up/reboot)"
  fi
  echo
}

#
# Apply offload settings at runtime (immediate, no reboot required).
#
apply_runtime() {
  local iface="$1"
  local ethtool_bin="$2"

  # Snapshot the current state before changing anything, so --revert-offloads
  # can restore exactly what was there rather than force-enabling everything.
  # Features reported as "[fixed]" cannot be changed and are not recorded.
  /bin/mkdir -p "$BACKUP_DIR"
  local snapshot="$BACKUP_DIR/offload-state.$iface"

  if [[ ! -f "$snapshot" ]]; then
    if "$ethtool_bin" -k "$iface" 2>/dev/null \
      | /bin/grep -vF '[fixed]' \
      | /usr/bin/awk -F': *' '
          /^(tx-checksumming|rx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|rx-vlan-offload|tx-vlan-offload):/ {
            gsub(/^[ \t]+/, "", $1); print $1 "=" $2
          }' > "$snapshot"; then
      /bin/chmod 0600 "$snapshot" 2>/dev/null || true
      log_info "Saved pre-change offload state to $snapshot"
    else
      # Without a snapshot, --revert-offloads has nothing to restore from, so
      # applying now would leave a change that cannot be cleanly undone. Stop
      # rather than proceed into an unrevertable state.
      /bin/rm -f "$snapshot" 2>/dev/null || true
      log_error "Could not snapshot current offload state for $iface"
      log_error "Refusing to apply: the change would not be revertable."
      log_error "Check that '$ethtool_bin -k $iface' works and $BACKUP_DIR is writable."
      return 1
    fi
  else
    log_info "Keeping existing snapshot $snapshot (from an earlier apply)"
  fi

  log_info "Disabling offloads on $iface (runtime)"
  # shellcheck disable=SC2086
  if "$ethtool_bin" -K "$iface" $OFFLOAD_ARGS 2>&1 | /bin/sed 's/^/  /'; then
    log_info "Runtime offloads applied"
  else
    log_warn "ethtool reported an issue; some offloads may be fixed/unsupported"
  fi
}

#
# Install a post-up hook so the settings survive link-up events and reboots.
#
# The driver silently re-enables offloads on subsequent link-up events, so a
# one-time boot command is not sufficient - the hook must re-apply them every
# time the interface comes up.
#
# Placement note: on a typical Proxmox host the physical port has no `auto`
# stanza (it is brought up implicitly as a bridge port), and a post-up on a
# non-auto slave stanza is unreliable under ifupdown2. The hook is therefore
# attached to the bridge stanza that owns the port, but targets the physical
# interface by name rather than $IFACE (which would resolve to the bridge).
#
install_hook() {
  local iface="$1"
  local ethtool_bin="$2"

  if [[ ! -f "$INTERFACES_FILE" ]]; then
    log_error "Not found: $INTERFACES_FILE"
    return 1
  fi

  if /bin/grep -qF "$HOOK_MARKER" "$INTERFACES_FILE"; then
    log_info "post-up hook already present; nothing to do"
    return 0
  fi

  # Find the bridge that owns this interface. Prefer live sysfs state; fall back
  # to parsing bridge-ports out of the config, which also works when the bridge
  # is defined but not currently up.
  local owner_stanza="$iface"
  local br
  for br in /sys/class/net/*/bridge; do
    [[ -e "$br" ]] || continue
    local brname
    brname=$(/usr/bin/basename "$(/usr/bin/dirname "$br")")
    if [[ -e "/sys/class/net/$brname/brif/$iface" ]]; then
      owner_stanza="$brname"
      break
    fi
  done

  if [[ "$owner_stanza" == "$iface" ]]; then
    local cfg_bridge
    cfg_bridge=$(/usr/bin/awk -v want="$iface" '
      /^[[:space:]]*iface[[:space:]]+/ { current = $2 }
      /^[[:space:]]*bridge[-_]ports[[:space:]]/ {
        for (i = 2; i <= NF; i++) {
          if ($i == want) { print current; exit }
        }
      }
    ' "$INTERFACES_FILE")

    if [[ -n "$cfg_bridge" ]]; then
      owner_stanza="$cfg_bridge"
      log_info "Resolved bridge from $INTERFACES_FILE (interface not up in sysfs)"
    fi
  fi

  if [[ "$owner_stanza" != "$iface" ]]; then
    log_info "$iface is enslaved to $owner_stanza; attaching hook to the bridge stanza"
  else
    # A physical port with no `auto` stanza is brought up implicitly as a bridge
    # port, and post-up on such a stanza is unreliable under ifupdown2.
    if ! /bin/grep -qE "^[[:space:]]*auto[[:space:]]+${iface}[[:space:]]*$" "$INTERFACES_FILE"; then
      log_warn "No bridge owns $iface and it has no 'auto $iface' stanza."
      log_warn "post-up may not fire reliably here; verify with: ifreload -a"
    fi
  fi

  if ! /bin/grep -qE "^[[:space:]]*iface[[:space:]]+${owner_stanza}[[:space:]]" "$INTERFACES_FILE"; then
    log_error "No 'iface $owner_stanza' stanza found in $INTERFACES_FILE"
    log_error "Add this line manually to the correct stanza:"
    echo "    post-up $ethtool_bin -K $iface $OFFLOAD_ARGS"
    return 1
  fi

  /bin/mkdir -p "$BACKUP_DIR"
  local backup
  backup="$BACKUP_DIR/interfaces.$(/usr/bin/date +%Y%m%d-%H%M%S).bak"
  /bin/cp "$INTERFACES_FILE" "$backup"
  log_info "Backed up $INTERFACES_FILE -> $backup"

  # Insert the hook as the last line of the target stanza. A stanza ends at the
  # next line that begins in column 0 (or EOF).
  local tmp
  tmp=$(/bin/mktemp)
  # shellcheck disable=SC1087  # awk array syntax, not shell expansion
  /usr/bin/awk -v stanza="$owner_stanza" \
               -v marker="$HOOK_MARKER" \
               -v hook="    post-up $ethtool_bin -K $iface $OFFLOAD_ARGS" '
    BEGIN { in_stanza = 0; pending = 0 }
    {
      # Buffer blank lines so the hook is appended to the last populated line
      # of the stanza rather than after the trailing blank separator.
      if (in_stanza && $0 ~ /^[[:space:]]*$/) {
        blanks[pending++] = $0
        next
      }

      # Leaving the target stanza: emit the hook, then any buffered blanks
      if (in_stanza && $0 ~ /^[^[:space:]#]/) {
        print "    " marker
        print hook
        for (i = 0; i < pending; i++) print blanks[i]
        pending = 0
        in_stanza = 0
      } else if (pending > 0) {
        for (i = 0; i < pending; i++) print blanks[i]
        pending = 0
      }

      print
      if ($0 ~ "^[[:space:]]*iface[[:space:]]+" stanza "[[:space:]]") {
        in_stanza = 1
      }
    }
    END {
      if (in_stanza) {
        print "    " marker
        print hook
      }
      for (i = 0; i < pending; i++) print blanks[i]
    }
  ' "$INTERFACES_FILE" > "$tmp"

  if ! /bin/grep -qF "$HOOK_MARKER" "$tmp"; then
    /bin/rm -f "$tmp"
    log_error "Failed to insert hook; $INTERFACES_FILE left unchanged"
    return 1
  fi

  /bin/cat "$tmp" > "$INTERFACES_FILE"
  /bin/rm -f "$tmp"
  log_info "post-up hook installed in the '$owner_stanza' stanza"
}

#
# Remove the post-up hook and re-enable offloads at runtime.
#
revert_offloads() {
  local iface="$1"
  local ethtool_bin="$2"

  if /bin/grep -qF "$HOOK_MARKER" "$INTERFACES_FILE" 2>/dev/null; then
    /bin/mkdir -p "$BACKUP_DIR"
    local backup
    backup="$BACKUP_DIR/interfaces.$(/usr/bin/date +%Y%m%d-%H%M%S).bak"
    /bin/cp "$INTERFACES_FILE" "$backup"
    log_info "Backed up $INTERFACES_FILE -> $backup"

    local tmp
    tmp=$(/bin/mktemp)
    # Remove ONLY our marker and the single line immediately after it. A blanket
    # filter on "post-up ... ethtool -K <iface>" would also delete hooks the
    # operator added by hand.
    /usr/bin/awk -v marker="$HOOK_MARKER" '
      skip_next { skip_next = 0; next }
      index($0, marker) { skip_next = 1; next }
      { print }
    ' "$INTERFACES_FILE" > "$tmp"
    /bin/cat "$tmp" > "$INTERFACES_FILE"
    /bin/rm -f "$tmp"
    log_info "post-up hook removed"
  else
    log_info "No post-up hook present"
  fi

  # Restore the snapshot taken at apply time rather than force-enabling every
  # feature, which would turn on offloads that were already off beforehand.
  local snapshot="$BACKUP_DIR/offload-state.$iface"

  if [[ ! -f "$snapshot" ]]; then
    log_warn "No saved offload state at $snapshot"
    log_warn "Runtime offloads left unchanged - this script will not guess a prior state."
    log_info "To re-enable manually: $ethtool_bin -K $iface tso on gso on gro on sg on"
    return 0
  fi

  # Map ethtool's -k report names onto the short keys that -K accepts
  local -a restore_args=()
  local feature value flag
  while IFS='=' read -r feature value; do
    [[ -n "$feature" ]] || continue
    case "$feature" in
      tx-checksumming)               flag="tx" ;;
      rx-checksumming)               flag="rx" ;;
      scatter-gather)                flag="sg" ;;
      tcp-segmentation-offload)      flag="tso" ;;
      generic-segmentation-offload)  flag="gso" ;;
      generic-receive-offload)       flag="gro" ;;
      rx-vlan-offload)               flag="rxvlan" ;;
      tx-vlan-offload)               flag="txvlan" ;;
      *)                             continue ;;
    esac
    case "$value" in
      on|off) restore_args+=("$flag" "$value") ;;
      *)      continue ;;
    esac
  done < "$snapshot"

  if (( ${#restore_args[@]} == 0 )); then
    log_warn "Snapshot $snapshot contained no restorable settings"
    return 0
  fi

  log_warn "Restoring pre-change offload state (may reinstate the hang-prone configuration)"
  if "$ethtool_bin" -K "$iface" "${restore_args[@]}" 2>&1 | /bin/sed 's/^/  /'; then
    log_info "Restored: ${restore_args[*]}"
    /bin/rm -f "$snapshot"
  else
    log_warn "ethtool reported an issue restoring offload state"
  fi
}

#
# Main
#

ACTION=""
IFACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)          ACTION="status"; shift ;;
    --apply-offloads)  ACTION="apply";  shift ;;
    --revert-offloads) ACTION="revert"; shift ;;
    --iface)           IFACE="${2:-}";  shift 2 ;;
    -h|--help)
      /bin/sed -n '2,25p' "$0" | /bin/sed 's/^# \?//'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Usage: $0 --status | --apply-offloads | --revert-offloads [--iface NAME]"
      exit 1
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "Usage: $0 --status | --apply-offloads | --revert-offloads [--iface NAME]"
  echo
  echo "Run --status first to inspect the current state. Nothing is changed"
  echo "unless --apply-offloads or --revert-offloads is given."
  exit 1
fi

ETHTOOL_BIN=""
if ! ETHTOOL_BIN=$(resolve_ethtool); then
  log_error "ethtool not found - install it with: apt-get install ethtool"
  exit 1
fi

if [[ -z "$IFACE" ]]; then
  if ! IFACE=$(detect_iface); then
    log_error "Could not auto-detect the physical interface; pass --iface NAME"
    exit 1
  fi
  log_info "Auto-detected physical interface: $IFACE"
fi

if [[ ! -e "/sys/class/net/$IFACE" ]]; then
  log_error "Interface does not exist: $IFACE"
  exit 1
fi

# Mutating actions need root
if [[ "$ACTION" != "status" ]] && [[ $EUID -ne 0 ]]; then
  log_error "This action must be run as root"
  exit 1
fi

case "$ACTION" in
  status)
    show_status "$IFACE" "$ETHTOOL_BIN"
    ;;
  apply)
    # Stop before install_hook if the runtime change did not happen - a
    # persistent hook for a change we could not apply or revert is worse than
    # no change at all.
    if ! apply_runtime "$IFACE" "$ETHTOOL_BIN"; then
      log_error "Aborting: nothing was changed."
      exit 1
    fi
    install_hook "$IFACE" "$ETHTOOL_BIN"
    echo
    log_info "Applied. Verify with:"
    echo "    $ETHTOOL_BIN -k $IFACE | grep -E 'tcp-segmentation|generic-segmentation|generic-receive'"
    echo
    log_info "Confirm the hook survives an interface bounce with: ifreload -a"
    ;;
  revert)
    revert_offloads "$IFACE" "$ETHTOOL_BIN"
    ;;
esac
