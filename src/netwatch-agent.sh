#!/usr/bin/env bash
#
# netwatch-agent.sh - WAN Watchdog for Proxmox VE
#
# Monitors WAN connectivity via parallel ICMP probes and reboots the host
# after a configurable period of continuous outage. Includes safety rails:
# boot grace, cooldown, disable file, and dry-run mode.
#
# Runtime: Bash + systemd only (no external dependencies beyond coreutils)
# License: MIT
#

set -Eeuo pipefail

# Absolute PATH for deterministic binary resolution
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Logging and runtime constants
TAG="netwatch-agent"
STATE_DIR="${STATE_DIR:-/run/netwatch-agent}"
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR=/tmp/netwatch-agent-$$
mkdir -p "$STATE_DIR"

# Load configuration from systemd EnvironmentFile
[[ -r /etc/default/netwatch-agent ]] && . /etc/default/netwatch-agent

# Apply defaults for all configuration variables
: "${HEALTH_CHECK_MODE:=icmp}"
: "${TARGETS:=1.1.1.1 8.8.8.8 9.9.9.9}"
: "${TCP_TARGETS:=1.1.1.1:853 8.8.8.8:443 9.9.9.9:443}"
: "${HTTP_TARGETS:=https://1.1.1.1 https://8.8.8.8 https://9.9.9.9}"
: "${HTTP_EXPECTED_CODE:=200}"
: "${MIN_OK:=1}"
: "${PING_COUNT:=1}"
: "${PING_TIMEOUT:=1}"
: "${CHECK_INTERVAL:=10}"
: "${DOWN_WINDOW_SECONDS:=600}"
: "${BOOT_GRACE:=180}"
: "${COOLDOWN_SECONDS:=1200}"
: "${DISABLE_FILE:=/etc/netwatch-agent.disable}"
: "${DRY_RUN:=0}"
: "${USE_FPING:=auto}"

# Webhook configuration
: "${WEBHOOK_ENABLED:=0}"
: "${WEBHOOK_URL:=}"
: "${WEBHOOK_METHOD:=POST}"
: "${WEBHOOK_HEADERS:=}"
: "${WEBHOOK_BODY_TEMPLATE:=}"
: "${WEBHOOK_EVENTS:=down,recovery,reboot,startup,health}"
: "${WEBHOOK_TIMEOUT:=10}"
: "${WEBHOOK_HEALTH_INTERVAL:=86400}"  # Daily health report (24 hours)

# Metrics persistence
METRICS_FILE="$STATE_DIR/metrics.dat"

#
# Utility functions
#

# Log a message to syslog/journald (fallback to stderr if logger unavailable)
log() {
  # Optionally mirror logs to stderr for test harnesses (LOG_TO_STDERR=1)
  if [[ "${LOG_TO_STDERR:-0}" == "1" ]]; then
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] $TAG: $*" >&2
  fi

  if [[ -x /usr/bin/logger ]]; then
    /usr/bin/logger -t "$TAG" -- "$*" || true
  elif [[ "${LOG_TO_STDERR:-0}" != "1" ]]; then
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] $TAG: $*" >&2
  fi
}

# Get current Unix timestamp
now() {
  /usr/bin/date +%s
}

#
# Metrics tracking
#
# Metrics stored in $METRICS_FILE as key=value pairs:
#   total_reboots, total_outages, total_recoveries, total_downtime_seconds
#   last_health_report, service_start_time
#

