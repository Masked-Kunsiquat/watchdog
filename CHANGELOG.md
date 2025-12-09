# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned for Future Releases
- Optional .deb packaging (Phase 5.3)
- HTTP/TCP layer 7 health checks (Phase 6)
- Per-interface routing table awareness (Phase 6)
- Prometheus metrics exporter (Phase 6)
- Web dashboard for multi-host monitoring (Phase 6)

## [v0.5.0] - 2025-12-09

**Webhook Notifications** - External alerting and metrics reporting

This release adds comprehensive webhook support for external notifications, enabling integration with Discord, ntfy, Gotify, Notifiarr, Apprise, and other webhook-compatible services.

### Added

**Webhook System**:
- Flexible webhook system for external notifications (Discord, ntfy, Gotify, Notifiarr, Apprise, etc.)
- Event-based notifications: `down`, `recovery`, `reboot`, `startup`, `health`
- Custom templating with variable substitution (15+ variables: `{EVENT}`, `{MESSAGE}`, `{HOSTNAME}`, `{TIMESTAMP}`, `{DURATION}`, `{UPTIME}`, `{TOTAL_REBOOTS}`, etc.)
- Configurable HTTP method, headers, timeout, and event filtering
- Non-blocking background execution (doesn't delay reboot actions)
- Persistent metrics tracking with availability calculations
- Automatic JSON default format with opt-in custom templates
- 8 configuration variables (`WEBHOOK_ENABLED`, `WEBHOOK_URL`, `WEBHOOK_METHOD`, `WEBHOOK_EVENTS`, `WEBHOOK_TIMEOUT`, `WEBHOOK_HEALTH_INTERVAL`, `WEBHOOK_HEADERS`, `WEBHOOK_BODY_TEMPLATE`)
- Startup notifications for post-reboot confirmation (sent if uptime < 10 minutes)
- Periodic health reports with comprehensive metrics (configurable interval, default 24h)
- Test script (`scripts/test-webhook.sh`) for on-demand notification testing
- Examples for 5+ popular notification services in config template

### Changed
- Updated version roadmap to avoid conflicts with existing releases
- All binaries now use absolute paths for security hardening consistency

## [v0.4.0-rc1] - 2025-12-08

**Phase 5 Complete** - Production-ready documentation and polish

This release marks the completion of Phase 5 with comprehensive documentation, testing, and production-ready code. The watchdog is ready for deployment on Proxmox VE and Debian systems.

### Added

**Documentation (Phase 5)**:
- Comprehensive README.md with:
  - 3-command quick start guide
  - Complete configuration reference with all variables documented
  - Example configurations for different use cases (conservative, aggressive, testing)
  - Extensive testing guide (dry-run, smoke test, manual integration)
  - Operations playbook (daily operations, pause/resume, tuning)
  - Troubleshooting section covering 10+ common scenarios
  - Architecture documentation with state machine diagram
  - Hardware watchdog integration guide
  - Development and contribution standards
- Updated CHANGELOG.md with semantic versioning commitment
- Project status tracking with component completion table

**Quality Improvements**:
- All documentation follows best practices for operator clarity
- Consistent formatting and structure across all docs
- Cross-referenced documentation (README ↔ AGENTS.md ↔ GAMEPLAN.md)
- Real-world examples for configuration and testing
- Clear troubleshooting flowcharts and decision trees

### Documentation Structure

| Document | Purpose | Audience |
|----------|---------|----------|
| [README.md](README.md) | Quick start, operations, troubleshooting | Operators/Users |
| [AGENTS.md](AGENTS.md) | Technical specification | Developers |
| [GAMEPLAN.md](GAMEPLAN.md) | Implementation phases | Project management |
| [CHANGELOG.md](CHANGELOG.md) | Version history | All stakeholders |

### Stability Notes

This release has been:
- Shellcheck validated (zero warnings)
- Smoke tested with unreachable targets
- Integration tested with simulated outages
- Documented comprehensively for production use
- Validated for deterministic timing (±5% accuracy)

### Known Limitations

- ICMP-only health checks (layer 3) - HTTP/TCP checks planned for future
- Single-interface monitoring - multi-interface routing awareness planned
- No built-in alerting - relies on journald/syslog forwarding
- Shell-only implementation - no advanced metrics or dashboards

### Upgrade Notes

This is the first production release. No upgrade path needed.

## [v0.3.0-beta] - 2025-12-08

Phase 4 complete - comprehensive testing suite ready.

### Added
- `tests/unit-tests.sh` - Unit test suite with:
  - Mock-based probe function testing
  - fping output parsing validation
  - ping fallback mode testing
  - MIN_OK threshold verification
  - Outage timer logic tests
  - Cooldown enforcement tests
  - Boot grace calculation tests
  - Color-coded test results with pass/fail summary
- Enhanced `tests/smoke-test.sh` with:
  - 6 comprehensive test scenarios
  - Unreachable target testing (reboot trigger)
  - Reachable target testing (no false positives)
  - Disable file functionality validation
  - Boot grace period verification
  - MIN_OK threshold testing
  - Ping fallback mode validation
  - Verbose mode for debugging (--verbose flag)
  - Automatic cleanup with trap handlers
- `docs/integration-testing.md` - Complete integration test guide with:
  - 8 detailed manual test procedures
  - Network simulation instructions (iptables)
  - Timing accuracy validation
  - Performance benchmarks (±5% accuracy requirement)
  - Regression test checklist
  - Troubleshooting guide for failed tests

### Quality
- All scripts validated for shellcheck compliance
- Test coverage for all critical paths
- Documented test procedures for operators
- Automated smoke tests for CI/CD integration

### Testing
- 9 unit tests covering probe logic and timing calculations
- 6 automated smoke tests for quick validation
- 8 documented integration tests for production readiness
- Performance validation framework (timing accuracy)

## [v0.2.0-alpha] - 2025-12-08

Phases 1-3 complete - installer ready for testing.

### Added
- `scripts/install.sh` - Idempotent installer with:
  - Root/systemd preflight checks
  - Config preservation on upgrades
  - Automatic fping detection with hints
  - Service enable + start automation
  - Color-coded user feedback
- `scripts/uninstall.sh` - Clean uninstaller with:
  - Service stop and disable
  - Complete file cleanup
  - Optional config preservation (--keep-config)
  - Backup management
- `.gitattributes` - Enforce Unix line endings for scripts

### Security
- All binaries use absolute paths (prevents PATH attacks)
- Shellcheck-clean code (SC2206, SC1017 resolved)
- Unix line endings enforced for Linux compatibility

### Quality
- Word splitting fixed with proper `read -ra` usage
- Cross-platform development support (Windows + Linux)
- Strict error handling in all scripts

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

- **v0.0.1-phase0** (2025-12-08): Project bootstrap (Phase 0)
- **v0.1.0-dev** (2025-12-08): Core agent implementation (Phase 1)
- **v0.2.0-alpha** (2025-12-08): Installers and systemd integration (Phases 2-3)
- **v0.3.0-beta** (2025-12-08): Testing suite and QA (Phase 4)
- **v0.4.0-rc1** (2025-12-08): Documentation and polish (Phase 5) ✓
- **v0.5.0** (2025-12-09): Webhook notifications ✓

## Semantic Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR** version: Incompatible API changes or breaking configuration changes
- **MINOR** version: New functionality in a backwards-compatible manner
- **PATCH** version: Backwards-compatible bug fixes

### Future Version Roadmap

- **v0.5.0**: Webhook notifications (current unreleased work)
- **v0.6.0**: Optional .deb packaging, enhanced installation experience
- **v0.7.0**: Advanced monitoring features (HTTP/TCP checks)
- **v1.0.0**: Long-term support release with production hardening

---

## Contributing to CHANGELOG

When making changes:

1. Add entries under `[Unreleased]` during development
2. Use categories: Added, Changed, Deprecated, Removed, Fixed, Security
3. Move unreleased items to versioned section on release
4. Include date in ISO format (YYYY-MM-DD)
5. Reference issues/PRs where applicable

---

**Maintained by**: Netwatch Contributors
**Last Updated**: 2025-12-08
