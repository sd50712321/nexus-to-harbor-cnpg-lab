#!/bin/bash
# 실서버 상태 재현: 쓰기 중인 V2 볼륨의 dm 을 suspend 한 직후 spdk_tgt 를 죽이고, 파드를 다른 노드로 보낸다.
# 옛 노드에 Suspended dm + D 상태 umount 가 남는지 보고, dmsetup remove → resume → remove 로 풀어 본다.
#   u4-orphan.sh <case> <node> [관찰초 목록, 기본 "30 60 90 120 180"]     (디플로이먼트 u4 가 <node> 에 떠 있어야 함)
C=$1; N=$2; W=${3:-30 60 90 120 180}
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/u/$C.log; PV=$(kubectl -n v2test get pvc u4 -o jsonpath='{.spec.volumeName}')
vagrant ssh $N -c "sudo bash -c 'cat > /root/u-snap.sh; chmod +x /root/u-snap.sh'" < v2test/u-snap.sh 2>/dev/null
echo "$C: Longhorn $(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://'), $N 에서 $PV dm suspend 직후 spdk_tgt SIGKILL, $N cordon, 파드 삭제" > $L
kubectl cordon $N >/dev/null
vagrant ssh $N -c "sudo bash -c 'dmesg -C; /root/u-snap.sh; echo \">>> dmsetup suspend --noflush --nolockfs\"; dmsetup suspend --noflush --nolockfs $PV; echo rc=\$?; echo \">>> kill -9 spdk_tgt\"; kill -9 \$(pgrep -f ^spdk_tgt|head -1)'" 2>/dev/null >> $L
echo ">>> delete pod u4 $(date -u +%H:%M:%S)" >> $L; kubectl -n v2test delete pod -l app=u4 --wait=false >/dev/null
vagrant ssh $N -c "sudo bash -c 'for i in $W; do sleep \$i; /root/u-snap.sh; done
echo \">>> dmsetup remove\"; timeout 20 dmsetup remove $PV; echo rc=\$?
echo \">>> dmsetup resume\"; timeout 20 dmsetup resume $PV; echo rc=\$?
for i in 3 10 30; do sleep \$i; /root/u-snap.sh; done
echo \">>> dmsetup remove (resume 뒤)\"; timeout 20 dmsetup remove $PV; echo rc=\$?; dmsetup info -c --noheadings -o name,suspended,open; echo mounts=\$(mount | grep -c $PV)
echo \"-- dmesg\"; dmesg | grep -v \"Reconnecting in\|Failed reconnect\|failed to connect socket\|^\\[[ 0-9.]*\\]  \" | tail -16 | cut -c1-160'" 2>&1 | grep -v '^Connection' >> $L
{ echo "-- k8s $(date -u +%H:%M:%S)"; kubectl -n v2test get pods -o wide --no-headers | awk '{print $1,$2,$3,$7}'; kubectl -n longhorn-system get volumes.longhorn.io --no-headers | awk '{print $1,$3,$4,$6}'; } >> $L
kubectl uncordon $N >/dev/null
awk '/^>>> kill/{f=1} f' $L | grep -v '^      ' | cut -c1-150
