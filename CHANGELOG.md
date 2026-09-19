# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (pending release)
- Release workflow: on `v*` tags, build and upload artifacts to the GitHub Release.
- Debian packaging script (`scripts/build-deb.sh`) to build `netwatch-agent_<version>_all.deb` via dpkg-deb (no network), including systemd enablement hooks.

## [v1.2.2] - 2026-09-19

Follow-ups from running v1.2.1 on a real host.

### Fixed

- **Offload labels were ambiguous.** The status summary truncated ethtool
  feature names to three characters, so `generic-segmentation-offload` and
  `generic-receive-offload` both rendered as `gen`:
  `offloads: tcp=off gen=off gen=off`. Now maps explicitly to `tso/gso/gro`,
  which are also the names `ethtool -K` accepts, so the output is directly
  actionable.
- **Three scripts were orphaned on uninstall.**
  `netwatch-nic-remediation.sh`, `netwatch-postmortem.sh`, and
  `netwatch-setup-journald.sh` have shipped since v1.1.0 but were never added
  to `uninstall.sh`, leaving them in `/usr/local/sbin` after removal. The
  `.deb` path was unaffected, since dpkg removes packaged files automatically.
- Suggested commands in the summary printed bare names, which only resolve if
  the install directory is on `PATH`. They now print absolute paths.

### Added

- **`netwatch-config-merge.sh`.** dpkg never merges config files: when a local
  edit collides with an upstream change it prompts, and keeping your version -
  which is correct, since it preserves the webhook URL and `DRY_RUN` - means
  new settings are absent and the features behind them stay silently off.
  That is how `DIGEST_FORMAT` shipped in v1.2.1 while embeds remained
  unusable without manual work.

  The tool compares the live config against dpkg's `.dpkg-dist` and appends
  only the missing keys, with their documentation comments, after taking a
  timestamped backup. It never modifies a value already set.

- **Config drift is reported in the status summary**, so the gap is visible at
  install time rather than discovered later.

## [v1.2.1] - 2026-09-18

**Packaging fix.** Upgrading to v1.2.0 via `dpkg -i` silently overwrote
`/etc/default/netwatch-agent`, losing the webhook URL, `DRY_RUN`, and custom
targets. Observed on a real host.

### Fixed

- **Config files are now declared as dpkg conffiles.** Without a
  `DEBIAN/conffiles` entry, dpkg treats them as ordinary package files and
  replaces them on every upgrade. Declared, dpkg preserves a modified file and
  reports the difference instead.
- **Configs are installed 0640, not 0644.** `/etc/default/netwatch-agent` can
  hold a webhook token and should not be world-readable. `install.sh` already
  used 0640; the package now matches.
- **The package ships the digest settings.** `install.sh` appends them to the
  sampler config, but `build-deb.sh` did not - so a `.deb` install had no
  `DIGEST_*` keys and the digest ran on built-in defaults with no visible way
  to change them.
- `postinst` documents that `mkdir -p` leaves existing state alone, so
  `metrics.dat` and the digest baseline survive an upgrade.

### Added

- **`DIGEST_FORMAT=embed`** renders the digest as a Discord embed: a
  verdict-coloured left border (green `HOLDING`, amber `ATTENTION`, red
  `DEGRADED`), values in a field grid, and a timestamp. Default stays `text`,
  since other webhook services do not understand the embeds array.
- JSON escaping extracted into a reusable `json_escape()` now that both payload
  shapes need it.

### Documentation

- **Removed `GAMEPLAN.md`.** It still read "Status: Ready for implementation"
  and planned building v1.0.0 as future work. Git history preserves it; the
  remaining wishlist moved to AGENTS.md §12.
- **AGENTS.md extended to all three components.** It specified only the WAN
  agent and never mentioned the sampler, digest, or e1000e work. Adds §13
  covering both timer-driven components and the remediation tooling, and
  updates Non-Goals (DNS/HTTP checks shipped in v1.0.0; the webhook is a single
  `curl` call, not an alerting stack).
- **`docs/integration-testing.md`**: fixed a broken clone URL and a stale
  expected-log line, and added six manual tests covering interface resolution,
  offload drift, digest verdict and redaction, delta baselines, the remediation
  round-trip, and config survival across a package upgrade.

