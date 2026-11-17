#!/bin/bash
# 전체 상태(문제 노드의 V2 인스턴스 매니저·노드 Ready, 볼륨과 복제본, 파드)를 바뀔 때만 출력. 인자: 노드, 최대 초, [모두 정상이면 끝=1]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; MAX=${2:-600}; ENDOK=${3:-0}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  vol=$(for v in $(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$2=="v2"{print $1}'); do
    echo -n "$(kubectl -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.status.kubernetesStatus.pvcName}:{.status.state}/{.status.robustness}' | sed -E 's/attached/att/; s/detached/det/; s/healthy/ok/; s/degraded/degr/')[$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=$v -o jsonpath='{range .items[*]}{.spec.nodeID}{.spec.failedAt},{end}' | sed -E 's/ks-//g; s/20[0-9-]+T[0-9:]+Z/!/g; s/,$//')] "; done)
  pod=$(kubectl -n v2test get pods --no-headers -o wide 2>/dev/null | awk '{printf "%s=%s(%s,r%s)@%s ",$1,$3,$2,$4,substr($7,4)}')
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}'); nd=$(kubectl get node $N --no-headers | awk '{print $2}')
  b="node=$nd im=$im | $vol| $pod"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ "$ENDOK" = 1 ] && [ "$im" = running ] && ! echo "$b" | grep -qE "Init|Pending|Creating|\(0/1|faulted|degr|unknown|!|NotReady|Unknown|Crash|Error" && break
  /bin/sleep 12
done
