# Netwatch

[![CI](https://github.com/Masked-Kunsiquat/watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/Masked-Kunsiquat/watchdog/actions/workflows/ci.yml)

**Network watchdog and NIC diagnostics for single-node Proxmox VE hosts.**

Two problems look identical from outside the box — the host stops answering —
but have completely different causes and fixes:

| | Symptom | Netwatch's answer |
|---|---|---|
| **WAN outage** | Upstream is gone; the host itself is fine | Reboot after a configurable window of continuous loss |
| **Local NIC hang** | The kernel is alive but the NIC is wedged | Diagnose the driver fault, apply the documented workaround, confirm it holds |

The second case is the one that bites Proxmox hosts built from small-form-factor
business desktops: Intel I217/I218/I219 NICs on the `e1000e` driver can wedge
their TX ring while the kernel keeps running. You can log in at the keyboard and
`reboot` cleanly — but nothing reaches the network until you do.

Runtime is **Bash + systemd only**. No Python, no daemons beyond systemd units.
On a machine whose job is staying reachable, every dependency is a new way to
fail.

---

## Quick start

```bash
git clone https://github.com/Masked-Kunsiquat/watchdog.git
cd watchdog
sudo ./scripts/install.sh
```

Or from a release:

```bash
wget https://github.com/Masked-Kunsiquat/watchdog/releases/latest/download/netwatch-agent_<version>_all.deb
sudo dpkg -i netwatch-agent_<version>_all.deb
```

Then:

```bash
systemctl status netwatch-agent            # the WAN watchdog
systemctl list-timers netwatch-netprobe    # NIC sampler, every 60s
systemctl list-timers netwatch-digest      # daily summary
```

> **Start in dry-run.** `DRY_RUN=1` in `/etc/default/netwatch-agent` logs what
> *would* happen without rebooting. Run that way until you have seen the agent
> behave correctly on your network — a watchdog you do not trust is worse than
> none.

---

## The three components

Each runs independently. Install all three, or skip the NIC tooling with
`INSTALL_NETPROBE=0 ./scripts/install.sh`.

### 1. WAN watchdog — `netwatch-agent`

A long-running service that probes reachability and reboots the host after a
configurable period of *continuous* loss.

- **ICMP** (default, `fping` or parallel `ping`), **TCP** (netcat), or **HTTP**
  (curl) checks
- `MIN_OK` of N targets must answer, so one dead provider is not an outage
- Safety rails: boot grace, reboot cooldown, a disable file, and dry-run
- Webhooks to Discord, ntfy, Gotify, Notifiarr, Apprise, or anything speaking
  JSON over HTTP

Config: [`/etc/default/netwatch-agent`](config/netwatch-agent.conf) — every
setting documented inline.

### 2. NIC sampler — `netwatch-netprobe`

A timer-driven sample every 60s of the *physical* interface, which is what the
WAN path depends on.

- Link state, `carrier_up/down` counts, and driver error counters
  (`tx_timeout_count`, `tx_restart_queue`, `rx_missed_errors`, `rx_crc_errors`)
- Deltas between samples, so a rising counter is visible rather than buried
- Detects offloads silently re-enabling after a link event
- Scans the kernel log for `e1000e` hang signatures

Anomalies log at `daemon.crit`, which makes journald fsync immediately — so the
record survives a hard power-cycle. Routine samples stay at `info`.

On Proxmox the default route points at `vmbr0`, but counters live on the
enslaved port. The sampler resolves through the bridge to the hardware, because
**a bridge reports nominal state while the NIC beneath it is wedged**.

Config: [`/etc/default/netwatch-netprobe`](config/netwatch-netprobe.conf)

### 3. Daily digest — `netwatch-digest`

One summary a day, so confirming a fix does not mean remembering commands.

```
**Netwatch daily digest** — 2026-09-18 21:00 EDT
Verdict: **HOLDING** (all clear)

NIC (eno1)           link=up  offloads: tso=off gso=off gro=off
Hangs (24h)          hardware-unit-hang=0  tx-timeout=0
Counters             tx_restart=912 (Δ65)  rx_missed=56  rx_crc=0
WAN (24h)            outages=0  downtime=0s  dry-run-trips=0
```

The verdict is `HOLDING`, `ATTENTION`, or `DEGRADED` — the last meaning the hang
returned or offloads re-enabled themselves.

**Redacted by default.** IPs and MACs are never included; the hostname requires
`DIGEST_INCLUDE_HOSTNAME=1`. The digest usually goes to a third-party service.

**Independent of the agent.** It reports whether or not `DRY_RUN` is set, and
`{DRYRUN_TRIPS}` counts the false positives dry-run exists to surface.

```bash
systemctl start netwatch-digest.service    # send one now
systemctl edit netwatch-digest.timer       # change the delivery time
journalctl -t netwatch-digest | tail       # local copy, always kept
```

Trim verbosity with `DIGEST_BODY_TEMPLATE` — a template of `{PLACEHOLDERS}`,
where anything you omit simply does not appear. Full list in
[`netwatch-digest.conf`](config/netwatch-digest.conf).

---

## Diagnosing an e1000e hang

If the host drops off the network but a keyboard `reboot` works cleanly, and the
link light stays on, this is the failure mode.

```bash
# What signature appears across retained boots?
sudo scripts/netwatch-postmortem.sh --all-boots

# Current NIC, offload, and counter state
sudo scripts/netwatch-nic-remediation.sh --status
```

Read the result:

| Signature | Means |
|---|---|
| `Detected Hardware Unit Hang` (hundreds+) | **TSO/offload erratum** — disable offloads |
| `NIC Link is Up/Down` repeatedly, no hangs | Link flapping — check EEE, cabling, switch |
| `ME firmware caused invalid RDT/TDT` | ME/CSME corrupting the ring — check BIOS AMT |
| `PCIe Bus Error` / `AER: Uncorrected` | PCIe problem — reseat, check the slot |

For a confirmed hang:

```bash
sudo scripts/netwatch-nic-remediation.sh --apply-offloads   # immediate + persistent
sudo scripts/netwatch-nic-remediation.sh --revert-offloads  # undo
```

Apply snapshots the prior state, so revert restores exactly what was there
rather than blanket-enabling everything. Persistence uses a `post-up` hook,
because **the driver re-enables offloads on link-up** — a one-time command is
not enough.

Full runbook with a worked example:
**[docs/nic-diagnostics.md](docs/nic-diagnostics.md)**

### Persistent logging comes first

Post-mortem analysis needs a journal that survives reboots. Without
`Storage=persistent`, `journalctl -b -1` returns nothing:

```bash
sudo scripts/netwatch-setup-journald.sh --check   # report only
sudo scripts/netwatch-setup-journald.sh --apply   # enable and cap the size
```

---

## Configuration

Settings live in two annotated files. Each documents every option inline, so
they are the authoritative reference rather than a table here that drifts out of
date:

| File | Covers | Template |
|---|---|---|
| `/etc/default/netwatch-agent` | Probing, timing, safety rails, webhooks | [source](config/netwatch-agent.conf) |
| `/etc/default/netwatch-netprobe` | NIC sampling, gateway checks, digest | [source](config/netwatch-netprobe.conf) |

The settings you are most likely to change:

```bash
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"   # probe these
MIN_OK=2                             # this many must answer
DOWN_WINDOW_SECONDS=600              # continuous loss before acting
DRY_RUN=1                            # log only; do not reboot
```

Apply with `systemctl restart netwatch-agent`.

---

## Operations

```bash
# Watch
journalctl -u netwatch-agent -f
journalctl -t netwatch-netprobe -f
journalctl -t netwatch-netprobe -p crit --no-pager   # anomalies only

# Pause without uninstalling
touch /etc/netwatch-agent.disable
rm /etc/netwatch-agent.disable

# Is the fix holding?
journalctl -k -b 0 --no-pager | grep -c 'Detected Hardware Unit Hang'   # want 0
ethtool -S eno1 | grep -E 'tx_timeout_count|tx_restart_queue'           # want flat

# Remove
sudo ./scripts/uninstall.sh --keep-config   # diagnostic logs are preserved
sudo ./scripts/uninstall.sh --purge-data    # remove them too
```

---

## Troubleshooting

**Service will not start** — `journalctl -u netwatch-agent -n 50`. Usually a
missing dependency for the chosen mode: TCP needs `netcat-openbsd`, HTTP needs
`curl`. The agent names which.

**Outage reported while the host is online** — check whether probes are actually
failing (`journalctl -u netwatch-agent | grep -i fping`). Raise `MIN_OK` or
lengthen `DOWN_WINDOW_SECONDS` if one flaky provider is tripping it.

**No reboot during a real outage** — confirm `DRY_RUN=0`, that
`/etc/netwatch-agent.disable` is absent, and that you are past `BOOT_GRACE`.
`Cooldown active` means a reboot happened within `COOLDOWN_SECONDS`.

**Offloads back `on` after a reboot** — the `post-up` hook is not firing. Check
it is attached to a stanza marked `auto`; see
[docs/nic-diagnostics.md](docs/nic-diagnostics.md).

**`journalctl -b -1` is empty** — persistent logging is off. Run
`scripts/netwatch-setup-journald.sh --apply`.

---

## How it works

```
        ┌──────────────┐  probe fails  ┌───────────┐  >= DOWN_WINDOW  ┌────────┐
        │  MONITORING  │──────────────►│ WAN DOWN  │─────────────────►│ REBOOT │
        └──────────────┘               └───────────┘                  └────────┘
               ▲                             │                             │
               └─────────────────────────────┘                             │
                      any probe succeeds                                   │
               ▲                                                           │
               └───────────────────────────────────────────────────────────┘
                              cooldown, then resume
```

Design decisions that matter:

- **Parallel probes** — loop time is roughly `PING_TIMEOUT`, not
  `PING_TIMEOUT × targets`
- **Wall-clock outages** — only *continuous* loss counts; any success resets the
  timer, so flapping never accumulates into a reboot
- **State survives restarts** — outage timers and cooldowns persist, keyed by
  boot ID so stale state from a previous boot is discarded
- **Cooldown gates reboots, not reports** — dry-run never arms it, since
  suppressing dry-run output would hide the signal it exists to produce

### Installed files

| Path | Purpose |
|---|---|
| `/usr/local/sbin/netwatch-{agent,netprobe,digest}.sh` | The three components |
| `/etc/default/netwatch-{agent,netprobe}` | Configuration |
| `/etc/systemd/system/netwatch-*.{service,timer}` | Units and timers |
| `/var/lib/netwatch-agent/` | Persistent metrics and state |
| `/var/log/netwatch/net-health.log` | Sampler mirror (journal is authoritative) |
| `/etc/netwatch-agent.disable` | Pause flag |

---

## Hardware watchdog

Netwatch handles network failures. A hardware watchdog handles **kernel panics
and total freezes** — a different layer.

> **Check for a conflict first.** Proxmox's HA stack claims `/dev/watchdog` via
> `watchdog-mux`. If it is active, do not point a second daemon at the same
> device.
>
> ```bash
> systemctl is-active watchdog-mux
> ```

If it is inactive:

```bash
sudo modprobe iTCO_wdt && echo "iTCO_wdt" | sudo tee -a /etc/modules
sudo apt install watchdog
sudo systemctl enable --now watchdog
```

Note that `softdog` only detects userspace liveness — it will **not** fire on a
NIC-only hang, which is precisely why the NIC tooling above exists.

---

## Development

```bash
cd tests && bash unit-tests.sh      # 32 unit tests
cd tests && bash smoke-test.sh      # 6 end-to-end tests
find . -name '*.sh' -exec shellcheck -x -e SC1091 -e SC2317 {} +
```

Standards: Bash with `set -Eeuo pipefail`, absolute binary paths, shellcheck
clean, LF line endings. Every bug fix gets a regression test, and that test must
be confirmed to **fail against the unfixed code** — a test that cannot detect
its bug is not a test.

Specification: [AGENTS.md](AGENTS.md) ·
Testing: [docs/integration-testing.md](docs/integration-testing.md) ·
History: [CHANGELOG.md](CHANGELOG.md)

---

## Requirements

Debian/Proxmox with systemd 219+, Bash 4.0+, and root. `ping` is always present;
`fping` (faster probes), `ethtool` (NIC tooling), and `curl` (webhooks) are
recommended — the `.deb` pulls these in.

## License

MIT — see [LICENSE](LICENSE). Contributions welcome; please keep the runtime
Bash + systemd only.
