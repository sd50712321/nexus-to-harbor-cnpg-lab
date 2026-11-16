#!/bin/bash
# 인자: 클러스터 이름, 관찰 초.  primary 가 있는 노드를 강제 정지하고 건드리지 않는다
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf CL=$1 VOLF=.
P=$(kubectl -n v2test get cluster $CL -o jsonpath='{.status.currentPrimary}'); N=$(kubectl -n v2test get pod $P -o jsonpath='{.spec.nodeName}')
echo "### $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S)) $CL primary=$P @ $N 강제 정지. operator: $(kubectl -n cnpg-system get pods -o wide --no-headers | awk '$3=="Running"{printf "%s ",$7}') leader=$(kubectl -n cnpg-system get lease db9c8771.cnpg.io -o jsonpath='{.spec.holderIdentity}' | cut -c1-35)"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S))"
./v2test/watch.sh $N ${2:-300} | sed -E 's/disk=[^|]*\| vol: [^|]*//; s/node=//'
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/watch.sh $N 480 "pg $(kubectl -n v2test get cluster $CL -o jsonpath='{.spec.instances}')/" | sed -E 's/disk=[^|]*\| vol: [^|]*//; s/node=//'
PROBE=${PROBE:-probe} ./v2test/probe-report.sh 15m
echo DONE
