#!/bin/bash
# doctor - one guided run for a capture host that loses packets:
#   licence snapshot -> loss now -> diagnosis (diag.sh) -> what is broken and why -> duplicates (dup.sh)
#   -> quick safe fixes -> NIC tuning (nic.sh) -> host fitting (capfit.sh) -> loss again -> licence check -> summary
#   bash doctor.sh                       guided run, asks before every stage and every change
#   NICS="eno1np0 eno2np1" bash doctor.sh
#   bash doctor.sh revert                undo doctor's own quick fixes (and offer nic.sh / capfit.sh revert)
# Env: SECS=10 (loss sample), DIAG_S=10 (diag.sh sample). Log and summary in /root/doctor/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SYS=${SYS:-/sys/class/net}; CPUDIR=${CPUDIR:-/sys/devices/system/cpu}; N2CONF=${N2CONF:-/etc/n2disk/n2disk.conf}
DST=${DST:-/root/doctor}; SECS=${SECS:-10}; DIAG_S=${DIAG_S:-10}; mkdir -p $DST
TS=$(date +%Y%m%d-%H%M%S); LOG=$DST/doctor-$TS.log; SUM=$DST/summary-$TS.txt; MF=$DST/measure-$TS.txt
if [ -t 1 ]; then R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi

have()  { command -v $1 >/dev/null 2>&1; }
stage() { echo; echo "${B}==================== $* ====================${N}"; }
ok()    { echo "${G}OK${N}      $*"; }
bad()   { echo "${R}BROKEN${N}  $*"; }
note()  { echo "${Y}NOTE${N}    $*"; }
if [ -t 0 ]; then QM=$'\e[30;43m Q \e[0m'; RS=$'\e[1;31mLINK RESET\e[0m'; else QM=" Q "; RS="LINK RESET"; fi
# question: $1 text, $2 what Y does, $3 what N does, $4 default y|n (n when omitted); true = yes
q() { local a d=${4:-n}; echo; echo "$QM $1"; [ -n "${2:-}" ] && echo "    Y  $2"; [ -n "${3:-}" ] && echo "    N  $3"
      read -rp "    $([ $d = y ] && echo '[Y/n]' || echo '[y/N]') > " a; [[ ${a:-$d} =~ ^[yYtT] ]]; }
sum()   { echo "$*" >> $SUM; }
CHG=(); OPEN=()

# one explained problem: severity | what diag/doctor saw | what it means | what to do | who does it
issue() { local c=$Y; [ "$1" = CRIT ] && c=$R
  echo; echo "${c}[$1]${N} $2"; echo "   means: $3"; echo "   ${B}fix:${N}   $4"; echo "   who:   $5"
  sum "[$1] $2"; sum "   means: $3"; sum "   fix:   $4"; sum "   who:   $5"
  [[ $5 == *customer* ]] && OPEN+=("$2 -> $4"); }

# ---------- NICs ----------
n2ifs() { [ -r $N2CONF ] && sed -n 's/^ *-i[= ]*//p' $N2CONF | tr ',' ' '; }
choose() {
  [ -n "${NICS:-}" ] && return
  local p; p=$(n2ifs)
  [ -z "$p" ] && for i in $(ls $SYS); do [ -e $SYS/$i/device ] || continue; (( $(cat $SYS/$i/flags) & 0x100 )) || continue
    have ip && [ -n "$(ip -o -4 addr show dev $i 2>/dev/null)" ] && continue; p="$p $i"; done
  p=$(echo $p)
  echo; read -rp "$QM Capture NICs [$p]: " NICS; NICS=$(echo ${NICS:-$p})
  [ -z "$NICS" ] && { echo "no capture NIC: NICS=\"eth1 eth2\" bash doctor.sh"; exit 1; }
  for i in $NICS; do [ -e $SYS/$i ] || { echo "$i does not exist"; exit 1; }; done
}

# ---------- counters and loss ----------
snap() {   # name value, ethtool -S first, plus the kernel's standard counters as sys_*
  have ethtool && ethtool -S $1 2>/dev/null | awk -F: 'NF>=2{k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/ /,"_",k); v=$2; gsub(/[ \t]/,"",v); if(k!="" && v~/^[0-9]+$/) print k, v}'
  for f in rx_packets rx_bytes rx_missed_errors rx_dropped; do [ -r $SYS/$1/statistics/$f ] && echo "sys_$f $(cat $SYS/$1/statistics/$f)"; done; }
