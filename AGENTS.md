# AGENTS.md — Netwatch (Proxmox network watchdog and NIC diagnostics)

Target: Single-node Proxmox VE host (Debian-based)
Status: Authoritative spec. Sections 0–11 specify the WAN agent, which was the
original scope; section 13 specifies the NIC sampler and daily digest added
later.

---

## 0) Objective

Netwatch addresses two failures that look identical from outside the host but
have different causes:

1. **WAN outage** — upstream connectivity is gone. Reboot the host after a
   strict, configurable duration of **continuous** loss, with safety rails.
2. **Local NIC hang** — the kernel is alive but the interface is wedged. On
   Intel I217/I218/I219 NICs the `e1000e` TX ring can stall while the machine
   keeps running. Diagnose it, apply the documented workaround, and confirm it
   holds.

Runtime must remain **shell + systemd only** on the host. This is a constraint,
not a preference: on a machine whose job is staying reachable, every added
dependency is another way for the watchdog itself to fail.

---

## 1) Deliverables

**WAN agent** (sections 2–11):

1. **Agent script**: `/usr/local/sbin/netwatch-agent.sh` (Bash)
2. **Config file**: `/etc/default/netwatch-agent` (key=value; root-only, 0640)
3. **systemd unit**: `/etc/systemd/system/netwatch-agent.service`

**NIC tooling** (section 13):

4. **Sampler**: `/usr/local/sbin/netwatch-netprobe.sh` + service and timer
5. **Digest**: `/usr/local/sbin/netwatch-digest.sh` + service and timer
6. **Shared config**: `/etc/default/netwatch-netprobe` (sampler and digest)
7. **Remediation**: `scripts/netwatch-nic-remediation.sh`
8. **Forensics**: `scripts/netwatch-postmortem.sh`, `scripts/netwatch-setup-journald.sh`

**Packaging and docs**:

9. **Installer** / **uninstaller**: idempotent, sudo-optional
10. **`.deb` build**: pure `dpkg-deb`, no network. Config files MUST be declared
    in `DEBIAN/conffiles` — without that, dpkg silently overwrites local edits
    on every upgrade.
11. **Docs**: README, CHANGELOG, LICENSE, `docs/nic-diagnostics.md`

---

## 2) Non‑Goals

- Cluster fencing/HA policy (handled separately by PVE‑HA)
- Long-running alerting stack (journald/syslog authoritative; no log shipping
  or forwarding agent on the host)
- Automatic NIC remediation — the tooling diagnoses and can apply a fix, but
  only when an operator runs it
- Any runtime dependency beyond Bash, systemd, and standard utilities

> **DNS/HTTP checks** were a non-goal in the initial release and shipped in
> v1.0.0 as optional `HEALTH_CHECK_MODE` values. ICMP remains the default.

> **On the logging non-goal.** The NIC sampler writes a plain-text mirror to
> `/var/log/netwatch/net-health.log`, and the digest can POST to a webhook.
> Neither relaxes the non-goal: the journal stays authoritative, the file is a
> convenience for `tail`/`grep` correlation (rotated by logrotate, disabled
> with `NETPROBE_LOG_TO_FILE=0`), and the webhook is a single `curl` call with
> no queue, retry, or daemon behind it.

---

## 3) Requirements

### Functional

- Probe **multiple IP targets** in **parallel** each loop (prefer `fping`, fallback to background `ping`).
- Consider WAN **up** if at least `MIN_OK` targets reply in a loop.
- Maintain `down_start` wall-clock; trigger reboot when `now - down_start >= DOWN_WINDOW_SECONDS`.
- Reset outage timer immediately on any successful probe.
- Provide **boot grace** and **cooldown**.
- Respect a **disable file** and **dry-run** mode.

### Reliability & Safety

- Deterministic loop time (parallel probes; timeout-bounded).
- Idempotent installer; safe permissions; absolute paths; strict shell options.
- Never reboot more often than `COOLDOWN_SECONDS`.
- If the box **hard-hangs**, document optional **hardware watchdog** enablement (Intel `iTCO_wdt` or vendor module) and Linux `watchdog` daemon.

### Security

- Run as root (needed for reboot). No external input at runtime.
- Config is root-readable, 0640. No sourcing of untrusted paths.
- Use IPs (not DNS) for outage detection to avoid resolver coupling.

### Observability

- Log single-line events via `logger -t netwatch-agent`; integrate with journald.
- Optional `Type=notify` + `systemd-notify` heartbeat (future toggle with `WatchdogSec=`).

---

## 4) Conventions & Standards

