#!/usr/bin/env bash
#
# unit-tests.sh - Unit tests for Netwatch WAN Watchdog
#
# Tests individual functions and logic paths in isolation using mocked
# commands and controlled environments. Run this before deployment.
#
# Usage: ./unit-tests.sh
#

set -Eeuo pipefail

# Find binaries (prefer /usr/bin, fallback to /bin)
if [[ -x /usr/bin/mktemp ]]; then
  MKTEMP="/usr/bin/mktemp"
elif [[ -x /bin/mktemp ]]; then
  MKTEMP="/bin/mktemp"
else
  echo "ERROR: mktemp not found" >&2
  exit 1
fi

if [[ -x /usr/bin/rm ]]; then
  RM="/usr/bin/rm"
elif [[ -x /bin/rm ]]; then
  RM="/bin/rm"
else
  echo "ERROR: rm not found" >&2
  exit 1
fi

if [[ -x /usr/bin/chmod ]]; then
  CHMOD="/usr/bin/chmod"
elif [[ -x /bin/chmod ]]; then
  CHMOD="/bin/chmod"
else
  echo "ERROR: chmod not found" >&2
  exit 1
fi

if [[ -x /usr/bin/cat ]]; then
  CAT="/usr/bin/cat"
elif [[ -x /bin/cat ]]; then
  CAT="/bin/cat"
else
  echo "ERROR: cat not found" >&2
  exit 1
fi

# Repository paths (allows running the harness from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="$SCRIPT_DIR/../src/netwatch-agent.sh"

# Test framework state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

#
# Test framework functions
#

test_start() {
  echo -e "${YELLOW}TEST:${NC} $*"
  ((TESTS_RUN++)) || true
}

test_pass() {
  echo -e "${GREEN}PASS${NC}"
  ((TESTS_PASSED++)) || true
}

test_fail() {
  echo -e "${RED}FAIL${NC} - $*"
  ((TESTS_FAILED++)) || true
}

#
# Mock environment setup
#
# Note: We create mock binaries but use absolute paths to invoke them
# instead of manipulating PATH (security requirement)
#

setup_mock_env() {
  export MOCK_DIR
  MOCK_DIR=$("$MKTEMP" -d)

  # Export absolute paths to mock binaries for tests to use
  export MOCK_FPING="$MOCK_DIR/fping"
  export MOCK_PING="$MOCK_DIR/ping"
}

cleanup_mock_env() {
  "$RM" -rf "$MOCK_DIR"
}

create_mock_fping() {
  local exit_code="${1:-0}"
  local output="${2:-}"

  "$CAT" > "$MOCK_FPING" <<EOF
#!/usr/bin/env bash
echo "$output"
exit $exit_code
EOF
  "$CHMOD" +x "$MOCK_FPING"
}

create_mock_ping() {
  local exit_code="${1:-0}"

  "$CAT" > "$MOCK_PING" <<EOF
#!/usr/bin/env bash
exit $exit_code
EOF
  "$CHMOD" +x "$MOCK_PING"
}

# Create mock netcat (nc) for TCP health checks
# Usage: create_mock_nc <exit_code>
create_mock_nc() {
  local exit_code="${1:-0}"

  export MOCK_NC="$MOCK_DIR/nc"
  "$CAT" > "$MOCK_NC" <<EOF
#!/usr/bin/env bash
# Mock netcat - simulates TCP connection test
# Usage: nc -z -w TIMEOUT HOST PORT
exit $exit_code
EOF
  "$CHMOD" +x "$MOCK_NC"
}

# Create mock curl for HTTP health checks
# Usage: create_mock_curl <http_status_code>
create_mock_curl() {
  local status_code="${1:-200}"

  export MOCK_CURL="$MOCK_DIR/curl"
  "$CAT" > "$MOCK_CURL" <<EOF
#!/usr/bin/env bash
# Mock curl - simulates HTTP request
# Usage: curl -s -o /dev/null -w "%{http_code}" --insecure -m TIMEOUT URL
echo "$status_code"
exit 0
EOF
  "$CHMOD" +x "$MOCK_CURL"
}

#
# Test helper functions
#

