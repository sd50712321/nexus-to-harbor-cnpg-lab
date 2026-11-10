#!/bin/bash
# DB 인스턴스가 있던 워커가 "돌아오지 않는" 경우 (이 랩 VM 만 정지/기동). 결과 logs/db-node-loss-<시각>.txt
#   G1. standby 인스턴스가 있는 워커 강제 정지 → OBS 초 동안 관찰: CNPG 가 스스로 다른 노드에 새 인스턴스를 만드는가, 그동안 DB 쓰기는 되는가
#   G2. 영구 손실 절차: 그 인스턴스의 PVC + 파드 삭제 → 다른 워커에 새 인스턴스가 생기는가(소요 시간, 복제 연결 수)
#   G3. 꺼 두었던 워커 기동 → 옛 볼륨(PV Retain)이 어떻게 남는가
# 근거: CNPG docs failure_modes.md "Standby Failure"(PVC 가 있으면 그 PVC 로 재기동, 없으면 primary 에서 새로 만든다),
#       troubleshooting.md "delete the PVC and let the operator rebuild the replica"
#   OBS=420 ./scripts/60-db-node-loss.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
. scripts/harbor-env.sh; OBS=${OBS:-420}; NS=harbor; CL=harbor-pg
OUT=logs/db-node-loss-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
pgc(){ kubectl -n $NS get cluster $CL -o jsonpath="$1"; }
inst(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.metadata.name}{"@"}{.spec.nodeName}{"("}{.metadata.labels.cnpg\.io/instanceRole}{","}{.status.phase}{") "}{end}'; }
pvcs(){ kubectl -n $NS get pvc -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{" "}{end}'; }
streaming(){ kubectl -n $NS exec "$(pgc '{.status.currentPrimary}')" -c postgres -- psql -tAc "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null; }
# 주의: macOS 기본 bash 3.2 는 "$( … \"…\" … )" 안의 이스케이프 따옴표를 잘못 쪼갠다("[: too many arguments") → 본문은 변수에, 결과도 변수에 받아서 비교
db_write(){ local n=g$(date +%s) body c; body=$(printf '{"project_name":"%s","public":false}' "$n")
  c=$(hcurl -m 8 -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$HU/api/v2.0/projects" -H 'Content-Type: application/json' -d "$body")
  [ "$c" = 201 ] || return 1; hcurl -m 8 -o /dev/null -u "$HA" -X DELETE "$HU/api/v2.0/projects/$n"; return 0; }

echo "== 사전 상태"
echo "CNPG: phase='$(pgc '{.status.phase}')' primary=$(pgc '{.status.currentPrimary}') instances=$(pgc '{.status.instances}') ready=$(pgc '{.status.readyInstances}')"
echo "인스턴스: $(inst)"; echo "PVC: $(pvcs)"; echo "복제 streaming: $(streaming)"
[ "$(pgc '{.status.readyInstances}')" = 3 ] || { echo "[중단] ready 3 이 아님"; exit 1; }
P=$(pgc '{.status.currentPrimary}')
# standby 중, 그 노드에 Harbor 파드가 가장 적은 것을 고른다(다른 영향과 섞이지 않게)
X=""; XN=""; best=999
for p in $(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.name}'); do [ $p = $P ] && continue
  n=$(kubectl -n $NS get pod $p -o jsonpath='{.spec.nodeName}'); c=$(kubectl -n $NS get pods --field-selector spec.nodeName=$n --no-headers | grep -vc "^$CL-")
  [ $c -lt $best ] && { best=$c; X=$p; XN=$n; }; done
ORIG=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.name}'); ORIGUID=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.uid}')
PV=$(kubectl -n $NS get pvc $X -o jsonpath='{.spec.volumeName}')
echo "대상: standby $X @ $XN (그 노드의 다른 harbor 파드 $best 개), PV $PV, Longhorn 복제본 위치: $(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$PV')]}{.spec.nodeID} {end}")"
echo "DB 가 없는 워커: $(comm -23 <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|node/||' | sort) <(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort) | tr '\n' ' ')"