load_metrics() {
  # Initialize defaults
  TOTAL_REBOOTS=0
  TOTAL_OUTAGES=0
  TOTAL_RECOVERIES=0
  TOTAL_DOWNTIME_SECONDS=0
  LAST_HEALTH_REPORT=0
  SERVICE_START_TIME=$(now)

  # Load from file if exists
  if [[ -f "$METRICS_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$METRICS_FILE" 2>/dev/null || true
  fi
}

save_metrics() {
  /bin/cat > "$METRICS_FILE" <<EOF
TOTAL_REBOOTS=$TOTAL_REBOOTS
TOTAL_OUTAGES=$TOTAL_OUTAGES
TOTAL_RECOVERIES=$TOTAL_RECOVERIES
TOTAL_DOWNTIME_SECONDS=$TOTAL_DOWNTIME_SECONDS
LAST_HEALTH_REPORT=$LAST_HEALTH_REPORT
SERVICE_START_TIME=$SERVICE_START_TIME
EOF
}

increment_metric() {
  local metric="$1"
  local value="${2:-1}"

  case "$metric" in
    reboots)
      TOTAL_REBOOTS=$((TOTAL_REBOOTS + value))
      ;;
    outages)
      TOTAL_OUTAGES=$((TOTAL_OUTAGES + value))
      ;;
    recoveries)
      TOTAL_RECOVERIES=$((TOTAL_RECOVERIES + value))
      ;;
    downtime)
      TOTAL_DOWNTIME_SECONDS=$((TOTAL_DOWNTIME_SECONDS + value))
      ;;
  esac

  save_metrics
}

#
# Send webhook notification
#
# Parameters:
#   $1 - event type (down, recovery, reboot)
#   $2 - message text
#   $3 - duration (optional, for recovery/reboot events)
#
send_webhook() {
  local event="$1"
  local message="$2"
  local duration="${3:-0}"

  # Check if webhooks are enabled and URL is configured
  [[ "$WEBHOOK_ENABLED" != "1" ]] && return 0
  [[ -z "$WEBHOOK_URL" ]] && return 0

  # Check if this event type should trigger webhook
  if [[ ! ",$WEBHOOK_EVENTS," == *",$event,"* ]]; then
    return 0
  fi

  # Check if curl is available
  if ! command -v /usr/bin/curl >/dev/null 2>&1; then
    log "WEBHOOK: curl not found, skipping notification"
    return 0
  fi

  # Get hostname
  local hostname
  hostname=$(/usr/bin/hostname 2>/dev/null || echo "unknown")

  # Get current timestamp
  local timestamp
  timestamp=$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")

  # Calculate uptime
  local uptime_seconds
  uptime_seconds=$(/usr/bin/cut -d. -f1 /proc/uptime 2>/dev/null || echo "0")

  # Calculate service runtime
  local service_runtime=$(($(now) - SERVICE_START_TIME))

  # Build the request body
  local body
  if [[ -n "$WEBHOOK_BODY_TEMPLATE" ]]; then
    # Use custom template with variable substitution
    body="$WEBHOOK_BODY_TEMPLATE"
    body="${body//\{EVENT\}/$event}"
    body="${body//\{MESSAGE\}/$message}"
    body="${body//\{HOSTNAME\}/$hostname}"
    body="${body//\{TIMESTAMP\}/$timestamp}"
    body="${body//\{DURATION\}/$duration}"
    body="${body//\{TARGETS\}/$TARGETS}"
    body="${body//\{DOWN_WINDOW\}/$DOWN_WINDOW_SECONDS}"
    body="${body//\{UPTIME\}/$uptime_seconds}"
    body="${body//\{TOTAL_REBOOTS\}/$TOTAL_REBOOTS}"
    body="${body//\{TOTAL_OUTAGES\}/$TOTAL_OUTAGES}"
    body="${body//\{TOTAL_RECOVERIES\}/$TOTAL_RECOVERIES}"
    body="${body//\{TOTAL_DOWNTIME\}/$TOTAL_DOWNTIME_SECONDS}"
    body="${body//\{SERVICE_RUNTIME\}/$service_runtime}"
  else
    # Default JSON format (include metrics for startup/health events)
    if [[ "$event" == "startup" ]] || [[ "$event" == "health" ]]; then
      body="{\"event\":\"$event\",\"message\":\"$message\",\"hostname\":\"$hostname\",\"timestamp\":\"$timestamp\",\"uptime\":$uptime_seconds,\"metrics\":{\"total_reboots\":$TOTAL_REBOOTS,\"total_outages\":$TOTAL_OUTAGES,\"total_recoveries\":$TOTAL_RECOVERIES,\"total_downtime_seconds\":$TOTAL_DOWNTIME_SECONDS,\"service_runtime\":$service_runtime}}"
    else
      body="{\"event\":\"$event\",\"message\":\"$message\",\"hostname\":\"$hostname\",\"timestamp\":\"$timestamp\",\"duration\":$duration,\"targets\":\"$TARGETS\"}"
    fi
  fi

  # Build curl command
  local -a curl_args=(
    -X "$WEBHOOK_METHOD"
    -m "$WEBHOOK_TIMEOUT"
    -s
    -S
  )

  # Add custom headers if specified (semicolon-separated)
  if [[ -n "$WEBHOOK_HEADERS" ]]; then
    local IFS=';'
    for header in $WEBHOOK_HEADERS; do
      curl_args+=(-H "$header")
    done
  fi

  # Add default Content-Type if not specified and body is JSON-like
  if [[ -z "$WEBHOOK_HEADERS" ]] || [[ ! "$WEBHOOK_HEADERS" == *"Content-Type"* ]]; then
    if [[ "$body" == "{"* ]] || [[ -z "$WEBHOOK_BODY_TEMPLATE" ]]; then
      curl_args+=(-H "Content-Type: application/json")
    fi
  fi

  # Add body data
  curl_args+=(-d "$body")

  # Send webhook (background to avoid blocking)
  (
    if /usr/bin/curl "${curl_args[@]}" "$WEBHOOK_URL" >/dev/null 2>&1; then
      log "WEBHOOK: sent $event notification"
    else
      log "WEBHOOK: failed to send $event notification to $WEBHOOK_URL"
    fi
  ) &
}

