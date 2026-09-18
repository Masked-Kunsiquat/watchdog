#!/usr/bin/env bash
#
# netwatch-postmortem.sh - Post-outage forensics collector
#
# Run this after recovering from a network outage. It reconstructs what the
# host was doing in its final moments before the previous boot ended, and
# reports the current NIC configuration for comparison.
#
# Requires persistent journald (Storage=persistent). Without it, `journalctl
# -b -1` returns nothing and there is no previous-boot evidence to read - the
# script reports this explicitly rather than silently returning empty results.
#
# Usage:
#   ./netwatch-postmortem.sh                 # previous boot (-1)
#   ./netwatch-postmortem.sh --boot -3       # a specific earlier boot
#   ./netwatch-postmortem.sh --all-boots     # hang-event summary across all boots
#   ./netwatch-postmortem.sh --output FILE   # also write to FILE
#
# License: MIT
#

set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BOOT="-1"
OUTPUT=""
ALL_BOOTS=0

# Kernel log signatures for e1000e hang classes, verified against the upstream
# driver source (drivers/net/ethernet/intel/e1000e/netdev.c).
NIC_PATTERN='Detected Hardware Unit Hang|NETDEV WATCHDOG|Reset adapter unexpectedly|ME firmware caused invalid|NIC Link is|PCIe Bus Error|AER:|e1000e'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot)       BOOT="${2:-}"; shift 2 ;;
    --output)     OUTPUT="${2:-}"; shift 2 ;;
    --all-boots)  ALL_BOOTS=1; shift ;;
    -h|--help)
      /bin/sed -n '2,20p' "$0" | /bin/sed 's/^# \?//'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ ! -x /usr/bin/journalctl ]]; then
  log_error "journalctl not found - this tool requires systemd"
  exit 1
fi

