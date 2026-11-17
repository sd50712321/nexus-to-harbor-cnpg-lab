#!/bin/bash
# K7: 재부팅 뒤 hugepage 가 없는 채로 kubelet 이 뜬다 → 5분 관찰 → hugepage 만 잡는다 → 5분 관찰 → kubelet 재시작 → 회복까지
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
im(){ kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}'; }
snap(){ echo "  $(date +%H:%M:%S) hp(node)=$(kubectl get node $N -o jsonpath='{.status.allocatable.hugepages-2Mi}') hp(os)=$(sshn 'grep HugePages_Total /proc/meminfo' | awk '{print $2}') im-v2=$(im) impod=$(kubectl -n longhorn-system get pods -o wide --no-headers | grep instance-manager | awk -v n=$N '$7==n{printf "%s(%s) ",$3,$5}') | pods@$N: $(kubectl -n v2test get pods -o wide --no-headers | awk -v n=$N '$7==n{printf "%s=%s(%s) ",$1,$3,$2}')"; }
watch(){ S=$(date +%s); last=; while [ $(( $(date +%s)-S )) -lt $1 ]; do o=$(snap); b=${o#*hp(}; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s$o"; last=$b; }; [ -n "${2:-}" ] && echo "$o" | grep -qE "$2" && break; /bin/sleep 10; done; }
echo "### K7 $(date +%H:%M:%S) $N: hugepage 설정 파일을 치우고 재부팅"
sshn 'sudo mv /etc/sysctl.d/90-longhorn-v2-hugepages.conf /root/hp.conf.off'
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N >/dev/null 2>&1; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
watch 300
echo "### $(date +%H:%M:%S) hugepage 만 잡는다 (kubelet 은 그대로)"; sshn 'sudo sysctl -q -w vm.nr_hugepages=1024'
watch 300 'im-v2=running'
if [ "$(im)" != running ]; then echo "### $(date +%H:%M:%S) kubelet 재시작"; sshn 'sudo systemctl restart kubelet'; watch 420 'im-v2=running'; fi
sshn 'sudo mv /root/hp.conf.off /etc/sysctl.d/90-longhorn-v2-hugepages.conf'
kubectl -n longhorn-system get events --sort-by=.lastTimestamp | grep -i instance-manager | grep -iE "fail|insufficient|hugepage|Unschedul" | tail -3 | cut -c1-230
echo DONE