- Language: Bash, `set -Eeuo pipefail`, `IFS` unchanged, quote all expansions.
- Style: shellcheck-clean; use functions, early returns, explicit scopes; avoid Useless Use of Cat; no subshells in hot paths unless needed.
- Paths/Perms:
  - Script: `/usr/local/sbin/netwatch-agent.sh` (0755 root\:root)
  - Config: `/etc/default/netwatch-agent` (0640 root\:root)
  - Unit: `/etc/systemd/system/netwatch-agent.service` (0644 root\:root)
  - Disable flag: `/etc/netwatch-agent.disable`
  - State dir: `/run/netwatch-agent` (volatile)
- Absolute binaries: `/usr/sbin/fping`, `/bin/ping`, `/usr/bin/logger`, `/usr/bin/systemd-notify`, `/bin/sleep`, `/bin/sync`, `/usr/bin/systemctl`, `/sbin/reboot`.

---

## 5) Configuration Schema (defaults shown)

```bash
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"   # space-separated IPs
MIN_OK=1                              # hosts that must reply per loop
PING_COUNT=1                          # probes per target
PING_TIMEOUT=1                        # seconds per target
CHECK_INTERVAL=10                     # seconds between loops
DOWN_WINDOW_SECONDS=600               # wall-clock outage before reboot
BOOT_GRACE=180                        # seconds after boot to wait
COOLDOWN_SECONDS=1200                 # min seconds between reboots
USE_FPING="auto"                     # auto|yes|no
DRY_RUN=0                             # 1=log only, no reboot
DISABLE_FILE="/etc/netwatch-agent.disable"
```

**Notes**

- Loop wall-time should be ≈ `PING_TIMEOUT` + small overhead, not multiplied by number of targets.
- Any success resets the outage timer; flapping links won’t trigger unless loss is continuous for the full window.

---

## 6) Architecture

**Main loop**

1. If `DISABLE_FILE` exists → log and sleep 30s.
2. Run parallel ICMP probes across `TARGETS`.
3. If `ok >= MIN_OK` → if previously down, log recovery; `down_start=-1`.
4. Else (offline): set `down_start` if unset; when `now - down_start >= DOWN_WINDOW_SECONDS`, check cooldown and reboot.
5. Sleep `CHECK_INTERVAL`, emit optional `systemd-notify --watchdog`.

**Reboot path**

- `sync` disks, `systemctl reboot -i || /sbin/reboot now`.

**Systemd unit**

```ini
[Unit]
Description=WAN Watchdog (reboot host after continuous WAN loss)
After=network.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/netwatch-agent
ExecStart=/usr/local/sbin/netwatch-agent.sh
Restart=always
RestartSec=5
# Optional: enable later if we want service-level watchdog
# WatchdogSec=30s

[Install]
WantedBy=multi-user.target
```

---

## 7) Agent Responsibilities (for Codex)

- **Bash Implementation Agent**

  - Implement `parallel_probe()`:
    - If `fping` present and `USE_FPING!=no`: `fping -c $PING_COUNT -t $((PING_TIMEOUT*1000)) -q ${targets[@]}`; parse lines to count successes (rcv ≥ 1).
    - Else: background `ping -n -q -c $PING_COUNT -W $PING_TIMEOUT` per host; `wait` and count zero-exit statuses.
  - Implement main loop with wall-clock outage, boot grace, cooldown, disable file, dry-run.
  - Log transitions: down start, recovery, threshold met, cooldown blocks, reboot.
  - Use absolute paths; strict error options; handle signals gracefully.

- **Systemd Packaging Agent**

  - Write the unit file above.
  - Ensure `daemon-reload`, `enable --now`, and status output in installer.
  - Optional: add `systemd-notify` readiness/heartbeat.

- **Installer Agent**

  - Single `install.sh` performing: tool checks (ensure `ping`; try-install `fping` on apt systems), render files, set perms, enable/start service.
  - Support env/flags overrides for common settings at install time.
  - Provide `uninstall.sh` to disable, remove files, and reload daemon.

- **QA Agent**

  - Unit tests for parsing `fping` summary lines; simulate `ping` exits.
  - Smoke test: `DRY_RUN=1`, `DOWN_WINDOW_SECONDS=8`, `TARGETS`=RFC5737 test IPs → expect “would reboot now” within \~8–10s.
  - Verify cooldown blocks repeated reboots; verify boot grace delays start.

- **Docs Agent**

  - README quick start, testing, ops playbook, troubleshooting (“service not running”, “dry run enabled”, “cooldown active”).
  - CHANGELOG and semantic versioning.

- **Hardware Watchdog Agent (optional)**

  - Document enabling Linux `watchdog` daemon and chipset module (e.g., `iTCO_wdt`).
  - Emphasize that H/W watchdog complements this policy for hard lockups.

