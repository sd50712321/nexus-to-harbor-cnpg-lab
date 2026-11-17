#!/bin/bash
# big-0 의 볼륨·복제본·파드 상태를 바뀔 때만 출력. 인자: 최대 초, [끝 조건 grep 식]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
V=$(kubectl -n v2test get pvc data-big-0 -o jsonpath='{.spec.volumeName}'); MAX=${1:-300}; END=${2:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  rep=$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=$V -o jsonpath='{range .items[*]}{.spec.nodeID}:{.status.currentState}{"("}{.spec.failedAt}{")"} {end}' 2>/dev/null | sed -E 's/\(\)//g; s/\(20[0-9-]+T([0-9:]+)Z\)/(failed \1)/g')
  pod=$(kubectl -n v2test get pod big-0 -o wide --no-headers 2>/dev/null | awk '{print $3"("$2",restarts="$4")@"$7}')
  nodes=$(kubectl get nodes ks-w1 ks-w2 ks-w3 --no-headers 2>/dev/null | awk '{printf "%s=%s ",$1,$2}')
  b="$nodes| vol $vol | rep $rep| pod $pod"
  [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && break
  /bin/sleep 5
done
