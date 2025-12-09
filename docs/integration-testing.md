# Integration Testing Guide

This document describes manual integration tests for Netwatch on real Debian/Proxmox systems.

## Prerequisites

- Fresh Debian 11+ or Proxmox VE 7+ system (VM recommended)
- Root access via sudo
- Network access for testing
- Ability to manipulate firewall rules (iptables)

## Test Environment Setup

### 1. Install Netwatch

```bash
# Clone repository
git clone https://github.com/your-org/watchdog.git
cd watchdog

# Run installer
sudo ./scripts/install.sh
```

Expected output:
- ✓ Preflight checks passed
- ✓ Agent script installed
- ✓ Config file installed
- ✓ Systemd unit installed
- ✓ Service enabled and started

### 2. Verify Installation

```bash
# Check service status
systemctl status netwatch-agent

# View initial logs
journalctl -u netwatch-agent -n 50
```

Expected log entries:
```
Starting WAN watchdog (targets: 1.1.1.1 8.8.8.8 9.9.9.9, threshold: 1/3, window: 600s)
```

## Test Suite

### Test 1: Normal Operation (Baseline)

**Objective**: Verify watchdog runs without false positives

**Steps**:
1. Ensure default config with reachable targets:
   ```bash
   cat /etc/default/netwatch-agent | grep TARGETS
   # Should show: TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
   ```

2. Monitor logs for 5 minutes:
   ```bash
   journalctl -u netwatch-agent -f
   ```

3. Verify no reboot triggers occur

**Expected Result**:
- No "WAN appears down" messages
- No reboot actions
- Regular heartbeat activity (if verbose logging enabled)

**Pass Criteria**: System runs stable for at least 5 minutes with no false alarms

---

### Test 2: Simulated WAN Outage (Core Functionality)

**Objective**: Verify watchdog triggers reboot after sustained outage

**Setup**:
1. Configure short thresholds for faster testing:
   ```bash
   sudo nano /etc/default/netwatch-agent
   ```

   Set:
   ```bash
   DOWN_WINDOW_SECONDS=60  # 1 minute for testing
   CHECK_INTERVAL=5        # Check every 5 seconds
   DRY_RUN=1              # Prevent actual reboot
   ```

2. Restart service:
   ```bash
   sudo systemctl restart netwatch-agent
   ```

**Steps**:
1. Block ICMP to all target IPs:
   ```bash
   # Save current iptables rules
   sudo iptables-save > /tmp/iptables-backup.rules

   # Block ICMP echo replies from targets
   sudo iptables -I OUTPUT -p icmp --icmp-type echo-request -d 1.1.1.1 -j DROP
   sudo iptables -I OUTPUT -p icmp --icmp-type echo-request -d 8.8.8.8 -j DROP
   sudo iptables -I OUTPUT -p icmp --icmp-type echo-request -d 9.9.9.9 -j DROP
   ```

2. Monitor logs:
   ```bash
   journalctl -u netwatch-agent -f
   ```

3. Wait for reboot trigger (should be ~60-70 seconds)

4. Restore iptables:
   ```bash
   sudo iptables-restore < /tmp/iptables-backup.rules
   ```

**Expected Result**:
- "WAN appears down" message appears within 5-10 seconds
- "DRY_RUN: would reboot now (outage: 60s >= 60s)" appears after ~60 seconds
- Outage duration is accurate (±10% of DOWN_WINDOW_SECONDS)

**Pass Criteria**: Reboot trigger fires within 10% of configured threshold

---

### Test 3: WAN Recovery (State Transition)

**Objective**: Verify watchdog recovers when WAN comes back online

**Setup**: Same as Test 2

**Steps**:
1. Block ICMP (as in Test 2)
2. Wait 30 seconds (half the threshold)
3. Verify "WAN appears down" message
4. Unblock ICMP:
   ```bash
   sudo iptables-restore < /tmp/iptables-backup.rules
   ```
5. Monitor logs for recovery

**Expected Result**:
- "WAN appears down" appears at ~5-10s
- "WAN recovered after Xs outage" appears when connectivity restored
- No reboot trigger fires
- Down timer resets

**Pass Criteria**: Recovery message appears and reboot is cancelled

---

### Test 4: Disable File (Emergency Pause)

**Objective**: Verify disable file immediately pauses watchdog

**Setup**: Same as Test 2 with WAN blocked

