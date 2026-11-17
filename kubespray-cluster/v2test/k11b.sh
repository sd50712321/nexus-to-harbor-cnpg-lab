#!/bin/bash
# K11b: 노드 강제 종료 → 시계가 SKEW 만큼 틀린 채 부팅(kubelet 보다 먼저 적용) → HOLD 초 방치 → 시계 복구 → 회복 관찰
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; SKEW=${2:-+9 hours}; HOLD=${3:-480}
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
echo "### K11b $(date +%H:%M:%S) $N 강제 종료 → 시계 '$SKEW' 로 부팅, ${HOLD}초 방치"
sshn "printf '[Unit]\nDescription=lab clock skew\nBefore=kubelet.service containerd.service\n[Service]\nType=oneshot\nExecStart=/bin/date -s \"$SKEW\"\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/lab-skew.service >/dev/null; sudo systemctl enable -q lab-skew; sudo systemctl disable -q --now systemd-timesyncd; sudo sync; sleep 2"
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"; /bin/sleep 45
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S) node-clock=$(sshn 'date -u +%m-%dT%H:%M:%S') real=$(date -u +%m-%dT%H:%M:%S) hp=$(sshn 'grep HugePages_Total /proc/meminfo' | awk '{print $2}')"
./v2test/allwatch.sh $N $HOLD
echo "--- 방치 끝 시점"; kubectl -n longhorn-system get events --sort-by=.lastTimestamp 2>/dev/null | grep -iE "$N|instance-manager" | grep -i warn | tail -3 | cut -c1-220
sshn 'sudo journalctl -u kubelet --since "-5 min" 2>/dev/null | grep -iE "x509|certificate|expired|not yet valid|clock|lease" | tail -3 | cut -c1-240'
echo "### $(date +%H:%M:%S) 시계 복구"
sshn 'sudo systemctl disable -q lab-skew; sudo rm -f /etc/systemd/system/lab-skew.service; sudo systemctl enable -q --now systemd-timesyncd; sleep 5; date -u +%m-%dT%H:%M:%S; timedatectl | grep synchronized'
./v2test/allwatch.sh $N 900 1
echo DONE
