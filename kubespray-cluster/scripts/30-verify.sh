#!/bin/bash
# 기동 검증 (읽기 + Harbor 에 테스트 이미지 1개 push/pull). 결과는 logs/verify-<시각>.txt
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
VIP=172.16.141.30; . scripts/harbor-env.sh      # HV(ingress VIP) HH(Harbor 호스트명) HB HU HA hcurl
OUT=logs/verify-$(date +%m%d-%H%M).txt; mkdir -p logs
exec > >(tee "$OUT") 2>&1
# 기대 대수는 인벤토리에서 읽는다 (워커 수를 바꿔도 스크립트를 안 고치게). 클러스터에서 세면 "있는 만큼 있다" 가 되어 검증이 아니다
cnt(){ awk -v g="[$1]" '$0==g{f=1;next} /^\[/{f=0} f&&NF&&$0!~/^#/{c++} END{print c+0}' ${INVENTORY:-inventory/lab}/inventory.ini; }
NCP=$(cnt kube_control_plane); NW=$(cnt kube_node); NALL=$((NCP+NW))
ok=0; ng=0; chk(){ if eval "$2" >/dev/null 2>&1; then echo "  [OK] $1"; ok=$((ok+1)); else echo "  [NG] $1"; ng=$((ng+1)); fi; }

echo "== 1. 노드 / 컨트롤플레인"
kubectl get nodes -o wide
chk "노드 ${NALL}대 Ready (CP $NCP + 워커 $NW)" "[ \$(kubectl get nodes --no-headers | grep -cw Ready) = $NALL ]"
chk "API VIP $VIP:6443 응답 (Mac 에서)" "curl -sk -m 5 https://$VIP:6443/livez | grep -q ok"
echo "  kubeconfig server: $(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
vagrant ssh ks-cp1 -c 'sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-ks-cp1.pem --key=/etc/ssl/etcd/ssl/admin-ks-cp1-key.pem endpoint status -w table' 2>/dev/null
chk "etcd 3 멤버 healthy" "vagrant ssh ks-cp1 -c 'sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-ks-cp1.pem --key=/etc/ssl/etcd/ssl/admin-ks-cp1-key.pem endpoint health' 2>/dev/null | grep -c 'is healthy' | grep -qx 3"
echo "  kube-vip 리더(VIP 보유 노드): $(for n in ks-cp1 ks-cp2 ks-cp3; do vagrant ssh $n -c "ip -4 a show eth1 | grep -q $VIP && hostname" 2>/dev/null; done | tr -d '\r')"

echo "== 2. Cilium"
chk "kube-proxy 없음" '[ $(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | wc -l) = 0 ]'
chk "cilium 에이전트 $NALL/$NALL Ready" "[ \"\$(kubectl -n kube-system get ds cilium -o jsonpath={.status.numberReady})\" = $NALL ]"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E 'KubeProxyReplacement|Cilium:|Host Routing|Masquerading'
kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy

echo "== 2-1. BGP (ToR ks-tor ↔ 워커)"
vagrant ssh ks-tor -c "sudo vtysh -c 'show bgp ipv4 unicast summary'" 2>/dev/null | sed -n '/Neighbor/,$p'
chk "ToR 에 BGP 세션 ${NW}개 Established" "[ \$(vagrant ssh ks-tor -c \"sudo vtysh -c 'show bgp ipv4 unicast summary json'\" 2>/dev/null | python3 -I -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for p in d[\"peers\"].values() if p[\"state\"]==\"Established\"))') = $NW ]"
vagrant ssh ks-tor -c "ip route show 10.250.0.10" 2>/dev/null | sed 's/^/    /'
chk "ToR 라우팅 테이블에 10.250.0.10 ECMP 경로(다음 홉 2개 이상)" "[ \$(vagrant ssh ks-tor -c 'ip route show 10.250.0.10' 2>/dev/null | grep -c nexthop) -ge 2 ]"
chk "ToR → BGP VIP 10.250.0.10 → ingress-nginx → Harbor ping" "vagrant ssh ks-tor -c 'curl -sk -m 5 --resolve $HH:443:10.250.0.10 $HU/api/v2.0/ping' 2>/dev/null | grep -q Pong"