measure() {   # $1 label; loss = missed / (received + missed) over SECS, safe against 32-bit counter wrap (i40e)
  local lab=$1 i r l; echo "measuring $SECS s on $NICS ..."
  for i in $NICS; do snap $i > $DST/.s0.$i; done; sleep $SECS
  for i in $NICS; do snap $i > $DST/.s1.$i
    r=$(awk -v s=$SECS -v nic=$i -v lab=$lab '
      NR==FNR{a[$1]=$2; next}
      { v[$1]=$2; if($1 in a){ d=$2-a[$1]; if(d<0 && a[$1]<4294967296) d+=4294967296; D[$1]=d } }
      function g(k){ return (k in D) ? D[k] : ((("sys_" k) in D) ? D["sys_" k] : "") }
      END{ p=g("rx_packets"); m=g("rx_missed_errors"); b=g("rx_bytes")+0
        if(p==""){ print "NOCOUNT"; exit }
        known=(m!=""); m+=0; arr=p+m
        printf "M %s %s %.1f %d %.2f %d %s\n", lab, nic, (arr?100*m/arr:0), arr/s, b*8/s/1e9, (p?b/p:0), (known?"yes":"no")
        if(("rx_unicast" in v) && v["rx_packets"]>0){ U=v["rx_unicast"]+v["rx_multicast"]+v["rx_broadcast"]; P=v["rx_packets"]
          if(U>P*1.001) printf "LIFE %.1f\n", 100*(U-P)/U }
        for(k in D) if(k!~/^sys_/ && k~/drop|discard|miss|no_?buf|fifo|overrun|error|fail/ && D[k]>0) printf "GREW %s %d/s\n", k, D[k]/s
      }' $DST/.s0.$i $DST/.s1.$i)
    [ "$r" = NOCOUNT ] && { note "$i: no rx_packets counter, loss unknown"; continue; }
    set -- $(echo "$r" | grep '^M '); l=$4
    echo "$2 $3 $4 $5 $6 $7" >> $MF
    if awk -v x=$l 'BEGIN{exit !(x>1)}'; then bad "$i loses ${B}$l%${N} of arriving packets at the NIC"; else ok "$i loss $l%"; fi
    echo "        arriving $(awk -v p=$5 'BEGIN{if(p>=100000) printf "%.2f Mpps", p/1e6; else printf "%d pps", p}'), received $6 Gbit/s, average packet $7 B"
    [ "$8" = no ] && note "$i: driver has no rx_missed_errors counter, the loss above is a lower bound"
    echo "$r" | grep '^LIFE' | while read _ x; do echo "        since boot about ${x}% never reached the host (rx_unicast+multicast+broadcast vs rx_packets)"; done
    echo "$r" | grep '^GREW' | sed 's/^GREW /        counter growing: /'
  done; rm -f $DST/.s0.* $DST/.s1.*; }
loss_of() { awk -v l=$1 -v n=$2 '$1==l && $2==n{x=$3} END{print x}' $MF 2>/dev/null; }
compare() {   # $1 before, $2 after label -> 0 any NIC improved by >= 1 point, 2 no loss before or after, 1 no gain
  local i a b better=1 lossy=0
  for i in $NICS; do a=$(loss_of $1 $i); b=$(loss_of $2 $i); [ -z "$a" ] || [ -z "$b" ] && continue
    echo "   $i: loss $a% -> $b%"
    awk -v a=$a -v b=$b 'BEGIN{exit !(a-b>=1)}' && better=0
    awk -v a=$a -v b=$b 'BEGIN{exit !(a>=1 || b>=1)}' && lossy=1; done
  [ $better = 0 ] && return 0; [ $lossy = 0 ] && return 2; return 1; }
maxloss() { awk -v l=$1 '$1==l && $3>m{m=$3} END{print m+0}' $MF 2>/dev/null; }

# ---------- licence ----------
lic() { have n2disk || { echo "n2disk not installed"; return; }
  { timeout 30 n2disk --show-system-id; timeout 30 n2disk --check-license; } 2>&1 |
    sed -E 's#[0-9]{2}/[A-Za-z]{3}/[0-9]{4} [0-9:]{8} ##; s#\[[^]]*\] ##g' | grep -v '^ *$'; }

# ---------- diag findings explained ----------
findings() { awk '/^ ?[0-9]+\. \[(CRIT|WARN|INFO)\]/{if(t!="")print t"|"x; t=$0; sub(/^ ?[0-9]+\. /,"",t); x=""; next}
                  /^ +fix: /{x=$0; sub(/^ +fix: /,"",x)} END{if(t!="")print t"|"x}' $1; }
cost_of()  { sed -n 's/^per-packet kernel cost: \([0-9.]*\) us.*/\1/p' $1 | head -1; }
explain() {
  local line sev t fx n
  ROOT=""; TUNE=0; GOVBAD=0; RPSN=""; DUPN=""
  while IFS= read -r line; do
    t=${line%%|*}; fx=${line#*|}; sev=${t:1:4}; t=${t#*] }; n=${t%% *}
    case $t in
      *"CPUs spend >90% in softirq"*)
        issue $sev "$t" "these cores do nothing but receive packets. The work is already spread over many cores, so more cores will not help: one packet costs too much." \
          "remove what multiplies the cost (copies, other sockets, bridge, duplicates - see the other findings)" "us";;
      *"governor is not"*) GOVBAD=1
        issue $sev "$t" "cores slow down to save power, so every packet costs more CPU time" "quick fixes below (governor performance); for good: BIOS power profile = maximum performance" "us now, customer BIOS later";;
      *"of packets at the NIC"*)
        issue $sev "$t" "the symptom. The NIC had these packets and dropped them because the host did not take them in time. PCAPs and flows miss this share of traffic." \
          "remove the causes listed below first; NIC tuning (nic.sh) is the last and smallest step" "us";;
      *"RX ring"*) TUNE=1
        issue $sev "$t" "the NIC's receive buffer is smaller than it can be, so a burst overflows sooner" "tuning stage (nic.sh apply: ring to the maximum)" "us, in a window";;
      *"GRO on"*) TUNE=1
        issue $sev "$t" "the kernel merges packets of a flow: extra CPU work and the recording no longer matches the wire" "tuning stage (nic.sh apply / capfit offloads)" "us, in a window";;
      *"sits in few queues"*) TUNE=1
        issue $sev "$t" "one or two cores get most packets while the others wait" "tuning stage (nic.sh rss); if it stays: a few huge flows or a tunnel (GRE/VXLAN/ERSPAN) in the mirror" "us";;
      *"another NUMA node"*) TUNE=1
        issue $sev "$t" "packets are handled by the other CPU socket than the one the NIC is attached to: slower memory, more cost" "tuning stage (nic.sh apply pins interrupts to the NIC's own socket)" "us, in a window";;
      *"has RPS on"*) RPSN="$RPSN $n"
        issue $sev "$t" "after receiving, the kernel hands every packet to another core again: the work is done twice" "quick fixes below (RPS off, no link reset)" "us";;
      *"bridge/bond"*) ROOT="$ROOT bridge"
        issue $sev "$t" "the kernel treats the mirrored traffic as traffic to forward and runs the whole network stack for every packet" \
          "take the NIC out of the bridge/bond (netplan or docker network config); a capture NIC stands alone, without an IP" "us + customer admin";;
      *"has an IP address"*)
        issue $sev "$t" "the capture NIC is also a normal network interface: the stack looks at the traffic and the NIC sends its own packets" "remove the IP (netplan), keep the NIC up without an address" "customer admin";;
      *"each packet costs"*)
        issue $sev "$t" "normal is 0.3-1 us per consumer. More means every packet is copied or processed several times" \
          "see the copy / socket / bridge / duplicate findings; if all are clean: PF_RING ZC + zbalance_ipc" "us";;
      *"no PF_RING consumer reads it"*)
        issue $sev "$t" "nothing records this NIC: all its traffic is missing in PCAPs and flows" "add it to -i in $N2CONF and to the nprobe interfaces" "us";;
      *"copied"*"times by PF_RING"*|*"copying packets into PF_RING"*) ROOT="$ROOT copies"
        issue $sev "$t" "each ring outside a common cluster gets its own full copy of every packet: N rings = N times the CPU work" \
          "target is 1 copy for n2disk + 1 for nprobe: nprobe threads/instances reading the same NIC share one --cluster-id; stop extra consumers" "us"
        echo "   running consumers:"; ps -eo pid,args 2>/dev/null | grep -E '[n]2disk|[n]probe|[p]fcount|[z]balance' | cut -c1-160 | sed 's/^/     /';;
      *"PF_RING:"*"lost up to"*)
        issue $sev "$t" "the application itself reads too slowly and its ring overflows. A different problem from NIC loss: the NIC delivered, the app missed it" "$fx" "us";;
      *"IDS reads the capture traffic"*)
        issue $sev "$t" "an IDS (Suricata/Zeek/Snort) reads the NIC on purpose. Its threads share one fanout group, so it costs one copy, not one per socket" \
          "nothing while the IDS is wanted" "nobody";;
      *"AF_PACKET sockets"*) ROOT="$ROOT sockets"
        issue $sev "$t" "another program (tcpdump, a libpcap tool, an old recorder, an 'any' capture) gets its own copy of every packet" "stop it if it is not needed" "us"
        have ss && ss -0 -p 2>/dev/null | awk 'NR>1' | cut -c1-160 | sed 's/^/     /' | head -8;;
      *"root filesystem"*)
        issue $sev "$t" "PCAPs go to the system disk: shorter history, competes with the OS. It does not cause the NIC loss" "own disk/array, sequential write >= capture rate (10G = 1.25 GB/s)" "customer hardware";;
      *"disk "*"busy"*)
        issue $sev "$t" "the disk cannot keep up with n2disk: n2disk will drop packets" "faster or dedicated storage, bigger n2disk -b buffer" "customer hardware";;
      *"extra copies of the same packet"*) ROOT="$ROOT duplicates"; DUPN="$DUPN $n"
        issue $sev "$t" "the mirror delivers the same packet several times: every copy costs full CPU and inflates all statistics" "the duplicate stage shows which hosts/VLANs; the SPAN/mirror must take each packet once" "customer network team";;
      *"network stack"*) ROOT="$ROOT stack"
        issue $sev "$t" "packets go up the normal network stack (bridge, firewall, conntrack, sockets) instead of only PF_RING" "bridge / IP / AF_PACKET / iptables on the capture NIC (see those findings)" "us";;
      *) issue $sev "$t" "see the diag report" "${fx:-see the report}" "us";;
    esac
  done < <(findings $1)
}

