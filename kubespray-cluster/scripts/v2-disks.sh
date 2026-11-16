#!/bin/bash
# (랩) Longhorn V2 시험용 빈 디스크 만들기: v2disks/<노드>-dummy.vmdk(1GB), <노드>-data.vmdk(10GB). 이미 있으면 건너뛴다.
#   ./scripts/v2-disks.sh ks-w1 ks-w2 ks-w3
set -euo pipefail
cd "$(dirname "$0")/.."; mkdir -p v2disks
VDM="/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager"
for n in "$@"; do
  [ -f v2disks/$n-dummy.vmdk ] || "$VDM" -c -s 1GB  -a lsilogic -t 0 v2disks/$n-dummy.vmdk
  [ -f v2disks/$n-data.vmdk ]  || "$VDM" -c -s 10GB -a lsilogic -t 0 v2disks/$n-data.vmdk
done
ls -lh v2disks