echo; echo "== G1. $XN 강제 정지 후 ${OBS}s 관찰 (아무것도 손대지 않음)"
vagrant halt $XN --force >/dev/null 2>&1; S=$(date +%s); echo "$(ts) $XN 정지"
W1=""; while [ $(( $(date +%s)-S )) -lt $OBS ]; do
  e=$(( $(date +%s)-S ))
  [ -z "$W1" ] && [ $e -ge 20 ] && { db_write && W1="OK(${e}s)" || W1=""; [ -n "$W1" ] && echo "$(ts) +${e}s DB 쓰기(프로젝트 생성) $W1"; }
  echo "$(ts) +${e}s node=$(kubectl get node $XN --no-headers | awk '{print $2}') pod=$(kubectl -n $NS get pod $X --no-headers 2>/dev/null | awk '{print $2"/"$3}') phase='$(pgc '{.status.phase}')' ready=$(pgc '{.status.readyInstances}')/$(pgc '{.status.instances}') streaming=$(streaming) pods=[$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.name}')]"
  sleep 30; done
NEW=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}' | awk -v u="$ORIGUID" 'index(u,$2)==0{print $1}')
[ -z "$NEW" ] && echo "$(ts) 결과: ${OBS}s 동안 새 인스턴스가 만들어지지 않음. PVC: $(pvcs)" || echo "$(ts) 결과: 새 인스턴스가 스스로 생김 → $NEW"
db_write && echo "$(ts) DB 쓰기 OK (standby 1개 없는 상태)" || echo "$(ts) [NG] DB 쓰기 실패"
kubectl -n $NS get events --field-selector involvedObject.name=$X --sort-by=.lastTimestamp 2>/dev/null | tail -4 | sed 's/^/    /'

echo; echo "== G2. 영구 손실 절차: PVC + 파드 삭제"
T=$(date +%s)
kubectl -n $NS delete pvc $X --wait=false | sed 's/^/    /'
kubectl -n $NS delete pod $X --force --grace-period=0 2>&1 | grep -v Warning | sed 's/^/    /'
joinpod(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/jobRole --no-headers 2>/dev/null | grep -q .; }
t=$(wait_until 600 joinpod) && echo "$(ts) 새 인스턴스 생성 작업(join) 시작: ${t}s" || { echo "$(ts) [NG] 600s 안에 생성 작업 없음"; kubectl -n $NS get pods,pvc,jobs | sed 's/^/    /'; }
# 새 인스턴스 = cnpg.io/instanceName 라벨이 붙은 파드 중, 꺼진 노드가 아닌 곳에서 Ready 이고 원래 있던 UID 가 아닌 것
newinst(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/podRole=instance -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | awk -v u="$ORIGUID" -v xn=$XN 'index(u,$2)==0 && $3!=xn && $4=="True"{print $1"@"$3; f=1} END{exit !f}'; }
t=$(wait_until 900 newinst) && echo "$(ts) 새 인스턴스 Ready: $(newinst) — 삭제 후 $(( $(date +%s)-T ))s" || { echo "$(ts) [NG] 900s 안에 새 인스턴스 Ready 안 됨"; kubectl -n $NS get pods,pvc,jobs | sed 's/^/    /'; }
t=$(wait_until 300 "[ \$(streaming) = 2 ]") && echo "$(ts) 복제 2개 streaming — 삭제 후 $(( $(date +%s)-T ))s"
kubectl -n $NS exec "$(pgc '{.status.currentPrimary}')" -c postgres -- psql -tAc "select application_name,state,sync_state from pg_stat_replication" | sed 's/^/    /'
echo "인스턴스: $(inst)"; echo "PVC: $(pvcs)"
echo "옛 PV $PV: $(kubectl get pv $PV -o jsonpath='{.status.phase} reclaim={.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || echo 없음) / Longhorn 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}' 2>/dev/null || echo 없음)"

echo; echo "== G3. $XN 기동"
B=$(date +%s); vagrant up $XN >/dev/null 2>&1
wait_until 300 "node_back $XN $B" >/dev/null && echo "$(ts) $XN kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $XN 복귀 안 됨"
sleep 60
echo "CNPG: phase='$(pgc '{.status.phase}')' primary=$(pgc '{.status.currentPrimary}') instances=$(pgc '{.status.instances}') ready=$(pgc '{.status.readyInstances}')"
echo "인스턴스: $(inst)"; echo "PVC: $(pvcs)"
echo "옛 PV $PV: $(kubectl get pv $PV -o jsonpath='{.status.phase}' 2>/dev/null || echo 없음) / Longhorn 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}' 2>/dev/null || echo 없음) (지우지 않고 남겨 둠)"
kubectl get nodes --no-headers | awk '{print "   ",$1,$2}'
