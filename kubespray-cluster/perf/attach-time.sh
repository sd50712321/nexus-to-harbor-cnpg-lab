#!/bin/bash
# 새 볼륨의 첫 마운트 시간(크기별)과, 같은 볼륨을 다시 붙이는 시간을 잰다.
#   perf/attach-time.sh <StorageClass> <노드> <크기...>      예: perf/attach-time.sh longhorn-v2-single ks-w1 2Gi 20Gi 60Gi
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
SC=$1; NODE=$2; shift 2; NS=perf
pod(){ cat <<Y | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: at-$1, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: $NODE}
  terminationGracePeriodSeconds: 1
  containers:
  - {name: c, image: busybox:1.36, command: [sleep, "86400"], volumeMounts: [{name: v, mountPath: /data}]}
  volumes: [{name: v, persistentVolumeClaim: {claimName: at-$1}}]
Y
}
wait_run(){ S=$(date +%s); until [ "$(kubectl -n $NS get pod at-$1 -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; do
    [ $(( $(date +%s)-S )) -gt ${MAX:-3600} ] && { echo timeout; return; }
    m=$(ssh -F inventory/lab/ssh.cfg $NODE "ps -eo etime,args | grep -E '[m]kfs|[b]lkid' | head -1" 2>/dev/null); [ -n "$m" ] && [ "$m" != "$lm" ] && { echo "    노드: $m" >&2; lm=$m; }
    /bin/sleep 1; done; echo $(( $(date +%s)-S )); }
for sz in "$@"; do
  n=$(echo $sz | tr 'A-Z' 'a-z')
  kubectl -n $NS apply -f - >/dev/null <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: at-$n, namespace: $NS}
spec: {storageClassName: $SC, accessModes: [ReadWriteOnce], resources: {requests: {storage: $sz}}}
Y
  pod $n; first=$(wait_run $n)
  kubectl -n $NS delete pod at-$n --wait=true >/dev/null; /bin/sleep 5
  pod $n; again=$(wait_run $n)
  echo "$SC $sz: 첫 마운트 ${first}s, 다시 붙이기 ${again}s"
  kubectl -n $NS delete pod at-$n --wait=true >/dev/null; kubectl -n $NS delete pvc at-$n >/dev/null
done
