#!/bin/bash
# 구성요소 하나만 설치/갱신:  ./scripts/addon.sh ingress|longhorn|cnpg|harbor|l2|tor
#   INVENTORY=inventory/prod ./scripts/addon.sh harbor
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
C=${1:?"구성요소: l2 | ingress | longhorn | cnpg | harbor | tor"}
INV=${INVENTORY:-inventory/lab}/inventory.ini
export ANSIBLE_CONFIG=kubespray/ansible.cfg ANSIBLE_HOST_KEY_CHECKING=False OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
mkdir -p logs secrets; chmod 700 secrets
if [ "$C" = tor ]; then ansible-playbook -i $INV tor.yml -b; else ansible-playbook -i $INV addons.yml -b --tags "$C"; fi 2>&1 | tee logs/addon-$C-$(date +%m%d-%H%M).log
