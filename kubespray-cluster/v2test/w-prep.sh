#!/bin/bash
# 시험 전 준비: pg-prod 3 인스턴스와 u4 를 띄우고 u4 를 <node> 에 올린다. 모든 볼륨이 healthy 가 될 때까지 기다린다.
N=${1:-ks-w2}; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
kubectl uncordon ks-w1 ks-w2 ks-w3 >/dev/null
kubectl -n v2test annotate cluster pg-prod cnpg.io/hibernation=off --overwrite >/dev/null
cur=$(kubectl -n v2test get pods -l app=u4 -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
if [ "$cur" != "$N" ]; then kubectl -n v2test scale deploy u4 --replicas=0 >/dev/null; /bin/sleep 20; for o in ks-w1 ks-w2 ks-w3; do [ $o != $N ] && kubectl cordon $o >/dev/null; done; kubectl -n v2test scale deploy u4 --replicas=1 >/dev/null
  for i in $(seq 1 40); do /bin/sleep 6; kubectl -n v2test get pods -l app=u4 --no-headers 2>/dev/null | grep -q '1/1' && break; done; kubectl uncordon ks-w1 ks-w2 ks-w3 >/dev/null; fi
for i in $(seq 1 60); do r=$(kubectl -n v2test get cluster pg-prod -o jsonpath='{.status.readyInstances}'); v=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers | awk '{printf "%s/%s ", $3,$4}'); u=$(kubectl -n v2test get pods -l app=u4 --no-headers | awk '{print $2}')
  [ "$r" = 3 ] && [ "$u" = 1/1 ] && ! echo "$v" | grep -q 'degraded\|unknown\|faulted\|detached\|attaching' && break; /bin/sleep 10; done
echo "prep: pg=$r u4=$u@$(kubectl -n v2test get pods -l app=u4 -o jsonpath='{.items[0].spec.nodeName}') $v"