#
# TCP probe function: check if WAN is reachable via TCP connection
#
# Returns 0 (success) if at least MIN_OK targets respond
# Returns 1 (failure) if fewer than MIN_OK targets respond
#
probe_tcp() {
  local ok=0
  local -a targets
  read -ra targets <<< "$TCP_TARGETS"

  # Check if netcat is available
  local nc_cmd=""
  if [[ -x /bin/nc ]]; then
    nc_cmd="/bin/nc"
  elif [[ -x /usr/bin/nc ]]; then
    nc_cmd="/usr/bin/nc"
  else
    log "ERROR: netcat (nc) not found - TCP health checks require netcat"
    return 1
  fi

  # Parallel TCP connection attempts
  local -a pids=()
  local -a tmp_files=()

  for target in "${targets[@]}"; do
    # Split host:port
    if [[ ! "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
      log "WARNING: Invalid TCP target format: $target (expected host:port)"
      continue
    fi

    local host="${BASH_REMATCH[1]}"
    local port="${BASH_REMATCH[2]}"

    # Create temp file for this check
    local tmp_file
    tmp_file=$(/bin/mktemp -p "$STATE_DIR" nc.XXXXXX)
    tmp_files+=("$tmp_file")

    # Background TCP connection test
    (
      if "$nc_cmd" -z -w "$PING_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
        echo "ok" > "$tmp_file"
      fi
    ) &
    pids+=($!)
  done

  # Wait for all probes to complete
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Count successes
  for tmp_file in "${tmp_files[@]}"; do
    if [[ -f "$tmp_file" ]] && [[ "$(<"$tmp_file")" == "ok" ]]; then
      ((ok++))
    fi
    /bin/rm -f "$tmp_file" 2>/dev/null || true
  done

  # Success if we met the minimum threshold
  (( ok >= MIN_OK ))
}

#
# HTTP probe function: check if WAN is reachable via HTTP/HTTPS request
#
# Returns 0 (success) if at least MIN_OK targets respond
# Returns 1 (failure) if fewer than MIN_OK targets respond
#
probe_http() {
  local ok=0
  local -a targets
  read -ra targets <<< "$HTTP_TARGETS"

  # Check if curl is available
  if ! [[ -x /usr/bin/curl ]]; then
    log "ERROR: curl not found - HTTP health checks require curl"
    return 1
  fi

  # Parallel HTTP requests
  local -a pids=()
  local -a tmp_files=()

  for url in "${targets[@]}"; do
    # Create temp file for this check
    local tmp_file
    tmp_file=$(/bin/mktemp -p "$STATE_DIR" http.XXXXXX)
    tmp_files+=("$tmp_file")

    # Background HTTP request
    (
      # Use --insecure to allow self-signed certs, --fail to error on HTTP errors
      # -m for timeout, -s for silent, -o to write status code
      local status_code
      status_code=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" \
        --insecure \
        -m "$PING_TIMEOUT" \
        "$url" 2>/dev/null || echo "000")

      if [[ "$status_code" == "$HTTP_EXPECTED_CODE" ]]; then
        echo "ok" > "$tmp_file"
      fi
    ) &
    pids+=($!)
  done

  # Wait for all probes to complete
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Count successes
  for tmp_file in "${tmp_files[@]}"; do
    if [[ -f "$tmp_file" ]] && [[ "$(<"$tmp_file")" == "ok" ]]; then
      ((ok++))
    fi
    /bin/rm -f "$tmp_file" 2>/dev/null || true
  done

  # Success if we met the minimum threshold
  (( ok >= MIN_OK ))
}

#
# ICMP probe function: check if WAN is reachable via ICMP ping
#
# Returns 0 (success) if at least MIN_OK targets respond
# Returns 1 (failure) if fewer than MIN_OK targets respond
#
probe_icmp() {
  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  # Determine fping binary (prefer /usr/sbin, fallback to /usr/bin for Debian/Ubuntu)
  local FPING_BIN="/usr/sbin/fping"
  if [[ ! -x "$FPING_BIN" ]] && [[ -x /usr/bin/fping ]]; then
    FPING_BIN="/usr/bin/fping"
  fi

  # Prefer fping for efficient parallel probing
  if [[ "$USE_FPING" != "no" ]] && [[ -x "$FPING_BIN" ]]; then
    log "using fping for parallel ICMP probing"
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output

    # Run fping and capture output (redirects stderr to stdout)
    output=$("$FPING_BIN" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)

    # Parse fping summary lines: look for "xmt/rcv/%loss" with rcv >= 1
    while IFS= read -r line; do
      [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
      # Extract received count (format: "host : xmt/rcv/%loss = X/Y/Z%")
      if [[ "$line" =~ :\ ([0-9]+)/([0-9]+)/ ]]; then
        local rcv="${BASH_REMATCH[2]}"
        if (( rcv >= 1 )); then
          ((ok++))
        fi
      fi
    done <<<"$output"
  else
    # Fallback: parallel background pings
    local -a pids=()

    for host in "${targets[@]}"; do
      (/bin/ping -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1) &
      pids+=($!)
    done

    # Wait for all probes and count successes
    for pid in "${pids[@]}"; do
      if wait "$pid"; then
        ((ok++))
      fi
    done
  fi

  # Success if we met the minimum threshold
  (( ok >= MIN_OK ))
}

#
# Main probe dispatcher: routes to appropriate health check method
#
# Returns 0 (success) if WAN is reachable
# Returns 1 (failure) if WAN is unreachable
#
parallel_probe() {
  case "$HEALTH_CHECK_MODE" in
    icmp)
      probe_icmp
      ;;
    tcp)
      probe_tcp
      ;;
    http)
      probe_http
      ;;
    *)
      log "ERROR: Invalid HEALTH_CHECK_MODE='$HEALTH_CHECK_MODE' (expected: icmp, tcp, or http)"
      log "Falling back to ICMP mode"
      probe_icmp
      ;;
  esac
}

