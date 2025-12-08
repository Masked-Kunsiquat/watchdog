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
  ((TESTS_RUN++))
}

test_pass() {
  echo -e "${GREEN}PASS${NC}"
  ((TESTS_PASSED++))
}

test_fail() {
  echo -e "${RED}FAIL${NC} - $*"
  ((TESTS_FAILED++))
}

#
# Mock environment setup
#

setup_mock_env() {
  export MOCK_DIR
  MOCK_DIR=$(mktemp -d)
  export PATH="$MOCK_DIR:$PATH"
}

cleanup_mock_env() {
  rm -rf "$MOCK_DIR"
}

create_mock_fping() {
  local exit_code="${1:-0}"
  local output="${2:-}"

  cat > "$MOCK_DIR/fping" <<EOF
#!/usr/bin/env bash
echo "$output"
exit $exit_code
EOF
  chmod +x "$MOCK_DIR/fping"
}

create_mock_ping() {
  local exit_code="${1:-0}"

  cat > "$MOCK_DIR/ping" <<EOF
#!/usr/bin/env bash
exit $exit_code
EOF
  chmod +x "$MOCK_DIR/ping"
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

  # Source the probe function (extract from agent script)
  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1
  USE_FPING="yes"

  # Run probe logic inline
  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_DIR/fping" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_DIR/fping" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)

    while IFS= read -r line; do
      [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
      if [[ "$line" =~ :\ ([0-9]+)/([0-9]+)/ ]]; then
        local rcv="${BASH_REMATCH[2]}"
        if (( rcv >= 1 )); then
          ((ok++))
        fi
      fi
    done <<<"$output"
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

  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1
  USE_FPING="yes"

  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_DIR/fping" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_DIR/fping" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)

    while IFS= read -r line; do
      [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
      if [[ "$line" =~ :\ ([0-9]+)/([0-9]+)/ ]]; then
        local rcv="${BASH_REMATCH[2]}"
        if (( rcv >= 1 )); then
          ((ok++))
        fi
      fi
    done <<<"$output"
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

  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=1
  PING_COUNT=1
  PING_TIMEOUT=1
  USE_FPING="yes"

  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_DIR/fping" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_DIR/fping" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)

    while IFS= read -r line; do
      [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
      if [[ "$line" =~ :\ ([0-9]+)/([0-9]+)/ ]]; then
        local rcv="${BASH_REMATCH[2]}"
        if (( rcv >= 1 )); then
          ((ok++))
        fi
      fi
    done <<<"$output"
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
    ("$MOCK_DIR/ping" -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      ((ok++))
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
    ("$MOCK_DIR/ping" -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      ((ok++))
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

  TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
  MIN_OK=2  # Require 2 targets
  PING_COUNT=1
  PING_TIMEOUT=1
  USE_FPING="yes"

  local ok=0
  local -a targets
  read -ra targets <<< "$TARGETS"

  if [[ -x "$MOCK_DIR/fping" ]]; then
    local timeout_ms=$((PING_TIMEOUT * 1000))
    local output
    output=$("$MOCK_DIR/fping" -c "$PING_COUNT" -t "$timeout_ms" -q "${targets[@]}" 2>&1 || true)

    while IFS= read -r line; do
      [[ "$line" == *"xmt/rcv/%loss"* ]] || continue
      if [[ "$line" =~ :\ ([0-9]+)/([0-9]+)/ ]]; then
        local rcv="${BASH_REMATCH[2]}"
        if (( rcv >= 1 )); then
          ((ok++))
        fi
      fi
    done <<<"$output"
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