---

## 8) Test Plan & Acceptance Criteria

**Smoke (local)**

- With `DRY_RUN=1`, `DOWN_WINDOW_SECONDS=8`, `CHECK_INTERVAL=1`, `TARGETS` set to `203.0.113.1 198.51.100.1 192.0.2.1`, logs show:\
  `WAN appears down; starting timer.` → \~8s later → `DRY_RUN=1: would reboot now`.

**Determinism**

- Under blackhole conditions (timeouts), trigger occurs within **±5%** of `DOWN_WINDOW_SECONDS`.

**Recovery**

- Any successful probe resets `down_start`; recovery is logged with duration.

**Safety**

- Reboots never happen more frequently than `COOLDOWN_SECONDS`.
- Service restarts automatically if it crashes.
- `touch /etc/netwatch-agent.disable` pauses actions; removal resumes.

**Packaging**

- Fresh system: `install.sh` creates files with correct perms, enables and starts service, and `journalctl -u netwatch-agent` shows readiness.

---

## 9) Ops Playbook

- **Follow logs**: `journalctl -u netwatch-agent -f`
- **Pause/Resume**: `touch /etc/netwatch-agent.disable` / `rm /etc/netwatch-agent.disable`
- **Change timings**: edit `/etc/default/netwatch-agent` → `systemctl restart netwatch-agent`
- **Uninstall**: run `uninstall.sh`

---

## 10) Risks & Mitigations

- **Kernel hang** → add hardware watchdog (system-level).
- **False positives due to target failures** → use multiple providers, keep `MIN_OK=1..2`.
- **DNS dependency** → use IPs only.
- **Long ICMP timeouts** → parallel probes + small `PING_TIMEOUT` keep loops bounded.

---

## 11) Minimal Skeleton (reference)

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
TAG="netwatch-agent"; STATE_DIR=/run/netwatch-agent; mkdir -p "$STATE_DIR"
[[ -r /etc/default/netwatch-agent ]] && . /etc/default/netwatch-agent
: "${TARGETS:=1.1.1.1 8.8.8.8 9.9.9.9}" "${MIN_OK:=1}" "${PING_COUNT:=1}" "${PING_TIMEOUT:=1}" \
  "${CHECK_INTERVAL:=10}" "${DOWN_WINDOW_SECONDS:=600}" "${BOOT_GRACE:=180}" "${COOLDOWN_SECONDS:=1200}" \
  "${DISABLE_FILE:=/etc/netwatch-agent.disable}" "${DRY_RUN:=0}" "${USE_FPING:=auto}"
