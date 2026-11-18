#!/bin/bash
# CNPG 클러스터에 pgbench 를 돌린다. 클러스터 밖의 별도 파드에서 -rw 서비스로 붙는다(부하 도구가 DB 의 CPU 를 쓰지 않게).
#   perf/pgbench.sh <네임스페이스> <클러스터> init <scale>
#   perf/pgbench.sh <네임스페이스> <클러스터> run <접속 수> <초> [pgbench 추가 옵션, 예: -S]
#   PGOPTIONS="-c synchronous_commit=local" 을 앞에 붙이면 그 실행만 동기 복제를 기다리지 않는다
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
NS=$1; C=$2; MODE=$3; IMG=${IMG:-ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm}
kubectl -n $NS get pod pgbench-$C >/dev/null 2>&1 || { kubectl -n $NS apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: pgbench-$C, namespace: $NS}
spec:
  ${BENCH_NODE:+nodeName: $BENCH_NODE}
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: $IMG
    command: [sleep, "864000"]
    env:
    - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: $C-app, key: password}}}
    - {name: PGHOST, value: $C-rw}
    - {name: PGUSER, value: app}
    - {name: PGDATABASE, value: app}
Y
  kubectl -n $NS wait --for=condition=Ready pod/pgbench-$C --timeout=120s >/dev/null; }
case $MODE in
  init) kubectl -n $NS exec pgbench-$C -- pgbench -i -q -s ${4:-10} ;;
  run)  CL=$4; T=$5; shift 5; kubectl -n $NS exec pgbench-$C -- env PGOPTIONS="${PGOPTIONS:-}" pgbench -c $CL -j 2 -T $T -P ${P:-10} "$@" ;;
esac
