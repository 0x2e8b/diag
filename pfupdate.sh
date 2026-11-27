#!/bin/bash
# pfupdate - fix the PF_RING bug "every packet processed once per network namespace" (ntop commit 5923ae6, 2026-07-09)
# without apt. The fix is only in the kernel module (pf_ring.c); n2disk/nprobe and libpfring stay as they are.
#   bash pfupdate.sh check      READ-ONLY: versions, is the fix in the DKMS source / loaded module, netns, ring/driver ratio
#   bash pfupdate.sh build      patch the installed DKMS source (pfring 9.2.0) with the upstream fix and build the module
#                               (nothing is reloaded, capture keeps running on the old module)
#   bash pfupdate.sh build94    alternative: build PF_RING 9.4.0-11029 kernel module from debs/ (fix included)
#   bash pfupdate.sh reload     IN THE WINDOW: stop n2disk/nprobe, reload pf_ring, start them, check licence + ratio
#   bash pfupdate.sh revert     original DKMS source back (and 9.4 removed), then: bash pfupdate.sh reload
# env: PFV=<dkms version> to pick one when several pfring DKMS versions exist (default: highest)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ST=/root/pfupdate; mkdir -p $ST; K=$(uname -r)
LOG=$ST/pfupdate-$(date +%Y%m%d-%H%M%S).log; exec > >(tee -a $LOG) 2>&1
have() { command -v $1 >/dev/null 2>&1; }
die()  { echo "STOP: $*"; exit 1; }
dkver() { [ -n "${PFV:-}" ] && { echo $PFV; return; }; dkms status pfring 2>/dev/null | sed -n 's#^pfring/\([^,:]*\)[,:].*#\1#p' | sort -V | tail -1; }
src()   { echo /usr/src/pfring-$1/pf_ring.c; }
units() { systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -E '^(n2disk|nprobe|cento|zbalance)' ; }
lic()   { have n2disk && { timeout 30 n2disk --show-system-id; timeout 30 n2disk --check-license; } 2>&1 | sed -E 's#[0-9]{2}/[A-Za-z]{3}/[0-9]{4} [0-9:]{8} ##; s#\[[^]]*\] ##g' | grep -v '^ *$'; }
ratio() {   # PF_RING ring packets vs driver rx of the ring's NICs, 10 s; 1.0 = fixed, ~N = once per netns
  local f d0 d1 p0 p1 devs
  for f in /proc/net/pf_ring/[0-9]*-*; do [ -r "$f" ] || continue
    devs=$(awk -F': *' '/^Bound Device/{print $2}' "$f" | tr ',' ' '); [ -z "$devs" ] && continue
    d0=0; for i in $devs; do d0=$((d0 + $(cat /sys/class/net/$i/statistics/rx_packets 2>/dev/null || echo 0))); done
    p0=$(awk -F': *' '/^Tot Packets/{print $2}' "$f"); sleep 10
    d1=0; for i in $devs; do d1=$((d1 + $(cat /sys/class/net/$i/statistics/rx_packets 2>/dev/null || echo 0))); done
    p1=$(awk -F': *' '/^Tot Packets/{print $2}' "$f")
    awk -v f="${f##*/}" -v a="$(awk -F': *' '/^Appl. Name/{print $2}' "$f")" -v d=$((d1-d0)) -v p=$((p1-p0)) \
      'BEGIN{printf "  ring %-22s %-8s driver %9.0f pps  ring %9.0f pps  ratio %.2fx\n", f, a, d/10, p/10, (d>0?p/d:0)}'
  done; }
netns() { ls -l /proc/*/ns/net 2>/dev/null | awk '{print $NF}' | sort -u | wc -l; }

case ${1:-check} in
check)
  echo "kernel $K"; dpkg -l 2>/dev/null | awk '$2~/^(pfring|pfring-dkms|n2disk|nprobe)$/{print "  " $2, $3}'
  echo "loaded: $(grep 'PF_RING Version' /proc/net/pf_ring/info 2>/dev/null)"
  echo "dkms:"; dkms status pfring 2>/dev/null | sed 's/^/  /'
  for s in /usr/src/pfring-*/pf_ring.c; do grep -q handler_registered $s && echo "  $s: FIX PRESENT" || echo "  $s: fix missing"; done
  m=$(modinfo -F filename pf_ring 2>/dev/null); echo "module on disk: $m ($(stat -c %y "$m" 2>/dev/null | cut -d. -f1))"
  echo "module loaded since: $(stat -c %y /sys/module/pf_ring 2>/dev/null | cut -d. -f1)"
  echo "network namespaces: $(netns) (with the bug every packet is processed this many times)"
  echo "running capture units: $(units | tr '\n' ' ')"
  echo "ratio (10 s per ring):"; ratio ;;

build)
  V=$(dkver); [ -n "$V" ] || die "no pfring DKMS module found (dkms status)"; S=$(src $V); [ -w "$S" ] || die "$S not found"
  grep -q handler_registered $S && { echo "fix already in $S"; } || {
    [ -f $ST/pf_ring.c.$V.orig ] || cp -p $S $ST/pf_ring.c.$V.orig
    python3 - "$S" <<'PY' || die "patch failed, source unchanged"
import sys
p=sys.argv[1]; s=open(p).read()
a1="/* Protocol hook */\nstatic struct packet_type init_prot_hook;\n#endif"
b1="/* Protocol hook */\nstatic struct packet_type init_prot_hook;\n#else\nstatic int handler_registered = 0;\n#endif"
a2="#ifndef SINGLE_PROT_HOOK\n  register_device_handler(&netns->prot_hook, net);\n#endif"
b2=("#ifndef SINGLE_PROT_HOOK\n  /* Note: register the protocol hook once, even with multiple\n"
    "   * namespaces, to avoid packet_rcv being called multiple times (ntop 5923ae6). */\n"
    "  if (!handler_registered) {\n    register_device_handler(&netns->prot_hook, &init_net);\n"
    "    handler_registered = 1;\n  }\n#endif")
for a,b in ((a1,b1),(a2,b2)):
    if s.count(a)!=1: sys.exit("context not found exactly once: "+a.splitlines()[-2])
    s=s.replace(a,b)
open(p,'w').write(s); print("patched", p)
PY
  }
  echo "building pfring/$V for $K ..."
  dkms build -m pfring -v $V -k $K --force >$ST/dkms-build.log 2>&1 || { tail -20 $ST/dkms-build.log; die "dkms build failed (log $ST/dkms-build.log); bash pfupdate.sh revert"; }
  dkms install -m pfring -v $V -k $K --force >>$ST/dkms-build.log 2>&1 || { tail -20 $ST/dkms-build.log; die "dkms install failed"; }
  echo "built and installed: $(modinfo -F filename pf_ring)"; echo "NOT loaded yet. In the window: bash pfupdate.sh reload" ;;

