#!/bin/bash
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf CL=pg-r3 VOLF='pvc-(9248|cf1f)'
N=$(kubectl -n v2test get pod pg-r3-2 -o jsonpath='{.spec.nodeName}')
echo "### B2 $(date +%H:%M:%S) $N(pg-r3-2, 3벌 복제 볼륨) 강제 정지 — 아무것도 안 하고 13분 관찰"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"
./v2test/watch.sh $N 780
echo "--- 13분 시점"; kubectl -n v2test get pods -l cnpg.io/cluster=pg-r3 -o wide --no-headers | awk '{print " ",$1,$2,$3,$7}'
kubectl get volumeattachment --no-headers | grep -E "9248|cf1f" | awk '{print " ",$3,$4,$5}'
kubectl -n v2test get events --sort-by=.lastTimestamp | grep pg-r3 | grep -i warn | tail -4 | cut -c1-280
if [ "$(kubectl -n v2test get cluster pg-r3 -o jsonpath='{.status.readyInstances}')" != 2 ]; then
  echo "### B3 $(date +%H:%M:%S) out-of-service taint 적용"; kubectl taint node $N node.kubernetes.io/out-of-service=nodeshutdown:NoExecute | tail -1
  ./v2test/watch.sh $N 420 'pg 2/2'
  kubectl -n v2test get pods -l cnpg.io/cluster=pg-r3 -o wide --no-headers | awk '{print " ",$1,$2,$3,$7}'
fi
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; kubectl taint node $N node.kubernetes.io/out-of-service- 2>&1 | tail -1; echo "up $(date +%H:%M:%S)"
VOLF=. CL=pg-v2 ./v2test/watch.sh $N 480 'pg 3/3'
echo DONE
