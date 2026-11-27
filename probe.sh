#!/bin/bash
# probe - READ-ONLY follow-up after doctor/diag: answers the open questions in one run (~40 s), changes nothing.
#   1 counters: port vs driver vs PF_RING rings (who counts what), busiest queues
#   2 why traffic sits in one queue: VLAN tags / QinQ / tunnels / elephant flows, RSS table and hash fields
#   3 LOOP examples: real routing loop or a chain of routers in the mirror
#   4 n2disk / nprobe threads: which cores, which NUMA node, n2disk.conf
#   5 disk under n2disk: devices, MB/s written, busy, free disks
#   6 hot softirq CPUs per NUMA node, 7 perf package
#   NICS="eno1np0 eno2np1" S=10 bash probe.sh        report: /root/diag/probe-<date>.txt
set -u
S=${S:-10}; N2CONF=${N2CONF:-/etc/n2disk/n2disk.conf}; OUT=${OUT:-/root/diag}; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $OUT; REP=$OUT/probe-$(date +%Y%m%d-%H%M%S).txt; exec > >(tee $REP) 2>&1
D=$(mktemp -d); trap 'rm -rf $D' EXIT
have() { command -v $1 >/dev/null 2>&1; }
h()    { echo; echo "=== $*"; }
cpunode() { local d; d=$(ls -d /sys/devices/system/cpu/cpu$1/node* 2>/dev/null | head -1); [ -n "$d" ] && echo ${d##*node} || echo ?; }
[ -z "${NICS:-}" ] && [ -r $N2CONF ] && NICS=$(sed -n 's/^ *-i[= ]*//p' $N2CONF | tr ',' ' ')
NICS=$(echo ${NICS:-}); [ -z "$NICS" ] && { echo 'NICS="eno1np0 eno2np1" bash probe.sh'; exit 1; }

snapn() { ethtool -S $1 2>/dev/null | awk -F: 'NF>=2{k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k); v=$2; gsub(/[ \t]/,"",v); if(k!="" && v~/^[0-9]+$/) print k, v}'
          for f in rx_packets rx_missed_errors rx_dropped tx_packets; do echo "sys_$f $(cat /sys/class/net/$1/statistics/$f 2>/dev/null || echo 0)"; done; }
snapr() { for f in /proc/net/pf_ring/[0-9]*-*; do [ -r "$f" ] || continue
  awk -v f="${f##*/}" -F: '{k=$1; gsub(/^ +| +$/,"",k); gsub(/ /,"_",k); v=substr($0,index($0,":")+1); gsub(/ /,"",v)
    if(k~/^(Tot_Packets|Tot_Pkt_Lost|Tot_Insert|Tot_Read|Appl._Name|Bound_Device\(s\)|Cluster_Id)$/) print f, k, (v==""?"-":v)}' "$f"; done; }

echo "probe $(date '+%F %T')  host $(hostname)  NICs: $NICS  sample ${S}s  (read-only)"
for i in $NICS; do snapn $i > $D/n0.$i; done; snapr > $D/r0; cat /proc/stat > $D/c0; cat /proc/diskstats > $D/d0
sleep $S
for i in $NICS; do snapn $i > $D/n1.$i; done; snapr > $D/r1; cat /proc/stat > $D/c1; cat /proc/diskstats > $D/d1

# ---------- 1 counters ----------
h "1 counters per second: port (what reached the NIC) vs driver vs PF_RING"
DRV=""
for i in $NICS; do
  echo "$i:"
  awk -v s=$S 'NR==FNR{a[$1]=$2; next} ($1 in a){d=$2-a[$1]; if(d<0 && a[$1]<4294967296) d+=4294967296; D[$1]=d}
    END{ P=D["port.rx_unicast"]+D["port.rx_multicast"]+D["port.rx_broadcast"]; V=D["rx_unicast"]+D["rx_multicast"]+D["rx_broadcast"]
      r=("rx_packets" in D)?D["rx_packets"]:D["sys_rx_packets"]; m=("rx_missed_errors" in D)?D["rx_missed_errors"]:D["sys_rx_missed_errors"]
      printf "  port in (port.rx_uc+mc+bc) %10.0f  port.rx_dropped %9.0f  port.rx_discards %9.0f\n", P/s, D["port.rx_dropped"]/s, D["port.rx_discards"]/s
      printf "  vsi in  (rx_uc+mc+bc)      %10.0f  rx_discards     %9.0f\n", V/s, D["rx_discards"]/s
      printf "  driver rx_packets          %10.0f  sys rx_packets  %9.0f  missed %9.0f  sys missed %9.0f\n", r/s, D["sys_rx_packets"]/s, m/s, D["sys_rx_missed_errors"]/s
      printf "  tx_packets                 %10.0f  port.tx_uc+mc+bc %8.0f\n", D["tx_packets"]/s, (D["port.tx_unicast"]+D["port.tx_multicast"]+D["port.tx_broadcast"])/s
      if(P>0) printf "  check: (driver + missed) / port in = %.0f%%,  port.rx_dropped / port in = %.1f%%\n", 100*(r+m)/P, 100*D["port.rx_dropped"]/P
      for(k in D) if(k~/^rx-[0-9]+\.packets$|^rx_queue_[0-9]+_packets$/ && D[k]>0){ q[k]=D[k]; qt+=D[k] }
      n=0; while(n<3){ mx=0; mk=""; for(k in q) if(q[k]>mx){mx=q[k]; mk=k}; if(mk=="") break; printf "%s %s %.0f%%", (n?",":"  busiest queues:"), mk, 100*mx/qt; delete q[mk]; n++ }; if(n) print ""
      printf "RES %.0f\n", r/s > "/dev/stderr" }' $D/n0.$i $D/n1.$i 2>$D/res.$i
  DRV="$DRV $i:$(sed -n 's/^RES //p' $D/res.$i)"
done
echo "PF_RING rings (per second):"
awk -v s=$S -v drv="$DRV" 'BEGIN{n=split(drv,x," "); for(j=1;j<=n;j++){split(x[j],y,":"); dr[y[1]]=y[2]}}
  NR==FNR{a[$1" "$2]=$3; next} {f=$1; R[f]=1; if($2~/^Tot_/) v[f,$2]=($3-a[f" "$2])/s; else t[f,$2]=$3}
  END{ for(f in R){ m=split(t[f,"Bound_Device(s)"],dv,","); sd=0; for(j=1;j<=m;j++) sd+=dr[dv[j]]
    printf "  %-22s %-8s %-18s cl %-3s packets %9.0f lost %8.0f insert %9.0f read %9.0f | driver rx of its NICs %9.0f -> ratio %.1fx\n",
      f, t[f,"Appl._Name"], t[f,"Bound_Device(s)"], t[f,"Cluster_Id"], v[f,"Tot_Packets"], v[f,"Tot_Pkt_Lost"], v[f,"Tot_Insert"], v[f,"Tot_Read"], sd, (sd>0?v[f,"Tot_Packets"]/sd:0) } }' $D/r0 $D/r1

# ---------- 2 queue concentration ----------
h "2 what the traffic looks like (3000 packets per NIC; only what the NIC delivered)"
for i in $NICS; do
  echo "$i:"
  timeout 15 tcpdump -nni $i -c 3000 -w $D/$i.pcap 2>/dev/null
  tcpdump -nn -e -r $D/$i.pcap 2>/dev/null | awk '
    { n++; t=gsub(/vlan [0-9]+/,"&"); tags[t]++
      s=$0; last=""; while(match(s,/ethertype [^ ,]+/)){ last=substr(s,RSTART+10,RLENGTH-10); s=substr(s,RSTART+RLENGTH) } et[last]++
      if($0~/QinQ|0x88a8|0x9100/) qq++
      if($0~/GRE|VXLAN|ERSPAN|[Gg]eneve|MPLS|GTP|ip-proto-4[^0-9]|ip-proto-41|IPIP/) tun++
      if(match($0,/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)? > [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?:/)){
        f=substr($0,RSTART,RLENGTH-1); fl[f]++; split(f,xy," > "); a=xy[1]; b=xy[2]
        if(split(a,p,".")==5) a=p[1]"."p[2]"."p[3]"."p[4]; if(split(b,p,".")==5) b=p[1]"."p[2]"."p[3]"."p[4]; ip[a" > "b]++ } }
    END{ if(!n){ print "  no packets captured"; exit }
      printf "  packets %d, vlan tags per packet:", n; for(k in tags) printf " %sx=%.0f%%", k, 100*tags[k]/n; print ""
      printf "  inner ethertype:"; for(k in et) printf " %s=%.0f%%", (k==""?"none":k), 100*et[k]/n; print ""
      printf "  QinQ frames %.1f%%, tunnel (GRE/VXLAN/ERSPAN/MPLS/GTP/IPIP) %.1f%%\n", 100*qq/n, 100*tun/n
      print "  top flows (5-tuple) % of packets:"; for(k in fl) printf "    %5.1f%%  %s\n", 100*fl[k]/n, k | "sort -rn | head -5"; close("sort -rn | head -5")
      print "  top IP pairs % of packets:";        for(k in ip) printf "    %5.1f%%  %s\n", 100*ip[k]/n, k | "sort -rn | head -5"; close("sort -rn | head -5") }'
  if have ethtool; then
    echo "  rss tcp4: $(ethtool -n $i rx-flow-hash tcp4 2>/dev/null | grep -vE '^$|^TCP' | tr '\n' ' ')"
    echo "  rss udp4: $(ethtool -n $i rx-flow-hash udp4 2>/dev/null | grep -vE '^$|^UDP' | tr '\n' ' ')"
    echo "  rss table: $(ethtool -x $i 2>/dev/null | awk '/^ *[0-9]+:/{for(j=2;j<=NF;j++){q[$j]=1; t++}} END{n=0; for(k in q) n++; printf "%d entries over %d queues", t, n}')"
    echo "  ntuple rules: $(ethtool -n $i 2>/dev/null | grep -m1 -i 'Total' | tr -s ' ')"
    echo "  offloads: $(ethtool -k $i 2>/dev/null | grep -E '^(rx-vlan-offload|rx-vlan-filter|ntuple-filters|receive-hashing):' | tr -s ' ' | tr '\n' ' ')"
    echo "  priv flags on: $(ethtool --show-priv-flags $i 2>/dev/null | awk -F: '$2~/on/{gsub(/ /,"",$1); printf "%s ", $1}')"
  fi
done

# ---------- 3 LOOP examples ----------
h "3 LOOP examples (ttl list and vlans of one packet; 2-3 TTLs on different vlans = chain of routers in the mirror, many falling TTLs = real loop)"
for i in $NICS; do [ -s $D/$i.pcap ] || continue; echo "$i:"
  SHOW=8 KIND=LOOP bash $HERE/dup.sh $D/$i.pcap 2>/dev/null | grep -E '^ *[0-9]+x LOOP' | sed 's/^/  /'; done
echo "(sample of 3000 packets; more: SHOW=20 KIND=LOOP bash dup.sh <nic> 50000)"

# ---------- 4 threads ----------
h "4 capture application threads (psr = core now, node = NUMA node; NICs on node $(cat /sys/class/net/$(set -- $NICS; echo $1)/device/numa_node 2>/dev/null))"
for p in $(ps -eo pid,comm | awk '$2~/^(n2disk|nprobe)/{print $1}'); do
  echo "pid $p $(ps -o comm= -p $p): affinity $(taskset -pc $p 2>/dev/null | sed 's/.*: //')"
  echo "  cmd: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-400)"
  ps -L -o tid=,psr=,pcpu=,comm= -p $p | sort -k3 -rn | head -8 | while read t c u n; do echo "    tid $t core $c node $(cpunode $c) cpu ${u}% $n"; done
done
[ -r $N2CONF ] && { echo "n2disk.conf:"; grep -vE '^\s*(#|$)' $N2CONF | sed 's/^/  /'; }

# ---------- 5 disk ----------
h "5 disk under n2disk"
DIR=$([ -r $N2CONF ] && sed -n 's/^ *\(-o\|--dump-directory\)[= ]*//p' $N2CONF | head -1)
[ -n "$DIR" ] && df -h $DIR | tail -1
paste -d' ' <(awk '{print $3, $10, $13}' $D/d0) <(awk '{print $10, $13}' $D/d1) | awk -v s=$S '$2!=$4 || $3!=$5 {w=($4-$2)*512/s/1e6; u=100*($5-$3)/(s*1000); if(w>1 || u>5) printf "  %-12s write %7.1f MB/s  busy %5.1f%%\n", $1, w, u}'
for dm in /sys/block/dm-*; do [ -d $dm/slaves ] && echo "  ${dm##*/} = $(cat $dm/dm/name 2>/dev/null) on: $(ls $dm/slaves | tr '\n' ' ')"; done
lsblk -o NAME,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null | grep -vE 'loop' | sed 's/^/  /' | head -30

# ---------- 6 hot CPUs ----------
h "6 CPUs >90% softirq per NUMA node"
paste <(grep -E '^cpu[0-9]+ ' $D/c0) <(grep -E '^cpu[0-9]+ ' $D/c1) | awk '{t0=0; for(i=2;i<=11;i++) t0+=$i; t1=0; for(i=13;i<=22;i++) t1+=$i; d=t1-t0; c=$1; sub("cpu","",c); if(d>0 && 100*($19-$8)/d>90) print c}' |
  while read c; do echo "$(cpunode $c) $c"; done | awk '{n[$1]++; l[$1]=l[$1] " " $2} END{for(k in n) printf "  node %s: %d cpus:%s\n", k, n[k], l[k]}'

# ---------- 7 perf ----------
h "7 perf"
have perf && perf --version 2>/dev/null || { echo "  not installed; package: $(apt-cache policy linux-tools-$(uname -r) 2>/dev/null | sed -n 's/ *Candidate: //p')"; }
echo; echo "report: $REP"
