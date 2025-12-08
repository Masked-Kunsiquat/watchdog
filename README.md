# Netwatch - Proxmox WAN Watchdog

**A robust WAN watchdog for single-node Proxmox VE hosts**

Netwatch automatically reboots your Proxmox host after a configurable period of continuous WAN loss, providing reliable self-healing for network outages.

## Features

- **Parallel ICMP probing** of multiple targets (fping or fallback ping)
- **Configurable outage window** before reboot action
- **Safety rails**: boot grace period, cooldown between reboots
- **Dry-run mode** for safe testing
- **Systemd integration** with automatic restart
- **Zero dependencies** beyond coreutils (shell + systemd only)

## Quick Start

```bash
# Install
sudo ./scripts/install.sh

# Check status
sudo systemctl status netwatch-agent

# View logs
sudo journalctl -u netwatch-agent -f

# Test with dry-run
sudo systemctl edit netwatch-agent
# Add: Environment="DRY_RUN=1"
sudo systemctl restart netwatch-agent
```

## Configuration

Edit `/etc/default/netwatch-agent` to customize:

- `TARGETS` - Space-separated IPs to probe (default: 1.1.1.1 8.8.8.8 9.9.9.9)
- `DOWN_WINDOW_SECONDS` - Continuous outage before reboot (default: 600)
- `CHECK_INTERVAL` - Seconds between health checks (default: 10)
- `COOLDOWN_SECONDS` - Minimum time between reboots (default: 1200)

See [AGENTS.md](AGENTS.md) for full configuration reference.

## Operations

**Pause watchdog**:
```bash
sudo touch /etc/netwatch-agent.disable
```

**Resume watchdog**:
```bash
sudo rm /etc/netwatch-agent.disable
```

**Change configuration**:
```bash
sudo nano /etc/default/netwatch-agent
sudo systemctl restart netwatch-agent
```

**Uninstall**:
```bash
sudo ./scripts/uninstall.sh
```

## Testing

Run the smoke test to verify behavior without rebooting:

```bash
cd tests/
sudo ./smoke-test.sh
```

## Documentation

- [AGENTS.md](AGENTS.md) - Complete technical specification
- [GAMEPLAN.md](GAMEPLAN.md) - Implementation phases
- [CHANGELOG.md](CHANGELOG.md) - Version history

## Architecture

Netwatch uses a simple state machine:

1. **Probe** multiple targets in parallel each loop
2. **Track** continuous outage duration
3. **Reboot** when threshold met (with safety checks)
4. **Reset** timer on any successful probe

No flapping - only continuous outages trigger reboots.

## Requirements

**Runtime**:
- Debian/Proxmox with systemd
- Bash 4.0+
- `ping` (always present)
- `fping` (recommended, optional)

**Development**:
- shellcheck (linting)
- Proxmox/Debian VM (testing)

## Safety

- **Boot grace**: Wait after boot before monitoring
- **Cooldown**: Never reboot more often than configured
- **Disable file**: Emergency pause mechanism
- **Dry-run**: Test without rebooting

## Hardware Watchdog

For protection against kernel hangs, enable your hardware watchdog separately. See [docs/hardware-watchdog.md](docs/hardware-watchdog.md).

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

This project follows the specification in [AGENTS.md](AGENTS.md). All code must be shellcheck-clean.

## Status

**Current Version**: v0.1.0-dev (Phase 1 complete)
**Status**: Core agent implemented, installers pending
**Next Release**: v0.2.0 (Phase 2-3: Installers + testing)
**Target**: Production-ready v1.0.0

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.

---

**Maintained by**: Netwatch Contributors
**Source of Truth**: [AGENTS.md](AGENTS.md)
