#!/bin/bash
# Kubespray 이후 애드온. 재실행 안전.
#   - tor 그룹이 있으면(랩) FRR 로 ToR 스위치 역할 구성. 실서버는 네트워크팀이 스위치에 BGP 설정(INFRA.md)
#   - addons.yml: Longhorn 준비 → Cilium L2 → ingress-nginx → Longhorn → CNPG → Harbor (첫 control plane 에서 kubectl/helm)
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
INV=${INVENTORY:-inventory/lab}/inventory.ini
export ANSIBLE_CONFIG=kubespray/ansible.cfg ANSIBLE_HOST_KEY_CHECKING=False OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
mkdir -p logs secrets; chmod 700 secrets
LOG=logs/addons-$(date +%m%d-%H%M).log
if ansible-inventory -i $INV --graph tor 2>/dev/null | grep -q -- '--'; then
  ansible-playbook -i $INV tor.yml -b 2>&1 | tee -a $LOG
fi
ansible-playbook -i $INV addons.yml -b 2>&1 | tee -a $LOG
