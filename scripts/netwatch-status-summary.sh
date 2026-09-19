#!/usr/bin/env bash
#
# netwatch-status-summary.sh - Report the resulting operational state
#
# Printed after an install or upgrade, by both install.sh and the .deb
# postinst, so the two paths report identically.
#
# This answers the question that matters after an install: is the watchdog
# armed, and what will it do? File-copy logging cannot answer that - a package
# upgrade that silently reset DRY_RUN would still look like a clean install.
#
# Safe to run any time:
#
#   netwatch-status-summary.sh
#
# License: MIT
#

set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="${CONFIG_FILE:-/etc/default/netwatch-agent}"
NETPROBE_CONFIG="${NETPROBE_CONFIG:-/etc/default/netwatch-netprobe}"

# Read a KEY=VALUE from a config file without sourcing it, so a malformed file
# cannot execute anything or abort this script.
cfg() {
  local file="$1" key="$2" fallback="${3:-}" value

  [[ -r "$file" ]] || { printf '%s' "$fallback"; return 0; }

  value=$(/bin/grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null \
    | /usr/bin/tail -1 \
    | /usr/bin/cut -d= -f2- \
    | /bin/sed 's/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//')

  printf '%s' "${value:-$fallback}"
}

unit_state() {
  local unit="$1"

  if ! [[ -x /usr/bin/systemctl ]]; then
    echo "unknown"
    return 0
  fi

  local enabled="disabled" active="inactive"
  /usr/bin/systemctl is-enabled --quiet "$unit" 2>/dev/null && enabled="enabled"
  /usr/bin/systemctl is-active --quiet "$unit" 2>/dev/null && active="active"
  echo "$enabled, $active"
}

# Resolve the physical NIC behind the default route, descending through a
# bridge if present.
detect_iface() {
  local route_dev
  route_dev=$(/sbin/ip route show default 2>/dev/null \
    | /usr/bin/awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true

  [[ -n "${route_dev:-}" ]] || { echo ""; return 0; }

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

    # The route device is a bridge but no physical port was found. Reporting
    # the bridge here would defeat the purpose: its offload state and counters
    # say nothing about the hardware the WAN path actually depends on.
    echo ""
    return 0
  fi

  # Not a bridge - the route device is the physical interface.
  echo "$route_dev"
}

echo
echo -e "${BOLD}=========================================${NC}"
echo -e "${BOLD} Netwatch status${NC}"
echo -e "${BOLD}=========================================${NC}"

# --- WAN watchdog ---
DRY_RUN=$(cfg "$CONFIG_FILE" DRY_RUN "1")
DOWN_WINDOW=$(cfg "$CONFIG_FILE" DOWN_WINDOW_SECONDS "600")
MODE=$(cfg "$CONFIG_FILE" HEALTH_CHECK_MODE "icmp")
MIN_OK=$(cfg "$CONFIG_FILE" MIN_OK "1")
TARGETS=$(cfg "$CONFIG_FILE" TARGETS "")
WEBHOOK=$(cfg "$CONFIG_FILE" WEBHOOK_ENABLED "0")

echo
echo "WAN watchdog"
echo "  service:     $(unit_state netwatch-agent.service)"
echo "  mode:        $MODE (need ${MIN_OK} of: ${TARGETS:-unset})"

# The single most important line: will this reboot the host?
if [[ "$DRY_RUN" == "0" ]]; then
  echo -e "  reboot:      ${RED}${BOLD}ARMED${NC} - will reboot after ${DOWN_WINDOW}s of continuous loss"
else
  echo -e "  reboot:      ${GREEN}dry-run${NC} - logs only, will not reboot (DRY_RUN=1)"
fi

if [[ "$WEBHOOK" == "1" ]]; then
  echo -e "  webhook:     ${GREEN}enabled${NC}"
else
  echo -e "  webhook:     ${YELLOW}disabled${NC} (set WEBHOOK_ENABLED=1 to get alerts)"
fi

# --- NIC tooling ---
if [[ -f /usr/local/sbin/netwatch-netprobe.sh ]]; then
  IFACE=$(detect_iface)
  echo
  echo "NIC monitoring"
  echo "  sampler:     $(unit_state netwatch-netprobe.timer)"
  echo "  digest:      $(unit_state netwatch-digest.timer)"
  echo "  interface:   ${IFACE:-not detected}"

  if [[ -n "$IFACE" ]] && [[ -x /usr/sbin/ethtool ]]; then
    OFFLOADS=$(/usr/sbin/ethtool -k "$IFACE" 2>/dev/null \
      | /bin/grep -E '^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' \
      | /usr/bin/awk '{printf "%s=%s ", substr($1,1,3), $2}') || true

    if [[ -n "${OFFLOADS:-}" ]]; then
      if echo "$OFFLOADS" | /bin/grep -q '=on'; then
        echo -e "  offloads:    ${YELLOW}${OFFLOADS}${NC}"
        echo "               (on = exposed to the e1000e hang if this is an Intel I217/I218/I219)"
      else
        echo -e "  offloads:    ${GREEN}${OFFLOADS}${NC}"
      fi
    fi
  fi

  DIGEST_TIME=""
  if [[ -x /usr/bin/systemctl ]]; then
    DIGEST_TIME=$(/usr/bin/systemctl show netwatch-digest.timer -p TimersCalendar --value 2>/dev/null \
      | /bin/grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | /usr/bin/head -1) || true
  fi
  [[ -n "${DIGEST_TIME:-}" ]] && echo "  digest at:   $DIGEST_TIME daily"
fi

# --- Journal persistence, required for post-mortem work ---
echo
if [[ -d /var/log/journal ]]; then
  echo -e "  journal:     ${GREEN}persistent${NC} (previous boots readable)"
else
  echo -e "  journal:     ${YELLOW}volatile${NC} - 'journalctl -b -1' will be empty"
  echo "               fix: netwatch-setup-journald.sh --apply"
fi

echo
echo "Config: $CONFIG_FILE"
[[ -f "$NETPROBE_CONFIG" ]] && echo "        $NETPROBE_CONFIG"
echo "Logs:   journalctl -u netwatch-agent -f"
echo "        journalctl -t netwatch-netprobe -p crit --no-pager"
echo
