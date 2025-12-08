# GAMEPLAN.md — Netwatch Implementation Phases

**Project**: Proxmox WAN Watchdog (Netwatch)
**Source Spec**: [AGENTS.md](AGENTS.md)
**Status**: Ready for implementation
**Target**: Production-ready systemd service for Debian/Proxmox hosts

---

## Overview

This document breaks down the implementation of Netwatch into **6 distinct phases**, from project bootstrap to advanced features. Each phase has clear goals, tasks, and deliverables.

---

## **Phase 0: Project Bootstrap** (Foundation)

**Goal**: Set up project structure and tooling

**Tasks**:
- Create directory structure (`src/`, `scripts/`, `tests/`, `docs/`)
- Add `.gitignore` for build artifacts
- Create `LICENSE` (likely MIT or GPL based on target)
- Set up basic `README.md` skeleton
- Initialize `CHANGELOG.md` (0.1.0-dev)

**Deliverables**: Clean repo structure ready for code

**Time Estimate**: 1-2 hours

---

## **Phase 1: Core Agent Script** (Critical Path)

**Goal**: Implement the main watchdog logic

**Tasks**:

1. **Create `/usr/local/sbin/netwatch-agent.sh` skeleton**
   - Strict bash options: `set -Eeuo pipefail`
   - Absolute PATH, logging function, timestamp function

2. **Implement `parallel_probe()` function**
   - Auto-detect `fping` availability
   - `fping` mode: parse summary lines for rcv count
   - Fallback `ping` mode: parallel background pings with `wait`
   - Return success if `>= MIN_OK` targets respond

3. **Implement main loop logic**
   - Boot grace period handling
   - Disable file check (`/etc/netwatch-agent.disable`)
   - WAN state machine: UP → DOWN → REBOOT
   - Wall-clock outage tracking (`down_start`)
   - Cooldown enforcement between reboots
   - Dry-run mode support

4. **Implement reboot path**
   - `sync` disks
   - `systemctl reboot -i || /sbin/reboot now`
   - Proper logging before action

5. **Add systemd notification support**
   - `systemd-notify --ready` on startup
   - Optional `--watchdog` heartbeat in loop

**Reference**: Skeleton provided in AGENTS.md lines 224-265

**Validation**: Script runs standalone with `DRY_RUN=1`, logs state transitions

**Time Estimate**: 1-2 days

---

## **Phase 2: Configuration & Systemd Integration**

**Goal**: Make it production-ready with proper systemd packaging

**Tasks**:

1. **Create `/etc/default/netwatch-agent` template**
   - All defaults from section 5 of spec:
     ```bash
     TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
     MIN_OK=1
     PING_COUNT=1
     PING_TIMEOUT=1
     CHECK_INTERVAL=10
     DOWN_WINDOW_SECONDS=600
     BOOT_GRACE=180
     COOLDOWN_SECONDS=1200
     USE_FPING="auto"
     DRY_RUN=0
     DISABLE_FILE="/etc/netwatch-agent.disable"
     ```
   - Inline documentation comments
   - Secure permissions (0640 root:root)

2. **Create systemd unit file**
   - `Type=notify` with network dependencies
   - `EnvironmentFile=-/etc/default/netwatch-agent`
   - `Restart=always` with 5s delay
   - Optional `WatchdogSec=30s` (commented for future)

3. **Integrate configuration loading in agent**
   - Source `/etc/default/netwatch-agent` safely
   - Apply defaults with `${VAR:=default}` pattern
   - Validate critical settings (MIN_OK, targets count)

**Validation**: Service runs under systemd, respects config changes on restart

**Time Estimate**: 1 day

---

## **Phase 3: Installer & Uninstaller**

**Goal**: Provide idempotent deployment tooling

**Tasks**:

1. **Create `install.sh`**
   - Check prerequisites (`ping`, attempt `apt install fping` if apt-based)
   - Copy agent script to `/usr/local/sbin/`
   - Install config to `/etc/default/` (preserve existing if present)
   - Install systemd unit
   - Set proper permissions (script 0755, config 0640, unit 0644)
   - `systemctl daemon-reload && systemctl enable --now netwatch-agent`
   - Display status and quick-start instructions
   - Support env var overrides at install time

2. **Create `uninstall.sh`**
   - `systemctl disable --now netwatch-agent`
   - Remove script, config, unit files
   - `systemctl daemon-reload`
   - Optional: preserve config with `.bak` suffix
   - Clean `/run/netwatch-agent` state dir

**Validation**:
- Install on clean system → works
- Uninstall → clean removal
- Re-install → idempotent

**Time Estimate**: 1 day

---

## **Phase 4: Testing & Quality Assurance**

**Goal**: Ensure reliability through automated and manual testing

**Tasks**:

1. **Unit Tests** (test helper script)
   - Mock `fping` output parsing (various success/fail scenarios)
   - Mock `ping` exit codes
   - Test outage timer logic with frozen time
   - Test cooldown enforcement