# ---------- duplicates explained ----------
dupcheck() {   # $1 NIC
  local f=$DST/dup-$1-$TS.txt p st ro lo l2 bc
  bash $HERE/dup.sh $1 100000 > $f 2>&1
  p=$(sed -n 's/^packets [0-9]*, extra copies [0-9]* (\([0-9.]*\)%).*/\1/p' $f)
  [ -z "$p" ] && { note "$1: dup.sh gave no result (see $f)"; return; }
  read st ro lo l2 <<< "$(sed -n 's/^duplicated packets: SAME-TTL \([0-9]*\), ROUTED \([0-9]*\), LOOP \([0-9]*\), L2-SAME \([0-9]*\)/\1 \2 \3 \4/p' $f)"
  bc=$(sed -n 's/^broadcast [0-9]* (\([0-9.]*\)%).*/\1/p' $f)
  if awk -v x=$p 'BEGIN{exit !(x<1)}'; then ok "$1: duplicates $p% (negligible), broadcast ${bc:-?}%"; return; fi
  bad "$1: ${B}$p%${N} of packets are extra copies, broadcast ${bc:-?}%"
  [ "${st:-0}" -gt 0 ] && echo "   SAME-TTL $st: identical copies. Mirror configuration (same traffic taken on several ports/VLANs, rx+tx on both ends); an L2 loop gives tens-hundreds of copies"
  [ "${ro:-0}" -gt 0 ] && echo "   ROUTED $ro: the mirror sees the packet before and after one router (both VLANs mirrored)"
  [ "${lo:-0}" -gt 0 ] && echo "   ${R}LOOP $lo: routing loop, TTL falls on every copy. Tell the network team now.${N}"
  [ "${l2:-0}" -gt 0 ] && echo "   L2-SAME $l2: non-IP copies (ARP...): mirror duplication or, with high broadcast %, an L2 loop / storm"
  awk -v x=${bc:-0} 'BEGIN{exit !(x>5)}' && echo "   ${R}broadcast ${bc}% is high: check STP topology changes, MAC flapping, storm-control${N}"
  echo "   top pairs (copies, kind, vlans, src > dst):"; sed -n '/^top pairs/,/^$/p' $f | sed -n '2,6p' | sed 's/^/   /'
  sum "duplicates $1: $p% extra copies (SAME-TTL $st, ROUTED $ro, LOOP $lo, L2-SAME $l2), broadcast ${bc}% - $f"
  OPEN+=("$1: $p% duplicated packets in the mirror -> fix the SPAN (details $f)")
}

