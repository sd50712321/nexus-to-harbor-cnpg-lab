#!/bin/bash
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf CL=pg-v2 VOLF=.
P=$(kubectl -n v2test get cluster pg-v2 -o jsonpath='{.status.currentPrimary}'); N=$(kubectl -n v2test get pod $P -o jsonpath='{.spec.nodeName}')
echo "### C1 $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S)) primary=$P 가 있는 $N 강제 정지 — 파드는 건드리지 않음, 7분 관찰"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S))"
./v2test/watch.sh $N 420
kubectl -n v2test get pods -l cnpg.io/cluster=pg-v2 -L cnpg.io/instanceRole -o wide --no-headers | awk '{print " ",$1,$3,$7,$NF}'
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/watch.sh $N 480 'pg 3/3'
kubectl -n v2test get pods -l cnpg.io/cluster=pg-v2 -L cnpg.io/instanceRole -o wide --no-headers | awk '{print " ",$1,$3,$7,$NF}'
./v2test/probe-report.sh 20m
echo DONE
