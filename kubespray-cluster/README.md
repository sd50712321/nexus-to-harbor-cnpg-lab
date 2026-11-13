# Kubespray + Cilium 클러스터에 Harbor · CNPG · Longhorn 올리기

control plane 3대(etcd 쿼럼), worker 5대 클러스터를 Kubespray 로 만들고, 그 위에 Harbor 를 올린다.
Harbor 의 DB 는 CloudNativePG(CNPG) 3개 인스턴스, 이미지 저장소는 Longhorn(노드 간 3벌 복제)이다.
밖에서 들어오는 HTTP(S) 는 ingress-nginx 가 VIP 하나로 받고, Harbor 는 그 뒤에서 호스트명으로 구분된다. 그 VIP 는 Cilium 의 L2 공지(같은 서브넷)와 BGP(스위치로 경로 광고) 두 가지로 알린다.

랩(Mac + VMware Fusion VM 9대)에서 설치부터 장애 시험까지 실측했다. 같은 플레이북을 인벤토리만 바꿔 리눅스 배포 서버에서 실서버에 쓴다.

| 문서 | 내용 |
|---|---|
| [INFRA.md](INFRA.md) | 네트워크·보안팀·가상화 담당자에게 요청할 것: 주소 계획, 스위치(L2), BGP, 방화벽 포트 표, 주의점, **노드가 VM 일 때**(6절) |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 구축 중 막힌 지점과 원인을 좁힌 과정 (실서버에도 해당하는 것 표시) |
| [LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md) | Longhorn V2 에서 노드 재부팅 뒤 디스크가 다시 안 붙을 때: 원인(`/dev/sdX` 이름 밀림)과 고정 경로 등록법. 랩 미재현, 공식 문서·이슈 근거 |
| [rendered/](rendered/) | 템플릿을 인벤토리 값으로 풀어 놓은 Helm values·매니페스트와 적용 순서 (아래 '설정 파일') |
| [BUNDLE.md](BUNDLE.md) | **다운로드가 안 될 때**: 모든 코드 파일을 붙여넣기용 블럭으로 모은 것 (아래 '파일 옮기기') |

## 구성

| 구성요소 | 버전 | 역할 |
|---|---|---|
| Kubespray | v2.32.0 | Kubernetes 1.36.4, containerd |
| Cilium | 1.20.2 | CNI(VXLAN), kube-proxy 대체, LB IPAM, L2 공지, BGP control plane |
| kube-vip | Kubespray 내장 | API VIP (ARP) |
| ingress-nginx | chart 4.15.1 (1.15.1) | 진입점. 컨트롤러 3개(worker 마다 하나), VIP 하나. TLS 를 여기서 끝낸다 |
| Longhorn | 1.13.0 | 블록 스토리지. 기본 3벌 복제, CNPG 용 1벌 `longhorn-single` |
| CloudNativePG | chart 0.29.1 (operator 1.30.1) | Harbor DB. 3 인스턴스, 서로 다른 노드, quorum 동기 복제 |
| Harbor | chart 1.18.0 (2.14.0) | 레지스트리. Ingress(호스트명)로 노출. 자체 nginx 파드와 전용 VIP 는 두지 않는다 |
| FRR | Ubuntu 패키지 | (랩 전용) ToR 스위치 역할. 실서버는 네트워크팀 스위치 |

```
           ┌──────── ToR 스위치 (BGP AS 65000) ────────┐
           │  10.250.0.0/24 의 /32 경로만 받음, ECMP    │
           └───────┬──────────────────────────┬─────────┘
       노드 서브넷  │ (L2: API VIP, ingress VIP)  │ BGP 피어 (worker 5대, AS 65010)
   ┌───────────────┴───┐              ┌───────┴─────────────────────────────┐
   │ cp1 cp2 cp3        │              │ w1 … w5                              │
   │ etcd · apiserver   │              │ ingress-nginx(3) → Harbor            │
   │                    │              │ Longhorn · CNPG(3)                   │
   │ kube-vip(API VIP)  │              │ Cilium L2 공지 / BGP 광고            │
   └────────────────────┘              └──────────────────────────────────────┘
```

들어오는 길은 하나다. 서비스를 더 올려도 VIP 는 늘지 않고 Ingress(호스트명)만 는다.

