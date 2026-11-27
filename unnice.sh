#!/bin/bash
# Undo the nice that capfit.sh set on n2disk (live + systemd drop-ins). nprobe is left as it is.
# OOM protection and locked memory stay. Nothing restarts.  usage: bash unnice.sh
set -u
ST=${ST:-/root/capfit}; UNITDIR=${UNITDIR:-/etc/systemd/system}
for p in $(pgrep -x n2disk); do
  v=0; [ -r $ST/prio.$p ] && v=$(cut -d' ' -f1 $ST/prio.$p)
  [[ $v =~ ^-?[0-9]+$ ]] || v=0
  renice -n $v -p $p >/dev/null && echo "n2disk pid $p: nice $(ps -o ni= -p $p | tr -d ' ')"
done
n=0
for f in $UNITDIR/n2disk*.service.d/60-capfit-nice.conf; do [ -f "$f" ] || continue; rm -f "$f"; echo "removed $f"; n=$((n+1)); done
[ $n -gt 0 ] && systemctl daemon-reload && echo "systemd reloaded (n2disk starts with default nice next time)"
echo "done: n2disk nice undone, OOM protection / memlock kept, nprobe untouched"
