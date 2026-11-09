# Kubespray + Cilium 클러스터에 Harbor · CNPG · Longhorn 올리기

control plane 3대(etcd 쿼럼), worker 7대 클러스터를 Kubespray 로 만들고, 그 위에 Harbor 를 올린다.
Harbor 의 DB 는 CloudNativePG(CNPG) 3개 인스턴스, 이미지 저장소는 Longhorn(노드 간 3벌 복제)이다.
외부 노출은 Cilium 의 L2 공지(같은 서브넷)와 BGP(스위치로 경로 광고) 두 가지를 모두 구성했다.

랩(Mac + VMware Fusion VM 11대)에서 설치부터 장애 시험까지 실측했다. 같은 플레이북을 인벤토리만 바꿔 리눅스 배포 서버에서 실서버에 쓴다.

| 문서 | 내용 |
|---|---|
| [INFRA.md](INFRA.md) | 네트워크·보안팀에 요청할 것: 주소 계획, 스위치(L2), BGP, 방화벽 포트 표, 주의점 |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 구축 중 막힌 지점과 원인을 좁힌 과정 (실서버에도 해당하는 것 표시) |
| [BUNDLE.md](BUNDLE.md) | **다운로드가 안 될 때**: 모든 코드 파일을 붙여넣기용 블럭으로 모은 것 (아래 '파일 옮기기') |

## 구성

| 구성요소 | 버전 | 역할 |
|---|---|---|
| Kubespray | v2.32.0 | Kubernetes 1.36.4, containerd |
| Cilium | 1.20.2 | CNI(VXLAN), kube-proxy 대체, LB IPAM, L2 공지, BGP control plane |
| kube-vip | Kubespray 내장 | API VIP (ARP) |
| Longhorn | 1.13.0 | 블록 스토리지. 기본 3벌 복제, CNPG 용 1벌 `longhorn-single` |
| CloudNativePG | chart 0.29.1 (operator 1.30.1) | Harbor DB. 3 인스턴스, 서로 다른 노드, quorum 동기 복제 |
| Harbor | chart 1.18.0 (2.14.0) | 레지스트리. L2 VIP + BGP VIP 두 서비스로 노출 |
| FRR | Ubuntu 패키지 | (랩 전용) ToR 스위치 역할. 실서버는 네트워크팀 스위치 |

```
           ┌──────── ToR 스위치 (BGP AS 65000) ────────┐
           │  10.250.0.0/24 의 /32 경로만 받음, ECMP    │
           └───────┬──────────────────────────┬─────────┘
       노드 서브넷  │ (L2: API VIP, Harbor L2 VIP)│ BGP 피어 (worker 7대, AS 65010)
   ┌───────────────┴───┐              ┌───────┴─────────────────────────────┐
   │ cp1 cp2 cp3        │              │ w1 … w7                              │
   │ etcd · apiserver   │              │ Longhorn · CNPG(3) · Harbor          │
   │ kube-vip(API VIP)  │              │ Cilium L2 공지 / BGP 광고            │
   └────────────────────┘              └──────────────────────────────────────┘
```

## 설치

모든 단계는 다시 실행해도 안전하다. 실패하면 고친 뒤 `--from <단계>` 로 그 단계부터 다시 한다.

```bash
./install.sh                           # 랩: 도구 → VM 11대 → Kubespray → 애드온 → 검증
./install.sh --from cluster            # 단계: tools | vms | cluster | addons | verify
INVENTORY=inventory/prod ./install.sh  # 실서버: VM 단계 없이 SSH 도달 확인부터
```

| 단계 | 하는 일 | 따로 실행 |
|---|---|---|
| tools | macOS 는 brew 로, 리눅스는 설치 여부만 확인. Kubespray 클론과 Python venv | |
| vms | (랩) `vagrant up`, SSH 설정 생성. (실서버) ansible ping | `scripts/00-inventory.sh` |
| cluster | 사전점검(`preflight.yml`) 후 Kubespray `cluster.yml` | `scripts/10-cluster.sh` |
| addons | (랩) ToR FRR → Cilium L2 → Longhorn → CNPG → Harbor | `scripts/20-addons.sh` |
| verify | 노드·VIP·etcd·Cilium·BGP·Longhorn·CNPG·Harbor, push/pull | `scripts/30-verify.sh` |

**구성요소 하나만 설치하거나 바꿀 때**는 `scripts/addon.sh` 를 쓴다. 환경에 이미 있는 것은 인벤토리에서 끈다.

```bash
./scripts/addon.sh longhorn
./scripts/addon.sh cnpg
./scripts/addon.sh harbor
./scripts/addon.sh l2       # Cilium L2 공지·LB 풀
./scripts/addon.sh tor      # (랩) ToR FRR
```

| 이미 있는 것 | 인벤토리에서 |
|---|---|
| 회사 스토리지(CSI) | `longhorn_enabled: false`, `harbor_storage_class`·`cnpg_storage_class` 를 그 SC 로 |
| 외부 PostgreSQL | `cnpg_enabled: false`, `harbor_db_host`·`harbor_db_secret` 을 외부 DB 로 |
| BGP 를 안 씀 | `bgp_enabled: false` (L2 VIP 만) |
| 노드가 Longhorn 패키지를 이미 가짐 | 그대로 둬도 된다. 설치 작업이 멱등이다 |