# ---------- quick fixes: no link reset, saved and reversible ----------
quick() {
  local i f v any=0 cur
  for i in $NICS; do for f in $SYS/$i/queues/rx-*/rps_cpus; do [ -r $f ] || continue
      v=$(tr -d ',0\n' < $f); [ -n "$v" ] && { any=1; break; }; done; done
  if [ $any = 1 ] && q "RPS is on: every packet is handed to another core a second time. Turn RPS off on $NICS?" \
       "rps_cpus = 0 on every queue now, no link reset; lasts until reboot; undo: bash doctor.sh revert" "RPS stays on" y; then
    for i in $NICS; do for f in $SYS/$i/queues/rx-*/rps_cpus; do [ -r $f ] || continue
        grep -q "^$f " $DST/rps.orig 2>/dev/null || echo "$f $(cat $f)" >> $DST/rps.orig; echo 0 > $f; done; done
    ok "RPS off"; CHG+=("RPS off on $NICS (doctor revert)"); fi
  cur=$(cat $CPUDIR/cpu0/cpufreq/scaling_governor 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != performance ] && grep -qw performance $CPUDIR/cpu0/cpufreq/scaling_available_governors 2>/dev/null &&
     q "CPU governor is '$cur': cores slow down and every packet costs more. Set 'performance'?" \
       "all cores at full clock now (more power, more heat), until reboot; undo: bash doctor.sh revert" "governor stays '$cur'" y; then
    [ -f $DST/gov.orig ] || echo $cur > $DST/gov.orig
    for f in $CPUDIR/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > $f 2>/dev/null; done
    ok "governor performance"; CHG+=("CPU governor performance, until reboot (doctor revert)"); fi
  for i in $NICS; do f=/proc/sys/net/ipv6/conf/$i/disable_ipv6; [ -w $f ] || continue
    [ "$(cat $f)" = 0 ] && have ip && [ -n "$(ip -6 addr show dev $i 2>/dev/null)" ] || continue
    if q "$i has IPv6 on: the capture NIC answers and sends its own packets (ND/MLD). Disable IPv6 on $i?" \
       "disable_ipv6 = 1 on $i only, capture unaffected, until reboot; undo: bash doctor.sh revert" "IPv6 stays on $i" y; then
      grep -q "^$i " $DST/ipv6.orig 2>/dev/null || echo "$i 0" >> $DST/ipv6.orig; echo 1 > $f
      ok "$i IPv6 off"; CHG+=("IPv6 off on $i, until reboot (doctor revert)"); fi; done
}
revert_quick() {
  local f v i
  [ -f $DST/rps.orig ] && { while read f v; do echo $v > $f 2>/dev/null; done < $DST/rps.orig; rm -f $DST/rps.orig; echo "RPS restored"; }
  [ -f $DST/gov.orig ] && { v=$(cat $DST/gov.orig); for f in $CPUDIR/cpu[0-9]*/cpufreq/scaling_governor; do echo $v > $f 2>/dev/null; done; rm -f $DST/gov.orig; echo "governor back to $v"; }
  [ -f $DST/ipv6.orig ] && { while read i v; do echo $v > /proc/sys/net/ipv6/conf/$i/disable_ipv6 2>/dev/null; done < $DST/ipv6.orig; rm -f $DST/ipv6.orig; echo "IPv6 restored"; }
  q "Also undo nic.sh?" "$RS: ring, queues, GRO/LRO, IRQs, irqbalance back to the original" "nic.sh settings stay" && NICS="$NICS" bash $HERE/nic.sh revert
  q "Also undo capfit.sh?" "offloads, kernel settings, priorities and drop-ins back to the original" "capfit.sh settings stay" && NICS="$NICS" bash $HERE/capfit.sh revert
}

