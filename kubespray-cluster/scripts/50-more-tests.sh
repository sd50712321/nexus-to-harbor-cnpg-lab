#!/bin/bash
# 추가 시험 3종 (이 랩 VM 만 정지/기동). 결과 logs/more-tests-<시각>.txt
#   F. BGP VIP 로 push/pull (ToR 에서, 인증 토큰 주소까지 BGP 경로인지 확인)
#   D. Longhorn 복제본 1벌을 가진 워커 정지 → 볼륨 degraded 중 push → 다른 노드에 복제본 재구성 → 노드 복귀 후 정리
#   E. CNPG primary 를 DB 만 있는 워커로 옮긴 뒤 그 워커를 강제 정지 → 승격 → 장애 전환 뒤 쓰기(프로젝트 생성·새 이미지 push) → 복귀·재동기
#   ./scripts/50-more-tests.sh [F] [D] [E]   (인자 없으면 전부)
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
HB=172.16.141.210; BGP=10.250.0.10; HA="admin:$(cat secrets/harbor-admin)"; TAG=$(cat logs/last-tag)
SRC_IMG=${SRC_IMG:-docker://docker.io/library/busybox:1.37}    # 새 레이어를 쓰기 위한 외부 이미지(Mac 에서 받음)
TESTS=${*:-F D E}
OUT=logs/more-tests-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
push_new(){ skopeo copy -q --override-os linux --override-arch arm64 --dest-tls-verify=false --dest-creds "$HA" "$SRC_IMG" "docker://$HB/$1" >/dev/null 2>&1; }
pull_back(){ rm -rf /tmp/ks-more; skopeo copy -q --src-tls-verify=false --src-creds "$HA" "docker://$HB/$1" dir:/tmp/ks-more >/dev/null 2>&1; }
pod_nodes(){ kubectl -n harbor get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}'; }   # 재시작 표기로 열이 밀리지 않게 jsonpath
harbor_nodes(){ pod_nodes | grep -v '^harbor-pg' | awk '{print $2}' | sort -u; }
pg_nodes(){ pod_nodes | grep '^harbor-pg' | awk '{print $2}' | sort -u; }
pgc(){ kubectl -n harbor get cluster.postgresql.cnpg.io harbor-pg -o jsonpath="$1"; }
V=$(kubectl -n harbor get pvc harbor-registry -o jsonpath='{.spec.volumeName}')
replicas(){ kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$V')]}{.spec.nodeID}({.status.currentState}) {end}"; }

for T in $TESTS; do case $T in
F)
echo "== F. BGP VIP($BGP) 로 push/pull (ToR 에서)"
vagrant ssh ks-tor -c 'command -v skopeo >/dev/null || sudo env http_proxy=http://172.16.141.1:3128 https_proxy=http://172.16.141.1:3128 DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::http::Proxy=http://172.16.141.1:3128 install -y -q skopeo >/dev/null 2>&1' 2>/dev/null
cat secrets/harbor-admin | vagrant ssh ks-tor -c "read -r P; C=\"admin:\$P\"; B=$BGP; N=bgp-\$(date +%H%M%S); rm -rf /tmp/bgp1 /tmp/bgp2
echo \"   경로: \$(ip route show \$B | grep -c nexthop) 개 다음 홉(ECMP)\"
echo \"   토큰 주소: \$(curl -s -o /dev/null -D - http://\$B/v2/ | grep -io 'realm=\"[^\"]*\"')\"
skopeo copy -q --src-tls-verify=false --src-creds \"\$C\" docker://\$B/lab/alpine:$TAG dir:/tmp/bgp1 && echo '   [OK] pull' || echo '   [NG] pull'
skopeo copy -q --dest-tls-verify=false --dest-creds \"\$C\" dir:/tmp/bgp1 docker://\$B/lab/alpine:\$N && echo \"   [OK] push lab/alpine:\$N\" || echo '   [NG] push'
skopeo copy -q --src-tls-verify=false --src-creds \"\$C\" docker://\$B/lab/alpine:\$N dir:/tmp/bgp2 && cmp -s /tmp/bgp1/manifest.json /tmp/bgp2/manifest.json && echo '   [OK] 되받은 manifest 동일' || echo '   [NG] 되받기/비교 실패'" 2>/dev/null | tr -d '\r'
;;
D)
echo; echo "== D. Longhorn 복제본 재구성 (볼륨 $V = harbor-registry)"
CUR=$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.currentNodeID}')
N=""; for r in $(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$V')]}{.spec.nodeID}{' '}{end}"); do
  [ "$r" != "$CUR" ] && ! harbor_nodes | grep -qx "$r" && ! pg_nodes | grep -qx "$r" && { N=$r; break; }; done
[ -z "$N" ] && { echo "   [SKIP] Harbor 파드가 없는 복제본 노드가 없음"; continue; }
echo "$(ts) 복제본: $(replicas)  / 볼륨 부착 노드 $CUR → $N 정지"
vagrant halt $N --force >/dev/null 2>&1; S=$(date +%s)
t=$(wait_until 180 "kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.robustness} | grep -qx degraded") && echo "$(ts) 볼륨 degraded (${t}s)"
NEW=lab/busybox:degraded-$(date +%H%M%S)
push_new $NEW && echo "$(ts) [OK] degraded 상태에서 새 이미지 push ($NEW)" || echo "$(ts) [NG] degraded 중 push 실패"
t=$(wait_until 900 "kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.robustness} | grep -qx healthy") \
  && echo "$(ts) 볼륨 healthy 복귀: 정지 후 $(( $(date +%s)-S ))s, 복제본: $(replicas)" || echo "$(ts) [NG] 900s 안에 재구성 안 됨: $(replicas)"
pull_back $NEW && echo "$(ts) [OK] 재구성 후 그 이미지 pull" || echo "$(ts) [NG] pull 실패"
echo "$(ts) $N 기동"; B=$(date +%s); vagrant up $N >/dev/null 2>&1
wait_until 300 "node_back $N $B" >/dev/null && echo "$(ts) $N kubelet 복귀"
wait_until 180 "! kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath=\"{range .items[?(@.spec.volumeName=='$V')]}{.status.currentState}{' '}{end}\" | grep -qv running" >/dev/null
echo "$(ts) 노드 복귀 후 복제본: $(replicas)"
;;
E)
echo; echo "== E. CNPG primary 노드 강제 정지 + 장애 전환 뒤 쓰기"
X=""; for p in $(kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
  n=$(kubectl -n harbor get pod $p -o jsonpath='{.spec.nodeName}'); harbor_nodes | grep -qx $n || { X=$p; XN=$n; break; }; done
[ -z "$X" ] && { echo "   [SKIP] Harbor 다른 파드와 겹치지 않는 DB 노드가 없음"; continue; }
if [ "$(pgc '{.status.currentPrimary}')" != "$X" ]; then
  echo "$(ts) switchover → $X ($XN)  (kubectl cnpg promote 와 같은 status 패치)"
  kubectl -n harbor patch cluster.postgresql.cnpg.io harbor-pg --subresource=status --type=merge \
    -p "{\"status\":{\"targetPrimary\":\"$X\",\"targetPrimaryTimestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"phase\":\"Switchover in progress\",\"phaseReason\":\"test switchover to $X\"}}" >/dev/null
  t=$(wait_until 180 "[ \"\$(pgc '{.status.currentPrimary}')\" = $X ] && [ \"\$(pgc '{.status.readyInstances}')\" = 3 ]") && echo "$(ts) switchover 완료 ${t}s" || echo "$(ts) [NG] switchover 안 됨"
fi
echo "$(ts) primary $X @ $XN → $XN 강제 정지"
vagrant halt $XN --force >/dev/null 2>&1; S=$(date +%s)
t=$(wait_until 300 "pgc '{.status.currentPrimary}' | grep -vqx $X") && echo "$(ts) 새 primary $(pgc '{.status.currentPrimary}'): 정지 후 $(( $(date +%s)-S ))s" || echo "$(ts) [NG] 300s 안에 승격 안 됨"
P=fo$(date +%H%M%S)
t=$(wait_until 120 "curl -s -o /dev/null -w '%{http_code}' -u '$HA' -H 'Content-Type: application/json' -X POST http://$HB/api/v2.0/projects -d '{\"project_name\":\"$P\",\"public\":false}' | grep -qE '201|409'") \
  && echo "$(ts) [OK] 프로젝트 생성(DB 쓰기) $P: 정지 후 $(( $(date +%s)-S ))s" || echo "$(ts) [NG] 프로젝트 생성 실패"
push_new $P/busybox:after-failover && echo "$(ts) [OK] 새 프로젝트에 이미지 push" || echo "$(ts) [NG] push 실패"
pull_back $P/busybox:after-failover && echo "$(ts) [OK] 되받기" || echo "$(ts) [NG] 되받기 실패"
echo "$(ts) $XN 기동"; B=$(date +%s); vagrant up $XN >/dev/null 2>&1
wait_until 300 "node_back $XN $B" >/dev/null && echo "$(ts) $XN kubelet 복귀"
t=$(wait_until 600 "kubectl -n harbor get pod $X -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True") && echo "$(ts) $X 파드 Ready (기동 후 $(( $(date +%s)-B ))s)"
NP=$(pgc '{.status.currentPrimary}')
wait_until 300 "[ \$(kubectl -n harbor exec $NP -c postgres -- psql -tAc \"select count(*) from pg_stat_replication where state='streaming'\") = 2 ]" >/dev/null
echo "$(ts) primary $NP 의 복제 상태:"; kubectl -n harbor exec $NP -c postgres -- psql -tAc "select application_name,state,sync_state from pg_stat_replication" | sed 's/^/    /'
kubectl -n harbor exec $NP -c postgres -- psql -d registry -tAc "select count(*) from project where name='$P'" | sed "s/^/    프로젝트 $P 행 수(primary): /"
R=$(kubectl -n harbor get pods -l cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
kubectl -n harbor exec $R -c postgres -- psql -d registry -tAc "select count(*) from project where name='$P'" | sed "s/^/    같은 행 수(replica $R): /"
;;
esac; done
echo; echo "== 마무리 상태"
kubectl get nodes --no-headers | awk '{printf "%s=%s ",$1,$2}'; echo
echo "CNPG: $(pgc '{.status.phase}') primary=$(pgc '{.status.currentPrimary}') ready=$(pgc '{.status.readyInstances}')"
echo "registry 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.robustness}')  $(replicas)"