```yaml
# inventory/prod/group_vars/all/env.yml — 회사 스토리지 + 외부 DB + BGP 미사용 예
longhorn_enabled: false
harbor_storage_class: <회사 StorageClass>
cnpg_enabled: false
harbor_db_host: <외부 PostgreSQL 주소>
harbor_db_secret: <키 password 를 가진 Secret 이름>
bgp_enabled: false
```

**실서버**는 `inventory/prod-sample` 을 `inventory/prod` 로 복사해 값을 바꾼다. 값은 모두 자리표시자이고, 무엇을 받아야 하는지는 INFRA.md 1절에 있다.

```bash
cp -r inventory/prod-sample inventory/prod
vi inventory/prod/inventory.ini                    # 노드 이름·IP, [tor] 그룹 없음
vi inventory/prod/group_vars/all/env.yml           # NIC, VIP, L2 풀, BGP, 프록시, 스토리지·DB 토글
vi inventory/prod/group_vars/k8s_cluster/k8s.yml   # 파드·서비스 대역 (사내망과 겹치지 않게)
INVENTORY=inventory/prod ./install.sh
```

배포 서버는 리눅스(점프 호스트)를 전제로 한다. 노드 OS 는 Ubuntu 24.04 에서 실측했다. `preflight.yml` 과 Longhorn 준비 작업은 RHEL 계열 분기도 갖고 있지만 실측하지 않았다.

## 초기화

아래로 갈수록 많이 지운다. 확인 문구를 입력해야 진행한다(`FORCE=1` 이면 생략).

```bash
./reset.sh apps      # Harbor·CNPG·Longhorn 제거, 클러스터 유지      → ./install.sh --from addons
./reset.sh cluster   # Kubespray reset.yml + Longhorn 데이터 삭제    → ./install.sh --from cluster
./reset.sh vms       # (랩 전용) VM 삭제                             → ./install.sh --from vms
```

Longhorn 볼륨, CNPG DB, Harbor 이미지가 모두 사라진다. 실서버는 백업 먼저.

## 실측 결과 (랩)

랩 사양: Apple Silicon Mac(32GB), VMware Fusion, Ubuntu 24.04 arm64. CP 2560MB, worker 1920MB, 2 vCPU.
아래 시간은 이 랩 기준이다. 실서버 값으로 단정하지 말고 같은 스크립트로 다시 잰다.

시험 실행 명령. 결과는 `logs/` 에 남는다. 40·50 은 **랩 VM 을 끄고 켜는 시험**이라 실서버에서 그대로 돌리지 않는다.

```bash
./scripts/30-verify.sh               # 검증 16항목
./scripts/40-failover.sh             # 장애 시험 A·B·C
./scripts/50-more-tests.sh           # 추가 시험 F·D·E (하나만: ./scripts/50-more-tests.sh E)
```

**검증** (`scripts/30-verify.sh`): 16개 항목 모두 통과. BGP 피어 7대 Established, ToR 에 Harbor BGP VIP ECMP 경로 7개, CNPG 복제 2개 quorum, Mac 에서 L2 VIP 로 push/pull.

**장애 시험** (`scripts/40-failover.sh`, `scripts/50-more-tests.sh`)

같은 시험을 여러 번 돌렸다(설치를 다시 한 클러스터 포함). 값이 다를 때는 범위로 적었다.

| 시험 | 결과 |
|---|---|
| A. API VIP 를 가진 CP 강제 정지 | 13~19초 뒤 VIP 가 다른 CP 로 이동, API 응답. etcd 2/3 로 쓰기 성공, Harbor pull 성공. 네 번 중 한 번은 정지 17초 뒤 첫 쓰기가 일시 실패(TROUBLESHOOTING 15절) |
| B. CNPG primary 파드 삭제 | 새 primary 18~21초, Harbor DB 조회는 그 뒤 3~6초에 복구. 설정 조정 전에는 173초(9절) |
| C. registry 파드가 있는 worker 강제 정지 | registry 는 367~416초 뒤 다른 노드에서 재기동(300초는 쿠버네티스 기본 축출 대기, 11절). Harbor 전체 복구는 그 노드에 registry 만 있었으면 380초, core·Redis 등까지 몰려 있었으면 558~575초(14절). 기존 이미지 pull 성공 |
| D. registry 볼륨 복제본 1벌을 가진 worker 정지 | 25~34초 뒤 degraded. 그 상태에서 새 이미지 push 성공. 110~120초 뒤 다른 노드에 복제본을 다시 만들어 healthy. 노드가 돌아온 뒤 옛 복제본은 실패 30분 뒤(`staleReplicaTimeout`) 자동 삭제 |
| E. CNPG primary 를 가진 worker 강제 정지 | 58~92초 뒤 새 primary. 64~95초에 Harbor 프로젝트 생성(DB 쓰기) 성공, 새 이미지 push·pull 성공. 노드 복귀 후 옛 primary 가 replica 로 재합류, 새 프로젝트 행이 replica 에도 있음 |
| F. BGP VIP 로 push/pull (ToR 에서) | 토큰 발급 주소도 BGP VIP 로 나옴. pull, 새 태그 push, 되받은 manifest 동일 |

