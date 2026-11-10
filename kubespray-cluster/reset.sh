#!/bin/bash
# =============================================================================
# 초기화. 세 단계 중 고른다 (아래로 갈수록 많이 지움). 확인 문구를 입력해야 진행.
#
#   ./reset.sh apps      Harbor·CNPG·Longhorn 만 제거 (클러스터 유지)       → install.sh --from addons
#   ./reset.sh cluster   Kubespray reset.yml: 노드에서 k8s 전부 제거 (OS·VM 유지) → install.sh --from cluster
#   ./reset.sh vms       (랩 전용) VM 삭제                                    → install.sh --from vms
#
#   INVENTORY=inventory/prod ./reset.sh cluster   # 실서버
#   FORCE=1 ./reset.sh ...                        # 확인 문구 생략(자동화용)
# 데이터: Longhorn 볼륨·CNPG DB·Harbor 이미지가 모두 사라진다. 실서버에서는 백업 먼저.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
INVENTORY=${INVENTORY:-inventory/lab}
MODE=${1:?"사용법: ./reset.sh apps|cluster|vms"}
export KUBECONFIG=$PWD/$INVENTORY/artifacts/admin.conf ANSIBLE_CONFIG=$PWD/kubespray/ansible.cfg ANSIBLE_HOST_KEY_CHECKING=False
. .venv/bin/activate

confirm(){ [ "${FORCE:-0}" = 1 ] && return; echo "대상 인벤토리: $INVENTORY / 모드: $MODE"; read -r -p "진행하려면 '$1' 을 입력: " a; [ "$a" = "$1" ] || { echo "취소"; exit 1; }; }

case $MODE in
apps)
  confirm "delete-apps"
  # 매니페스트는 첫 control plane 안에서 렌더링되므로(addons.yml) 여기서는 이름으로 지운다
  kubectl -n harbor delete service harbor-bgp --ignore-not-found
  helm uninstall harbor -n harbor --wait 2>/dev/null || true
  kubectl -n harbor delete cluster.postgresql.cnpg.io harbor-pg --ignore-not-found --wait
  kubectl -n harbor delete pvc --all --wait          # resourcePolicy keep 으로 남은 PVC 까지
  kubectl delete namespace harbor --ignore-not-found --wait
  helm uninstall cnpg -n cnpg-system --wait 2>/dev/null || true
  # Longhorn 은 삭제 확인 플래그를 켜야 uninstall 이 진행된다
  kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag --type merge -p '{"value":"true"}' 2>/dev/null || true
  helm uninstall longhorn -n longhorn-system --wait --timeout 10m 2>/dev/null || true
  kubectl delete sc longhorn-single --ignore-not-found
  kubectl get pv -o name | xargs -r kubectl delete --wait=false   # Retain 정책으로 남은 PV
  kubectl delete ciliuml2announcementpolicies.cilium.io lab-l2 --ignore-not-found
  echo "앱 제거 완료. 워커의 /var/lib/longhorn 데이터 디렉터리는 남아 있다(cluster 모드에서 함께 지움)."
  ;;
cluster)
  confirm "reset-cluster"
  ansible-playbook -i $INVENTORY/inventory.ini kubespray/reset.yml -b -e reset_confirmation=yes
  # Kubespray reset 이 안 지우는 것: Longhorn 데이터, iSCSI 세션
  ansible -i $INVENTORY/inventory.ini kube_node -b -m shell -a 'iscsiadm -m node -u 2>/dev/null; rm -rf /var/lib/longhorn' || true
  rm -rf $INVENTORY/artifacts
  echo "클러스터 제거 완료. 다시 설치: INVENTORY=$INVENTORY ./install.sh --from cluster"
  ;;
vms)
  [ "$INVENTORY" = inventory/lab ] || { echo "vms 모드는 랩 전용"; exit 1; }
  confirm "destroy-vms"
  vagrant destroy -f
  rm -rf inventory/lab/artifacts inventory/lab/ssh.cfg
  echo "VM 삭제 완료. 다시 설치: ./install.sh --from vms"
  ;;
*) echo "모드: apps | cluster | vms"; exit 1;;
esac
