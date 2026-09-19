#!/usr/bin/env bash
#
# netwatch-digest.sh - Daily diagnostic digest
#
# Collects NIC health, offload state, and WAN outage metrics for the last 24
# hours and sends a single summary (webhook and/or journal). Intended to run
# once a day from a systemd timer so a fix can be confirmed as holding without
# remembering ad-hoc commands.
#
# Host identifiers (IP, MAC, hostname) are REDACTED by default: the digest
# typically goes to a third-party service such as Discord. Set
# DIGEST_INCLUDE_HOSTNAME=1 to include the hostname.
#
# Output is templated the same way netwatch-agent's webhooks are - see
# DIGEST_BODY_TEMPLATE in the config to trim verbosity by choosing which
# {PLACEHOLDERS} appear.
#
# Runtime: Bash + systemd only
# License: MIT
#

set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

TAG="netwatch-digest"

# Load configuration. The digest reuses the sampler's interface selection and
# the agent's webhook credentials, so both files are sourced.
[[ -r /etc/default/netwatch-netprobe ]] && . /etc/default/netwatch-netprobe
[[ -r /etc/default/netwatch-agent ]] && . /etc/default/netwatch-agent

# Digest-specific defaults
: "${DIGEST_ENABLED:=1}"
: "${DIGEST_INCLUDE_HOSTNAME:=0}"
: "${DIGEST_WINDOW_HOURS:=24}"
: "${DIGEST_BODY_TEMPLATE:=}"
: "${DIGEST_WEBHOOK_URL:=}"

# Payload shape: "text" (a content string, works with any webhook service) or
# "embed" (a Discord embed with a verdict-coloured border and a field grid).
# Only Discord understands the embeds array, so text remains the default.
: "${DIGEST_FORMAT:=text}"

# Inherited from the agent config (webhook delivery)
: "${WEBHOOK_ENABLED:=0}"
: "${WEBHOOK_URL:=}"
: "${WEBHOOK_METHOD:=POST}"
: "${WEBHOOK_HEADERS:=}"
: "${WEBHOOK_TIMEOUT:=10}"

# Inherited from the sampler config (interface selection)
: "${NETPROBE_IFACE:=}"

# Persistent state
: "${PERSIST_DIR:=/var/lib/netwatch-agent}"
METRICS_FILE="$PERSIST_DIR/metrics.dat"
DIGEST_STATE="$PERSIST_DIR/digest-state.dat"

#
# Utility functions
#

log() {
  if [[ "${LOG_TO_STDERR:-0}" == "1" ]]; then
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] $TAG: $*" >&2
  fi
  if [[ -x /usr/bin/logger ]]; then
    /usr/bin/logger -t "$TAG" -- "$*" || true
  elif [[ "${LOG_TO_STDERR:-0}" != "1" ]]; then
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] $TAG: $*" >&2
  fi
}

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

# Resolve the physical NIC behind the default route, descending through a
# bridge if present (counters live on the hardware, not on vmbr0).
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

get_stat() {
  local stats="$1" name="$2" value
  value=$(echo "$stats" | /bin/grep -E "^[[:space:]]*${name}:" | /usr/bin/head -1 \
    | /usr/bin/awk -F: '{gsub(/[[:space:]]/, "", $2); print $2}')
  echo "${value:-0}"
}

# Read a numeric field from a KEY=VALUE state file, with a fallback.
#
# The fallback uses ${3-0} (unset-only), not ${3:-0}: callers pass an explicit
# empty string to mean "no baseline recorded yet", and ${3:-0} would turn that
# into 0 - making the first-ever digest report the full counter value as an
# overnight delta.
read_field() {
  local file="$1" key="$2" fallback="${3-0}" value

  [[ -r "$file" ]] || { echo "$fallback"; return 0; }
  value=$(/bin/grep -E "^${key}=" "$file" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d= -f2)
  [[ "$value" =~ ^[0-9]{1,15}$ ]] || { echo "$fallback"; return 0; }
  echo "$value"
}