# ================================= main =================================
[ $(id -u) -eq 0 ] || [ -n "${NOROOT:-}" ] || { echo "run as root (sudo su -)"; exit 1; }
for s in diag.sh dup.sh nic.sh capfit.sh; do [ -r $HERE/$s ] || { echo "missing $HERE/$s (git pull)"; exit 1; }; done
choose
[ "${1:-}" = revert ] && { revert_quick; exit; }
exec > >(tee -a $LOG) 2>&1
touch $DST/.start-$TS; CST=${CAPFIT_ST:-/root/capfit}
trap 'echo; echo "stopped. log: $LOG  summary so far: $SUM"; exit 1' INT
sum "doctor $(date '+%F %T')  host $(hostname)  NICs: $NICS"
echo "doctor  host $(hostname)  NICs: $NICS  log $LOG"
for t in ethtool tcpdump perf; do have $t || note "$t not installed: $([ $t = perf ] && echo 'no kernel profile (linux-tools-$(uname -r))' || echo 'some checks are skipped')"; done

stage "1/9 licence snapshot (must be identical at the end)"
lic | tee $DST/licence-before-$TS.txt

stage "2/9 loss now"
for i in $NICS; do echo "$i: $(ethtool -i $i 2>/dev/null | awk -F': ' '/^driver|^firmware/{printf "%s %s  ", $1, $2}') speed $(cat $SYS/$i/speed 2>/dev/null) Mb/s"; done
measure before

