#!/bin/bash
# G1(느린 저장소): spdk_tgt 를 SIGSTOP/SIGCONT 로 번갈아 멈춰 "살아 있지만 느린" 타깃을 만든다(기본 0.95초 멈춤 / 0.05초 실행).
# 더티 페이지를 잔뜩 쌓은 뒤 스냅샷을 요청해 Longhorn 의 dm suspend(flush + fs freeze)가 30초를 넘기게 한다.
#   w3-slow-suspend.sh <case> <node> [느린 구간 초, 기본 150] [더티 MB, 기본 600]
C=$1; N=$2; SLOW=${3:-150}; MB=${4:-600}; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/w/$C.log; mkdir -p v2test/results/w; PV=$(kubectl -n v2test get pvc u4 -o jsonpath='{.spec.volumeName}')
ver=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
IM=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $1}')
P=$(kubectl -n v2test get pods -l app=u4 -o jsonpath='{.items[0].metadata.name}')
echo "$C: Longhorn $ver, $N. spdk_tgt 를 ${SLOW}초 동안 0.95s 멈춤/0.05s 실행 반복. 버퍼 쓰기 ${MB}MB 직후 스냅샷 생성 요청" > $L
SNAP=w3-$(date +%s)
vagrant ssh $N -c "sudo bash -c 'nohup /root/u-dmwatch.sh $((SLOW+200)) > /root/dmwatch.out 2>&1 & dmesg -C
nohup bash -c \"P=\\\$(pgrep -f ^spdk_tgt | head -1); E=\\\$(( \\\$(date +%s) + $SLOW )); while [ \\\$(date +%s) -lt \\\$E ]; do kill -STOP \\\$P; sleep 0.95; kill -CONT \\\$P; sleep 0.05; done; kill -CONT \\\$P; echo \\\">>> slow off \\\$(date -u +%H:%M:%S)\\\" >> /root/dmwatch.out\" >/dev/null 2>&1 &
echo \">>> slow on \$(date -u +%H:%M:%S)\"'" 2>/dev/null >> $L
kubectl -n v2test exec $P -- bash -c "dd if=/dev/zero of=/data/big bs=1M count=$MB 2>&1 | tail -1" >> $L 2>&1 &
/bin/sleep 6; echo ">>> snapshot create $(date -u +%H:%M:%S) $SNAP" >> $L
printf 'apiVersion: longhorn.io/v1beta2\nkind: Snapshot\nmetadata: {name: %s, namespace: longhorn-system}\nspec: {volume: %s, createSnapshot: true}\n' $SNAP $PV | kubectl apply -f - >/dev/null 2>&1
/bin/sleep $((SLOW+190))
{ echo "-- snapshot CR"; kubectl -n longhorn-system get snapshots.longhorn.io $SNAP -o jsonpath='   readyToUse={.status.readyToUse} error={.status.error}{"\n"}' | cut -c1-300
  echo "-- volume"; kubectl -n longhorn-system get volumes.longhorn.io $PV --no-headers | awk '{print "   ",$3,$4}'; kubectl -n v2test get pods -l app=u4 -o wide --no-headers | awk '{print "    pod",$2,$3,$4,$7}'
  kubectl -n longhorn-system get pod $IM -o jsonpath='    IM restarts={.status.containerStatuses[0].restartCount}{"\n"}'
  echo "-- instance-manager 로그 (suspend/resume/timeout)"; kubectl -n longhorn-system logs $IM --since=$((SLOW+260))s 2>/dev/null | grep -i 'suspend\|resum\|timeout executing' | sed 's/^\[longhorn-instance-manager\] time="2026-11-18T//; s/func=[^ ]* file=[^ ]* //' | cut -c1-260 | tail -16; } >> $L
vagrant ssh $N -c "sudo bash -c 'echo \"-- dmwatch\"; cat /root/dmwatch.out; /root/u-snap.sh | grep -v \"^      \"; echo \"-- dmsetup 프로세스\"; ps -eo pid,ppid,stat,etimes,comm | awk \"\\\$5==\\\"dmsetup\\\"\"; echo \"-- dmesg\"; dmesg | grep -v \"Reconnecting in\|Failed reconnect\|^\\[[ 0-9.]*\\]  \" | uniq -c -f3 | tail -10 | cut -c1-150'" 2>/dev/null >> $L
cat $L | cut -c1-260
