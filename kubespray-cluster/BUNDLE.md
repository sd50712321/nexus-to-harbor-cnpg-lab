# 코드 묶음 (붙여넣기용)

다운로드·`git clone` 이 안 되는 곳으로 이 디렉터리를 옮길 때 쓴다. `scripts/make-bundle.sh` 가 만든 파일이므로 직접 고치지 않는다.

1. 빈 디렉터리를 만들고 들어간다.

```bash
mkdir -p ~/kubespray-cluster && cd ~/kubespray-cluster
```

2. 아래 블럭을 위에서부터 차례로 복사해 터미널에 붙여넣는다. 블럭 하나가 파일 하나를 만든다. 붙여넣기가 불안하면 블럭들을 편집기로 `bundle.sh` 한 파일에 모은 뒤 `bash bundle.sh` 로 실행한다.

3. 맨 아래 sha256 대조 블럭을 붙여넣어 모든 줄이 `OK` 인지 확인한다.

파일 38개. 문서(README·INFRA·TROUBLESHOOTING)는 GitHub 화면에서 바로 읽으면 되므로 넣지 않았다.

| # | 파일 | 줄 수 |
|---|---|---|
| 1 | [.gitignore](#1-gitignore) | 12 |
| 2 | [Vagrantfile](#2-vagrantfile) | 62 |
| 3 | [addons.yml](#3-addonsyml) | 154 |
| 4 | [install.sh](#4-installsh) | 85 |
| 5 | [preflight.yml](#5-preflightyml) | 69 |
| 6 | [render.yml](#6-renderyml) | 23 |
| 7 | [reset.sh](#7-resetsh) | 56 |
| 8 | [tor.yml](#8-toryml) | 53 |
| 9 | [versions.yml](#9-versionsyml) | 6 |
| 10 | [scripts/00-inventory.sh](#10-scripts00-inventorysh) | 6 |
| 11 | [scripts/10-cluster.sh](#11-scripts10-clustersh) | 12 |
| 12 | [scripts/20-addons.sh](#12-scripts20-addonssh) | 15 |
| 13 | [scripts/30-verify.sh](#13-scripts30-verifysh) | 68 |
| 14 | [scripts/40-failover.sh](#14-scripts40-failoversh) | 64 |
| 15 | [scripts/50-more-tests.sh](#15-scripts50-more-testssh) | 92 |
| 16 | [scripts/60-db-node-loss.sh](#16-scripts60-db-node-losssh) | 76 |
| 17 | [scripts/61-db-move-instance.sh](#17-scripts61-db-move-instancesh) | 53 |
| 18 | [scripts/62-ingress-failover.sh](#18-scripts62-ingress-failoversh) | 82 |
| 19 | [scripts/addon.sh](#19-scriptsaddonsh) | 11 |
| 20 | [scripts/harbor-env.sh](#20-scriptsharbor-envsh) | 10 |
| 21 | [scripts/lab-proxy.sh](#21-scriptslab-proxysh) | 16 |
| 22 | [scripts/make-bundle.sh](#22-scriptsmake-bundlesh) | 79 |
| 23 | [scripts/render-values.sh](#23-scriptsrender-valuessh) | 13 |
| 24 | [scripts/rolling-reload.sh](#24-scriptsrolling-reloadsh) | 29 |
| 25 | [templates/apply-order.md.j2](#25-templatesapply-ordermdj2) | 71 |
| 26 | [templates/cilium-l2.yaml.j2](#26-templatescilium-l2yamlj2) | 15 |
| 27 | [templates/harbor-bgp-svc.yaml.j2](#27-templatesharbor-bgp-svcyamlj2) | 38 |
| 28 | [templates/harbor-pg.yaml.j2](#28-templatesharbor-pgyamlj2) | 32 |
| 29 | [templates/harbor-values.yaml.j2](#29-templatesharbor-valuesyamlj2) | 85 |
| 30 | [templates/ingress-nginx-values.yaml.j2](#30-templatesingress-nginx-valuesyamlj2) | 22 |
| 31 | [templates/longhorn-sc-single.yaml.j2](#31-templateslonghorn-sc-singleyamlj2) | 14 |
| 32 | [templates/longhorn-values.yaml.j2](#32-templateslonghorn-valuesyamlj2) | 20 |
| 33 | [inventory/lab/inventory.ini](#33-inventorylabinventoryini) | 23 |
| 34 | [inventory/prod-sample/inventory.ini](#34-inventoryprod-sampleinventoryini) | 22 |
| 35 | [inventory/lab/group_vars/all/lab.yml](#35-inventorylabgroup_varsalllabyml) | 46 |
| 36 | [inventory/lab/group_vars/k8s_cluster/lab.yml](#36-inventorylabgroup_varsk8s_clusterlabyml) | 92 |
| 37 | [inventory/prod-sample/group_vars/all/env.yml](#37-inventoryprod-samplegroup_varsallenvyml) | 58 |
| 38 | [inventory/prod-sample/group_vars/k8s_cluster/k8s.yml](#38-inventoryprod-samplegroup_varsk8s_clusterk8syml) | 96 |

## 1. .gitignore

```bash
cat > '.gitignore' <<'__KS_EOF__'
# 다시 받는 것
kubespray/
.venv/
.vagrant/
# 비밀값·접속 정보 (절대 커밋 금지)
secrets/
inventory/*/artifacts/
inventory/*/credentials/
inventory/*/ssh.cfg
# 실행 기록·개인 메모
logs/
notes/
__KS_EOF__
```

## 2. Vagrantfile

```bash
cat > 'Vagrantfile' <<'__KS_EOF__'
# -*- mode: ruby -*-
# Kubespray HA 클러스터 랩: control plane 3 (etcd 쿼럼 2) + worker 5
# 환경: macOS Apple Silicon + VMware Fusion + vagrant-vmware-desktop, bento/ubuntu-24.04 arm64
#
#   vagrant up                       # VM 9대 기동 (프로비저닝 없음, 클러스터는 Kubespray 로)
#   ./scripts/00-inventory.sh        # vagrant ssh-config → inventory/lab/ssh.cfg
#   ./scripts/10-cluster.sh          # Kubespray cluster.yml
#
# 메모리 합계 = 3 × CP_MEM + W_COUNT × W_MEM + TOR (기본 3×2560 + 5×2688 + 512 MB = 약 21 GB). CP 1792MB 는 etcd+apiserver 로 메모리 150% → kube-vip 리스 실패(VIP 이동)를 겪어 2560 으로 올림. 32 GB Mac 에서 다른 VM/podman 을 끄고 돌린다.
# 워커는 처음에 7대 × 1920MB 였다. kubelet 이 노드마다 868Mi 를 떼어 두고(kubeReserved 256 + systemReserved 512 + eviction 100) Cilium·Longhorn 데몬이 또 깔려서,
# DB 복구처럼 I/O 가 몰리면 memory.available < 100Mi → Longhorn 파드 퇴거 → 그 노드 볼륨 정지가 반복됐다(TROUBLESHOOTING 16절). 같은 합계로 5대 × 2688MB 로 바꿨다.
# 7대로 되돌리려면 W_COUNT=7 W_MEM=1920 을 주고 scale.yml 로 ks-w6·ks-w7 을 다시 넣는다(두 VM 은 지우지 않고 꺼 두었다).

CP_COUNT = Integer(ENV.fetch("CP_COUNT", 3))      # 3 = etcd 쿼럼 2. 2 는 쓰지 않는다(한 대만 죽어도 쿼럼 상실)
W_COUNT  = Integer(ENV.fetch("W_COUNT", 5))
CP_MEM   = Integer(ENV.fetch("CP_MEM", 2560))
W_MEM    = Integer(ENV.fetch("W_MEM", 2688))
TOR_MEM  = Integer(ENV.fetch("TOR_MEM", 512))
BOX          = "bento/ubuntu-24.04"
BOX_VERSION  = "202510.26.0"

# Apple Silicon Fusion 은 Vagrant 가 새 vmnet 을 못 만든다 → Fusion 이 잡아 둔 host-only(vmnet1) 대역을 재사용
FUSION_NET_CONF = "/Library/Preferences/VMware Fusion/networking"
NET = File.read(FUSION_NET_CONF)[/VNET_1_HOSTONLY_SUBNET (\d+\.\d+\.\d+)\.\d+/, 1] or abort("vmnet1 host-only 서브넷을 못 읽음")

# 주소 계획 (같은 vmnet1 의 기존 k8s-core 랩 .10~.16/.100/.200 과 겹치지 않게)
#   .29        ks-tor   — ToR(상단) 스위치/라우터 역할. FRR 로 BGP(AS 65000), 노드들(AS 65010)과 피어링
#   .30        API VIP (kube-vip, ARP)
#   .31~.33    ks-cp1~3
#   .41~.45    ks-w1~5 (.46·.47 = 꺼 둔 ks-w6·7)
#   .210~.219  Cilium LB 풀 "L2" — 노드 서브넷 안 VIP, ARP 로 광고 (Harbor = .210)
#   10.250.0.0/24  Cilium LB 풀 "BGP" — 노드 서브넷 밖 VIP 대역, BGP 로 ToR 에 경로 광고 (ECMP)
NODES = [{ name: "ks-tor", ip: "#{NET}.29", mem: TOR_MEM }] +
        (1..CP_COUNT).map { |i| { name: "ks-cp#{i}", ip: "#{NET}.#{30 + i}", mem: CP_MEM } } +
        (1..W_COUNT).map  { |i| { name: "ks-w#{i}",  ip: "#{NET}.#{40 + i}", mem: W_MEM } }

Vagrant.configure("2") do |config|
  config.vm.box              = BOX
  config.vm.box_version      = BOX_VERSION
  config.vm.box_architecture = "arm64"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |n|
    config.vm.define n[:name] do |m|
      m.vm.hostname = n[:name]
      m.vm.network "private_network", ip: n[:ip]
      m.vm.provider "vmware_desktop" do |v|
        v.gui    = false
        v.memory = n[:mem]
        v.cpus   = 2
        v.linked_clone = true
        v.vmx["displayName"] = n[:name]
        # suspend 금지 + Tools 시간 동기화 끔: resume/RTC(KST) 로 시계가 튀면 etcd 리스·프로브가 깨진다 (k8s-core TROUBLESHOOTING 참고)
        v.vmx["suspend.disabled"] = "TRUE"
        %w[tools.synctime time.synchronize.continue time.synchronize.restore time.synchronize.resume.disk
           time.synchronize.shrink time.synchronize.tools.startup time.synchronize.tools.enable].each { |k| v.vmx[k] = "FALSE" }
        # Fusion 무료화 이후 라이선스 오인식으로 private_network 가 무시되는 문제 회피
        v.force_vmware_license = "professional"
      end
    end
  end
end
__KS_EOF__
```

## 3. addons.yml

```bash
cat > 'addons.yml' <<'__KS_EOF__'
---
# Kubespray 이후 애드온: Cilium L2 → ingress-nginx → Longhorn → CNPG → Harbor
# kubectl/helm 은 첫 control plane 노드에서 실행 → 배포 호스트(Mac/Linux)에 kubectl·helm 이 없어도 된다.
#   전부        : ansible-playbook -i inventory/<env>/inventory.ini addons.yml -b
#   하나만      : ... --tags longhorn   (l2 | ingress | longhorn | cnpg | harbor)
#   켜기/끄기   : 인벤토리의 *_enabled 변수 (환경에 이미 있는 구성요소는 false)

- name: Longhorn 노드 사전 조건 (워커, Ubuntu/RHEL 공통)
  hosts: kube_node
  become: true
  tags: [longhorn]
  environment:
    http_proxy: "{{ http_proxy | default('') }}"
    https_proxy: "{{ https_proxy | default('') }}"
  tasks:
    - meta: end_play
      when: not (longhorn_enabled | bool)
    - name: 패키지 (Debian 계열)
      apt:
        name: [open-iscsi, nfs-common, cryptsetup, dmsetup]
        update_cache: true
        cache_valid_time: 3600
      when: ansible_os_family == 'Debian'
    - name: 패키지 (RHEL 계열)
      dnf:
        name: [iscsi-initiator-utils, nfs-utils, cryptsetup, device-mapper]
      when: ansible_os_family == 'RedHat'
    - name: iscsid 기동
      systemd: {name: iscsid, enabled: true, state: started}
    - name: 커널 모듈 (지금 + 부팅 시)
      community.general.modprobe: {name: "{{ item }}", state: present, persistent: present}
      loop: [iscsi_tcp, dm_crypt]
    - name: multipath 설정 여부
      stat: {path: /etc/multipath.conf}
      register: mp
    - name: multipathd 가 Longhorn 장치(/dev/sd*)를 잡지 않게 블랙리스트
      blockinfile:
        path: /etc/multipath.conf
        block: |
          blacklist {
              devnode "^sd[a-z0-9]+"
          }
      when: mp.stat.exists
      register: mpconf
    - name: multipathd 재시작
      systemd: {name: multipathd, state: restarted}
      when: mpconf is changed

- name: 클러스터 애드온 (첫 control plane 에서 kubectl/helm)
  hosts: kube_control_plane[0]
  become: true
  vars_files: [versions.yml]
  vars:
    work: /root/lab-addons
    harbor_arm64: "{{ ansible_architecture == 'aarch64' }}"
    harbor_admin_password: "{{ lookup('ansible.builtin.password', playbook_dir + '/secrets/harbor-admin', length=20, chars=['ascii_letters', 'digits']) }}"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
    http_proxy: "{{ http_proxy | default('') }}"
    https_proxy: "{{ https_proxy | default('') }}"
    no_proxy: "{{ no_proxy | default('') }}"
    PATH: "/usr/local/bin:{{ ansible_env.PATH }}"
  tasks:
    - name: 작업 디렉터리
      tags: [always]
      file: {path: "{{ work }}", state: directory, mode: "0700"}
    - name: 매니페스트·values 렌더링
      tags: [always]
      template: {src: "templates/{{ item }}.j2", dest: "{{ work }}/{{ item }}", mode: "0600"}
      loop: [cilium-l2.yaml, ingress-nginx-values.yaml, longhorn-values.yaml, longhorn-sc-single.yaml, harbor-pg.yaml, harbor-values.yaml, harbor-bgp-svc.yaml]

    - name: Cilium L2 공지 정책
      command: kubectl apply -f {{ work }}/cilium-l2.yaml
      tags: [l2]
      when: cilium_l2_enabled | bool

    - name: helm 저장소
      tags: [ingress, longhorn, cnpg, harbor]
      shell: |
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
        helm repo add longhorn https://charts.longhorn.io --force-update
        helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
        helm repo add harbor https://helm.goharbor.io --force-update
        helm repo update
      changed_when: false

    - name: ingress-nginx (밖에서 들어오는 HTTP(S) 를 VIP 하나로 받는다)
      command: >-
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
        --version {{ ingress_nginx_chart_version }} -f {{ work }}/ingress-nginx-values.yaml --wait --timeout 10m
      tags: [ingress]
      when: ingress_nginx_enabled | bool

    - name: Longhorn
      command: >-
        helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace
        --version {{ longhorn_version }} -f {{ work }}/longhorn-values.yaml --wait --timeout 15m
      tags: [longhorn]
      when: longhorn_enabled | bool
    - name: CNPG 용 StorageClass (복제 1벌, strict-local)
      command: kubectl apply -f {{ work }}/longhorn-sc-single.yaml

      tags: [longhorn]
      when: longhorn_enabled | bool
    - name: CloudNativePG operator
      command: >-
        helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
        --version {{ cnpg_chart_version }} --wait --timeout 10m
      tags: [cnpg]
      when: cnpg_enabled | bool
    - name: harbor 네임스페이스
      shell: kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
      tags: [cnpg, harbor]
      when: cnpg_enabled | bool or harbor_enabled | bool
    - name: Harbor DB (CNPG 3 인스턴스)
      command: kubectl apply -f {{ work }}/harbor-pg.yaml
      tags: [cnpg]
      when: cnpg_enabled | bool
    - name: Harbor DB Ready 대기
      command: kubectl -n harbor wait cluster/harbor-pg --for=condition=Ready --timeout=15m
      changed_when: false

      tags: [cnpg]
      when: cnpg_enabled | bool
    - name: Harbor admin 비밀번호 Secret (값은 배포 호스트 secrets/harbor-admin 에만)
      shell: |
        kubectl -n harbor get secret harbor-admin >/dev/null 2>&1 && exit 0
        kubectl -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD="$P"
      environment: {P: "{{ harbor_admin_password }}"}
      no_log: true

      tags: [harbor]
      when: harbor_enabled | bool
    - name: Harbor
      command: >-
        helm upgrade --install harbor harbor/harbor -n harbor --version {{ harbor_chart_version }}
        -f {{ work }}/harbor-values.yaml --wait --timeout 20m
      tags: [harbor]
      when: harbor_enabled | bool
    - name: 옛 Harbor 전용 BGP 서비스 정리 (노출을 loadBalancer → ingress 로 바꾼 클러스터. 같은 BGP VIP 를 쥐고 있어 새 서비스가 IP 를 못 받는다)
      command: kubectl -n harbor delete svc harbor-bgp --ignore-not-found
      tags: [harbor, ingress]
      when: bgp_enabled | bool and harbor_expose == 'ingress'
    - name: BGP 서비스 (ingress-nginx 또는 Harbor 앞)
      command: kubectl apply -f {{ work }}/harbor-bgp-svc.yaml
      tags: [harbor, ingress]
      when: bgp_enabled | bool and ((harbor_expose == 'ingress' and ingress_nginx_enabled | bool) or (harbor_expose != 'ingress' and harbor_enabled | bool))
    - name: 서비스 확인
      tags: [harbor]
      shell: kubectl -n harbor get svc,ingress; kubectl -n ingress-nginx get svc 2>/dev/null || true
      register: svc
      changed_when: false
    - debug: {var: svc.stdout_lines}
      tags: [harbor]
__KS_EOF__
```

## 4. install.sh

```bash
cat > 'install.sh' <<'__KS_EOF__'
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
__KS_EOF__
chmod +x 'install.sh'
```

## 5. preflight.yml

```bash
cat > 'preflight.yml' <<'__KS_EOF__'
---
# Kubespray 전 사전 점검 (모든 노드). 실서버에서도 그대로 쓴다.
- hosts: k8s_cluster
  become: true
  gather_facts: true
  tasks:
    - name: 설치 중 OS 자동 업데이트 정지 (Debian 계열 apt-daily / unattended-upgrades) — 패키지 잠금 경합으로 Kubespray 가 멈추는 것 방지
      systemd: {name: "{{ item }}", state: stopped, enabled: false}
      loop: [apt-daily.timer, apt-daily-upgrade.timer, unattended-upgrades.service]
      failed_when: false
      when: ansible_os_family == 'Debian'
    - name: 설치 중 dnf-automatic 정지 (RHEL 계열)
      systemd: {name: "{{ item }}", state: stopped, enabled: false}
      loop: [dnf-automatic.timer, dnf-makecache.timer]
      failed_when: false
      when: ansible_os_family == 'RedHat'
    - name: 클러스터 NIC 존재 확인
      assert:
        that: node_iface in ansible_interfaces
        fail_msg: "{{ inventory_hostname }}: node_iface={{ node_iface }} 가 없음. 실제 NIC: {{ ansible_interfaces | join(', ') }}"
    - name: ip 변수가 해당 NIC 의 주소인지
      assert:
        that: ip == hostvars[inventory_hostname]['ansible_' + node_iface | replace('-', '_')].ipv4.address
        fail_msg: "{{ inventory_hostname }}: ip={{ ip }} 가 {{ node_iface }} 주소와 다름"
    - name: VIP 응답 여부 (최초 설치 전에 응답이 오면 다른 장비와 IP 충돌)
      command: "ping -c1 -W1 {{ item }}"
      register: vip_ping
      changed_when: false
      failed_when: false
      loop: ["{{ apiserver_vip }}", "{{ ingress_vip if harbor_expose | default('ingress') == 'ingress' else harbor_vip }}"]
      run_once: true
    - name: VIP 충돌 경고 (재설치·재실행이면 우리 클러스터가 쓰는 중이라 정상)
      debug: {msg: "{{ item.item }} 가 이미 응답함. 최초 설치라면 IP 충돌 — IPAM 확인"}
      loop: "{{ vip_ping.results }}"
      when: item.rc == 0
      run_once: true
    - name: 시간 동기화 상태
      command: timedatectl show -p NTPSynchronized --value
      register: ntp
      changed_when: false
    - name: NTP 미동기 경고
      debug: {msg: "{{ inventory_hostname }}: NTP 미동기. etcd·인증서 문제 위험"}
      when: ntp.stdout != 'yes'

    # ----- 노드가 VM 일 때: 같은 템플릿에서 복제한 VM 은 식별자가 겹칠 수 있다 (INFRA.md 6절) -----
    - name: 가상화 종류
      debug: {msg: "{{ inventory_hostname }}: {{ ansible_virtualization_role }} / {{ ansible_virtualization_type }}, 메모리 {{ ansible_memtotal_mb }}MB, vCPU {{ ansible_processor_vcpus }}, swap {{ ansible_swaptotal_mb }}MB"}
    - name: (VM 복제) machine-id · product_uuid · 클러스터 NIC 의 MAC 이 노드마다 다른지 — kubeadm 설치 조건
      assert:
        that:
          - (ansible_play_hosts | map('extract', hostvars, 'ansible_machine_id') | unique | length) == (ansible_play_hosts | length)
          - (ansible_play_hosts | map('extract', hostvars, 'ansible_product_uuid') | unique | length) == (ansible_play_hosts | length)
          - (ansible_play_hosts | map('extract', hostvars, ['ansible_' + node_iface | replace('-', '_'), 'macaddress']) | unique | length) == (ansible_play_hosts | length)
        fail_msg: "겹치는 식별자가 있다. machine-id {{ ansible_play_hosts | map('extract', hostvars, 'ansible_machine_id') | unique | length }}종, product_uuid {{ ansible_play_hosts | map('extract', hostvars, 'ansible_product_uuid') | unique | length }}종 / 노드 {{ ansible_play_hosts | length }}대. VM 템플릿 복제 후 재생성 필요(INFRA.md 6절)"
      run_once: true
    - name: (VM 복제) iSCSI initiator 이름
      shell: sed -n 's/^InitiatorName=//p' /etc/iscsi/initiatorname.iscsi 2>/dev/null || true
      register: iqn
      changed_when: false
    - name: (VM 복제) iSCSI initiator 이름이 겹침 — 경고만. 템플릿에 open-iscsi 가 들어 있으면 복제본이 같은 이름을 갖는다
      debug:
        msg: "initiator 이름 {{ _iqns | unique | length }}종 / 이름이 있는 노드 {{ _iqns | length }}대. Longhorn 은 노드 안의 타깃에만 붙어 동작하지만, 사내 iSCSI 스토리지를 같이 쓰면 충돌한다. 고치는 법은 INFRA.md 6절"
      vars:
        _iqns: "{{ ansible_play_hosts | map('extract', hostvars, ['iqn', 'stdout']) | select | list }}"
      when: (_iqns | unique | length) < (_iqns | length)
      run_once: true
    - name: swap 이 켜져 있음 — 경고 (Kubespray 가 끄지만 템플릿의 fstab·swapfile 이 재부팅 때 되살리는지 확인)
      debug: {msg: "{{ inventory_hostname }}: swap {{ ansible_swaptotal_mb }}MB"}
      when: ansible_swaptotal_mb | int > 0
__KS_EOF__
```

## 6. render.yml

```bash
cat > 'render.yml' <<'__KS_EOF__'
---
# 클러스터에 손대지 않고 templates/ 를 인벤토리 값으로 풀어 rendered/<인벤토리 이름>/ 에 쓴다.
#   ./scripts/render-values.sh                                   # 랩 (arm64)
#   INVENTORY=inventory/prod-sample ./scripts/render-values.sh   # 견본 값 (amd64)
# 쓰임: 설치 전에 values 를 눈으로 검토, ansible 없이 helm/kubectl 로 직접 설치, 변경 전후 비교(diff)
- name: values·매니페스트 렌더링 (로컬)
  hosts: kube_control_plane[0]
  connection: local
  gather_facts: false
  become: false
  vars_files: [versions.yml]
  vars:
    ansible_python_interpreter: "{{ ansible_playbook_python }}"   # 로컬에서 도는데 인벤토리 호스트의 인터프리터 경로를 쓰지 않게
    harbor_arm64: "{{ (render_arch | default('amd64')) in ['arm64', 'aarch64'] }}"
    out: "{{ playbook_dir }}/rendered/{{ inventory_dir | basename }}"
  tasks:
    - name: 출력 디렉터리
      file: {path: "{{ out }}", state: directory, mode: "0755"}
    - name: 렌더링
      template: {src: "templates/{{ item }}.j2", dest: "{{ out }}/{{ item }}", mode: "0644"}
      loop: [cilium-l2.yaml, ingress-nginx-values.yaml, longhorn-values.yaml, longhorn-sc-single.yaml, harbor-pg.yaml, harbor-values.yaml, harbor-bgp-svc.yaml]
    - name: 적용 순서
      template: {src: templates/apply-order.md.j2, dest: "{{ out }}/README.md", mode: "0644"}
__KS_EOF__
```

## 7. reset.sh

```bash
cat > 'reset.sh' <<'__KS_EOF__'
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
__KS_EOF__
chmod +x 'reset.sh'
```

## 8. tor.yml

```bash
cat > 'tor.yml' <<'__KS_EOF__'
---
# ks-tor: 랩의 ToR(Top of Rack) L3 스위치 역할. 실장비(Arista/Cisco/Juniper)의 BGP 설정을 FRR 로 흉내낸다.
#   - AS 65000, 노드망 172.16.141.0/24 에서 AS 65010 피어를 동적으로 받는다(listen range)
#   - Cilium 이 광고한 LB VIP(10.250.0.0/24 /32 경로)를 ECMP 로 설치
- hosts: tor
  become: true
  environment:
    http_proxy: "{{ http_proxy | default('') }}"
    https_proxy: "{{ https_proxy | default('') }}"
  tasks:
    - name: FRR 설치
      apt: {name: [frr, frr-pythontools], state: present, update_cache: true, cache_valid_time: 3600}
    - name: bgpd 켜기
      lineinfile: {path: /etc/frr/daemons, regexp: '^bgpd=', line: 'bgpd=yes'}
      register: daemons
    - name: IP 포워딩 (라우터)
      sysctl: {name: net.ipv4.ip_forward, value: "1", sysctl_set: true, state: present}
    - name: frr.conf
      copy:
        dest: /etc/frr/frr.conf
        owner: frr
        group: frr
        mode: "0640"
        content: |
          frr defaults datacenter
          hostname ks-tor
          log syslog informational
          !
          router bgp 65000
           bgp router-id 172.16.141.29
           no bgp ebgp-requires-policy
           bgp bestpath as-path multipath-relax
           neighbor K8S peer-group
           neighbor K8S remote-as 65010
           neighbor K8S timers 3 9
           bgp listen range 172.16.141.0/24 peer-group K8S
           !
           address-family ipv4 unicast
            neighbor K8S activate
            neighbor K8S soft-reconfiguration inbound
            ! 노드에서 받는 건 LB VIP 대역만 (실장비에서도 prefix-list 로 반드시 제한)
            neighbor K8S prefix-list K8S-IN in
            neighbor K8S prefix-list DENY-ALL out
            maximum-paths 16
           exit-address-family
          !
          ip prefix-list K8S-IN seq 10 permit 10.250.0.0/24 ge 32
          ip prefix-list DENY-ALL seq 10 deny any
          !
      register: conf
    - name: FRR 재시작
      systemd: {name: frr, enabled: true, state: restarted}
      when: daemons is changed or conf is changed
__KS_EOF__
```

## 9. versions.yml

```bash
cat > 'versions.yml' <<'__KS_EOF__'
---
# 애드온 버전 (addons.yml 설치, render.yml 렌더링이 같이 읽는다). 랩에서 실측한 조합이다.
ingress_nginx_chart_version: 4.15.1   # ingress-nginx 컨트롤러 1.15.1
longhorn_version: 1.13.0
cnpg_chart_version: 0.29.1            # CloudNativePG operator 1.30.1
harbor_chart_version: 1.18.0          # Harbor 2.14.0
__KS_EOF__
```

## 10. scripts/00-inventory.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/00-inventory.sh' <<'__KS_EOF__'
#!/bin/bash
# (랩 전용) vagrant ssh-config → inventory/lab/ssh.cfg (VM 재생성마다 키·주소가 바뀌므로 매번 다시 만든다)
set -euo pipefail
cd "$(dirname "$0")/.."
vagrant ssh-config > inventory/lab/ssh.cfg
grep -c '^Host ' inventory/lab/ssh.cfg | xargs echo "hosts:"
__KS_EOF__
chmod +x 'scripts/00-inventory.sh'
```

## 11. scripts/10-cluster.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/10-cluster.sh' <<'__KS_EOF__'
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
__KS_EOF__
chmod +x 'scripts/10-cluster.sh'
```

## 12. scripts/20-addons.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/20-addons.sh' <<'__KS_EOF__'
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
__KS_EOF__
chmod +x 'scripts/20-addons.sh'
```

## 13. scripts/30-verify.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/30-verify.sh' <<'__KS_EOF__'
#!/bin/bash
# 기동 검증 (읽기 + Harbor 에 테스트 이미지 1개 push/pull). 결과는 logs/verify-<시각>.txt
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
VIP=172.16.141.30; . scripts/harbor-env.sh      # HV(ingress VIP) HH(Harbor 호스트명) HB HU HA hcurl
OUT=logs/verify-$(date +%m%d-%H%M).txt; mkdir -p logs
exec > >(tee "$OUT") 2>&1
# 기대 대수는 인벤토리에서 읽는다 (워커 수를 바꿔도 스크립트를 안 고치게). 클러스터에서 세면 "있는 만큼 있다" 가 되어 검증이 아니다
cnt(){ awk -v g="[$1]" '$0==g{f=1;next} /^\[/{f=0} f&&NF&&$0!~/^#/{c++} END{print c+0}' ${INVENTORY:-inventory/lab}/inventory.ini; }
NCP=$(cnt kube_control_plane); NW=$(cnt kube_node); NALL=$((NCP+NW))
ok=0; ng=0; chk(){ if eval "$2" >/dev/null 2>&1; then echo "  [OK] $1"; ok=$((ok+1)); else echo "  [NG] $1"; ng=$((ng+1)); fi; }

echo "== 1. 노드 / 컨트롤플레인"
kubectl get nodes -o wide
chk "노드 ${NALL}대 Ready (CP $NCP + 워커 $NW)" "[ \$(kubectl get nodes --no-headers | grep -cw Ready) = $NALL ]"
chk "API VIP $VIP:6443 응답 (Mac 에서)" "curl -sk -m 5 https://$VIP:6443/livez | grep -q ok"
echo "  kubeconfig server: $(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
vagrant ssh ks-cp1 -c 'sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-ks-cp1.pem --key=/etc/ssl/etcd/ssl/admin-ks-cp1-key.pem endpoint status -w table' 2>/dev/null
chk "etcd 3 멤버 healthy" "vagrant ssh ks-cp1 -c 'sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-ks-cp1.pem --key=/etc/ssl/etcd/ssl/admin-ks-cp1-key.pem endpoint health' 2>/dev/null | grep -c 'is healthy' | grep -qx 3"
echo "  kube-vip 리더(VIP 보유 노드): $(for n in ks-cp1 ks-cp2 ks-cp3; do vagrant ssh $n -c "ip -4 a show eth1 | grep -q $VIP && hostname" 2>/dev/null; done | tr -d '\r')"

echo "== 2. Cilium"
chk "kube-proxy 없음" '[ $(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | wc -l) = 0 ]'
chk "cilium 에이전트 $NALL/$NALL Ready" "[ \"\$(kubectl -n kube-system get ds cilium -o jsonpath={.status.numberReady})\" = $NALL ]"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E 'KubeProxyReplacement|Cilium:|Host Routing|Masquerading'
kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy

echo "== 2-1. BGP (ToR ks-tor ↔ 워커)"
vagrant ssh ks-tor -c "sudo vtysh -c 'show bgp ipv4 unicast summary'" 2>/dev/null | sed -n '/Neighbor/,$p'
chk "ToR 에 BGP 세션 ${NW}개 Established" "[ \$(vagrant ssh ks-tor -c \"sudo vtysh -c 'show bgp ipv4 unicast summary json'\" 2>/dev/null | python3 -I -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for p in d[\"peers\"].values() if p[\"state\"]==\"Established\"))') = $NW ]"
vagrant ssh ks-tor -c "ip route show 10.250.0.10" 2>/dev/null | sed 's/^/    /'
chk "ToR 라우팅 테이블에 10.250.0.10 ECMP 경로(다음 홉 2개 이상)" "[ \$(vagrant ssh ks-tor -c 'ip route show 10.250.0.10' 2>/dev/null | grep -c nexthop) -ge 2 ]"
chk "ToR → BGP VIP 10.250.0.10 → ingress-nginx → Harbor ping" "vagrant ssh ks-tor -c 'curl -sk -m 5 --resolve $HH:443:10.250.0.10 $HU/api/v2.0/ping' 2>/dev/null | grep -q Pong"

echo "== 3. Longhorn"
kubectl -n longhorn-system get nodes.longhorn.io
chk "Longhorn 노드 ${NW}대 Ready·Schedulable" "[ \$(kubectl -n longhorn-system get nodes.longhorn.io --no-headers | grep -c 'True.*true.*True') = $NW ]"
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=VOL:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,REPLICAS:.spec.numberOfReplicas,NODE:.status.currentNodeID
echo "  복제본 배치(볼륨 → 노드):"
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState --no-headers | sort | awk '{a[$1]=a[$1]" "$2"("$3")"} END{for(k in a) print "   ",k":"a[k]}'
chk "붙어 있는 Longhorn 볼륨 모두 healthy" '[ $(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath="{range .items[?(@.status.state==\"attached\")]}{.status.robustness}{\"\\n\"}{end}" | grep -vc healthy) = 0 ]'
# 떼어진 볼륨 = DB 인스턴스를 다시 만들 때 남은 옛 볼륨(PV reclaim=Retain → Released). 서비스에는 안 쓰이지만 디스크를 차지하고, 그 노드의 drain 을 막는다(TROUBLESHOOTING 20절)
echo "  떼어진(옛) 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[?(@.status.state=="detached")]}{.metadata.name}{" "}{end}' | wc -w | tr -d ' ')개"

echo "== 4. CNPG"
kubectl -n harbor get cluster harbor-pg
kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o custom-columns=POD:.metadata.name,ROLE:.metadata.labels.cnpg\\.io/instanceRole,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready
chk "CNPG 3 인스턴스 healthy" 'kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.phase} | grep -q "healthy"'
chk "CNPG 인스턴스 3개가 서로 다른 노드" '[ $(kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o jsonpath="{range .items[*]}{.spec.nodeName}{\"\n\"}{end}" | sort -u | wc -l) = 3 ]'
kubectl -n harbor exec harbor-pg-1 -c postgres -- psql -tAc "select application_name, state, sync_state from pg_stat_replication" 2>/dev/null || \
  kubectl -n harbor exec $(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o name | head -1) -c postgres -- psql -tAc "select application_name, state, sync_state from pg_stat_replication"

echo "== 5. Harbor"
kubectl -n harbor get pods -o wide | grep -v harbor-pg
kubectl -n ingress-nginx get pods -o wide --no-headers | awk '{print "    "$1,$2,$3,$7}'
kubectl -n ingress-nginx get svc ingress-nginx-controller; kubectl -n harbor get ingress
echo "  VIP $HV 를 ARP 로 알리는 노드: $(kubectl -n kube-system get lease cilium-l2announce-ingress-nginx-ingress-nginx-controller -o jsonpath='{.spec.holderIdentity}')"
chk "ingress-nginx VIP = $HV, Harbor Ingress 호스트 = $HH" "[ \"\$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')\" = $HV ] && [ \"\$(kubectl -n harbor get ingress harbor-ingress -o jsonpath='{.spec.rules[0].host}')\" = $HH ]"
chk "Mac → $HU/api/v2.0/ping (VIP $HV)" "hcurl -m 5 $HU/api/v2.0/ping | grep -q Pong"
hcurl -m 5 -u "$HA" $HU/api/v2.0/health | python3 -I -c 'import sys,json;d=json.load(sys.stdin);print("  health:",d["status"],{c["name"]:c["status"] for c in d["components"]})'
hcurl -o /dev/null -u "$HA" -X POST $HU/api/v2.0/projects -H 'Content-Type: application/json' -d '{"project_name":"lab","public":false}'
TAG=v$(date +%H%M)
chk "skopeo push lab/alpine:$TAG" "skopeo copy -q --override-os linux --override-arch arm64 --dest-tls-verify=false --dest-creds '$HA' docker://docker.io/library/alpine:3.20 docker://$HB/lab/alpine:$TAG"
rm -rf /tmp/ks-pull; chk "skopeo pull 되돌려 받기" "skopeo copy -q --src-tls-verify=false --src-creds '$HA' docker://$HB/lab/alpine:$TAG dir:/tmp/ks-pull"
echo "$TAG" > logs/last-tag

echo; echo "결과: OK=$ok NG=$ng  (로그 $OUT)"
__KS_EOF__
chmod +x 'scripts/30-verify.sh'
```

## 14. scripts/40-failover.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/40-failover.sh' <<'__KS_EOF__'
#!/bin/bash
# 장애 시험 3종 (이 랩의 VM 만 정지/기동). 각 시험 후 원복까지 한다. 결과 logs/failover-<시각>.txt
#   A. API VIP 를 쥔 control plane 정지 → VIP 이동, etcd 쿼럼(2/3) 유지, API 계속 응답
#   B. CNPG primary 파드 삭제 → standby 승격, Harbor 계속 동작
#   C. Harbor registry 파드가 있는 워커 정지 → Longhorn 볼륨이 다른 노드에 재부착, 기존 이미지 pull 성공
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
VIP=172.16.141.30; . scripts/harbor-env.sh; TAG=$(cat logs/last-tag)
OUT=logs/failover-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
pull_ok(){ rm -rf /tmp/ks-fo; skopeo copy -q --src-tls-verify=false --src-creds "$HA" docker://$HB/lab/alpine:$TAG dir:/tmp/ks-fo >/dev/null 2>&1; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
# 재기동 판정: Ready 표시만 보면 짧게 꺼졌던 노드는 NotReady 로 바뀌기 전 값이 남아 0s 로 찍힌다.
# 그래서 kubelet 이 기동 시각 이후에 노드 lease 를 갱신했는지(실제로 살아 돌아왔는지)를 함께 본다.
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
harbor_healthy(){ hcurl -m 3 $HU/api/v2.0/health | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin)["status"]=="healthy" else 1)'; }
vip_holder(){ for n in ks-cp1 ks-cp2 ks-cp3; do vagrant ssh $n -c "ip -4 a show eth1 | grep -q $VIP && hostname" 2>/dev/null; done | tr -d '\r' | head -1; }

echo "== A. API VIP 보유 control plane 정지"
H=$(vip_holder); echo "$(ts) VIP 보유: $H → 정지"
vagrant halt $H --force >/dev/null 2>&1
t=$(wait_until 120 "curl -sk -m 3 https://$VIP:6443/livez | grep -q ok") && echo "$(ts) VIP 로 API 다시 응답: ${t}s 후, 새 보유: $(vip_holder)" || echo "$(ts) [NG] 120s 안에 API 복구 안 됨"
kubectl get nodes --no-headers | awk '{print "   ",$1,$2}'
O=$(for n in ks-cp1 ks-cp2 ks-cp3; do [ $n != $H ] && echo $n; done | head -1)
vagrant ssh $O -c "sudo ETCDCTL_API=3 etcdctl --endpoints=https://172.16.141.31:2379,https://172.16.141.32:2379,https://172.16.141.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-$O.pem --key=/etc/ssl/etcd/ssl/admin-$O-key.pem endpoint health 2>&1 | sed 's/^/    /'" 2>/dev/null
# CP 가 죽은 직후엔 apiserver 의 etcd 연결이 죽은 멤버에 붙어 있다가 넘어가는 동안 쓰기가 Unavailable 로 실패할 수 있다 → 재시도하며 첫 성공 시각을 잰다
write_cm(){ kubectl create configmap fo-write-test --from-literal=t="$(date +%s%N)" -n default --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; }
F0=0; write_cm || F0=1
t=$(wait_until 90 write_cm) && echo "$(ts) 쿼럼 2/3 상태에서 쓰기 OK (첫 시도 $([ $F0 = 0 ] && echo 성공 || echo "실패, ${t}s 재시도 후 성공"))" || echo "$(ts) [NG] 90s 동안 쓰기 실패"
pull_ok && echo "$(ts) Harbor pull OK (CP 1대 다운 중)" || echo "$(ts) [NG] Harbor pull 실패"
echo "$(ts) $H 기동"; B=$(date +%s); vagrant up $H >/dev/null 2>&1
t=$(wait_until 300 "node_back $H $B") && echo "$(ts) $H kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $H 300s 안에 복귀 안 됨"

echo; echo "== B. CNPG primary 삭제"
P=$(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); PN=$(kubectl -n harbor get pod $P -o jsonpath='{.spec.nodeName}')
echo "$(ts) primary: $P ($PN) → 삭제"
kubectl -n harbor delete pod $P --wait=false >/dev/null
t=$(wait_until 180 "kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.currentPrimary} | grep -vqx $P") && echo "$(ts) 새 primary: $(kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.currentPrimary}) (${t}s)"
t=$(wait_until 180 "hcurl -m 3 -u '$HA' $HU/api/v2.0/projects | grep -q lab") && echo "$(ts) Harbor API(DB 조회) 복구 ${t}s"
pull_ok && echo "$(ts) Harbor pull OK" || echo "$(ts) [NG] pull 실패"
# Cluster.status.readyInstances 는 수 분 늦게 갱신될 수 있다(TROUBLESHOOTING 9절) → 지운 인스턴스의 파드 Ready 와 실제 복제 연결 수로 판정
t=$(wait_until 300 "kubectl -n harbor get pod $P -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True") && echo "$(ts) $P 재기동 Ready ${t}s"
NP=$(kubectl -n harbor get cluster harbor-pg -o jsonpath={.status.currentPrimary})
t=$(wait_until 300 "[ \$(kubectl -n harbor exec $NP -c postgres -- psql -tAc \"select count(*) from pg_stat_replication where state='streaming'\") = 2 ]") && echo "$(ts) 새 primary $NP 에 복제 2개 streaming ${t}s"

echo; echo "== C. Harbor registry 파드가 있는 워커 정지 (Longhorn 재부착)"
RP=$(kubectl -n harbor get pods -l component=registry -o jsonpath='{.items[0].metadata.name}'); W=$(kubectl -n harbor get pod $RP -o jsonpath='{.spec.nodeName}')
V=$(kubectl -n harbor get pvc harbor-registry -o jsonpath='{.spec.volumeName}')
echo "$(ts) registry 파드 $RP @ $W, 볼륨 $V 복제본: $(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$V')]}{.spec.nodeID} {end}")"
echo "    같은 노드의 다른 Harbor 파드: $(kubectl -n harbor get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk -v w=$W '$2==w{print $1}' | grep -v "$RP" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//' | tr '\n' ' ')"
echo "$(ts) $W 정지"; vagrant halt $W --force >/dev/null 2>&1; S=$(date +%s)
t=$(wait_until 600 "kubectl -n harbor get pods -l component=registry -o wide --no-headers | grep -v $W | grep -q '2/2.*Running'") && \
  echo "$(ts) registry 파드 다른 노드에서 Running: ${t}s 후 → $(kubectl -n harbor get pods -l component=registry -o wide --no-headers | grep Running | awk '{print $1"@"$7}')" || echo "$(ts) [NG] 600s 안에 재기동 안 됨"
echo "    볼륨 상태: $(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.state}/{.status.robustness} node={.status.currentNodeID}')"
# 같은 노드에 core·redis 등이 함께 있었다면 registry 가 떠도 Harbor 는 아직 안 된다 → Harbor health 를 먼저 기다린다
t=$(wait_until 900 harbor_healthy) && echo "$(ts) Harbor 전체 healthy: 정지 후 $(( $(date +%s)-S ))s" || echo "$(ts) [NG] 900s 안에 Harbor healthy 안 됨"
t=$(wait_until 120 pull_ok) && echo "$(ts) 기존 이미지 pull OK (${t}s)" || echo "$(ts) [NG] pull 실패"
echo "$(ts) $W 기동"; B=$(date +%s); vagrant up $W >/dev/null 2>&1
wait_until 300 "node_back $W $B" >/dev/null && echo "$(ts) $W kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $W 복귀 안 됨"
t=$(wait_until 900 "kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.robustness} | grep -qx healthy") && echo "$(ts) 볼륨 복제본 3벌 재구성(healthy) ${t}s"
kubectl get nodes --no-headers | awk '{print "   ",$1,$2}'
__KS_EOF__
chmod +x 'scripts/40-failover.sh'
```

## 15. scripts/50-more-tests.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/50-more-tests.sh' <<'__KS_EOF__'
#!/bin/bash
# 추가 시험 3종 (이 랩 VM 만 정지/기동). 결과 logs/more-tests-<시각>.txt
#   F. BGP VIP 로 push/pull (ToR 에서, 인증 토큰 주소까지 BGP 경로인지 확인)
#   D. Longhorn 복제본 1벌을 가진 워커 정지 → 볼륨 degraded 중 push → 다른 노드에 복제본 재구성 → 노드 복귀 후 정리
#   E. CNPG primary 를 DB 만 있는 워커로 옮긴 뒤 그 워커를 강제 정지 → 승격 → 장애 전환 뒤 쓰기(프로젝트 생성·새 이미지 push) → 복귀·재동기
#   ./scripts/50-more-tests.sh [F] [D] [E]   (인자 없으면 전부)
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
. scripts/harbor-env.sh; BGP=10.250.0.10; TAG=$(cat logs/last-tag)
SRC_IMG=${SRC_IMG:-docker://docker.io/library/busybox:1.37}    # 새 레이어를 쓰기 위한 외부 이미지(Mac 에서 받음)
TESTS=${*:-F D E}
OUT=logs/more-tests-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
push_new(){ skopeo copy -q --override-os linux --override-arch arm64 --dest-tls-verify=false --dest-creds "$HA" "$SRC_IMG" "docker://$HB/$1" >/dev/null 2>&1; }
pull_back(){ rm -rf /tmp/ks-more; skopeo copy -q --src-tls-verify=false --src-creds "$HA" "docker://$HB/$1" dir:/tmp/ks-more >/dev/null 2>&1; }
pod_nodes(){ kubectl -n harbor get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}'; }   # 재시작 표기로 열이 밀리지 않게 jsonpath
harbor_nodes(){ pod_nodes | grep -v '^harbor-pg' | awk '{print $2}' | sort -u; }
pg_nodes(){ pod_nodes | grep '^harbor-pg' | awk '{print $2}' | sort -u; }
pgc(){ kubectl -n harbor get cluster.postgresql.cnpg.io harbor-pg -o jsonpath="$1"; }
V=$(kubectl -n harbor get pvc harbor-registry -o jsonpath='{.spec.volumeName}')
replicas(){ kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$V')]}{.spec.nodeID}({.status.currentState}) {end}"; }

for T in $TESTS; do case $T in
F)
echo "== F. BGP VIP($BGP) 로 push/pull (ToR 에서. ToR 의 /etc/hosts 에 $HH → $BGP 를 넣어 토큰 발급까지 BGP 경로로 가게 한다)"
vagrant ssh ks-tor -c "grep -q ' $HH\$' /etc/hosts || echo '$BGP $HH' | sudo tee -a /etc/hosts >/dev/null" 2>/dev/null
vagrant ssh ks-tor -c 'command -v skopeo >/dev/null || sudo env http_proxy=http://172.16.141.1:3128 https_proxy=http://172.16.141.1:3128 DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::http::Proxy=http://172.16.141.1:3128 install -y -q skopeo >/dev/null 2>&1' 2>/dev/null
cat secrets/harbor-admin | vagrant ssh ks-tor -c "read -r P; C=\"admin:\$P\"; V=$BGP; B=$HH; N=bgp-\$(date +%H%M%S); rm -rf /tmp/bgp1 /tmp/bgp2
echo \"   경로: \$(ip route show \$V | grep -c nexthop) 개 다음 홉(ECMP)\"
echo \"   토큰 주소: \$(curl -sk -o /dev/null -D - https://\$B/v2/ | grep -io 'realm=\"[^\"]*\"')\"
skopeo copy -q --src-tls-verify=false --src-creds \"\$C\" docker://\$B/lab/alpine:$TAG dir:/tmp/bgp1 && echo '   [OK] pull' || echo '   [NG] pull'
skopeo copy -q --dest-tls-verify=false --dest-creds \"\$C\" dir:/tmp/bgp1 docker://\$B/lab/alpine:\$N && echo \"   [OK] push lab/alpine:\$N\" || echo '   [NG] push'
skopeo copy -q --src-tls-verify=false --src-creds \"\$C\" docker://\$B/lab/alpine:\$N dir:/tmp/bgp2 && cmp -s /tmp/bgp1/manifest.json /tmp/bgp2/manifest.json && echo '   [OK] 되받은 manifest 동일' || echo '   [NG] 되받기/비교 실패'" 2>/dev/null | tr -d '\r'
;;
D)
echo; echo "== D. Longhorn 복제본 재구성 (볼륨 $V = harbor-registry)"
CUR=$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.currentNodeID}')
N=""; for r in $(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$V')]}{.spec.nodeID}{' '}{end}"); do
  [ "$r" != "$CUR" ] && ! harbor_nodes | grep -qx "$r" && ! pg_nodes | grep -qx "$r" && { N=$r; break; }; done
[ -z "$N" ] && { echo "   [SKIP] Harbor 파드가 없는 복제본 노드가 없음"; continue; }
echo "$(ts) 복제본: $(replicas)  / 볼륨 부착 노드 $CUR → $N 정지"
vagrant halt $N --force >/dev/null 2>&1; S=$(date +%s)
t=$(wait_until 180 "kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.robustness} | grep -qx degraded") && echo "$(ts) 볼륨 degraded (${t}s)"
NEW=lab/busybox:degraded-$(date +%H%M%S)
push_new $NEW && echo "$(ts) [OK] degraded 상태에서 새 이미지 push ($NEW)" || echo "$(ts) [NG] degraded 중 push 실패"
t=$(wait_until 900 "kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.robustness} | grep -qx healthy") \
  && echo "$(ts) 볼륨 healthy 복귀: 정지 후 $(( $(date +%s)-S ))s, 복제본: $(replicas)" || echo "$(ts) [NG] 900s 안에 재구성 안 됨: $(replicas)"
pull_back $NEW && echo "$(ts) [OK] 재구성 후 그 이미지 pull" || echo "$(ts) [NG] pull 실패"
echo "$(ts) $N 기동"; B=$(date +%s); vagrant up $N >/dev/null 2>&1
wait_until 300 "node_back $N $B" >/dev/null && echo "$(ts) $N kubelet 복귀"
wait_until 180 "! kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath=\"{range .items[?(@.spec.volumeName=='$V')]}{.status.currentState}{' '}{end}\" | grep -qv running" >/dev/null
echo "$(ts) 노드 복귀 후 복제본: $(replicas)"
;;
E)
echo; echo "== E. CNPG primary 노드 강제 정지 + 장애 전환 뒤 쓰기"
X=""; for p in $(kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
  n=$(kubectl -n harbor get pod $p -o jsonpath='{.spec.nodeName}'); harbor_nodes | grep -qx $n || { X=$p; XN=$n; break; }; done
[ -z "$X" ] && { echo "   [SKIP] Harbor 다른 파드와 겹치지 않는 DB 노드가 없음"; continue; }
if [ "$(pgc '{.status.currentPrimary}')" != "$X" ]; then
  echo "$(ts) switchover → $X ($XN)  (kubectl cnpg promote 와 같은 status 패치)"
  kubectl -n harbor patch cluster.postgresql.cnpg.io harbor-pg --subresource=status --type=merge \
    -p "{\"status\":{\"targetPrimary\":\"$X\",\"targetPrimaryTimestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"phase\":\"Switchover in progress\",\"phaseReason\":\"test switchover to $X\"}}" >/dev/null
  t=$(wait_until 180 "[ \"\$(pgc '{.status.currentPrimary}')\" = $X ] && [ \"\$(pgc '{.status.readyInstances}')\" = 3 ]") && echo "$(ts) switchover 완료 ${t}s" || echo "$(ts) [NG] switchover 안 됨"
fi
echo "$(ts) primary $X @ $XN → $XN 강제 정지"
vagrant halt $XN --force >/dev/null 2>&1; S=$(date +%s)
t=$(wait_until 300 "pgc '{.status.currentPrimary}' | grep -vqx $X") && echo "$(ts) 새 primary $(pgc '{.status.currentPrimary}'): 정지 후 $(( $(date +%s)-S ))s" || echo "$(ts) [NG] 300s 안에 승격 안 됨"
P=fo$(date +%H%M%S)
t=$(wait_until 120 "hcurl -o /dev/null -w '%{http_code}' -u '$HA' -H 'Content-Type: application/json' -X POST $HU/api/v2.0/projects -d '{\"project_name\":\"$P\",\"public\":false}' | grep -qE '201|409'") \
  && echo "$(ts) [OK] 프로젝트 생성(DB 쓰기) $P: 정지 후 $(( $(date +%s)-S ))s" || echo "$(ts) [NG] 프로젝트 생성 실패"
push_new $P/busybox:after-failover && echo "$(ts) [OK] 새 프로젝트에 이미지 push" || echo "$(ts) [NG] push 실패"
pull_back $P/busybox:after-failover && echo "$(ts) [OK] 되받기" || echo "$(ts) [NG] 되받기 실패"
echo "$(ts) $XN 기동"; B=$(date +%s); vagrant up $XN >/dev/null 2>&1
wait_until 300 "node_back $XN $B" >/dev/null && echo "$(ts) $XN kubelet 복귀"
t=$(wait_until 600 "kubectl -n harbor get pod $X -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True") && echo "$(ts) $X 파드 Ready (기동 후 $(( $(date +%s)-B ))s)"
NP=$(pgc '{.status.currentPrimary}')
wait_until 300 "[ \$(kubectl -n harbor exec $NP -c postgres -- psql -tAc \"select count(*) from pg_stat_replication where state='streaming'\") = 2 ]" >/dev/null
echo "$(ts) primary $NP 의 복제 상태:"; kubectl -n harbor exec $NP -c postgres -- psql -tAc "select application_name,state,sync_state from pg_stat_replication" | sed 's/^/    /'
kubectl -n harbor exec $NP -c postgres -- psql -d registry -tAc "select count(*) from project where name='$P'" | sed "s/^/    프로젝트 $P 행 수(primary): /"
R=$(kubectl -n harbor get pods -l cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
kubectl -n harbor exec $R -c postgres -- psql -d registry -tAc "select count(*) from project where name='$P'" | sed "s/^/    같은 행 수(replica $R): /"
;;
esac; done
echo; echo "== 마무리 상태"
kubectl get nodes --no-headers | awk '{printf "%s=%s ",$1,$2}'; echo
echo "CNPG: $(pgc '{.status.phase}') primary=$(pgc '{.status.currentPrimary}') ready=$(pgc '{.status.readyInstances}')"
echo "registry 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.robustness}')  $(replicas)"
__KS_EOF__
chmod +x 'scripts/50-more-tests.sh'
```

## 16. scripts/60-db-node-loss.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/60-db-node-loss.sh' <<'__KS_EOF__'
#!/bin/bash
# DB 인스턴스가 있던 워커가 "돌아오지 않는" 경우 (이 랩 VM 만 정지/기동). 결과 logs/db-node-loss-<시각>.txt
#   G1. standby 인스턴스가 있는 워커 강제 정지 → OBS 초 동안 관찰: CNPG 가 스스로 다른 노드에 새 인스턴스를 만드는가, 그동안 DB 쓰기는 되는가
#   G2. 영구 손실 절차: 그 인스턴스의 PVC + 파드 삭제 → 다른 워커에 새 인스턴스가 생기는가(소요 시간, 복제 연결 수)
#   G3. 꺼 두었던 워커 기동 → 옛 볼륨(PV Retain)이 어떻게 남는가
# 근거: CNPG docs failure_modes.md "Standby Failure"(PVC 가 있으면 그 PVC 로 재기동, 없으면 primary 에서 새로 만든다),
#       troubleshooting.md "delete the PVC and let the operator rebuild the replica"
#   OBS=420 ./scripts/60-db-node-loss.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
. scripts/harbor-env.sh; OBS=${OBS:-420}; NS=harbor; CL=harbor-pg
OUT=logs/db-node-loss-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
pgc(){ kubectl -n $NS get cluster $CL -o jsonpath="$1"; }
inst(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.metadata.name}{"@"}{.spec.nodeName}{"("}{.metadata.labels.cnpg\.io/instanceRole}{","}{.status.phase}{") "}{end}'; }
pvcs(){ kubectl -n $NS get pvc -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{" "}{end}'; }
streaming(){ kubectl -n $NS exec "$(pgc '{.status.currentPrimary}')" -c postgres -- psql -tAc "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null; }
# 주의: macOS 기본 bash 3.2 는 "$( … \"…\" … )" 안의 이스케이프 따옴표를 잘못 쪼갠다("[: too many arguments") → 본문은 변수에, 결과도 변수에 받아서 비교
db_write(){ local n=g$(date +%s) body c; body=$(printf '{"project_name":"%s","public":false}' "$n")
  c=$(hcurl -m 8 -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$HU/api/v2.0/projects" -H 'Content-Type: application/json' -d "$body")
  [ "$c" = 201 ] || return 1; hcurl -m 8 -o /dev/null -u "$HA" -X DELETE "$HU/api/v2.0/projects/$n"; return 0; }

echo "== 사전 상태"
echo "CNPG: phase='$(pgc '{.status.phase}')' primary=$(pgc '{.status.currentPrimary}') instances=$(pgc '{.status.instances}') ready=$(pgc '{.status.readyInstances}')"
echo "인스턴스: $(inst)"; echo "PVC: $(pvcs)"; echo "복제 streaming: $(streaming)"
[ "$(pgc '{.status.readyInstances}')" = 3 ] || { echo "[중단] ready 3 이 아님"; exit 1; }
P=$(pgc '{.status.currentPrimary}')
# standby 중, 그 노드에 Harbor 파드가 가장 적은 것을 고른다(다른 영향과 섞이지 않게)
X=""; XN=""; best=999
for p in $(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.name}'); do [ $p = $P ] && continue
  n=$(kubectl -n $NS get pod $p -o jsonpath='{.spec.nodeName}'); c=$(kubectl -n $NS get pods --field-selector spec.nodeName=$n --no-headers | grep -vc "^$CL-")
  [ $c -lt $best ] && { best=$c; X=$p; XN=$n; }; done
ORIG=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.name}'); ORIGUID=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.uid}')
PV=$(kubectl -n $NS get pvc $X -o jsonpath='{.spec.volumeName}')
echo "대상: standby $X @ $XN (그 노드의 다른 harbor 파드 $best 개), PV $PV, Longhorn 복제본 위치: $(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath="{range .items[?(@.spec.volumeName=='$PV')]}{.spec.nodeID} {end}")"
echo "DB 가 없는 워커: $(comm -23 <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|node/||' | sort) <(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort) | tr '\n' ' ')"

echo; echo "== G1. $XN 강제 정지 후 ${OBS}s 관찰 (아무것도 손대지 않음)"
vagrant halt $XN --force >/dev/null 2>&1; S=$(date +%s); echo "$(ts) $XN 정지"
W1=""; while [ $(( $(date +%s)-S )) -lt $OBS ]; do
  e=$(( $(date +%s)-S ))
  [ -z "$W1" ] && [ $e -ge 20 ] && { db_write && W1="OK(${e}s)" || W1=""; [ -n "$W1" ] && echo "$(ts) +${e}s DB 쓰기(프로젝트 생성) $W1"; }
  echo "$(ts) +${e}s node=$(kubectl get node $XN --no-headers | awk '{print $2}') pod=$(kubectl -n $NS get pod $X --no-headers 2>/dev/null | awk '{print $2"/"$3}') phase='$(pgc '{.status.phase}')' ready=$(pgc '{.status.readyInstances}')/$(pgc '{.status.instances}') streaming=$(streaming) pods=[$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{.items[*].metadata.name}')]"
  sleep 30; done
NEW=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}' | awk -v u="$ORIGUID" 'index(u,$2)==0{print $1}')
[ -z "$NEW" ] && echo "$(ts) 결과: ${OBS}s 동안 새 인스턴스가 만들어지지 않음. PVC: $(pvcs)" || echo "$(ts) 결과: 새 인스턴스가 스스로 생김 → $NEW"
db_write && echo "$(ts) DB 쓰기 OK (standby 1개 없는 상태)" || echo "$(ts) [NG] DB 쓰기 실패"
kubectl -n $NS get events --field-selector involvedObject.name=$X --sort-by=.lastTimestamp 2>/dev/null | tail -4 | sed 's/^/    /'

echo; echo "== G2. 영구 손실 절차: PVC + 파드 삭제"
T=$(date +%s)
kubectl -n $NS delete pvc $X --wait=false | sed 's/^/    /'
kubectl -n $NS delete pod $X --force --grace-period=0 2>&1 | grep -v Warning | sed 's/^/    /'
joinpod(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/jobRole --no-headers 2>/dev/null | grep -q .; }
t=$(wait_until 600 joinpod) && echo "$(ts) 새 인스턴스 생성 작업(join) 시작: ${t}s" || { echo "$(ts) [NG] 600s 안에 생성 작업 없음"; kubectl -n $NS get pods,pvc,jobs | sed 's/^/    /'; }
# 새 인스턴스 = cnpg.io/instanceName 라벨이 붙은 파드 중, 꺼진 노드가 아닌 곳에서 Ready 이고 원래 있던 UID 가 아닌 것
newinst(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/podRole=instance -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | awk -v u="$ORIGUID" -v xn=$XN 'index(u,$2)==0 && $3!=xn && $4=="True"{print $1"@"$3; f=1} END{exit !f}'; }
t=$(wait_until 900 newinst) && echo "$(ts) 새 인스턴스 Ready: $(newinst) — 삭제 후 $(( $(date +%s)-T ))s" || { echo "$(ts) [NG] 900s 안에 새 인스턴스 Ready 안 됨"; kubectl -n $NS get pods,pvc,jobs | sed 's/^/    /'; }
t=$(wait_until 300 "[ \$(streaming) = 2 ]") && echo "$(ts) 복제 2개 streaming — 삭제 후 $(( $(date +%s)-T ))s"
kubectl -n $NS exec "$(pgc '{.status.currentPrimary}')" -c postgres -- psql -tAc "select application_name,state,sync_state from pg_stat_replication" | sed 's/^/    /'
echo "인스턴스: $(inst)"; echo "PVC: $(pvcs)"
echo "옛 PV $PV: $(kubectl get pv $PV -o jsonpath='{.status.phase} reclaim={.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || echo 없음) / Longhorn 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}' 2>/dev/null || echo 없음)"

echo; echo "== G3. $XN 기동"
B=$(date +%s); vagrant up $XN >/dev/null 2>&1
wait_until 300 "node_back $XN $B" >/dev/null && echo "$(ts) $XN kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $XN 복귀 안 됨"
sleep 60
echo "CNPG: phase='$(pgc '{.status.phase}')' primary=$(pgc '{.status.currentPrimary}') instances=$(pgc '{.status.instances}') ready=$(pgc '{.status.readyInstances}')"
echo "인스턴스: $(inst)"; echo "PVC: $(pvcs)"
echo "옛 PV $PV: $(kubectl get pv $PV -o jsonpath='{.status.phase}' 2>/dev/null || echo 없음) / Longhorn 볼륨: $(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}' 2>/dev/null || echo 없음) (지우지 않고 남겨 둠)"
kubectl get nodes --no-headers | awk '{print "   ",$1,$2}'
__KS_EOF__
chmod +x 'scripts/60-db-node-loss.sh'
```

## 17. scripts/61-db-move-instance.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/61-db-move-instance.sh' <<'__KS_EOF__'
#!/bin/bash
# 계획된 노드 제거/교체 전에, 그 노드에 있는 DB standby 인스턴스를 다른 워커로 옮긴다. 결과 logs/db-move-<시각>.txt
#   전제: 그 인스턴스가 있는 노드를 먼저 cordon 해 둔다 (새 인스턴스가 같은 노드로 돌아오지 않게). primary 는 대상이 아니다(먼저 switchover).
#   방법: 그 인스턴스의 PVC + 파드 삭제 → operator 가 primary 에서 받아 다른 노드에 새로 만든다. 볼륨이 노드 로컬(strict-local)이라 "이동"이 아니라 "다시 만들기"다.
#   근거: CNPG docs troubleshooting.md "delete the PVC and let the operator rebuild the replica" (kubectl cnpg destroy 와 같은 동작)
#   옛 PV 는 reclaim=Retain 이라 Released 로 남는다 → 확인 후 따로 지운다(이 스크립트는 지우지 않음).
#   ./scripts/61-db-move-instance.sh harbor-pg-2
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
X=${1:?옮길 인스턴스 이름}; . scripts/harbor-env.sh; NS=harbor; CL=harbor-pg
OUT=logs/db-move-$(date +%m%d-%H%M).txt; exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
pgc(){ kubectl -n $NS get cluster $CL -o jsonpath="$1"; }
inst(){ kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/podRole=instance -o jsonpath='{range .items[*]}{.metadata.name}{"@"}{.spec.nodeName}{"("}{.metadata.labels.cnpg\.io/instanceRole}{","}{.status.phase}{") "}{end}'; }
streaming(){ kubectl -n $NS exec "$(pgc '{.status.currentPrimary}')" -c postgres -- psql -tAc "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null; }
# bash 3.2(macOS) 따옴표 문제 때문에 본문·결과를 변수로 받는다 (60-db-node-loss.sh 와 같은 이유)
db_write(){ local n=m$(date +%s) body c; body=$(printf '{"project_name":"%s","public":false}' "$n")
  c=$(hcurl -m 8 -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$HU/api/v2.0/projects" -H 'Content-Type: application/json' -d "$body")
  [ "$c" = 201 ] || return 1; hcurl -m 8 -o /dev/null -u "$HA" -X DELETE "$HU/api/v2.0/projects/$n"; return 0; }

P=$(pgc '{.status.currentPrimary}'); XN=$(kubectl -n $NS get pod $X -o jsonpath='{.spec.nodeName}'); XUID=$(kubectl -n $NS get pod $X -o jsonpath='{.metadata.uid}')
PV=$(kubectl -n $NS get pvc $X -o jsonpath='{.spec.volumeName}')
echo "== 사전 상태"
echo "CNPG: phase='$(pgc '{.status.phase}')' primary=$P ready=$(pgc '{.status.readyInstances}')/$(pgc '{.status.instances}') streaming=$(streaming)"
echo "인스턴스: $(inst)"
echo "대상: $X @ $XN, PV $PV"
[ "$X" != "$P" ] || { echo "[중단] $X 는 primary. 먼저 switchover"; exit 1; }
[ "$(pgc '{.status.readyInstances}')" = "$(pgc '{.status.instances}')" ] || { echo "[중단] 모든 인스턴스가 ready 가 아님 — 하나를 더 빼면 동기 복제 대상이 없어 쓰기가 멈춘다"; exit 1; }
[ "$(kubectl get node $XN -o jsonpath='{.spec.unschedulable}')" = true ] || { echo "[중단] $XN 이 cordon 되어 있지 않음 (새 인스턴스가 같은 노드로 돌아올 수 있다)"; exit 1; }
db_write && echo "쓰기 확인(사전): OK" || { echo "[중단] 사전 쓰기 실패"; exit 1; }

echo; echo "== $X 의 PVC + 파드 삭제"
T=$(date +%s)
kubectl -n $NS delete pvc $X --wait=false 2>&1 | sed 's/^/    /'
kubectl -n $NS delete pod $X --wait=false 2>&1 | sed 's/^/    /'
ok=0; ng=0; done_at=""; join_at=""
while :; do
  e=$(( $(date +%s)-T ))
  db_write && { ok=$((ok+1)); w=OK; } || { ng=$((ng+1)); w=NG; }
  [ -z "$join_at" ] && kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/jobRole --no-headers 2>/dev/null | grep -q . && join_at=$e
  new=$(kubectl -n $NS get pods -l cnpg.io/cluster=$CL,cnpg.io/podRole=instance,cnpg.io/instanceName=$X -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk -v u=$XUID '$1!=u{print $2" "$3}')
  s=$(streaming); ph=$(pgc '{.status.phase}')
  echo "$(ts) +${e}s 쓰기=$w streaming=${s:-?} phase='$ph' 새 $X: ${new:-없음}"
  if [ "${new#* }" = True ] && [ "$s" = 2 ] && [ "$ph" = "Cluster in healthy state" ]; then done_at=$e; break; fi
  [ $e -ge 900 ] && break
  sleep 4
done
echo
[ -n "$done_at" ] && echo "$(ts) 결과: 새 $X 가 ${new% *} 에서 Ready + 복제 2개 streaming — 삭제 후 ${done_at}s (join 작업 시작 ${join_at:-?}s)" || echo "$(ts) [NG] 900s 안에 복구 안 됨"
echo "그동안 쓰기: 성공 $ok / 실패 $ng"
echo "인스턴스: $(inst)"
echo "옛 PV $PV: $(kubectl get pv $PV -o jsonpath='{.status.phase} reclaim={.spec.persistentVolumeReclaimPolicy}' 2>/dev/null) (지우지 않고 남겨 둠, 복제본은 $XN 에 있음)"
__KS_EOF__
chmod +x 'scripts/61-db-move-instance.sh'
```

## 18. scripts/62-ingress-failover.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/62-ingress-failover.sh' <<'__KS_EOF__'
#!/bin/bash
# 진입점(ingress-nginx VIP) 시험 (이 랩 VM 만 정지/기동). 결과 logs/ingress-<시각>.txt, 1초 간격 탐침 기록 logs/ingress-probe-<시각>.txt
#   K. 큰 요청 본문: Ingress 의 proxy-body-size 를 1m 로 줄였다가 되돌리며 3MB 업로드 응답 코드를 본다 (Harbor 차트 기본값 "0" = 제한 없음)
#   L. VIP 를 ARP 로 알리는 워커 정지 → 다른 워커가 VIP 를 넘겨받을 때까지 끊기는 시간
#   M. ingress-nginx 컨트롤러 파드가 있는 워커(VIP 를 알리는 노드가 아닌 것) 정지 → 남은 컨트롤러로만 갈 때까지 실패하는 요청
#   ./scripts/62-ingress-failover.sh [K] [L] [M]   (인자 없으면 전부)
# 탐침 두 가지: nginx = VIP 에 호스트명 없이 요청(컨트롤러 자체가 404 로 답함, Harbor 와 무관), harbor = Harbor ping(컨트롤러 → core 까지)
# registry·jobservice 까지는 10초마다 찍는 상태 줄의 Harbor=(health API)로 본다
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/${INVENTORY:-inventory/lab}/artifacts/admin.conf
. scripts/harbor-env.sh
TESTS=${*:-K L M}; DOWN=${DOWN:-150}
STAMP=$(date +%m%d-%H%M); OUT=logs/ingress-$STAMP.txt; PR=logs/ingress-probe-$STAMP.txt; mkdir -p logs
exec > >(tee "$OUT") 2>&1
ts(){ date +%H:%M:%S; }
LEASE=cilium-l2announce-ingress-nginx-ingress-nginx-controller
holder(){ kubectl -n kube-system get lease $LEASE -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
health(){ hcurl -m 3 $HU/api/v2.0/health 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);b=[c['name'] for c in d['components'] if c['status']!='healthy'];print(d['status']+('('+','.join(b)+')' if b else ''))" 2>/dev/null || echo 응답없음; }
ctl_nodes(){ kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{range .items[*]}{.spec.nodeName}{"("}{.status.phase}{") "}{end}'; }
on_node(){ kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | awk -v n=$1 '$1==n{print $2}' | grep -E '^(harbor|ingress-nginx|cnpg-system)/' | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//' | tr '\n' ' '; }
node_back(){ local n=$1 since=$2; kubectl get node $n --no-headers | grep -qw Ready || return 1
  local r=$(kubectl -n kube-node-lease get lease $n -o jsonpath='{.spec.renewTime}'); [ -n "$r" ] || return 1
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $since ]; }
wait_until(){ local max=$1; shift; local s=$(date +%s); while ! eval "$@" >/dev/null 2>&1; do sleep 3; [ $(( $(date +%s)-s )) -ge $max ] && return 1; done; echo $(( $(date +%s)-s )); }
probe(){ while :; do
    a=$(curl -sk -m 2 -o /dev/null -w '%{http_code}' https://$HV/); b=$(hcurl -m 2 -o /dev/null -w '%{http_code}' $HU/api/v2.0/ping)
    echo "$(date +%s) $(ts) nginx=$a harbor=$b"; sleep 1; done >> "$PR"; }
# 탐침 기록에서 [from,to] 구간의 실패(nginx 404 아님 / harbor 200 아님)를 센다
summary(){ awk -v f=$1 -v t=$2 '$1>=f && $1<=t { n++; split($3,a,"="); split($4,b,"=");
    if (a[2]!="404") { na++; if(!fa) fa=$2; la=$2 }  if (b[2]!="200") { nb++; if(!fb) fb=$2; lb=$2 } }
  END { printf "    탐침 %d번: nginx 실패 %d번%s, harbor 실패 %d번%s\n", n, na, (na? " ("fa"~"la")":""), nb, (nb? " ("fb"~"lb")":"") }' "$PR"; }
stop_node(){ # $1=노드
  local N=$1; echo "$(ts) $N 에 있던 것: $(on_node $N)"
  probe & PP=$!; sleep 10
  S=$(date +%s); echo "$(ts) $N 강제 정지"; vagrant halt $N --force >/dev/null 2>&1
  local e; while e=$(( $(date +%s)-S )); [ $e -lt $DOWN ]; do
    echo "$(ts) +${e}s VIP 알리는 노드=$(holder) 컨트롤러=[$(ctl_nodes)] 노드=$(kubectl get node $N --no-headers 2>/dev/null | awk '{print $2}') Harbor=$(health)"; sleep 10; done
  E=$(date +%s); echo "$(ts) 정지 중 ${DOWN}s:"; summary $S $E
  echo "$(ts) $N 기동"; B=$(date +%s); vagrant up $N >/dev/null 2>&1
  wait_until 300 "node_back $N $B" >/dev/null && echo "$(ts) $N kubelet 복귀(기동 명령 후 $(( $(date +%s)-B ))s)" || echo "$(ts) [NG] $N 복귀 안 됨"
  wait_until 600 "[ \"\$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.phase} {.status.readyInstances}')\" = 'Cluster in healthy state 3' ] && [ \$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller --no-headers | grep -c '1/1.*Running') -ge 3 ]" >/dev/null \
    && echo "$(ts) DB 3/3, 컨트롤러 3개 Running: [$(ctl_nodes)]" || echo "$(ts) [NG] 600s 안에 원상 복귀 안 됨: [$(ctl_nodes)]"
  # ping 은 core 까지만 본다. registry·jobservice 는 볼륨을 다시 붙여야 해서 더 늦게 돌아온다(health API 로 확인)
  wait_until 600 "[ \"\$(health)\" = healthy ]" >/dev/null && echo "$(ts) Harbor health 전 구성요소 healthy (기동 명령 후 $(( $(date +%s)-B ))s, 정지 후 $(( $(date +%s)-S ))s)" || echo "$(ts) [NG] Harbor health: $(health)"
  sleep 5; kill $PP 2>/dev/null; wait $PP 2>/dev/null
  echo "$(ts) 기동 뒤:"; summary $E $(date +%s)
}

for T in $TESTS; do case $T in
K)
echo "== K. 큰 요청 본문 (3MB 업로드)"
head -c 3000000 /dev/urandom > /tmp/ks-body.bin
up(){ local loc; loc=$(hcurl -m 10 -u "$HA" -X POST -o /dev/null -D - $HU/v2/lab/bodytest/blobs/uploads/ | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
  case "$loc" in /*) loc=$HU$loc;; esac
  hcurl -m 30 -u "$HA" -X PATCH -H 'Content-Type: application/octet-stream' --data-binary @/tmp/ks-body.bin -o /dev/null -w '%{http_code}' "$loc"; }
cur(){ kubectl -n harbor get ingress harbor-ingress -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/proxy-body-size}'; }
echo "$(ts) proxy-body-size=$(cur) → 업로드 응답 $(up)   (202 = 받음)"
kubectl -n harbor annotate ingress harbor-ingress nginx.ingress.kubernetes.io/proxy-body-size=1m --overwrite >/dev/null; sleep 8
echo "$(ts) proxy-body-size=$(cur) → 업로드 응답 $(up)   (413 = nginx 가 크기 초과로 거절)"
kubectl -n harbor annotate ingress harbor-ingress nginx.ingress.kubernetes.io/proxy-body-size=0 --overwrite >/dev/null; sleep 8
echo "$(ts) proxy-body-size=$(cur) 로 되돌림 → 업로드 응답 $(up)"
rm -f /tmp/ks-body.bin
;;
L)
echo; echo "== L. VIP $HV 를 ARP 로 알리는 워커 정지"
N=$(holder); echo "$(ts) VIP 알리는 노드: $N / 컨트롤러: [$(ctl_nodes)]"
stop_node $N
echo "    지금 VIP 알리는 노드: $(holder)"
;;
M)
echo; echo "== M. 컨트롤러 파드가 있는 워커 정지 (VIP 를 알리는 노드 제외, DB primary 노드 제외)"
H=$(holder); PN=$(kubectl -n harbor get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].spec.nodeName}')
N=""; for c in $(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort); do
  [ "$c" != "$H" ] && [ "$c" != "$PN" ] && { N=$c; break; }; done
[ -z "$N" ] && { echo "   [SKIP] 조건에 맞는 노드 없음"; continue; }
echo "$(ts) VIP 알리는 노드: $H / 컨트롤러: [$(ctl_nodes)] → $N 정지"
stop_node $N
;;
esac; done
echo; echo "== 마무리"; kubectl get nodes --no-headers | awk '{printf "%s=%s ",$1,$2}'; echo
echo "VIP 알리는 노드=$(holder) 컨트롤러=[$(ctl_nodes)] DB=$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.phase} {.status.readyInstances}/{.status.instances}')"
__KS_EOF__
chmod +x 'scripts/62-ingress-failover.sh'
```

## 19. scripts/addon.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/addon.sh' <<'__KS_EOF__'
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
__KS_EOF__
chmod +x 'scripts/addon.sh'
```

## 20. scripts/harbor-env.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/harbor-env.sh' <<'__KS_EOF__'
# Harbor 접속 정보. 시험 스크립트가 source 해서 쓴다 (랩 디렉터리에서 실행). 인벤토리의 ingress_vip / harbor_host 와 같아야 한다.
#   경로: 밖 → ingress-nginx VIP:443 → 호스트명으로 Harbor Ingress → core/portal
#   curl 은 --resolve 로 VIP 를 직접 지정해 DNS 없이도 된다. skopeo 는 이름을 풀 수 있어야 한다(랩: sslip.io, 실서버: 사내 DNS 또는 /etc/hosts)
#   실서버: INGRESS_VIP=<VIP> HARBOR_HOST=<호스트명> ./scripts/30-verify.sh
HV=${INGRESS_VIP:-172.16.141.211}
HH=${HARBOR_HOST:-harbor.$HV.sslip.io}
HB=$HH                    # skopeo 용 (docker://$HB/…)
HU=https://$HH            # API 주소
HA="admin:$(cat secrets/harbor-admin)"
hcurl(){ curl -sk --resolve "$HH:443:$HV" "$@"; }
__KS_EOF__
```

## 21. scripts/lab-proxy.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/lab-proxy.sh' <<'__KS_EOF__'
#!/bin/bash
# (랩 전용) VMware NAT(vmnet-natd)가 안 될 때, Mac 의 host-only 주소에 HTTP 프록시를 띄워 노드가 인터넷에 나가게 한다.
# 인벤토리 http_proxy/https_proxy 가 이 주소를 가리킨다. Mac 재부팅 시 사라지므로 다시 실행. 근본 해결은 TROUBLESHOOTING 2절.
#   ./scripts/lab-proxy.sh          # 시작(이미 떠 있으면 그대로)
#   ./scripts/lab-proxy.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."
ADDR=${PROXY_ADDR:-172.16.141.1}; PORT=${PROXY_PORT:-3128}
if [ "${1:-}" = stop ]; then pkill -f "bin/proxy --hostname $ADDR --port $PORT" && echo "중지" || echo "떠 있지 않음"; exit 0; fi
if (exec 3<>/dev/tcp/$ADDR/$PORT) 2>/dev/null; then echo "이미 응답 중: $ADDR:$PORT"; exit 0; fi
. .venv/bin/activate
command -v proxy >/dev/null || pip -q install proxy.py
mkdir -p logs
nohup proxy --hostname $ADDR --port $PORT > logs/lab-proxy.log 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/$ADDR/$PORT) 2>/dev/null && { echo "프록시 시작: http://$ADDR:$PORT"; exit 0; }; sleep 1; done
echo "시작 실패: logs/lab-proxy.log 확인"; exit 1
__KS_EOF__
chmod +x 'scripts/lab-proxy.sh'
```

## 22. scripts/make-bundle.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/make-bundle.sh' <<'__KS_EOF__'
#!/usr/bin/env bash
# BUNDLE.md 생성: 다운로드·git clone 이 안 되는 곳으로 코드를 복사·붙여넣기로 옮기기 위한 문서.
#   파일마다 블럭 하나 = 그 파일을 만드는 셸 명령(heredoc). 마지막 블럭은 sha256 대조.
#   ./scripts/make-bundle.sh            → BUNDLE.md 생성
#   ./scripts/make-bundle.sh --check    → BUNDLE.md 를 빈 디렉터리에 풀어 원본과 대조
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - "${1:-}" <<'PY'
import os, sys, hashlib, subprocess, tempfile, filecmp
D = '__KS_' + 'EOF__'          # heredoc 구분자 (이 파일 안에 그 줄이 그대로 나오지 않게 나눠 씀)
SKIP_DIRS = {'kubespray', '.venv', '.vagrant', 'secrets', 'logs', 'notes', '.git', 'artifacts', 'credentials', 'rendered'}
SKIP_FILES = {'ssh.cfg', 'BUNDLE.md'}
files = []
for root, dirs, names in os.walk('.'):
    dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
    for n in sorted(names):
        if n in SKIP_FILES or n.endswith('.md') or n == '.DS_Store':
            continue
        files.append(os.path.relpath(os.path.join(root, n)))
order = lambda p: (p.count('/'), p)
files.sort(key=order)

def check_file(p, data):
    lines = data.split('\n')
    if D in lines: sys.exit(f'{p}: heredoc 구분자와 같은 줄이 있다')
    if any(l.startswith('```') for l in lines): sys.exit(f'{p}: ``` 로 시작하는 줄이 있다 (마크다운 블럭이 깨짐)')
    if not data.endswith('\n'): sys.exit(f'{p}: 마지막 줄바꿈이 없다 (heredoc 이 줄바꿈을 붙여 sha256 이 달라짐)')

if sys.argv[1] == '--check':
    src = open('BUNDLE.md').read()
    blocks, cur = [], None
    for line in src.split('\n'):
        if cur is None and line == '```bash': cur = []
        elif cur is not None and line == '```': blocks.append('\n'.join(cur)); cur = None
        elif cur is not None: cur.append(line)
    with tempfile.TemporaryDirectory() as t:
        script = '\n'.join(blocks[1:]) + '\n'          # 0번은 README 안내용 mkdir 블럭
        r = subprocess.run(['bash', '-e'], input=script, text=True, cwd=t, capture_output=True)
        print(r.stdout[-3000:], r.stderr[-2000:])
        bad = [p for p in files if not filecmp.cmp(p, os.path.join(t, p), shallow=False)]
        modes = [p for p in files if os.access(p, os.X_OK) != os.access(os.path.join(t, p), os.X_OK)]
        print(f'파일 {len(files)}개, 내용 불일치 {len(bad)} {bad}, 실행권한 불일치 {len(modes)} {modes}, bash rc={r.returncode}')
        sys.exit(1 if bad or modes or r.returncode else 0)

out = []
w = out.append
w('# 코드 묶음 (붙여넣기용)\n')
w('다운로드·`git clone` 이 안 되는 곳으로 이 디렉터리를 옮길 때 쓴다. `scripts/make-bundle.sh` 가 만든 파일이므로 직접 고치지 않는다.\n')
w('1. 빈 디렉터리를 만들고 들어간다.\n')
w('```bash\nmkdir -p ~/kubespray-cluster && cd ~/kubespray-cluster\n```\n')
w('2. 아래 블럭을 위에서부터 차례로 복사해 터미널에 붙여넣는다. 블럭 하나가 파일 하나를 만든다. 붙여넣기가 불안하면 블럭들을 편집기로 `bundle.sh` 한 파일에 모은 뒤 `bash bundle.sh` 로 실행한다.\n')
w('3. 맨 아래 sha256 대조 블럭을 붙여넣어 모든 줄이 `OK` 인지 확인한다.\n')
w(f'파일 {len(files)}개. 문서(README·INFRA·TROUBLESHOOTING)는 GitHub 화면에서 바로 읽으면 되므로 넣지 않았다.\n')
w('| # | 파일 | 줄 수 |\n|---|---|---|')
datas = {}
for i, p in enumerate(files, 1):
    data = open(p, encoding='utf-8').read(); check_file(p, data); datas[p] = data
    w(f'| {i} | [{p}](#{i}-{p.replace("/", "").replace(".", "").replace("_", "_").lower()}) | {data.count(chr(10))} |')
w('')
for i, p in enumerate(files, 1):
    w(f'## {i}. {p}\n')
    w('```bash')
    d = os.path.dirname(p)
    if d: w(f"mkdir -p '{d}'")
    w(f"cat > '{p}' <<'{D}'")
    out.append(datas[p].rstrip('\n'))
    w(D)
    if os.access(p, os.X_OK): w(f"chmod +x '{p}'")
    w('```\n')
w('## sha256 대조\n')
w('리눅스는 `sha256sum -c`, macOS 는 `shasum -a 256 -c`. 모든 줄이 `OK` 여야 한다.\n')
w('```bash')
w(f"sha256sum -c <<'{D}'")
for p in files: w(f'{hashlib.sha256(datas[p].encode()).hexdigest()}  {p}')
w(D)
w('```')
open('BUNDLE.md', 'w').write('\n'.join(out) + '\n')
print(f'BUNDLE.md: 파일 {len(files)}개, {os.path.getsize("BUNDLE.md")} bytes')
PY
__KS_EOF__
chmod +x 'scripts/make-bundle.sh'
```

## 23. scripts/render-values.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/render-values.sh' <<'__KS_EOF__'
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
__KS_EOF__
chmod +x 'scripts/render-values.sh'
```

## 24. scripts/rolling-reload.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/rolling-reload.sh' <<'__KS_EOF__'
#!/bin/bash
# (랩) 노드를 한 대씩 재기동(vagrant reload) — Vagrantfile 의 메모리 변경 반영 + 쿼럼 유지 확인
#   ./scripts/rolling-reload.sh ks-cp3 ks-cp2 ks-cp1
#   W_MEM=2688 WAIT_DB=1 ./scripts/rolling-reload.sh ks-w1 ks-w2     # 워커: 다음 노드로 넘어가기 전에 DB 3/3 + 붙어 있는 Longhorn 볼륨 healthy 를 기다린다
#   (메모리 값은 Vagrantfile 이 읽는 환경변수 W_MEM/CP_MEM 또는 그 기본값. reload 때 VM 설정에 반영된다)
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
# Ready 표시만 보면 재기동이 빨라 NotReady 로 바뀌기 전 값이 남는다 → kubelet 이 기동 후 lease 를 갱신했는지 본다
renewed_after(){ local r=$(kubectl -n kube-node-lease get lease $1 -o jsonpath='{.spec.renewTime}' 2>/dev/null); [ -n "$r" ] && \
  [ $(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$r") -gt $2 ]; }
for n in "$@"; do
  echo "$(date +%H:%M:%S) $n reload"
  B=$(date +%s); vagrant reload $n >/dev/null 2>&1 || echo "  [NG] vagrant reload 실패"
  for i in $(seq 1 60); do kubectl get node $n --no-headers 2>/dev/null | grep -qw Ready && renewed_after $n $B && break; sleep 5; done
  echo "$(date +%H:%M:%S) $n $(kubectl get node $n --no-headers | awk '{print $2}'), API(VIP): $(curl -sk -m 3 https://172.16.141.30:6443/livez)"
  if [ "${WAIT_DB:-0}" = 1 ]; then
    # DB 인스턴스·Longhorn 복제본이 그 노드에 있으면 돌아와 다시 붙을 때까지 다음 노드를 건드리지 않는다 (동시에 둘이 빠지면 동기 복제 대상이 없어 쓰기가 멈춘다)
    S=$(date +%s); ok=0
    for i in $(seq 1 120); do
      ph=$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.phase} {.status.readyInstances}/{.status.instances}' 2>/dev/null)
      bad=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$3=="attached" && $4!="healthy"' | wc -l | tr -d ' ')
      [ "$ph" = "Cluster in healthy state 3/3" ] && [ "$bad" = 0 ] && { ok=1; break; }; sleep 5
    done
    echo "$(date +%H:%M:%S) $n 이후 DB='$ph' 비정상 볼륨=$bad ($(( $(date +%s)-S ))s 대기) mem=$(kubectl get node $n -o jsonpath='{.status.capacity.memory}')"
    [ $ok = 1 ] || { echo "  [중단] 600s 안에 정상으로 안 돌아옴 — 다음 노드 진행 안 함"; exit 1; }
  fi
  sleep 20
done
__KS_EOF__
chmod +x 'scripts/rolling-reload.sh'
```

## 25. templates/apply-order.md.j2

```bash
mkdir -p 'templates'
cat > 'templates/apply-order.md.j2' <<'__KS_EOF__'
# 풀어 놓은 values·매니페스트 ({{ inventory_dir | basename }})

`./scripts/render-values.sh` 가 `templates/` 를 `{{ inventory_dir | basename }}` 인벤토리 값으로 풀어 만든 파일이다. 손으로 고치지 않는다(다시 만들면 덮어쓴다).
`addons.yml` 이 하는 일을 helm·kubectl 명령으로 적으면 아래 순서다. 첫 control plane 에서, 이 디렉터리 안에서 실행한다.
{% if (render_arch | default('amd64')) in ['arm64', 'aarch64'] %}

노드가 arm64 라 Harbor 는 대체 이미지를 쓰게 풀었다. amd64 노드는 `ARCH=amd64` 로 다시 만든다.
{% endif %}

| 파일 | 내용 | 값이 오는 곳 |
|---|---|---|
| `cilium-l2.yaml` | L2 공지 정책 (어느 노드·NIC 이 VIP 를 ARP 로 알릴지) | `node_iface` |
| `ingress-nginx-values.yaml` | ingress-nginx 차트 values (컨트롤러 {{ ingress_replicas }}개, VIP {{ ingress_vip }}) | `ingress_vip`, `ingress_replicas` |
| `longhorn-values.yaml` | Longhorn 차트 values | `longhorn_csi_replicas` |
| `longhorn-sc-single.yaml` | CNPG 용 StorageClass (복제 1벌, strict-local) | 고정 |
| `harbor-pg.yaml` | Harbor DB: CNPG Cluster 3 인스턴스 | `cnpg_storage_class`, `cnpg_storage_size`, `cnpg_smart_shutdown_timeout` |
| `harbor-values.yaml` | Harbor 차트 values (노출 방식 `{{ harbor_expose }}`) | `harbor_expose`, `harbor_host`, `harbor_storage_class`, `harbor_registry_size`, `harbor_db_host`, `harbor_db_secret` |
| `harbor-bgp-svc.yaml` | BGP VIP 를 받는 Service (`bgp_enabled: {{ bgp_enabled | lower }}`) | `harbor_bgp_vip` |

클러스터 자체의 설정(Kubernetes·Cilium·kube-vip·LB 풀·BGP)은 values 파일이 아니라 Kubespray 변수다: `{{ inventory_dir | basename }}/group_vars/k8s_cluster/` 와 `group_vars/all/`.

## 순서

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo add longhorn https://charts.longhorn.io
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo add harbor https://helm.goharbor.io
    helm repo update

{% if cilium_l2_enabled | bool %}
    # 1. L2 공지 정책
    kubectl apply -f cilium-l2.yaml

{% endif %}
{% if ingress_nginx_enabled | bool %}
    # 2. ingress-nginx
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
      --version {{ ingress_nginx_chart_version }} -f ingress-nginx-values.yaml --wait --timeout 10m

{% endif %}
{% if longhorn_enabled | bool %}
    # 3. Longhorn (worker 에 open-iscsi·nfs 클라이언트·커널 모듈 iscsi_tcp 가 먼저 있어야 한다 — addons.yml 첫 플레이)
    helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
      --version {{ longhorn_version }} -f longhorn-values.yaml --wait --timeout 15m
    kubectl apply -f longhorn-sc-single.yaml

{% endif %}
{% if cnpg_enabled | bool %}
    # 4. CloudNativePG operator + Harbor DB
    helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
      --version {{ cnpg_chart_version }} --wait --timeout 10m
    kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f harbor-pg.yaml
    kubectl -n harbor wait cluster/harbor-pg --for=condition=Ready --timeout=15m

{% endif %}
{% if harbor_enabled | bool %}
    # 5. Harbor. admin 비밀번호는 values 에 없다. Secret 으로 먼저 만든다(값은 직접 정한다)
    kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD='<비밀번호>'
    helm upgrade --install harbor harbor/harbor -n harbor --version {{ harbor_chart_version }} \
      -f harbor-values.yaml --wait --timeout 20m

{% endif %}
{% if bgp_enabled | bool %}
    # 6. BGP VIP 서비스
    kubectl apply -f harbor-bgp-svc.yaml

{% endif %}
    # 확인
    kubectl -n ingress-nginx get svc; kubectl -n harbor get ingress,pods
__KS_EOF__
```

## 26. templates/cilium-l2.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/cilium-l2.yaml.j2' <<'__KS_EOF__'
# Cilium L2 공지: LB 풀(l2-pool, Kubespray 가 생성)의 IP 를 {{ node_iface }} 에서 ARP 로 광고. 서비스마다 노드 한 대가 리더(Lease)로 응답.
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: lab-l2
spec:
  interfaces: ["^{{ node_iface }}$"]
  loadBalancerIPs: true
  externalIPs: false
  serviceSelector:                     # BGP 로 광고하는 서비스는 ARP 대상에서 뺀다
    matchExpressions:
      - {key: lab.io/bgp, operator: DoesNotExist}
  nodeSelector:
    matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
__KS_EOF__
```

## 27. templates/harbor-bgp-svc.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/harbor-bgp-svc.yaml.j2' <<'__KS_EOF__'
# 같은 진입점을 BGP VIP 로도 노출: 노드 서브넷 밖 {{ harbor_bgp_vip }} → ToR 에 /32 경로 광고(워커 수만큼 ECMP)
# 실서비스에서는 L2 와 BGP 중 하나를 고른다. 랩은 두 방식을 비교하려고 같이 둔다.
#   harbor_expose=ingress      → ingress-nginx 컨트롤러 앞에 붙는다 (호스트명으로 들어와야 Harbor 로 간다)
#   harbor_expose=loadBalancer → Harbor 자체 nginx 앞에 붙는다
apiVersion: v1
kind: Service
metadata:
{% if harbor_expose == 'ingress' %}
  name: ingress-nginx-bgp
  namespace: ingress-nginx
{% else %}
  name: harbor-bgp
  namespace: harbor
{% endif %}
  labels:
    lab.io/bgp: "true"
  annotations:
    lbipam.cilium.io/ips: "{{ harbor_bgp_vip }}"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster     # 모든 BGP 노드가 경로 광고 → ToR 가 ECMP. Local 이면 파드 있는 노드만 광고
{% if harbor_expose == 'ingress' %}
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
  ports:
    - {name: http, port: 80, targetPort: http}
    - {name: https, port: 443, targetPort: https}
{% else %}
  selector:
    app: harbor
    component: nginx
  ports:
    - name: http
      port: 80
      targetPort: 8080
{% endif %}
__KS_EOF__
```

## 28. templates/harbor-pg.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/harbor-pg.yaml.j2' <<'__KS_EOF__'
# Harbor 전용 PostgreSQL: CNPG 3 인스턴스(primary 1 + 동기 standby), 노드 분산
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: harbor-pg
  namespace: harbor
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
  primaryUpdateStrategy: unsupervised
  # primary 파드 삭제·drain 시 Postgres 는 먼저 smart shutdown(클라이언트 접속 종료 대기)을 한다.
  # 기본 180s 동안 WAL 송신이 살아 있어 standby 승격이 그만큼 늦어진다(랩 실측 173s). Harbor 는 재접속하므로 짧게.
  smartShutdownTimeout: {{ cnpg_smart_shutdown_timeout | default(15) }}
  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
    podAntiAffinityType: required    # 인스턴스 3개가 반드시 서로 다른 노드
  bootstrap:
    initdb: {database: registry, owner: harbor}
  postgresql:
    synchronous:                     # 커밋은 standby 1대 이상 확인 후 → primary 장애에도 커밋된 데이터 손실 0
      method: any
      number: 1
    parameters:
      max_connections: "200"
      shared_buffers: "128MB"
  storage:
    storageClass: "{{ cnpg_storage_class }}"
    size: {{ cnpg_storage_size | default('2Gi') }}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {memory: 512Mi}
__KS_EOF__
```

## 29. templates/harbor-values.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/harbor-values.yaml.j2' <<'__KS_EOF__'
# Harbor chart 1.18.0 (Harbor 2.14.0) on Kubespray 클러스터
#   저장소 = Longhorn(3벌 복제, 노드 장애 시 다른 노드로 재부착), DB = CNPG(harbor-pg, 3 인스턴스)
#   노출 = harbor_expose 로 고른다
#     ingress      : ingress-nginx 의 VIP({{ ingress_vip }}) 뒤에 호스트명 {{ harbor_host }} 로 붙는다. TLS 는 ingress-nginx 에서 끝난다. Harbor 자체 nginx 파드는 생기지 않는다
#     loadBalancer : Harbor 전용 VIP({{ harbor_vip }}, Cilium LB IPAM + L2 공지), http
#   이미지: amd64 = 차트 기본(goharbor/*), arm64 노드일 때만 ghcr.io/octohelm/harbor/* 로 대체 (goharbor 는 arm64 이미지 없음)
{% if harbor_expose == 'ingress' %}
expose:
  type: ingress
  tls:
    enabled: true
    certSource: auto          # 차트가 자체 서명 인증서를 만든다(랩). 실서버는 certSource: secret + 사내 인증서 Secret
  ingress:
    className: nginx
    hosts:
      core: "{{ harbor_host }}"
    # annotations 는 차트 기본값을 그대로 쓴다: nginx.ingress.kubernetes.io/proxy-body-size "0" (레이어 업로드 크기 제한 없음), ssl-redirect "true"
externalURL: https://{{ harbor_host }}
{% else %}
expose:
  type: loadBalancer
  tls:
    enabled: false
  loadBalancer:
    name: harbor
    IP: ""
    ports: {httpPort: 80}
    annotations:
      lbipam.cilium.io/ips: "{{ harbor_vip }}"
externalURL: http://{{ harbor_vip }}
{% endif %}

# registry·jobservice 볼륨이 RWO(Longhorn) 라 한 번에 한 노드에만 붙는다. 기본값 RollingUpdate 는 새 파드를 먼저 띄우는데,
# 새 파드가 다른 노드에 잡히면 볼륨을 못 붙여 멈춘다(TROUBLESHOOTING 23절). 옛 파드를 먼저 내리게 한다.
updateStrategy:
  type: Recreate

existingSecretAdminPassword: harbor-admin
existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD

persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:   {storageClass: "{{ harbor_storage_class }}", size: {{ harbor_registry_size | default('5Gi') }}}
    jobservice:
      jobLog:   {storageClass: "{{ harbor_storage_class }}", size: 1Gi}
    redis:      {storageClass: "{{ harbor_storage_class }}", size: 1Gi}

database:
  type: external
  external:
    host: "{{ harbor_db_host }}"
    port: "5432"
    username: harbor
    coreDatabase: registry
    existingSecret: "{{ harbor_db_secret }}"
    sslmode: require
  maxIdleConns: 10
  maxOpenConns: 50

trivy:   {enabled: false}
metrics: {enabled: false}

{% if harbor_arm64 %}
nginx:
  image: {repository: ghcr.io/octohelm/harbor/nginx-photon, tag: v2.14.0}
portal:
  image: {repository: ghcr.io/octohelm/harbor/harbor-portal, tag: v2.14.0}
core:
  image: {repository: ghcr.io/octohelm/harbor/harbor-core, tag: v2.14.0}
jobservice:
  image: {repository: ghcr.io/octohelm/harbor/harbor-jobservice, tag: v2.14.0}
registry:
  registry:
    image: {repository: ghcr.io/octohelm/harbor/registry-photon, tag: v2.14.0}
  controller:
    image: {repository: ghcr.io/octohelm/harbor/harbor-registryctl, tag: v2.14.0}
redis:
  type: internal
  internal:
    image: {repository: ghcr.io/octohelm/harbor/redis-photon, tag: v2.14.0}
exporter:
  image: {repository: ghcr.io/octohelm/harbor/harbor-exporter, tag: v2.14.0}
{% endif %}
__KS_EOF__
```

## 30. templates/ingress-nginx-values.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/ingress-nginx-values.yaml.j2' <<'__KS_EOF__'
# ingress-nginx chart {{ ingress_nginx_chart_version }}: 밖에서 들어오는 HTTP(S) 를 VIP 하나({{ ingress_vip }})로 받아 호스트명(Ingress 규칙)으로 서비스에 나눈다.
#   VIP 는 Cilium LB IPAM 이 주고 L2 공지(ARP)로 알린다. 컨트롤러는 워커에 {{ ingress_replicas }}개, 노드마다 하나씩.
#   워커 → apiserver 사이의 nginx-proxy(Kubespray) 와는 다른 것이다.
controller:
  replicaCount: {{ ingress_replicas }}
  ingressClassResource:
    name: nginx
    default: true
  service:
    type: LoadBalancer
    annotations:
      lbipam.cilium.io/ips: "{{ ingress_vip }}"
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
              app.kubernetes.io/component: controller
  resources:
    requests: {cpu: 50m, memory: 128Mi}
__KS_EOF__
```

## 31. templates/longhorn-sc-single.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/longhorn-sc-single.yaml.j2' <<'__KS_EOF__'
# CNPG 용: DB 는 CNPG 가 스트리밍 복제로 이미 3벌 → 스토리지 복제는 1벌 + 데이터를 파드와 같은 노드에 둠(strict-local)
# Longhorn 3벌 × CNPG 3벌 = 9벌 쓰기 증폭을 피한다 (CNPG 문서의 권장)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
parameters:
  numberOfReplicas: "1"
  dataLocality: strict-local
  staleReplicaTimeout: "30"
__KS_EOF__
```

## 32. templates/longhorn-values.yaml.j2

```bash
mkdir -p 'templates'
cat > 'templates/longhorn-values.yaml.j2' <<'__KS_EOF__'
# Longhorn v1.13.0 — 노드 로컬 디스크(/var/lib/longhorn)를 블록 단위로 노드 간 동기 복제
persistence:
  defaultClass: true
  defaultClassReplicaCount: 3        # 볼륨마다 서로 다른 노드 3곳에 복제본
  defaultDataLocality: disabled
  reclaimPolicy: Retain
defaultSettings:
  replicaSoftAntiAffinity: false     # 같은 노드에 복제본 2개 금지
  storageMinimalAvailablePercentage: 15
  storageOverProvisioningPercentage: 200
  nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod   # 노드 다운 시 파드를 지워 다른 노드에서 볼륨 재부착
  replicaReplenishmentWaitInterval: 60
# 랩은 메모리 절약으로 2 (longhorn_csi_replicas). 차트 기본값은 3
csi:
  attacherReplicaCount: {{ longhorn_csi_replicas | default(2) }}
  provisionerReplicaCount: {{ longhorn_csi_replicas | default(2) }}
  resizerReplicaCount: {{ longhorn_csi_replicas | default(2) }}
  snapshotterReplicaCount: {{ longhorn_csi_replicas | default(2) }}
longhornUI:
  replicas: 1
__KS_EOF__
```

## 33. inventory/lab/inventory.ini

```bash
mkdir -p 'inventory/lab'
cat > 'inventory/lab/inventory.ini' <<'__KS_EOF__'
# ip = 클러스터 통신용 host-only(eth1) 주소. ansible_host 는 ssh.cfg(vagrant ssh-config) 의 NAT 주소를 쓴다.
[kube_control_plane]
ks-cp1 ip=172.16.141.31 etcd_member_name=etcd1
ks-cp2 ip=172.16.141.32 etcd_member_name=etcd2
ks-cp3 ip=172.16.141.33 etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node]
ks-w1 ip=172.16.141.41
ks-w2 ip=172.16.141.42
ks-w3 ip=172.16.141.43
ks-w4 ip=172.16.141.44
ks-w5 ip=172.16.141.45

[k8s_cluster:children]
kube_control_plane
kube_node

# ToR 스위치/라우터 역할 (클러스터 밖). Kubespray 대상 아님 → tor.yml 로 FRR 구성
[tor]
ks-tor ip=172.16.141.29
__KS_EOF__
```

## 34. inventory/prod-sample/inventory.ini

```bash
mkdir -p 'inventory/prod-sample'
cat > 'inventory/prod-sample/inventory.ini' <<'__KS_EOF__'
# 실서버 견본 (CP 3 + 워커 5, 노드는 VM). 주소는 전부 자리표시자(10.0.10.x = 노드 서브넷 예시). 실제 값으로 바꾼 뒤 inventory/prod 로 복사해 쓴다.
#   ip = 클러스터 통신 NIC(node_iface) 의 주소. ansible_host 는 SSH 로 닿는 주소(같으면 생략)
[kube_control_plane]
cp1 ansible_host=10.0.10.11 ip=10.0.10.11 etcd_member_name=etcd1
cp2 ansible_host=10.0.10.12 ip=10.0.10.12 etcd_member_name=etcd2
cp3 ansible_host=10.0.10.13 ip=10.0.10.13 etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node]
w1 ansible_host=10.0.10.21 ip=10.0.10.21
w2 ansible_host=10.0.10.22 ip=10.0.10.22
w3 ansible_host=10.0.10.23 ip=10.0.10.23
w4 ansible_host=10.0.10.24 ip=10.0.10.24
w5 ansible_host=10.0.10.25 ip=10.0.10.25

[k8s_cluster:children]
kube_control_plane
kube_node

# [tor] 그룹 없음: 랩의 ToR(FRR) 역할은 실서버에서 네트워크팀 스위치가 한다 (INFRA.md 4절). VM 이면 BGP 없이 L2 만 쓰는 경우가 많다 (INFRA.md 6절)
__KS_EOF__
```

## 35. inventory/lab/group_vars/all/lab.yml

```bash
mkdir -p 'inventory/lab/group_vars/all'
cat > 'inventory/lab/group_vars/all/lab.yml' <<'__KS_EOF__'
---
# ===== 환경별로 바꾸는 값 (실서버는 inventory/prod-sample 참고) =====
ansible_user: vagrant
ansible_ssh_common_args: "-F {{ inventory_dir }}/ssh.cfg"   # 랩 전용(vagrant ssh-config)

node_iface: eth1                       # 클러스터 통신 NIC (VM 예: ens192, 물리 서버 예: bond1). kube-vip ARP, Cilium L2 공지가 이 NIC 에서 나간다
cilium_node_devices: [eth0, eth1]      # Cilium 이 NodePort/LB 를 처리할 NIC 목록 (실서버는 실제 NIC 이름으로)

apiserver_vip: 172.16.141.30           # API VIP (kube-vip, ARP). 노드 서브넷 안, DHCP 범위 밖
ingress_vip: 172.16.141.211            # ingress-nginx VIP (L2 풀 안). 밖에서 들어오는 HTTP(S) 는 전부 이 주소 하나로 받는다
harbor_expose: ingress                 # ingress = ingress-nginx 뒤에 호스트명으로 / loadBalancer = Harbor 전용 VIP(harbor_vip)
harbor_host: "harbor.{{ ingress_vip }}.sslip.io"   # Harbor 호스트명. 랩 전용: Mac 에 /etc/hosts 권한이 없어 IP 가 들어간 이름을 공개 DNS(sslip.io)로 푼다. 실서버는 사내 DNS 레코드
harbor_vip: 172.16.141.210             # Harbor 전용 LB VIP (harbor_expose=loadBalancer 일 때만)
l2_pool_start: 172.16.141.210
l2_pool_stop: 172.16.141.219

bgp_enabled: true                      # ToR 스위치와 BGP 를 할지
bgp_local_asn: 65010                   # 노드(Cilium) 쪽 ASN — 네트워크팀이 할당
bgp_peer_asn: 65000                    # ToR 스위치 ASN
bgp_peer_address: 172.16.141.29        # ToR 스위치 피어 IP (노드 서브넷의 게이트웨이/SVI)
bgp_pool_cidr: 10.250.0.0/24           # BGP 로 광고할 VIP 대역 — 노드 서브넷 밖, 네트워크팀이 할당
harbor_bgp_vip: 10.250.0.10

# ===== 프록시 (랩: Mac 의 VMware NAT 가 죽어 Mac host-only 주소의 HTTP 프록시로 설치. 사내 프록시 망과 같은 경로) =====
http_proxy: "http://172.16.141.1:3128"
https_proxy: "http://172.16.141.1:3128"
# Kubespray 가 노드 IP·서비스/파드 대역·localhost 는 자동으로 no_proxy 에 넣는다. VIP·사내 대역은 직접 추가
additional_no_proxy: "172.16.141.0/24,10.250.0.0/24,.svc,.cluster.local"

# ===== 구성요소 켜기/끄기 (환경에 이미 있는 건 false) =====
cilium_l2_enabled: true                # L2 공지 정책. BGP 만 쓰는 환경이면 false
longhorn_enabled: true                 # 회사 CSI(NFS/Ceph/벤더)가 있으면 false 로 두고 아래 SC 이름을 바꾼다
cnpg_enabled: true                     # 외부 PostgreSQL 을 쓰면 false (harbor_db_* 값을 외부 DB 로)
harbor_enabled: true
ingress_nginx_enabled: true            # 이미 ingress 컨트롤러가 있으면 false (그때 Harbor Ingress 의 className 은 templates/harbor-values.yaml.j2 에서 맞춘다)
ingress_replicas: 3                    # 컨트롤러 파드 수. 워커마다 하나씩만 뜬다
harbor_storage_class: longhorn         # Harbor registry/redis/jobservice PVC
cnpg_storage_class: longhorn-single    # CNPG PVC (DB 가 자체 복제하므로 스토리지 복제 1벌)
cnpg_smart_shutdown_timeout: 15         # primary 계획 종료 시 접속 종료 대기(초). CNPG 기본 180 → 승격이 3분 늦어짐
harbor_db_host: harbor-pg-rw.harbor.svc
harbor_db_secret: harbor-pg-app        # 키 'password' 를 가진 Secret (CNPG 가 생성)

loadbalancer_apiserver:
  address: "{{ apiserver_vip }}"
  port: 6443
loadbalancer_apiserver_localhost: false
__KS_EOF__
```

## 36. inventory/lab/group_vars/k8s_cluster/lab.yml

```bash
mkdir -p 'inventory/lab/group_vars/k8s_cluster'
cat > 'inventory/lab/group_vars/k8s_cluster/lab.yml' <<'__KS_EOF__'
---
cluster_name: cluster.local
container_manager: containerd
# Cilium 은 kube_owner=root 필수 (init 컨테이너가 CAP_DAC_OVERRIDE 없이 /opt/cni/bin 에 쓴다). Kubespray 기본값 kube 면 assert 로 중단됨
kube_owner: root
# kubeadm 인증서는 1년. 매월 첫 월요일 자동 갱신 (systemd 타이머)
auto_renew_certificates: true

# --- CNI: Cilium, kube-proxy 없이 (eBPF kube-proxy replacement) ---
kube_network_plugin: cilium
cilium_kube_proxy_replacement: true
kube_proxy_remove: true
# Kubespray v2.32.0: kube-vip 사전검사 조건식이 이 변수를 읽는데 기본값이 없다(샘플 인벤토리에만 있음) → 명시. kube-proxy 가 없으니 값 자체는 무의미
kube_proxy_strict_arp: false
cilium_tunnel_mode: vxlan
# LoadBalancer 서비스용 VIP: Cilium LB IPAM (MetalLB 대신). 광고 방식 두 가지를 같이 둔다.
#   L2  : 노드 서브넷 안 IP 를 ARP 로 광고. 스위치가 노드 포트의 ARP/GARP·MAC 이동을 허용해야 한다
#   BGP : 노드 서브넷 밖 대역을 ToR 에 경로로 광고. 스위치(L3)가 BGP 피어링을 받아야 한다
cilium_l2announcements: true
cilium_loadbalancer_ip_pools:
  - name: l2-pool                       # 라벨 없는 서비스(기본)
    ranges:
      - start: "{{ l2_pool_start }}"
        stop: "{{ l2_pool_stop }}"
  - name: bgp-pool                      # lab.io/bgp=true 라벨 서비스만
    cidrs: ["{{ bgp_pool_cidr }}"]
    serviceSelector:
      matchLabels: {lab.io/bgp: "true"}

# --- BGP Control Plane (bgpv2 API): 워커 전체 ↔ ToR(ks-tor, FRR) eBGP ---
cilium_enable_bgp_control_plane: "{{ bgp_enabled }}"
cilium_bgp_cluster_configs: "{{ _bgp_cluster_configs if bgp_enabled else [] }}"
cilium_bgp_peer_configs: "{{ _bgp_peer_configs if bgp_enabled else [] }}"
cilium_bgp_advertisements: "{{ _bgp_advertisements if bgp_enabled else [] }}"
_bgp_cluster_configs:
  - name: lab-bgp
    spec:
      nodeSelector:
        matchExpressions:
          - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
      bgpInstances:
        - name: main
          localASN: "{{ bgp_local_asn | int }}"
          peers:
            - name: tor
              peerASN: "{{ bgp_peer_asn | int }}"
              peerAddress: "{{ bgp_peer_address }}"
              peerConfigRef: {name: tor-peer}
_bgp_peer_configs:
  - name: tor-peer
    spec:
      timers: {holdTimeSeconds: 9, keepAliveTimeSeconds: 3}   # 노드 다운 감지 ≈ 9초 (기본 90초). 운영은 BFD 와 함께 검토
      gracefulRestart: {enabled: true, restartTimeSeconds: 15}
      families:
        - afi: ipv4
          safi: unicast
          advertisements:
            matchLabels: {advertise: bgp}
_bgp_advertisements:
  - name: lb-services
    labels: {advertise: bgp}
    spec:
      advertisements:
        - advertisementType: Service
          service:
            addresses: [LoadBalancerIP]
          selector:
            matchLabels: {lab.io/bgp: "true"}
cilium_extra_values:
  # NodePort/LB 를 처리할 NIC 목록 (env 의 cilium_node_devices). 랩: eth0 = Vagrant NAT(인터넷), eth1 = 클러스터망
  devices: "{{ cilium_node_devices }}"
  # L2 공지는 서비스마다 Lease 를 갱신 → API 호출이 늘어 기본 레이트리밋을 올린다 (Cilium 문서 권장)
  k8sClientRateLimit:
    qps: 20
    burst: 40
  operator:
    replicas: 2

# --- API VIP: kube-vip (control plane 정적 파드, ARP) ---
kube_vip_enabled: true
kube_vip_arp_enabled: true
kube_vip_controlplane_enabled: true
kube_vip_services_enabled: false     # 서비스 VIP 는 Cilium 이 맡는다
kube_vip_address: "{{ apiserver_vip }}"
kube_vip_interface: "{{ node_iface }}"
supplementary_addresses_in_ssl_keys: ["{{ apiserver_vip }}"]

# --- 애드온 ---
helm_enabled: true
metrics_server_enabled: true
kubeconfig_localhost: true           # artifacts/admin.conf 를 Mac 에 받아 둔다
kubectl_localhost: false
__KS_EOF__
```

## 37. inventory/prod-sample/group_vars/all/env.yml

```bash
mkdir -p 'inventory/prod-sample/group_vars/all'
cat > 'inventory/prod-sample/group_vars/all/env.yml' <<'__KS_EOF__'
---
# ===== 실서버 견본: 값은 전부 자리표시자. INFRA.md 의 신청 항목으로 받은 값을 넣는다 =====
ansible_user: deploy                   # sudo 권한 있는 배포 계정 (SSH 키 인증)
# ansible_ssh_private_key_file: ~/.ssh/k8s_deploy

# 클러스터 통신 NIC. 노드에서 `ip -br addr` 로 확인한 실제 이름을 넣는다 (preflight.yml 이 이름·주소를 검사한다)
#   VM      : 보통 NIC 하나 (예: ens192, eth0). 이중화는 하이퍼바이저가 하므로 게스트 안에서 bond 를 묶지 않는다
#   물리 서버: bond 이름 (예: bond1)
node_iface: ens192                     # kube-vip ARP, Cilium L2 공지가 이 NIC 에서 나간다
cilium_node_devices: [ens192]          # Cilium 이 NodePort/LB 를 처리할 NIC 목록. NIC 가 여럿이면 전부 적는다

apiserver_vip: 10.0.10.100           # API VIP (kube-vip, ARP). 노드 서브넷 안, DHCP 범위 밖
ingress_vip: 10.0.10.211            # ingress-nginx VIP (L2 풀 안). 밖에서 들어오는 HTTP(S) 는 전부 이 주소 하나로 받는다
harbor_expose: ingress                 # ingress = ingress-nginx 뒤에 호스트명으로 / loadBalancer = Harbor 전용 VIP(harbor_vip)
harbor_host: harbor.example.internal   # Harbor 호스트명. 사내 DNS 에 이 이름 → ingress_vip 레코드를 신청한다
harbor_vip: 10.0.10.210             # Harbor 전용 LB VIP (harbor_expose=loadBalancer 일 때만)
l2_pool_start: 10.0.10.210
l2_pool_stop: 10.0.10.219

bgp_enabled: false                     # ToR 스위치와 BGP 를 할지. 네트워크팀이 피어링을 열어 주면 true. VM 은 물리 스위치와 직접 피어링이 안 되는 경우가 많다 (INFRA.md 6절)
bgp_local_asn: 65010                   # 노드(Cilium) 쪽 ASN — 네트워크팀이 할당
bgp_peer_asn: 65000                    # ToR 스위치 ASN
bgp_peer_address: 10.0.10.1        # ToR 스위치 피어 IP (노드 서브넷의 게이트웨이/SVI)
bgp_pool_cidr: 10.250.0.0/24           # BGP 로 광고할 VIP 대역 — 노드 서브넷 밖, 네트워크팀이 할당
harbor_bgp_vip: 10.250.0.10

# ===== 구성요소 켜기/끄기 (환경에 이미 있는 건 false) =====
cilium_l2_enabled: true                # L2 공지 정책. BGP 만 쓰는 환경이면 false
longhorn_enabled: true                 # 회사 CSI(NFS/Ceph/벤더)가 있으면 false 로 두고 아래 SC 이름을 바꾼다
cnpg_enabled: true                     # 외부 PostgreSQL 을 쓰면 false (harbor_db_* 값을 외부 DB 로)
harbor_enabled: true
ingress_nginx_enabled: true            # 이미 ingress 컨트롤러가 있으면 false (그때 Harbor Ingress 의 className 은 templates/harbor-values.yaml.j2 에서 맞춘다)
ingress_replicas: 3                    # 컨트롤러 파드 수. 워커마다 하나씩만 뜬다
harbor_storage_class: longhorn         # Harbor registry/redis/jobservice PVC
cnpg_storage_class: longhorn-single    # CNPG PVC (DB 가 자체 복제하므로 스토리지 복제 1벌)
cnpg_smart_shutdown_timeout: 15         # primary 계획 종료 시 접속 종료 대기(초). CNPG 기본 180 → 승격이 3분 늦어짐
harbor_db_host: harbor-pg-rw.harbor.svc
harbor_db_secret: harbor-pg-app        # 키 'password' 를 가진 Secret (CNPG 가 생성)

# ===== 크기 (안 적으면 랩 값: registry 5Gi, DB 2Gi, CSI 사이드카 2벌) =====
# 아래 숫자는 자리표시자다. registry 는 Nexus 의 실제 사용량을 보고 정한다. Longhorn 은 여기에 복제 수(3)를 곱한 만큼 노드 디스크를 쓴다
harbor_registry_size: 200Gi            # Harbor 이미지 저장 PVC
cnpg_storage_size: 20Gi                # Harbor DB PVC (인스턴스마다 하나씩, 3개)
longhorn_csi_replicas: 3               # Longhorn CSI 사이드카 수 (차트 기본 3)

loadbalancer_apiserver:
  address: "{{ apiserver_vip }}"
  port: 6443
loadbalancer_apiserver_localhost: false

# ===== 실서버 추가 고려 =====
# 인터넷이 안 되는 망: Kubespray 오프라인 설치(contrib/offline) 로 바이너리·이미지를 사내 미러에 올리고 아래를 미러로 바꾼다
# kube_image_repo: "<사내레지스트리>/registry.k8s.io"
# docker_image_repo / quay_image_repo / github_image_repo / files_repo 도 동일
# HTTP 프록시만 되는 망:
# http_proxy: "http://<proxy>:<port>"
# https_proxy: "http://<proxy>:<port>"
# no_proxy 는 Kubespray 가 노드·서비스 대역을 자동으로 추가한다 (additional_no_proxy 로 사내 도메인 추가)
__KS_EOF__
```

## 38. inventory/prod-sample/group_vars/k8s_cluster/k8s.yml

```bash
mkdir -p 'inventory/prod-sample/group_vars/k8s_cluster'
cat > 'inventory/prod-sample/group_vars/k8s_cluster/k8s.yml' <<'__KS_EOF__'
---
cluster_name: cluster.local
container_manager: containerd
# Cilium 은 kube_owner=root 필수 (init 컨테이너가 CAP_DAC_OVERRIDE 없이 /opt/cni/bin 에 쓴다). Kubespray 기본값 kube 면 assert 로 중단됨
kube_owner: root
# kubeadm 인증서는 1년. 매월 첫 월요일 자동 갱신 (systemd 타이머)
auto_renew_certificates: true

# --- CNI: Cilium, kube-proxy 없이 (eBPF kube-proxy replacement) ---
kube_network_plugin: cilium
cilium_kube_proxy_replacement: true
kube_proxy_remove: true
# Kubespray v2.32.0: kube-vip 사전검사 조건식이 이 변수를 읽는데 기본값이 없다(샘플 인벤토리에만 있음) → 명시. kube-proxy 가 없으니 값 자체는 무의미
kube_proxy_strict_arp: false
cilium_tunnel_mode: vxlan
# LoadBalancer 서비스용 VIP: Cilium LB IPAM (MetalLB 대신). 광고 방식 두 가지를 같이 둔다.
#   L2  : 노드 서브넷 안 IP 를 ARP 로 광고. 스위치가 노드 포트의 ARP/GARP·MAC 이동을 허용해야 한다
#   BGP : 노드 서브넷 밖 대역을 ToR 에 경로로 광고. 스위치(L3)가 BGP 피어링을 받아야 한다
cilium_l2announcements: true
cilium_loadbalancer_ip_pools:
  - name: l2-pool                       # 라벨 없는 서비스(기본)
    ranges:
      - start: "{{ l2_pool_start }}"
        stop: "{{ l2_pool_stop }}"
  - name: bgp-pool                      # lab.io/bgp=true 라벨 서비스만
    cidrs: ["{{ bgp_pool_cidr }}"]
    serviceSelector:
      matchLabels: {lab.io/bgp: "true"}

# --- BGP Control Plane (bgpv2 API): 워커 전체 ↔ ToR 스위치 eBGP. env 의 bgp_enabled 가 false 면 전부 꺼진다 ---
cilium_enable_bgp_control_plane: "{{ bgp_enabled }}"
cilium_bgp_cluster_configs: "{{ _bgp_cluster_configs if bgp_enabled else [] }}"
cilium_bgp_peer_configs: "{{ _bgp_peer_configs if bgp_enabled else [] }}"
cilium_bgp_advertisements: "{{ _bgp_advertisements if bgp_enabled else [] }}"
_bgp_cluster_configs:
  - name: lab-bgp
    spec:
      nodeSelector:
        matchExpressions:
          - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
      bgpInstances:
        - name: main
          localASN: "{{ bgp_local_asn | int }}"
          peers:
            - name: tor
              peerASN: "{{ bgp_peer_asn | int }}"
              peerAddress: "{{ bgp_peer_address }}"
              peerConfigRef: {name: tor-peer}
_bgp_peer_configs:
  - name: tor-peer
    spec:
      timers: {holdTimeSeconds: 9, keepAliveTimeSeconds: 3}   # 노드 다운 감지 ≈ 9초 (기본 90초). 운영은 BFD 와 함께 검토
      gracefulRestart: {enabled: true, restartTimeSeconds: 15}
      families:
        - afi: ipv4
          safi: unicast
          advertisements:
            matchLabels: {advertise: bgp}
_bgp_advertisements:
  - name: lb-services
    labels: {advertise: bgp}
    spec:
      advertisements:
        - advertisementType: Service
          service:
            addresses: [LoadBalancerIP]
          selector:
            matchLabels: {lab.io/bgp: "true"}
cilium_extra_values:
  # NodePort/LB 를 처리할 NIC 목록 (env 의 cilium_node_devices)
  devices: "{{ cilium_node_devices }}"
  # L2 공지는 서비스마다 Lease 를 갱신 → API 호출이 늘어 기본 레이트리밋을 올린다 (Cilium 문서 권장)
  k8sClientRateLimit:
    qps: 20
    burst: 40
  operator:
    replicas: 2

# --- API VIP: kube-vip (control plane 정적 파드, ARP) ---
kube_vip_enabled: true
kube_vip_arp_enabled: true
kube_vip_controlplane_enabled: true
kube_vip_services_enabled: false     # 서비스 VIP 는 Cilium 이 맡는다
kube_vip_address: "{{ apiserver_vip }}"
kube_vip_interface: "{{ node_iface }}"
supplementary_addresses_in_ssl_keys: ["{{ apiserver_vip }}"]

# --- 실서버: 노드·서비스·파드 대역이 사내망과 겹치지 않게 (겹치면 그 대역으로 가는 사내 트래픽이 클러스터 안으로 빨려 들어간다) ---
kube_service_addresses: 10.233.0.0/18   # Kubespray 기본. 사내망과 겹치면 변경
kube_pods_subnet: 10.233.64.0/18        # Kubespray 기본. 사내망과 겹치면 변경

# --- 애드온 ---
helm_enabled: true
metrics_server_enabled: true
kubeconfig_localhost: true           # artifacts/admin.conf 를 배포 호스트에 받아 둔다
kubectl_localhost: false
__KS_EOF__
```

## sha256 대조

리눅스는 `sha256sum -c`, macOS 는 `shasum -a 256 -c`. 모든 줄이 `OK` 여야 한다.

```bash
sha256sum -c <<'__KS_EOF__'
623a8f30fcb6163cfa9027eca241b45fc852498d3a8f10c3bc1eec6b93619c81  .gitignore
810deb9db15679d38a555096ec0dfbe12fe6cdbcc6ac413ba67d0d3dfa03fe03  Vagrantfile
389fdd8a54ea5d36af59948219aa5be453f51e581e1ba066ae223ccf6e987601  addons.yml
051604e43cf1b970e446c7d368f17e3a03fdb467740d3cba7271a08559939fc2  install.sh
78bdd3882e7b0b4f85aa81f8fbdacf52369051a238c879ee99efffc771aca9c2  preflight.yml
aa52952a1d6f86a7e8be5b62898eb542420df11d0b89ee00e171ed4cceb1ce04  render.yml
a0d42e1d9be9cab375fb85be6623d8fb0a5ac220effec01439a531b38fc94df0  reset.sh
77ad03136b46c6499062d382d8a93801bc701deb3a3275bde3154f7c5882a2e8  tor.yml
8173dbc99c184048da66a9d7fa7c50eb99aec081897ee1807c8616d2a14e1b3d  versions.yml
720767d711a816362b700997c963c5c8b2ede739defe86e369830073dd7e0a19  scripts/00-inventory.sh
52078dc353409d1a79f98e8d7af67f59eed40e6d60e99dcdd6c2d732aa04abb4  scripts/10-cluster.sh
a0ff4735531a6a1b4e325033aa6e17d0e02ec8c1a35b56b7399c82d4245f2688  scripts/20-addons.sh
2e7dbe54d4ccdd2858b0d58ae16879bc0f97702f679f1abe07a7d9e0918ead17  scripts/30-verify.sh
29804d5a040fec863c6228e6071ea8694a0a7874f4cdb0fe4f7845797b97d360  scripts/40-failover.sh
c26f80eb45e853d00807ecebd43c553b588527afd408f1460b34cb1e211c37c4  scripts/50-more-tests.sh
e912cb73f6101229c524b015aa28c5bfc121b5e97a442fe7b402a070440da108  scripts/60-db-node-loss.sh
5dce9b595098b09cdef3026911a7793c7ce4d7a8137d9f57fde7ae56c793ef45  scripts/61-db-move-instance.sh
cdca41d681a59baa9ca319160c94af6f2ef057d68236bfab8d4d4efe1d242cbc  scripts/62-ingress-failover.sh
ce112cab4a558263867755ebd82e67db2a411eb52293298fb2732fb058b4bb60  scripts/addon.sh
51f6b22520eb71b03f100ab577ad42da1b534f00e97665aa1eb0c0a9269b8890  scripts/harbor-env.sh
39d2a850852c28b4f7d71c4a6c14a4db6cb5c39286c0460a1399196e382ece15  scripts/lab-proxy.sh
f78408a72931a389badb5cc04931cf47c93a7cbfce8835bc6b9d8bfb458304aa  scripts/make-bundle.sh
aa6ff9680a3433e09db4e03b87af2413a4b8a6a8e94f7eb3fa74cc77514b3269  scripts/render-values.sh
cd5596bf6489464abeffc7778930316f05798e71ea4f47ef745c9b22dca6e7a6  scripts/rolling-reload.sh
c645819848ed423513975c527308e3f59c4b0e937dc3f419c7de13ef527824e3  templates/apply-order.md.j2
384ba5bf0faf6c94a2a4aa522151272b3cff8fb50b36ad107ff2c93cfcb4e332  templates/cilium-l2.yaml.j2
e397a55c1b334d6db9c4d0fccc0b5c2a816d1a52d82bd4cdedbe74fc95179ff5  templates/harbor-bgp-svc.yaml.j2
bde082f8b7260d41c892e6848fe595a2f938c1c770ffff55b9f195b38c14166c  templates/harbor-pg.yaml.j2
701f51fafd950494082de3b2234f9192ded2e70b2ccc22a0905eeb645622a0b5  templates/harbor-values.yaml.j2
b257ac488dedf44ca3bb25e77a9fb72961f4b5bcc68faa712392ce654c16a77f  templates/ingress-nginx-values.yaml.j2
487c6cf992e888f9ff9b794fbff50b5c2bfa86fd56a2c96cc2d9769b77888b04  templates/longhorn-sc-single.yaml.j2
75bc29bbc174c86e1bacc713c6a39ffb59b5f525d7bd772576305af5445ef69b  templates/longhorn-values.yaml.j2
61158d2c2ce45bb49405d69c95308801fe0ef8057d2c7be1385969a94c236884  inventory/lab/inventory.ini
b34386cc08dbbce883f5b26328e654408c369de3ea7d4a89fb2ee3400853cce9  inventory/prod-sample/inventory.ini
1e1c3444e3d9da28662ad225426d3c0bffed10e2e4c7799ac898b0d43f18c388  inventory/lab/group_vars/all/lab.yml
68941e5fe54d16b645fe221d3ce8a2628a73c993ddeda97964cfa001fd618f9b  inventory/lab/group_vars/k8s_cluster/lab.yml
47c063e621fa311ccaf666ceb7dad13ae3b1adac20ffa9e257a132d7e5e7c1b8  inventory/prod-sample/group_vars/all/env.yml
aca163db8544309beac8eaf6a4c2a8f24376a54db64991b962604c94e93f2dfe  inventory/prod-sample/group_vars/k8s_cluster/k8s.yml
__KS_EOF__
```