#
# Reboot the host with proper sync and logging
#
perform_reboot() {
  log "Initiating host reboot due to continuous WAN outage"

  # Sync filesystems
  /bin/sync 2>/dev/null || true

  # Attempt graceful systemd reboot, fallback to direct reboot
  if /usr/bin/systemctl reboot -i 2>/dev/null; then
    log "Reboot command sent via systemctl"
  else
    /sbin/reboot now
  fi

  # Sleep to prevent loop thrashing during shutdown
  /bin/sleep 30
}

#
# Main execution
#

# Validate health check mode and dependencies
case "$HEALTH_CHECK_MODE" in
  icmp)
    # ICMP only requires ping (always available)
    log "Health check mode: ICMP (ping)"
    ;;
  tcp)
    # TCP requires netcat
    log "Health check mode: TCP (netcat)"
    if ! [[ -x /bin/nc ]] && ! [[ -x /usr/bin/nc ]]; then
      log "FATAL: netcat (nc) not found - TCP mode requires netcat (install netcat-openbsd)"
      exit 1
    fi
    ;;
  http)
    # HTTP requires curl
    log "Health check mode: HTTP/HTTPS (curl)"
    if ! [[ -x /usr/bin/curl ]]; then
      log "FATAL: curl not found - HTTP mode requires curl (install with: apt install curl)"
      exit 1
    fi
    ;;
  *)
    log "ERROR: Invalid HEALTH_CHECK_MODE='$HEALTH_CHECK_MODE' (expected: icmp, tcp, or http)"
    log "Falling back to ICMP mode"
    HEALTH_CHECK_MODE="icmp"
    ;;
