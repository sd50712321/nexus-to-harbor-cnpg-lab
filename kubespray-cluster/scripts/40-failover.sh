#!/bin/bash
# 장애 시험 3종 (이 랩의 VM 만 정지/기동). 각 시험 후 원복까지 한다. 결과 logs/failover-<시각>.txt
#   A. API VIP 를 쥔 control plane 정지 → VIP 이동, etcd 쿼럼(2/3) 유지, API 계속 응답
#   B. CNPG primary 파드 삭제 → standby 승격, Harbor 계속 동작
#   C. Harbor registry 파드가 있는 워커 정지 → Longhorn 볼륨이 다른 노드에 재부착, 기존 이미지 pull 성공
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
VIP=172.16.141.30; HB=172.16.141.210; HA="admin:$(cat secrets/harbor-admin)"; TAG=$(cat logs/last-tag)
OUT=logs/failover-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
pull_ok(){ rm -rf /tmp/ks-fo; skopeo copy -q --src-tls-verify=false --src-creds "$HA" docker://$HB/lab/alpine:$TAG dir:/tmp/ks-fo >/dev/null 2>&1; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
# 재기동 판정: Ready 표시만 보면 짧게 꺼졌던 노드는 NotReady 로 바뀌기 전 값이 남아 0s 로 찍힌다.
# 그래서 kubelet 이 기동 시각 이후에 노드 lease 를 갱신했는지(실제로 살아 돌아왔는지)를 함께 본다.
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
harbor_healthy(){ curl -s -m 3 http://$HB/api/v2.0/health | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin)["status"]=="healthy" else 1)'; }
vip_holder(){ for n in ks-cp1 ks-cp2 ks-cp3; do vagrant ssh $n -c "ip -4 a show eth1 | grep -q $VIP && hostname" 2>/dev/null; done | tr -d '\r' | head -1; }

echo "== A. API VIP 보유 control plane 정지"
H=$(vip_holder); echo "$(ts) VIP 보유: $H → 정지"
vagrant halt $H --force >/dev/null 2>&1
t=$(wait_until 120 "curl -sk -m 3 https://$VIP:6443/livez | grep -q ok") && echo "$(ts) VIP 로 API 다시 응답: ${t}s 후, 새 보유: $(vip_holder)" || echo "$(ts) [NG] 120s 안에 API 복구 안 됨"
kubectl get nodes --no-headers | awk '{print "   ",$1,$2}'
O=$(for n in ks-cp1 ks-cp2 ks-cp3; do [ $n != $H ] && echo $n; done | head -1)
vagrant ssh $O -c "sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-$O.pem --key=/etc/ssl/etcd/ssl/admin-$O-key.pem endpoint health 2>&1 | sed 's/^/    /'" 2>/dev/null
# CP 가 죽은 직후엔 apiserver 의 etcd 연결이 죽은 멤버에 붙어 있다가 넘어가는 동안 쓰기가 Unavailable 로 실패할 수 있다 → 재시도하며 첫 성공 시각을 잰다
write_cm(){ kubectl create configmap fo-write-test --from-literal=t="$(date +%s%N)" -n default --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; }
F0=0; write_cm || F0=1
t=$(wait_until 90 write_cm) && echo "$(ts) 쿼럼 2/3 상태에서 쓰기 OK (첫 시도 $([ $F0 = 0 ] && echo 성공 || echo "실패, ${t}s 재시도 후 성공"))" || echo "$(ts) [NG] 90s 동안 쓰기 실패"
pull_ok && echo "$(ts) Harbor pull OK (CP 1대 다운 중)" || echo "$(ts) [NG] Harbor pull 실패"
echo "$(ts) $H 기동"; B=$(date +%s); vagrant up $H >/dev/null 2>&1
t=$(wait_until 300 "node_back $H $B") && echo "$(ts) $H kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $H 300s 안에 복귀 안 됨"

echo; echo "== B. CNPG primary 삭제"
P=$(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); PN=$(kubectl -n harbor get pod $P -o jsonpath='{.spec.nodeName}')
echo "$(ts) primary: $P ($PN) → 삭제"
kubectl -n harbor delete pod $P --wait=false >/dev/null
t=$(wait_until 180 "kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.currentPrimary} | grep -vqx $P") && echo "$(ts) 새 primary: $(kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.currentPrimary}) (${t}s)"
t=$(wait_until 180 "curl -s -m 3 -u '$HA' http://$HB/api/v2.0/projects | grep -q lab") && echo "$(ts) Harbor API(DB 조회) 복구 ${t}s"
pull_ok && echo "$(ts) Harbor pull OK" || echo "$(ts) [NG] pull 실패"
# Cluster.status.readyInstances 는 수 분 늦게 갱신될 수 있다(TROUBLESHOOTING 9절) → 지운 인스턴스의 파드 Ready 와 실제 복제 연결 수로 판정
t=$(wait_until 300 "kubectl -n harbor get pod $P -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True") && echo "$(ts) $P 재기동 Ready ${t}s"
NP=$(kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.currentPrimary})
t=$(wait_until 300 "[ \$(kubectl -n harbor exec $NP -c postgres -- psql -tAc \"select count(*) from pg_stat_replication where state='streaming'\") = 2 ]") && echo "$(ts) 새 primary $NP 에 복제 2개 streaming ${t}s"

echo; echo "== C. Harbor registry 파드가 있는 워커 정지 (Longhorn 재부착)"
RP=$(kubectl -n harbor get pods -l component=registry -o jsonpath='{.items[0].metadata.name}'); W=$(kubectl -n harbor get pod $RP -o jsonpath='{.spec.nodeName}')
V=$(kubectl -n harbor get pvc harbor-registry -o jsonpath='{.spec.volumeName}')
echo "$(ts) registry 파드 $RP @ $W, 볼륨 $V 복제본: $(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$V')]}{.spec.nodeID} {end}")"
echo "    같은 노드의 다른 Harbor 파드: $(kubectl -n harbor get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk -v w=$W '$2==w{print $1}' | grep -v "$RP" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//' | tr '\n' ' ')"
echo "$(ts) $W 정지"; vagrant halt $W --force >/dev/null 2>&1; S=$(date +%s)
t=$(wait_until 600 "kubectl -n harbor get pods -l component=registry -o wide --no-headers | grep -v $W | grep -q '2/2.*Running'") && \
  echo "$(ts) registry 파드 다른 노드에서 Running: ${t}s 후 → $(kubectl -n harbor get pods -l component=registry -o wide --no-headers | grep Running | awk '{print $1"@"$7}')" || echo "$(ts) [NG] 600s 안에 재기동 안 됨"
echo "    볼륨 상태: $(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.state}/{.status.robustness} node={.status.currentNodeID}')"
# 같은 노드에 core·redis 등이 함께 있었다면 registry 가 떠도 Harbor 는 아직 안 된다 → Harbor health 를 먼저 기다린다
t=$(wait_until 900 harbor_healthy) && echo "$(ts) Harbor 전체 healthy: 정지 후 $(( $(date +%s)-S ))s" || echo "$(ts) [NG] 900s 안에 Harbor healthy 안 됨"
t=$(wait_until 120 pull_ok) && echo "$(ts) 기존 이미지 pull OK (${t}s)" || echo "$(ts) [NG] pull 실패"
echo "$(ts) $W 기동"; B=$(date +%s); vagrant up $W >/dev/null 2>&1
wait_until 300 "node_back $W $B" >/dev/null && echo "$(ts) $W kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $W 복귀 안 됨"
t=$(wait_until 900 "kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.robustness} | grep -qx healthy") && echo "$(ts) 볼륨 복제본 3벌 재구성(healthy) ${t}s"
kubectl get nodes --no-headers | awk '{print "   ",$1,$2}'