```
사용자·CI·노드 ── https://<harbor_host> ──▶ ingress VIP ──▶ ingress-nginx 컨트롤러 3개 ──▶ Ingress harbor-ingress ──▶ harbor-core / harbor-portal
                  (DNS: 이름 → ingress VIP)   (L2: worker 한 대가 ARP 응답 / BGP: worker 5대로 ECMP)        (/v2·/api·/service·/c → core, 나머지 → portal)
```

- VIP 를 ARP 로 알리는 worker 와 컨트롤러 파드가 있는 worker 는 달라도 된다(`externalTrafficPolicy: Cluster`). 받은 노드가 컨트롤러가 있는 노드로 넘긴다.
- Harbor 전용 VIP 로 직접 노출하던 예전 방식은 `harbor_expose: loadBalancer` 로 남겨 두었다.
- API 서버로 가는 길(kube-vip 의 API VIP)은 이것과 별개다.

## 설치

모든 단계는 다시 실행해도 안전하다. 실패하면 고친 뒤 `--from <단계>` 로 그 단계부터 다시 한다.

```bash
./install.sh                           # 랩: 도구 → VM 9대 → Kubespray → 애드온 → 검증
./install.sh --from cluster            # 단계: tools | vms | cluster | addons | verify
INVENTORY=inventory/prod ./install.sh  # 실서버: VM 단계 없이 SSH 도달 확인부터
```

| 단계 | 하는 일 | 따로 실행 |
|---|---|---|
| tools | macOS 는 brew 로, 리눅스는 설치 여부만 확인. Kubespray 클론과 Python venv | |
| vms | (랩) `vagrant up`, SSH 설정 생성. (실서버) ansible ping | `scripts/00-inventory.sh` |
| cluster | 사전점검(`preflight.yml`) 후 Kubespray `cluster.yml` | `scripts/10-cluster.sh` |
| addons | (랩) ToR FRR → Cilium L2 → ingress-nginx → Longhorn → CNPG → Harbor | `scripts/20-addons.sh` |
| verify | 노드·VIP·etcd·Cilium·BGP·Longhorn·CNPG·Harbor, push/pull | `scripts/30-verify.sh` |

**구성요소 하나만 설치하거나 바꿀 때**는 `scripts/addon.sh` 를 쓴다. 환경에 이미 있는 것은 인벤토리에서 끈다.

```bash
./scripts/addon.sh ingress  # ingress-nginx (VIP 하나)
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
| ingress 컨트롤러 | `ingress_nginx_enabled: false`. Harbor Ingress 의 `className` 은 `templates/harbor-values.yaml.j2` 에서 그 컨트롤러 것으로 |
| Harbor 에 전용 VIP 를 주고 싶음 | `harbor_expose: loadBalancer`, `harbor_vip` (ingress 를 거치지 않는다) |
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
vi inventory/prod/group_vars/all/env.yml           # NIC, API VIP, ingress VIP, Harbor 호스트명, L2 풀, BGP, 프록시, 스토리지·DB 토글, 크기
vi inventory/prod/group_vars/k8s_cluster/k8s.yml   # 파드·서비스 대역 (사내망과 겹치지 않게)
INVENTORY=inventory/prod ./install.sh
```

견본은 CP 3 + worker 5, 노드가 VM 인 경우로 적어 두었다(NIC 하나, BGP 꺼짐). VM 에서 따로 확인할 것(템플릿 복제 식별자, 가상 스위치의 VIP 허용, 물리 호스트 분산, 스냅샷 멈춤 등)은 INFRA.md 6절에 있고, 그중 노드에서 볼 수 있는 것은 `preflight.yml` 이 설치 전에 검사한다.

배포 서버는 리눅스(점프 호스트)를 전제로 한다. 노드 OS 는 Ubuntu 24.04 에서 실측했다. `preflight.yml` 과 Longhorn 준비 작업은 RHEL 계열 분기도 갖고 있지만 실측하지 않았다.

## 설정 파일

설정은 네 군데에 있다. 환경마다 바뀌는 값은 인벤토리에만 있고, 나머지 파일은 그 값을 읽는다.

