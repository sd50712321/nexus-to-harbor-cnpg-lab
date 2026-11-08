#!/bin/bash
# (랩) 노드를 한 대씩 재기동(vagrant reload) — Vagrantfile 의 메모리 변경 반영 + 쿼럼 유지 확인
#   ./scripts/rolling-reload.sh ks-cp3 ks-cp2 ks-cp1
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
# Ready 표시만 보면 재기동이 빨라 NotReady 로 바뀌기 전 값이 남는다 → kubelet 이 기동 후 lease 를 갱신했는지 본다
renewed_after(){ local r=$(kubectl -n kube-node-lease get lease $1 -o jsonpath='{.spec.renewTime}' 2>/dev/null); [ -n "$r" ] && \
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $2 ]; }
for n in "$@"; do
  echo "$(date +%H:%M:%S) $n reload"
  B=$(date +%s); vagrant reload $n >/dev/null 2>&1 || echo "  [NG] vagrant reload 실패"
  for i in $(seq 1 60); do kubectl get node $n --no-headers 2>/dev/null | grep -qw Ready && renewed_after $n $B && break; sleep 5; done
  echo "$(date +%H:%M:%S) $n $(kubectl get node $n --no-headers | awk '{print $2}'), API(VIP): $(curl -sk -m 3 https://172.16.141.30:6443/livez)"
  sleep 20
done