#
# Emit the full report on stdout; the caller may tee it to a file.
#
generate_report() {
  echo "################ NETWATCH POST-MORTEM ################"
  echo "## generated: $(/usr/bin/date -Is)"
  echo "## host:      $(/usr/bin/hostname 2>/dev/null || echo unknown)"
  echo "## kernel:    $(/usr/bin/uname -r)"
  echo

  echo "=== [0] JOURNAL PERSISTENCE ==="
  local storage
  storage=$(/usr/bin/journalctl --header 2>/dev/null | /bin/grep -iE '^Storage:' | /usr/bin/head -1 || true)
  if [[ -d /var/log/journal ]]; then
    echo "  /var/log/journal exists - persistent logging available"
  else
    echo "  /var/log/journal MISSING - journal is volatile"
    echo "  Previous-boot evidence is NOT being retained."
    echo "  Fix with: scripts/netwatch-setup-journald.sh"
  fi
  [[ -n "$storage" ]] && echo "  $storage"
  echo "  disk usage: $(/usr/bin/journalctl --disk-usage 2>&1 | /usr/bin/tail -1)"
  echo
  echo "--- boots recorded ---"
  /usr/bin/journalctl --list-boots --no-pager 2>&1 | /usr/bin/tail -10 | /bin/sed 's/^/  /'
  echo

  if (( ALL_BOOTS )); then
    echo "=== [1] HANG-EVENT SUMMARY (ALL RETAINED BOOTS) ==="
    local b
    for b in 0 -1 -2 -3 -4 -5 -6 -7; do
      local kmsg hang txto reset me link
      kmsg=$(/usr/bin/journalctl -k -b "$b" --no-pager 2>/dev/null || true)
      [[ -z "$kmsg" ]] && continue
      hang=$(echo "$kmsg" | /bin/grep -c 'Detected Hardware Unit Hang' || true)
      txto=$(echo "$kmsg" | /bin/grep -c 'NETDEV WATCHDOG' || true)
      reset=$(echo "$kmsg" | /bin/grep -c 'Reset adapter unexpectedly' || true)
      me=$(echo "$kmsg" | /bin/grep -c 'ME firmware caused invalid' || true)
      link=$(echo "$kmsg" | /bin/grep -cE 'NIC Link is' || true)
      printf "  boot %-3s hang=%-7s txtimeout=%-4s reset=%-4s me=%-4s link=%s\n" \
        "$b" "${hang:-0}" "${txto:-0}" "${reset:-0}" "${me:-0}" "${link:-0}"
    done
    echo
    echo "  Interpretation:"
    echo "    hang>0                  -> TSO/offload erratum (apply the offload workaround)"
    echo "    link>2 with hang=0      -> link flapping (investigate EEE, cabling, switch)"
    echo "    me>0                    -> ME/CSME firmware corrupting the descriptor ring"
    echo "    txtimeout>0 / reset>0   -> driver attempted its own recovery"
    echo
  fi

  echo "=== [2] NIC EVENTS, BOOT $BOOT ==="
  local nic_events
  nic_events=$(/usr/bin/journalctl -k -b "$BOOT" --no-pager -o short-precise 2>/dev/null \
    | /bin/grep -iE "$NIC_PATTERN" || true)

  if [[ -z "$nic_events" ]]; then
    echo "  (no NIC events found for boot $BOOT)"
    if ! /usr/bin/journalctl -b "$BOOT" --no-pager -n1 >/dev/null 2>&1; then
      echo "  NOTE: boot $BOOT has no journal data at all."
      echo "        Either it predates retention, or persistence was off then."
    fi
  else
    echo "$nic_events" | /usr/bin/head -60 | /bin/sed 's/^/  /'
    local total
    total=$(echo "$nic_events" | /usr/bin/wc -l)
    echo "  ... ($total matching lines total)"
  fi
  echo

  echo "=== [3] HANG COUNTS, BOOT $BOOT ==="
  local kmsg
  kmsg=$(/usr/bin/journalctl -k -b "$BOOT" --no-pager 2>/dev/null || true)
  echo "  Detected Hardware Unit Hang: $(echo "$kmsg" | /bin/grep -c 'Detected Hardware Unit Hang' || true)"
  echo "  NETDEV WATCHDOG:             $(echo "$kmsg" | /bin/grep -c 'NETDEV WATCHDOG' || true)"
  echo "  Reset adapter unexpectedly:  $(echo "$kmsg" | /bin/grep -c 'Reset adapter unexpectedly' || true)"
  echo "  ME firmware caused invalid:  $(echo "$kmsg" | /bin/grep -c 'ME firmware caused invalid' || true)"
  echo "  NIC Link is Up/Down:         $(echo "$kmsg" | /bin/grep -cE 'NIC Link is' || true)"
  echo

  echo "=== [4] ERRORS, BOOT $BOOT ==="
  /usr/bin/journalctl -b "$BOOT" -p err --no-pager -o short-precise 2>/dev/null \
    | /usr/bin/tail -40 | /bin/sed 's/^/  /' || echo "  (none)"
  echo

  echo "=== [5] NETWATCH UNITS, BOOT $BOOT ==="
  echo "--- netwatch-agent ---"
  /usr/bin/journalctl -b "$BOOT" -t netwatch-agent --no-pager -o short-precise 2>/dev/null \
    | /usr/bin/tail -25 | /bin/sed 's/^/  /' || echo "  (none)"
  echo "--- netwatch-netprobe ---"
  /usr/bin/journalctl -b "$BOOT" -t netwatch-netprobe --no-pager -o short-precise 2>/dev/null \
    | /usr/bin/tail -25 | /bin/sed 's/^/  /' || echo "  (none)"
  echo

  echo "=== [6] FINAL LINES BEFORE BOOT $BOOT ENDED ==="
  echo "  (a clean systemd shutdown sequence here means a graceful reboot;"
  echo "   an abrupt cut means power loss or a hard reset)"
  /usr/bin/journalctl -b "$BOOT" --no-pager -o short-precise 2>/dev/null \
    | /usr/bin/tail -25 | /bin/sed 's/^/  /' || echo "  (none)"
  echo

  echo "=== [7] CURRENT NIC STATE ==="
  local ethtool_bin=""
  if [[ -x /usr/sbin/ethtool ]]; then
    ethtool_bin=/usr/sbin/ethtool
  elif [[ -x /sbin/ethtool ]]; then
    ethtool_bin=/sbin/ethtool
  fi

  local iface
  iface=$(/sbin/ip route show default 2>/dev/null \
    | /usr/bin/awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')

  if [[ -n "$iface" ]] && [[ -d "/sys/class/net/$iface/bridge" ]]; then
    local port name
    for port in "/sys/class/net/$iface/brif/"*; do
      [[ -e "$port" ]] || continue
      name=$(/usr/bin/basename "$port")
      case "$name" in veth*|tap*|fwln*|fwpr*|vnet*) continue ;; esac
      if [[ -e "/sys/class/net/$name/device" ]]; then
        echo "  (resolved $iface bridge -> physical port $name)"
        iface="$name"
        break
      fi
    done
  fi

  if [[ -n "$iface" ]]; then
    echo "  interface: $iface"
    echo "  operstate: $(/bin/cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo NA)"
    if [[ -n "$ethtool_bin" ]]; then
      echo "--- offloads ---"
      "$ethtool_bin" -k "$iface" 2>/dev/null \
        | /bin/grep -E 'tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|scatter-gather:' \
        | /bin/sed 's/^/    /' || true
      echo "--- error counters ---"
      "$ethtool_bin" -S "$iface" 2>/dev/null \
        | /bin/grep -E 'tx_timeout_count|tx_restart_queue|rx_missed_errors|rx_crc_errors' \
        | /bin/sed 's/^/    /' || true
      echo "--- driver ---"
      "$ethtool_bin" -i "$iface" 2>/dev/null \
        | /bin/grep -E 'driver|version|firmware' | /bin/sed 's/^/    /' || true
    else
      echo "  (ethtool not installed - install with: apt-get install ethtool)"
    fi
  else
    echo "  (could not determine the default-route interface)"
  fi
  echo

  echo "################ END POST-MORTEM ################"
}

if [[ -n "$OUTPUT" ]]; then
  generate_report | /usr/bin/tee "$OUTPUT"
  echo
  log_info "Report written to $OUTPUT"
else
  generate_report
fi
