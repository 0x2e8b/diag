# diag - packet capture host toolkit

Five bash scripts for a Linux host that captures mirrored (SPAN/TAP) traffic with
PF_RING, n2disk and nProbe: find out **why packets are lost**, **tune the capture NICs**
**fit the host for capture** and **find duplicated packets or loops** in the mirror.

Made to be typed by hand over a screen share: short commands, one screen of output,
no dependencies beyond `bash`, `ethtool`, `iproute2`, `tcpdump` (and optionally `perf`).

```
sudo su -
git clone https://github.com/0x2e8b/diag && cd diag
bash doctor.sh        # 0. all of the below in order, explained, one question per change
bash diag.sh          # 1. what is wrong (read-only)
bash nic.sh           # 2. tune the NICs (interactive, reversible)
bash capfit.sh        # 3. offloads, kernel, priorities (asks before every change, reversible)
bash dup.sh eno1np0   # 4. duplicates / loops on one NIC
```

| Script | Changes the system? | Use it for |
|---|---|---|
| `doctor.sh` | only what you confirm; `revert` undoes its quick fixes | guided run: measure, diagnose, explain, fix, measure again, summary |
| `diag.sh` | no, read-only | full diagnosis with findings and proposed fixes |
| `nic.sh` | yes, only after you confirm; `revert` undoes it | RX ring, queues, IRQ placement, RSS, persistence |
| `capfit.sh` | yes, one question per change; `revert` undoes it | NIC features that alter packets (GRO/LRO/TSO/GSO, VLAN stripping), kernel buffers and disk write-back, n2disk/nprobe priority |
| `dup.sh` | no (a short `tcpdump`) | duplicated packets, L2/L3 loops, broadcast storms |

On site, start with `doctor.sh`: it runs the others in the right order. Alone, start with `diag.sh`. It tells you whether `nic.sh` will help at all.
`capfit.sh` is worth running on every capture host: VLAN stripping and GRO change what is recorded, not only how fast.

---

## doctor.sh - the guided run

