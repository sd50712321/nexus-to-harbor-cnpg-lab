#!/bin/bash
# 데이터 3GB 가 든 3벌 V2 볼륨: 파드가 있는 노드 강제 정지 → DOWN 초 관찰 → 기동 → healthy 까지
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; DOWN=${1:-480}
N=$(kubectl -n v2test get pod big-0 -o jsonpath='{.spec.nodeName}')
echo "### $(date +%H:%M:%S) big-0 @ $N 강제 정지, ${DOWN}초 관찰"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"
./v2test/bigwatch.sh $DOWN
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/bigwatch.sh 1500 'vol attached/healthy.*pod Running\(1/1'
kubectl -n v2test logs big-0 --tail=400 2>/dev/null | grep -c WRITE-FAIL
kubectl -n v2test get events --sort-by=.lastTimestamp | grep big-0 | grep -iE "warn|kill|delet" | tail -8 | cut -c1-230
echo DONE
