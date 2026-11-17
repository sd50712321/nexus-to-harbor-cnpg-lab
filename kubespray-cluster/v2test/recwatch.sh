#!/bin/bash
# 전체 회복 관찰: V2 볼륨 상태와 v2test 파드 상태를 바뀔 때만 출력. 모두 정상이면 끝. 인자: 최대 초
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; MAX=${1:-3600}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$2=="v2"{printf "%s:%s/%s ",substr($1,5,4),substr($3,1,4),substr($4,1,4)}')
  pod=$(kubectl -n v2test get pods --no-headers -o wide 2>/dev/null | grep -v probe | awk '{printf "%s=%s(%s,r%s)@%s ",$1,$3,$2,$4,substr($7,4)}')
  b="$vol| $pod"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  echo "$vol" | grep -qvE "deta|faul|degr|unkn|atta:atta/unkn" && [ $(echo "$vol" | grep -o "heal" | wc -l) -ge 6 ] && ! echo "$pod" | grep -qE "\(0/1|Crash|Init|Pending|Terminating|Creating" && { echo "ALL-OK +$(( $(date +%s)-S ))s"; break; }
  /bin/sleep 10
done
echo DONE
