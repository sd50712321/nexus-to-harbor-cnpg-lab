#!/bin/bash
# 살아 있는 노드 사이에서 파드를 옮기며 볼륨이 다시 붙는 시간을 잰다.
#   move.sh <케이스 이름> <파드> <pvc> [옛 노드에서 실행할 준비 명령] [정리 명령]   — 명령 안의 $MNT 는 파드의 볼륨 마운트 경로로 바뀐다
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
CASE=$1; POD=$2; PVC=$3; PRE=${4:-}; POST=${5:-}; MAX=${MAX:-900}; NS=v2test
N=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}'); U=$(kubectl -n $NS get pod $POD -o jsonpath='{.metadata.uid}')
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}'); MNT=/var/lib/kubelet/pods/$U/volumes/kubernetes.io~csi/$PV/mount
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
echo "### $CASE $(date +%H:%M:%S) $POD @ $N pv=${PV:0:12}"
[ -n "$PRE" ] && { sshn "MNT=$MNT; $PRE"; /bin/sleep 3; echo "  준비: $PRE"; }
sshn 'sudo dmesg -C' 2>/dev/null
kubectl cordon $N >/dev/null; S=$(date +%s); kubectl -n $NS delete pod $POD --wait=false >/dev/null; last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  st=$(kubectl -n $NS get pod $POD -o wide --no-headers 2>/dev/null | awk '{print $3"("$2")@"$7}'); vol=$(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  b="pod ${st:-없음} | vol $vol"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $b"; last=$b; }
  echo "$st" | grep -q "Running(1/1)" && ! echo "$st" | grep -q "@$N" && break
  /bin/sleep 3
done
echo "  결과: $(( $(date +%s)-S ))s"
echo "  옛 노드: mounts=$(sshn "findmnt | grep -c $PV") umount=$(sshn "ps -eo stat,etime,args | grep '[u]mount' | head -2 | tr '\n' ';'") hung=$(sshn 'sudo dmesg | grep -c "blocked for more than"')"
sshn "sudo journalctl -u kubelet --since -$(( ($(date +%s)-S)/60+1 ))m | grep $PV | grep -iE 'busy|unmount.*fail|error' | tail -2 | cut -c1-260"
kubectl -n $NS get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "$POD|$PV" | grep -E "Multi-Attach|FailedAttach|SuccessfulAttach|FailedMount|Killing" | tail -6 | cut -c1-200
[ -n "$POST" ] && sshn "$POST"
kubectl uncordon $N >/dev/null
