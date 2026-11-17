#!/bin/bash
# 한 노드의 V2 준비 상태를 바뀔 때만 출력 (손대지 않고 저절로 풀리는지 보는 용). 인자: 노드, 최대 초, [끝 조건]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; MAX=${2:-3600}; END=${3:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  hpn=$(kubectl get node $N -o jsonpath='{.status.allocatable.hugepages-2Mi}'); os=$(ssh -F inventory/lab/ssh.cfg $N 'echo "hp=$(grep HugePages_Total /proc/meminfo | tr -s " " | cut -d" " -f2) mod=$(lsmod | grep -cE "^(nvme_tcp|vfio_pci|uio_pci_generic) ")/3"' 2>/dev/null)
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}')
  impods=$(kubectl -n longhorn-system get pods -o wide --no-headers | grep instance-manager | awk -v n=$N '$7==n{c++} END{print c+0}')
  dk=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o jsonpath='{.status.diskStatus.v2-disk.conditions[?(@.type=="Ready")].status}')
  pods=$(kubectl -n v2test get pods -o wide --no-headers | awk -v n=$N '$7==n{printf "%s=%s(%s,r%s) ",$1,$3,$2,$4}')
  b="node-hp=$hpn os:$os im-v2=$im im-pods=$impods v2disk=$dk | $pods"
  [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && break
  /bin/sleep 15
done; echo DONE
