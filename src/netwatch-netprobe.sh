#!/usr/bin/env bash
#
# netwatch-netprobe.sh - Local NIC health sampler
#
# Samples the physical NIC's link state, driver error counters, and offload
# configuration, then logs a single structured line per run. Companion to
# netwatch-agent.sh, which probes WAN reachability; this probes the local
# hardware that the WAN path depends on.
#
# Purpose: confirm the e1000e TSO/offload workaround is holding. It watches for
#   - "Detected Hardware Unit Hang" reappearing in the kernel log
#   - tx_restart_queue / tx_timeout_count climbing
#   - offloads silently re-enabling after a link-up event
#
# Designed to run from a systemd timer (Type=oneshot). Read-only: it never
# changes NIC configuration. Use scripts/netwatch-nic-remediation.sh for that.
#
# Runtime: Bash + systemd only
# License: MIT
#

set -Eeuo pipefail

# Absolute PATH for deterministic binary resolution
PATH=/usr/sbin:/usr/bin:/sbin:/bin

TAG="netwatch-netprobe"

# Volatile state (last-sample counters for delta computation)
STATE_DIR="${STATE_DIR:-/run/netwatch-netprobe}"
/bin/mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="/tmp/netwatch-netprobe-$$"
/bin/mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/last-sample.dat"

# Load configuration from systemd EnvironmentFile
[[ -r /etc/default/netwatch-netprobe ]] && . /etc/default/netwatch-netprobe

# Apply defaults
: "${NETPROBE_IFACE:=}"           # empty = auto-detect the physical uplink
: "${NETPROBE_LOG_FILE:=/var/log/netwatch/net-health.log}"
: "${NETPROBE_LOG_TO_FILE:=1}"
: "${NETPROBE_CHECK_GATEWAY:=1}"
: "${NETPROBE_GATEWAY:=}"         # empty = derive from the default route
: "${NETPROBE_PING_COUNT:=3}"     # conservative: several tries before failing
: "${NETPROBE_PING_TIMEOUT:=2}"

#
# Utility functions
#

# Log to journald at the given priority. Uses `crit` for anomalies because
# journald fsyncs immediately at crit+, so the line survives a hard power-cycle;
# routine samples stay at `info` to avoid constant disk sync.
log_pri() {
  local priority="$1"
  shift

  if [[ "${LOG_TO_STDERR:-0}" == "1" ]]; then
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] ${TAG}[${priority}]: $*" >&2
  fi

  if [[ -x /usr/bin/logger ]]; then
    /usr/bin/logger -t "$TAG" -p "daemon.$priority" -- "$*" || true
  elif [[ "${LOG_TO_STDERR:-0}" != "1" ]]; then
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] ${TAG}[${priority}]: $*" >&2
  fi
}

log_info() { log_pri "info" "$@"; }
log_crit() { log_pri "crit" "$@"; }

# Append to the plain-text log, best-effort (journal remains authoritative)
log_file() {
  [[ "$NETPROBE_LOG_TO_FILE" == "1" ]] || return 0

  local dir
  dir=$(/usr/bin/dirname "$NETPROBE_LOG_FILE")
  /bin/mkdir -p "$dir" 2>/dev/null || return 0

  echo "$(/usr/bin/date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$NETPROBE_LOG_FILE" 2>/dev/null || true
}

# Resolve ethtool across distro layouts
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
# Resolve the physical NIC behind the default route.
#
# On Proxmox the default route points at a bridge (vmbr0). Counters and offload
# state live on the enslaved physical port, and the bridge reports nominal state
# even while the underlying NIC is wedged - so always descend to the hardware.
#
detect_iface() {
  local route_dev
  route_dev=$(/sbin/ip route show default 2>/dev/null \
    | /usr/bin/awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')

  [[ -n "$route_dev" ]] || return 1

  if [[ -d "/sys/class/net/$route_dev/bridge" ]]; then
    local port name
    for port in "/sys/class/net/$route_dev/brif/"*; do
      [[ -e "$port" ]] || continue
      name=$(/usr/bin/basename "$port")
      case "$name" in
        veth*|tap*|fwln*|fwpr*|vnet*) continue ;;
      esac
      if [[ -e "/sys/class/net/$name/device" ]]; then
        echo "$name"
        return 0
      fi
    done
    return 1
  fi

  echo "$route_dev"
}

