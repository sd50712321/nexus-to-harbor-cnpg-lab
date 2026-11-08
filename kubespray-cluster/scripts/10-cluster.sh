#!/bin/bash
# Kubespray 로 클러스터 생성. 재실행 안전(멱등). 로그는 logs/cluster-<시각>.log
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
mkdir -p logs
export ANSIBLE_CONFIG=kubespray/ansible.cfg ANSIBLE_HOST_KEY_CHECKING=False
# macOS 컨트롤러: fork 된 워커가 Objective-C 런타임 검사로 멈추는 문제 회피 (ansible macOS 알려진 이슈)
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
LOG=logs/cluster-$(date +%m%d-%H%M).log
ansible-playbook -i ${INVENTORY:-inventory/lab}/inventory.ini preflight.yml 2>&1 | tee $LOG
ansible-playbook -i ${INVENTORY:-inventory/lab}/inventory.ini kubespray/cluster.yml -b "$@" 2>&1 | tee -a $LOG
