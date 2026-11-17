#!/bin/bash
# K13c: 파드를 지운 뒤, 새 파드가 볼륨을 마운트하기 직전에 장치를 멈춘다(suspend --nolockfs).
#   k13c.sh <케이스> <파드> <pvc> <멈춰 둘 초>      (파드가 같은 노드에 다시 뜨는 볼륨이어야 한다)
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
CASE=$1; POD=$2; PVC=$3; HOLD=$4; NS=v2test
N=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}')
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
snap(){
  st=$(kubectl -n $NS get pod $POD -o wide --no-headers 2>/dev/null | awk '{print $3"("$2")@"$7}')
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  x=$(sshn "echo dm=\$(sudo dmsetup info $PV 2>/dev/null | awk '/State/{print \$2}') mnt=\$(findmnt -rn | grep -c $PV) hung=\$(sudo dmesg | grep -c 'blocked for more than') trap=\$(systemctl is-active k13c)" 2>/dev/null)
  echo "pod ${st:-없음} | vol $vol | $x"
}
echo "### $CASE $(date +%H:%M:%S) $POD @ $N pv=${PV:0:12} hold=${HOLD}s"
sshn 'sudo dmesg -C; sudo systemctl reset-failed k13c 2>/dev/null'
# 노드에서 기다리다가: 마운트가 사라지고 → (장치가 없어졌다 다시 생기면 그때, 20초 안에 안 없어지면 바로) 멈춘다
sshn "sudo systemd-run --unit=k13c bash -c 'while findmnt -rn | grep -q $PV; do sleep 0.05; done; echo unmounted; i=0; while dmsetup info $PV >/dev/null 2>&1 && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done; echo gone-or-timeout \$i; until dmsetup suspend --nolockfs $PV 2>/dev/null; do sleep 0.02; done; echo suspended; sleep 3600'" 
S=$(date +%s); kubectl -n $NS delete pod $POD --wait=false >/dev/null; last=; resumed=
while :; do
  t=$(( $(date +%s)-S )); b=$(snap)
  [ "$b" != "$last" ] && { echo "+${t}s $b"; last=$b; }
  if [ -z "$resumed" ] && [ $t -ge $HOLD ]; then
    echo "+${t}s --- resume ---"; sshn "sudo systemctl stop k13c; sudo dmsetup resume $PV 2>&1; sudo dmsetup info $PV 2>&1 | grep -E 'State|not'"; resumed=$t
  fi
  if [ -n "$resumed" ] && echo "$b" | grep -q "Running(1/1)"; then break; fi
  [ -n "$resumed" ] && [ $(( t-resumed )) -gt 600 ] && { echo "  resume 뒤 600초 넘게 미회복"; break; }
  /bin/sleep 5
done
echo "  결과: 총 $(( $(date +%s)-S ))s, resume 뒤 $(( $(date +%s)-S-${resumed:-0} ))s"
echo "  --- 함정 로그 ---"; sshn 'sudo journalctl -u k13c --no-pager -o cat | tail -5'
echo "  --- dmesg (멈춘 작업) ---"
sshn 'sudo dmesg | grep -A16 "blocked for more than" | grep -E "blocked for more|Workqueue| (dm_|__dm|submit_bio|wb_|jbd2|ext4_|blkdev_|sync_|mount|do_mount|writeback)" | cut -c1-150 | head -40'
echo "  --- 파드 이벤트 ---"
kubectl -n $NS get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "$POD|$PV" | tail -8 | cut -c1-220
echo "  --- kubelet ---"
sshn "sudo journalctl -u kubelet --since -$(( ($(date +%s)-S)/60+1 ))m | grep -iE '$PV' | grep -iE 'fail|error|timeout|busy' | tail -4 | cut -c1-300"
echo "  --- longhorn csi plugin ---"
kubectl -n longhorn-system logs $(kubectl -n longhorn-system get pod -l app=longhorn-csi-plugin -o wide --no-headers | awk -v n=$N '$7==n{print $1}') -c longhorn-csi-plugin --since=$(( ($(date +%s)-S)/60+1 ))m 2>/dev/null | grep -iE "$PV" | grep -iE "error|fail|timeout|deadline" | tail -4 | cut -c1-300
