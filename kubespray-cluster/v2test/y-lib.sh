#!/bin/bash
# Y 시험 공통: pg-prod 에 pgbench 부하를 걸고, 1초 단위 기록에서 쓰기가 끊긴 구간을 뽑고, pg 데이터가 온전한지 본다.
cd "$(dirname "${BASH_SOURCE[0]}")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1
NS=longhorn-system; W="ks-w1 ks-w2 ks-w3"; mkdir -p v2test/results/y
ver(){ kubectl -n $NS get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://'; }
on(){ n=$1; shift; vagrant ssh $n -c "sudo bash -c '$*'" 2>/dev/null | tr -d '\r'; }
vols(){ kubectl -n $NS get volumes.longhorn.io --no-headers | awk '{printf "%s/%s ", $3,$4}'; }
allok(){ [ "$(kubectl -n v2test get cluster pg-prod -o jsonpath='{.status.readyInstances}')" = 3 ] && ! vols | grep -q 'degraded\|unknown\|faulted\|detached\|attaching' && kubectl -n v2test get pods -l app=u4 --no-headers | grep -q '1/1'; }
susp(){ for n in $W; do on $n "dmsetup info -c --noheadings -o name,suspended,open | grep ^pvc- | grep Suspended | sed \"s/^/$n /\""; done; }
# 부하 준비: scale 10 (약 150MB). 이미 있으면 건너뜀
load_init(){ perf/pgbench.sh v2test pg-prod run 1 1 >/dev/null 2>&1; kubectl -n v2test exec pgbench-pg-prod -- psql -Atc "select count(*) from pgbench_accounts" 2>/dev/null | grep -q 1000000 || perf/pgbench.sh v2test pg-prod init 10 2>&1 | tail -1
  # pgbench 를 -n 없이 돌리면 history 를 비운다(위 run 이 그렇다). 그래서 지금의 차이(계좌 합 - history 합)를 기준으로 적어 둔다.
  HB=$(kubectl -n v2test exec pgbench-pg-prod -- psql -Atc "select (select sum(abalance) from pgbench_accounts)-(select coalesce(sum(delta),0) from pgbench_history)" 2>/dev/null); echo "   history 기준 차이=$HB"; }
# 부하 시작: <초> <기록 파일>. 접속이 끊기면 다시 붙는다. 줄마다 시각(UTC)
load_start(){ kubectl -n v2test exec pgbench-pg-prod -- bash -c "end=\$((SECONDS+$1)); while [ \$SECONDS -lt \$end ]; do pgbench -n -c 4 -j 2 -T \$((end-SECONDS)) -P 1 2>&1 | grep --line-buffered -E '^progress|aborted|could not connect|FATAL' | while read l; do echo \"\$(date -u +%H:%M:%S) \$l\"; done; echo \"\$(date -u +%H:%M:%S) -- 재접속\"; sleep 1; done" > $2 2>&1 & LOADPID=$!; }
# 쓰기 중단 구간: tps>0 인 줄 사이가 3초 넘게 벌어진 곳
load_gaps(){ python3 - $1 <<'PY'
import sys,datetime as d
tm=lambda x:d.datetime.strptime(x,'%H:%M:%S'); ok=[]
for l in open(sys.argv[1]):
    p=l.split(' ',1)
    if len(p)==2 and p[1].startswith('progress'):
        try:
            if float(p[1].split(',')[1].split()[0])>0: ok.append((tm(p[0]),float(p[1].split(',')[1].split()[0])))
        except Exception: pass
if not ok: print('   정상 구간 없음'); sys.exit()
g=[(a[0],b[0],(b[0]-a[0]).seconds) for a,b in zip(ok,ok[1:]) if (b[0]-a[0]).seconds>3]
tot=(ok[-1][0]-ok[0][0]).seconds+1
print(f"   부하 {tot}초, 평균 {sum(t for _,t in ok)/len(ok):.0f} tps, 쓰기 중단 {len(g)}번 합계 {sum(x[2] for x in g)}초")
for a,b,s in g: print(f"   중단 {a.time()} ~ {b.time()} ({s}초)")
PY
}
# pg 데이터 점검: pgbench 불변식(계좌·창구·지점 잔액 합 = history 합), amcheck(테이블·인덱스 구조), standby 재생 위치
pg_check(){ P=$(kubectl -n v2test get cluster pg-prod -o jsonpath='{.status.currentPrimary}'); q(){ kubectl -n v2test exec $P -c postgres -- psql -U postgres -d app -Atc "$1" 2>&1; }
  echo "   primary=$P 잔액 합(계좌|창구|지점|history): $(q "select (select sum(abalance) from pgbench_accounts)||'|'||(select sum(tbalance) from pgbench_tellers)||'|'||(select sum(bbalance) from pgbench_branches)||'|'||(select coalesce(sum(delta),0)+${HB:-0} from pgbench_history)")"
  q "create extension if not exists amcheck" >/dev/null
  echo "   amcheck 인덱스: $(q "select count(*)||'개 통과' from (select bt_index_parent_check(c.oid, true) from pg_class c join pg_am a on a.oid=c.relam where a.amname='btree' and c.relname like 'pgbench%') s" | tail -1 | cut -c1-200)"
  echo "   amcheck 테이블 오류 줄: $(q "select count(*) from pg_class c, lateral verify_heapam(c.oid) v where c.relname like 'pgbench%' and c.relkind='r'" | tail -1 | cut -c1-200)"
  echo "   복제: $(q "select string_agg(application_name||':'||state||':'||coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)::text,'?'),' ') from pg_stat_replication")"; }
