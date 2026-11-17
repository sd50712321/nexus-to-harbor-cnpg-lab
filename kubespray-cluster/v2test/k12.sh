#!/bin/bash
# K12: 노드의 V2 디스크 I/O 를 STALL 초 동안 사실상 멈췄다가 푼다 (spdk_tgt 의 cgroup io.max 로 초당 1KB 제한) (하이퍼바이저 쪽 디스크 멈춤 흉내). 인자: 노드, 장치(sdc), STALL 초
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; DEV=${2:-sdc}; STALL=${3:-360}
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
echo "### K12 $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S)) $N 의 /dev/$DEV I/O 를 ${STALL}초 막음"
MM=$(sshn "lsblk -d -n -o MAJ:MIN /dev/$DEV" | tr -d ' ')
CGCMD='P=$(pgrep -f "spdk_tgt -L" | head -1); echo /sys/fs/cgroup$(cut -d: -f3 /proc/$P/cgroup)'
sshn "sudo dmesg -C; CG=\$($CGCMD); echo '$MM rbps=1024 wbps=1024' | sudo tee \$CG/io.max >/dev/null; cat \$CG/io.max"
./v2test/allwatch.sh $N $STALL
echo "--- 막힌 동안: hung=$(sshn 'sudo dmesg | grep -c "blocked for more than"') D상태=$(sshn 'ps -eLo stat,comm | awk "\$1 ~ /^D/" | sort | uniq -c | sort -rn | head -4 | tr "\n" ";"')"
sshn 'sudo dmesg -T | grep -A16 "blocked for more than" | grep -E "blocked for|Workqueue:" | head -6'
echo "### $(date +%H:%M:%S) I/O 재개"; sshn "CG=\$($CGCMD); echo '$MM rbps=max wbps=max riops=max wiops=max' | sudo tee \$CG/io.max >/dev/null; echo \"io.max: [\$(cat \$CG/io.max)]\""
./v2test/allwatch.sh $N 1200 1
PROBE=probe ./v2test/probe-report.sh 40m 2>/dev/null | tail -3
echo DONE
