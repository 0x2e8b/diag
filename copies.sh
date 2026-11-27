#!/bin/bash
# copies - READ-ONLY look at the 5 copies of one packet in a recent n2disk PCAP: timestamps, MACs, VLAN, ip id.
#   same timestamp to the ns = the same packet put into the ring 5 times (PF_RING); different = separate packets
#   bash copies.sh [file.pcap]       (first undoes q64.sh on any NIC it changed)
set -u
N2CONF=${N2CONF:-/etc/n2disk/n2disk.conf}
for s in /root/q64/*; do [ -f "$s" ] || continue; i=${s##*/}; echo "undo q64 on $i"; bash "$(dirname "$0")/q64.sh" $i revert; done
F=${1:-}
if [ -z "$F" ]; then DIR=$(sed -n 's/^ *\(-o\|--dump-directory\)[= ]*//p' $N2CONF 2>/dev/null | head -1)
  F=$(find ${DIR:-/storage/pcaps/rolling} -name '*.pcap' -mmin -30 -size +1M 2>/dev/null | xargs -r ls -t 2>/dev/null | sed -n 2p); fi
[ -r "$F" ] || { echo "no pcap found: bash copies.sh /path/file.pcap"; exit 1; }
echo "file: $F"; echo
tcpdump -nn -e -v --time-stamp-precision=nano -r "$F" -c 20000 2>/dev/null |
  awk '/^[0-9][0-9]:/{if(h!="")print h; h=$0; next}{h=h" "$0} END{if(h!="")print h}' |
  awk '{ k=$0; sub(/^[0-9:.]+ /,"",k); sub(/[0-9a-f:]{17} > [0-9a-f:]{17}, /,"",k)
         gsub(/ethertype 802\.1Q(-QinQ)? \(0x[0-9a-f]+\), /,"",k); gsub(/vlan [0-9]+, p [0-9]+, /,"",k)
         sub(/length [0-9]+: /,"",k); gsub(/(ttl|hlim) [0-9]+, /,"",k); gsub(/, cksum 0x[0-9a-f]+[^)]*\)/,")",k)
         c[k]++; L[k]=L[k] "\n" $0; if(c[k]==4 && n<3){ o[++n]=k } }
       END{ if(!n){ print "no packet with 4+ copies in the first 20000"; exit }
            for(j=1;j<=n;j++){ printf "=== packet %d: %d copies%s\n\n", j, c[o[j]], L[o[j]]; print "" } }' | cut -c1-260
echo "=== PF_RING device info"
for d in /proc/net/pf_ring/dev/*/info; do [ -r "$d" ] || continue; echo "-- $d"; sed 's/^/  /' "$d"; done