# Escape a string for inclusion in a JSON string literal.
#
# Backslashes MUST be handled first, or the escapes added afterwards would
# themselves be escaped again. RFC 8259 also forbids raw U+0000-U+001F inside a
# string, so every control character needs escaping - not just newline. A tab in
# a custom template would otherwise produce a payload that strict parsers reject
# ("Bad control character in string literal"), silently breaking delivery.
json_escape() {
  local text="$1"
  local dec cc esc

  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\b'/\\b}"
  text="${text//$'\f'/\\f}"

  # Remaining control characters have no short escape; emit the \uXXXX form.
  # Decimal codepoints, skipping those handled above (8, 9, 10, 12, 13).
  for dec in 1 2 3 4 5 6 7 11 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    cc=$(printf '%b' "$(printf '\\%03o' "$dec")")
    if [[ "$text" == *"$cc"* ]]; then
      esc=$(printf '\\u%04X' "$dec")
      text="${text//$cc/$esc}"
    fi
  done

  printf '%s' "$text"
}

# Format a second count as a human duration
fmt_duration() {
  local s="$1"
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "n/a"; return 0; }

  if (( s < 60 )); then
    echo "${s}s"
  elif (( s < 3600 )); then
    echo "$((s / 60))m"
  elif (( s < 86400 )); then
    echo "$((s / 3600))h $(((s % 3600) / 60))m"
  else
    echo "$((s / 86400))d $(((s % 86400) / 3600))h"
  fi
}

#
# Main
#

if [[ "$DIGEST_ENABLED" != "1" ]]; then
  log "Digest disabled (DIGEST_ENABLED=0)"
  exit 0
fi

SINCE="${DIGEST_WINDOW_HOURS} hours ago"

# --- Interface ---
ETHTOOL_BIN=""
ETHTOOL_OK=1
resolve_ethtool >/dev/null 2>&1 || ETHTOOL_OK=0
(( ETHTOOL_OK )) && ETHTOOL_BIN=$(resolve_ethtool)

IFACE="$NETPROBE_IFACE"
if [[ -z "$IFACE" ]]; then
  IFACE=$(detect_iface 2>/dev/null || echo "")
fi

# --- NIC hang signatures in the window ---
HANG_COUNT=0
TXTIMEOUT_COUNT=0
RESET_COUNT=0
ME_COUNT=0
LINK_CHANGES=0

if [[ -x /usr/bin/journalctl ]]; then
  KMSG=$(/usr/bin/journalctl -k --since "$SINCE" --no-pager 2>/dev/null || true)
  if [[ -n "$KMSG" ]]; then
    HANG_COUNT=$(echo "$KMSG" | /bin/grep -c 'Detected Hardware Unit Hang' || true)
    TXTIMEOUT_COUNT=$(echo "$KMSG" | /bin/grep -cE 'NETDEV WATCHDOG.*timed out' || true)
    RESET_COUNT=$(echo "$KMSG" | /bin/grep -c 'Reset adapter unexpectedly' || true)
    ME_COUNT=$(echo "$KMSG" | /bin/grep -c 'ME firmware caused invalid' || true)
    LINK_CHANGES=$(echo "$KMSG" | /bin/grep -cE 'NIC Link is (Up|Down)' || true)
  fi
fi

# --- Driver counters and trend since the previous digest ---
TX_TIMEOUT=0
TX_RESTART=0
RX_MISSED=0
RX_CRC=0
COUNTERS_OK=0

if (( ETHTOOL_OK )) && [[ -n "$IFACE" ]]; then
  STATS=$("$ETHTOOL_BIN" -S "$IFACE" 2>/dev/null || true)
  if [[ -n "$STATS" ]]; then
    COUNTERS_OK=1
    TX_TIMEOUT=$(get_stat "$STATS" "tx_timeout_count")
    TX_RESTART=$(get_stat "$STATS" "tx_restart_queue")
    RX_MISSED=$(get_stat "$STATS" "rx_missed_errors")
    RX_CRC=$(get_stat "$STATS" "rx_crc_errors")
  fi
fi

PREV_TX_TIMEOUT=$(read_field "$DIGEST_STATE" "TX_TIMEOUT" "")
PREV_TX_RESTART=$(read_field "$DIGEST_STATE" "TX_RESTART" "")

