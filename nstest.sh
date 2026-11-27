#!/bin/bash
# nstest - does PF_RING deliver every packet once per network namespace? (adds one empty netns for ~10 s, then removes it)
#   bash nstest.sh <nic>        expected if yes: ratio grows by ~1.0 while the test netns exists
# Ratio = packets seen by a PF_RING consumer (tcpdump with PF_RING libpcap) / driver rx_packets, 5 s each.
set -u
i=${1:?nic}; NS=pfring-nstest
meas() { local a b r o
  a=$(cat /sys/class/net/$i/statistics/rx_packets); o=$(timeout -s INT 5 tcpdump -nni $i -w /dev/null 2>&1); b=$(cat /sys/class/net/$i/statistics/rx_packets)
  r=$(echo "$o" | sed -n 's/^\([0-9]*\) packets received by filter.*/\1/p')
  awk -v l="$1" -v d=$((b-a)) -v r=${r:-0} -v n=$(ls -l /proc/*/ns/net 2>/dev/null | awk '{print $NF}' | sort -u | wc -l) \
    'BEGIN{printf "%-16s netns %d  driver %8.0f pps  pf_ring %8.0f pps  ratio %.2fx\n", l, n, d/5, r/5, (d>0?r/d:0)}'; }
trap 'ip netns del $NS 2>/dev/null' EXIT
meas before
ip netns add $NS || exit 1; ip netns exec $NS ip link set lo up; sleep 1
meas "with +1 netns"
ip netns del $NS; sleep 2
meas after
echo "ratio +1 with the extra netns = PF_RING hooks every namespace (fix: fewer netns, e.g. containers with network_mode: host, or a PF_RING fix)"
