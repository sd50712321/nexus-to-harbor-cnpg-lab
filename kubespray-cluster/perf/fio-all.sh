#!/bin/bash
# StorageClass 를 하나씩 바꿔 가며 perf/fio.yaml 을 돌리고 결과를 모은다.
#   NODE=ks-w2 perf/fio-all.sh longhorn longhorn-v2 longhorn-v2-single
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
export NODE=${NODE:-ks-w2} SIZE=${SIZE:-2G} RUNTIME=${RUNTIME:-20} PROXY=${PROXY:-http://172.16.141.1:3128}
for SC in "$@"; do export SC
  echo "### $SC @ $NODE size=$SIZE runtime=${RUNTIME}s $(date +%H:%M:%S)"
  envsubst '$SC $NODE $SIZE $RUNTIME $PROXY' < perf/fio.yaml | kubectl apply -f - >/dev/null
  kubectl -n perf wait --for=condition=complete job/fio-$SC --timeout=${MAX:-1200}s >/dev/null 2>&1 || echo "  (미완료)"
  kubectl -n perf logs job/fio-$SC
  kubectl -n perf delete job fio-$SC >/dev/null; kubectl -n perf delete pvc fio-$SC >/dev/null
done
