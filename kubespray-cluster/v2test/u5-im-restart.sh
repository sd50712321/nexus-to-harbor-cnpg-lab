#!/bin/bash
# V2 인스턴스 매니저 파드를 전부 한꺼번에 지우고(=동시 재생성 → 동시 attach), NVMe-oF transport 개수와 spdk_tgt 사망을 본다.
#   u5-im-restart.sh <case> <횟수>     (Longhorn 이슈 #14399/#14400 조건)
C=$1; N=${2:-3}
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/u/$C.log; mkdir -p v2test/results/u
ims(){ kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk '$2=="v2"{print $1}'; }
echo "$C: V2 인스턴스 매니저 파드 전부 동시 삭제 x$N. Longhorn $(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}')" > $L
kubectl -n longhorn-system get volumes.longhorn.io --no-headers | awk '{print "  vol",$1,$3,$4}' >> $L
for r in $(seq 1 $N); do
  t0=$(date +%s); echo "== round $r $(date -u +%H:%M:%S) delete $(ims | wc -l | tr -d ' ') IM pods" >> $L
  kubectl -n longhorn-system delete pod $(ims) --wait=false >/dev/null 2>&1
  /bin/sleep 20; ok=0
  for i in $(seq 1 60); do
    v=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers | awk '{printf "%s/%s ", $3,$4}')
    p=$(kubectl -n v2test get pods --no-headers | awk '$2!="1/1"' | wc -l | tr -d ' ')
    if ! echo "$v" | grep -q 'degraded\|unknown\|faulted\|detached\|attaching' && [ "$p" = 0 ]; then ok=1; break; fi; /bin/sleep 10; done
  echo "   회복=$ok 걸린시간=$(( $(date +%s)-t0 ))s  volumes: $v  notready_pods=$p" >> $L
  for im in $(ims); do
    n=$(kubectl -n longhorn-system get pod $im -o jsonpath='{.spec.nodeName} restarts={.status.containerStatuses[0].restartCount}' 2>/dev/null)
    tr=$(kubectl -n longhorn-system exec $im -- go-spdk-helper nvmf transport-get 2>/dev/null | grep -c trtype)
    as=$(kubectl -n longhorn-system logs $im 2>/dev/null | grep -c 'Assertion\|iobuf.*fail\|Failed to create iobuf')
    echo "   $n transports=$tr assert/iobuf줄=$as" >> $L; done
done
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -i 'BackOff\|Unhealthy\|FailedAttach\|FailedMount' | tail -8 | cut -c1-220 >> $L
cat $L
