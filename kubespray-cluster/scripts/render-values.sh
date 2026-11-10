#!/bin/bash
# templates/ 를 인벤토리 값으로 풀어 rendered/<인벤토리 이름>/ 에 쓴다. 클러스터에 접속하지 않는다.
#   ./scripts/render-values.sh                                   # 랩
#   INVENTORY=inventory/prod-sample ./scripts/render-values.sh   # 견본 값
#   ARCH=arm64 …                                                 # 노드가 arm64 일 때(Harbor 대체 이미지). 랩은 자동으로 arm64
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
INVD=${INVENTORY:-inventory/lab}
ARCH=${ARCH:-$([ "$(basename $INVD)" = lab ] && echo arm64 || echo amd64)}
export ANSIBLE_CONFIG=kubespray/ansible.cfg OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
ansible-playbook -i $INVD/inventory.ini render.yml -e render_arch=$ARCH | grep -E "^(fatal|failed)|ok="
ls -1 rendered/$(basename $INVD)