build94)
  D=$HERE/debs/pfring-dkms_9.4.0.11029_all.deb; [ -r $D ] || die "$D missing"
  T=$(mktemp -d); dpkg-deb -x $D $T || die "cannot unpack $D"
  [ -d /usr/src/pfring-9.4.0.11029 ] || cp -a $T/usr/src/pfring-9.4.0.11029 /usr/src/; rm -rf $T
  dkms status pfring/9.4.0.11029 2>/dev/null | grep -q . || dkms add -m pfring -v 9.4.0.11029 || die "dkms add failed"
  dkms build -m pfring -v 9.4.0.11029 -k $K --force >$ST/dkms-build94.log 2>&1 || { tail -20 $ST/dkms-build94.log; die "dkms build 9.4 failed"; }
  dkms install -m pfring -v 9.4.0.11029 -k $K --force >>$ST/dkms-build94.log 2>&1 || { tail -20 $ST/dkms-build94.log; die "dkms install 9.4 failed"; }
  echo "PF_RING 9.4.0 kernel module installed: $(modinfo -F filename pf_ring) (userland libpfring stays 9.2, slot version 21 in both)"
  echo "NOT loaded yet. In the window: bash pfupdate.sh reload" ;;

reload)
  echo "licence before:"; lic | tee $ST/lic.before | sed 's/^/  /'
  echo "ratio before:"; ratio
  U=$(units); echo "stopping: $(echo $U)"; echo "$U" > $ST/units
  [ -n "$U" ] && systemctl stop $U
  sleep 2; r=$(awk '$1=="pf_ring"{print $3}' /proc/modules)
  if [ "${r:-0}" != 0 ]; then echo "pf_ring still used by $r:"; ls /proc/net/pf_ring/ | grep -E '^[0-9]+-' | sed 's/^/  /'
    [ -n "$U" ] && systemctl start $U; die "something else holds pf_ring (see rings above); units started again, nothing changed"; fi
  rmmod pf_ring || { [ -n "$U" ] && systemctl start $U; die "rmmod failed; units started again"; }
  modprobe pf_ring || die "modprobe pf_ring FAILED - capture is down! bash pfupdate.sh revert && modprobe pf_ring && systemctl start $(echo $U)"
  echo "loaded: $(grep 'PF_RING Version' /proc/net/pf_ring/info)"
  [ -n "$U" ] && systemctl start $U; sleep 15
  echo "running: $(units | tr '\n' ' ')"
  for u in $U; do systemctl is-active --quiet $u || echo "!! $u NOT running: journalctl -u $u -n 30"; done
  echo "licence after:"; lic | tee $ST/lic.after | sed 's/^/  /'
  diff -q $ST/lic.before $ST/lic.after >/dev/null && echo "licence UNCHANGED" || echo "!! licence output CHANGED - compare $ST/lic.before $ST/lic.after"
  echo "ratio after (expected ~1.0x):"; ratio ;;

revert)
  V=$(ls $ST/pf_ring.c.*.orig 2>/dev/null | sed 's#.*/pf_ring.c.\(.*\).orig#\1#' | head -1)
  if [ -n "$V" ]; then cp -p $ST/pf_ring.c.$V.orig $(src $V) && echo "original source pfring/$V restored"
    dkms build -m pfring -v $V -k $K --force >$ST/dkms-revert.log 2>&1 && dkms install -m pfring -v $V -k $K --force >>$ST/dkms-revert.log 2>&1 && echo "original module rebuilt"; fi
  dkms status pfring/9.4.0.11029 2>/dev/null | grep -q . && dkms remove -m pfring -v 9.4.0.11029 --all && rm -rf /usr/src/pfring-9.4.0.11029 && echo "9.4.0 removed"
  dkms install -m pfring -v $(dkver) -k $K --force >/dev/null 2>&1
  echo "module on disk: $(modinfo -F filename pf_ring). To load it: bash pfupdate.sh reload" ;;
*) sed -n '2,10p' $0 ;;
esac
echo "log: $LOG"
