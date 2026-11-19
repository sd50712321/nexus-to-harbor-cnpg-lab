#!/bin/bash
# Y1: 실제 pg 부하(pgbench) 아래에서 무작위 노드의 spdk_tgt 를 무작위 시점에 죽이는 일을 되풀이한다.
#     시점을 맞추지 않고, 파드를 손으로 옮기지도 않는다(CNPG 가 알아서 하게 둔다). 굳은 dm 이 저절로 생기는가.
#   y1-random-kill.sh <case> <횟수> [회복 한도 초, 기본 420]
. "$(dirname "$0")/y-lib.sh"; C=$1; R=${2:-8}; LIM=${3:-420}; L=v2test/results/y/$C.log; PG=v2test/results/y/$C.pgbench
{
echo "$C: Longhorn $(ver). pgbench 접속 4, u4 쓰기. spdk_tgt 무작위 kill -9 ${R}번, 회복 한도 ${LIM}초"
load_init; load_start $((R*(LIM/2+90))) $PG; stuck=0
for r in $(seq 1 $R); do n=$(echo $W | tr ' ' '\n' | awk -v s=$RANDOM 'BEGIN{srand(s)}{a[NR]=$0}END{print a[int(rand()*NR)+1]}'); w=$((RANDOM%40+15)); /bin/sleep $w
  pr=$(kubectl -n v2test get cluster pg-prod -o jsonpath='{.status.currentPrimary}'); prn=$(kubectl -n v2test get pod $pr -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  reb=$(vols | grep -c degraded); t0=$(date +%s); on $n "pkill -9 -f ^spdk_tgt"
  echo "[$(date -u +%H:%M:%S)] $r/$R $n 의 spdk_tgt kill (${w}초 대기 뒤, primary=$pr@$prn, 그때 degraded 볼륨 있음=$reb)"
  /bin/sleep 20; ok=0; while [ $(( $(date +%s)-t0 )) -lt $LIM ]; do allok && { ok=1; break; }; /bin/sleep 10; done
  s=$(susp); echo "   회복=$ok $(( $(date +%s)-t0 ))초  Suspended: ${s:-없음}"
  if [ $ok = 0 ]; then stuck=$((stuck+1)); echo "   볼륨: $(vols)"; kubectl -n v2test get pods -o wide --no-headers | awk '$2!="1/1"{print "   파드",$1,$2,$3,$7}'
    kubectl -n v2test get events --sort-by=.lastTimestamp | grep -i 'FailedAttach\|FailedMount\|FailedKill' | tail -3 | awk '{$1="";print "  "$0}' | cut -c1-200
    for n2 in $W; do on $n2 "ps -eo stat,etimes,comm --no-headers | awk \"\\\$1~/^D/{print \\\"   $n2 D\\\",\\\$2\\\"s\\\",\\\$3}\""; done
    if [ -n "$s" ]; then echo "$s" | while read n2 d rest; do d=${d%%:*}; echo "   >>> $n2 $d resume"; on $n2 "dmsetup resume $d"; done; fi
    t1=$(date +%s); while [ $(( $(date +%s)-t1 )) -lt 300 ]; do allok && break; /bin/sleep 10; done; echo "   조치 뒤 회복까지 $(( $(date +%s)-t1 ))초 (allok=$(allok && echo 1 || echo 0))"; fi
done
kill $LOADPID 2>/dev/null; kubectl -n v2test exec pgbench-pg-prod -- pkill pgbench 2>/dev/null
echo ">>> 요약: ${R}번 중 한도 안에 회복 못 함 ${stuck}번"; echo "-- 쓰기 중단"; load_gaps $PG
echo "-- 남은 dm"; ./v2test/dm-audit.sh 2>/dev/null | grep -v '정상' | sed 's/^/   /'
echo "-- pg 데이터"; pg_check
} 2>&1 | tee $L | cut -c1-220