esac

# Signal systemd that we're ready (if systemd-notify is available and socket is set)
if [[ -x /usr/bin/systemd-notify ]] && [[ -n "${NOTIFY_SOCKET:-}" ]]; then
  /usr/bin/systemd-notify --ready || true
fi

# Boot grace period: wait if system just booted
UPTIME_SEC=$(/usr/bin/cut -d. -f1 /proc/uptime)
if (( UPTIME_SEC < BOOT_GRACE )); then
  WAIT_TIME=$((BOOT_GRACE - UPTIME_SEC))
  log "Boot grace: waiting ${WAIT_TIME}s (system uptime: ${UPTIME_SEC}s)"
  /bin/sleep "$WAIT_TIME"
fi

log "Starting WAN watchdog (targets: $TARGETS, threshold: ${MIN_OK}/${TARGETS// /,}, window: ${DOWN_WINDOW_SECONDS}s)"

# Load metrics from persistent storage
load_metrics

# Send startup notification (useful for confirming system came back up after reboot)
if [[ "$UPTIME_SEC" -lt 600 ]]; then
  # Recent boot (within 10 minutes) - likely post-reboot
  UPTIME_MIN=$((UPTIME_SEC / 60))
  send_webhook "startup" "Service started after system boot (uptime: ${UPTIME_MIN}m, total reboots: $TOTAL_REBOOTS)" "$UPTIME_SEC"
  log "Startup notification sent (uptime: ${UPTIME_MIN}m)"
fi

# State tracking
DOWN_START=-1      # Timestamp when outage started (-1 = currently up)
LAST_REBOOT=0      # Timestamp of last reboot (for cooldown enforcement)

# Initialize health report schedule only if enabled
if (( WEBHOOK_HEALTH_INTERVAL > 0 )); then
  NEXT_HEALTH_REPORT=$(($(now) + WEBHOOK_HEALTH_INTERVAL))
else
  NEXT_HEALTH_REPORT=0  # Disabled
fi

