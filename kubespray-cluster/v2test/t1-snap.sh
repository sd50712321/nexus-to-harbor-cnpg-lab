#!/bin/bash
# 노드 한 대의 V2 상태 한 번 찍기 (노드 안에서 root 로 실행)
p=$(pgrep -f '^spdk_tgt' | head -1)
echo "== $(date +%H:%M:%S) spdk_tgt: pid=$p $( [ -n "$p" ] && ps -o etime=,stat= -p $p | tr -s ' ')"
echo "-- dm";   dmsetup info -c --noheadings -o name,suspended,open 2>/dev/null | grep -v ubuntu
echo "-- nvme"; for c in /sys/class/nvme/nvme*; do [ -e $c ] && echo "   $(basename $c) $(cat $c/state 2>/dev/null) $(cat $c/address 2>/dev/null) $(ls $c | grep -E '^nvme[0-9]+c?[0-9]*n[0-9]+' | tr '\n' ' ')"; done
for b in /sys/block/nvme*n*; do [ -e $b ] && echo "   $(basename $b) size=$(cat $b/size)"; done
echo "-- D";    ps -eo pid,stat,etime,ppid,args | awk '$2 ~ /^D/' | cut -c1-150