# Read a sysfs value, echoing a fallback when absent
read_sysfs() {
  local path="$1"
  local fallback="${2:-NA}"

  if [[ -r "$path" ]]; then
    /bin/cat "$path" 2>/dev/null || echo "$fallback"
  else
    echo "$fallback"
  fi
}

# Extract a named counter from `ethtool -S`
get_stat() {
  local stats="$1"
  local name="$2"
  local value

  value=$(echo "$stats" | /bin/grep -E "^[[:space:]]*${name}:" | /usr/bin/head -1 \
    | /usr/bin/awk -F: '{gsub(/[[:space:]]/, "", $2); print $2}')
  echo "${value:-0}"
}

# Conservative gateway reachability: several attempts before reporting failure,
# so a single dropped packet is not treated as an outage.
check_gateway() {
  local gw="$1"
  local ping_bin="/bin/ping"

  [[ -x "$ping_bin" ]] || ping_bin="/usr/bin/ping"
  [[ -x "$ping_bin" ]] || { echo "NA"; return 0; }

  if "$ping_bin" -n -q -c "$NETPROBE_PING_COUNT" -W "$NETPROBE_PING_TIMEOUT" "$gw" >/dev/null 2>&1; then
    echo "ok"
  else
    echo "FAIL"
  fi
}

#
# Scan the kernel log for e1000e hang signatures since the last sample.
#
# These strings are verified against the upstream driver source
# (drivers/net/ethernet/intel/e1000e/netdev.c).
#
scan_kernel_events() {
  local since="$1"
  local verdicts=""

  [[ -x /usr/bin/journalctl ]] || { echo "NA"; return 0; }

  local kmsg
  kmsg=$(/usr/bin/journalctl -k --since "$since" --no-pager 2>/dev/null || true)
  [[ -n "$kmsg" ]] || { echo "clean"; return 0; }

  local n
  n=$(echo "$kmsg" | /bin/grep -c 'Detected Hardware Unit Hang' || true)
  (( ${n:-0} > 0 )) && verdicts+="HANG_TSO:$n "

  n=$(echo "$kmsg" | /bin/grep -cE 'NETDEV WATCHDOG.*transmit queue.*timed out' || true)
  (( ${n:-0} > 0 )) && verdicts+="HANG_TXTIMEOUT:$n "

  n=$(echo "$kmsg" | /bin/grep -c 'Reset adapter unexpectedly' || true)
  (( ${n:-0} > 0 )) && verdicts+="RESET_UNEXPECTED:$n "

  n=$(echo "$kmsg" | /bin/grep -c 'ME firmware caused invalid' || true)
  (( ${n:-0} > 0 )) && verdicts+="ME_CORRUPTION:$n "

  n=$(echo "$kmsg" | /bin/grep -cE 'NIC Link is (Up|Down)' || true)
  (( ${n:-0} > 0 )) && verdicts+="LINK_CHANGE:$n "

  n=$(echo "$kmsg" | /bin/grep -cE 'PCIe Bus Error|AER: (Uncorrected|Fatal)' || true)
  (( ${n:-0} > 0 )) && verdicts+="PCIE_AER:$n "

  if [[ -z "$verdicts" ]]; then
    echo "clean"
  else
    echo "${verdicts% }"
  fi
}

#
# Main
#

ETHTOOL_BIN=""
ETHTOOL_AVAILABLE=1
if ! ETHTOOL_BIN=$(resolve_ethtool); then
  ETHTOOL_AVAILABLE=0
fi

IFACE="$NETPROBE_IFACE"
if [[ -z "$IFACE" ]]; then
  if ! IFACE=$(detect_iface); then
    log_crit "Could not resolve the physical uplink interface; set NETPROBE_IFACE"
    exit 1
  fi
fi

if [[ ! -e "/sys/class/net/$IFACE" ]]; then
  log_crit "Interface does not exist: $IFACE"
  exit 1
fi

# --- Link state (from sysfs; no privileges required) ---
OPERSTATE=$(read_sysfs "/sys/class/net/$IFACE/operstate")
CARRIER=$(read_sysfs "/sys/class/net/$IFACE/carrier")
CARRIER_UP=$(read_sysfs "/sys/class/net/$IFACE/carrier_up_count" "0")
CARRIER_DOWN=$(read_sysfs "/sys/class/net/$IFACE/carrier_down_count" "0")

