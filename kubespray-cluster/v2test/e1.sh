#!/bin/bash
# 인자: 노드, 꺼 둘 초. 파드가 없는(복제본만 있는) 노드를 강제 정지 → 관찰 → 기동 → healthy 까지. staleReplicaTimeout 효과를 본다
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; DOWN=${2:-420}
V=$(kubectl -n v2test get pvc data-big-0 -o jsonpath='{.spec.volumeName}')
echo "### $(date +%H:%M:%S) $N 강제 정지 (big-0 은 $(kubectl -n v2test get pod big-0 -o jsonpath='{.spec.nodeName}')), ${DOWN}초. staleReplicaTimeout=$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.spec.staleReplicaTimeout}')분"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"
./v2test/bigwatch.sh $DOWN
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/bigwatch.sh 1200 'vol attached/healthy.*pod Running\(1/1'
kubectl -n longhorn-system logs -l app=longhorn-manager --since=25m --tail=6000 2>/dev/null | grep "$V" | grep -iE "staled|failed too long|Cleaning up" | cut -c1-40,100-330 | sort -u | head -4
echo "write fails: $(kubectl -n v2test logs big-0 --tail=2000 2>/dev/null | grep -c WRITE-FAIL)"
echo DONE