**Steps**:
1. Block ICMP to simulate outage
2. Wait for "WAN appears down" message
3. Create disable file:
   ```bash
   sudo touch /etc/netwatch-agent.disable
   ```
4. Monitor logs for 2 minutes
5. Verify no reboot occurs despite sustained outage

**Expected Result**:
- "Watchdog disabled via /etc/netwatch-agent.disable" message appears
- No reboot trigger despite outage exceeding threshold
- Logs show periodic disable file checks

**Pass Criteria**: No reboot for 2x DOWN_WINDOW_SECONDS with disable file present

**Cleanup**:
```bash
sudo rm /etc/netwatch-agent.disable
sudo iptables-restore < /tmp/iptables-backup.rules
```

---

### Test 5: Reboot Cooldown (Boot Loop Prevention)

**Objective**: Verify cooldown prevents rapid reboot cycles

**Setup**:
1. Edit config:
   ```bash
   sudo nano /etc/default/netwatch-agent
   ```

   Set:
   ```bash
   DOWN_WINDOW_SECONDS=30
   COOLDOWN_SECONDS=120  # 2 minutes
   DRY_RUN=1
   ```

2. Restart service

**Steps**:
1. Block ICMP
2. Wait for first "would reboot" message
3. Note the timestamp
4. Continue monitoring for another 2 minutes

**Expected Result**:
- First reboot trigger at ~30 seconds
- Subsequent log messages show: "Cooldown active: Xs remaining (outage continues: Ys)"
- No additional reboot triggers for 120 seconds
- Cooldown countdown decreases over time

**Pass Criteria**: Only one reboot trigger despite sustained 3+ minute outage

---

### Test 6: Boot Grace Period

**Objective**: Verify watchdog doesn't trigger premature reboot after system startup

