# Netwatch - Proxmox WAN Watchdog

[![CI](https://github.com/Masked-Kunsiquat/watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/Masked-Kunsiquat/watchdog/actions/workflows/ci.yml)

**A robust WAN watchdog for single-node Proxmox VE hosts**

Netwatch automatically reboots your Proxmox host after a configurable period of continuous WAN loss, providing reliable self-healing for network outages.

## Features

- **Parallel ICMP probing** of multiple targets (fping or fallback ping)
- **TCP and HTTP health checks** for Layer 4/7 validation (netcat/curl)
- **Configurable outage window** before reboot action
- **Safety rails**: boot grace period, cooldown between reboots
- **Webhook notifications** for Discord, ntfy, Gotify, Notifiarr, Apprise, and more
- **Dry-run mode** for safe testing
- **Systemd integration** with automatic restart and Type=notify support
- **Zero dependencies** beyond coreutils (shell + systemd only, curl optional for webhooks)
- **Root-first, sudo-optional** installers for Proxmox environments without sudo

## Quick Start

Install and verify in under 3 commands:

```bash
# 1. Install (run as root; prefix with sudo if available)
./scripts/install.sh

# 2. Check status
systemctl status netwatch-agent

# 3. View logs
journalctl -u netwatch-agent -f
```

That's it! The watchdog is now monitoring your WAN connection.

## Release Artifacts

- CI builds artifacts on every `v*` tag and uploads them to the GitHub Release:
  - `netwatch-agent_<version>.tar.gz` (source + scripts + configs)
  - `netwatch-agent_<version>_all.deb` (dpkg-deb, systemd-enabled)
- Build locally if needed:
  - Tarball: `VERSION=1.0.0 ./scripts/build-tarball.sh` → `dist/netwatch-agent_1.0.0.tar.gz`
  - Debian: `VERSION=1.0.0 ./scripts/build-deb.sh` → `dist/netwatch-agent_1.0.0_all.deb`

## Configuration Reference

All settings are in `/etc/default/netwatch-agent`. After editing, restart the service:

```bash
sudo nano /etc/default/netwatch-agent
sudo systemctl restart netwatch-agent
```

### Health Check Modes

Netwatch supports three health check methods with different network layer validation:

| Mode | Layer | Use Case | Dependencies |
|------|-------|----------|--------------|
| **ICMP** (default) | Layer 3 | Universal connectivity, works everywhere | `ping` (always available) |
| **TCP** | Layer 4 | Verify port reachability, bypass ICMP filters | `netcat` (`apt install netcat-openbsd`) |
| **HTTP/HTTPS** | Layer 7 | Full application stack validation | `curl` (`apt install curl`) |

**Configuration**:

| Variable | Default | Description |
|----------|---------|-------------|
| `HEALTH_CHECK_MODE` | `icmp` | Health check method: `icmp`, `tcp`, or `http`. |
| `TARGETS` | `1.1.1.1 8.8.8.8 9.9.9.9` | **ICMP mode**: Space-separated IP addresses to ping. |
| `TCP_TARGETS` | `1.1.1.1:853 8.8.8.8:443 9.9.9.9:443` | **TCP mode**: Space-separated `host:port` pairs to connect to. |
| `HTTP_TARGETS` | `https://1.1.1.1 https://8.8.8.8 https://9.9.9.9` | **HTTP mode**: Space-separated URLs to request. |
| `HTTP_EXPECTED_CODE` | `200` | **HTTP mode**: Expected HTTP status code (e.g., `200`, `204`, `301`). |

**Example: TCP health checks** (for environments blocking ICMP):
```bash
HEALTH_CHECK_MODE="tcp"
TCP_TARGETS="1.1.1.1:853 8.8.8.8:443 9.9.9.9:443"  # DNS-over-TLS and HTTPS ports
MIN_OK=2
```

**Example: HTTP health checks** (verify full application stack):
```bash
HEALTH_CHECK_MODE="http"
HTTP_TARGETS="https://1.1.1.1 https://www.google.com https://www.cloudflare.com"
HTTP_EXPECTED_CODE="200"
MIN_OK=2
```

### Network Probing (Common Settings)

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_OK` | `1` | Minimum number of targets that must respond to consider WAN "up" (applies to all health check modes). |
| `PING_TIMEOUT` | `1` | Timeout in seconds per target probe (applies to all modes: ICMP ping, TCP connection, or HTTP request). |
| `PING_COUNT` | `1` | **ICMP mode only**: Number of ICMP echo requests per target per loop. |
| `USE_FPING` | `auto` | **ICMP mode only**: Use fping if available (`auto`), require fping (`yes`), or force standard ping (`no`). |

### Timing & Safety

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECK_INTERVAL` | `10` | Seconds between health check loops. |
| `DOWN_WINDOW_SECONDS` | `600` | Continuous WAN outage duration (wall-clock) before triggering reboot. |
| `BOOT_GRACE` | `180` | Seconds after boot before monitoring starts (prevents boot loops). |
| `COOLDOWN_SECONDS` | `1200` | Minimum seconds between reboot actions (prevents rapid reboots). |

### Control & Testing

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `0` | Set to `1` to log reboot decisions without actually rebooting. Perfect for testing. |
| `DISABLE_FILE` | `/etc/netwatch-agent.disable` | If this file exists, monitoring is paused (sleeps 30s per loop). |

### Example Configurations

**Conservative (home router)**:
```bash
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222"
MIN_OK=2
DOWN_WINDOW_SECONDS=900    # 15 minutes
CHECK_INTERVAL=30          # Check every 30s
```

**Aggressive (datacenter with redundant uplinks)**:
```bash
TARGETS="1.1.1.1 8.8.8.8"
MIN_OK=1
DOWN_WINDOW_SECONDS=180    # 3 minutes
CHECK_INTERVAL=5
BOOT_GRACE=60
```

**Testing/Development**:
```bash
DRY_RUN=1
DOWN_WINDOW_SECONDS=30
CHECK_INTERVAL=5
```

### Webhook Notifications

Netwatch can send notifications to external services via webhooks for key events.

| Variable | Default | Description |
|----------|---------|-------------|
| `WEBHOOK_ENABLED` | `0` | Enable webhook notifications (`1` = enabled, `0` = disabled). |
| `WEBHOOK_URL` | (empty) | HTTP(S) URL to send notifications to. Required if webhooks enabled. |
| `WEBHOOK_METHOD` | `POST` | HTTP method to use (`POST`, `GET`, `PUT`, etc.). |
| `WEBHOOK_EVENTS` | `down,recovery,reboot,startup,health` | Comma-separated list of events to notify on. |
| `WEBHOOK_TIMEOUT` | `10` | Timeout in seconds for webhook HTTP requests. |
| `WEBHOOK_HEALTH_INTERVAL` | `86400` | Interval in seconds between health reports (24 hours). Set to `0` to disable. |
| `WEBHOOK_HEADERS` | (empty) | Custom HTTP headers (semicolon-separated, e.g., `Content-Type: application/json;Authorization: Bearer token`). |
| `WEBHOOK_BODY_TEMPLATE` | (JSON) | Custom body template with variable substitution (see examples below). |

**Event Types**:
- `down` - WAN connectivity lost (sent when outage begins)
- `recovery` - WAN connectivity restored (sent when connection returns)
- `reboot` - System about to reboot due to sustained outage
- `startup` - Service started after system boot (sent if uptime < 10 minutes - useful for confirming post-reboot recovery)
- `health` - Periodic health report with metrics (sent every `WEBHOOK_HEALTH_INTERVAL` seconds)

**Available template variables**:
- `{EVENT}` - Event type
- `{MESSAGE}` - Human-readable event message
- `{HOSTNAME}` - System hostname
- `{TIMESTAMP}` - ISO 8601 timestamp (UTC)
- `{DURATION}` - Event duration in seconds
- `{TARGETS}` - Configured target IPs
- `{DOWN_WINDOW}` - Configured outage threshold
- `{UPTIME}` - System uptime in seconds
- `{TOTAL_REBOOTS}` - Total reboots initiated by netwatch
- `{TOTAL_OUTAGES}` - Total WAN outages detected
- `{TOTAL_RECOVERIES}` - Total WAN recoveries
- `{TOTAL_DOWNTIME}` - Total downtime in seconds
- `{SERVICE_RUNTIME}` - Service runtime in seconds

**Quick Setup Examples**:

**Ntfy.sh** (simple notifications):
```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="https://ntfy.sh/my-unique-topic"
WEBHOOK_BODY_TEMPLATE="{HOSTNAME}: {MESSAGE}"
```

**Discord**:
```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"
WEBHOOK_BODY_TEMPLATE='{"content":"**{HOSTNAME}**: {MESSAGE}"}'
```

**Gotify**:
```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="https://gotify.example.com/message?token=YOUR_TOKEN"
WEBHOOK_BODY_TEMPLATE='{"title":"Netwatch {EVENT}","message":"{MESSAGE}","priority":8}'
```

**Notifiarr**:
```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="https://notifiarr.com/api/v1/notification/netwatch"
WEBHOOK_HEADERS="X-API-Key: your_api_key_here"
```

**Apprise API**:
```bash
WEBHOOK_ENABLED=1
WEBHOOK_URL="http://apprise.example.com:8000/notify"
WEBHOOK_BODY_TEMPLATE='{"urls":["discord://webhook_id/webhook_token"],"title":"Netwatch {EVENT}","body":"{MESSAGE}"}'
```

**Default JSON format** (if no template specified):
```json
{
  "event": "down",
  "message": "WAN connectivity lost...",
  "hostname": "proxmox",
  "timestamp": "2025-12-08T12:34:56Z",
  "duration": 0,
  "targets": "1.1.1.1 8.8.8.8 9.9.9.9"
}
```

**Requirements**: Webhooks require `curl` to be installed (`apt install curl`).

**Testing webhooks**:
```bash
# Test your webhook configuration (sends test notification)
sudo ./scripts/test-webhook.sh
```

This will send a test notification to verify your URL, authentication, and formatting are correct.

## Testing Guide

### Dry-Run Testing (Recommended First Step)

Test the watchdog without actually rebooting your system:

```bash
# Enable dry-run mode
sudo nano /etc/default/netwatch-agent
# Set: DRY_RUN=1

# Restart to apply
sudo systemctl restart netwatch-agent

# Watch the logs
sudo journalctl -u netwatch-agent -f
```

You'll see log messages like `DRY_RUN: would reboot now` when the threshold is met.

### Smoke Test

Run the automated smoke test to verify behavior with unreachable targets:

```bash
cd tests/
sudo ./smoke-test.sh
```

Expected output:
- Service starts successfully
- Detects WAN down within 8-10 seconds (using test IPs)
- Logs "would reboot now" message
- No actual reboot occurs

### Manual Integration Test

Test on a VM or non-critical system:

1. **Set short timings for faster testing**:
   ```bash
   sudo nano /etc/default/netwatch-agent
   ```
   ```bash
   DOWN_WINDOW_SECONDS=60    # 1 minute for testing
   CHECK_INTERVAL=5
   DRY_RUN=0                 # Actual reboot!
   ```

2. **Simulate WAN outage** using iptables:
   ```bash
   # Block ICMP to test targets
   sudo iptables -I OUTPUT -p icmp -d 1.1.1.1 -j DROP
   sudo iptables -I OUTPUT -p icmp -d 8.8.8.8 -j DROP
   sudo iptables -I OUTPUT -p icmp -d 9.9.9.9 -j DROP
   ```

3. **Verify behavior**:
   ```bash
   sudo journalctl -u netwatch-agent -f
   ```
   - Should see "WAN appears down; starting timer."
   - After ~60 seconds: "Threshold met; rebooting."
   - System reboots

4. **Test recovery** (restore connectivity before reboot):
   ```bash
   sudo iptables -D OUTPUT -p icmp -d 1.1.1.1 -j DROP
   ```
   - Should see "WAN reachable again after Xs"
   - Timer resets, no reboot

### Verifying Determinism

The watchdog should trigger within ±5% of `DOWN_WINDOW_SECONDS`:

- 600s window → trigger between 570-630s
- 180s window → trigger between 171-189s

Check logs with timestamps:
```bash
sudo journalctl -u netwatch-agent -o short-iso | grep -E "(appears down|rebooting)"
```

## Operations Playbook

### Daily Operations

**View live status**:
```bash
sudo systemctl status netwatch-agent
```

**Follow logs**:
```bash
sudo journalctl -u netwatch-agent -f
```

**Check recent activity**:
```bash
sudo journalctl -u netwatch-agent --since "1 hour ago"
```

### Pause and Resume

**Pause watchdog** (e.g., during maintenance):
```bash
sudo touch /etc/netwatch-agent.disable
```

The service continues running but takes no action. Logs show:
```
Disabled via /etc/netwatch-agent.disable
```

**Resume watchdog**:
```bash
sudo rm /etc/netwatch-agent.disable
```

Monitoring resumes immediately on next loop.

### Tuning Configuration

**Change settings**:
```bash
sudo nano /etc/default/netwatch-agent
sudo systemctl restart netwatch-agent
```

**Common tuning scenarios**:

- **Flaky connection**: Increase `MIN_OK` and add more `TARGETS`
- **Faster response**: Reduce `DOWN_WINDOW_SECONDS` and `CHECK_INTERVAL`
- **Prevent false positives**: Increase `DOWN_WINDOW_SECONDS`
- **After infrastructure change**: Update `TARGETS` to match new network

### Uninstall

```bash
sudo ./scripts/uninstall.sh
```

Removes service, config, and script. Optionally backs up config with `.bak` suffix.

## Troubleshooting

### Service Not Running

**Check status**:
```bash
sudo systemctl status netwatch-agent
```

**If failed to start**:
```bash
# View full error logs
sudo journalctl -u netwatch-agent -n 50 --no-pager

# Check config syntax
sudo bash -n /usr/local/sbin/netwatch-agent.sh

# Verify config file exists
ls -l /etc/default/netwatch-agent
```

**Common causes**:
- Missing config file → reinstall or create from template
- Syntax error in config → check for quotes, equals signs
- Missing dependencies → ensure `ping` is available

### Watchdog Not Rebooting During Outage

**Check if dry-run is enabled**:
```bash
grep DRY_RUN /etc/default/netwatch-agent
```
If `DRY_RUN=1`, the watchdog only logs decisions. Set to `0` for actual reboots.

**Check if disabled**:
```bash
ls -l /etc/netwatch-agent.disable
```
Remove the file to re-enable: `sudo rm /etc/netwatch-agent.disable`

**Check cooldown status**:
```bash
sudo journalctl -u netwatch-agent | grep -i cooldown
```
If "Cooldown active" appears, the system recently rebooted and the cooldown timer is preventing another reboot.

**Verify targets are actually unreachable**:
```bash
ping -c 3 1.1.1.1
ping -c 3 8.8.8.8
```
If targets respond, the watchdog is working correctly by NOT rebooting.

### Unexpected Reboots

**Check recent logs**:
```bash
sudo journalctl -u netwatch-agent --since "2 hours ago" | grep -E "(down|reboot)"
```

**Verify timing**:
- Was WAN actually down for `DOWN_WINDOW_SECONDS`?
- Check if `DOWN_WINDOW_SECONDS` is too aggressive

**Increase threshold**:
```bash
sudo nano /etc/default/netwatch-agent
# Increase DOWN_WINDOW_SECONDS (e.g., from 600 to 900)
# Increase MIN_OK (e.g., from 1 to 2)
sudo systemctl restart netwatch-agent
```

### False Positives (Transient Failures)

**Add more diverse targets**:
```bash
sudo nano /etc/default/netwatch-agent
```
```bash
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222"  # Add more providers
MIN_OK=2                                           # Require 2 to respond
```

**Increase tolerance**:
```bash
PING_COUNT=3              # Send 3 pings per target
PING_TIMEOUT=2            # Wait 2 seconds
CHECK_INTERVAL=15         # Slower checks
DOWN_WINDOW_SECONDS=900   # Require 15min continuous outage
```

### Watchdog Triggers Too Slowly

**Reduce timings** (use with caution):
```bash
CHECK_INTERVAL=5          # Check every 5 seconds
DOWN_WINDOW_SECONDS=180   # 3 minute window
```

**Enable fping** for faster parallel probes:
```bash
sudo apt install fping
# Verify in logs: should see "using fping"
```

### Cannot Install fping

The watchdog works fine without fping using fallback ping mode. Performance difference is minimal for small target lists.

To verify fallback mode:
```bash
sudo journalctl -u netwatch-agent | grep -i fping
```

Should not see errors, just uses `ping` in background processes.

### Logs Show "Disabled via /etc/netwatch-agent.disable"

This is normal if the disable file exists. Remove it to resume:
```bash
sudo rm /etc/netwatch-agent.disable
```

### Boot Loops After Install

**This should never happen** due to `BOOT_GRACE` and `COOLDOWN_SECONDS` safety mechanisms.

If experiencing boot loops:

1. **Boot into recovery mode** or single-user mode
2. **Disable the service**:
   ```bash
   systemctl disable netwatch-agent
   systemctl stop netwatch-agent
   ```
3. **Investigate config**:
   ```bash
   cat /etc/default/netwatch-agent
   ```
4. **Likely causes**:
   - `BOOT_GRACE=0` (should be ≥60)
   - `DOWN_WINDOW_SECONDS` too short (should be ≥180)
   - `COOLDOWN_SECONDS` too short (should be ≥600)

5. **Fix and re-enable**:
   ```bash
   nano /etc/default/netwatch-agent
   # Set safe values: BOOT_GRACE=180, DOWN_WINDOW_SECONDS=600
   systemctl enable --now netwatch-agent
   ```

### Checking Watchdog State

**View current configuration**:
```bash
sudo systemctl show netwatch-agent --property=Environment
```

**Check if service is healthy**:
```bash
sudo systemctl is-active netwatch-agent
sudo systemctl is-enabled netwatch-agent
```

**Verify heartbeat** (if using systemd watchdog):
```bash
sudo journalctl -u netwatch-agent | grep -i watchdog
```

## Documentation

- [AGENTS.md](AGENTS.md) - Complete technical specification
- [GAMEPLAN.md](GAMEPLAN.md) - Implementation phases
- [CHANGELOG.md](CHANGELOG.md) - Version history

## Architecture

### State Machine

Netwatch implements a simple, deterministic state machine:

```
           ┌─────────────┐
           │   STARTUP   │
           │ (boot grace)│
           └──────┬──────┘
                  │
                  ▼
           ┌─────────────┐
      ┌───►│  MONITORING │◄────┐
      │    └──────┬──────┘     │
      │           │             │
      │    Probe fails          │ Probe succeeds
      │    (< MIN_OK)           │ (≥ MIN_OK)
      │           │             │
      │           ▼             │
      │    ┌─────────────┐     │
      │    │  WAN DOWN   │─────┘
      │    │ (tracking   │  Recovery
      │    │  duration)  │
      │    └──────┬──────┘
      │           │
      │    Outage ≥ DOWN_WINDOW
      │           │
      │           ▼
      │    ┌─────────────┐
      │    │   REBOOT    │
      │    │  (cooldown) │
      │    └──────┬──────┘
      │           │
      │      Host reboots
      │           │
      └───────────┘
```

### Key Design Principles

1. **Parallel probing**: All targets checked simultaneously (not sequentially)
   - Uses `fping` when available for efficient batch ICMP
   - Falls back to background `ping` processes
   - Loop time ≈ `PING_TIMEOUT` regardless of target count

2. **Wall-clock tracking**: Outage duration measured in real time
   - `down_start` timestamp set on first failure
   - Checked against `DOWN_WINDOW_SECONDS` threshold
   - Any success immediately resets the timer

3. **No flapping tolerance**: Only continuous outages trigger reboots
   - Transient failures don't accumulate
   - Single successful probe = WAN is up
   - Prevents reboots during intermittent connectivity

4. **Safety mechanisms**:
   - **Boot grace**: Delays monitoring after boot to prevent boot loops
   - **Cooldown**: Enforces minimum time between reboot attempts
   - **Disable file**: Provides emergency pause without stopping service
   - **Dry-run mode**: Allows testing without actual reboots

### File Locations

| Path | Purpose | Permissions |
|------|---------|-------------|
| `/usr/local/sbin/netwatch-agent.sh` | Main agent script | 0755 root:root |
| `/etc/default/netwatch-agent` | Configuration file | 0640 root:root |
| `/etc/systemd/system/netwatch-agent.service` | systemd unit | 0644 root:root |
| `/etc/netwatch-agent.disable` | Disable flag (optional) | any |
| `/run/netwatch-agent/` | Runtime state (volatile) | 0755 root:root |

## Requirements

**Runtime**:
- Debian/Proxmox with systemd 219+
- Bash 4.0+
- `ping` (always present in coreutils)
- `fping` (recommended, optional - provides faster parallel probes)
- `logger` for syslog/journald integration
- Root privileges (required for reboot capability)

**Development**:
- `shellcheck` for linting (all scripts must be shellcheck-clean)
- Debian/Proxmox VM for integration testing
- Git for version control

## Hardware Watchdog (Complementary)

Netwatch protects against **network-related outages**. For protection against **kernel hangs or complete system freezes**, enable your hardware watchdog separately.

### Quick Hardware Watchdog Setup

Most Proxmox/server hardware has a built-in hardware watchdog timer (e.g., Intel iTCO_wdt):

1. **Load the kernel module**:
   ```bash
   sudo modprobe iTCO_wdt
   echo "iTCO_wdt" | sudo tee -a /etc/modules
   ```

2. **Install watchdog daemon**:
   ```bash
   sudo apt install watchdog
   ```

3. **Configure** `/etc/watchdog.conf`:
   ```bash
   watchdog-device = /dev/watchdog
   max-load-1 = 24
   ```

4. **Enable and start**:
   ```bash
   sudo systemctl enable --now watchdog
   ```

The hardware watchdog and Netwatch work together:
- **Netwatch**: Handles WAN outages, reboots when internet is lost
- **Hardware watchdog**: Handles kernel panics, reboots when system hangs

Both are recommended for production Proxmox hosts.

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

This project follows the specification in [AGENTS.md](AGENTS.md).

### Development Standards

- All shell scripts must be **shellcheck-clean** (no warnings or errors)
- Use strict bash options: `set -Eeuo pipefail`
- Absolute paths for all binaries
- Comprehensive logging for all state transitions
- Follow existing code style and conventions

### Testing Requirements

Before submitting changes:

1. Run `shellcheck -x` on all modified scripts
2. Execute the smoke test suite
3. Test on a Proxmox/Debian VM with both fping and fallback modes
4. Verify dry-run mode works correctly
5. Update documentation and CHANGELOG

## Project Status

| Component | Status | Version |
|-----------|--------|---------|
| Core Agent | Complete | v0.1.0 |
| Systemd Integration | Complete | v0.1.0 |
| Installers | Complete | v0.1.0 |
| Unit Tests | Complete | v0.1.0 |
| Documentation | Complete | v0.1.0 |

**Current Version**: v0.1.0
**Stability**: Production-ready
**Next Planned**: Future extensions (see [GAMEPLAN.md](GAMEPLAN.md) Phase 6)

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.

## Support

- **Issues**: Report bugs via GitHub Issues
- **Questions**: See [Troubleshooting](#troubleshooting) section above
- **Documentation**: [AGENTS.md](AGENTS.md) is the authoritative technical spec

---

**Maintained by**: Netwatch Contributors
**Source of Truth**: [AGENTS.md](AGENTS.md)
**Last Updated**: 2025-12-08
