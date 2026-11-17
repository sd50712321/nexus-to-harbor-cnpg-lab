#!/bin/bash
# K13: 파드가 쓰는 V2 볼륨의 device-mapper 장치를 멈춘(suspend) 채 파드를 지운다.
#   k13.sh <케이스> <파드> <pvc> <멈춰 둘 초> [cordon]
#   cordon 을 주면 다른 노드로 옮기는 경우, 안 주면 같은 노드에서 다시 뜨는 경우.
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
CASE=$1; POD=$2; PVC=$3; HOLD=$4; CORDON=${5:-}; NS=v2test
N=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}')
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
snap(){
  st=$(kubectl -n $NS get pod $POD -o wide --no-headers 2>/dev/null | awk '{print $3"("$2")@"$7}')
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers 2>/dev/null | grep " v2 " | grep " $N " | awk "{print \$3}")
  hung=$(sshn 'sudo dmesg | grep -c "blocked for more than"' 2>/dev/null)
  echo "pod ${st:-없음} | vol $vol | v2im $im | hung $hung"
}
echo "### $CASE $(date +%H:%M:%S) $POD @ $N pv=${PV:0:12} hold=${HOLD}s cordon=${CORDON:-no}"
sshn 'sudo dmesg -C'
sshn "sudo dmsetup suspend ${NOLOCKFS:+--nolockfs} $PV && sudo dmsetup info $PV | grep State"
[ -n "$CORDON" ] && kubectl cordon $N >/dev/null
S=$(date +%s); kubectl -n $NS delete pod $POD --wait=false >/dev/null; last=; resumed=
while :; do
  t=$(( $(date +%s)-S )); b=$(snap)
  [ "$b" != "$last" ] && { echo "+${t}s $b"; last=$b; }
  if [ -z "$resumed" ] && [ $t -ge $HOLD ]; then
    echo "+${t}s --- resume ---"; sshn "sudo dmsetup resume $PV 2>&1; sudo dmsetup info $PV 2>&1 | grep -E 'State|not'"; resumed=$t
  fi
  if echo "$b" | grep -q "Running(1/1)" && [ $t -gt 20 ]; then break; fi
  [ -n "$resumed" ] && [ $(( t-resumed )) -gt 600 ] && { echo "  resume 뒤 600초 넘게 미회복"; break; }
  /bin/sleep 5
done
echo "  결과: 총 $(( $(date +%s)-S ))s, resume 뒤 $(( $(date +%s)-S-${resumed:-0} ))s"
echo "  --- dmesg (멈춘 작업) ---"
sshn 'sudo dmesg | grep -A14 "blocked for more than" | grep -E "blocked for more|Workqueue|Call Trace|^\[.*\]  (dm_|__dm|submit_bio|wb_|jbd2|ext4_|blkdev_|sync|io_schedule|schedule)" | cut -c1-150 | head -40'
echo "  --- 파드 이벤트 ---"
kubectl -n $NS get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "$POD|$PV" | tail -8 | cut -c1-220
echo "  --- kubelet ---"
sshn "sudo journalctl -u kubelet --since -$(( ($(date +%s)-S)/60+1 ))m | grep -iE '$PV' | grep -iE 'fail|error|timeout|busy' | tail -4 | cut -c1-300"
[ -n "$CORDON" ] && kubectl uncordon $N >/dev/null
