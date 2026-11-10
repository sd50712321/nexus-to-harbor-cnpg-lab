#!/bin/bash
# (랩) 노드를 한 대씩 재기동(vagrant reload) — Vagrantfile 의 메모리 변경 반영 + 쿼럼 유지 확인
#   ./scripts/rolling-reload.sh ks-cp3 ks-cp2 ks-cp1
#   W_MEM=2688 WAIT_DB=1 ./scripts/rolling-reload.sh ks-w1 ks-w2     # 워커: 다음 노드로 넘어가기 전에 DB 3/3 + 붙어 있는 Longhorn 볼륨 healthy 를 기다린다
#   (메모리 값은 Vagrantfile 이 읽는 환경변수 W_MEM/CP_MEM 또는 그 기본값. reload 때 VM 설정에 반영된다)
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
  if [ "${WAIT_DB:-0}" = 1 ]; then
    # DB 인스턴스·Longhorn 복제본이 그 노드에 있으면 돌아와 다시 붙을 때까지 다음 노드를 건드리지 않는다 (동시에 둘이 빠지면 동기 복제 대상이 없어 쓰기가 멈춘다)
    S=$(date +%s); ok=0
    for i in $(seq 1 120); do
      ph=$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.phase} {.status.readyInstances}/{.status.instances}' 2>/dev/null)
      bad=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$3=="attached" && $4!="healthy"' | wc -l | tr -d ' ')
      [ "$ph" = "Cluster in healthy state 3/3" ] && [ "$bad" = 0 ] && { ok=1; break; }; sleep 5
    done
    echo "$(date +%H:%M:%S) $n 이후 DB='$ph' 비정상 볼륨=$bad ($(( $(date +%s)-S ))s 대기) mem=$(kubectl get node $n -o jsonpath='{.status.capacity.memory}')"
    [ $ok = 1 ] || { echo "  [중단] 600s 안에 정상으로 안 돌아옴 — 다음 노드 진행 안 함"; exit 1; }
  fi
  sleep 20
done
