# NIC Diagnostics: Intel e1000e Hardware Unit Hang

Diagnosing and fixing intermittent total network loss on a host whose kernel
stays alive — specifically the Intel e1000e TX-ring hang affecting I217/I218/I219
NICs, which is common on Proxmox hosts built from small-form-factor business
desktops.

---

## Symptom

The host drops off the network completely: unpingable, no SSH, no web UI, gone
from the router's client table. But it is **not** crashed:

- A keyboard attached to the host can log in blind and run `reboot`
- That reboot performs a clean systemd shutdown
- The link light stays on and the interface still reports `UP`
- On a Proxmox host, every VM and container loses networking simultaneously

Outages are unpredictable — several in a day, then stable for one to two weeks.

The key distinction: the kernel is alive and scheduling. Only the NIC is wedged.
That rules out a panic and points at the driver or hardware.

---

## Step 1 — Confirm the journal survives reboots

Everything below depends on reading logs from the boot that failed. Without
persistent storage the journal lives in a tmpfs and is erased at every boot, so
`journalctl -b -1` returns nothing.

```bash
journalctl --list-boots
```

If only boot `0` is listed, stop and enable persistence first:

```bash
sudo scripts/netwatch-setup-journald.sh --check   # report only
sudo scripts/netwatch-setup-journald.sh --apply   # enable + cap size
```

That script also bounds journal size. An uncapped journal defaults to 10% of the
filesystem and can grow to several GB.

> **Drop-in precedence.** systemd sorts `*.conf.d/` snippets lexicographically
> **across all** config directories (`/usr/lib`, `/run`, `/etc`), and for
> single-value options the **last** file sorted wins. A vendor file named
> `40-foo.conf` therefore beats an admin file named `10-bar.conf`. The setup
> script writes `90-netwatch.conf` so it reliably takes precedence.

---

## Step 2 — Identify the failure signature

Run the collector:

```bash
sudo scripts/netwatch-postmortem.sh --all-boots
```

It counts each hang class per boot. Interpret as follows:

| Signature | Count pattern | Diagnosis |
|---|---|---|
| `Detected Hardware Unit Hang` | hundreds to tens of thousands | **TSO/offload erratum** → disable offloads |
| `NIC Link is Up/Down` | many per boot, hang = 0 | **Link flapping** → investigate EEE, cabling, switch |
| `ME firmware caused invalid RDT/TDT` | any | **ME/CSME corrupting the ring** → BIOS AMT settings, ME firmware |
| `NETDEV WATCHDOG ... timed out` | any | Driver's own TX-timeout recovery fired |
| `Reset adapter unexpectedly` | any | Driver reset outside the normal path |
| `PCIe Bus Error` / `AER: Uncorrected` | any | PCIe link problem → reseat, check the slot |

These strings are verified against the upstream driver source
(`drivers/net/ethernet/intel/e1000e/netdev.c`), so they are safe to grep for
literally.

Manually, for a single boot:

```bash
journalctl -k -b -1 --no-pager | grep -c 'Detected Hardware Unit Hang'
journalctl -k -b -1 --no-pager -o short-precise \
  | grep -iE 'e1000e|NETDEV|Hardware Unit Hang|Reset adapter|ME firmware|NIC Link'
```

### Reading a Hardware Unit Hang

```
e1000e 0000:00:19.0 eno1: Detected Hardware Unit Hang:
  TDH                  <1a>
  TDT                  <2f>
  next_to_use          <2f>
  next_to_clean        <1a>
```