| 파일 | 들어 있는 것 | 읽는 쪽 |
|---|---|---|
| `inventory/<환경>/inventory.ini` | 노드 이름·IP·역할 | Kubespray, `addons.yml` |
| `inventory/<환경>/group_vars/all/` (랩 `lab.yml`, 견본 `env.yml`) | **환경마다 바뀌는 값 전부**: NIC, API VIP, ingress VIP, Harbor 호스트명, L2 풀, BGP, 프록시, 구성요소 켜기/끄기, StorageClass, 크기 | 전부 |
| `inventory/<환경>/group_vars/k8s_cluster/` (랩 `lab.yml`, 견본 `k8s.yml`) | Kubespray 변수: Cilium(VXLAN, kube-proxy 대체, L2 공지, LB IP 풀, BGP), kube-vip, 파드·서비스 대역, 인증서 자동 갱신 | Kubespray `cluster.yml` |
| `versions.yml` | 애드온 차트 버전 4개. Kubespray 버전은 `install.sh` 의 `KUBESPRAY_VER` | `addons.yml`, `render.yml` |
| `templates/*.j2` | Helm values·매니페스트 원본(변수가 들어 있다) | `addons.yml`, `render.yml` |
| `rendered/<환경>/` | 위 템플릿을 그 환경 값으로 푼 결과 7개 + 적용 순서(`README.md`). 만들어진 파일이라 직접 고치지 않는다 | 사람 |

값이 실제로 어떻게 들어가는지는 풀어 놓은 파일로 본다. 클러스터에 접속하지 않고 만든다.

```bash
./scripts/render-values.sh                                  # rendered/lab
INVENTORY=inventory/prod ./scripts/render-values.sh         # rendered/prod (노드가 arm64 면 ARCH=arm64)
```

- [rendered/lab/](rendered/lab/) 은 랩 클러스터에 지금 적용돼 있는 파일과 같다(첫 control plane 의 `/root/lab-addons/` 7개와 바이트 단위로 대조).
- [rendered/prod-sample/](rendered/prod-sample/) 은 견본 인벤토리의 자리표시자 값으로 푼 것이다. 주소·호스트명·크기는 실제 값이 아니다.
- **클러스터를 다른 도구로 만들었을 때**(사내 설치 스크립트 등)는 `rendered/<환경>/README.md` 의 순서대로 helm·kubectl 로 직접 적용할 수 있다. 그 순서는 `addons.yml` 이 실행하는 명령을 옮겨 적은 것이고, 손으로 따라 하는 경로는 이 랩에서 따로 돌려 보지 않았다. 이때 클러스터 쪽에 먼저 있어야 하는 것은 Cilium 의 LB IP 풀과 L2 공지다(`group_vars/k8s_cluster/` 의 `cilium_l2announcements`, `cilium_loadbalancer_ip_pools`). worker 의 Longhorn 사전 조건(open-iscsi 등)은 `addons.yml` 의 첫 플레이다.
- 비밀값은 어느 파일에도 없다. Harbor admin 비밀번호는 Secret 이름만 values 에 있다(아래 '비밀값').

## 초기화

아래로 갈수록 많이 지운다. 확인 문구를 입력해야 진행한다(`FORCE=1` 이면 생략).

```bash
./reset.sh apps      # Harbor·CNPG·Longhorn 제거, 클러스터 유지      → ./install.sh --from addons
./reset.sh cluster   # Kubespray reset.yml + Longhorn 데이터 삭제    → ./install.sh --from cluster
./reset.sh vms       # (랩 전용) VM 삭제                             → ./install.sh --from vms
```

Longhorn 볼륨, CNPG DB, Harbor 이미지가 모두 사라진다. 실서버는 백업 먼저.

## 실측 결과 (랩)

랩 사양: Apple Silicon Mac(32GB), VMware Fusion, Ubuntu 24.04 arm64. CP 2560MB × 3, worker 2688MB × 5, 2 vCPU.
처음에는 worker 1920MB × 7 이었다. 메모리 부족으로 Longhorn 이 퇴거되는 일이 반복되어 합계는 그대로 두고 5대로 줄였다(TROUBLESHOOTING 16절). 아래 A~F 와 재설치 시간은 7대 때, G 이후는 표에 적은 구성에서 잰 값이다.
아래 시간은 이 랩 기준이다. 실서버 값으로 단정하지 말고 같은 스크립트로 다시 잰다.

