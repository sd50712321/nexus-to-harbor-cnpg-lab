#!/bin/bash
# 계획된 노드 제거/교체 전에, 그 노드에 있는 DB standby 인스턴스를 다른 워커로 옮긴다. 결과 logs/db-move-<시각>.txt
#   전제: 그 인스턴스가 있는 노드를 먼저 cordon 해 둔다 (새 인스턴스가 같은 노드로 돌아오지 않게). primary 는 대상이 아니다(먼저 switchover).
#   방법: 그 인스턴스의 PVC + 파드 삭제 → operator 가 primary 에서 받아 다른 노드에 새로 만든다. 볼륨이 노드 로컬(strict-local)이라 "이동"이 아니라 "다시 만들기"다.
#   근거: CNPG docs troubleshooting.md "delete the PVC and let the operator rebuild the replica" (kubectl cnpg destroy 와 같은 동작)
#   옛 PV 는 reclaim=Retain 이라 Released 로 남는다 → 확인 후 따로 지운다(이 스크립트는 지우지 않음).
#   ./scripts/61-db-move-instance.sh harbor-pg-2
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
X=${1:?옮길 인스턴스 이름}; . scripts/harbor-env.sh; NS=harbor; CL=harbor-pg
OUT=logs/db-move-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
pgc(){ kubectl -n $NS get cluster $CL -o jsonpath="$1"; }
inst(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/podRole=instance -o jsonpath='{range .items[*]}{.metadata.name}{"@"}{.spec.nodeName}{"("}{.metadata.labels.cnpg\.io/instanceRole}{","}{.status.phase}{") "}{end}'; }
streaming(){ kubectl -n $NS exec "$(pgc '{.status.currentPrimary}')" -c postgres -- psql -tAc "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null; }
# bash 3.2(macOS) 따옴표 문제 때문에 본문·결과를 변수로 받는다 (60-db-node-loss.sh 와 같은 이유)
db_write(){ local n=m$(date +%s) body c; body=$(printf '{"project_name":"%s","public":false}' "$n")
  c=$(hcurl -m 8 -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$HU/api/v2.0/projects" -H 'Content-Type: application/json' -d "$body")
  [ "$c" = 201 ] || return 1; hcurl -m 8 -o /dev/null -u "$HA" -X DELETE "$HU/api/v2.0/projects/$n"; return 0; }

P=$(pgc '{.status.currentPrimary}'); XN=$(kubectl -n $NS get pod $X -o jsonpath='{.spec.nodeName}'); XUID=$(kubectl -n $NS get pod $X -o jsonpath='{.metadata.uid}')
PV=$(kubectl -n $NS get pvc $X -o jsonpath='{.spec.volumeName}')
echo "== 사전 상태"
echo "CNPG: phase='$(pgc '{.status.phase}')' primary=$P ready=$(pgc '{.status.readyInstances}')/$(pgc '{.status.instances}') streaming=$(streaming)"
echo "인스턴스: $(inst)"
echo "대상: $X @ $XN, PV $PV"
[ "$X" != "$P" ] || { echo "[중단] $X 는 primary. 먼저 switchover"; exit 1; }
[ "$(pgc '{.status.readyInstances}')" = "$(pgc '{.status.instances}')" ] || { echo "[중단] 모든 인스턴스가 ready 가 아님 — 하나를 더 빼면 동기 복제 대상이 없어 쓰기가 멈춘다"; exit 1; }
[ "$(kubectl get node $XN -o jsonpath='{.spec.unschedulable}')" = true ] || { echo "[중단] $XN 이 cordon 되어 있지 않음 (새 인스턴스가 같은 노드로 돌아올 수 있다)"; exit 1; }
db_write && echo "쓰기 확인(사전): OK" || { echo "[중단] 사전 쓰기 실패"; exit 1; }

echo; echo "== $X 의 PVC + 파드 삭제"
T=$(date +%s)
kubectl -n $NS delete pvc $X --wait=false 2>&1 | sed 's/^/    /'
kubectl -n $NS delete pod $X --wait=false 2>&1 | sed 's/^/    /'
ok=0; ng=0; done_at=""; join_at=""
while :; do
  e=$(( $(date +%s)-T ))
  db_write && { ok=$((ok+1)); w=OK; } || { ng=$((ng+1)); w=NG; }
  [ -z "$join_at" ] && kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/jobRole --no-headers 2>/dev/null | grep -q . && join_at=$e
  new=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/podRole=instance,cnpg.io/instanceName=$X -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk -v u=$XUID '$1!=u{print $2" "$3}')
  s=$(streaming); ph=$(pgc '{.status.phase}')
  echo "$(ts) +${e}s 쓰기=$w streaming=${s:-?} phase='$ph' 새 $X: ${new:-없음}"
  if [ "${new#* }" = True ] && [ "$s" = 2 ] && [ "$ph" = "Cluster in healthy state" ]; then done_at=$e; break; fi
  [ $e -ge 900 ] && break
  sleep 4
done
echo
[ -n "$done_at" ] && echo "$(ts) 결과: 새 $X 가 ${new% *} 에서 Ready + 복제 2개 streaming — 삭제 후 ${done_at}s (join 작업 시작 ${join_at:-?}s)" || echo "$(ts) [NG] 900s 안에 복구 안 됨"
echo "그동안 쓰기: 성공 $ok / 실패 $ng"
echo "인스턴스: $(inst)"
echo "옛 PV $PV: $(kubectl get pv $PV -o jsonpath='{.status.phase} reclaim={.spec.persistentVolumeReclaimPolicy}' 2>/dev/null) (지우지 않고 남겨 둠, 복제본은 $XN 에 있음)"
