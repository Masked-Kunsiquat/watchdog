# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned for v0.2.0
- Installer and uninstaller scripts (Phase 2)
- Unit tests and integration tests (Phase 4)
- Comprehensive operations documentation (Phase 5)
- Optional .deb packaging

## [v0.1.0-dev] - 2025-12-08

Core agent implementation complete (Phase 1).

### Added
- `src/netwatch-agent.sh` - Main watchdog agent
  - Parallel ICMP probing with fping/ping fallback
  - Wall-clock outage tracking with configurable threshold
  - State machine: UP → DOWN → REBOOT with recovery
  - Boot grace period and reboot cooldown safety
  - Disable file support for emergency pause
  - Dry-run mode for safe testing
  - systemd notification support (ready + watchdog heartbeat)
- `config/netwatch-agent.conf` - Configuration template with documented defaults
- `config/netwatch-agent.service` - systemd unit file
- `tests/smoke-test.sh` - Dry-run validation script

### Features
- Deterministic loop timing via parallel probes
- Cross-platform logging (logger + stderr fallback)
- Strict bash mode for reliability
- Zero dependencies beyond coreutils

## [v0.0.1-phase0] - 2025-12-08

Project bootstrap and foundation (Phase 0).

### Added
- Project directory structure (src/, config/, scripts/, tests/, docs/)
- `.gitignore` for build artifacts and IDE files
- `LICENSE` (MIT)
- `README.md` with quick start guide and operations reference
- `CHANGELOG.md` for version tracking
- `AGENTS.md` - Complete technical specification
- `GAMEPLAN.md` - Phased implementation plan

---

## Version History

- **0.1.0-dev**: Initial development phase
- **0.1.0**: Planned first release (MVP)
- **0.2.0**: Planned .deb packaging support
- **1.0.0**: Planned production-ready release

---

**Maintained by**: Netwatch Contributors
**Last Updated**: 2025-12-08
