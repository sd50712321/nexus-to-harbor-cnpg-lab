#!/bin/bash
# G2: 타깃은 멀쩡한데 dm 만 Suspended 로 남은 경우. Longhorn 이 스스로 푸는가, 그 상태에서 떼면 다음 attach 가 얼마나 밀리는가.
#   w1-suspend-healthy.sh <case> <node>     (u4 가 <node> 에 떠 있어야 함)
C=$1; N=$2; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/w/$C.log; mkdir -p v2test/results/w; PV=$(kubectl -n v2test get pvc u4 -o jsonpath='{.spec.volumeName}')
ver=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
echo "$C: Longhorn $ver, $N. 정상 볼륨 $PV 의 dm 을 suspend(--noflush --nolockfs)만 하고 3분 둔다. 그 뒤 $N cordon + 파드 삭제" > $L
vagrant ssh $N -c "sudo bash -c 'nohup /root/u-dmwatch.sh 620 > /root/dmwatch.out 2>&1 & sleep 2; dmesg -C; echo \">>> suspend \$(date -u +%H:%M:%S)\"; dmsetup suspend --noflush --nolockfs $PV; echo rc=\$?'" 2>/dev/null >> $L
/bin/sleep 180
{ echo "-- 3분 뒤 (Longhorn 이 스스로 풀었나)"; kubectl -n longhorn-system get volumes.longhorn.io $PV --no-headers | awk '{print "   volume",$3,$4}'; kubectl -n longhorn-system get enginefrontends.longhorn.io --no-headers 2>/dev/null | grep $PV | awk '{print "   ef",$3,$4}'; } >> $L
vagrant ssh $N -c "sudo /root/u-snap.sh" 2>/dev/null | grep -v '^      ' >> $L
kubectl cordon $N >/dev/null; t0=$(date +%s); echo ">>> delete pod $(date -u +%H:%M:%S)" >> $L; kubectl -n v2test delete pod -l app=u4 --wait=false >/dev/null
ok=0; for i in $(seq 1 80); do /bin/sleep 5; s=$(kubectl -n v2test get pods -l app=u4 -o wide --no-headers | awk '$3=="Running" && $2=="1/1"{print $7}'); [ -n "$s" ] && { ok=1; break; }; done
echo "   새 파드 Running=$ok 노드=$s 걸린시간=$(( $(date +%s)-t0 ))s" >> $L
kubectl get events -n v2test --sort-by=.lastTimestamp | grep 'u4' | grep -i 'warn' | tail -4 | cut -c1-260 >> $L
/bin/sleep 20; vagrant ssh $N -c "sudo bash -c '/root/u-snap.sh | grep -v \"^      \"; echo \"-- dmwatch\"; cat /root/dmwatch.out; pkill -x u-dmwatch.sh; echo \">>> 정리: resume\"; S=\$(dmsetup info -c --noheadings -o suspended $PV 2>/dev/null); echo \"상태=\$S\"; [ \"\$S\" = Suspended ] && { dmsetup resume $PV; sleep 5; dmsetup info -c --noheadings -o name,suspended,open $PV; }; echo \"-- dmesg\"; dmesg | grep -v \"^\\[[ 0-9.]*\\]  \" | tail -8 | cut -c1-150'" 2>/dev/null >> $L
kubectl -n longhorn-system logs -l longhorn.io/component=instance-manager --tail=3000 --since=15m 2>/dev/null | grep -i 'suspend' | grep -i 'fail\|stuck\|error' | tail -5 | cut -c1-260 >> $L
kubectl uncordon $N >/dev/null; cat $L | cut -c1-170
