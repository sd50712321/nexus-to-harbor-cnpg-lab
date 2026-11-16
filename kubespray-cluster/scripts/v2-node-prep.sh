#!/bin/bash
# Longhorn V2 를 쓸 노드 준비 (Longhorn 1.13 문서 "V2 Data Engine Requirements"): 커널 모듈 3개 + hugepage 2GiB + kubelet 재시작
#   ./scripts/v2-node-prep.sh ks-w1 ks-w2 ks-w3
set -uo pipefail
cd "$(dirname "$0")/.."
for n in "$@"; do
  echo "== $n"
  ssh -F inventory/lab/ssh.cfg $n 'sudo bash -s' <<'REMOTE'
set -e
export DEBIAN_FRONTEND=noninteractive
dpkg -s linux-modules-extra-$(uname -r) >/dev/null 2>&1 || apt-get install -y -q linux-modules-extra-$(uname -r) >/dev/null
printf 'vfio_pci\nuio_pci_generic\nnvme_tcp\n' > /etc/modules-load.d/longhorn-v2.conf
for m in vfio_pci uio_pci_generic nvme_tcp; do modprobe $m; done
echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/90-longhorn-v2-hugepages.conf
sysctl -q -p /etc/sysctl.d/90-longhorn-v2-hugepages.conf
systemctl restart kubelet
echo "modules: $(lsmod | grep -cE '^(vfio_pci|uio_pci_generic|nvme_tcp) ')/3  hugepages: $(grep HugePages_Total /proc/meminfo | awk '{print $2}')"
REMOTE
done