## [v1.2.0] - 2026-09-18

**Daily diagnostic digest**, plus a fix for a regression introduced in v1.1.0.

### Fixed

- **Dry-run armed the reboot cooldown.** `LAST_REBOOT` was assigned before the
  `DRY_RUN` branch, so a dry-run trip started a `COOLDOWN_SECONDS` window even
  though nothing rebooted. Harmless until v1.1.0 made `LAST_REBOOT` persist
  across restarts - after that, a single trip suppressed threshold reporting
  even through a service restart, hiding exactly the signal dry-run exists to
  surface. Cooldown now applies only when a reboot can actually happen:
  dry-run neither arms nor honours it (the latter also clears cooldowns armed
  by v1.1.0). Real reboots remain cooldown-gated.
- Digest: the first-ever run reported the full counter value as an overnight
  delta (`tx_restart=912(Δ912)`) because an explicit empty baseline was
  defaulted to `0`. It now reports `Δn/a` until a baseline exists.
- Digest: only newline was JSON-escaped, so a tab or carriage return in a
  custom template produced a payload strict parsers reject, silently breaking
  delivery. All control characters are now escaped per RFC 8259.

### Added

- **`netwatch-digest.sh` and a daily timer.** One summary per day with a
  leading `HOLDING` / `ATTENTION` / `DEGRADED` verdict, covering NIC hang
  counts, offload state, driver-counter deltas since the previous digest, and
  WAN outage totals. Default 21:00, changed with
  `systemctl edit netwatch-digest.timer`.
- Runs independently of the agent and reports in either mode;
  `{DRYRUN_TRIPS}` counts `would reboot now` messages, which are the false
  positives worth watching while `DRY_RUN=1`.
- Host identifiers redacted by default - IPs and MACs are never included, and
  the hostname requires `DIGEST_INCLUDE_HOSTNAME=1`.
- `DIGEST_BODY_TEMPLATE` controls verbosity using the same `{PLACEHOLDER}`
  substitution the agent's webhooks already use, so the runtime stays
  Bash + systemd. Templates can target Notifiarr, ntfy, Gotify, or Apprise as
  a relay.

### Changed

- Installer, uninstaller, and `.deb` stage the digest script, unit, and timer;
  digest settings are appended to `/etc/default/netwatch-netprobe` on first
  install only.
- CI: test configs are seeded before `install.sh` starts the service (the
  default 180s boot grace made jobs flaky on fresh runners), and the ICMP
  reachability assertion is gated on `MIN_OK` since GitHub runners often block
  outbound ICMP.

## [v1.1.0] - 2026-09-18

**Local NIC health monitoring and e1000e hang remediation**, plus two agent
correctness fixes found while investigating repeated host outages.

### Fixed

**Agent crash-restart loop (caused false-positive outage reports)**
- Counter increments used the post-increment form `((ok++))`. Under
  `set -Eeuo pipefail` this is fatal: when the counter is 0 the expression
  evaluates to 0 and returns exit status 1, which errexit treats as an error.
  The agent died on the first *successful* probe and systemd restarted it,
  producing a new PID roughly every 30 minutes. Converted all six call sites to
  the pre-increment form already used in the test suite.
- `DOWN_START` and `LAST_REBOOT` were memory-only, so each restart re-derived
  the outage window from boot time and reported a phantom multi-day outage
  (observed: `DRY_RUN: would reboot now (outage: 721303s >= 60s)` on a host
  that was online). Both are now persisted to `metrics.dat` and keyed by boot
  ID, so state is resumed within a boot and discarded across boots.
- The availability calculation in the health report divided by service runtime,
  which is zero if the report fires on the first pass — fatal under `errexit`.
  Now guarded and clamped.
- `netwatch-agent.service` gained `StartLimitIntervalSec`/`StartLimitBurst` so a
  crash-loop surfaces as a failed unit instead of restarting silently forever.
- Corrected the stale `Documentation=` URL in the unit file.

### Added

**NIC health sampler** (`src/netwatch-netprobe.sh`)
- Samples link state, driver error counters (`tx_timeout_count`,
  `tx_restart_queue`, `rx_missed_errors`, `rx_crc_errors`), offload
  configuration, and gateway reachability on a 60s systemd timer.