시험 실행 명령. 결과는 `logs/` 에 남는다. Harbor 주소는 `scripts/harbor-env.sh` 한 곳에서 정한다. 40·50·60·62 는 **랩 VM 을 끄고 켜는 시험**이라 실서버에서 그대로 돌리지 않는다.

```bash
./scripts/30-verify.sh               # 검증 16항목
./scripts/40-failover.sh             # 장애 시험 A·B·C
./scripts/50-more-tests.sh           # 추가 시험 F·D·E (하나만: ./scripts/50-more-tests.sh E)
./scripts/60-db-node-loss.sh         # 시험 G: DB standby 가 있는 worker 가 돌아오지 않을 때
./scripts/61-db-move-instance.sh harbor-pg-2   # 시험 H: 노드를 빼기 전에 그 노드의 DB standby 를 다른 worker 에 다시 만들기 (노드 cordon 먼저)
./scripts/62-ingress-failover.sh     # 시험 K·L·M: 진입점(ingress VIP). 하나만: ./scripts/62-ingress-failover.sh K
```

**검증** (`scripts/30-verify.sh`): 16개 항목 모두 통과. BGP 피어 5대 Established, ToR 에 Harbor BGP VIP ECMP 경로 5개(worker 수는 인벤토리에서 읽는다), CNPG 복제 2개 quorum, ingress 컨트롤러 3개와 Harbor Ingress, Mac 에서 ingress VIP(호스트명)로 push/pull, ToR 에서 BGP VIP 로 같은 호스트명 응답.

**장애 시험** (`scripts/40-failover.sh`, `scripts/50-more-tests.sh`, `scripts/60-db-node-loss.sh`, `scripts/61-db-move-instance.sh`, `scripts/62-ingress-failover.sh`)

같은 시험을 여러 번 돌렸다(설치를 다시 한 클러스터 포함). 값이 다를 때는 범위로 적었다.
A~E, G~J 는 Harbor 를 전용 VIP(`harbor_expose: loadBalancer`)로 노출하던 때의 값이다. ingress 로 바꾼 뒤에는 검증 16항목과 F, K, L, M 만 다시 쟀다.

