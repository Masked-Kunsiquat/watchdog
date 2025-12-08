# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned for v1.0.0
- Comprehensive operations documentation (Phase 5)
- Optional .deb packaging
- Production hardening and final QA

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

- **0.1.0-dev**: Initial development phase
- **0.1.0**: Planned first release (MVP)
- **0.2.0**: Planned .deb packaging support
- **1.0.0**: Planned production-ready release

---

**Maintained by**: Netwatch Contributors
**Last Updated**: 2025-12-08