- Resolves the *physical* NIC behind a bridge: on Proxmox the default route
  points at `vmbr0`, which reports nominal state even while the underlying NIC
  is wedged.
- Scans the kernel log for e1000e hang signatures verified against the upstream
  driver source, classifying `HANG_TSO`, `HANG_TXTIMEOUT`, `RESET_UNEXPECTED`,
  `ME_CORRUPTION`, `LINK_CHANGE`, and `PCIE_AER`.
- Detects offloads silently re-enabling after a link-up event.
- Anomalies log at `daemon.crit`, which forces an immediate journald fsync so
  the record survives a hard power-cycle; routine samples stay at `info`.
- `Type=oneshot` with `TimeoutStartSec=20s` so a hung `ethtool` during an actual
  NIC hang is killed rather than accumulating stuck instances.
- Install with `INSTALL_NETPROBE=0` to skip.

**e1000e remediation tooling** (`scripts/netwatch-nic-remediation.sh`)
- `--status` / `--apply-offloads` / `--revert-offloads`. Nothing is applied
  automatically; `--status` changes nothing.
- Persists via a `post-up` hook, because the driver re-enables offloads on
  link-up events. On a bridged host the hook attaches to the bridge stanza but
  names the physical port explicitly, since the physical port typically has no
  `auto` stanza and `post-up` on a non-auto slave is unreliable under ifupdown2.
- Backs up `/etc/network/interfaces` before every modification; idempotent.

**Forensics and logging tooling**
- `scripts/netwatch-postmortem.sh` — previous-boot analysis with `--all-boots`
  summary, hang-class counts, and current NIC state.
- `scripts/netwatch-setup-journald.sh` — persistent, size-capped journal. Uses a
  `90-` drop-in prefix because systemd sorts drop-ins lexicographically across
  all config directories and the last file wins for single-value options.
- `docs/nic-diagnostics.md` — full runbook with a worked example.

**Tests**
- Three regression tests covering the errexit/increment crash, including a
  source guard that fails if the unsafe form is reintroduced. All three fail
  against the pre-fix source.

### Changed
- `install.sh` now creates `/var/lib/netwatch-agent` (previously only created at
  runtime by the agent) and installs the sampler components.
- `uninstall.sh` now removes the sampler and cleans `/var/lib/netwatch-agent`.
  Diagnostic logs are **preserved** unless `--purge-data` is given, since they
  may be the only record of a past outage.
- `build-deb.sh` stages the new components and recommends `ethtool`.
- README documents the NIC tooling and corrects the Hardware Watchdog section,
  which recommended a setup that conflicts with Proxmox's `watchdog-mux`.
- `.gitattributes` enforces LF on `.timer` and `.logrotate` files.

## [v1.0.0] - 2025-12-09

### Added
- **HTTP/TCP Health Check Modes**: Alternative health check methods to ICMP ping
  - TCP mode: Layer 4 TCP connection tests using netcat (bypasses ICMP filters)
  - HTTP mode: Layer 7 HTTP/HTTPS request validation using curl (full stack verification)
  - Configuration variables: `HEALTH_CHECK_MODE`, `TCP_TARGETS`, `HTTP_TARGETS`, `HTTP_EXPECTED_CODE`
  - Parallel probing for all modes (maintains timing determinism)
  - Automatic dependency validation at startup with clear error messages
  - Backwards compatible: defaults to ICMP mode if not configured
- CI hardening: shared sudo helper for all jobs; consistent restart semantics for dependency validation; stabilized integration timings to reduce flakes
- Installer/uninstaller: root-first, sudo-optional execution for Proxmox environments where sudo may be absent

### Changed
- Renamed `parallel_probe()` to dispatcher function that routes to mode-specific probes
- ICMP probe logic moved to `probe_icmp()` (unchanged behavior)
- `PING_TIMEOUT` now applies to all modes (ICMP, TCP connection, HTTP request)
- systemd notify handling tightened (only when NOTIFY_SOCKET is set); clearer dependency error messages for curl/netcat/fping

### Planned for Future Releases
- Optional .deb packaging (Phase 5.3)
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
| GAMEPLAN.md (removed in v1.2.1) | Implementation phases | Project management |
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