# --- Driver counters ---
TX_TIMEOUT=0
TX_RESTART=0
RX_MISSED=0
RX_CRC=0
if (( ETHTOOL_AVAILABLE )); then
  STATS=$("$ETHTOOL_BIN" -S "$IFACE" 2>/dev/null || true)
  if [[ -n "$STATS" ]]; then
    TX_TIMEOUT=$(get_stat "$STATS" "tx_timeout_count")
    TX_RESTART=$(get_stat "$STATS" "tx_restart_queue")
    RX_MISSED=$(get_stat "$STATS" "rx_missed_errors")
    RX_CRC=$(get_stat "$STATS" "rx_crc_errors")
  fi
fi

# --- Offload state: the setting the workaround depends on ---
OFFLOAD_STATE="unknown"
OFFLOAD_DRIFT=0
if (( ETHTOOL_AVAILABLE )); then
  FEATURES=$("$ETHTOOL_BIN" -k "$IFACE" 2>/dev/null || true)
  if [[ -n "$FEATURES" ]]; then
    TSO=$(echo "$FEATURES" | /bin/grep -E '^tcp-segmentation-offload:' | /usr/bin/awk '{print $2}')
    GSO=$(echo "$FEATURES" | /bin/grep -E '^generic-segmentation-offload:' | /usr/bin/awk '{print $2}')
    GRO=$(echo "$FEATURES" | /bin/grep -E '^generic-receive-offload:' | /usr/bin/awk '{print $2}')
    OFFLOAD_STATE="tso=${TSO:-?},gso=${GSO:-?},gro=${GRO:-?}"

    # The driver can silently re-enable offloads on a link-up event, which
    # reinstates the hang-prone configuration. Treat that as an anomaly.
    if [[ "$TSO" == "on" ]] || [[ "$GSO" == "on" ]] || [[ "$GRO" == "on" ]]; then
      OFFLOAD_DRIFT=1
    fi
  fi
fi