# Deltas are only meaningful when both samples are real and the counters did
# not reset (a reboot zeroes them).
delta_of() {
  local prev="$1" cur="$2"
  [[ "$prev" =~ ^[0-9]{1,15}$ ]] || { echo "n/a"; return 0; }
  [[ "$cur"  =~ ^[0-9]{1,15}$ ]] || { echo "n/a"; return 0; }
  if (( cur >= prev )); then
    echo $(( cur - prev ))
  else
    echo "reset"
  fi
}

DELTA_TX_TIMEOUT=$(delta_of "$PREV_TX_TIMEOUT" "$TX_TIMEOUT")
DELTA_TX_RESTART=$(delta_of "$PREV_TX_RESTART" "$TX_RESTART")

# --- Offload state ---
OFFLOAD_SUMMARY="unknown"
OFFLOAD_OK=1
if (( ETHTOOL_OK )) && [[ -n "$IFACE" ]]; then
  FEATURES=$("$ETHTOOL_BIN" -k "$IFACE" 2>/dev/null || true)
  if [[ -n "$FEATURES" ]]; then
    TSO=$(echo "$FEATURES" | /bin/grep -E '^tcp-segmentation-offload:' | /usr/bin/awk '{print $2}')
    GSO=$(echo "$FEATURES" | /bin/grep -E '^generic-segmentation-offload:' | /usr/bin/awk '{print $2}')
    GRO=$(echo "$FEATURES" | /bin/grep -E '^generic-receive-offload:' | /usr/bin/awk '{print $2}')
    OFFLOAD_SUMMARY="tso=${TSO:-?} gso=${GSO:-?} gro=${GRO:-?}"
    if [[ "$TSO" == "on" ]] || [[ "$GSO" == "on" ]] || [[ "$GRO" == "on" ]]; then
      OFFLOAD_OK=0
    fi
  fi
fi

# --- Link state ---
OPERSTATE="unknown"
CARRIER_DOWN=0
if [[ -n "$IFACE" ]] && [[ -r "/sys/class/net/$IFACE/operstate" ]]; then
  OPERSTATE=$(/bin/cat "/sys/class/net/$IFACE/operstate" 2>/dev/null || echo unknown)
  CARRIER_DOWN=$(/bin/cat "/sys/class/net/$IFACE/carrier_down_count" 2>/dev/null || echo 0)
fi

# --- WAN outage metrics (cumulative, and delta over the window) ---
TOTAL_OUTAGES=$(read_field "$METRICS_FILE" "TOTAL_OUTAGES" 0)
TOTAL_RECOVERIES=$(read_field "$METRICS_FILE" "TOTAL_RECOVERIES" 0)
TOTAL_REBOOTS=$(read_field "$METRICS_FILE" "TOTAL_REBOOTS" 0)
TOTAL_DOWNTIME=$(read_field "$METRICS_FILE" "TOTAL_DOWNTIME_SECONDS" 0)

PREV_OUTAGES=$(read_field "$DIGEST_STATE" "TOTAL_OUTAGES" "")
PREV_DOWNTIME=$(read_field "$DIGEST_STATE" "TOTAL_DOWNTIME" "")

DAY_OUTAGES=$(delta_of "$PREV_OUTAGES" "$TOTAL_OUTAGES")
DAY_DOWNTIME_RAW=$(delta_of "$PREV_DOWNTIME" "$TOTAL_DOWNTIME")
if [[ "$DAY_DOWNTIME_RAW" =~ ^[0-9]+$ ]]; then
  DAY_DOWNTIME=$(fmt_duration "$DAY_DOWNTIME_RAW")
else
  DAY_DOWNTIME="$DAY_DOWNTIME_RAW"
fi

# Count DRY_RUN trips in the window - while DRY_RUN=1 these are the false
# positives worth watching, not real reboots.
DRYRUN_TRIPS=0
if [[ -x /usr/bin/journalctl ]]; then
  DRYRUN_TRIPS=$(/usr/bin/journalctl -t netwatch-agent --since "$SINCE" --no-pager 2>/dev/null \
    | /bin/grep -c 'DRY_RUN: would reboot now' || true)
fi

