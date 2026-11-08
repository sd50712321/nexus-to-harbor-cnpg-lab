#!/bin/bash
# 기동 검증 (읽기 + Harbor 에 테스트 이미지 1개 push/pull). 결과는 logs/verify-<시각>.txt
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
VIP=172.16.141.30; HB=172.16.141.210; HA="admin:$(cat secrets/harbor-admin)"
OUT=logs/verify-$(date +%m%d-%H%M).txt; mkdir -p logs
exec > >(tee "$OUT") 2>&1
ok=0; ng=0; chk(){ if eval "$2" >/dev/null 2>&1; then echo "  [OK] $1"; ok=$((ok+1)); else echo "  [NG] $1"; ng=$((ng+1)); fi; }

echo "== 1. 노드 / 컨트롤플레인"
kubectl get nodes -o wide
chk "노드 10대 Ready" '[ $(kubectl get nodes --no-headers | grep -cw Ready) = 10 ]'
chk "API VIP $VIP:6443 응답 (Mac 에서)" "curl -sk -m 5 https://$VIP:6443/livez | grep -q ok"
echo "  kubeconfig server: $(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
vagrant ssh ks-cp1 -c 'sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-ks-cp1.pem --key=/etc/ssl/etcd/ssl/admin-ks-cp1-key.pem endpoint status -w table' 2>/dev/null
chk "etcd 3 멤버 healthy" "vagrant ssh ks-cp1 -c 'sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-ks-cp1.pem --key=/etc/ssl/etcd/ssl/admin-ks-cp1-key.pem endpoint health' 2>/dev/null | grep -c 'is healthy' | grep -qx 3"
echo "  kube-vip 리더(VIP 보유 노드): $(for n in ks-cp1 ks-cp2 ks-cp3; do vagrant ssh $n -c "ip -4 a show eth1 | grep -q $VIP && hostname" 2>/dev/null; done | tr -d '\r')"

echo "== 2. Cilium"
chk "kube-proxy 없음" '[ $(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | wc -l) = 0 ]'
chk "cilium 에이전트 10/10 Ready" '[ "$(kubectl -n kube-system get ds cilium -o jsonpath={.status.numberReady})" = 10 ]'
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E 'KubeProxyReplacement|Cilium:|Host Routing|Masquerading'
kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy

echo "== 2-1. BGP (ToR ks-tor ↔ 워커)"
vagrant ssh ks-tor -c "sudo vtysh -c 'show bgp ipv4 unicast summary'" 2>/dev/null | sed -n '/Neighbor/,$p'
chk "ToR 에 BGP 세션 7개 Established" "[ \$(vagrant ssh ks-tor -c \"sudo vtysh -c 'show bgp ipv4 unicast summary json'\" 2>/dev/null | python3 -I -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for p in d[\"peers\"].values() if p[\"state\"]==\"Established\"))') = 7 ]"
vagrant ssh ks-tor -c "ip route show 10.250.0.10" 2>/dev/null | sed 's/^/    /'
chk "ToR 라우팅 테이블에 10.250.0.10 ECMP 경로(다음 홉 2개 이상)" "[ \$(vagrant ssh ks-tor -c 'ip route show 10.250.0.10' 2>/dev/null | grep -c nexthop) -ge 2 ]"
chk "ToR → http://10.250.0.10/api/v2.0/ping (BGP VIP)" "vagrant ssh ks-tor -c 'curl -s -m 5 http://10.250.0.10/api/v2.0/ping' 2>/dev/null | grep -q Pong"

echo "== 3. Longhorn"
kubectl -n longhorn-system get nodes.longhorn.io
chk "Longhorn 노드 7대 Ready·Schedulable" '[ $(kubectl -n longhorn-system get nodes.longhorn.io --no-headers | grep -c "True.*true.*True") = 7 ]'
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=VOL:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,REPLICAS:.spec.numberOfReplicas,NODE:.status.currentNodeID
echo "  복제본 배치(볼륨 → 노드):"
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState --no-headers | sort | awk '{a[$1]=a[$1]" "$2"("$3")"} END{for(k in a) print "   ",k":"a[k]}'
chk "모든 Longhorn 볼륨 healthy" '[ $(kubectl -n longhorn-system get volumes.longhorn.io --no-headers | grep -vc healthy) = 0 ]'

echo "== 4. CNPG"
kubectl -n harbor get cluster harbor-pg
kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o custom-columns=POD:.metadata.name,ROLE:.metadata.labels.cnpg\\.io/instanceRole,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready
chk "CNPG 3 인스턴스 healthy" 'kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.phase} | grep -q "healthy"'
chk "CNPG 인스턴스 3개가 서로 다른 노드" '[ $(kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o jsonpath="{range .items[*]}{.spec.nodeName}{\"\n\"}{end}" | sort -u | wc -l) = 3 ]'
kubectl -n harbor exec harbor-pg-1 -c postgres -- psql -tAc "select application_name, state, sync_state from pg_stat_replication" 2>/dev/null || \
  kubectl -n harbor exec $(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o name | head -1) -c postgres -- psql -tAc "select application_name, state, sync_state from pg_stat_replication"

echo "== 5. Harbor"
kubectl -n harbor get pods -o wide | grep -v harbor-pg
kubectl -n harbor get svc harbor
chk "Harbor LB IP = $HB" "[ \"\$(kubectl -n harbor get svc harbor -o jsonpath='{.status.loadBalancer.ingress[0].ip}')\" = $HB ]"
chk "Mac → http://$HB/api/v2.0/ping" "curl -s -m 5 http://$HB/api/v2.0/ping | grep -q Pong"
curl -s -m 5 -u "$HA" http://$HB/api/v2.0/health | python3 -I -c 'import sys,json;d=json.load(sys.stdin);print("  health:",d["status"],{c["name"]:c["status"] for c in d["components"]})'
curl -s -o /dev/null -u "$HA" -X POST http://$HB/api/v2.0/projects -H 'Content-Type: application/json' -d '{"project_name":"lab","public":false}'
TAG=v$(date +%H%M)
chk "skopeo push lab/alpine:$TAG" "skopeo copy -q --override-os linux --override-arch arm64 --dest-tls-verify=false --dest-creds '$HA' docker://docker.io/library/alpine:3.20 docker://$HB/lab/alpine:$TAG"
rm -rf /tmp/ks-pull; chk "skopeo pull 되돌려 받기" "skopeo copy -q --src-tls-verify=false --src-creds '$HA' docker://$HB/lab/alpine:$TAG dir:/tmp/ks-pull"
echo "$TAG" > logs/last-tag

echo; echo "결과: OK=$ok NG=$ng  (로그 $OUT)"