**초기화 후 재설치** (`reset.sh` 각 모드 → `install.sh --from …`, 확인 문구는 `FORCE=1`)

| 모드 | 초기화 | 재설치 + 검증 | 검증 |
|---|---|---|---|
| apps | 1분 35초 | 8분 | 16/16 |
| cluster | 4분 30초 | 31분 30초 (Kubespray 18분) | 16/16 |
| vms (VM 까지 삭제, 빈 상태부터) | 2분 | 46분 (VM 11분, Kubespray 18분 40초, 애드온 15분) | 16/16 |

`install.sh` 의 tools 단계(brew 설치)는 이 Mac 의 Homebrew 가 macOS 버전을 인식하지 못해 시험하지 못했다. 도구는 미리 설치된 상태에서 vms 단계부터 돌렸다.

**아직 시험하지 않은 것**

- 이 클러스터에서의 CNPG 백업과 복구. 백업 저장소(S3 호환)가 필요하다. 같은 CNPG 버전으로 barman-cloud 플러그인 + MinIO 백업과 시점 복구(PITR)를 잰 기록은 상위 README 의 5차 절에 있다.
- Harbor 자체 이중화. core·registry·Redis 가 1개씩이고 분산 규칙이 없어, 그 파드가 있는 노드가 죽으면 6~10분 멈춘다(시험 C, TROUBLESHOOTING 14절).
- 노드 OS RHEL 계열, 오프라인(인터넷 없는 망) 설치.

## 랩 전용 사항

- **Mac 자원.** VM 11대가 디스크 약 56GB, 메모리 설정 합계 약 21GB 를 쓴다. 시작 전 디스크 여유 80GB 이상, Docker Desktop 같은 다른 VM 은 끈다(TROUBLESHOOTING 7·8절).
- **랩 프록시.** 이 Mac 은 VMware NAT 가 동작하지 않아, Mac 의 host-only 주소에 HTTP 프록시를 띄워 노드가 인터넷에 나간다. `install.sh` 가 `scripts/lab-proxy.sh` 로 자동으로 띄운다. Mac 을 재부팅하면 다시 띄워야 한다.
- **ToR.** `ks-tor` VM 이 FRR 로 스위치 역할을 한다(`tor.yml`). 실서버에서는 인벤토리에 `[tor]` 그룹을 두지 않는다.
- **arm64 이미지.** Harbor 공식 이미지는 arm64 가 없어, 노드가 arm64 일 때만 대체 이미지를 쓴다(`templates/harbor-values.yaml.j2`). amd64 실서버는 공식 이미지 그대로다.
- **그 밖의 랩 스크립트.** `scripts/rolling-reload.sh` 는 VM 을 한 대씩 재기동해 메모리 변경을 반영한다.

## 파일 옮기기 (다운로드·git clone 이 안 될 때)

[BUNDLE.md](BUNDLE.md) 에 이 디렉터리의 코드 파일이 파일마다 블럭 하나씩 들어 있다. 각 블럭은 그 파일을 만드는 셸 명령(`cat > 파일 <<'__KS_EOF__' … __KS_EOF__`)이다.

1. 작업할 디렉터리를 만들고 들어간다.

   ```bash
   mkdir -p ~/kubespray-cluster && cd ~/kubespray-cluster
   ```

2. BUNDLE.md 의 블럭을 위에서부터 차례로 복사해 터미널에 붙여넣는다. GitHub 화면에서 블럭 오른쪽 위 복사 버튼을 쓰면 들여쓰기가 그대로 간다. 터미널 붙여넣기가 불안하면, 블럭들을 편집기로 `bundle.sh` 한 파일에 붙여 모은 뒤 `bash bundle.sh` 로 실행해도 된다.
3. 마지막 블럭(sha256 대조)을 붙여넣어 모든 줄이 `OK` 인지 확인한다.

BUNDLE.md 는 `scripts/make-bundle.sh` 로 다시 만든다. 코드를 고치면 같이 다시 만든다.

이 파일들만으로 설치가 끝나지는 않는다. Kubespray 소스(`git clone`), Python 패키지(pip), Helm 차트, 컨테이너 이미지는 설치 중에 인터넷(또는 프록시)에서 받는다. 인터넷이 전혀 없는 망은 INFRA.md 4-3 의 오프라인 절차가 따로 필요하다(미실측).

## 비밀값

Harbor admin 비밀번호는 처음 설치할 때 배포 호스트의 `secrets/harbor-admin` 에 생성되고, 클러스터에는 Secret 으로만 들어간다.
`secrets/`, kubeconfig(`inventory/*/artifacts/`), SSH 설정, 로그는 `.gitignore` 로 제외한다.