#
# Main monitoring loop
#
while true; do
  # Check for disable file
  if [[ -f "$DISABLE_FILE" ]]; then
    log "Watchdog disabled via $DISABLE_FILE"
    /bin/sleep 30
    continue
  fi

  # Probe WAN connectivity
  if parallel_probe; then
    # WAN is reachable
    if (( DOWN_START != -1 )); then
      # Recovery from outage
      OUTAGE_DURATION=$(($(now) - DOWN_START))
      log "WAN reachable again after ${OUTAGE_DURATION}s outage"
      increment_metric "recoveries"
      increment_metric "downtime" "$OUTAGE_DURATION"
      send_webhook "recovery" "WAN connectivity restored after ${OUTAGE_DURATION}s outage" "$OUTAGE_DURATION"
      DOWN_START=-1
    fi
  else
    # WAN is down
    if (( DOWN_START == -1 )); then
      # Outage just started
      DOWN_START=$(now)
      log "WAN appears down; starting outage timer"
      increment_metric "outages"
      send_webhook "down" "WAN connectivity lost, monitoring for ${DOWN_WINDOW_SECONDS}s threshold" "0"
    else
      # Outage continuing - check if threshold met
      CURRENT_OUTAGE=$(($(now) - DOWN_START))

      if (( CURRENT_OUTAGE >= DOWN_WINDOW_SECONDS )); then
        # Threshold met - check cooldown
        TIME_SINCE_REBOOT=$(($(now) - LAST_REBOOT))

        if (( TIME_SINCE_REBOOT >= COOLDOWN_SECONDS )); then
          # Ready to reboot
          LAST_REBOOT=$(now)

          if (( DRY_RUN == 1 )); then
            log "DRY_RUN: would reboot now (outage: ${CURRENT_OUTAGE}s >= ${DOWN_WINDOW_SECONDS}s)"
            send_webhook "reboot" "DRY_RUN: Would reboot after ${CURRENT_OUTAGE}s outage" "$CURRENT_OUTAGE"
          else
            log "Reboot threshold met (outage: ${CURRENT_OUTAGE}s >= ${DOWN_WINDOW_SECONDS}s)"
            increment_metric "reboots"
            send_webhook "reboot" "Rebooting host after ${CURRENT_OUTAGE}s continuous WAN outage" "$CURRENT_OUTAGE"
            perform_reboot
          fi

          # Sleep after reboot trigger to prevent tight loop
          /bin/sleep 30
        else
          # Cooldown active
          COOLDOWN_REMAINING=$((COOLDOWN_SECONDS - TIME_SINCE_REBOOT))
          log "Cooldown active: ${COOLDOWN_REMAINING}s remaining (outage continues: ${CURRENT_OUTAGE}s)"
        fi
      fi
    fi
  fi

  # Send periodic health report (only if enabled)
  if (( WEBHOOK_HEALTH_INTERVAL > 0 )) && (( $(now) >= NEXT_HEALTH_REPORT )); then
    UPTIME_HOURS=$(( $(/usr/bin/cut -d. -f1 /proc/uptime) / 3600 ))
    DOWNTIME_HOURS=$((TOTAL_DOWNTIME_SECONDS / 3600))
    AVAILABILITY_PCT=$(( (TOTAL_DOWNTIME_SECONDS > 0) ? (100 - (TOTAL_DOWNTIME_SECONDS * 100 / ($(now) - SERVICE_START_TIME))) : 100 ))

    HEALTH_MSG="Health report: uptime ${UPTIME_HOURS}h, ${TOTAL_OUTAGES} outages (${TOTAL_RECOVERIES} recoveries), ${TOTAL_REBOOTS} reboots, ${DOWNTIME_HOURS}h total downtime, ${AVAILABILITY_PCT}% availability"
    send_webhook "health" "$HEALTH_MSG" "0"
    log "$HEALTH_MSG"

    LAST_HEALTH_REPORT=$(now)
    NEXT_HEALTH_REPORT=$(($(now) + WEBHOOK_HEALTH_INTERVAL))
    save_metrics
  fi

  # Send watchdog heartbeat to systemd (if configured)
  if [[ -x /usr/bin/systemd-notify ]] && [[ -n "${NOTIFY_SOCKET:-}" ]]; then
    /usr/bin/systemd-notify WATCHDOG=1 || true
  fi

  # Sleep until next check
  /bin/sleep "$CHECK_INTERVAL"
done