echo "== 3. Longhorn"
kubectl -n longhorn-system get nodes.longhorn.io
chk "Longhorn 노드 ${NW}대 Ready·Schedulable" "[ \$(kubectl -n longhorn-system get nodes.longhorn.io --no-headers | grep -c 'True.*true.*True') = $NW ]"
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=VOL:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,REPLICAS:.spec.numberOfReplicas,NODE:.status.currentNodeID
echo "  복제본 배치(볼륨 → 노드):"
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState --no-headers | sort | awk '{a[$1]=a[$1]" "$2"("$3")"} END{for(k in a) print "   ",k":"a[k]}'
chk "붙어 있는 Longhorn 볼륨 모두 healthy" '[ $(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath="{range .items[?(@.status.state==\"attached\")]}{.status.robustness}{\"\\n\"}{end}" | grep -vc healthy) = 0 ]'
# 떼어진 볼륨 = DB 인스턴스를 다시 만들 때 남은 옛 볼륨(PV reclaim=Retain → Released). 서비스에는 안 쓰이지만 디스크를 차지하고, 그 노드의 drain 을 막는다(TROUBLESHOOTING 20절)
echo "  떼어진(옛) 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[?(@.status.state=="detached")]}{.metadata.name}{" "}{end}' | wc -w | tr -d ' ')개"

echo "== 4. CNPG"
kubectl -n harbor get cluster harbor-pg
kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o custom-columns=POD:.metadata.name,ROLE:.metadata.labels.cnpg\\.io/instanceRole,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready
chk "CNPG 3 인스턴스 healthy" 'kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.phase} | grep -q "healthy"'
chk "CNPG 인스턴스 3개가 서로 다른 노드" '[ $(kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o jsonpath="{range .items[*]}{.spec.nodeName}{\"\n\"}{end}" | sort -u | wc -l) = 3 ]'
kubectl -n harbor exec harbor-pg-1 -c postgres -- psql -tAc "select application_name, state, sync_state from pg_stat_replication" 2>/dev/null || \
  kubectl -n harbor exec $(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o name | head -1) -c postgres -- psql -tAc "select application_name, state, sync_state from pg_stat_replication"

echo "== 5. Harbor"
kubectl -n harbor get pods -o wide | grep -v harbor-pg
kubectl -n ingress-nginx get pods -o wide --no-headers | awk '{print "    "$1,$2,$3,$7}'
kubectl -n ingress-nginx get svc ingress-nginx-controller; kubectl -n harbor get ingress
echo "  VIP $HV 를 ARP 로 알리는 노드: $(kubectl -n kube-system get lease cilium-l2announce-ingress-nginx-ingress-nginx-controller -o jsonpath='{.spec.holderIdentity}')"
chk "ingress-nginx VIP = $HV, Harbor Ingress 호스트 = $HH" "[ \"\$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')\" = $HV ] && [ \"\$(kubectl -n harbor get ingress harbor-ingress -o jsonpath='{.spec.rules[0].host}')\" = $HH ]"
chk "Mac → $HU/api/v2.0/ping (VIP $HV)" "hcurl -m 5 $HU/api/v2.0/ping | grep -q Pong"
hcurl -m 5 -u "$HA" $HU/api/v2.0/health | python3 -I -c 'import sys,json;d=json.load(sys.stdin);print("  health:",d["status"],{c["name"]:c["status"] for c in d["components"]})'
hcurl -o /dev/null -u "$HA" -X POST $HU/api/v2.0/projects -H 'Content-Type: application/json' -d '{"project_name":"lab","public":false}'
TAG=v$(date +%H%M)
chk "skopeo push lab/alpine:$TAG" "skopeo copy -q --override-os linux --override-arch arm64 --dest-tls-verify=false --dest-creds '$HA' docker://docker.io/library/alpine:3.20 docker://$HB/lab/alpine:$TAG"
rm -rf /tmp/ks-pull; chk "skopeo pull 되돌려 받기" "skopeo copy -q --src-tls-verify=false --src-creds '$HA' docker://$HB/lab/alpine:$TAG dir:/tmp/ks-pull"
echo "$TAG" > logs/last-tag

echo; echo "결과: OK=$ok NG=$ng  (로그 $OUT)"