# --- Gateway reachability ---
GW_STATE="skipped"
if [[ "$NETPROBE_CHECK_GATEWAY" == "1" ]]; then
  GW="$NETPROBE_GATEWAY"
  if [[ -z "$GW" ]]; then
    GW=$(/sbin/ip route show default 2>/dev/null \
      | /usr/bin/awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
  fi
  if [[ -n "$GW" ]]; then
    GW_STATE=$(check_gateway "$GW")
  else
    GW_STATE="no-route"
  fi
fi

# --- Previous sample: window for the kernel scan, and counter baselines ---
SINCE="-5min"
PREV_TX_TIMEOUT=""
PREV_TX_RESTART=""
PREV_RX_MISSED=""
PREV_RX_CRC=""

if [[ -f "$STATE_FILE" ]]; then
  PREV_TS=$(/bin/grep -E '^LAST_RUN=' "$STATE_FILE" 2>/dev/null | /usr/bin/cut -d= -f2 || true)
  if [[ -n "${PREV_TS:-}" ]]; then
    SINCE="@$PREV_TS"
  fi
  PREV_TX_TIMEOUT=$(/bin/grep -E '^TX_TIMEOUT=' "$STATE_FILE" 2>/dev/null | /usr/bin/cut -d= -f2 || true)
  PREV_TX_RESTART=$(/bin/grep -E '^TX_RESTART=' "$STATE_FILE" 2>/dev/null | /usr/bin/cut -d= -f2 || true)
  PREV_RX_MISSED=$(/bin/grep -E '^RX_MISSED=' "$STATE_FILE" 2>/dev/null | /usr/bin/cut -d= -f2 || true)
  PREV_RX_CRC=$(/bin/grep -E '^RX_CRC=' "$STATE_FILE" 2>/dev/null | /usr/bin/cut -d= -f2 || true)
fi
KERNEL_EVENTS=$(scan_kernel_events "$SINCE")

#
# Compare a counter against its previous sample.
#
# Echoes the delta when the counter increased, nothing otherwise. A decrease
# means the counters were reset (interface reload, driver reload, reboot), so
# the new value simply becomes the next baseline rather than an anomaly.
#
counter_delta() {
  local previous="$1"
  local current="$2"

  [[ -n "$previous" ]] || return 0
  [[ "$previous" =~ ^[0-9]+$ ]] || return 0
  [[ "$current" =~ ^[0-9]+$ ]] || return 0

  if (( current > previous )); then
    echo $(( current - previous ))
  fi
}

DELTA_TX_TIMEOUT=$(counter_delta "$PREV_TX_TIMEOUT" "$TX_TIMEOUT")
DELTA_TX_RESTART=$(counter_delta "$PREV_TX_RESTART" "$TX_RESTART")
DELTA_RX_MISSED=$(counter_delta "$PREV_RX_MISSED" "$RX_MISSED")
DELTA_RX_CRC=$(counter_delta "$PREV_RX_CRC" "$RX_CRC")

# --- Emit ---
SAMPLE="iface=$IFACE operstate=$OPERSTATE carrier=$CARRIER"
SAMPLE+=" carrier_up=$CARRIER_UP carrier_down=$CARRIER_DOWN"
SAMPLE+=" tx_timeout=$TX_TIMEOUT tx_restart=$TX_RESTART"
SAMPLE+=" rx_missed=$RX_MISSED rx_crc=$RX_CRC"
SAMPLE+=" offloads=$OFFLOAD_STATE gateway=$GW_STATE events=$KERNEL_EVENTS"

# Surface counter movement since the last sample; absent means unchanged
DELTAS=""
[[ -n "$DELTA_TX_TIMEOUT" ]] && DELTAS+="tx_timeout+$DELTA_TX_TIMEOUT "
[[ -n "$DELTA_TX_RESTART" ]] && DELTAS+="tx_restart+$DELTA_TX_RESTART "
[[ -n "$DELTA_RX_MISSED" ]] && DELTAS+="rx_missed+$DELTA_RX_MISSED "
[[ -n "$DELTA_RX_CRC" ]] && DELTAS+="rx_crc+$DELTA_RX_CRC "
if [[ -n "$DELTAS" ]]; then
  SAMPLE+=" deltas=${DELTAS% }"
fi

ANOMALY=0
REASONS=""

if [[ "$KERNEL_EVENTS" == *"HANG_TSO"* ]]; then
  ANOMALY=1
  REASONS+="hardware-unit-hang "
fi
if [[ "$KERNEL_EVENTS" == *"HANG_TXTIMEOUT"* ]] || [[ "$KERNEL_EVENTS" == *"RESET_UNEXPECTED"* ]]; then
  ANOMALY=1
  REASONS+="tx-timeout-or-reset "
fi
if [[ "$KERNEL_EVENTS" == *"ME_CORRUPTION"* ]]; then
  ANOMALY=1
  REASONS+="me-firmware-corruption "
fi
if (( OFFLOAD_DRIFT )); then
  ANOMALY=1
  REASONS+="offloads-re-enabled "
fi

# A rising tx_timeout_count means the NETDEV watchdog fired - the clearest
# single signal that a TX hang cycle occurred since the last sample.
if [[ -n "$DELTA_TX_TIMEOUT" ]]; then
  ANOMALY=1
  REASONS+="tx-timeout-count-rising "
fi
if [[ -n "$DELTA_RX_CRC" ]]; then
  ANOMALY=1
  REASONS+="rx-crc-errors-rising "
fi
if [[ "$GW_STATE" == "FAIL" ]]; then
  ANOMALY=1
  REASONS+="gateway-unreachable "
fi
if [[ "$OPERSTATE" != "up" ]]; then
  ANOMALY=1
  REASONS+="link-not-up "
fi

if (( ANOMALY )); then
  log_crit "ANOMALY [${REASONS% }] $SAMPLE"
else
  log_info "$SAMPLE"
fi
log_file "$SAMPLE"

# --- Persist counters for the next run's delta window ---
/bin/cat > "$STATE_FILE" <<EOF
LAST_RUN=$(/usr/bin/date +%s)
TX_TIMEOUT=$TX_TIMEOUT
TX_RESTART=$TX_RESTART
RX_MISSED=$RX_MISSED
RX_CRC=$RX_CRC
CARRIER_DOWN=$CARRIER_DOWN
EOF

exit 0