One command for a host that loses packets. It runs the other scripts in order, explains every finding
in plain words (what it means, what to do, who does it: us or the customer's network team) and asks
before each stage and each change.

```
bash doctor.sh
NICS="eno1np0 eno2np1" bash doctor.sh
SECS=20 DIAG_S=10 bash doctor.sh     # longer loss sample / diag sample
bash doctor.sh revert                # undo its quick fixes, offers nic.sh / capfit.sh revert too
```

| Stage | What happens | Changes? |
|---|---|---|
| 1 licence | `n2disk --show-system-id` and `--check-license` saved | no |
| 2 loss now | per NIC: loss %, Mpps, Gbit/s, average packet, loss since boot, every drop/discard/miss counter that grows | no |
| 3 diagnosis | `diag.sh` | no |
| 4 explained | each finding: what it means, the fix, who does it | no |
| 5 duplicates | `dup.sh` 100000 packets per NIC, kinds explained, top pairs for the network team | no |
| 6 quick fixes | RPS off, CPU governor `performance`, IPv6 off on capture NICs; then measured | yes, each asked, no link reset |
| 7 verdict | root causes (PF_RING copies, other sockets, bridge, duplicates, stack) vs tuning | no |
| 8 tuning | only in the agreed window: `nic.sh check/apply`, measure, keep or revert; `capfit.sh check/all`, measure | yes, link resets |
| 9 result | loss again, `diag.sh` after, licence compared, summary | no |

Loss is `missed / (received + missed)` over the sample, safe against the 32-bit wrap of
`rx_missed_errors` on i40e. Never read the cumulative `rx_missed_errors` as lifetime loss there: it wraps
every 4.29e9. "Loss since boot" uses `rx_unicast + rx_multicast + rx_broadcast` against `rx_packets` instead.

Every question in `doctor.sh`, `nic.sh` and `capfit.sh` looks the same: a yellow ` Q ` marker, then what **Y** does
and what **N** does, the default in capitals. The answer is written back (`-> yes`, `-> no (default)`), so the log shows every decision. Questions that reset the link say `LINK RESET` in red.

```
 Q  Apply nic.sh to eno1np0 eno2np1?
    Y  LINK RESET ~3 s (n2disk loses them): ring to max, GRO/LRO off, IRQs on the NIC's own cores, irqbalance off; then measured
    N  nothing changes, go to capfit
    [Y/n] >
```

With no loss at the NIC (below 1%), `doctor.sh` recommends skipping `nic.sh` and says so instead of reporting a failure.

When the per-packet cost is above 2 us, tuning keeps the current number of queues: fewer queues
would raise the loss while each packet is that expensive.

Output: `/root/doctor/doctor-<date>.log` (everything), `summary-<date>.txt` (findings, loss before/after,
cost per packet, what was changed, what is open for the customer), `measure-<date>.txt`, `diag-before/after`,
`dup-<nic>`, `licence-before/after`.

---

## diag.sh - where the CPU goes and why packets are lost

Samples everything for a few seconds at once, then prints each section and a ranked
list of **FINDINGS** (`CRIT`, `WARN`, `INFO`), each with a `fix:` line.
The full report is saved to `/root/diag/diag-<date>.txt`.

```
bash diag.sh                              # capture NICs found automatically
NICS="eno1np0 eno2np1" bash diag.sh       # or named
S=10 bash diag.sh                         # longer sample (default 5 s)
DUP=0 PERF=0 bash diag.sh                 # skip the duplicate check / kernel profile
```

Capture NICs are taken from `-i=` in `/etc/n2disk/n2disk.conf`, otherwise every
physical NIC in promiscuous mode without an IP address.

What it checks:

| Area | Check | Finding when |
|---|---|---|
| CPU | softirq share per CPU, load, frequency governor | many CPUs >90% in softirq; governor not `performance` |
| Cost per packet | softirq CPU time / arriving packets | > 2 us per packet (normal: ~0.3-1 us per PF_RING consumer) |
| NIC | arriving pps, `rx_missed_errors` (loss at the NIC), CRC errors | loss > 1% |
| NIC | RX ring vs maximum, queues, GRO | ring below maximum, GRO on |
| NIC | traffic per queue | one queue carries most of the packets |
| NIC | which CPUs handled its interrupts, their NUMA node | interrupts on the other NUMA node |
| NIC | RPS, bridge/bond membership, IP address | RPS on; NIC inside a bridge; IP on a capture NIC |
| PF_RING | every ring: application, device, cluster, pps, loss | a packet copied to more than 2 rings; a NIC no ring reads; ring loss > 1% |
| Other receivers | AF_PACKET sockets (tcpdump, libpcap tools, `any` captures) | any socket sees the capture traffic; an IDS (Suricata, Zeek, Snort) is only `INFO`: its threads share one fanout group, so it is one copy |
| Applications | n2disk, nprobe, suricata, zeek, tcpdump, zbalance_ipc, cento | (listed) |
| Storage | n2disk `-o` directory: filesystem, disk busy % | on the root filesystem; disk > 80% busy |
| Duplicates | `dup.sh` on 20000 packets per NIC | > 5% extra copies |
| Kernel profile | `perf record` 5 s: PF_RING copy / network stack / driver | > 15% in the stack or in ring copies |

How to read the result:

- **Loss at the NIC** (`rx_missed_errors`) is the symptom: the NIC has the packet but
  the host did not free RX descriptors in time. The cause is in the other findings.
- **Many CPUs at 100% softirq** means the work is already spread. Then the problem is
  the **cost per packet**, not the number of cores. Usually the cause is one of:
  - PF_RING copies: every ring outside a common cluster gets its own copy;
  - other AF_PACKET sockets;
  - the NIC in a bridge;
  - duplicated packets in the mirror.
- **PF_RING ring loss** means the application (n2disk, nprobe) does not read fast enough.
  This is a different problem from NIC loss.
- **If everything is clean and loss stays**, the ceiling of the kernel path is reached.
  The next step is the PF_RING ZC driver with `zbalance_ipc`: the NIC is read once, and
  n2disk and nprobe get the packets from shared memory. It needs a ZC licence.

`perf` is optional. Without it the kernel profile is skipped (on Ubuntu:
`linux-tools-$(uname -r)`).

---

## nic.sh - tune the capture NICs

Interactive. It finds the physical NICs, proposes the capture ones and shows a menu.
Every step that changes something asks first, and the original settings are saved once,
so `revert` always brings back the state from before the first run.

```
bash nic.sh
```

```
Physical NICs:
  eno1np0      i40e        10000 Mb/s  n2disk promisc no-ip
  eno2np1      i40e        10000 Mb/s  n2disk promisc no-ip
  eno3         igb          1000 Mb/s  ip=10.0.0.5/24
Capture NICs, space separated [eno1np0 eno2np1]:

 1 check    state, plan, loss now (saves the original once)
 2 apply    max ring, queues, IRQs on own CPUs, irqbalance off   (link resets!)
 3 measure  loss over 10 s
 4 rss      spread UDP over queues by ports                       (link resets!)
 5 persist  keep after reboot
 6 revert   back to the original                                  (link resets!)
 7 status   state only
 8 change NICs      0 quit
```

The NICs are proposed in this order:

1. the NICs in `n2disk.conf`;
2. otherwise, NICs in promiscuous mode without an IP;
3. otherwise, NICs that are up and have no IP.

A NIC with an IP address gets a warning, because it could be the management NIC.

What `apply` does:

- RX ring to the maximum;
- GRO/LRO off;
- irqbalance stopped and disabled;
- each NIC's interrupts pinned to **its own physical cores on its own NUMA node**;
- after those cores, the hyper-threads of the same cores; the NICs never share a physical core.

Queues per NIC, by default:

`(physical cores of the NIC's node - RESERVE) / NICs on that node`, capped at the NIC's maximum.

- Example: 2 NICs on a node with 28 cores and the default `RESERVE=4`: 12 queues each.
- `RESERVE` cores (default 4) stay free for n2disk and nprobe. `check` prints them as
  ready `-c= -w= -z=` options for `n2disk.conf`. You set those by hand; the script never edits `n2disk.conf`.
- Queues are **never lowered silently**. If the NIC has more queues now, the menu asks
  `Reduce ... from 56 to 12 queues? [y/N]`. Without the menu the script keeps the current number.

Other steps:

- `measure`: loss % = missed / (received + missed) over 10 s, appended to `/root/nic/measure.log`.
  Run it before and after `apply`.
- `rss`: also hashes UDP on ports. Use it only when `check` shows one queue carrying most of the traffic.
- `persist`: installs `nic-tune.service`, which runs before `n2disk.service` at boot.
- `revert`: restores the saved ring, queues, GRO/LRO and UDP hashing, re-enables irqbalance
  if it was on, and removes the boot unit.

Fallbacks:

- no `rx_missed_errors` in `ethtool -S`: it reads `/sys/class/net/*/statistics`;
- interrupt names it does not know: it uses the PCI device's MSI interrupts;
- no NUMA information (VMs): it uses all CPUs;
- driver limits on queues or ring, or an interrupt that cannot be moved: it warns and continues.

Without the menu:

```
NICS="eno1np0 eno2np1" bash nic.sh check|apply|measure|rss|persist|revert|status
Q=12 RESERVE=4 NICS="eno1np0" bash nic.sh apply
```

`apply`, `rss` and `revert` reset the NIC link for a few seconds, so the capture
applications lose a few seconds of traffic. Run them in an agreed window.

---

## capfit.sh - fit the host for capture

`nic.sh` decides **how fast** the NIC hands packets to the host. `capfit.sh` covers three other things:

- **what the NIC does to the packets**;
- **kernel settings**;
- **priority of the capture applications**.

It is interactive and asks **before every single change**, with one line saying why.
So you can, for example, turn off GRO but keep VLAN stripping when the customer
wants it that way.

```
bash capfit.sh
```

```
 1 check     what is not capture-friendly (changes nothing)
 2 offloads  NIC: GRO/LRO/TSO/GSO, VLAN stripping   (asks for each; link may blink)
 3 kernel    backlog, socket buffers, steady disk write-back, swappiness
 4 priority  n2disk/nprobe: nice, OOM protection, locked memory (live + drop-in, no restart)
 5 all       2 + 3 + 4, still one question per change
 6 persist   the offloads you turned off, again after reboot
 7 revert    everything back to the original
```

`check` prints one table with the current value, the recommended value and the status
(`OK`, `CHANGE`, `cannot change (driver)`) for each item.

**NIC features** (recommended: off on a capture NIC):

| Feature | Why it matters |
|---|---|
| `gro` | the kernel merges the packets of a flow: the recording no longer matches the wire, flow counters are wrong |
| `lro` | the same, in hardware |
| `tso`, `gso` | segmentation on transmit: no effect on a pure capture NIC, off for consistency |
| `rxvlan` | the NIC strips the 802.1Q tag: packets are recorded **without their VLAN**, VLAN filters stop matching. Keep it on only when the VLAN must not reach the applications |

**Kernel** (written to `/etc/sysctl.d/60-capfit.conf`, only the keys you accept):

| Key | Recommended | Why |
|---|---|---|
| `net.core.netdev_max_backlog` | >= 250000 | queue for bursts the softirq cannot drain at once |
| `net.core.rmem_max` | >= 268435456 | largest socket receive buffer an application may ask for |
| `net.core.rmem_default` | >= 33554432 | default receive buffer for libpcap/AF_PACKET users |
| `vm.dirty_background_bytes` | 268435456 | start writing captured data early, in small portions |
| `vm.dirty_bytes` | 1073741824 | cap on unwritten data, so n2disk's writer does not stall on a huge flush |
| `vm.swappiness` | <= 1 | keep capture buffers in RAM |

**Applications**, two separate questions per application:

| Item | n2disk | nprobe | Effect | When |
|---|---|---|---|---|
| `<app>-protect`: OOM score adj, locked memory, open files | -900, unlimited, 65535 | -500, unlimited, 65535 | killed last when RAM runs out; buffers stay in RAM; no "too many open files" | always safe |
| `<app>-nice`: nice | -10 | -5 | wins CPU against other programs on the same core | only when the app runs on its own cores |

- **Why nice can hurt:** under heavy load the kernel receives packets in `ksoftirqd` threads, which run at nice 0.
  An unpinned n2disk at nice -10 takes their CPU and the NIC loss can rise. `check` shows whether the app is
  pinned (some thread limited to fewer CPUs, e.g. n2disk `-c/-w/-z`); the question says "RECOMMENDED: N" when it is not,
  and the non-interactive mode skips nice for an unpinned app.
- Already set values are not asked again.
- The running process is changed live (`renice`, `oom_score_adj`, `prlimit`).
- Drop-ins `60-capfit.conf` (protection) and `60-capfit-nice.conf` make it stay from the next start of the unit.
- **Nothing is restarted.**

**Undo:**

- Every original value is saved once, before the first change.
- `revert` undoes only what capfit changed: offloads, sysctl values and file, priorities of
  processes that still run, drop-ins and the boot unit.
- `persist` sets **only the offloads you turned off** again at boot (`capfit.service`, before `n2disk.service`).
  The kernel file and the drop-ins persist on their own.

Without the menu everything is applied, except the names in `SKIP`:

```
NICS="eno1np0 eno2np1" bash capfit.sh check
NICS="eno1np0 eno2np1" SKIP="rxvlan vm.swappiness" bash capfit.sh all
NICS="eno1np0 eno2np1" bash capfit.sh revert
```

`SKIP` takes offload names (`gro lro tso gso rxvlan`), kernel keys and application items (`n2disk-protect n2disk-nice nprobe-protect nprobe-nice`, or `n2disk` / `nprobe` for both).

---

## dup.sh - duplicates, loops, broadcast storms

Captures N packets (default 100000, at most 60 s) or reads a pcap. It finds packets
seen more than once: same content, ignoring time, MAC addresses, VLAN tag, TTL and
IP checksum. Each duplicated packet gets one of these kinds:

| Kind | Copies look like | Meaning |
|---|---|---|
| `SAME-TTL` | identical, e.g. `ttl: 64 64 64` | the mirror takes the same packet in several places (SPAN on several ports/VLANs, rx+tx on both ends) or an L2 loop |
| `ROUTED` | 2 copies, TTL differs by 1 | the mirror sees the packet before and after one router hop (both VLANs mirrored) |
| `LOOP` | 3+ copies, TTL falling, e.g. `60 59 58 57` | L3 routing loop: the route to `dst` goes in a circle |
| `L2-SAME` | non-IP (ARP...) copies | mirror duplication; hundreds of copies with a high broadcast % = L2 loop / broadcast storm |

```
bash dup.sh eno1np0            # 100000 packets
bash dup.sh eno1np0 500000     # more
bash dup.sh /tmp/some.pcap     # an existing capture
```

Output:

- up to 15 examples with the TTL list and VLANs of the copies;
- totals: packets, extra copies %, count per kind, broadcast % and multicast %;
- the top 20 src > dst pairs by extra copies: these are the hosts involved;
- the top 10 broadcast senders by MAC;
- the files: `s.pcap` and the decoded `s.txt`.

Details for one host: `tcpdump -nn -e -v -r /tmp/dup.<pid>/s.pcap host 10.1.2.3`.
Different MAC pairs on the copies show which network segments or routers they came through.

A pure `SAME-TTL` result is a mirror configuration problem, not a network fault.
It still inflates every byte, packet and flow counter, and every copy costs full
CPU in each capture application.
Loops and storms are best confirmed on the switches:

- MAC flapping / mac-address-move logs;
- STP topology change counters;
- broadcast counters / storm-control on the ports.
