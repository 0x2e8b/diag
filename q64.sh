#!/bin/bash
# q64 - test: NIC queues down to 64 (PF_RING standard mode supports max 64 channels; with 112 the host saw every packet ~5x).
#   bash q64.sh eno2np1           measure, set combined 64, measure again (queues reset: a few seconds of capture gap)
#   bash q64.sh eno2np1 revert    back to the saved queue count
# Measure = PF_RING-aware tcpdump packets vs driver rx_packets (ratio 1.0 = no multiplication) + NIC loss, 5 s.
set -u
i=${1:?nic}; ST=/root/q64; mkdir -p $ST
meas() { local a m b n o r
  a=$(cat /sys/class/net/$i/statistics/rx_packets); m=$(cat /sys/class/net/$i/statistics/rx_missed_errors)
  o=$(timeout -s INT 5 tcpdump -nni $i -w /dev/null 2>&1)
  b=$(cat /sys/class/net/$i/statistics/rx_packets); n=$(cat /sys/class/net/$i/statistics/rx_missed_errors)
  r=$(echo "$o" | sed -n 's/^\([0-9]*\) packets received by filter.*/\1/p')
  awk -v l="$1" -v d=$((b-a)) -v mm=$((n-m)) -v r=${r:-0} 'BEGIN{printf "%-7s driver %8.0f pps  missed %8.0f pps  loss %5.1f%%  tcpdump %8.0f pps  ratio %.2fx\n", l, d/5, mm/5, (d+mm>0?100*mm/(d+mm):0), r/5, (d>0?r/d:0)}'; }
cur() { ethtool -l $i 2>/dev/null | awk '/Current/{c=1} c&&/^Combined:/{print $2; exit}'; }
if [ "${2:-}" = revert ]; then
  [ -r $ST/$i ] || { echo "nothing saved for $i"; exit 1; }
  ethtool -L $i combined $(cat $ST/$i) && echo "$i combined $(cur) again"; rm -f $ST/$i; exit; fi
c=$(cur); echo "$i: queues now $c"
[ "$c" = 64 ] && { meas now; exit; }
[ -r $ST/$i ] || echo $c > $ST/$i
meas before
ethtool -L $i combined 64 || { echo "ethtool -L failed, nothing changed"; exit 1; }
echo "$i: queues $(cur), waiting 5 s for the link and rings"; sleep 5
meas after
pgrep -x n2disk >/dev/null && echo "n2disk running" || echo "!! n2disk NOT running"
ps -eo comm | grep -q '^nprobe' && echo "nprobe running" || echo "!! nprobe NOT running"
echo "undo: bash q64.sh $i revert"