2. **Smoke Test** (documented procedure)
   - Config: `DRY_RUN=1`, `DOWN_WINDOW_SECONDS=8`, `CHECK_INTERVAL=1`
   - Targets: RFC5737 test IPs (203.0.113.1, 198.51.100.1, 192.0.2.1 - unreachable)
   - Expected: "would reboot" log within 8-10s
   - Verify recovery on adding reachable target

3. **Integration Test** (manual on VM)
   - Install on fresh Debian/Proxmox system
   - Simulate WAN loss (firewall rule to drop ICMP)
   - Verify deterministic reboot timing (±5% of DOWN_WINDOW)
   - Test disable file pauses action
   - Test cooldown prevents rapid reboots

4. **Shellcheck & Linting**
   - Run `shellcheck -x` on all scripts
   - Fix all warnings/errors

**Deliverables**: Test suite in `tests/`, documented test procedures

**Time Estimate**: 2-3 days

---

## **Phase 5: Documentation & Polish**

**Goal**: Production-ready documentation for operators

**Tasks**:

1. **README.md** (comprehensive)
   - Quick start (install in 3 commands)
   - Architecture overview
   - Configuration reference (all variables documented)
   - Testing guide (smoke test, dry-run testing)
   - Ops playbook (logs, pause/resume, tuning)
   - Troubleshooting (common issues)
   - Hardware watchdog complementary setup

2. **CHANGELOG.md**
   - Version 0.1.0 initial release notes
   - Semantic versioning commitment

3. **Optional: .deb packaging**
   - Create `build-deb.sh` using `dpkg-deb`
   - Package structure with pre/post install scripts
   - Test on clean Debian system

4. **Hardware Watchdog Documentation**
   - Guide for enabling `iTCO_wdt` module
   - Configuring Linux `watchdog` daemon
   - Interaction with netwatch-agent

**Deliverables**: Complete docs, optional `.deb` package

**Time Estimate**: 2-3 days

---

## **Phase 6 (Future/Optional): Advanced Features**

**Goal**: Extensions beyond MVP (post-v1.0)

**Potential Features**:
- HTTP/TCP health checks (layer 7 validation)
- Per-interface routing table awareness
- Prometheus metrics exporter
- Web dashboard for multi-host monitoring
- Multi-host orchestration
- Jitter-aware adaptive timers
- Alert integration (email, webhook, Slack)

**Priority**: Post-1.0 based on user feedback

---

## Implementation Timeline

**Week 1**: Phases 0-1 (foundation + core logic)
**Week 2**: Phases 2-3 (systemd integration + installers)
**Week 3**: Phases 4-5 (testing + docs)
**Optional**: Phase 6 based on production feedback

---

## Critical Success Factors

1. **Reliability**: Zero false positives causing unnecessary reboots
2. **Safety**: Cooldown and boot grace prevent boot loops
3. **Observability**: Clear logging for troubleshooting
4. **Simplicity**: Shell-only runtime, no dependencies beyond coreutils
5. **Security**: Root-only config, no external input at runtime

---

## Dependencies & Prerequisites

**Runtime** (on target host):
- Bash 4.0+
- `ping` (always present)
- `fping` (recommended, optional)
- `systemd` 219+
- `logger` (syslog/journald integration)

**Development**:
- `shellcheck` for linting
- Debian/Proxmox VM for integration testing
- Git for version control

---

## File Structure (Final)

```
watchdog/
├── AGENTS.md                    # Original spec
├── GAMEPLAN.md                  # This file
├── README.md                    # User documentation
├── CHANGELOG.md                 # Version history
├── LICENSE                      # Software license
├── src/
│   └── netwatch-agent.sh        # Main agent script
├── config/
│   ├── netwatch-agent.conf      # Default config template
│   └── netwatch-agent.service   # Systemd unit
├── scripts/
│   ├── install.sh               # Installer
│   └── uninstall.sh             # Uninstaller
├── tests/
│   ├── smoke-test.sh            # Dry-run smoke test
│   └── unit-tests.sh            # Unit test helpers
└── docs/
    ├── ops-playbook.md          # Operations guide
    ├── troubleshooting.md       # Common issues
    └── hardware-watchdog.md     # HW watchdog setup
```

---

## Next Steps

1. **Immediate**: Start Phase 0 (project structure)
2. **Day 1-2**: Complete Phase 1 (core agent)
3. **Day 3-4**: Complete Phases 2-3 (systemd + installers)
4. **Day 5-7**: Complete Phases 4-5 (testing + docs)
5. **Release**: v0.1.0 tagged release

---

## Notes

- Reference skeleton in AGENTS.md (lines 224-265) accelerates Phase 1
- All absolute paths per spec conventions (section 4)
- shellcheck-clean requirement enforced in Phase 4
- Optional .deb packaging can be deferred to v0.2.0 if needed

---

**Last Updated**: 2025-12-08
**Maintained By**: Development Team
**Source of Truth**: AGENTS.md
