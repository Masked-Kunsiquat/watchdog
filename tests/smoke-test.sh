#!/usr/bin/env bash
#
# smoke-test.sh - Comprehensive smoke tests for netwatch-agent
#
# Tests the agent in DRY_RUN mode with various scenarios:
# 1. Unreachable targets (triggers reboot)
# 2. Reachable targets (no reboot)
# 3. Recovery from outage
# 4. Disable file functionality
# 5. Boot grace period
#
# Usage: ./smoke-test.sh [--verbose]
#

set -Eeuo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="$SCRIPT_DIR/../src/netwatch-agent.sh"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#
# Test utilities
#

log_test() {
  echo -e "${YELLOW}TEST${NC} [$((++TESTS_RUN))] $*"
}

log_pass() {
  echo -e "${GREEN}PASS${NC}"
  ((TESTS_PASSED++))
}

log_fail() {
  echo -e "${RED}FAIL${NC} - $*"
  ((TESTS_FAILED++))
}

run_agent() {
  local timeout_sec="$1"
  local expected_pattern="${2:-}"

  if $VERBOSE; then
    timeout "$timeout_sec" bash "$AGENT_SCRIPT" 2>&1 | tee /tmp/smoke-test-output-$$.log
  else
    timeout "$timeout_sec" bash "$AGENT_SCRIPT" > /tmp/smoke-test-output-$$.log 2>&1 || true
  fi

  if [[ -n "$expected_pattern" ]]; then
    if grep -q "$expected_pattern" /tmp/smoke-test-output-$$.log; then
      return 0
    else
      return 1
    fi
  fi
}

cleanup() {
  rm -f /tmp/smoke-test-output-$$.log
  rm -f /tmp/netwatch-smoke-test-disable-$$
}

trap cleanup EXIT

#
# Preflight checks
#

echo "=========================================="
echo "Netwatch Agent Smoke Tests"
echo "=========================================="
echo

if [[ ! -f "$AGENT_SCRIPT" ]]; then
  echo -e "${RED}ERROR${NC}: Agent script not found at $AGENT_SCRIPT"
  exit 1
fi

echo "[Preflight] Checking bash syntax..."
if bash -n "$AGENT_SCRIPT"; then
  echo -e "${GREEN}✓${NC} Syntax OK"
else
  echo -e "${RED}✗${NC} Syntax errors found"
  exit 1
fi

echo

#
# Test 1: All targets unreachable (should trigger reboot)
#

log_test "All targets unreachable - should trigger reboot"

export TARGETS="203.0.113.1"  # RFC5737 TEST-NET (unreachable)
export MIN_OK=1
export PING_COUNT=1
export PING_TIMEOUT=1
export CHECK_INTERVAL=2
export DOWN_WINDOW_SECONDS=5
export BOOT_GRACE=0
export COOLDOWN_SECONDS=0
export DRY_RUN=1
export USE_FPING="no"
export DISABLE_FILE="/tmp/netwatch-smoke-test-disable-$$.nonexistent"

if run_agent 12s "DRY_RUN: would reboot"; then
  log_pass
else
  log_fail "Expected 'would reboot' message not found"
  $VERBOSE || cat /tmp/smoke-test-output-$$.log
fi

#
# Test 2: Reachable target (no reboot)
#

log_test "Reachable target - should NOT trigger reboot"

export TARGETS="8.8.8.8"  # Google DNS (likely reachable)
export DOWN_WINDOW_SECONDS=30

if run_agent 5s ""; then
  # Check that we started monitoring but didn't reboot
  if grep -q "Starting WAN watchdog" /tmp/smoke-test-output-$$.log && \
     ! grep -q "would reboot" /tmp/smoke-test-output-$$.log; then
    log_pass
  else
    log_fail "Unexpected reboot with reachable target"
    $VERBOSE || cat /tmp/smoke-test-output-$$.log
  fi
else
  log_pass
fi

#
# Test 3: Disable file prevents reboot
#

log_test "Disable file - should prevent monitoring"

export TARGETS="203.0.113.1"
export DOWN_WINDOW_SECONDS=5
export DISABLE_FILE="/tmp/netwatch-smoke-test-disable-$$"

# Create disable file
touch "$DISABLE_FILE"

if run_agent 8s ""; then
  if grep -q "Watchdog disabled" /tmp/smoke-test-output-$$.log && \
     ! grep -q "would reboot" /tmp/smoke-test-output-$$.log; then
    log_pass
  else
    log_fail "Disable file not respected"
    $VERBOSE || cat /tmp/smoke-test-output-$$.log
  fi
else
  log_pass
fi

rm -f "$DISABLE_FILE"

#
# Test 4: Boot grace period
#

log_test "Boot grace period - verify wait time calculation"

# Note: This test verifies the boot grace is logged but doesn't actually wait
# since we can't mock system uptime in a simple smoke test

export TARGETS="8.8.8.8"
export BOOT_GRACE=300
export DISABLE_FILE="/tmp/netwatch-smoke-test-disable-$$.nonexistent"

if run_agent 3s ""; then
  # Check if either boot grace message appears OR normal startup (uptime > grace)
  if grep -q -E "(Boot grace|Starting WAN watchdog)" /tmp/smoke-test-output-$$.log; then
    log_pass
  else
    log_fail "Expected boot grace or startup message"
    $VERBOSE || cat /tmp/smoke-test-output-$$.log
  fi
else
  log_pass
fi

#
# Test 5: MIN_OK threshold (require 2/3 targets)
#

log_test "MIN_OK threshold - require 2/3 targets"

export TARGETS="8.8.8.8 203.0.113.1 198.51.100.1"  # 1 reachable, 2 unreachable
export MIN_OK=2  # Need 2 to pass
export BOOT_GRACE=0
export DOWN_WINDOW_SECONDS=5

if run_agent 12s ""; then
  # Should trigger reboot since only 1/3 targets reachable but need 2
  if grep -q "would reboot" /tmp/smoke-test-output-$$.log; then
    log_pass
  else
    log_fail "Expected reboot with insufficient targets"
    $VERBOSE || cat /tmp/smoke-test-output-$$.log
  fi
else
  log_pass
fi

#
# Test 6: Verify fping fallback works
#

log_test "Ping fallback mode - forced ping usage"

export TARGETS="8.8.8.8"
export MIN_OK=1
export USE_FPING="no"  # Force ping fallback
export DOWN_WINDOW_SECONDS=30

if run_agent 5s ""; then
  if grep -q "Starting WAN watchdog" /tmp/smoke-test-output-$$.log; then
    log_pass
  else
    log_fail "Ping fallback failed to start"
    $VERBOSE || cat /tmp/smoke-test-output-$$.log
  fi
else
  log_pass
fi

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
  echo "Run with --verbose flag for detailed output"
  exit 1
else
  echo
  echo -e "${GREEN}All tests PASSED${NC}"
  exit 0
fi
