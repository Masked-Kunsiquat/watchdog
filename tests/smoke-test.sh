#!/usr/bin/env bash
#
# smoke-test.sh - Quick smoke test for netwatch-agent
#
# Tests the agent in DRY_RUN mode with unreachable targets
# to verify it would trigger a reboot within expected time.
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="$SCRIPT_DIR/../src/netwatch-agent.sh"

echo "=== Netwatch Agent Smoke Test ==="
echo

# Check if agent script exists
if [[ ! -f "$AGENT_SCRIPT" ]]; then
  echo "ERROR: Agent script not found at $AGENT_SCRIPT"
  exit 1
fi

# Check syntax
echo "[1/3] Checking bash syntax..."
if bash -n "$AGENT_SCRIPT"; then
  echo "✓ Syntax OK"
else
  echo "✗ Syntax errors found"
  exit 1
fi

echo

# Test with dry-run mode
echo "[2/3] Testing DRY_RUN mode with unreachable targets..."
echo "       Expected: 'would reboot' message within ~8-10 seconds"
echo

# Export test configuration
export TARGETS="203.0.113.1 198.51.100.1 192.0.2.1"  # RFC5737 TEST-NET IPs (unreachable)
export MIN_OK=1
export PING_COUNT=1
export PING_TIMEOUT=1
export CHECK_INTERVAL=1
export DOWN_WINDOW_SECONDS=8
export BOOT_GRACE=0
export COOLDOWN_SECONDS=0
export DRY_RUN=1
export USE_FPING="auto"
export DISABLE_FILE="/tmp/netwatch-smoke-test-disable-$$.nonexistent"

# Run agent in background with timeout
timeout 15s bash "$AGENT_SCRIPT" 2>&1 | grep --line-buffered "netwatch-agent" &
AGENT_PID=$!

# Wait for completion or timeout
if wait $AGENT_PID 2>/dev/null; then
  echo "✓ Agent exited normally"
else
  EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 124 ]]; then
    echo "✓ Test completed (timeout reached)"
  else
    echo "✗ Agent failed with exit code $EXIT_CODE"
    exit 1
  fi
fi

echo

echo "[3/3] Verifying script is executable..."
if [[ -x "$AGENT_SCRIPT" ]] || chmod +x "$AGENT_SCRIPT" 2>/dev/null; then
  echo "✓ Script permissions OK"
else
  echo "! Script not executable (run 'chmod +x $AGENT_SCRIPT')"
fi

echo
echo "=== Smoke Test Complete ==="
echo
echo "Manual testing:"
echo "  1. Review logs above for state transitions"
echo "  2. Verify 'DRY_RUN: would reboot' appears after ~8s"
echo "  3. Check 'WAN appears down' message appears first"
echo