`TDH` (hardware's read pointer into the TX ring) has stopped advancing while
`TDT` (the driver's write pointer) keeps moving. The DMA engine stopped pulling
descriptors while the driver kept queuing frames. When `next_to_clean` is stuck
at the same value as `TDH`, the ring is stalled.

If `NETDEV WATCHDOG` and `Reset adapter` counts are **zero** alongside a high
hang count, the driver never even attempted recovery — which is why only a
reboot clears it.

---

## Step 3 — Confirm the interface and its state

On Proxmox the default route points at the bridge (`vmbr0`), but counters and
offload settings live on the **physical port** enslaved to it. The bridge looks
perfectly healthy while the hardware beneath it is wedged, so always check the
physical interface.

```bash
sudo scripts/netwatch-nic-remediation.sh --status
```

This resolves through the bridge automatically and reports driver, offload
state, error counters, and hang history.

Manually:

```bash
ip route show default                    # e.g. "default via 10.0.0.2 dev vmbr0"
ls /sys/class/net/vmbr0/brif/            # the enslaved ports
ethtool -i eno1                          # driver + firmware
ethtool -k eno1 | grep -E 'tcp-segmentation|generic-segmentation|generic-receive'
ethtool -S eno1 | grep -E 'tx_timeout_count|tx_restart_queue|rx_missed_errors'
```

Counters worth watching:

| Counter | Meaning |
|---|---|
| `tx_timeout_count` | NETDEV watchdog fired. Non-zero = at least one hang cycle. |
| `tx_restart_queue` | TX queue stopped and restarted. Climbing = TX-path pressure. |
| `rx_missed_errors` | RX FIFO overruns — the OS wasn't draining buffers fast enough. |
| `rx_crc_errors` | Physical-layer problems. Climbing steadily suggests cable or switch. |

---

## Step 4 — Rule out the alternatives

Do this before changing anything, so the fix is driven by evidence.

**Energy Efficient Ethernet (EEE)** — causes link *flapping*, a different
signature from a TX hang:

```bash
ethtool --show-eee eno1
cat /sys/class/net/eno1/carrier_down_count
```

`EEE status: enabled - active` plus repeated link transitions implicates EEE.
`enabled - inactive` means LPI never engages (usually because the link partner
doesn't advertise EEE), so EEE is not your problem.

**PCIe ASPM**:

```bash
lspci -vvv -s 00:19.0 | grep -E 'LnkCap|LnkCtl'
```

Empty output means the NIC is PCH-integrated with no PCIe link capability
structure — there is no ASPM state to disable, and `pcie_aspm=off` cannot help.

**ME / AMT** — the `-LM` NIC variants are AMT-capable and share the PHY with the
Management Engine. Direct evidence is the driver's own message:

```bash
journalctl -k --no-pager | grep 'ME firmware caused invalid'
```

Zero occurrences rules it out.

**Switch or cabling** — check `rx_crc_errors` and the switch's own port counters
for the outage timestamp.

**Thermal** — `sensors` (from `lm-sensors`). Weakly evidenced for this failure
class, but cheap to check.

---

## Step 5 — Apply the fix

For a confirmed `Detected Hardware Unit Hang`, disable hardware offloads. Intel
acknowledges this as a long-standing hardware bug on this silicon; the CPU cost
at gigabit rates is negligible.

```bash
sudo scripts/netwatch-nic-remediation.sh --status           # before
sudo scripts/netwatch-nic-remediation.sh --apply-offloads
```

This applies the change immediately **and** installs a persistent hook.

Manually:

```bash
ethtool -K eno1 gso off gro off tso off tx off rx off rxvlan off txvlan off sg off
```

### Why persistence needs `post-up`

The driver silently re-enables offloads on subsequent link-up events, so a
one-time boot command is not enough — the setting must be reapplied every time
the interface comes up.

Placement matters. A typical Proxmox `/etc/network/interfaces` looks like:

```
iface eno1 inet manual          # note: no "auto eno1"

auto vmbr0
iface vmbr0 inet static
        address 10.0.0.180/22
        gateway 10.0.0.2
        bridge-ports eno1
```

`eno1` has no `auto` stanza — it is brought up implicitly as a bridge port, and
`post-up` on a non-`auto` slave stanza is unreliable under ifupdown2. So the hook
goes on the **`vmbr0`** stanza but names `eno1` explicitly (using `$IFACE` there
would resolve to `vmbr0`, applying the setting to the wrong device):

```
auto vmbr0
iface vmbr0 inet static
        ...
        # netwatch: e1000e TSO/offload hang workaround
        post-up /usr/sbin/ethtool -K eno1 gso off gro off tso off tx off rx off rxvlan off txvlan off sg off
```

Verify it survives an interface bounce:

```bash
sudo ifreload -a
ethtool -k eno1 | grep -E 'tcp-segmentation|generic-segmentation|generic-receive'
```

All three must read `off`.

To revert:

```bash
sudo scripts/netwatch-nic-remediation.sh --revert-offloads
```

---

## Step 6 — Verify the fix holds

The sampler runs every 60s and records link state, counters, offload state, and
any new hang signatures:

```bash
sudo systemctl enable --now netwatch-netprobe.timer
journalctl -t netwatch-netprobe -f
```

A healthy sample:

```
iface=eno1 operstate=up carrier=1 carrier_up=1 carrier_down=1 tx_timeout=0
tx_restart=847 rx_missed=56 rx_crc=0 offloads=tso=off,gso=off,gro=off
gateway=ok events=clean
```

Anomalies are logged at `crit`, which makes journald fsync immediately so the
record survives a hard power-cycle:

```bash
journalctl -t netwatch-netprobe -p crit --no-pager
```

Watch for:

- `hardware-unit-hang` — the hang returned; the fix did not hold
- `offloads-re-enabled` — something re-enabled offloads (check the `post-up` hook)
- `gateway-unreachable` / `link-not-up` — connectivity lost

**Success criteria** after two to three weeks — longer than the previous failure
interval:

1. Zero `Detected Hardware Unit Hang` events
2. `tx_restart_queue` flat, not climbing
3. `tx_timeout_count` still 0
4. No `offloads-re-enabled` anomalies

---

## Capturing state during a live hang

If the host wedges again and you have keyboard access, capture kernel state
*before* rebooting. Requires `kernel.sysrq=1` (set by the journald setup script).

At the physical console:

| Keys | Captures |
|---|---|
| `Alt+SysRq+t` | All task states |
| `Alt+SysRq+w` | Tasks blocked in uninterruptible sleep |
| `Alt+SysRq+l` | Backtrace for all active CPUs |
| `Alt+SysRq+m` | Memory info |

Output goes to the kernel ring buffer, which journald ingests — so with
persistent storage it is readable after the reboot. Then:

```
Alt+SysRq+s    # sync filesystems
reboot
```

Afterwards:

```bash
sudo scripts/netwatch-postmortem.sh --boot -1 --output /tmp/postmortem.txt
```

---

## If the fix does not hold

In rough order of escalation:

1. **Check the hook actually applied** — `ethtool -k eno1` after a reboot. A
   silent revert to `on` means the `post-up` hook is not firing.
2. **Kernel regression** — some Proxmox kernel versions are reported as
   regressing this. Compare `uname -r` against when outages began; consider
   pinning an older kernel with `proxmox-boot-tool kernel pin <version>`.
3. **Bridge ARP behavior** — a documented contributing factor on bridged hosts:
   `net.ipv4.conf.all.arp_ignore=2`, `net.ipv4.conf.all.arp_announce=2`.
4. **ME firmware** — if `ME firmware caused invalid` appears, check BIOS AMT/ME
   settings and whether the vendor's ME firmware update has been applied.
5. **Replace the NIC** — the reported last resort is an add-in card using a
   different driver (e.g. Intel I210 via `igb`), bypassing the onboard part.

---

## A worked example

From the investigation that produced this tooling — a Lenovo ThinkCentre M93p
Tiny (Haswell, Intel I217-LM `8086:153a`) running Proxmox VE:

```
boot -1  hang=70084  txtimeout=0  reset=0  me=0  link=1
boot -2  hang=0      txtimeout=0  reset=0  me=0  link=1
boot -3  hang=3257   txtimeout=0  reset=0  me=0  link=1
boot -4  hang=0      txtimeout=0  reset=0  me=0  link=1
boot -5  hang=0      txtimeout=0  reset=0  me=0  link=1
```

Conclusion:

- **hang ≫ 0 on two boots** → TSO/offload erratum confirmed
- **txtimeout = 0, reset = 0** → no self-recovery, explaining why only a reboot
  ever restored networking
- **link = 1 per boot** → a single link-up at boot, so no flapping; EEE excluded
  (independently corroborated by `EEE status: enabled - inactive`)
- **me = 0** → ME/CSME excluded
- **`lspci -vvv` showed no LnkCap/LnkCtl** → PCH-integrated, ASPM not applicable

All offloads were `on` at the time. The fix was to disable them, persisted via a
`post-up` hook on the `vmbr0` stanza.

Baseline at the time of the fix, for trend comparison: `tx_restart_queue=847`,
`tx_timeout_count=0`, `rx_missed_errors=56`.

---

## Related

- [Operations and troubleshooting](../README.md)
- [Integration testing](integration-testing.md)
- `scripts/netwatch-nic-remediation.sh` — apply, revert, inspect
- `scripts/netwatch-postmortem.sh` — post-outage forensics
- `scripts/netwatch-setup-journald.sh` — persistent, size-capped journal
- `src/netwatch-netprobe.sh` — the NIC health sampler
