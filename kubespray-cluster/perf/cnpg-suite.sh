#!/bin/bash
# CNPG 성능 시험 묶음: 초기화 → 읽기·쓰기 → 읽기 전용 → 동기 복제를 안 기다릴 때 → 복제 지연 → fsync
#   perf/cnpg-suite.sh <네임스페이스> <클러스터> [scale=20] [접속 수=8] [초=60]
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
NS=$1; C=$2; SCALE=${3:-20}; CL=${4:-8}; T=${5:-60}
PRI=$(kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}')
q(){ kubectl -n $NS exec $PRI -c postgres -- psql -qAt -c "$1"; }
sum(){ grep -E "^tps|latency average|latency stddev|number of failed|scaling factor|number of clients"; }
echo "### $C (primary $PRI) scale=$SCALE clients=$CL ${T}s $(date +%H:%M:%S)"
echo "sync: $(q 'show synchronous_standby_names')  shared_buffers: $(q 'show shared_buffers')  max_connections: $(q 'show max_connections')"
echo "== init"; ( time perf/pgbench.sh $NS $C init $SCALE ) 2>&1 | grep -E "done in|real"
echo "db size: $(q "select pg_size_pretty(pg_database_size('app'))")"
echo "== 읽기·쓰기 (TPC-B)"; perf/pgbench.sh $NS $C run $CL $T | sum &
/bin/sleep $((T/2)); echo "  부하 중 복제 지연: $(q "select string_agg(application_name||' '||sync_state||' replay_lag='||coalesce(replay_lag::text,'0')||' behind='||pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)), ' | ') from pg_stat_replication")"; wait
echo "== 읽기 전용 (-S)"; perf/pgbench.sh $NS $C run $CL $T -S | sum
echo "== 읽기·쓰기, synchronous_commit=local (standby 를 기다리지 않음)"; PGOPTIONS="-c synchronous_commit=local" perf/pgbench.sh $NS $C run $CL $T | sum
echo "== 읽기·쓰기, 접속 수 $((CL*4))"; perf/pgbench.sh $NS $C run $((CL*4)) $T | sum
echo "== pg_test_fsync (primary 의 데이터 볼륨)"; kubectl -n $NS exec $PRI -c postgres -- pg_test_fsync -s 2 -f /var/lib/postgresql/data/pgdata/fsync.tmp 2>&1 | grep -E "fdatasync|open_datasync|fsync  " | head -4
echo "== 체크포인트·WAL"; q "select 'checkpoints timed='||checkpoints_timed||' requested='||checkpoints_req from pg_stat_bgwriter"      # PostgreSQL 17 부터는 pg_stat_checkpointer (num_timed, num_requested); q "select 'wal '||pg_size_pretty(wal_bytes)||' fpi='||wal_fpi from pg_stat_wal"