stage "3/9 diagnosis (diag.sh, read-only, ~$((DIAG_S + 30)) s)"
NICS="$NICS" S=$DIAG_S bash $HERE/diag.sh | tee $DST/diag-before-$TS.txt
COST0=$(cost_of $DST/diag-before-$TS.txt)

stage "4/9 what is broken and what to do"
sum ""; sum "== findings"
explain $DST/diag-before-$TS.txt
[ -z "$(findings $DST/diag-before-$TS.txt)" ] && ok "diag.sh found nothing obvious"

stage "5/9 duplicates and loops in the mirror (dup.sh, up to 60 s per NIC)"
if have tcpdump && q "Check duplicates on $NICS?" "tcpdump reads 100000 packets per NIC (max 60 s each), changes nothing" "skip, go to quick fixes" y; then for i in $NICS; do dupcheck $i; done; fi

stage "6/9 quick fixes (no link reset, undo: bash doctor.sh revert)"
quick; if [ ${#CHG[@]} -gt 0 ]; then measure after-quick; compare before after-quick; else ok "nothing to fix here"; fi

stage "7/9 verdict before tuning"
if [ -n "$ROOT" ]; then
  bad "root causes found:$(echo $ROOT | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  echo "   These multiply the cost of every packet. Fix them first: NIC tuning alone gives only a few points."
elif awk -v x=$(maxloss before) 'BEGIN{exit !(x<1)}'; then ok "no loss at the NIC and no root cause: nothing to repair, capfit below only checks that recordings are correct"
else ok "no root cause found in copies, sockets, bridge, duplicates or stack; tuning is the next step"; fi
echo "   cost per packet now: ${COST0:-n/a (traffic below 100k pps)}${COST0:+ us} (normal 0.3-1 us per consumer)"

stage "8/9 NIC tuning and host fitting"
L0=$(maxloss before); TUNE=1
if awk -v x=$L0 'BEGIN{exit !(x<1)}'; then
  ok "no loss at the NIC (max $L0%): nothing for nic.sh to improve"
  q "Run nic.sh anyway?" "$RS: check, then apply if you confirm; n2disk loses a few seconds" "skip nic.sh (recommended)" || TUNE=0
else
  q "Are we in the agreed window? nic.sh resets the links" "go on: nic.sh check (read-only), then a separate question before apply" "skip nic.sh, run it later in the window" y || TUNE=0
fi
if [ $TUNE = 1 ]; then
  Q=""; if [ -n "$COST0" ] && awk -v c=$COST0 'BEGIN{exit !(c>2)}'; then
    Q=$(for i in $NICS; do ethtool -l $i 2>/dev/null | awk '/Current/{c=1} c&&/^Combined:/{print $2; exit}'; done | sort -n | tail -1)
    [ -n "$Q" ] && note "cost per packet is $COST0 us: keeping the current $Q queues (fewer queues would make the loss worse now)"; fi
  env NICS="$NICS" ${Q:+Q=$Q} bash $HERE/nic.sh check
  if q "Apply nic.sh to $NICS?" "$RS ~3 s (n2disk loses them): ring to max, GRO/LRO off, IRQs on the NIC's own cores, irqbalance off; then measured" "nothing changes, go to capfit" y; then
    env NICS="$NICS" ${Q:+Q=$Q} bash $HERE/nic.sh apply
    measure after-nic; compare before after-nic; rc=$?
    if [ $rc = 0 ]; then ok "nic.sh lowered the loss"
      if q "Keep the nic.sh tuning after reboot?" "installs nic-tune.service (runs before n2disk at boot); undo: bash nic.sh revert" "tuning lasts until reboot" y; then
        env NICS="$NICS" ${Q:+Q=$Q} bash $HERE/nic.sh persist; CHG+=("nic.sh apply + persist (undo: bash nic.sh revert)")
      else CHG+=("nic.sh apply, until reboot (undo: bash nic.sh revert)"); fi
    elif [ $rc = 2 ]; then ok "no loss before or after: nothing to improve, settings kept (they match the recommendation)"
      CHG+=("nic.sh apply, until reboot, no loss to improve (undo: bash nic.sh revert)")
    else bad "nic.sh did not lower the loss"
      if q "Undo nic.sh?" "$RS: ring, queues, GRO/LRO, IRQs, irqbalance back to the original" "keep it (it does no harm), undo later: bash nic.sh revert" y; then
        NICS="$NICS" bash $HERE/nic.sh revert
      else CHG+=("nic.sh apply without gain (undo: bash nic.sh revert)"); fi; fi
  fi
fi
NICS="$NICS" bash $HERE/capfit.sh check
if q "Run capfit.sh?" "a separate question before EVERY change (offloads, kernel, priorities); VLAN stripping is the customer's decision" "skip, nothing changes" y; then
  NICS="$NICS" bash $HERE/capfit.sh all | tee $DST/capfit-$TS.txt
  CF=$(grep -E '^    [^ ]' $DST/capfit-$TS.txt | grep -vE '^    (kept|Y |N |\[)' | sed 's/^ *//')
  if [ -n "$CF" ]; then
    while IFS= read -r c; do CHG+=("capfit: $c"); done <<< "$CF"; CHG+=("(undo capfit: bash capfit.sh revert)")
    measure after-capfit; compare before after-capfit; rc=$?
    [ $rc = 0 ] && ok "loss lower than at the start" || note "no change in loss (capfit is mostly about correct recordings, not speed)"
    if [ -f $CST/offl.off ] && [ $CST/offl.off -nt $DST/.start-$TS ]; then
      q "Turn the same offloads off at every boot?" "installs capfit.service (before n2disk); undo: bash capfit.sh revert" "offloads come back after reboot" y &&
        NICS="$NICS" bash $HERE/capfit.sh persist; fi
  else ok "capfit changed nothing"; fi
fi

stage "9/9 result"
measure final
DF=""; if q "Run diag.sh again for the 'after' report?" "read-only, ~$((DIAG_S + 15)) s, saved next to the 'before' report" "skip, the summary uses the loss measurements only" y; then
  NICS="$NICS" S=$DIAG_S DUP=0 bash $HERE/diag.sh > $DST/diag-after-$TS.txt 2>&1; DF=$DST/diag-after-$TS.txt
  echo "after report: $DF"; fi
lic > $DST/licence-after-$TS.txt
if diff -q $DST/licence-before-$TS.txt $DST/licence-after-$TS.txt >/dev/null; then ok "n2disk SystemID and licence unchanged"
else bad "${R}n2disk SystemID/licence output CHANGED - stop and check before anything else${N}"; diff $DST/licence-before-$TS.txt $DST/licence-after-$TS.txt; fi

{ echo; echo "== loss per NIC (label nic loss% arriving_pps Gbit/s avg_B)"; cat $MF
  C1=$([ -n "$DF" ] && cost_of $DF); na="n/a (traffic below 100k pps)"
  echo; echo "== cost per packet: before ${COST0:-$na}${COST0:+ us}, after ${C1:-$([ -n "$DF" ] && echo "$na" || echo "not measured")}${C1:+ us} (normal 0.3-1 us per consumer)"
  echo; echo "== changed today"; [ ${#CHG[@]} -eq 0 ] && echo "nothing"; for c in "${CHG[@]}"; do echo "- $c"; done
  echo; echo "== open for the customer"; [ ${#OPEN[@]} -eq 0 ] && echo "nothing"; for c in "${OPEN[@]}"; do echo "- $c"; done
  awk -v x=$(maxloss final) 'BEGIN{exit !(x>=1)}' && { echo; echo "== loss stays ($(maxloss final)%): once the root causes are gone, next is the PF_RING ZC driver + zbalance_ipc (licence) and a dedicated capture disk"; }
} >> $SUM
stage "summary ($SUM)"; cat $SUM
echo; echo "log $LOG   reports in $DST   undo quick fixes: bash doctor.sh revert"