| 시험 | 결과 |
|---|---|
| A. API VIP 를 가진 CP 강제 정지 | 13~19초 뒤 VIP 가 다른 CP 로 이동, API 응답. etcd 2/3 로 쓰기 성공, Harbor pull 성공. 네 번 중 한 번은 정지 17초 뒤 첫 쓰기가 일시 실패(TROUBLESHOOTING 15절) |
| B. CNPG primary 파드 삭제 | 새 primary 18~21초, Harbor DB 조회는 그 뒤 3~6초에 복구. 설정 조정 전에는 173초(9절) |
| C. registry 파드가 있는 worker 강제 정지 | registry 는 367~416초 뒤 다른 노드에서 재기동(300초는 쿠버네티스 기본 축출 대기, 11절). Harbor 전체 복구는 그 노드에 registry 만 있었으면 380초, core·Redis 등까지 몰려 있었으면 558~575초(14절). 기존 이미지 pull 성공 |
| D. registry 볼륨 복제본 1벌을 가진 worker 정지 | 25~34초 뒤 degraded. 그 상태에서 새 이미지 push 성공. 110~120초 뒤 다른 노드에 복제본을 다시 만들어 healthy. 노드가 돌아온 뒤 옛 복제본은 실패 30분 뒤(`staleReplicaTimeout`) 자동 삭제 |
| E. CNPG primary 를 가진 worker 강제 정지 | 58~92초 뒤 새 primary. 64~95초에 Harbor 프로젝트 생성(DB 쓰기) 성공, 새 이미지 push·pull 성공. 노드 복귀 후 옛 primary 가 replica 로 재합류, 새 프로젝트 행이 replica 에도 있음 |
| F. BGP VIP 로 push/pull (ToR 에서) | ToR 가 Harbor 호스트명을 BGP VIP 로 풀게 해 두고 잰다. ECMP 다음 홉 5개, 토큰 발급 주소는 같은 호스트명. pull, 새 태그 push, 되받은 manifest 동일 |
| G. DB standby 가 있는 worker 가 돌아오지 않음 (7대, 1회) | 420초 동안 새 인스턴스가 **만들어지지 않음**(PVC 가 남아 있어 그 노드를 기다린다). 그 인스턴스의 PVC + 파드를 지우면 3초 뒤 다른 worker 에서 만들기 시작, 33초 뒤 Ready·복제 2개. 옛 볼륨은 남는다(TROUBLESHOOTING 19절) |
| H. 노드를 빼기 전 DB standby 다시 만들기 (7대 → 5대로 줄이며 2회) | 41초, 49초 뒤 다른 worker 에서 Ready·복제 2개. 그동안 Harbor 프로젝트 생성(DB 쓰기) 10/10, 12/12 성공 |
| I. worker 제거 (Kubespray `remove-node.yml`, 2회) | 두 번 모두 정상 종료. 그 전에 옛 DB 볼륨이 drain 을 막았고, Longhorn 복제본 비우기 요청은 strict-local 볼륨에서 멈췄다(20절). 플레이북이 남는 노드에도 패키지 점검을 돌려 메모리가 빠듯한 노드에서 Longhorn 이 퇴거됐다(21절) |
| J. worker 5대를 한 대씩 재기동 (`rolling-reload.sh`, 2688MB 로 올리며) | 노드 Ready 까지 64~109초, 그 뒤 DB 3/3 + 볼륨 healthy 까지 37~104초. 뒤의 3대를 재기동하는 약 10분 동안 2초 간격 쓰기 275번 중 94번 실패: Redis·nginx·portal 이 있던 노드에서 약 3분(14절과 같은 원인), primary 가 있던 노드에서 27초. Harbor 파드도 DB 도 없던 노드에서는 실패 없음 |
| K. Ingress 의 요청 본문 크기 (3MB 업로드) | 차트 기본값 `proxy-body-size: "0"` 에서 202. `1m` 로 줄이면 nginx 가 413 으로 거절. 되돌리면 다시 202 |
| L. ingress VIP 를 ARP 로 알리는 worker 강제 정지 (1회) | 약 15초 동안 모든 요청 실패, 그 뒤 다른 worker 가 VIP 를 넘겨받아 정상(L2 공지 lease 15초). 그 worker 에 컨트롤러 파드는 없었다. 노드가 돌아와도 VIP 는 넘겨받은 노드에 남는다 |
| M. ingress-nginx 컨트롤러 파드가 있는 worker 강제 정지 (2회) | VIP 는 그대로. 정지 후 43초, 46초까지 요청 일부가 2초 타임아웃(40번 중 11번, 38번 중 13번), 노드가 NotReady 로 판정된 뒤로는 남은 컨트롤러 2개로만 가서 실패 없음. 그 노드에 registry·jobservice 가 같이 있던 회차는 노드가 150초 만에 돌아온 뒤에도 두 파드가 다른 worker 에 다시 만들어져, push/pull 은 정지부터 약 5분 뒤에 복구(TROUBLESHOOTING 25절) |

**초기화 후 재설치** (`reset.sh` 각 모드 → `install.sh --from …`, 확인 문구는 `FORCE=1`)

| 모드 | 초기화 | 재설치 + 검증 | 검증 |
|---|---|---|---|
| apps | 1분 35초 | 8분 | 16/16 |
| cluster | 4분 30초 | 31분 30초 (Kubespray 18분) | 16/16 |
| vms (VM 까지 삭제, 빈 상태부터) | 2분 | 46분 (VM 11분, Kubespray 18분 40초, 애드온 15분) | 16/16 |

`install.sh` 의 tools 단계(brew 설치)는 이 Mac 의 Homebrew 가 macOS 버전을 인식하지 못해 시험하지 못했다. 도구는 미리 설치된 상태에서 vms 단계부터 돌렸다.

**아직 시험하지 않은 것**

