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
: "${TARGETS:=1.1.1.1 8.8.8.8 9.9.9.9}"
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

#
# Utility functions
#

# Log a message to syslog/journald (fallback to stderr if logger unavailable)
log() {
  if [[ -x /usr/bin/logger ]]; then
    /usr/bin/logger -t "$TAG" -- "$*"
  else
    echo "[$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')] $TAG: $*" >&2
  fi
}

# Get current Unix timestamp
now() {
  /usr/bin/date +%s
}

#
# Core probe function: check if WAN is reachable
#
# Returns 0 (success) if at least MIN_OK targets respond
# Returns 1 (failure) if fewer than MIN_OK targets respond
#
parallel_probe() {
  local ok=0
  local -a targets=($TARGETS)

  # Prefer fping for efficient parallel probing
  if [[ "$USE_FPING" != "no" ]] && [[ -x /usr/sbin/fping ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output

    # Run fping and capture output (redirects stderr to stdout)
    output=$(/usr/sbin/fping -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)

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

# Signal systemd that we're ready (if systemd-notify is available)
if [[ -x /usr/bin/systemd-notify ]]; then
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

# State tracking
DOWN_START=-1      # Timestamp when outage started (-1 = currently up)
LAST_REBOOT=0      # Timestamp of last reboot (for cooldown enforcement)

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
      DOWN_START=-1
    fi
  else
    # WAN is down
    if (( DOWN_START == -1 )); then
      # Outage just started
      DOWN_START=$(now)
      log "WAN appears down; starting outage timer"
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
          else
            log "Reboot threshold met (outage: ${CURRENT_OUTAGE}s >= ${DOWN_WINDOW_SECONDS}s)"
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

  # Send watchdog heartbeat to systemd (if configured)
  if [[ -x /usr/bin/systemd-notify ]]; then
    /usr/bin/systemd-notify --watchdog || true
  fi

  # Sleep until next check
  /bin/sleep "$CHECK_INTERVAL"
done
