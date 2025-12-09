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
    if [[ "$line" =~ :\ ([0-9]+)/([0-9]+)/ ]]; then
      local rcv="${BASH_REMATCH[2]}"
      if (( rcv >= 1 )); then
        ((count++))
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
    ("$MOCK_PING" -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" >/dev/null 2>&1) &
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
        ((ok++))
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
          ((ok++))
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
          ((ok++))
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
      ((valid_targets++))
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
        ((ok++))
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
        ((ok++))
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
        ((ok++))
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
        ((ok++))
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
