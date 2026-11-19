#!/bin/bash
# X2: CNPG 클러스터를 새로 만드는 동안(초기화 잡 → 본 파드 → 조인 잡 → 본 파드, 같은 볼륨을 연달아 떼고 붙임)
#     V2 인스턴스 매니저 파드를 돌아가며 내린다. 클러스터가 끝까지 올라오는가, 굳은 dm 이 남는가.
#   x2-pg-create-im-restart.sh <case> <내리는 횟수, 0 이면 기준선> [간격 초, 기본 40] [기다리는 한도 초, 기본 900]
C=$1; K=${2:-0}; GAP=${3:-40}; LIM=${4:-900}; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
export V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1
L=v2test/results/x/$C.log; mkdir -p v2test/results/x; NS=longhorn-system; W="ks-w1 ks-w2 ks-w3"
ver=$(kubectl -n $NS get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
im(){ kubectl -n $NS get instancemanagers.longhorn.io --no-headers | awk -v n=$1 '$2=="v2" && $5==n{print $1}'; }
pods(){ kubectl -n v2test get pods -o wide --no-headers 2>/dev/null | grep '^pg-x2' | awk '{printf "%s(%s,%s) ", $1,$3,$7}'; }
st(){ echo "[$(date -u +%H:%M:%S) +$(( $(date +%s)-t0 ))s] ready=$(kubectl -n v2test get cluster pg-x2 -o jsonpath='{.status.readyInstances}' 2>/dev/null)/3 phase=\"$(kubectl -n v2test get cluster pg-x2 -o jsonpath='{.status.phase}' 2>/dev/null)\""; echo "   $(pods)"
  kubectl -n $NS get volumes.longhorn.io --no-headers -o custom-columns=N:.metadata.name,S:.status.state,R:.status.robustness,NODE:.status.currentNodeID,PVC:.status.kubernetesStatus.pvcName | awk '$5~/^pg-x2/{printf "   vol %s %s/%s@%s\n",$5,$2,$3,$4}'; }
{
echo "$C: Longhorn $ver. pg-x2(3 인스턴스, 1Gi) 생성 중 V2 인스턴스 매니저를 ${GAP}초 간격으로 ${K}번 내림 (w1→w2→w3 순환)"
for n in $W; do vagrant ssh $n -c "sudo bash -c 'dmesg -C; nohup /root/u-dmwatch.sh $((LIM+60)) > /root/dmwatch.out 2>&1 &'" 2>/dev/null; done
sed 's/name: pg-prod/name: pg-x2/; s/size: 2Gi/size: 1Gi/' v2test/pg-prod.yaml | kubectl apply -f - | sed 's/^/   /'; t0=$(date +%s)
/bin/sleep 12; i=0
for n in $(for r in $(seq 1 $K); do echo $W; done | tr ' ' '\n' | head -$K); do i=$((i+1)); st "내리기 직전"
  echo ">>> $(date -u +%H:%M:%S) [$i/$K] $n 의 인스턴스 매니저 파드 삭제"; kubectl -n $NS delete pod $(im $n) --wait=false >/dev/null 2>&1; /bin/sleep $GAP; done
ok=0; while [ $(( $(date +%s)-t0 )) -lt $LIM ]; do r=$(kubectl -n v2test get cluster pg-x2 -o jsonpath='{.status.readyInstances}' 2>/dev/null)
  [ "$r" = 3 ] && { ok=1; break; }; [ $(( ($(date +%s)-t0) % 120 )) -lt 10 ] && st "대기"; /bin/sleep 10; done
st "끝"; echo ">>> 결과: 3/3 도달=$ok, 걸린 시간 $(( $(date +%s)-t0 ))s (한도 ${LIM}s)"
echo "-- 이벤트"; kubectl -n v2test get events --sort-by=.lastTimestamp 2>/dev/null | grep 'pg-x2' | grep -i 'FailedAttach\|FailedMount\|FailedKill\|DeadlineExceeded\|BackOff\|FailedCreatePodSandBox' | awk '{$1="";print}' | cut -c1-200 | sort | uniq -c | sort -rn | head -8 | sed 's/^/   /'
echo "-- 남은 dm 전수 조사"; ./v2test/dm-audit.sh 2>/dev/null | sed 's/^/   /'
for n in $W; do echo "-- $n dmwatch 요약 / D 상태 / dmesg"; vagrant ssh $n -c "sudo bash -c 'grep -c Suspended /root/dmwatch.out; grep \"최장\|끝까지\" /root/dmwatch.out; ps -eo stat,etimes,comm --no-headers | awk \"\\\$1~/^D/\"; dmesg | grep -i \"hung\|blocked for\|XFS.*shut\|I/O error\" | uniq -c -f3 | tail -4 | cut -c1-150; pkill -x u-dmwatch.sh'" 2>/dev/null | tr -d '\r' | sed 's/^/   /'; done
echo "-- 인스턴스 매니저"; kubectl -n $NS get pods --no-headers | grep instance-manager | awk '{print "   ",$1,$2,$3,$4,$5}'
} 2>&1 | tee $L | cut -c1-220
