#!/bin/bash
# hist - READ-ONLY: when did PF_RING / n2disk / nprobe / kernel / docker change, vs boot and n2disk start
echo "boot: $(uptime -s)   now: $(date '+%F %T')"
echo "pf_ring module loaded: $(stat -c %y /sys/module/pf_ring 2>/dev/null | cut -d. -f1)"
for p in $(pgrep -x n2disk) $(ps -eo pid,comm | awk '$2~/^nprobe/{print $1}'); do echo "pid $p $(ps -o comm= -p $p) started $(ps -o lstart= -p $p)"; done
echo "--- package installs/upgrades (pfring, n2disk, nprobe, linux-image, docker, i40e)"
zgrep -hE ' (install|upgrade) ' /var/log/dpkg.log* 2>/dev/null | grep -E 'pfring|n2disk|nprobe|ntop|linux-image|linux-modules|docker|containerd|i40e' | sort | tail -40
echo "--- dkms"; dkms status 2>/dev/null | grep -iE 'pf_ring|pfring|i40e'
echo "--- loaded i40e: $(modinfo -F filename i40e 2>/dev/null)  pf_ring: $(modinfo -F filename pf_ring 2>/dev/null)"
echo "--- docker started: $(systemctl show docker -p ActiveEnterTimestamp --value 2>/dev/null)"
