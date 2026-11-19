#!/bin/bash
# Y3: pg 부하와 u4 쓰기가 도는 채로 Longhorn 을 helm 으로 올린다(1.12.1 → 1.12.2). 실서버가 할 작업의 예행.
#     볼 것: 쓰기 중단, 인스턴스 매니저가 언제 새 이미지로 바뀌는가, 굳은 dm, 끝난 뒤 데이터.
#   y3-upgrade-under-load.sh <case> <새 버전> [helm 뒤 지켜보는 초, 기본 420]
. "$(dirname "$0")/y-lib.sh"; C=$1; V=$2; WATCH=${3:-420}; L=v2test/results/y/$C.log; PG=v2test/results/y/$C.pgbench
ims(){ kubectl -n $NS get pods -l longhorn.io/component=instance-manager -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.labels.longhorn\.io/data-engine}{" "}{.spec.containers[0].image}{" "}{.status.startTime}{"\n"}{end}' | sed 's/longhornio\/longhorn-instance-manager://' | sort | awk '{printf "%s/%s=%s(%s) ", $1,$2,$3,substr($4,12,8)}'; }
st(){ echo "[$(date -u +%H:%M:%S)] $1"; echo "   볼륨: $(vols)"; echo "   IM: $(ims)"; s=$(susp); [ -n "$s" ] && echo "   Suspended: $s"; kubectl -n v2test get pods --no-headers | awk '$2!="1/1" && $1!~/pgbench/{print "   파드",$1,$2,$3}'; }
{
echo "$C: Longhorn $(ver) → $V. pgbench 접속 4 + u4 쓰기 중에 helm upgrade"
load_init; for n in $W; do on $n "dmesg -C; nohup /root/u-dmwatch.sh $((WATCH+900)) > /root/dmwatch.out 2>&1 &"; done
load_start $((WATCH+900)) $PG; /bin/sleep 30; st "올리기 전"; pg_check
echo ">>> $(date -u +%H:%M:%S) helm upgrade --version $V"; t0=$(date +%s)
on ks-cp1 "helm repo update longhorn >/dev/null 2>&1; helm upgrade longhorn longhorn/longhorn -n $NS --version $V -f /root/lh-values.yaml --wait --timeout 15m 2>&1 | grep -E \"STATUS|Error|REVISION\"" | sed 's/^/   /'
echo ">>> helm 끝 $(( $(date +%s)-t0 ))초"; st "helm 직후"
for t in 60 180 300 $WATCH; do /bin/sleep $(( t==60 ? 60 : 120 )); st "helm 뒤 ~${t}초"; done
echo "-- 엔진·인스턴스 매니저 이미지"; kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sed 's/.*\///' | sort | uniq -c | sed 's/^/   /'
kubectl -n $NS get instancemanagers.longhorn.io --no-headers | awk '{print "   IM",$1,$2,$3,$4,$5}'
kill $LOADPID 2>/dev/null; kubectl -n v2test exec pgbench-pg-prod -- pkill pgbench 2>/dev/null
echo "-- 쓰기 중단"; load_gaps $PG
for n in $W; do echo "-- $n dmwatch"; on $n "grep -c Suspended /root/dmwatch.out; grep \"최장\\|끝까지\" /root/dmwatch.out; pkill -x u-dmwatch.sh"; done | sed 's/^/   /'
echo "-- 남은 dm"; ./v2test/dm-audit.sh 2>/dev/null | grep -v '정상' | sed 's/^/   /'
echo "-- pg 데이터"; pg_check
} 2>&1 | tee $L | cut -c1-260
