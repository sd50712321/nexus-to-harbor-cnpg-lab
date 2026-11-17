#!/bin/bash
# K10 복합: 노드 강제 종료 → V2 를 못 쓰는 상태(hugepage 0)로 복귀 → HOLD 초 동안 손대지 않고 관찰 → hugepage 복구 + kubelet 재시작 → 회복 관찰
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; HOLD=${2:-2400}
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
snap(){
  vol=$(for v in $(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$2=="v2"{print $1}'); do
    echo -n "$(kubectl -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.status.kubernetesStatus.pvcName}:{.status.state}/{.status.robustness}' | sed -E 's/attached/att/; s/detached/det/; s/healthy/ok/; s/degraded/degr/')[$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=$v -o jsonpath='{range .items[*]}{.spec.nodeID}{.spec.failedAt},{end}' | sed -E 's/ks-//g; s/20[0-9-]+T[0-9:]+Z/!/g; s/,$//')] "; done)
  pod=$(kubectl -n v2test get pods --no-headers -o wide 2>/dev/null | awk '{printf "%s=%s(%s,r%s)@%s ",$1,$3,$2,$4,substr($7,4)}')
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}')
  echo "im=$im | $vol| $pod"; }
watch(){ S=$(date +%s); last=; while [ $(( $(date +%s)-S )) -lt $1 ]; do b=$(snap); [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }; [ -n "${2:-}" ] && echo "$b" | grep -qE "$2" && ! echo "$b" | grep -qE "Init|Pending|Creating|\(0/1|faulted|degr|unknown" && break; /bin/sleep 15; done; }
echo "### K10 $(date +%H:%M:%S) $N 강제 종료 → hugepage 0 으로 복귀, ${HOLD}초 방치"; snap
sshn 'sudo mv /etc/sysctl.d/90-longhorn-v2-hugepages.conf /root/hp.conf.off; sudo sync; sleep 2'
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"; /bin/sleep 60
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S) hp=$(sshn 'grep HugePages_Total /proc/meminfo' | awk '{print $2}')"
watch $HOLD
echo "### $(date +%H:%M:%S) hugepage 복구 + kubelet 재시작"
sshn 'sudo mv /root/hp.conf.off /etc/sysctl.d/90-longhorn-v2-hugepages.conf; sudo sysctl -q -p /etc/sysctl.d/90-longhorn-v2-hugepages.conf; sudo systemctl restart kubelet'
watch 1500 'im=running'
kubectl -n longhorn-system logs -l app=longhorn-manager --since=70m --tail=60000 2>/dev/null | grep -iE "failed too long ago" | cut -c7-26 | sort -u | head -6
echo DONE
