#!/bin/bash
# bundle - READ-ONLY: everything needed to reproduce / report the PF_RING packet multiplication (for ntop and our lab)
#   bash bundle.sh      -> /root/diag/bundle-<host>-<date>.tgz  (no packet payloads, only headers of 20 packets)
set -u
N2CONF=${N2CONF:-/etc/n2disk/n2disk.conf}; HERE=$(cd "$(dirname "$0")" && pwd)
NICS=${NICS:-$(sed -n 's/^ *-i[= ]*//p' $N2CONF 2>/dev/null | tr ',' ' ')}
B=/root/diag/bundle-$(hostname)-$(date +%Y%m%d-%H%M%S); mkdir -p $B
r() { local f=$1; shift; { echo "# $*"; "$@"; } > $B/$f 2>&1; }
r uname.txt uname -a; r os.txt cat /etc/os-release
r pfring-info.txt cat /proc/net/pf_ring/info
for f in /proc/net/pf_ring/[0-9]*-*; do [ -r "$f" ] && cp "$f" $B/ring-${f##*/}.txt; done
for d in /proc/net/pf_ring/dev/*/info; do [ -r "$d" ] && { echo "-- $d"; cat "$d"; }; done > $B/pfring-dev.txt
for p in /sys/module/pf_ring/parameters/*; do echo "${p##*/} = $(cat $p)"; done > $B/pfring-params.txt 2>&1
r pfring-pkg.txt sh -c 'dpkg -l | grep -iE "pfring|n2disk|nprobe|ntop"'
r dmesg-pfring.txt sh -c 'dmesg -T | grep -iE "pf_ring|pfring|i40e" | tail -200'
r ptype.txt cat /proc/net/ptype
r iplink.txt ip -d link
r netns.txt sh -c 'ip netns list; ls -l /proc/*/ns/net 2>/dev/null | awk "{print \$NF}" | sort | uniq -c'
r docker.txt sh -c 'docker ps --format "{{.Names}} {{.Image}} {{.Networks}} {{.Status}}" 2>&1; docker network ls 2>&1'
r procs.txt sh -c 'ps -eo pid,comm,args | grep -E "[n]2disk|[n]probe|[t]cpdump|[p]fcount|[z]balance|[c]ento" | cut -c1-300'
r n2disk.conf.txt cat $N2CONF
for i in $NICS; do
  r ethtool-$i.txt sh -c "ethtool -i $i; ethtool -l $i; ethtool -g $i; ethtool -k $i; ethtool --show-priv-flags $i; ethtool -S $i"
  a=$(cat /sys/class/net/$i/statistics/rx_packets); o=$(timeout -s INT 5 tcpdump -nni $i -w /dev/null 2>&1); b=$(cat /sys/class/net/$i/statistics/rx_packets)
  echo "$i driver rx_packets in 5 s: $((b-a)); PF_RING tcpdump: $o" > $B/ratio-$i.txt
done
bash $HERE/copies.sh > $B/copies.txt 2>&1
tar czf $B.tgz -C $(dirname $B) $(basename $B) && rm -rf $B && echo "bundle: $B.tgz ($(du -h $B.tgz | cut -f1))"