UPTIME_SEC=$(/usr/bin/cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
UPTIME_H=$(fmt_duration "$UPTIME_SEC")

# --- Verdict ---
#
# HOLDING    - no hang signatures, offloads still off
# ATTENTION  - something worth looking at but not the known failure mode
# DEGRADED   - the e1000e hang is back, or offloads silently re-enabled
#
VERDICT="HOLDING"
VERDICT_NOTES=""

if (( HANG_COUNT > 0 )); then
  VERDICT="DEGRADED"
  VERDICT_NOTES+="hardware-unit-hang "
fi
if (( ! OFFLOAD_OK )); then
  VERDICT="DEGRADED"
  VERDICT_NOTES+="offloads-re-enabled "
fi
if (( ME_COUNT > 0 )); then
  VERDICT="DEGRADED"
  VERDICT_NOTES+="me-firmware-corruption "
fi

if [[ "$VERDICT" == "HOLDING" ]]; then
  if (( TXTIMEOUT_COUNT > 0 )) || (( RESET_COUNT > 0 )); then
    VERDICT="ATTENTION"
    VERDICT_NOTES+="tx-timeout-or-reset "
  fi
  if [[ "$DELTA_TX_TIMEOUT" =~ ^[0-9]+$ ]] && (( DELTA_TX_TIMEOUT > 0 )); then
    VERDICT="ATTENTION"
    VERDICT_NOTES+="tx-timeout-rising "
  fi
  if (( LINK_CHANGES > 2 )); then
    VERDICT="ATTENTION"
    VERDICT_NOTES+="link-flapping "
  fi
  if [[ "$OPERSTATE" != "up" ]] && [[ "$OPERSTATE" != "unknown" ]]; then
    VERDICT="ATTENTION"
    VERDICT_NOTES+="link-not-up "
  fi
  if (( COUNTERS_OK == 0 )); then
    VERDICT="ATTENTION"
    VERDICT_NOTES+="counters-unreadable "
  fi
fi

[[ -z "$VERDICT_NOTES" ]] && VERDICT_NOTES="all clear"

# --- Redaction ---
#
# The digest usually goes to a third-party service, so host identifiers are
# omitted unless explicitly enabled. The interface name is a local label with
# no addressing information, so it is safe to include.
if [[ "$DIGEST_INCLUDE_HOSTNAME" == "1" ]]; then
  HOST_LABEL=$(/usr/bin/hostname 2>/dev/null || echo "unknown")
else
  HOST_LABEL="(redacted)"
fi

DATE_LABEL=$(/usr/bin/date '+%Y-%m-%d %H:%M %Z')
IFACE_LABEL="${IFACE:-unknown}"

# --- Render ---
#
# Default body is a compact table. Override DIGEST_BODY_TEMPLATE to trim or
# restructure - any {PLACEHOLDER} below is substituted, and ones you leave out
# simply do not appear.
DEFAULT_TEMPLATE='**Netwatch daily digest** — {DATE}
Verdict: **{VERDICT}** ({VERDICT_NOTES})

```
NIC ({IFACE})        link={OPERSTATE}  offloads: {OFFLOADS}
Hangs ({WINDOW_HOURS}h)         hardware-unit-hang={HANGS}  tx-timeout={TXTIMEOUTS}
                     adapter-reset={RESETS}  me-corruption={ME}
Counters             tx_timeout={TX_TIMEOUT} (Δ{D_TX_TIMEOUT})
                     tx_restart={TX_RESTART} (Δ{D_TX_RESTART})
                     rx_missed={RX_MISSED}  rx_crc={RX_CRC}
Link changes ({WINDOW_HOURS}h)  {LINK_CHANGES}
WAN ({WINDOW_HOURS}h)           outages={DAY_OUTAGES}  downtime={DAY_DOWNTIME}  dry-run-trips={DRYRUN_TRIPS}
WAN (lifetime)       outages={TOTAL_OUTAGES}  recoveries={TOTAL_RECOVERIES}  reboots={TOTAL_REBOOTS}
Host                 uptime={UPTIME}
```'

BODY_RAW="${DIGEST_BODY_TEMPLATE:-$DEFAULT_TEMPLATE}"

subst() {
  local text="$1"
  text="${text//\{DATE\}/$DATE_LABEL}"
  text="${text//\{HOSTNAME\}/$HOST_LABEL}"
  text="${text//\{IFACE\}/$IFACE_LABEL}"
  text="${text//\{VERDICT\}/$VERDICT}"
  text="${text//\{VERDICT_NOTES\}/${VERDICT_NOTES% }}"
  text="${text//\{OPERSTATE\}/$OPERSTATE}"
  text="${text//\{OFFLOADS\}/$OFFLOAD_SUMMARY}"
  text="${text//\{HANGS\}/$HANG_COUNT}"
  text="${text//\{TXTIMEOUTS\}/$TXTIMEOUT_COUNT}"
  text="${text//\{RESETS\}/$RESET_COUNT}"
  text="${text//\{ME\}/$ME_COUNT}"
  text="${text//\{LINK_CHANGES\}/$LINK_CHANGES}"
  text="${text//\{CARRIER_DOWN\}/$CARRIER_DOWN}"
  text="${text//\{TX_TIMEOUT\}/$TX_TIMEOUT}"
  text="${text//\{TX_RESTART\}/$TX_RESTART}"
  text="${text//\{RX_MISSED\}/$RX_MISSED}"
  text="${text//\{RX_CRC\}/$RX_CRC}"
  text="${text//\{D_TX_TIMEOUT\}/$DELTA_TX_TIMEOUT}"
  text="${text//\{D_TX_RESTART\}/$DELTA_TX_RESTART}"
  text="${text//\{DAY_OUTAGES\}/$DAY_OUTAGES}"
  text="${text//\{DAY_DOWNTIME\}/$DAY_DOWNTIME}"
  text="${text//\{DRYRUN_TRIPS\}/$DRYRUN_TRIPS}"
  text="${text//\{TOTAL_OUTAGES\}/$TOTAL_OUTAGES}"
  text="${text//\{TOTAL_RECOVERIES\}/$TOTAL_RECOVERIES}"
  text="${text//\{TOTAL_REBOOTS\}/$TOTAL_REBOOTS}"
  text="${text//\{TOTAL_DOWNTIME\}/$(fmt_duration "$TOTAL_DOWNTIME")}"
  text="${text//\{UPTIME\}/$UPTIME_H}"
  text="${text//\{WINDOW_HOURS\}/$DIGEST_WINDOW_HOURS}"
  printf '%s' "$text"
}

BODY=$(subst "$BODY_RAW")

# Always record the digest in the journal, redaction-independent: the journal
# is local, and this is the copy that matters for post-mortem work.
log "Digest [$VERDICT] iface=$IFACE_LABEL hangs=$HANG_COUNT tx_timeout=$TX_TIMEOUT(Δ$DELTA_TX_TIMEOUT) tx_restart=$TX_RESTART(Δ$DELTA_TX_RESTART) offloads=$OFFLOAD_SUMMARY day_outages=$DAY_OUTAGES dryrun_trips=$DRYRUN_TRIPS notes=${VERDICT_NOTES% }"

# --- Deliver ---
TARGET_URL="${DIGEST_WEBHOOK_URL:-$WEBHOOK_URL}"

if [[ "$WEBHOOK_ENABLED" == "1" ]] && [[ -n "$TARGET_URL" ]] && [[ -x /usr/bin/curl ]]; then
  JSON_BODY=$(json_escape "$BODY")

  # Discord embeds give a verdict-coloured left border, a field grid, and a
  # timestamp - none of which a plain content string can express. Other webhook
  # services do not understand the embeds array, so this is opt-in and the text
  # payload remains the default.
  if [[ "$DIGEST_FORMAT" == "embed" ]]; then
    case "$VERDICT" in
      HOLDING)   EMBED_COLOR=3066993 ;;   # green
      ATTENTION) EMBED_COLOR=16098851 ;;  # amber
      DEGRADED)  EMBED_COLOR=15158332 ;;  # red
      *)         EMBED_COLOR=9807270 ;;   # grey
    esac

    EMBED_TITLE=$(json_escape "Netwatch digest - $VERDICT")
    EMBED_DESC=$(json_escape "${VERDICT_NOTES% }")
    EMBED_TS=$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

    # Field values are short so they sit side by side in Discord's grid.
    F_NIC=$(json_escape "link=$OPERSTATE"$'\n'"$OFFLOAD_SUMMARY")
    F_HANGS=$(json_escape "hang=$HANG_COUNT  tx-timeout=$TXTIMEOUT_COUNT"$'\n'"reset=$RESET_COUNT  me=$ME_COUNT")
    F_COUNTERS=$(json_escape "tx_timeout=$TX_TIMEOUT (${DELTA_TX_TIMEOUT:-0})"$'\n'"tx_restart=$TX_RESTART (${DELTA_TX_RESTART:-0})")
    F_WAN=$(json_escape "outages=$DAY_OUTAGES  downtime=$DAY_DOWNTIME"$'\n'"dry-run trips=$DRYRUN_TRIPS")
    F_HOST=$(json_escape "iface=$IFACE_LABEL  uptime=$UPTIME_H"$'\n'"link changes=$LINK_CHANGES")

    # DIGEST_WINDOW_HOURS comes from operator-editable config, so it needs the
    # same escaping as every other dynamic value - a stray quote in it would
    # otherwise produce a malformed field name and break the whole payload.
    WINDOW_LABEL=$(json_escape "${DIGEST_WINDOW_HOURS}h")

    PAYLOAD="{\"embeds\":[{\"title\":\"$EMBED_TITLE\",\"description\":\"$EMBED_DESC\",\"color\":$EMBED_COLOR,\"timestamp\":\"$EMBED_TS\",\"fields\":["
    PAYLOAD+="{\"name\":\"NIC\",\"value\":\"$F_NIC\",\"inline\":true},"
    PAYLOAD+="{\"name\":\"Hangs ($WINDOW_LABEL)\",\"value\":\"$F_HANGS\",\"inline\":true},"
    PAYLOAD+="{\"name\":\"Counters\",\"value\":\"$F_COUNTERS\",\"inline\":true},"
    PAYLOAD+="{\"name\":\"WAN ($WINDOW_LABEL)\",\"value\":\"$F_WAN\",\"inline\":true},"
    PAYLOAD+="{\"name\":\"Host\",\"value\":\"$F_HOST\",\"inline\":true}"
    PAYLOAD+="]}]}"
  else
    PAYLOAD="{\"content\":\"$JSON_BODY\"}"
  fi

  declare -a curl_args=(-X "$WEBHOOK_METHOD" -m "$WEBHOOK_TIMEOUT" -s -S)
  if [[ -n "$WEBHOOK_HEADERS" ]]; then
    IFS=';' read -ra _headers <<< "$WEBHOOK_HEADERS"
    for h in "${_headers[@]}"; do
      curl_args+=(-H "$h")
    done
  fi
  if [[ ! "$WEBHOOK_HEADERS" == *"Content-Type"* ]]; then
    curl_args+=(-H "Content-Type: application/json")
  fi
  curl_args+=(-d "$PAYLOAD")

  if /usr/bin/curl "${curl_args[@]}" "$TARGET_URL" >/dev/null 2>&1; then
    log "Digest webhook sent"
  else
    log "WARNING: digest webhook failed"
  fi
else
  log "Webhook not configured; digest recorded in the journal only"
fi

# --- Persist for tomorrow's deltas ---
#
# Only overwrite counters that were actually read, so an ethtool outage does
# not reset the baseline and make tomorrow's real value look like a spike.
/bin/mkdir -p "$PERSIST_DIR" 2>/dev/null || true

SAVE_TX_TIMEOUT="$TX_TIMEOUT"
SAVE_TX_RESTART="$TX_RESTART"
if (( ! COUNTERS_OK )); then
  SAVE_TX_TIMEOUT="${PREV_TX_TIMEOUT:-0}"
  SAVE_TX_RESTART="${PREV_TX_RESTART:-0}"
fi

/bin/cat > "$DIGEST_STATE" <<EOF
LAST_DIGEST=$(/usr/bin/date +%s)
TX_TIMEOUT=$SAVE_TX_TIMEOUT
TX_RESTART=$SAVE_TX_RESTART
TOTAL_OUTAGES=$TOTAL_OUTAGES
TOTAL_DOWNTIME=$TOTAL_DOWNTIME
EOF
/bin/chmod 0600 "$DIGEST_STATE" 2>/dev/null || true

exit 0
