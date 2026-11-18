#!/bin/bash
# 부하(pgbench)를 거는 도중에 계획 전환(switchover)을 하고, 1초 단위 tps 에서 쓰기가 끊긴 구간을 잰다.
#   perf/switchover-load.sh <네임스페이스> <클러스터> [접속 수=8] [전체 초=90] [전환 시점=30]
# 전환은 kubectl-cnpg 플러그인이 있으면 `kubectl cnpg promote`, 없으면 같은 동작의 status 패치로 한다.
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
NS=$1; C=$2; CL=${3:-8}; T=${4:-90}; AT=${5:-30}
perf/pgbench.sh $NS $C run 1 1 >/dev/null 2>&1      # 부하 파드 준비
OLD=$(kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}')
NEW=$(kubectl -n $NS get pods -l cnpg.io/cluster=$C,role=replica -o jsonpath='{.items[0].metadata.name}')
echo "### $C switchover $OLD → $NEW, clients=$CL $(date +%H:%M:%S)"
# pgbench 는 접속이 끊기면 끝나므로 반복문으로 다시 붙인다. 줄마다 시각을 붙인다
kubectl -n $NS exec pgbench-$C -- bash -c "end=\$((SECONDS+$T)); while [ \$SECONDS -lt \$end ]; do pgbench -n -c $CL -j 2 -T \$((end-SECONDS)) -P 1 2>&1 | grep --line-buffered -E '^progress|Run was aborted|could not connect|FATAL' | while read l; do echo \"\$(date +%H:%M:%S) \$l\"; done; echo \"\$(date +%H:%M:%S) -- pgbench 재접속\"; sleep 1; done" > /tmp/sw-$C.log 2>&1 &
/bin/sleep $AT; echo "전환 시작 $(date -u +%H:%M:%S) UTC"
if kubectl cnpg version >/dev/null 2>&1; then kubectl cnpg promote $C $NEW -n $NS
else kubectl -n $NS patch cluster $C --subresource=status --type merge -p "{\"status\":{\"targetPrimary\":\"$NEW\",\"targetPrimaryTimestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)\",\"phase\":\"Switchover in progress\",\"phaseReason\":\"Switching over to $NEW\"}}" >/dev/null; fi
wait
python3 - /tmp/sw-$C.log <<'PY'
import sys,datetime as d
L=[l.split(' ',1) for l in open(sys.argv[1]) if ' ' in l]
tm=lambda x:d.datetime.strptime(x,'%H:%M:%S')
ok=[tm(t) for t,r in L if r.startswith('progress') and float(r.split(',')[1].split()[0])>0]
bad=[tm(t) for t,r in L if not r.startswith('progress')]
if not bad: print('끊김 없음'); sys.exit()
b=min(bad); before=max([t for t in ok if t<=b],default=b); after=min([t for t in ok if t>before and t>=b],default=None)
tps=[float(r.split(',')[1].split()[0]) for t,r in L if r.startswith('progress')]
print(f"마지막 정상 {before.time()} → 첫 오류 {b.time()} → 다시 정상 {after.time() if after else '없음'}: 쓰기 중단 약 {(after-before).seconds if after else '?'}초 (1초 단위)")
print(f"1초 구간 {len(tps)}개, 평균 {sum(tps)/len(tps):.0f} tps, 오류·재접속 줄 {len(bad)}개")
PY
echo "--- 전환 앞뒤 ---"; grep -n -B2 -A14 -m1 -E "aborted|FATAL|could not" /tmp/sw-$C.log | grep -vE "client [1-9] " | cut -c1-120 | head -20
echo "새 primary: $(kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}')"