log(){ logger -t "$TAG" -- "$*"; }
now(){ date +%s; }
parallel_probe(){
  local ok=0; local -a t=($TARGETS)
  if [[ "$USE_FPING" != "no" ]] && command -v fping >/dev/null 2>&1; then
    local tms=$(( PING_TIMEOUT*1000 )); local out
    out=$(fping -c "$PING_COUNT" -t "$tms" -q "${t[@]}" 2>&1 || true)
    while read -r line; do [[ "$line" == *xmt/rcv/%loss* ]] || continue; [[ "$line" =~ :\ ([1-9][0-9]*)/ ]] && ok=$((ok+1)); done <<<"$out"
  else
    declare -a pids=(); for h in "${t[@]}"; do ( ping -n -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$h" >/dev/null 2>&1 ) & pids+=($!); done
    for pid in "${pids[@]}"; do if wait "$pid"; then ok=$((ok+1)); fi; done
  fi
  (( ok >= MIN_OK ))
}
command -v systemd-notify >/dev/null 2>&1 && systemd-notify --ready || true
UP=$(cut -d. -f1 /proc/uptime); (( UP < BOOT_GRACE )) && sleep $(( BOOT_GRACE - UP ))
DOWN_START=-1; LAST_REBOOT=0
while true; do
  [[ -f "$DISABLE_FILE" ]] && { log "Disabled via $DISABLE_FILE"; sleep 30; continue; }
  if parallel_probe; then (( DOWN_START!=-1 )) && log "WAN reachable again after $(( $(now)-DOWN_START ))s"; DOWN_START=-1
  else
    (( DOWN_START==-1 )) && { DOWN_START=$(now); log "WAN appears down; starting timer."; }
    if (( $(now)-DOWN_START >= DOWN_WINDOW_SECONDS )); then
      if (( $(now)-LAST_REBOOT >= COOLDOWN_SECONDS )); then LAST_REBOOT=$(now); log "Threshold met; rebooting."; (( DRY_RUN==1 )) && { log "DRY_RUN: would reboot"; } || { sync||true; systemctl reboot -i || /sbin/reboot now; }; sleep 30
      else log "Cooldown active"; fi
    fi
  fi
  command -v systemd-notify >/dev/null 2>&1 && systemd-notify --watchdog || true
  sleep "$CHECK_INTERVAL"
done
```

---

## 12) Future Extensions

Not committed to, and each must preserve the Bash + systemd constraint:

- Per-interface routing table awareness
- Prometheus metrics exporter
- Multi-host orchestration or a dashboard
- Jitter-aware adaptive timers
- A builder that ships the `.deb` over SSH (the host stays Bash-only)

Delivered since the original plan: HTTP/TCP health checks (v1.0.0), webhook
alerting (v0.5.0), NIC sampling and e1000e remediation (v1.1.0), daily digest
(v1.2.0).

---

## 13) NIC Sampler and Daily Digest

Added after the original spec. Both are **timer-driven and independent of the
agent**: they report regardless of `DRY_RUN`, and either can be disabled
without affecting the watchdog.

### 13.1 Why a separate component

The agent probes WAN reachability. A wedged local NIC looks identical to it —
targets stop answering — so the agent alone cannot distinguish "the ISP is
down" from "my NIC hung". The sampler observes the hardware directly.

### 13.2 Sampler (`netwatch-netprobe.sh`)

Runs every 60s via `netwatch-netprobe.timer` (`Type=oneshot`).

**Must resolve the physical interface, not the bridge.** On Proxmox the default
route points at `vmbr0`, but counters live on the enslaved port — and the
bridge reports nominal state while the NIC beneath it is wedged. Descend
through `/sys/class/net/<bridge>/brif/`, skipping `veth*`, `tap*`, `fwln*`,
`fwpr*`, `vnet*`.

Samples: link state and carrier counts from sysfs; `tx_timeout_count`,
`tx_restart_queue`, `rx_missed_errors`, `rx_crc_errors` from `ethtool -S`;
offload state from `ethtool -k`; gateway reachability; and a scan of
`journalctl -k` for e1000e hang signatures.

Requirements:

- **Deltas need a real baseline.** Track whether counters were actually read.
  If `ethtool` is unavailable, carry the previous values forward rather than
  storing placeholder zeros — otherwise the next successful sample reports the
  real value as an overnight spike.
- **Anomalies log at `daemon.crit`**, which forces an immediate journald fsync
  so the record survives a hard power-cycle. Routine samples stay at `info`.
- **`TimeoutStartSec`** must be set: a wedged NIC can block `ethtool`
  indefinitely, and a oneshot unit would otherwise accumulate stuck instances.
- Never set `PrivateNetwork=true`; the unit needs the real host network.

### 13.3 Digest (`netwatch-digest.sh`)

Runs daily via `netwatch-digest.timer` (`OnCalendar`, default 21:00). Emits a
`HOLDING` / `ATTENTION` / `DEGRADED` verdict plus NIC, counter, and WAN
summaries.

Requirements:

- **Redact by default.** IPs and MACs are never included. The hostname requires
  an explicit `DIGEST_INCLUDE_HOSTNAME=1`, because the digest typically goes to
  a third-party service.
- **Escape every dynamic value** through `json_escape` before it enters the
  payload — including config-sourced values like `DIGEST_WINDOW_HOURS`. RFC 8259
  forbids raw U+0000–U+001F in strings, so control characters need escaping,
  not just quotes and backslashes.
- **`DIGEST_FORMAT`**: `text` (default, any webhook service) or `embed`
  (Discord only — a verdict-coloured border and field grid). The payload shapes
  differ, so `embed` must stay opt-in.
- Configuration lives in `/etc/default/netwatch-netprobe`; the digest does not
  source a file of its own.

### 13.4 Remediation and forensics

`scripts/netwatch-nic-remediation.sh` — `--status` / `--apply-offloads` /
`--revert-offloads`. Nothing is applied automatically.

- Snapshot the pre-change offload state before applying, so revert restores
  exactly what was there rather than blanket-enabling everything.
- **Refuse to apply if the snapshot fails** — an unrevertable change is worse
  than no change.
- Persist via a `post-up` hook, because the driver re-enables offloads on
  link-up events. On a bridged host the physical port typically has no `auto`
  stanza, where `post-up` is unreliable, so attach the hook to the bridge
  stanza while naming the physical port explicitly.

`scripts/netwatch-postmortem.sh` reads the previous boot; it requires
persistent journald, which `scripts/netwatch-setup-journald.sh` configures.
Reports written with `--output` must be mode 0600 — they embed journal
excerpts, MACs, and IPs.