- 이 클러스터에서의 CNPG 백업과 복구. 백업 저장소(S3 호환)가 필요하다. 같은 CNPG 버전으로 barman-cloud 플러그인 + MinIO 백업과 시점 복구(PITR)를 잰 기록은 상위 README 의 5차 절에 있다.
- Harbor 자체 이중화. core·registry·Redis 가 1개씩이고 분산 규칙이 없어, 그 파드가 있는 노드가 죽으면 6~10분 멈춘다(시험 C, TROUBLESHOOTING 14절). 진입점(ingress-nginx)은 3개라 버티지만 그 뒤가 1개다(시험 M).
- **노드(containerd)가 Harbor 호스트명으로 pull 하는 것.** 지금까지의 push/pull 은 Mac 과 ToR 의 skopeo 다. 노드는 그 이름을 풀 수 있어야 하고 인증서의 CA 를 믿어야 한다(INFRA.md 5절).
- worker 가 API 서버로 가는 길을 Kubespray 의 노드 로컬 nginx(`nginx-proxy`)로 두는 구성. 이 랩은 kube-vip 의 API VIP 다.
- `externalTrafficPolicy: Local`(클라이언트 IP 보존)에서의 VIP 전환.
- 노드 OS RHEL 계열, 오프라인(인터넷 없는 망) 설치.
- etcd 스냅샷으로 되돌리기.
- VM 플랫폼에 달린 것: IP·MAC 필터가 있는 가상 스위치에서의 VIP, VM 스냅샷·라이브 마이그레이션 중의 동작, 공유 데이터스토어에서의 etcd 쓰기 지연, 사내 iSCSI 스토리지와 같이 쓰는 경우(INFRA.md 6절). 랩 노드도 VM 이지만 Mac 한 대 위의 host-only 망이라 이 조건들이 없다.

## 랩 전용 사항

- **Mac 자원.** VM 9대가 디스크 약 69GB(시험을 여러 번 돌린 뒤 값, 새로 만든 직후는 더 작다), 메모리 설정 합계 약 21GB 를 쓴다. 시작 전 디스크 여유 80GB 이상, Docker Desktop 같은 다른 VM 은 끈다(TROUBLESHOOTING 7·8절).
- **랩 프록시.** 이 Mac 은 VMware NAT 가 동작하지 않아, Mac 의 host-only 주소에 HTTP 프록시를 띄워 노드가 인터넷에 나간다. `install.sh` 가 `scripts/lab-proxy.sh` 로 자동으로 띄운다. Mac 을 재부팅하면 다시 띄워야 한다.
- **Harbor 호스트명.** 이 Mac 은 `/etc/hosts` 를 고칠 권한이 없어, 주소가 이름에 들어 있는 공개 DNS 이름(`harbor.<ingress VIP>.sslip.io`)을 쓴다. 인터넷 DNS 가 되어야 풀린다. 실서버는 사내 DNS 레코드다(INFRA.md 1절). 인증서도 차트가 만든 자체 서명이라 시험 스크립트는 검증을 끈다(`curl -k`, `skopeo … --src-tls-verify=false`).
- **ToR.** `ks-tor` VM 이 FRR 로 스위치 역할을 한다(`tor.yml`). 실서버에서는 인벤토리에 `[tor]` 그룹을 두지 않는다.
- **arm64 이미지.** Harbor 공식 이미지는 arm64 가 없어, 노드가 arm64 일 때만 대체 이미지를 쓴다(`templates/harbor-values.yaml.j2`). amd64 실서버는 공식 이미지 그대로다.
- **그 밖의 랩 스크립트.** `scripts/rolling-reload.sh` 는 VM 을 한 대씩 재기동해 메모리 변경을 반영한다. `WAIT_DB=1` 을 주면 다음 노드로 넘어가기 전에 DB 3/3 과 붙어 있는 Longhorn 볼륨 healthy 를 기다린다.
- **지운 VM.** worker 를 7대에서 5대로 줄일 때 `ks-w6`·`ks-w7` 은 클러스터에서 빼고 꺼 두었다가, 2026-11-13 에 호스트 디스크 확보를 위해 지웠다. 7대로 되돌리는 방법은 `Vagrantfile` 머리말에 있다.

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
`secrets/`, kubeconfig(`inventory/*/artifacts/`), SSH 설정, 로그는 `.gitignore` 로 제외한다. `rendered/` 에는 Secret 이름만 있고 값은 없다.
