#!/bin/bash
# X1: 손으로 dm 을 멈추지 않는다. "다른 노드의 인스턴스 매니저가 내려갔다 올라옴 → 재구축 → Longhorn 이 스스로 dm 을 멈춤"
#     바로 그 순간에 엔진 노드의 spdk_tgt 가 죽으면 dm 이 Suspended 로 남는가. 이어서 파드를 다른 노드로 옮기면 어떻게 되는가.
#   x1-im-during-rebuild.sh <case> [더티 MB, 기본 400] [트리거 대기 초, 기본 240] [kill 후 파드 이동까지 초, 기본 180. 0 이면 즉시]
#   전제: w-prep.sh 로 u4 와 pg-prod 가 떠 있고 볼륨이 전부 healthy.
C=$1; MB=${2:-400}; TMO=${3:-240}; MV=${4:-180}; cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
export V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1
L=v2test/results/x/$C.log; mkdir -p v2test/results/x
NS=longhorn-system; PV=$(kubectl -n v2test get pvc u4 -o jsonpath='{.spec.volumeName}')
P=$(kubectl -n v2test get pods -l app=u4 -o jsonpath='{.items[0].metadata.name}'); N=$(kubectl -n v2test get pod $P -o jsonpath='{.spec.nodeName}')
M=$(for o in ks-w1 ks-w2 ks-w3; do [ $o != $N ] && echo $o; done | head -1)
im(){ kubectl -n $NS get instancemanagers.longhorn.io --no-headers | awk -v n=$1 '$2=="v2" && $5==n{print $1}'; }
IMN=$(im $N); IMM=$(im $M); ver=$(kubectl -n $NS get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
ns(){ vagrant ssh $N -c "sudo bash -c '$1'" 2>/dev/null | tr -d '\r'; }
st(){ echo "[$(date -u +%H:%M:%S)] $1"; kubectl -n $NS get volumes.longhorn.io $PV --no-headers -o custom-columns=S:.status.state,R:.status.robustness,NODE:.status.currentNodeID | sed 's/^/   volume /'
  kubectl -n v2test get pods -l app=u4 -o wide --no-headers | awk '{print "   pod",$1,$2,$3,$7}'
  ns "dmsetup info -c --noheadings -o name,suspended,open | grep ^pvc- | sed \"s/^/   dm /\"; ps -eo stat,etimes,comm --no-headers | awk \"\\\$1~/^D/{print \\\"   D\\\",\\\$2\\\"s\\\",\\\$3}\"; pgrep -f ^spdk_tgt >/dev/null && echo \"   spdk_tgt 살아 있음\" || echo \"   spdk_tgt 없음\""; }
{
echo "$C: Longhorn $ver. 엔진 노드 $N(u4), 인스턴스 매니저를 내릴 노드 $M. 더티 ${MB}MB. 손으로 suspend 하지 않음"
# 노드 N: 볼륨의 dm 이 Suspended 로 보이는 즉시 spdk_tgt 를 죽이는 트리거
T='P='$PV'; END=$(( $(date +%s)+'$TMO' )); n=0
while [ $(date +%s) -lt $END ]; do n=$((n+1))
  if dmsetup info -c --noheadings -o name,suspended 2>/dev/null | grep "^$P" | grep -q Suspended; then
    pkill -9 -f "^spdk_tgt"; echo "FIRED $(date -u +%H:%M:%S.%N | cut -c1-12) Suspended 를 보고 spdk_tgt kill -9 (폴링 $n회째)"; exit 0; fi
done; echo "NOT FIRED: ${n}회 폴링 동안 Suspended 를 못 봄"'
echo "$T" | base64 | tr -d '\n' > /tmp/x1-trigger.b64
ns "echo $(cat /tmp/x1-trigger.b64) | base64 -d > /root/x1-trigger.sh; chmod +x /root/x1-trigger.sh; rm -f /root/x1.out; dmesg -C; nohup /root/u-dmwatch.sh $((TMO+420)) > /root/dmwatch.out 2>&1 & nohup /root/x1-trigger.sh > /root/x1.out 2>&1 & echo trigger armed"
kubectl -n v2test exec $P -- bash -c "rm -f /data/big; dd if=/dev/zero of=/data/big bs=1M count=$MB 2>&1 | tail -1" 2>&1 | sed 's/^/   dd: /' &
/bin/sleep 4; st "처음"
echo ">>> $(date -u +%H:%M:%S) $M 의 인스턴스 매니저 파드 삭제 ($IMM) → 올라오면 재구축"
kubectl -n $NS delete pod $IMM --wait=false >/dev/null 2>&1
for i in $(seq 1 $((TMO/5+4))); do /bin/sleep 5; r=$(ns "cat /root/x1.out 2>/dev/null"); [ -n "$r" ] && break; done
echo ">>> 트리거: ${r:-응답 없음}"
case "$r" in FIRED*) F=1;; *) F=0;; esac
if [ $F = 1 ]; then
  if [ $MV -gt 0 ]; then for t in 20 60 120 180; do [ $t -gt $MV ] && break; /bin/sleep $([ $t = 20 ] && echo 15 || echo 50); st "kill 후 ~${t}s"; done; fi
  echo ">>> $(date -u +%H:%M:%S) $N cordon + 파드 삭제 (다른 노드로 이동)"
  kubectl cordon $N >/dev/null; kubectl -n v2test delete pod -l app=u4 --wait=false >/dev/null
  for t in 60 120 240 360; do /bin/sleep $([ $t = 60 ] && echo 50 || echo 100); st "이동 후 ~${t}s"; done
  echo "-- 이벤트"; kubectl -n v2test get events --sort-by=.lastTimestamp 2>/dev/null | grep -i 'FailedAttach\|FailedMount\|Killing\|FailedKill\|DeadlineExceeded' | tail -6 | cut -c1-230 | sed 's/^/   /'
else st "트리거 미발동"; fi
echo "-- dmwatch ($N)"; ns "cat /root/dmwatch.out | tail -25"
echo "-- 인스턴스 매니저 로그 ($N, suspend/resume)"; { kubectl -n $NS logs $(im $N) --previous --tail=4000 2>/dev/null; kubectl -n $NS logs $(im $N) --tail=4000 2>/dev/null; } | grep -i 'suspend\|resum' | grep -v 'Suspending linear\|Resuming linear' | sed 's/^\[longhorn-instance-manager\] time="[0-9-]*T//; s/func=[^ ]* file=[^ ]* //' | cut -c1-230 | tail -12 | sed 's/^/   /'
echo "-- dmesg ($N)"; ns "dmesg | grep -v \"Reconnecting in\|Failed reconnect\" | grep -i \"hung\|blocked for\|XFS\|nvme.*timeout\|nvme.*Removing\|failfast\" | uniq -c -f3 | tail -8 | cut -c1-170"
echo "-- 남은 dm 전수 조사"; ./v2test/dm-audit.sh 2>/dev/null | sed 's/^/   /'
left=$(ns "dmsetup info -c --noheadings -o name,suspended | grep ^pvc- | grep Suspended | cut -d: -f1")
if [ -n "$left" ]; then echo ">>> $(date -u +%H:%M:%S) 남은 Suspended dm 을 resume: $left"; for d in $left; do ns "dmsetup resume $d; sleep 5; dmsetup remove $d 2>&1 | tail -1"; done; /bin/sleep 20; st "resume 후"; fi
kubectl uncordon $N >/dev/null
} 2>&1 | tee $L | cut -c1-240
