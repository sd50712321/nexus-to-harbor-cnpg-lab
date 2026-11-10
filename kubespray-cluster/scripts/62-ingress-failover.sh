#!/bin/bash
# 진입점(ingress-nginx VIP) 시험 (이 랩 VM 만 정지/기동). 결과 logs/ingress-<시각>.txt, 1초 간격 탐침 기록 logs/ingress-probe-<시각>.txt
#   K. 큰 요청 본문: Ingress 의 proxy-body-size 를 1m 로 줄였다가 되돌리며 3MB 업로드 응답 코드를 본다 (Harbor 차트 기본값 "0" = 제한 없음)
#   L. VIP 를 ARP 로 알리는 워커 정지 → 다른 워커가 VIP 를 넘겨받을 때까지 끊기는 시간
#   M. ingress-nginx 컨트롤러 파드가 있는 워커(VIP 를 알리는 노드가 아닌 것) 정지 → 남은 컨트롤러로만 갈 때까지 실패하는 요청
#   ./scripts/62-ingress-failover.sh [K] [L] [M]   (인자 없으면 전부)
# 탐침 두 가지: nginx = VIP 에 호스트명 없이 요청(컨트롤러 자체가 404 로 답함, Harbor 와 무관), harbor = Harbor ping(컨트롤러 → core 까지)
# registry·jobservice 까지는 10초마다 찍는 상태 줄의 Harbor=(health API)로 본다
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
. scripts/harbor-env.sh
TESTS=${*:-K L M}; DOWN=${DOWN:-150}
STAMP=$(date +%m%d-%H%M); OUT=logs/ingress-$STAMP.txt; PR=logs/ingress-probe-$STAMP.txt; mkdir -p logs
exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
LEASE=cilium-l2announce-ingress-nginx-ingress-nginx-controller
holder(){ kubectl -n kube-system get lease $LEASE -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
health(){ hcurl -m 3 $HU/api/v2.0/health 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);b=[c['name'] for c in d['components'] if c['status']!='healthy'];print(d['status']+('('+','.join(b)+')' if b else ''))" 2>/dev/null || echo 응답없음; }
ctl_nodes(){ kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{range .items[*]}{.spec.nodeName}{"("}{.status.phase}{") "}{end}'; }
on_node(){ kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | awk -v n=$1 '$1==n{print $2}' | grep -E '^(harbor|ingress-nginx|cnpg-system)/' | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//' | tr '\n' ' '; }
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
probe(){ while :; do
    a=$(curl -sk -m 2 -o /dev/null -w '%{http_code}' https://$HV/); b=$(hcurl -m 2 -o /dev/null -w '%{http_code}' $HU/api/v2.0/ping)
    echo "$(date +%s) $(ts) nginx=$a harbor=$b"; sleep 1; done >> "$PR"; }
# 탐침 기록에서 [from,to] 구간의 실패(nginx 404 아님 / harbor 200 아님)를 센다
summary(){ awk -v f=$1 -v t=$2 '$1>=f && $1<=t { n++; split($3,a,"="); split($4,b,"=");
    if (a[2]!="404") { na++; if(!fa) fa=$2; la=$2 }  if (b[2]!="200") { nb++; if(!fb) fb=$2; lb=$2 } }
  END { printf "    탐침 %d번: nginx 실패 %d번%s, harbor 실패 %d번%s\n", n, na, (na? " ("fa"~"la")":""), nb, (nb? " ("fb"~"lb")":"") }' "$PR"; }
stop_node(){ # $1=노드
  local N=$1; echo "$(ts) $N 에 있던 것: $(on_node $N)"
  probe & PP=$!; sleep 10
  S=$(date +%s); echo "$(ts) $N 강제 정지"; vagrant halt $N --force >/dev/null 2>&1
  local e; while e=$(( $(date +%s)-S )); [ $e -lt $DOWN ]; do
    echo "$(ts) +${e}s VIP 알리는 노드=$(holder) 컨트롤러=[$(ctl_nodes)] 노드=$(kubectl get node $N --no-headers 2>/dev/null | awk '{print $2}') Harbor=$(health)"; sleep 10; done
  E=$(date +%s); echo "$(ts) 정지 중 ${DOWN}s:"; summary $S $E
  echo "$(ts) $N 기동"; B=$(date +%s); vagrant up $N >/dev/null 2>&1
  wait_until 300 "node_back $N $B" >/dev/null && echo "$(ts) $N kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $N 복귀 안 됨"
  wait_until 600 "[ \"\$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.phase} {.status.readyInstances}')\" = 'Cluster in healthy state 3' ] && [ \$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller --no-headers | grep -c '1/1.*Running') -ge 3 ]" >/dev/null \
    && echo "$(ts) DB 3/3, 컨트롤러 3개 Running: [$(ctl_nodes)]" || echo "$(ts) [NG] 600s 안에 원상 복귀 안 됨: [$(ctl_nodes)]"
  # ping 은 core 까지만 본다. registry·jobservice 는 볼륨을 다시 붙여야 해서 더 늦게 돌아온다(health API 로 확인)
  wait_until 600 "[ \"\$(health)\" = healthy ]" >/dev/null && echo "$(ts) Harbor health 전 구성요소 healthy (기동 명령 후 $(( $(date +%s)-B ))s, 정지 후 $(( $(date +%s)-S ))s)" || echo "$(ts) [NG] Harbor health: $(health)"
  sleep 5; kill $PP 2>/dev/null; wait $PP 2>/dev/null
  echo "$(ts) 기동 뒤:"; summary $E $(date +%s)
}

for T in $TESTS; do case $T in
K)
echo "== K. 큰 요청 본문 (3MB 업로드)"
head -c 3000000 /dev/urandom > /tmp/ks-body.bin
up(){ local loc; loc=$(hcurl -m 10 -u "$HA" -X POST -o /dev/null -D - $HU/v2/lab/bodytest/blobs/uploads/ | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
  case "$loc" in /*) loc=$HU$loc;; esac
  hcurl -m 30 -u "$HA" -X PATCH -H 'Content-Type: application/octet-stream' --data-binary @/tmp/ks-body.bin -o /dev/null -w '%{http_code}' "$loc"; }
cur(){ kubectl -n harbor get ingress harbor-ingress -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/proxy-body-size}'; }
echo "$(ts) proxy-body-size=$(cur) → 업로드 응답 $(up)   (202 = 받음)"
kubectl -n harbor annotate ingress harbor-ingress nginx.ingress.kubernetes.io/proxy-body-size=1m --overwrite >/dev/null; sleep 8
echo "$(ts) proxy-body-size=$(cur) → 업로드 응답 $(up)   (413 = nginx 가 크기 초과로 거절)"
kubectl -n harbor annotate ingress harbor-ingress nginx.ingress.kubernetes.io/proxy-body-size=0 --overwrite >/dev/null; sleep 8
echo "$(ts) proxy-body-size=$(cur) 로 되돌림 → 업로드 응답 $(up)"
rm -f /tmp/ks-body.bin
;;
L)
echo; echo "== L. VIP $HV 를 ARP 로 알리는 워커 정지"
N=$(holder); echo "$(ts) VIP 알리는 노드: $N / 컨트롤러: [$(ctl_nodes)]"
stop_node $N
echo "    지금 VIP 알리는 노드: $(holder)"
;;
M)
echo; echo "== M. 컨트롤러 파드가 있는 워커 정지 (VIP 를 알리는 노드 제외, DB primary 노드 제외)"
H=$(holder); PN=$(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].spec.nodeName}')
N=""; for c in $(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort); do
  [ "$c" != "$H" ] && [ "$c" != "$PN" ] && { N=$c; break; }; done
[ -z "$N" ] && { echo "   [SKIP] 조건에 맞는 노드 없음"; continue; }
echo "$(ts) VIP 알리는 노드: $H / 컨트롤러: [$(ctl_nodes)] → $N 정지"
stop_node $N
;;
esac; done
echo; echo "== 마무리"; kubectl get nodes --no-headers | awk '{printf "%s=%s ",$1,$2}'; echo
echo "VIP 알리는 노드=$(holder) 컨트롤러=[$(ctl_nodes)] DB=$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.phase} {.status.readyInstances}/{.status.instances}')"
