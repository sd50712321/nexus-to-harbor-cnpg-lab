#!/bin/bash
# G1: Longhorn 의 dm suspend(스냅샷 생성)가 시간 초과하게 만든다. I/O 가 잠깐(기본 45초) 멎은 사이 스냅샷을 요청한다.
# Longhorn 이 포기한 뒤 dm 이 Suspended 로 남는지, 버려진 dmsetup 프로세스가 있는지 본다.
#   w2-suspend-timeout.sh <case> <node> [멎는 초, 기본 45]     (u4 가 <node> 에 떠 있어야 함)
C=$1; N=$2; HOLD=${3:-45}; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/w/$C.log; mkdir -p v2test/results/w; PV=$(kubectl -n v2test get pvc u4 -o jsonpath='{.spec.volumeName}')
ver=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
IM=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $1}')
echo "$C: Longhorn $ver, $N. 쓰기 중인 $PV 의 NVMe-TCP 포트를 ${HOLD}초 DROP, 3초 뒤 스냅샷 생성 요청" > $L
SNAP=w2-$(date +%s)
vagrant ssh $N -c "sudo bash -c 'nohup /root/u-dmwatch.sh 330 > /root/dmwatch.out 2>&1 & sleep 2; dmesg -C
PORT=\$(for c in /sys/class/nvme/nvme*; do grep -q $PV \$c/subsysnqn && cat \$c/address; done | grep -o \"trsvcid=[0-9]*\" | cut -d= -f2 | head -1); echo port=\$PORT
echo \">>> blackhole on \$(date -u +%H:%M:%S)\"; /root/u-blackhole.sh on \$PORT >/dev/null
(sleep $HOLD; /root/u-blackhole.sh off \$PORT >/dev/null; echo \">>> blackhole off \$(date -u +%H:%M:%S)\" >> /root/dmwatch.out) >/dev/null 2>&1 &
sleep 1'" 2>/dev/null >> $L
/bin/sleep 2; echo ">>> snapshot create $(date -u +%H:%M:%S) $SNAP" >> $L
printf 'apiVersion: longhorn.io/v1beta2\nkind: Snapshot\nmetadata: {name: %s, namespace: longhorn-system}\nspec: {volume: %s, createSnapshot: true}\n' $SNAP $PV | kubectl apply -f - >/dev/null
/bin/sleep 300
{ echo "-- snapshot CR"; kubectl -n longhorn-system get snapshots.longhorn.io $SNAP -o jsonpath='   readyToUse={.status.readyToUse} error={.status.error}{"\n"}'
  echo "-- volume"; kubectl -n longhorn-system get volumes.longhorn.io $PV --no-headers | awk '{print "   ",$3,$4}'; kubectl -n v2test get pods -l app=u4 -o wide --no-headers | awk '{print "    pod",$2,$3,$4,$7}'
  echo "-- instance-manager 로그 (suspend/resume)"; kubectl -n longhorn-system logs $IM --since=7m 2>/dev/null | grep -i 'suspend\|resum\|timeout executing' | cut -c1-330 | tail -14; } >> $L
vagrant ssh $N -c "sudo bash -c 'echo \"-- dmwatch\"; cat /root/dmwatch.out; /root/u-snap.sh | grep -v \"^      \"; echo \"-- dmsetup 프로세스\"; ps -eo pid,ppid,stat,etimes,args | grep \"[d]msetup\"; echo \"-- dmesg\"; dmesg | grep -v \"Reconnecting in\|Failed reconnect\|^\\[[ 0-9.]*\\]  \" | uniq -c -f3 | tail -12 | cut -c1-150'" 2>/dev/null >> $L
cat $L | cut -c1-240
