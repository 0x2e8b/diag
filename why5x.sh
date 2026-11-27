#!/bin/bash
# why5x - READ-ONLY: why the host sees every packet ~5 times (PF_RING and tcpdump get 5x what the NIC port received).
#   1 tcpdump (AF_PACKET) count vs driver rx_packets      2 packet handlers (/proc/net/ptype)
#   3 tc qdisc/filters (mirred re-injection), XDP, upper devices, VFs   4 kernel log   5 modules
#   6 are the 5 copies also in n2disk PCAPs on disk
#   NICS="eno1np0 eno2np1" bash why5x.sh          report: /root/diag/why5x-<date>.txt
set -u
N2CONF=${N2CONF:-/etc/n2disk/n2disk.conf}; OUT=${OUT:-/root/diag}; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $OUT; REP=$OUT/why5x-$(date +%Y%m%d-%H%M%S).txt; exec > >(tee $REP) 2>&1
D=$(mktemp -d); trap 'rm -rf $D' EXIT
h() { echo; echo "=== $*"; }
[ -z "${NICS:-}" ] && [ -r $N2CONF ] && NICS=$(sed -n 's/^ *-i[= ]*//p' $N2CONF | tr ',' ' ')
NICS=$(echo ${NICS:-}); [ -z "$NICS" ] && { echo 'NICS="eno1np0 eno2np1" bash why5x.sh'; exit 1; }
echo "why5x $(date '+%F %T')  host $(hostname)  NICs: $NICS  (read-only)"

h "1 tcpdump vs driver (3 s per NIC): ratio ~5 = every packet reaches the sockets 5 times"
for i in $NICS; do
  a=$(cat /sys/class/net/$i/statistics/rx_packets); o=$(timeout -s INT 3 tcpdump -nni $i -w /dev/null 2>&1); b=$(cat /sys/class/net/$i/statistics/rx_packets)
  r=$(echo "$o" | sed -n 's/^\([0-9]*\) packets received by filter.*/\1/p'); d=$(echo "$o" | sed -n 's/^\([0-9]*\) packets dropped by kernel.*/\1/p')
  awk -v i=$i -v dr=$((b-a)) -v r=${r:-0} -v d=${d:-0} 'BEGIN{printf "  %-10s driver %9.0f pps  tcpdump got %9.0f pps (+%0.f dropped by kernel)  ratio %.2fx\n", i, dr/3, r/3, d/3, (dr>0?r/dr:0)}'
done

h "2 packet handlers (/proc/net/ptype): every line is one consumer of every packet"
cat /proc/net/ptype 2>/dev/null | sed 's/^/  /'

h "3 tc / XDP / upper devices / VFs on the capture NICs"
for i in $NICS; do
  echo "$i:"
  tc qdisc show dev $i 2>/dev/null | sed 's/^/  qdisc: /'
  for dir in ingress egress; do tc -s filter show dev $i $dir 2>/dev/null | sed "s/^/  filter $dir: /" | head -20; done
  ip -d link show $i 2>/dev/null | grep -iE 'xdp|prog|vf [0-9]' | sed 's/^/  link: /'
  ls -d /sys/class/net/$i/upper_* /sys/class/net/$i/lower_* 2>/dev/null | sed 's#.*/#  upper/lower: #'
  echo "  sriov vfs: $(cat /sys/class/net/$i/device/sriov_numvfs 2>/dev/null || echo n/a)"
done
echo "all tc qdiscs with ingress/clsact on the host:"; tc qdisc show 2>/dev/null | grep -E 'ingress|clsact' | sed 's/^/  /'
echo "devices on top of the capture NICs:"; ip -o link 2>/dev/null | grep -E "@($(echo $NICS | tr ' ' '|'))" | cut -c1-150 | sed 's/^/  /'
have_bpf=$(command -v bpftool); [ -n "$have_bpf" ] && { echo "bpf net attachments:"; bpftool net 2>/dev/null | sed 's/^/  /' | head -20; }

h "4 kernel log (mirred / recursion / pf_ring / i40e)"
dmesg -T 2>/dev/null | grep -iE 'mirred|recursion|pf_ring|pfring|i40e.*(vsi|veb|promisc|vf)' | tail -15 | sed 's/^/  /'

h "5 modules"
lsmod | grep -E '^(pf_ring|act_mirred|act_|cls_|sch_ingress|sch_clsact|macvlan|ipvlan|8021q|openvswitch|bridge|veth|vxlan)' | awk '{printf "  %-16s used by %s %s\n", $1, $3, $4}'
echo "pf_ring params:"; for f in /sys/module/pf_ring/parameters/*; do [ -r "$f" ] && echo "  ${f##*/} = $(cat $f)"; done
grep -vE '^\s*$' /proc/net/pf_ring/info 2>/dev/null | sed 's/^/  /'

h "6 n2disk PCAP on disk: are the copies recorded too (20000 packets of a recent closed file)"
DIR=$([ -r $N2CONF ] && sed -n 's/^ *\(-o\|--dump-directory\)[= ]*//p' $N2CONF | head -1)
F=$([ -n "$DIR" ] && find $DIR -name '*.pcap' -mmin -30 -size +1M 2>/dev/null | xargs -r ls -t 2>/dev/null | sed -n 2p)
if [ -n "$F" ]; then echo "  file: $F"
  timeout 30 tcpdump -nn -r "$F" -c 20000 -w $D/p.pcap 2>/dev/null
  SHOW=6 bash $HERE/dup.sh $D/p.pcap 2>/dev/null | grep -E '^ *[0-9]+x |^packets|^duplicated' | sed 's/^/  /'
else echo "  no recent pcap under ${DIR:-?}"; fi
echo; echo "report: $REP"
