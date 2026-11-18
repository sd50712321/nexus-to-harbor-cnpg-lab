#!/bin/bash
# spdk_tgt 를 강제로 죽이고 노드 상태를 지켜본다.
#   t-spdk-kill.sh <case> <node> [suspend 할 PV]
# PV 를 주면 dmsetup suspend 직후에 죽인다 (Longhorn 이 장치를 멈춘 순간에 죽는 경우).
# 랩 전용. 그 노드의 V2 볼륨이 전부 끊겼다가 다시 붙는다.
C=$1; N=$2; PV=$3
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
L=v2test/results/t/$C.log; mkdir -p v2test/results/t
ssh_n(){ vagrant ssh $N -c "$1" 2>/dev/null; }
echo "$C: $N 에서 ${PV:+dmsetup suspend $PV 직후 }spdk_tgt 를 SIGABRT 로 죽임" > $L
echo "start(UTC) $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> $L
vagrant ssh $N -c "sudo bash -c 'cat > /root/snap.sh; chmod +x /root/snap.sh'" < v2test/t1-snap.sh 2>/dev/null
SUS=; [ -n "$PV" ] && SUS="echo \">>> dmsetup suspend\"; timeout 30 dmsetup suspend $PV; echo rc=\$?;"
ssh_n "sudo bash -c 'dmesg -C; /root/snap.sh; $SUS echo \">>> kill -ABRT\"; kill -ABRT \$(pgrep -f ^spdk_tgt | head -1); for i in 5 15 30 30 60 60 60 60; do sleep \$i; /root/snap.sh; done; echo \"-- dmesg\"; dmesg | grep -v \"Reconnecting in\|failed to connect socket\" | tail -40'" >> $L
{ echo "-- k8s"
  kubectl -n v2test get pods -o wide --no-headers | awk '{print $1,$2,$3,$4,$7}'
  kubectl -n longhorn-system get volumes.longhorn.io --no-headers | awk '$2=="v2"{print $1,$3,$4}'
  kubectl -n longhorn-system get pods -o wide --no-headers | grep instance-manager | awk '{print $1,$2,$3,$4,$5,$7}'
  echo "-- events"; kubectl get events -A --sort-by=.lastTimestamp | tail -25 | cut -c1-300; } >> $L
echo "기록: $L"