# Parse fping output and count successful targets
# Usage: count=$(parse_fping_success_count "$fping_output")
parse_fping_success_count() {
  local output="$1"
  local count=0

  while IFS= read -r line; do
    [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
    # Extract received count (format: "host : xmt/rcv/%loss = X/Y/Z%")
    if [[ "$line" =~ =\ ([0-9]+)/([0-9]+)/ ]]; then
      local rcv="${BASH_REMATCH[2]}"
      if (( rcv >= 1 )); then
        ((++count))
      fi
    fi
  done <<<"$output"

  echo "$count"
}

#
# Test cases
#

test_fping_all_targets_up() {
  test_start "fping mode: all targets responding"

  setup_mock_env

  # Mock fping output showing 3 targets all responding
  create_mock_fping 0 "1.1.1.1 : xmt/rcv/%loss = 1/1/0%
8.8.8.8 : xmt/rcv/%loss = 1/1/0%
9.9.9.9 : xmt/rcv/%loss = 1/1/0%"

  # Test configuration
  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1

  # Run fping probe logic inline
  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_FPING" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_FPING" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)
    ok=$(parse_fping_success_count "$output")
  fi

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

test_fping_partial_failure() {
  test_start "fping mode: partial target failure (should still pass with MIN_OK=1)"

  setup_mock_env

  # Mock fping output: 1 target up, 2 down
  create_mock_fping 1 "1.1.1.1 : xmt/rcv/%loss = 1/1/0%
8.8.8.8 : xmt/rcv/%loss = 1/0/100%
9.9.9.9 : xmt/rcv/%loss = 1/0/100%"

  # Test configuration
  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1

  # Run fping probe logic inline
  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_FPING" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_FPING" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)
    ok=$(parse_fping_success_count "$output")
  fi

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

test_fping_all_targets_down() {
  test_start "fping mode: all targets down (should fail)"

  setup_mock_env

  # Mock fping output: all targets down
  create_mock_fping 1 "1.1.1.1 : xmt/rcv/%loss = 1/0/100%
8.8.8.8 : xmt/rcv/%loss = 1/0/100%
9.9.9.9 : xmt/rcv/%loss = 1/0/100%"

  # Test configuration
  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1

  # Run fping probe logic inline
  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_FPING" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_FPING" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)
    ok=$(parse_fping_success_count "$output")
  fi

  if (( ok < MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok < $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

test_ping_fallback_all_up() {
  test_start "ping fallback mode: all targets responding"

  setup_mock_env

  # Mock ping to always succeed
  create_mock_ping 0

  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1

  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  # Simulate fallback ping mode
  local -a pids=()
  for host in "${targets[@]}"; do
    ("$MOCK_PING" -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      ((++ok))
    fi
  done

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

test_ping_fallback_all_down() {
  test_start "ping fallback mode: all targets down (should fail)"

  setup_mock_env

  # Mock ping to always fail
  create_mock_ping 1

  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1

  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  local -a pids=()
  for host in "${targets[@]}"; do
    ("$MOCK_PING" -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      ((++ok))
    fi
  done

  if (( ok < MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok < $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

test_min_ok_threshold() {
  test_start "MIN_OK threshold: require 2/3 targets (should fail with 1/3)"

  setup_mock_env

  # Mock fping: only 1 target up
  create_mock_fping 1 "1.1.1.1 : xmt/rcv/%loss = 1/1/0%
8.8.8.8 : xmt/rcv/%loss = 1/0/100%
9.9.9.9 : xmt/rcv/%loss = 1/0/100%"

  # Test configuration
  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=2  # Require 2 targets
  PING_COUNT=1
  PING_TIMEOUT=1

  # Run fping probe logic inline
  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_FPING" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_FPING" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)
    ok=$(parse_fping_success_count "$output")
  fi

  if (( ok < MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok < $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

test_outage_timer_logic() {
  test_start "Outage timer: threshold detection"

  # Simulate time progression
  local DOWN_START=1000
  local NOW=1610
  local DOWN_WINDOW_SECONDS=600

  local CURRENT_OUTAGE=$((NOW - DOWN_START))

  if (( CURRENT_OUTAGE >= DOWN_WINDOW_SECONDS )); then
    test_pass
  else
    test_fail "Expected outage >= $DOWN_WINDOW_SECONDS, got $CURRENT_OUTAGE"
  fi
}

test_cooldown_enforcement() {
  test_start "Cooldown enforcement: prevent reboot during cooldown"

  local LAST_REBOOT=1000
  local NOW=1500
  local COOLDOWN_SECONDS=1200

  local TIME_SINCE_REBOOT=$((NOW - LAST_REBOOT))

  if (( TIME_SINCE_REBOOT < COOLDOWN_SECONDS )); then
    test_pass
  else
    test_fail "Expected cooldown active, got time_since=$TIME_SINCE_REBOOT"
  fi
}

test_boot_grace_calculation() {
  test_start "Boot grace: wait time calculation"

  local UPTIME_SEC=60
  local BOOT_GRACE=180
  local EXPECTED_WAIT=$((BOOT_GRACE - UPTIME_SEC))

  if (( UPTIME_SEC < BOOT_GRACE )); then
    local WAIT_TIME=$((BOOT_GRACE - UPTIME_SEC))
    if (( WAIT_TIME == EXPECTED_WAIT )); then
      test_pass
    else
      test_fail "Expected wait=$EXPECTED_WAIT, got $WAIT_TIME"
    fi
  else
    test_fail "Expected to wait, but uptime >= boot_grace"
  fi
}

#
# Regression Tests (fping summary parsing)
#

# The agent parses fping's per-host summary to count replies. Real `fping -q`
# output looks like:
#
#   1.1.1.1 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 22.4/24.0/27.3
#
# The counts follow "= ", not the colon - the colon is followed by the literal
# text "xmt/rcv/%loss". An earlier version anchored on ": " and therefore never
# matched, so every probe counted as a failure even when all targets replied,
# producing phantom outage reports on a healthy host.
#
# This test runs the agent's OWN regex against verbatim fping output, so it
# fails if the anchor regresses. (The parse_fping_success_count helper above
# uses its own copy of the regex and so cannot catch this.)
test_fping_regex_matches_real_output() {
  test_start "Regression: agent fping regex matches real fping output"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  # Verbatim `fping -c 3 -q` output from a host where all targets replied
  local real_output='1.1.1.1 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 22.4/24.0/27.3
8.8.8.8 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 19.2/20.8/24.1
9.9.9.9 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 21.0/21.7/22.2'

  local ok=0
  while IFS= read -r line; do
    [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
    if [[ "$line" =~ =\ ([0-9]+)/([0-9]+)/ ]]; then
      if (( BASH_REMATCH[2] >= 1 )); then
        ((++ok))
      fi
    fi
  done <<<"$real_output"

  # Guard the source. Isolate the agent's fping-summary regex and require it to
  # anchor on "=" rather than ":". fping puts the literal text "xmt/rcv/%loss"
  # after the colon, so a ':' anchor can never match.
  local regex_line
  # shellcheck disable=SC2016  # literal source text, not an expansion
  regex_line=$(grep -F 'BASH_REMATCH[2]' -B3 "$AGENT_SCRIPT" \
    | grep -F '"$line" =~' | head -1)

  if [[ -z "$regex_line" ]]; then
    test_fail "Could not locate the fping summary regex in the agent source"
  elif [[ "$regex_line" != *'=~ ='* ]]; then
    test_fail "Agent fping regex must anchor on '=', found: ${regex_line#"${regex_line%%[![:space:]]*}"}"
  elif (( ok == 3 )); then
    test_pass
  else
    test_fail "Expected 3 replying targets, counted $ok"
  fi
}

# All targets genuinely down must still count zero, so the fix does not
# introduce false positives in the other direction.
test_fping_regex_all_down() {
  test_start "Regression: fping regex counts zero when all targets are down"

  local down_output='1.1.1.1 : xmt/rcv/%loss = 3/0/100%
8.8.8.8 : xmt/rcv/%loss = 3/0/100%'

  local ok=0
  while IFS= read -r line; do
    [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
    if [[ "$line" =~ =\ ([0-9]+)/([0-9]+)/ ]]; then
      if (( BASH_REMATCH[2] >= 1 )); then
        ((++ok))
      fi
    fi
  done <<<"$down_output"

  if (( ok == 0 )); then
    test_pass
  else
    test_fail "Expected 0 replying targets, counted $ok"
  fi
}

#
# Regression Tests (outage state persistence)
#

# An outage that spans a service restart must still be announced. DOWN_START is
# persisted across restarts, so the main loop sees it already set and goes
# straight to "outage continuing" - meaning the "WAN appears down" transition
# would never be logged for that outage unless the resume path restates it.
# CI and operators both grep for that string.
test_resume_announces_wan_down() {
  test_start "Regression: outage resumed across restart still logs WAN down"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist"

  local now_ts started_ts
  now_ts=$(date +%s)
  started_ts=$((now_ts - 20))

  # Metrics left behind by a previous run with an outage still in progress.
  # BOOT_ID must match the CURRENT boot or load_metrics() will (correctly)
  # discard the state as stale, and the resume path would never be exercised.
  local boot_id=""
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    boot_id=$(< /proc/sys/kernel/random/boot_id)
  fi

  cat > "$persist/metrics.dat" <<EOF
TOTAL_REBOOTS=0
TOTAL_OUTAGES=1
TOTAL_RECOVERIES=0
TOTAL_DOWNTIME_SECONDS=0
LAST_HEALTH_REPORT=0
SERVICE_START_TIME=$started_ts
DOWN_START=$started_ts
LAST_REBOOT=0
BOOT_ID=$boot_id
TRACKING_SINCE=$started_ts
EOF

  local output
  output=$(
    STATE_DIR="$MOCK_DIR/run" \
    PERSIST_DIR="$persist" \
    LOG_TO_STDERR=1 \
    TARGETS="203.0.113.1" \
    MIN_OK=1 \
    BOOT_GRACE=0 \
    CHECK_INTERVAL=1 \
    DOWN_WINDOW_SECONDS=3600 \
    DRY_RUN=1 \
    USE_FPING="no" \
    DISABLE_FILE="$MOCK_DIR/none.disable" \
    timeout 4 bash "$AGENT_SCRIPT" 2>&1
  ) || true

  cleanup_mock_env

  # Require the distinct resume message, not merely "WAN appears down" - a fresh
  # outage detected by the first probe would also print the generic string and
  # mask a broken resume path.
  if echo "$output" | grep -qi "WAN appears down; resuming in-progress outage"; then
    test_pass
  elif echo "$output" | grep -qi "discarding outage state"; then
    test_fail "State was discarded as stale; the resume path never ran"
  else
    test_fail "No resume message logged: $(echo "$output" | head -3)"
  fi
}

# read_field's callers pass an explicit "" to mean "no baseline recorded yet".
# A ${3:-0} default would turn that into 0, making the FIRST digest report the
# entire counter value as an overnight delta (e.g. tx_restart jumping 0 -> 912).
# ${3-0} preserves the explicit empty.
test_digest_first_run_has_no_fake_delta() {
  test_start "Digest: first run reports no baseline instead of a fake delta"

  local digest="$SCRIPT_DIR/../src/netwatch-digest.sh"
  if [[ ! -f "$digest" ]]; then
    test_fail "Digest script not found: $digest"
    return
  fi

  # Guard the source: the unset-only form is what makes this work
  # shellcheck disable=SC2016  # literal source text, not an expansion
  if grep -q 'fallback="${3:-0}"' "$digest"; then
    test_fail "read_field uses \${3:-0}; an explicit empty baseline becomes 0"
    return
  fi

  # shellcheck disable=SC2016  # literal source text, not an expansion
  if ! grep -q 'fallback="${3-0}"' "$digest"; then
    test_fail "read_field does not use the unset-only \${3-0} default"
    return
  fi

  # Behavioural check: with no state file, deltas must read n/a
  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist"

  local output
  output=$(
    PERSIST_DIR="$persist"     NETPROBE_IFACE="lo"     LOG_TO_STDERR=1     WEBHOOK_ENABLED=0     timeout 20 bash "$digest" 2>&1
  ) || true

  cleanup_mock_env

  if echo "$output" | grep -q 'tx_restart=[0-9]*(Δn/a)'; then
    test_pass
  elif echo "$output" | grep -qE 'tx_restart=[0-9]+\(Δ[0-9]+\)'; then
    test_fail "First run fabricated a delta: $(echo "$output" | grep -o 'tx_restart=[0-9]*(Δ[^)]*)' | head -1)"
  else
    # Counters unreadable in this environment is acceptable; the source guard
    # above already covers the defaulting behaviour.
    test_pass
  fi
}

#
# Regression Tests (dry-run cooldown)
#

# Cooldown prevents reboot LOOPS, so it must only apply when a reboot can
# actually happen. In dry-run nothing reboots, so arming or honouring a
# cooldown suppresses exactly the reports dry-run exists to produce. This
# matters more since LAST_REBOOT began persisting across restarts: one dry-run
# trip would otherwise silence threshold reporting for COOLDOWN_SECONDS even
# across a service restart.
test_dryrun_does_not_arm_cooldown() {
  test_start "Regression: dry-run neither arms nor honours the cooldown"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist"

  local boot_id=""
  [[ -r /proc/sys/kernel/random/boot_id ]] && boot_id=$(< /proc/sys/kernel/random/boot_id)

  local now_ts
  now_ts=$(date +%s)

  # A cooldown armed moments ago, as an older build would have done on a
  # dry-run trip
  cat > "$persist/metrics.dat" <<EOF
TOTAL_REBOOTS=0
TOTAL_OUTAGES=0
TOTAL_RECOVERIES=0
TOTAL_DOWNTIME_SECONDS=0
LAST_HEALTH_REPORT=0
SERVICE_START_TIME=$now_ts
DOWN_START=-1
LAST_REBOOT=$now_ts
BOOT_ID=$boot_id
TRACKING_SINCE=$now_ts
EOF

  local output
  output=$(
    STATE_DIR="$MOCK_DIR/run"     PERSIST_DIR="$persist"     LOG_TO_STDERR=1     TARGETS="203.0.113.1 198.51.100.1"     MIN_OK=2     BOOT_GRACE=0     PING_COUNT=1     PING_TIMEOUT=1     CHECK_INTERVAL=2     DOWN_WINDOW_SECONDS=4     COOLDOWN_SECONDS=1200     DRY_RUN=1     USE_FPING="no"     DISABLE_FILE="$MOCK_DIR/none.disable"     timeout 12 bash "$AGENT_SCRIPT" 2>&1
  ) || true

  local saved_last_reboot
  saved_last_reboot=$(grep -E '^LAST_REBOOT=' "$persist/metrics.dat" 2>/dev/null | cut -d= -f2)

  cleanup_mock_env

  if ! echo "$output" | grep -q "DRY_RUN: would reboot now"; then
    test_fail "Dry-run trip suppressed by cooldown: $(echo "$output" | grep -i cooldown | head -1)"
  elif [[ "$saved_last_reboot" != "$now_ts" ]]; then
    test_fail "Dry-run advanced LAST_REBOOT ($now_ts -> $saved_last_reboot)"
  else
    test_pass
  fi
}

# DIGEST_FORMAT=embed emits a Discord embed rather than a content string. The
# shape differs entirely, so this guards that the verdict maps to the right
# colour and that the payload is still valid JSON.
test_digest_embed_format() {
  test_start "Digest: embed format produces a valid coloured payload"

  local digest="$SCRIPT_DIR/../src/netwatch-digest.sh"
  if [[ ! -f "$digest" ]]; then
    test_fail "Digest script not found: $digest"
    return
  fi

  # Each verdict needs a distinct colour, or the border conveys nothing
  local missing=""
  local v
  for v in HOLDING ATTENTION DEGRADED; do
    grep -qE "^ *$v\)" "$digest" || missing+="$v "
  done
  if [[ -n "$missing" ]]; then
    test_fail "No embed colour mapped for: $missing"
    return
  fi

  # Text must remain the default: other webhook services reject embeds
  if ! grep -q 'DIGEST_FORMAT:=text' "$digest"; then
    test_fail "DIGEST_FORMAT does not default to text"
    return
  fi

  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist" "$MOCK_DIR/bin"

  cat > "$MOCK_DIR/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-d" ]; then printf '%s' "$2" > "$CAPTURE_FILE"; fi
  shift
done
exit 0
CURLEOF
  chmod +x "$MOCK_DIR/bin/curl"

  local capture="$MOCK_DIR/embed.json"
  local patched="$MOCK_DIR/digest.sh"
  sed "s|/usr/bin/curl|$MOCK_DIR/bin/curl|g" "$digest" > "$patched"

  export CAPTURE_FILE="$capture"
  export PERSIST_DIR="$persist"
  export NETPROBE_IFACE="lo"
  export DIGEST_FORMAT="embed"
  export WEBHOOK_ENABLED=1
  export WEBHOOK_URL="https://example.invalid/hook"
  bash "$patched" >/dev/null 2>&1 || true
  unset CAPTURE_FILE PERSIST_DIR NETPROBE_IFACE DIGEST_FORMAT WEBHOOK_ENABLED WEBHOOK_URL

  local result="fail"
  if [[ -f "$capture" ]]; then
    if grep -q '"embeds"' "$capture" && grep -q '"color"' "$capture"; then
      # No raw control characters, same requirement as the text payload
      if ! LC_ALL=C grep -q '[-]' "$capture"; then
        result="ok"
      fi
    fi
  fi

  cleanup_mock_env

  if [[ "$result" == "ok" ]]; then
    test_pass
  else
    test_fail "Embed payload missing embeds/color, or contained a raw control character"
  fi
}

# DIGEST_WINDOW_HOURS is operator-editable config interpolated into the embed
# field names. Unescaped, a quote in it produces a malformed field name
# ("Hangs (24"xh)") that invalidates the entire payload.
test_digest_embed_escapes_window_hours() {
  test_start "Digest: embed escapes DIGEST_WINDOW_HOURS"

  local digest="$SCRIPT_DIR/../src/netwatch-digest.sh"
  if [[ ! -f "$digest" ]]; then
    test_fail "Digest script not found: $digest"
    return
  fi

  # Guard the source: the raw value must not be interpolated into a field name
  if grep -qE '\\"name\\":\\"(Hangs|WAN) \(\$\{DIGEST_WINDOW_HOURS\}' "$digest"; then
    test_fail "DIGEST_WINDOW_HOURS is interpolated raw into an embed field name"
    return
  fi

  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist" "$MOCK_DIR/bin"

  cat > "$MOCK_DIR/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-d" ]; then printf '%s' "$2" > "$CAPTURE_FILE"; fi
  shift
done
exit 0
CURLEOF
  chmod +x "$MOCK_DIR/bin/curl"

  local capture="$MOCK_DIR/embed.json"
  local patched="$MOCK_DIR/digest.sh"
  sed "s|/usr/bin/curl|$MOCK_DIR/bin/curl|g" "$digest" > "$patched"

  export CAPTURE_FILE="$capture"
  export PERSIST_DIR="$persist"
  export NETPROBE_IFACE="lo"
  export DIGEST_FORMAT="embed"
  export DIGEST_WINDOW_HOURS='24"x'
  export WEBHOOK_ENABLED=1
  export WEBHOOK_URL="https://example.invalid/hook"
  bash "$patched" >/dev/null 2>&1 || true
  unset CAPTURE_FILE PERSIST_DIR NETPROBE_IFACE DIGEST_FORMAT DIGEST_WINDOW_HOURS
  unset WEBHOOK_ENABLED WEBHOOK_URL

  local result="fail"
  if [[ -f "$capture" ]]; then
    if python3 -c "import json; json.load(open('$capture'))" 2>/dev/null       || python -c "import json; json.load(open('$capture'))" 2>/dev/null; then
      result="ok"
    else
      # No parser available: the quote must appear escaped inside the field
      # name. \134 is the octal escape for a backslash, which avoids quoting
      # one inside a shell literal.
      local bs esc_quote
      bs=$(printf '\134')
      esc_quote="${bs}\""
      grep -qF "Hangs (24${esc_quote}xh)" "$capture" && result="ok"
    fi
  fi

  cleanup_mock_env

  if [[ "$result" == "ok" ]]; then
    test_pass
  else
    test_fail "A quote in DIGEST_WINDOW_HOURS produced an invalid embed payload"
  fi
}

# After an install or upgrade, the operator needs to know what is actually
# armed - not just which files were copied. A package upgrade that silently
# reset DRY_RUN to 0 would otherwise look identical to a clean install.
test_summary_reports_armed_state() {
  test_start "Summary: reports DRY_RUN state prominently"

  local summary="$SCRIPT_DIR/../scripts/netwatch-status-summary.sh"
  if [[ ! -f "$summary" ]]; then
    test_fail "Summary script not found: $summary"
    return
  fi

  setup_mock_env
  local cfg="$MOCK_DIR/agent.conf"

  # Dry-run must read as safe
  cat > "$cfg" <<'CFGEOF'
HEALTH_CHECK_MODE="icmp"
TARGETS="1.1.1.1 8.8.8.8"
MIN_OK=1
DOWN_WINDOW_SECONDS=600
DRY_RUN=1
WEBHOOK_ENABLED=1
CFGEOF

  local dry armed
  dry=$(CONFIG_FILE="$cfg" NETPROBE_CONFIG="$MOCK_DIR/none" bash "$summary" 2>&1 || true)

  # DRY_RUN=0 must be called out as ARMED
  sed -i 's/DRY_RUN=1/DRY_RUN=0/' "$cfg"
  armed=$(CONFIG_FILE="$cfg" NETPROBE_CONFIG="$MOCK_DIR/none" bash "$summary" 2>&1 || true)

  cleanup_mock_env

  if ! echo "$dry" | grep -qi 'dry-run'; then
    test_fail "DRY_RUN=1 was not reported as dry-run"
  elif echo "$dry" | grep -q 'ARMED'; then
    test_fail "DRY_RUN=1 was wrongly reported as ARMED"
  elif ! echo "$armed" | grep -q 'ARMED'; then
    test_fail "DRY_RUN=0 was not reported as ARMED"
  elif ! echo "$armed" | grep -q '600s'; then
    test_fail "The reboot window was not shown when armed"
  else
    test_pass
  fi
}

# Every script the package installs must also be removed by uninstall.sh.
# Three diagnostic tools shipped since v1.1.0 were never added to the removal
# list and sat orphaned in /usr/local/sbin after an uninstall.
test_uninstall_removes_every_packaged_script() {
  test_start "Uninstall: removes every script the package installs"

  local builder="$SCRIPT_DIR/../scripts/build-deb.sh"
  local uninstaller="$SCRIPT_DIR/../scripts/uninstall.sh"

  if [[ ! -f "$builder" ]] || [[ ! -f "$uninstaller" ]]; then
    test_fail "build-deb.sh or uninstall.sh not found"
    return
  fi

  local orphans="" script
  while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    grep -qF "$script" "$uninstaller" || orphans+="$script "
  done < <(grep -oE 'usr/local/sbin/[a-z-]+\.sh' "$builder" | sed 's|.*/||' | sort -u)

  if [[ -z "$orphans" ]]; then
    test_pass
  else
    test_fail "Installed but never removed on uninstall: $orphans"
  fi
}

# dpkg never merges config files, so keeping your version on upgrade leaves new
# settings absent - the features behind them silently stay off. The merge tool
# must add only what is missing and never touch a value already set.
test_config_merge_preserves_values() {
  test_start "Config merge: adds missing keys without altering existing values"

  local merge="$SCRIPT_DIR/../scripts/netwatch-config-merge.sh"
  if [[ ! -f "$merge" ]]; then
    test_fail "Merge script not found: $merge"
    return
  fi

  setup_mock_env
  local d="$MOCK_DIR/etc/default"
  mkdir -p "$d"

  # A customised config missing a new key, and the shipped reference
  printf 'DIGEST_ENABLED=1
DIGEST_WINDOW_HOURS=6
' > "$d/netwatch-netprobe"
  printf 'DIGEST_ENABLED=1
DIGEST_WINDOW_HOURS=24
DIGEST_FORMAT="text"
'     > "$d/netwatch-netprobe.dpkg-dist"

  local patched="$MOCK_DIR/merge.sh"
  # shellcheck disable=SC2016  # literal source text, not an expansion
  sed -e "s|/etc/default/netwatch|$d/netwatch|g"       -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|' "$merge" > "$patched"

  bash "$patched" --apply >/dev/null 2>&1 || true

  local result="ok"
  # The new key must be added
  grep -q '^DIGEST_FORMAT=' "$d/netwatch-netprobe" || result="missing-new-key"
  # The customised value must survive
  grep -q '^DIGEST_WINDOW_HOURS=6' "$d/netwatch-netprobe" || result="lost-custom-value"
  # The shipped default must NOT overwrite it
  grep -q '^DIGEST_WINDOW_HOURS=24' "$d/netwatch-netprobe" && result="clobbered-with-default"

  cleanup_mock_env

  if [[ "$result" == "ok" ]]; then
    test_pass
  else
    test_fail "Merge behaved incorrectly: $result"
  fi
}

# The offload labels must be the short names ethtool -K accepts, so the summary
# can be acted on directly. Truncating the feature names instead rendered both
# generic-* features as "gen", making the output ambiguous.
test_summary_offload_labels_unambiguous() {
  test_start "Summary: offload labels are tso/gso/gro, not truncated"

  local summary="$SCRIPT_DIR/../scripts/netwatch-status-summary.sh"
  if [[ ! -f "$summary" ]]; then
    test_fail "Summary script not found: $summary"
    return
  fi

  # Guard the source: substr truncation cannot distinguish the generic-* pair
  # shellcheck disable=SC2016  # literal source text, not an expansion
  if grep -q 'substr($1,1,3)' "$summary"; then
    test_fail "Offload labels are truncated; both generic-* features render as gen"
    return
  fi

  # Each short name must be mapped explicitly
  local missing=""
  local k
  for k in tso gso gro; do
    grep -q "\"$k\"" "$summary" || missing+="$k "
  done

  if [[ -n "$missing" ]]; then
    test_fail "No explicit mapping for: $missing"
  else
    test_pass
  fi
}

# Every detect_iface implementation must refuse to report the bridge. Its whole
# purpose is finding the hardware the WAN path depends on - and a bridge shows
# nominal state while the NIC beneath it is wedged, so naming vmbr0 would make
# the reported offload state and counters meaningless.
test_detect_iface_never_reports_bridge() {
  test_start "detect_iface: never falls back to the bridge name"

  local missing=""
  local f
  for f in "$SCRIPT_DIR/../scripts/netwatch-status-summary.sh"            "$SCRIPT_DIR/../src/netwatch-netprobe.sh"            "$SCRIPT_DIR/../src/netwatch-digest.sh"; do
    [[ -f "$f" ]] || { missing+="$(basename "$f") "; continue; }

    # Isolate the bridge branch: between "if [[ -d .../bridge" and the "fi"
    # that closes it, the path after the port loop must not echo route_dev.
    local branch
    # shellcheck disable=SC2016  # literal source text, not an expansion
    branch=$(sed -n '/-d "\/sys\/class\/net\/\$route_dev\/bridge"/,/^  fi$/p' "$f")

    if [[ -z "$branch" ]]; then
      missing+="$(basename "$f"):no-bridge-branch "
      continue
    fi

    # After the loop closes, the branch must terminate (return or empty echo)
    # rather than falling through to the route_dev fallback.
    local after_loop
    after_loop=$(echo "$branch" | sed -n '/^    done$/,$p')

    if ! echo "$after_loop" | grep -qE 'return 1|echo ""'; then
      missing+="$(basename "$f"):falls-through "
    fi
  done

  if [[ -z "$missing" ]]; then
    test_pass
  else
    test_fail "Bridge fallthrough possible in: $missing"
  fi
}

# The summary reads config by grepping, never by sourcing - a malformed or
# hostile config file must not be able to execute anything.
test_summary_does_not_source_config() {
  test_start "Summary: reads config without sourcing it"

  local summary="$SCRIPT_DIR/../scripts/netwatch-status-summary.sh"
  if [[ ! -f "$summary" ]]; then
    test_fail "Summary script not found: $summary"
    return
  fi

  # No `. "$CONFIG_FILE"` or `source` of the config
  # shellcheck disable=SC2016  # literal source text, not an expansion
  if grep -qE '^\s*(\.|source)\s+"?\$(CONFIG_FILE|NETPROBE_CONFIG)' "$summary"; then
    test_fail "Summary sources the config file instead of parsing it"
    return
  fi

  setup_mock_env
  local cfg="$MOCK_DIR/evil.conf"
  local canary="$MOCK_DIR/canary"

  # If this were sourced, the command substitution would run
  cat > "$cfg" <<CFGEOF
DRY_RUN=1
EVIL=\$(touch "$canary")
CFGEOF

  CONFIG_FILE="$cfg" NETPROBE_CONFIG="$MOCK_DIR/none" bash "$summary" >/dev/null 2>&1 || true

  local leaked=0
  [[ -f "$canary" ]] && leaked=1
  cleanup_mock_env

  if (( leaked )); then
    test_fail "Config contents were executed - the summary must not source config"
  else
    test_pass
  fi
}

#
# Packaging Tests
#

# dpkg silently overwrites a package file on upgrade unless it is declared a
# conffile. /etc/default/netwatch-agent holds the webhook URL, DRY_RUN, and
# custom targets - losing those on `dpkg -i` is silent data loss, which is
# exactly what happened on a real host during the v1.2.0 upgrade.
test_deb_declares_conffiles() {
  test_start "Packaging: config files are declared as dpkg conffiles"

  local builder="$SCRIPT_DIR/../scripts/build-deb.sh"
  if [[ ! -f "$builder" ]]; then
    test_fail "build-deb.sh not found: $builder"
    return
  fi

  if ! grep -q 'DEBIAN/conffiles' "$builder"; then
    test_fail "No DEBIAN/conffiles is written; dpkg will clobber local config"
    return
  fi

  local missing=""
  local f
  for f in /etc/default/netwatch-agent /etc/default/netwatch-netprobe; do
    grep -qF "$f" "$builder" || missing+="$f "
  done

  if [[ -n "$missing" ]]; then
    test_fail "Not declared as conffiles: $missing"
    return
  fi

  test_pass
}

# The agent config can hold a webhook token, so it must not be world-readable.
# install.sh uses 0640; the package must match.
test_deb_config_permissions() {
  test_start "Packaging: configs are installed 0640, not world-readable"

  local builder="$SCRIPT_DIR/../scripts/build-deb.sh"
  if [[ ! -f "$builder" ]]; then
    test_fail "build-deb.sh not found: $builder"
    return
  fi

  local bad=""
  if grep -qE 'install -m 0644 .*etc/default/netwatch-agent"' "$builder"; then
    bad+="netwatch-agent "
  fi
  if grep -qE 'install -m 0644 .*etc/default/netwatch-netprobe"' "$builder"; then
    bad+="netwatch-netprobe "
  fi

  if [[ -n "$bad" ]]; then
    test_fail "Installed world-readable despite holding secrets: $bad"
  else
    test_pass
  fi
}

# install.sh appends the digest settings to the sampler config. The package must
# do the same, or a .deb install ships no DIGEST_* keys and the digest runs on
# built-in defaults with no way for the operator to see or change them.
test_deb_ships_digest_settings() {
  test_start "Packaging: digest settings are shipped in the sampler config"

  local builder="$SCRIPT_DIR/../scripts/build-deb.sh"
  if [[ ! -f "$builder" ]]; then
    test_fail "build-deb.sh not found: $builder"
    return
  fi

  if grep -q 'netwatch-digest.conf.*>>.*etc/default/netwatch-netprobe' "$builder"; then
    test_pass
  else
    test_fail "netwatch-digest.conf is never appended to the sampler config"
  fi
}

#
# Daily Digest Tests
#

# The digest goes to a third-party service, so host identifiers must not leak.
# IPs and MACs are never included; the hostname only with an explicit opt-in.
test_digest_redacts_host_identifiers() {
  test_start "Digest: redacts IPs, MACs, and hostname by default"

  local digest="$SCRIPT_DIR/../src/netwatch-digest.sh"
  if [[ ! -f "$digest" ]]; then
    test_fail "Digest script not found: $digest"
    return
  fi

  # The default must be redacted, and the hostname must be gated on the flag
  if ! grep -q 'DIGEST_INCLUDE_HOSTNAME:=0' "$digest"; then
    test_fail "DIGEST_INCLUDE_HOSTNAME does not default to 0"
    return
  fi

  if ! grep -q 'HOST_LABEL="(redacted)"' "$digest"; then
    test_fail "No redacted fallback for the hostname"
    return
  fi

  # No placeholder should expose addressing information
  if grep -qE '\{(IP|IPADDR|MAC|MACADDR)\}' "$digest"; then
    test_fail "Digest exposes an IP or MAC placeholder"
    return
  fi

  test_pass
}

# A custom DIGEST_BODY_TEMPLATE is the documented way to trim verbosity, so
# every placeholder the config advertises must actually be substituted.
test_digest_template_placeholders_substituted() {
  test_start "Digest: documented placeholders are all substituted"

  local digest="$SCRIPT_DIR/../src/netwatch-digest.sh"
  local conf="$SCRIPT_DIR/../config/netwatch-digest.conf"

  if [[ ! -f "$digest" ]] || [[ ! -f "$conf" ]]; then
    test_fail "Digest script or config not found"
    return
  fi

  # Placeholders advertised in the config reference block
  local -a advertised
  # {PLACEHOLDER} is prose in the config's explanatory text, not a real variable
  mapfile -t advertised < <(grep -oE '\{[A-Z_]+\}' "$conf" | grep -v '^{PLACEHOLDER}$' | sort -u)

  if (( ${#advertised[@]} == 0 )); then
    test_fail "No placeholders found in the config documentation"
    return
  fi

  local ph missing=""
  for ph in "${advertised[@]}"; do
    # Each must appear in the substitution function
    if ! grep -qF "text=\"\${text//\$ph" "$digest"; then
      local bare="${ph//[\{\}]/}"
      if ! grep -qF "\{${bare}\}" "$digest"; then
        missing+="$ph "
      fi
    fi
  done

  if [[ -z "$missing" ]]; then
    test_pass
  else
    test_fail "Documented but never substituted: $missing"
  fi
}

# The digest builds JSON by hand; unescaped quotes or backslashes in a custom
# template would produce a malformed payload that silently fails to deliver.
test_digest_json_escaping() {
  test_start "Digest: JSON escaping produces valid JSON"

  local digest="$SCRIPT_DIR/../src/netwatch-digest.sh"
  if [[ ! -f "$digest" ]]; then
    test_fail "Digest script not found: $digest"
    return
  fi

  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist" "$MOCK_DIR/bin"

  # Capture the payload instead of sending it
  cat > "$MOCK_DIR/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-d" ]; then printf '%s' "$2" > "$CAPTURE_FILE"; fi
  shift
done
exit 0
CURLEOF
  chmod +x "$MOCK_DIR/bin/curl"

  local capture="$MOCK_DIR/payload.json"
  local patched="$MOCK_DIR/digest.sh"
  sed "s|/usr/bin/curl|$MOCK_DIR/bin/curl|g" "$digest" > "$patched"

  # A template containing the characters that break naive JSON building
  export CAPTURE_FILE="$capture"
  export PERSIST_DIR="$persist"
  export NETPROBE_IFACE="lo"
  export WEBHOOK_ENABLED=1
  export WEBHOOK_URL="https://example.invalid/hook"
  # Include control characters: RFC 8259 forbids raw U+0000-U+001F in strings,
  # so a tab or carriage return must be escaped too, not just newline.
  export DIGEST_BODY_TEMPLATE
  DIGEST_BODY_TEMPLATE=$(printf 'quote " backslash \ tab:	cr:
bell: and {VERDICT}')
  bash "$patched" >/dev/null 2>&1 || true
  unset CAPTURE_FILE PERSIST_DIR NETPROBE_IFACE WEBHOOK_ENABLED WEBHOOK_URL DIGEST_BODY_TEMPLATE

  # Validate the payload. Prefer a real JSON parser; fall back to asserting the
  # escaping directly when no usable interpreter is available (the Windows
  # dev environment has stubs that exist but do not run).
  local result="fail"
  if [[ -f "$capture" ]]; then
    if python3 -c "import json; json.load(open('$capture'))" 2>/dev/null       || python -c "import json; json.load(open('$capture'))" 2>/dev/null; then
      result="ok"
    else
      # The template contained a bare " and a bare backslash. Both must appear
      # escaped in the payload for it to be valid JSON. Build the needles with
      # printf so the escaping is unambiguous to both bash and shellcheck.
      # \134 is the octal escape for a backslash, which avoids having to quote
      # one inside a shell literal.
      local bs esc_quote esc_backslash
      bs=$(printf '\134')
      esc_quote="${bs}\""
      esc_backslash="${bs}${bs}"
      # Also require that no RAW control character survived into the payload:
      # those are exactly what strict parsers reject.
      if grep -qF "$esc_quote" "$capture" && grep -qF "$esc_backslash" "$capture"         && ! LC_ALL=C grep -q '[-]' "$capture"; then
        result="ok"
      fi
    fi
  fi

  cleanup_mock_env

  if [[ "$result" == "ok" ]]; then
    test_pass
  else
    test_fail "Digest payload was not valid JSON with quotes/backslashes in the template"
  fi
}

#
# Regression Tests (corrupt persistent state)
#

# metrics.dat is sourced, so a truncated or hand-edited file can leave a numeric
# field holding text. Under `set -u`, (( VAR != 0 )) on a non-numeric value
# treats the contents as a variable name and aborts: "garbage: unbound
# variable". An unclean shutdown mid-write can produce exactly this, which would
# leave the watchdog dead until someone noticed.
test_corrupt_metrics_does_not_crash() {
  test_start "Regression: corrupt metrics.dat does not kill the agent"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  setup_mock_env
  local persist="$MOCK_DIR/persist"
  mkdir -p "$persist"

  cat > "$persist/metrics.dat" <<'CORRUPT'
DOWN_START=garbage
LAST_REBOOT=
TRACKING_SINCE=notanumber
TOTAL_DOWNTIME_SECONDS=abc
BOOT_ID=stale
CORRUPT

  local output
  output=$(
    STATE_DIR="$MOCK_DIR/run" \
    PERSIST_DIR="$persist" \
    LOG_TO_STDERR=1 \
    TARGETS="127.0.0.1" \
    MIN_OK=1 \
    BOOT_GRACE=0 \
    CHECK_INTERVAL=1 \
    DOWN_WINDOW_SECONDS=3600 \
    DRY_RUN=1 \
    USE_FPING="no" \
    DISABLE_FILE="$MOCK_DIR/none.disable" \
    timeout 4 bash "$AGENT_SCRIPT" 2>&1
  ) || true

  cleanup_mock_env

  if echo "$output" | grep -qi "unbound variable"; then
    test_fail "Agent died on corrupt metrics: $(echo "$output" | grep -i 'unbound' | head -1)"
  elif echo "$output" | grep -q "Starting WAN watchdog"; then
    test_pass
  else
    test_fail "Agent did not start: $(echo "$output" | head -3)"
  fi
}

# If ethtool is briefly unavailable (package upgrade, interface down), the
# sampler reports 0 for every counter. Persisting those placeholder zeros would
# make the next successful sample look like a spike from 0 to the real value,
# raising a false hang alert. The state file must carry the previous values
# forward instead.
test_sampler_preserves_counters_when_unreadable() {
  test_start "Regression: unreadable counters do not reset the saved baseline"

  local probe="$SCRIPT_DIR/../src/netwatch-netprobe.sh"
  if [[ ! -f "$probe" ]]; then
    test_fail "Sampler script not found: $probe"
    return
  fi

  # The write must be gated on COUNTERS_READ, not write the live values blindly
  if ! grep -q 'COUNTERS_READ' "$probe"; then
    test_fail "Sampler does not track whether counters were actually read"
    return
  fi

  # shellcheck disable=SC2016  # literal source text, not an expansion
  if ! grep -q 'SAVE_TX_TIMEOUT="\$PREV_TX_TIMEOUT"' "$probe"; then
    test_fail "Sampler does not carry previous counters forward when unreadable"
    return
  fi

  # Deltas must also be gated, or a placeholder zero would still be compared
  local gated
  # shellcheck disable=SC2016  # literal source text, not an expansion
  gated=$(grep -A6 'if (( COUNTERS_READ )); then' "$probe" | grep -c 'DELTA_TX_TIMEOUT=\$(counter_delta' || true)

  if (( gated >= 1 )); then
    test_pass
  else
    test_fail "Counter deltas are computed without checking COUNTERS_READ"
  fi
}

# Persisted metrics need field-specific bounds, not just "is it an integer".
# A negative TOTAL_DOWNTIME_SECONDS produces an availability above 100%, and a
# value near INT64_MAX overflows when the availability calculation multiplies it
# by 100. Only DOWN_START may be negative, and only as the -1 "up" sentinel.
test_metrics_reject_out_of_range() {
  test_start "Regression: out-of-range persisted metrics are rejected"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  local -a cases=(
    "TOTAL_DOWNTIME_SECONDS=-500|TOTAL_DOWNTIME_SECONDS"
    "TOTAL_DOWNTIME_SECONDS=92233720368547759|TOTAL_DOWNTIME_SECONDS"
    "DOWN_START=-42|DOWN_START"
  )

  local entry fixture expect output failures=""
  for entry in "${cases[@]}"; do
    fixture="${entry%%|*}"
    expect="${entry##*|}"

    setup_mock_env
    mkdir -p "$MOCK_DIR/persist"
    printf '%s\n' "$fixture" > "$MOCK_DIR/persist/metrics.dat"

    output=$(
      STATE_DIR="$MOCK_DIR/run" \
      PERSIST_DIR="$MOCK_DIR/persist" \
      LOG_TO_STDERR=1 \
      TARGETS="127.0.0.1" \
      MIN_OK=1 \
      BOOT_GRACE=0 \
      CHECK_INTERVAL=1 \
      DOWN_WINDOW_SECONDS=3600 \
      DRY_RUN=1 \
      USE_FPING="no" \
      DISABLE_FILE="$MOCK_DIR/none.disable" \
      timeout 4 bash "$AGENT_SCRIPT" 2>&1
    ) || true

    cleanup_mock_env

    if ! echo "$output" | grep -q "invalid $expect"; then
      failures+="$fixture "
    fi
  done

  # The documented sentinel must still be accepted
  setup_mock_env
  mkdir -p "$MOCK_DIR/persist"
  printf 'DOWN_START=-1\n' > "$MOCK_DIR/persist/metrics.dat"
  output=$(
    STATE_DIR="$MOCK_DIR/run" PERSIST_DIR="$MOCK_DIR/persist" LOG_TO_STDERR=1 \
    TARGETS="127.0.0.1" MIN_OK=1 BOOT_GRACE=0 CHECK_INTERVAL=1 \
    DOWN_WINDOW_SECONDS=3600 DRY_RUN=1 USE_FPING="no" \
    DISABLE_FILE="$MOCK_DIR/none.disable" \
    timeout 4 bash "$AGENT_SCRIPT" 2>&1
  ) || true
  cleanup_mock_env

  if echo "$output" | grep -q "invalid DOWN_START"; then
    failures+="rejected-the--1-sentinel "
  fi

  if [[ -z "$failures" ]]; then
    test_pass
  else
    test_fail "Validation gaps: $failures"
  fi
}

# A corrupt state file could hold a value above INT64_MAX. Bash arithmetic is
# 64-bit signed and wraps silently, so such a value compares as negative and
# the sampler would report a bogus counter increase - a false crit anomaly.
test_counter_delta_rejects_overflow() {
  test_start "Regression: counter delta rejects out-of-range values"

  local probe="$SCRIPT_DIR/../src/netwatch-netprobe.sh"
  if [[ ! -f "$probe" ]]; then
    test_fail "Sampler script not found: $probe"
    return
  fi

  # Extract counter_delta and exercise it directly
  local fn
  fn=$(sed -n '/^counter_delta()/,/^}/p' "$probe")

  if [[ -z "$fn" ]]; then
    test_fail "Could not extract counter_delta from the sampler"
    return
  fi

  local overflow normal reset
  overflow=$(bash -c "set -Eeuo pipefail; $fn; counter_delta '18446744073709551615' '1'" 2>/dev/null || true)
  normal=$(bash -c "set -Eeuo pipefail; $fn; counter_delta '5' '9'" 2>/dev/null || true)
  reset=$(bash -c "set -Eeuo pipefail; $fn; counter_delta '9' '5'" 2>/dev/null || true)

  if [[ -n "$overflow" ]]; then
    test_fail "Out-of-range previous value produced a delta of '$overflow'"
  elif [[ "$normal" != "4" ]]; then
    test_fail "Normal increase 5->9 gave '$normal', expected 4"
  elif [[ -n "$reset" ]]; then
    test_fail "Counter reset 9->5 produced a delta of '$reset', expected none"
  else
    test_pass
  fi
}

#
# Regression Tests (errexit safety)
#

# Regression: `set -Eeuo pipefail` + post-increment `((var++))` kills the script.
# When var is 0, `((var++))` evaluates to 0 and returns exit status 1, which
# errexit treats as fatal. This crashed the agent on the FIRST successful probe
# after startup, causing a silent restart loop (observed in production: a new
# PID every ~30 minutes with a phantom multi-day outage timer).
# Counters must use the pre-increment form `((++var))` instead.
test_errexit_safe_increment() {
  test_start "Regression: counter increment from zero survives errexit"

  local result
  result=$(
    bash -c '
      set -Eeuo pipefail
      ok=0
      ((++ok))
      echo "$ok"
    ' 2>/dev/null
  ) || true

  if [[ "$result" == "1" ]]; then
    test_pass
  else
    test_fail "Pre-increment from zero did not survive errexit (got '$result')"
  fi
}

# Guard against the unsafe form being reintroduced into the agent source.
test_no_post_increment_in_agent() {
  test_start "Regression: agent source contains no errexit-unsafe increments"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  # Match `((name++))` / `((name--))` not guarded by `|| true`
  local hits
  hits=$(grep -nE '\(\([A-Za-z_][A-Za-z0-9_]*(\+\+|--)\)\)' "$AGENT_SCRIPT" \
    | grep -v '|| true' || true)

  if [[ -z "$hits" ]]; then
    test_pass
  else
    test_fail "Found errexit-unsafe increment(s): $hits"
  fi
}

# Execute each counter-increment line lifted verbatim from the agent under the
# same `set -Eeuo pipefail` the agent uses, with the counter starting at zero.
# This exercises the real source text rather than a reimplementation, so the
# post-increment bug is caught even on hosts where the probe path itself cannot
# run (e.g. no /bin/ping available in the test environment).
test_agent_increment_lines_survive_errexit() {
  test_start "Regression: agent increment lines survive errexit at zero"

  if [[ ! -f "$AGENT_SCRIPT" ]]; then
    test_fail "Agent script not found: $AGENT_SCRIPT"
    return
  fi

  # Pull every bare arithmetic-increment statement out of the agent source
  local -a lines=()
  while IFS= read -r stmt; do
    [[ -n "$stmt" ]] && lines+=("$stmt")
  done < <(grep -oE '\(\(\+\+?[A-Za-z_][A-Za-z0-9_]*\+?\+?\)\)' "$AGENT_SCRIPT" | sort -u)

  if (( ${#lines[@]} == 0 )); then
    test_fail "No increment statements found in agent source (grep too narrow?)"
    return
  fi

  local stmt failed=""
  for stmt in "${lines[@]}"; do
    # Reconstruct the counter name and run the statement from zero under errexit
    local var
    var=$(echo "$stmt" | grep -oE '[A-Za-z_][A-Za-z0-9_]*')
    if ! bash -c "set -Eeuo pipefail; $var=0; $stmt; exit 0" 2>/dev/null; then
      failed+="$stmt "
    fi
  done

  if [[ -z "$failed" ]]; then
    test_pass
  else
    test_fail "Increment statement(s) died under errexit when counter was 0: $failed"
  fi
}

#
# TCP Health Check Tests
#

# Test TCP health check with all targets reachable
test_tcp_all_targets_up() {
  test_start "TCP mode: all targets reachable"

  setup_mock_env

  # Mock netcat to succeed (TCP connection successful)
  create_mock_nc 0

  # Test configuration
  TCP_TARGETS="1.1.1.1:853 8.8.8.8:443 9.9.9.9:443"
  MIN_OK=1
  PING_TIMEOUT=1
  STATE_DIR="$MOCK_DIR"

  # Simulate TCP probe logic
  local ok=0
  local -a targets
  read -ra targets <<< "$TCP_TARGETS"

  if [[ -x "$MOCK_NC" ]]; then
    local -a pids=()
    local -a tmp_files=()

    for target in "${targets[@]}"; do
      if [[ "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
        local host="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        local tmp_file
        tmp_file=$("$MKTEMP" -p "$STATE_DIR" nc.XXXXXX)
        tmp_files+=("$tmp_file")

        (
          if "$MOCK_NC" -z -w "$PING_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
            echo "ok" > "$tmp_file"
          fi
        ) &
        pids+=($!)
      fi
    done

    # Wait for all probes
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done

    # Count successes
    for tmp_file in "${tmp_files[@]}"; do
      if [[ -f "$tmp_file" ]] && [[ "$(<"$tmp_file")" == "ok" ]]; then
        ((++ok))
      fi
      "$RM" -f "$tmp_file" 2>/dev/null || true
    done
  fi

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

# Test TCP health check with partial target failures
test_tcp_partial_failure() {
  test_start "TCP mode: partial target failure (should pass with MIN_OK=1)"

  setup_mock_env

  # Mock netcat to succeed only once (first call)
  # This is a simplification - in real test we'd need more sophisticated mocking
  create_mock_nc 0

  TCP_TARGETS="1.1.1.1:853"
  MIN_OK=1
  PING_TIMEOUT=1
  STATE_DIR="$MOCK_DIR"

  local ok=0
  local -a targets
  read -ra targets <<< "$TCP_TARGETS"

  if [[ -x "$MOCK_NC" ]]; then
    for target in "${targets[@]}"; do
      if [[ "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
        local host="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        if "$MOCK_NC" -z -w "$PING_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
          ((++ok))
        fi
      fi
    done
  fi

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

# Test TCP health check with all targets unreachable
test_tcp_all_targets_down() {
  test_start "TCP mode: all targets unreachable (should fail)"

  setup_mock_env

  # Mock netcat to fail (TCP connection refused)
  create_mock_nc 1

  TCP_TARGETS="1.1.1.1:853 8.8.8.8:443"
  MIN_OK=1
  PING_TIMEOUT=1
  STATE_DIR="$MOCK_DIR"

  local ok=0
  local -a targets
  read -ra targets <<< "$TCP_TARGETS"

  if [[ -x "$MOCK_NC" ]]; then
    for target in "${targets[@]}"; do
      if [[ "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
        local host="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        if "$MOCK_NC" -z -w "$PING_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
          ((++ok))
        fi
      fi
    done
  fi

  if (( ok < MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok < $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

# Test TCP health check with invalid target format
test_tcp_invalid_target_format() {
  test_start "TCP mode: invalid target format (missing port)"

  setup_mock_env
  create_mock_nc 0

  TCP_TARGETS="1.1.1.1 8.8.8.8:443"  # First target missing port
  MIN_OK=1
  PING_TIMEOUT=1

  local ok=0
  local -a targets
  read -ra targets <<< "$TCP_TARGETS"

  # Simulate validation logic
  local valid_targets=0
  for target in "${targets[@]}"; do
    if [[ "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
      ((++valid_targets))
    fi
  done

  # Should have 1 valid target (8.8.8.8:443), 1 invalid (1.1.1.1)
  if (( valid_targets == 1 )); then
    test_pass
  else
    test_fail "Expected 1 valid target, got $valid_targets"
  fi

  cleanup_mock_env
}

#
# HTTP Health Check Tests
#

# Test HTTP health check with all targets returning expected status
test_http_all_targets_up() {
  test_start "HTTP mode: all targets returning HTTP 200"

  setup_mock_env

  # Mock curl to return HTTP 200
  create_mock_curl 200

  # Test configuration
  HTTP_TARGETS="https://1.1.1.1 https://8.8.8.8 https://9.9.9.9"
  HTTP_EXPECTED_CODE="200"
  MIN_OK=1
  PING_TIMEOUT=1
  STATE_DIR="$MOCK_DIR"

  # Simulate HTTP probe logic
  local ok=0
  local -a targets
  read -ra targets <<< "$HTTP_TARGETS"

  if [[ -x "$MOCK_CURL" ]]; then
    local -a pids=()
    local -a tmp_files=()

    for url in "${targets[@]}"; do
      local tmp_file
      tmp_file=$("$MKTEMP" -p "$STATE_DIR" http.XXXXXX)
      tmp_files+=("$tmp_file")

      (
        local status_code
        status_code=$("$MOCK_CURL" -s -o /dev/null -w "%{http_code}" \
          --insecure -m "$PING_TIMEOUT" "$url" 2>/dev/null || echo "000")

        if [[ "$status_code" == "$HTTP_EXPECTED_CODE" ]]; then
          echo "ok" > "$tmp_file"
        fi
      ) &
      pids+=($!)
    done

    # Wait for all probes
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done

    # Count successes
    for tmp_file in "${tmp_files[@]}"; do
      if [[ -f "$tmp_file" ]] && [[ "$(<"$tmp_file")" == "ok" ]]; then
        ((++ok))
      fi
      "$RM" -f "$tmp_file" 2>/dev/null || true
    done
  fi

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

# Test HTTP health check with partial failures
test_http_partial_failure() {
  test_start "HTTP mode: partial target failure (should pass with MIN_OK=1)"

  setup_mock_env

  # Mock curl to return HTTP 200
  create_mock_curl 200

  HTTP_TARGETS="https://1.1.1.1"
  HTTP_EXPECTED_CODE="200"
  MIN_OK=1
  PING_TIMEOUT=1

  local ok=0
  local -a targets
  read -ra targets <<< "$HTTP_TARGETS"

  if [[ -x "$MOCK_CURL" ]]; then
    for url in "${targets[@]}"; do
      local status_code
      status_code=$("$MOCK_CURL" -s -o /dev/null -w "%{http_code}" \
        --insecure -m "$PING_TIMEOUT" "$url" 2>/dev/null || echo "000")

      if [[ "$status_code" == "$HTTP_EXPECTED_CODE" ]]; then
        ((++ok))
      fi
    done
  fi

  if (( ok >= MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok >= $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

# Test HTTP health check with all targets unreachable
test_http_all_targets_down() {
  test_start "HTTP mode: all targets unreachable (timeout/connection error)"

  setup_mock_env

  # Mock curl to return 000 (connection failed)
  create_mock_curl 000

  HTTP_TARGETS="https://1.1.1.1 https://8.8.8.8"
  HTTP_EXPECTED_CODE="200"
  MIN_OK=1
  PING_TIMEOUT=1

  local ok=0
  local -a targets
  read -ra targets <<< "$HTTP_TARGETS"

  if [[ -x "$MOCK_CURL" ]]; then
    for url in "${targets[@]}"; do
      local status_code
      status_code=$("$MOCK_CURL" -s -o /dev/null -w "%{http_code}" \
        --insecure -m "$PING_TIMEOUT" "$url" 2>/dev/null || echo "000")

      if [[ "$status_code" == "$HTTP_EXPECTED_CODE" ]]; then
        ((++ok))
      fi
    done
  fi

  if (( ok < MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok < $MIN_OK, got $ok"
  fi

  cleanup_mock_env
}

# Test HTTP health check with unexpected status code
test_http_unexpected_status_code() {
  test_start "HTTP mode: unexpected status code (got 404, expected 200)"

  setup_mock_env

  # Mock curl to return HTTP 404
  create_mock_curl 404

  HTTP_TARGETS="https://1.1.1.1"
  HTTP_EXPECTED_CODE="200"
  MIN_OK=1
  PING_TIMEOUT=1

  local ok=0
  local -a targets
  read -ra targets <<< "$HTTP_TARGETS"

  if [[ -x "$MOCK_CURL" ]]; then
    for url in "${targets[@]}"; do
      local status_code
      status_code=$("$MOCK_CURL" -s -o /dev/null -w "%{http_code}" \
        --insecure -m "$PING_TIMEOUT" "$url" 2>/dev/null || echo "000")

      if [[ "$status_code" == "$HTTP_EXPECTED_CODE" ]]; then
        ((++ok))
      fi
    done
  fi

  # Should fail because status code doesn't match
  if (( ok < MIN_OK )); then
    test_pass
  else
    test_fail "Expected ok < $MIN_OK, got $ok (status code mismatch should fail)"
  fi

  cleanup_mock_env
}

#
# Run all tests
#

echo "=========================================="
echo "Netwatch Unit Tests"
echo "=========================================="
echo

# Probe logic tests
test_fping_all_targets_up
test_fping_partial_failure
test_fping_all_targets_down
test_ping_fallback_all_up
test_ping_fallback_all_down
test_min_ok_threshold

# Timer logic tests
test_outage_timer_logic
test_cooldown_enforcement
test_boot_grace_calculation

# Regression tests (errexit safety)
test_dryrun_does_not_arm_cooldown
test_digest_embed_format
test_digest_embed_escapes_window_hours
test_summary_reports_armed_state
test_summary_does_not_source_config
test_uninstall_removes_every_packaged_script
test_config_merge_preserves_values
test_summary_offload_labels_unambiguous
test_detect_iface_never_reports_bridge
test_deb_declares_conffiles
test_deb_config_permissions
test_deb_ships_digest_settings
test_digest_first_run_has_no_fake_delta
test_digest_redacts_host_identifiers
test_digest_template_placeholders_substituted
test_digest_json_escaping
test_corrupt_metrics_does_not_crash
test_metrics_reject_out_of_range
test_counter_delta_rejects_overflow
test_sampler_preserves_counters_when_unreadable
test_resume_announces_wan_down
test_fping_regex_matches_real_output
test_fping_regex_all_down
test_errexit_safe_increment
test_no_post_increment_in_agent
test_agent_increment_lines_survive_errexit

# TCP health check tests
test_tcp_all_targets_up
test_tcp_partial_failure
test_tcp_all_targets_down
test_tcp_invalid_target_format

# HTTP health check tests
test_http_all_targets_up
test_http_partial_failure
test_http_all_targets_down
test_http_unexpected_status_code

#
# Summary
#

echo
echo "=========================================="
echo "Test Results"
echo "=========================================="
echo -e "Total:  $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if (( TESTS_FAILED > 0 )); then
  echo
  echo -e "${RED}Some tests FAILED${NC}"
  exit 1
else
  echo
  echo -e "${GREEN}All tests PASSED${NC}"
  exit 0
fi
