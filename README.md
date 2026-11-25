# diag - packet capture host toolkit

Three bash scripts for a Linux host that captures mirrored (SPAN/TAP) traffic with
PF_RING, n2disk and nProbe: find out **why packets are lost**, **tune the capture NICs**
and **find duplicated packets or loops** in the mirror.

Made to be typed by hand over a screen share: short commands, one screen of output,
no dependencies beyond `bash`, `ethtool`, `iproute2`, `tcpdump` (and optionally `perf`).

```
sudo su -
git clone https://github.com/0x2e8b/diag && cd diag
bash diag.sh          # 1. what is wrong (read-only)
bash nic.sh           # 2. tune the NICs (interactive, reversible)
bash dup.sh eno1np0   # 3. duplicates / loops on one NIC
```

| Script | Changes the system? | Use it for |
|---|---|---|
| `diag.sh` | no, read-only | full diagnosis with findings and proposed fixes |
| `nic.sh` | yes, only after you confirm; `revert` undoes it | RX ring, queues, IRQ placement, RSS, persistence |
| `dup.sh` | no (a short `tcpdump`) | duplicated packets, L2/L3 loops, broadcast storms |

Start with `diag.sh`. It tells you whether `nic.sh` will help at all.

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
| Other receivers | AF_PACKET sockets (tcpdump, libpcap tools, `any` captures) | any socket sees the capture traffic |
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
