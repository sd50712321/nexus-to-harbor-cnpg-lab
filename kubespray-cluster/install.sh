#!/bin/bash
# =============================================================================
# 처음부터 끝까지 설치: 도구 준비 → (랩) VM 기동 → Kubespray → ToR/L2/Longhorn/CNPG/Harbor → 검증
#
#   ./install.sh                     # 랩: Vagrant VM 9대 + 전체 설치
#   ./install.sh --from cluster      # 특정 단계부터 재개 (tools|vms|cluster|addons|verify)
#   INVENTORY=inventory/prod ./install.sh   # 실서버: VM 단계 건너뜀, 해당 인벤토리로 설치
#
# 단계마다 재실행 안전(멱등). 실패하면 고치고 --from 으로 그 단계부터 다시.
# 실서버 인벤토리는 inventory/lab 을 복사해 ip·ssh 설정·VIP·풀 대역을 바꾼다 (INFRA.md 참고).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
KUBESPRAY_VER=v2.32.0
INVENTORY=${INVENTORY:-inventory/lab}
LAB=$([ "$INVENTORY" = inventory/lab ] && echo 1 || echo 0)
FROM=tools; [ "${1:-}" = --from ] && FROM=${2:?단계 이름}
STEPS=(tools vms cluster addons verify)
run=0; step(){ [ "$1" = "$FROM" ] && run=1; [ $run = 1 ]; }
say(){ echo; echo "################ $(date +%H:%M:%S) $*"; }
need(){ command -v "$1" >/dev/null || { echo "필요: $1 ($2)"; exit 1; }; }

if step tools; then
  say "1/5 도구 준비"
  if [ "$(uname)" = Darwin ]; then
    need brew "https://brew.sh"
    for p in git python@3.12 kubectl helm skopeo; do brew list --formula $p >/dev/null 2>&1 || brew install $p; done
    if [ $LAB = 1 ]; then
      brew list --cask vagrant >/dev/null 2>&1 || brew install --cask vagrant
      [ -d "/Applications/VMware Fusion.app" ] || { echo "VMware Fusion 을 먼저 설치하세요 (Broadcom 무료 다운로드, 계정 필요)"; exit 1; }
      vagrant plugin list | grep -q vagrant-vmware-desktop || vagrant plugin install vagrant-vmware-desktop
      [ -e /opt/vagrant-vmware-desktop/bin/vagrant-vmware-utility ] || { echo "Vagrant VMware Utility 설치 필요: https://developer.hashicorp.com/vagrant/install/vmware"; exit 1; }
      vagrant box list | grep -q 'bento/ubuntu-24.04.*202510.26.0' || vagrant box add bento/ubuntu-24.04 --box-version 202510.26.0 --provider vmware_desktop --architecture arm64
    fi
    PY=$(brew --prefix)/bin/python3.12
  else
    # 리눅스 배포 서버(점프 호스트)
    need python3 "apt/dnf 로 설치"; need git "apt/dnf 로 설치"; need kubectl "https://kubernetes.io/docs/tasks/tools/"; need helm "https://helm.sh/docs/intro/install/"
    PY=python3
  fi
  [ -d kubespray ] || git clone -q --depth 1 --branch $KUBESPRAY_VER https://github.com/kubernetes-sigs/kubespray.git
  [ -d .venv ] || $PY -m venv .venv
  . .venv/bin/activate; pip -q install -U pip; pip -q install -r kubespray/requirements.txt
  ansible --version | head -1
fi

. .venv/bin/activate
export ANSIBLE_CONFIG=$ROOT/kubespray/ansible.cfg ANSIBLE_HOST_KEY_CHECKING=False

# 인벤토리에 http_proxy 가 있으면 설치 전에 프록시가 응답하는지 본다. 꺼져 있으면 apt/이미지 받기에서 멈춘다(TROUBLESHOOTING 1·2절).
PROXY=$(grep -hE '^http_proxy:' $INVENTORY/group_vars/all/*.yml 2>/dev/null | head -1 | grep -oE 'https?://[^" ]+' || true)
if [ -n "$PROXY" ]; then
  HP=${PROXY#*://}; HP=${HP%%/*}
  [ $LAB = 1 ] && ./scripts/lab-proxy.sh      # 랩: Mac 에 프록시가 없으면 띄운다
  if (exec 3<>/dev/tcp/${HP%:*}/${HP##*:}) 2>/dev/null; then echo "프록시 $PROXY 응답 OK"
  else echo "프록시 $PROXY 에 연결 안 됨. 랩이면 scripts/lab-proxy.sh 로그 확인. 실서버면 사내 프록시 주소·방화벽 확인."; exit 1; fi
fi

if step vms; then
  if [ $LAB = 1 ]; then
    say "2/5 VM 기동 (Vagrant)"
    vagrant up --parallel
    ./scripts/00-inventory.sh
  else
    say "2/5 실서버: VM 단계 건너뜀, SSH 도달 확인"
  fi
  ansible -i $INVENTORY/inventory.ini all -m ping -o
fi

if step cluster; then
  say "3/5 Kubespray cluster.yml"
  INVENTORY=$INVENTORY ./scripts/10-cluster.sh
fi

if step addons; then
  say "4/5 ToR(랩) · Cilium L2 · Longhorn · CNPG · Harbor"
  INVENTORY=$INVENTORY ./scripts/20-addons.sh
fi

if step verify; then
  say "5/5 검증"
  INVENTORY=$INVENTORY ./scripts/30-verify.sh
fi
echo; echo "완료. kubeconfig: $ROOT/$INVENTORY/artifacts/admin.conf"
