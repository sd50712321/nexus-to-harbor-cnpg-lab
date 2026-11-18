#!/bin/bash
# Harbor 성능 시험: 큰 이미지 push/pull, 동시 push, 작은 이미지 여러 개, API 부하, 그동안 DB(CNPG)가 한 일.
#   perf/harbor-bench.sh            (랩: scripts/harbor-env.sh 가 주소와 관리자 계정을 준다)
#   HARBOR_HOST=<호스트> HARBOR_CREDS=<계정:비밀번호> PG_NS=harbor PG_CLUSTER=harbor-pg perf/harbor-bench.sh
# 필요한 도구: skopeo, python3, oha(또는 ab), kubectl
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
[ -z "${HARBOR_CREDS:-}" ] && { . scripts/harbor-env.sh; HARBOR_CREDS=$HA; HARBOR_HOST=$HH; }
H=$HARBOR_HOST; P=${PROJECT:-perf}; BIG=${BIG_MB:-50}; W=${WORK:-/tmp/harbor-bench}; NS=${PG_NS:-harbor}; C=${PG_CLUSTER:-harbor-pg}
rm -rf $W; mkdir -p $W
api(){ curl -sk -u "$HARBOR_CREDS" -H 'Content-Type: application/json' "$@"; }
now(){ python3 -c 'import time;print(time.time())'; }
el(){ python3 -c "print(f'{$(now)-$1:.1f}')"; }
PRI=$(kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}')
db(){ kubectl -n $NS exec $PRI -c postgres -- psql -qAt -d registry -c "$1"; }
dbstat(){ db "select xact_commit||' '||tup_inserted+tup_updated+tup_deleted||' '||numbackends||' '||pg_database_size('registry')/1024/1024 from pg_stat_database where datname='registry'"; }
delta(){ set -- $1 $2; python3 -c "a='$1'.split(',');b='$2'.split(',');print(f'  DB: 커밋 +{int(b[0])-int(a[0])}, 행 변경 +{int(b[1])-int(a[1])}, 접속 {b[2]}개, 크기 {b[3]}MB')"; }
d(){ dbstat | tr ' ' ','; }
echo "### Harbor $(api https://$H/api/v2.0/systeminfo | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","?"))'), DB primary $PRI, $(date +%H:%M:%S)"
api -X POST https://$H/api/v2.0/projects -d "{\"project_name\":\"$P\"}" -o /dev/null
push(){ skopeo copy -q --dest-tls-verify=false --dest-creds "$HARBOR_CREDS" oci:$1 docker://$H/$P/$2; }
pull(){ skopeo copy -q --src-tls-verify=false --src-creds "$HARBOR_CREDS" docker://$H/$P/$1 dir:$2; }
R=$(date +%s)

echo "== 1. 큰 이미지 하나 (${BIG}MB 레이어 1개)"
python3 perf/mkimage.py $W/big $BIG; a=$(d); t=$(now); push $W/big big:$R; s=$(el $t)
echo "  push ${s}s ($(python3 -c "print(f'{$BIG/$s:.1f}')") MB/s)"; delta $a $(d)
t=$(now); pull big:$R $W/pull; s=$(el $t); echo "  pull ${s}s ($(python3 -c "print(f'{$BIG/$s:.1f}')") MB/s)"

echo "== 2. 동시 push 4개 (각 ${BIG}MB)"
for i in 1 2 3 4; do python3 perf/mkimage.py $W/c$i $BIG; done; a=$(d); t=$(now)
for i in 1 2 3 4; do push $W/c$i conc$i:$R & done; wait; s=$(el $t)
echo "  ${s}s (합계 $(python3 -c "print(f'{4*$BIG/$s:.1f}')") MB/s)"; delta $a $(d)

echo "== 3. 작은 이미지 30개 (각 1MB, 차례로): 데이터보다 요청 수가 많은 경우"
for i in $(seq 30); do python3 perf/mkimage.py $W/s$i 1; done; a=$(d); t=$(now)
for i in $(seq 30); do push $W/s$i small:$R-$i; done; s=$(el $t)
echo "  ${s}s (이미지당 $(python3 -c "print(f'{$s/30:.2f}')")s)"; delta $a $(d)

echo "== 4. API 부하 (oha, 20 동시, 500 요청씩)"
for u in "/api/v2.0/projects" "/api/v2.0/projects/$P/repositories?page_size=50" "/api/v2.0/projects/$P/repositories/small/artifacts?page_size=50"; do
  a=$(d); oha --no-tui -n 500 -c 20 --insecure -a "$HARBOR_CREDS" "https://$H$u" 2>/dev/null > $W/oha.txt
  echo "  $u"; echo "    $(grep -E 'Requests/sec' $W/oha.txt | xargs) | $(grep -E '^ +(50|95|99)\.00% in' $W/oha.txt | xargs) | $(grep -A6 'Status code' $W/oha.txt | grep -E '\[[0-9]+\]' | xargs)"; delta $a $(d)
done

echo "== 5. DB 에 쌓인 것"
db "select relname||' '||n_live_tup||'행 '||pg_size_pretty(pg_total_relation_size(relid)) from pg_stat_user_tables order by pg_total_relation_size(relid) desc limit 6"
db "select 'max_connections='||current_setting('max_connections')||', 지금 접속 '||count(*)||'개 (idle '||count(*) filter (where state='idle')||')' from pg_stat_activity where datname='registry'"
rm -rf $W
