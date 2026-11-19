#!/bin/bash
# G1(느린 저장소): spdk_tgt 컨테이너의 CPU 할당(cgroup cpu.max)을 조여 "살아 있지만 느린" 타깃을 만든다(기본 3%). 프로세스는 계속 R 상태다.
# 더티 페이지를 잔뜩 쌓은 뒤 레플리카를 지워 재구축을 일으킨다. 재구축의 dm suspend 가 30초를 넘기면 Longhorn 은 "proceeding without suspension" 으로 진행하고 resume 을 부르지 않는다.
#   w4-rebuild-suspend.sh <case> <node> [느린 구간 초, 기본 150] [더티 MB, 기본 600] [cpu.max quota(us/100ms), 기본 3000]
C=$1; N=$2; SLOW=${3:-150}; MB=${4:-600}; QUOTA=${5:-3000}; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/w/$C.log; mkdir -p v2test/results/w; PV=$(kubectl -n v2test get pvc u4 -o jsonpath='{.spec.volumeName}')
ver=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
IM=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $1}')
P=$(kubectl -n v2test get pods -l app=u4 -o jsonpath='{.items[0].metadata.name}')
echo "$C: Longhorn $ver, $N. spdk_tgt 컨테이너 CPU 를 ${SLOW}초 동안 cpu.max=$QUOTA/100000 으로 제한. 버퍼 쓰기 ${MB}MB 직후 다른 노드의 레플리카 1개 삭제(재구축)" > $L
SNAP=w3-$(date +%s)
vagrant ssh $N -c "sudo bash -c 'nohup /root/u-dmwatch.sh $((SLOW+200)) > /root/dmwatch.out 2>&1 & dmesg -C
CG=/sys/fs/cgroup\$(cut -d: -f3 /proc/\$(pgrep -f ^spdk_tgt | head -1)/cgroup); echo cgroup=\$CG; echo \"$QUOTA 100000\" > \$CG/cpu.max
nohup bash -c \"sleep $SLOW; echo max 100000 > \$CG/cpu.max; echo \\\">>> slow off \\\$(date -u +%H:%M:%S)\\\" >> /root/dmwatch.out\" >/dev/null 2>&1 &
echo \">>> slow on \$(date -u +%H:%M:%S)\"'" 2>/dev/null >> $L
kubectl -n v2test exec $P -- bash -c "dd if=/dev/zero of=/data/big bs=1M count=$MB 2>&1 | tail -1" >> $L 2>&1 &
/bin/sleep 6; R=$(kubectl -n longhorn-system get replicas.longhorn.io --no-headers -o custom-columns=N:.metadata.name,V:.spec.volumeName,H:.spec.nodeID | awk -v v=$PV -v n=$N '$2==v && $3!=n{print $1}' | head -1)
echo ">>> replica delete $(date -u +%H:%M:%S) $R (재구축 유도)" >> $L; kubectl -n longhorn-system delete replicas.longhorn.io $R --wait=false >/dev/null 2>&1
/bin/sleep $((SLOW+190))
{ echo "-- volume"; kubectl -n longhorn-system get volumes.longhorn.io $PV --no-headers | awk '{print "   ",$3,$4}'; kubectl -n v2test get pods -l app=u4 -o wide --no-headers | awk '{print "    pod",$2,$3,$4,$7}'
  kubectl -n longhorn-system get pod $IM -o jsonpath='    IM restarts={.status.containerStatuses[0].restartCount}{"\n"}'
  echo "-- instance-manager 로그 (suspend/resume/timeout)"; kubectl -n longhorn-system logs $IM --since=$((SLOW+260))s 2>/dev/null | grep -i 'suspend\|resum\|timeout executing' | grep -v 'Suspending linear\|Resuming linear' | sed 's/^\[longhorn-instance-manager\] time="2026-11-18T//; s/func=[^ ]* file=[^ ]* //' | cut -c1-260 | tail -16; } >> $L
vagrant ssh $N -c "sudo bash -c 'echo \"-- dmwatch\"; cat /root/dmwatch.out; /root/u-snap.sh | grep -v \"^      \"; echo \"-- dmsetup 프로세스\"; ps -eo pid,ppid,stat,etimes,comm | awk \"\\\$5==\\\"dmsetup\\\"\"; echo \"-- dmesg\"; dmesg | grep -v \"Reconnecting in\|Failed reconnect\|^\\[[ 0-9.]*\\]  \" | uniq -c -f3 | tail -10 | cut -c1-150'" 2>/dev/null >> $L
cat $L | cut -c1-260
