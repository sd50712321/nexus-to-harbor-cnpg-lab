#!/bin/bash
# PVC/PV 수명 패턴별로 attach/detach 를 반복하고, 붙는 시간과 남는 dm(고아)을 센다.
#   u6-pv-cycle.sh <case> <delete|retain|static> <횟수>
#   delete: 동적 PV, Delete 정책 / retain: 동적 PV, Retain + 같은 이름 PVC 재생성(Released PV 가 쌓임)
#   static: 남아 있는 PV 하나를 claimRef 만 비워 계속 다시 묶음(정적 PV)
C=$1; M=$2; N=${3:-3}
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/u/$C.log; NS=v2test
kubectl get sc u6-retain >/dev/null 2>&1 || kubectl get sc pgtest-v2 -o json | python3 -c '
import json,sys; s=json.load(sys.stdin); s["metadata"]={"name":"u6-retain"}; s["reclaimPolicy"]="Retain"; s["volumeBindingMode"]="Immediate"; print(json.dumps(s))' | kubectl apply -f - >/dev/null
SC=pgtest-v2; [ $M != delete ] && SC=u6-retain
echo "$C: mode=$M x$N sc=$SC" > $L
mk(){ # $1 = volumeName (정적일 때)
cat <<Y | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: u6, namespace: $NS}
spec: {accessModes: [ReadWriteOnce], storageClassName: $SC, resources: {requests: {storage: 512Mi}}${1:+, volumeName: $1}}
---
apiVersion: v1
kind: Pod
metadata: {name: u6, namespace: $NS}
spec:
  terminationGracePeriodSeconds: 2
  securityContext: {runAsUser: 0}
  containers:
  - name: w
    image: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
    command: ["bash","-c","dd if=/dev/zero of=/data/f bs=1M count=50 oflag=direct; touch /data/ok; sleep 3600"]
    readinessProbe: {exec: {command: ["test","-f","/data/ok"]}, periodSeconds: 1}
    volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: u6}}]
Y
}
SPV=
if [ $M = static ]; then SPV=$(kubectl get pv --no-headers | awk '$5=="Released" && $6=="v2test/u6"{print $1}' | head -1); echo "  static PV=$SPV" >> $L; fi
for r in $(seq 1 $N); do
  [ -n "$SPV" ] && kubectl patch pv $SPV --type json -p '[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null 2>&1
  t0=$(date +%s); mk $SPV
  kubectl -n $NS wait pod/u6 --for=condition=Ready --timeout=300s >/dev/null 2>&1; rc=$?
  t1=$(date +%s); node=$(kubectl -n $NS get pod u6 -o jsonpath='{.spec.nodeName}'); pv=$(kubectl -n $NS get pvc u6 -o jsonpath='{.spec.volumeName}')
  kubectl -n $NS delete pod u6 --wait=true >/dev/null 2>&1; kubectl -n $NS delete pvc u6 --wait=true >/dev/null 2>&1
  for i in $(seq 1 30); do kubectl get volumeattachments --no-headers 2>/dev/null | grep -q " $pv " || break; /bin/sleep 2; done
  echo "  round $r ready_rc=$rc attach+ready=$((t1-t0))s detach=$(( $(date +%s)-t1 ))s node=$node pv=$pv" >> $L
done
echo "  PV (claim v2test/u6):" >> $L; kubectl get pv --no-headers | awk '$6=="v2test/u6"{print "   ",$1,$4,$5,$6}' >> $L
echo "  dm 전수:" >> $L; ./v2test/dm-audit.sh | sed 's/^/    /' >> $L
cat $L
