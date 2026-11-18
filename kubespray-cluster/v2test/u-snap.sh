#!/bin/bash
# 노드 상태 한 장: spdk_tgt, dm, nvme 컨트롤러, D 상태 프로세스와 커널 스택 윗부분
P=$(pgrep -f '^spdk_tgt' | head -1)
echo "== $(date -u +%H:%M:%S) spdk_tgt pid=$P $(ps -o etime=,stat= -p ${P:-1} 2>/dev/null)"
echo "-- dm (name:suspended:open)"; dmsetup info -c --noheadings -o name,suspended,open 2>/dev/null | sed 's/^/   /'
echo "-- nvme"; for c in /sys/class/nvme/nvme*; do [ -e $c ] && echo "   $(basename $c) $(cat $c/state 2>/dev/null) $(cat $c/address 2>/dev/null | cut -d, -f1-2)"; done
for d in /sys/block/dm-*; do [ -e $d ] && echo "   $(basename $d) slaves=[$(ls $d/slaves | tr '\n' ' ')]"; done
echo "-- D"; ps -eo pid,ppid,stat,etimes,comm,args --no-headers | awk '$3 ~ /^D/' | cut -c1-110 | while read pid rest; do
  echo "   $pid $rest"; grep -v '^\[<0>\] \(entry_\|do_syscall\|x64_sys\|__x64\|ret_from\|el0\|invoke_syscall\|do_el0\|__arm64\|kthread\|worker_thread\)' /proc/$pid/stack 2>/dev/null | head -7 | sed 's/^\[<0>\]/      /'; done