**Setup**:
1. Set BOOT_GRACE=300 (5 minutes) in config
2. Ensure DRY_RUN=0 (we'll use disable file instead)
3. Block ICMP before reboot
4. Create disable file to prevent actual reboot

**Steps**:
1. Prepare environment:
   ```bash
   sudo iptables -I OUTPUT -p icmp --icmp-type echo-request -j DROP
   sudo touch /etc/netwatch-agent.disable
   ```

2. Reboot system:
   ```bash
   sudo reboot
   ```

3. After boot, SSH back in and check logs:
   ```bash
   journalctl -u netwatch-agent -b 0 -n 50
   ```

4. Look for boot grace message:
   ```
   Boot grace: waiting Xs (system uptime: Ys)
   ```

5. Cleanup:
   ```bash
   sudo rm /etc/netwatch-agent.disable
   sudo iptables -F OUTPUT
   ```

**Expected Result**:
- Boot grace wait message appears
- Watchdog delays monitoring for (300 - uptime) seconds
- No false reboot during boot process

**Pass Criteria**: Boot grace delay calculated correctly based on system uptime

---

### Test 7: MIN_OK Threshold (Partial Connectivity)

**Objective**: Verify watchdog respects MIN_OK threshold with partial target failures

**Setup**:
1. Edit config:
   ```bash
   sudo nano /etc/default/netwatch-agent
   ```

   Set:
   ```bash
   TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
   MIN_OK=2  # Require 2/3 targets
   DOWN_WINDOW_SECONDS=60
   DRY_RUN=1
   ```

2. Restart service

**Steps**:
1. Block only ONE target:
   ```bash
   sudo iptables -I OUTPUT -p icmp --icmp-type echo-request -d 1.1.1.1 -j DROP
   ```

2. Monitor logs for 2 minutes

3. Verify NO reboot (2/3 targets still reachable)

4. Block SECOND target:
   ```bash
   sudo iptables -I OUTPUT -p icmp --icmp-type echo-request -d 8.8.8.8 -j DROP
   ```

5. Monitor for reboot trigger (now only 1/3 targets reachable, below MIN_OK)

**Expected Result**:
- With 2/3 targets up: No "WAN appears down" message
- With 1/3 targets up: "WAN appears down" → reboot trigger after threshold

**Pass Criteria**: Watchdog correctly evaluates MIN_OK threshold

---

### Test 8: fping vs ping Fallback

**Objective**: Verify both probe methods work correctly

**Test 8a: fping mode**

1. Verify fping is installed:
   ```bash
   which fping
   dpkg -l | grep fping
   ```

2. Check logs show fping usage (or set USE_FPING="yes" to force)

3. Run Test 2 (simulated outage)

4. Verify reboot trigger works with fping

**Test 8b: ping fallback mode**

1. Force ping mode:
   ```bash
   sudo nano /etc/default/netwatch-agent
   # Set: USE_FPING="no"
   ```

2. Restart service

3. Run Test 2 again

4. Compare timing accuracy between fping and ping modes

**Expected Result**:
- fping mode: More deterministic timing (preferred)
- ping mode: Works correctly but slightly more variable timing
- Both modes trigger reboot at correct threshold

**Pass Criteria**: Both probe methods successfully detect outages

---

## Performance Validation

### Timing Accuracy Test

**Objective**: Verify reboot trigger timing is within ±5% of DOWN_WINDOW_SECONDS

**Setup**:
- DRY_RUN=1
- DOWN_WINDOW_SECONDS=300 (5 minutes)
- CHECK_INTERVAL=10

**Steps**:
1. Note exact time when blocking ICMP
2. Monitor logs with timestamps:
   ```bash
   journalctl -u netwatch-agent -f -o short-precise
   ```
3. Record exact time of "would reboot" message
4. Calculate delta

**Pass Criteria**: Reboot trigger within 285-315 seconds (±5%)

---

## Failure Modes

### What to Check if Tests Fail

**Test 2 fails (no reboot trigger)**:
- Verify iptables rules are active: `sudo iptables -L OUTPUT -n -v`
- Check targets are actually unreachable: `ping -c 1 1.1.1.1`
- Verify config loaded: `journalctl -u netwatch-agent | grep "Starting WAN watchdog"`
- Check for disable file: `ls -la /etc/netwatch-agent.disable`

**Test 3 fails (no recovery)**:
- Verify iptables rules were removed: `sudo iptables -L OUTPUT -n`
- Check targets are reachable: `ping -c 1 8.8.8.8`
- Review state machine logic in logs

**Timing is inaccurate (>10% variance)**:
- Check system load: `uptime`, `top`
- Verify CHECK_INTERVAL is appropriate (not too large)
- Consider using fping instead of ping fallback
- Check for clock skew: `timedatectl`

---

## Clean Uninstall Verification

**Objective**: Verify uninstaller removes all components

**Steps**:
1. Run uninstaller:
   ```bash
   sudo ./scripts/uninstall.sh
   ```

2. Verify complete removal:
   ```bash
   # Service should be gone
   systemctl status netwatch-agent  # Should fail

   # Files removed
   ls /usr/local/sbin/netwatch-agent.sh  # Should not exist
   ls /etc/systemd/system/netwatch-agent.service  # Should not exist
   ls /etc/default/netwatch-agent  # Should not exist
   ls /run/netwatch-agent  # Should not exist
   ```

3. Test with config preservation:
   ```bash
   # Reinstall
   sudo ./scripts/install.sh

   # Uninstall with --keep-config
   sudo ./scripts/uninstall.sh --keep-config

   # Verify config preserved
   ls /etc/default/netwatch-agent  # Should exist
   ls /etc/default/netwatch-agent.uninstall-backup  # Backup should exist
   ```

**Pass Criteria**: All components removed except config when --keep-config used

---

## Regression Test Checklist

Before each release, run this checklist:

- [ ] Test 1: Normal operation (5 min baseline)
- [ ] Test 2: Simulated outage triggers reboot
- [ ] Test 3: WAN recovery cancels reboot
- [ ] Test 4: Disable file pauses watchdog
- [ ] Test 5: Cooldown prevents boot loop
- [ ] Test 6: Boot grace delays monitoring
- [ ] Test 7: MIN_OK threshold respected
- [ ] Test 8a: fping mode works
- [ ] Test 8b: ping fallback works
- [ ] Performance: Timing accuracy ±5%
- [ ] Uninstall: Clean removal
- [ ] Uninstall: Config preservation with --keep-config

---

## Automated Test Execution

For CI/CD integration, see:
- [tests/unit-tests.sh](../tests/unit-tests.sh) - Unit tests for probe logic
- [tests/smoke-test.sh](../tests/smoke-test.sh) - Automated smoke tests

Manual integration tests require real network manipulation and cannot be fully automated.

---

**Last Updated**: 2025-12-08
**Maintained By**: Netwatch Contributors
