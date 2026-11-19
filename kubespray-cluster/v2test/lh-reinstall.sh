#!/bin/bash
# 랩 Longhorn 을 지우고 <버전> 으로 새로 깐다(내려가는 방향은 helm upgrade 가 안 되므로). 시험 볼륨은 전부 사라진다.
#   lh-reinstall.sh <버전, 예 1.12.1>
#   순서: 워크로드·PVC 삭제 → deleting-confirmation-flag → helm uninstall → CRD 삭제 → V2 디스크 앞 200MB 0 채움
#         → helm install → 설정 3개 → 노드에 v2-disk·태그 → pg-prod, u4 다시 생성
V=$1; [ -z "$V" ] && { echo "usage: $0 <version>"; exit 1; }
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1
NS=longhorn-system; W="ks-w1 ks-w2 ks-w3"; cp1(){ vagrant ssh ks-cp1 -c "sudo bash -c '$1'" 2>/dev/null | tr -d '\r'; }
# 맥의 bash 3.2 에는 연관 배열이 없다. 노드별 변수(DISK_ks_w1 …)로 둔다.
disk(){ eval echo "\$DISK_${1//-/_}"; }
for n in $W; do p=$(kubectl -n $NS get nodes.longhorn.io $n -o jsonpath='{.spec.disks.v2-disk.path}'); eval "DISK_${n//-/_}=$p"; echo "$n v2-disk=$(disk $n)"; done
for n in $W; do case "$(disk $n)" in /dev/disk/by-id/*) ;; *) echo "v2-disk 경로를 못 읽음: $n"; exit 1;; esac; done
echo ">>> 워크로드와 PVC 삭제"; kubectl uncordon $W >/dev/null
kubectl -n v2test delete cluster --all --wait=true >/dev/null 2>&1; kubectl -n v2test delete deploy u4 --wait=true >/dev/null 2>&1; kubectl -n v2test delete pvc --all --wait=false >/dev/null 2>&1
for i in $(seq 1 30); do c=$(kubectl -n $NS get volumes.longhorn.io --no-headers 2>/dev/null | wc -l | tr -d ' '); [ "$c" = 0 ] && break; /bin/sleep 10; done; echo "   남은 볼륨 $c"
kubectl -n $NS delete volumes.longhorn.io --all --wait=true >/dev/null 2>&1
echo ">>> helm uninstall"; kubectl -n $NS patch settings.longhorn.io deleting-confirmation-flag --type merge -p '{"value":"true"}' >/dev/null
cp1 "helm uninstall longhorn -n $NS --wait --timeout 10m 2>&1 | tail -1"
kubectl get crd -o name | grep longhorn.io | xargs kubectl delete --wait=true >/dev/null 2>&1
for i in $(seq 1 30); do c=$(kubectl -n $NS get pods --no-headers 2>/dev/null | wc -l | tr -d ' '); [ "$c" = 0 ] && break; /bin/sleep 6; done; echo "   남은 파드 $c"
echo ">>> V2 디스크 앞 200MB 0 채움"; for n in $W; do vagrant ssh $n -c "sudo bash -c 'dmsetup ls | grep -c pvc-; [ -b $(disk $n) ] || { echo 블록 장치가 아님; exit 1; }; dd if=/dev/zero of=$(disk $n) bs=1M count=200 oflag=direct 2>&1 | tail -1'" 2>/dev/null | tr -d '\r' | sed "s/^/   $n /"; done
echo ">>> helm install $V"; cp1 "helm repo update longhorn >/dev/null 2>&1; helm install longhorn longhorn/longhorn -n $NS --version $V -f /root/lh-values.yaml --wait --timeout 15m 2>&1 | grep -E \"STATUS|Error\""
for s in 'v2-data-engine true' 'data-engine-cpu-mask {"v2":"0x1"}' 'data-engine-cpu-isolation-enabled {"v2":"true"}'; do k=${s%% *}; v=${s#* }; kubectl -n $NS patch settings.longhorn.io $k --type merge -p "{\"value\":$(printf '%s' "$v" | jq -Rs .)}" | sed 's/^/   /'; done
/bin/sleep 60
for n in $W; do kubectl -n $NS patch nodes.longhorn.io $n --type merge -p "{\"spec\":{\"tags\":[\"longhorn-v2-node\"],\"disks\":{\"v2-disk\":{\"allowScheduling\":true,\"diskDriver\":\"aio\",\"diskType\":\"block\",\"evictionRequested\":false,\"path\":\"$(disk $n)\",\"storageReserved\":0,\"tags\":[\"longhorn-v2\"]}}}}" | sed 's/^/   /'; done
for i in $(seq 1 60); do r=$(kubectl -n $NS get nodes.longhorn.io -o json | jq -r '[.items[] | select(.spec.disks["v2-disk"]) | (.status.diskStatus["v2-disk"].conditions[]? | select(.type=="Ready") | .status)] | join(",")'); [ "$r" = "True,True,True" ] && break; /bin/sleep 10; done; echo "   v2-disk ready=$r"
echo ">>> 워크로드 다시 생성"; kubectl apply -f v2test/pg-prod.yaml -f v2test/u4.yaml | sed 's/^/   /'
echo "images: $(kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sed 's/.*://' | sort | uniq -c | tr '\n' ' ')"
