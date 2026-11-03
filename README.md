# Nexus → Harbor + CloudNativePG 이관 실측 랩

폐쇄망에서 운영 중인 Nexus Repository(3.82 CE)의 **커스텀 docker 이미지·helm 차트만** Harbor 로 옮기고, Harbor 의 DB 를 CloudNativePG(CNPG) 로 두는 구성을 랩 클러스터에서 **처음부터 끝까지 실제로 구축·이관·검증**한 기록입니다. Nexus 는 그대로 유지합니다.

모든 수치는 실측값이고, 겪은 이슈와 주의점을 해당 단계에 함께 적었습니다.

## 구성

| 항목 | 랩(검증) | 운영 권장 |
|---|---|---|
| Harbor | 2.14.0 (chart 1.18.0, arm64 빌드 `ghcr.io/octohelm/harbor/*`) | **2.15.4 (chart 1.19.4, 공식 `goharbor/*`)** — 공식 이미지는 amd64 전용 |
| CNPG operator | 1.30.1 (chart cloudnative-pg 0.29.1) | 동일 |
| PostgreSQL | 16.15 (`ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm`) | 동일, instances 3 |
| helm 차트 저장 | OCI 아티팩트 (`helm push/pull oci://`) | 동일 — ChartMuseum 없음 |
| 1차 비교 대상 | Harbor 2.7.0 (chart 1.11.0, ChartMuseum 있음) | 참고용 |



## 핵심 실측 결과

- **이관**: 이미지 7개(단일아치·OCI·멀티아치 index·동일 digest 태그 3개·60MB) 복사 후 **digest 전부 원본과 동일**, 차트 6개 OCI push 후 `helm pull oci://` 로 받은 tgz **원본과 바이트 동일**. 재실행 시 전부 건너뜀, 원본에 추가분이 있으면 그것만 복사(델타 동기화).
- **클러스터 배포**: Harbor 의 OCI 차트 + Harbor 의 이미지로 `helm install` → Running, 서비스 200, 파드 imageID = 이관 digest. 멀티아치 태그는 노드가 자기 아키텍처 선택.
- **CNPG 파드 재시작**: 기본 `smartShutdownTimeout`(180s)이면 193초(Harbor 커넥션 풀이 안 끊겨 대기), 15초로 두면 28초. 실제 서비스 끊김은 둘 다 ~11초. **DB 가 없는 동안 pull 도 401** — DB 장애 = 레지스트리 장애.
- **백업**: `pg_dump -Fc` 무중단 → 새 CNPG 클러스터에 복구, 행 수 일치. 백업 대상은 **DB + registry 저장소** 두 곳.

## 겪은 이슈 (전부 해결)

| 이슈 | 원인 | 해결 |
|---|---|---|
| 1차 이관 docker 전부 `trying to reuse blob`, 차트 401 | 로봇 이름 `robot$migrator` 의 `$` 가 셸 변수로 풀려 사용자명이 `robot` | 비밀값 파일을 작은따옴표로 저장 |
| `kubectl apply` CNPG 매니페스트 실패 `annotations: Too long` | CRD 크기 | `kubectl apply --server-side` |
| Harbor 차트 `maxOpenConns` 기본 900 | PG `max_connections` 200 초과 | 50 으로 조정 |
| jobservice 초기 2회 재시작 | redis 준비 전 기동 | 정상, 조치 불필요 |
| 로봇으로 프로젝트 저장소 목록 API 403 | 로봇 권한 범위 | 개별 아티팩트 목록은 200; 전체 목록은 admin 으로 |
| 공식 goharbor 2.15 이미지 arm64 없음 | amd64 단일 아키 | arm64 랩은 2.14.0(octohelm) |

## 사용자 체감 변경 (ChartMuseum → OCI)

`helm repo add` / `helm search repo` 는 없어집니다. `helm registry login <harbor>` 후 `helm pull oci://<harbor>/charts/<이름> --version <버전>`, 배포는 `helm install <릴리스> oci://<harbor>/charts/<이름> --version <버전>`. 버전 검색은 Harbor UI 또는 API. helm 3.8 이상 필요.

## 컷오버 순서

1. (무영향) Harbor·CNPG 구축, 초기 동기화, 검증
2. Nexus 의 docker-hosted·helm-hosted 를 Read-only 로 전환
3. 델타 동기화 → 검증
4. CI push 대상, 배포 매니페스트의 이미지 호스트·차트 참조(`oci://`)를 Harbor 로 변경 (이미지 경로는 유지)
5. Nexus 의 두 저장소는 읽기 전용으로 남겨 롤백 경로로, 안정 후 삭제. 다른 저장소는 손대지 않음

이 문서 하나에 절차·실측 기록·설정·스크립트가 모두 들어 있다. 스크립트의 주소·포트·경로는 랩 값(172.16.141.x, NodePort 30004, scratchpad 경로)이고 비밀값은 포함돼 있지 않다.

---

# 부록 A. 실측 기록 (랩 로그 원문)

## 커스텀 docker·helm: Nexus → Harbor 2.7(ChartMuseum) on CloudNativePG — 전체 이관 실측 (2026-11-03)

범위: Nexus 는 그대로 유지. Nexus 의 **커스텀 docker 이미지(docker-hosted)·helm 차트(helm-hosted)만** Harbor 로 옮긴다. Harbor DB 는 CNPG.
랩: k8s-core cp1 단일 노드(arm64, 2 CPU / 2.9 GiB), 폐쇄망 구조(노드는 인터넷 불가, containerd 가 docker.io/ghcr.io/quay.io/registry.k8s.io → 내부 레지스트리 172.16.141.10:5000 미러).
원본: nexus6(3.82.0-08 CE). 산출물: `~/nexus-lab/harbor-cnpg/`.

### 0. 결정 버전
| 구성 | 버전 | 비고 |
|---|---|---|
| CNPG operator | **1.30.1** (Helm chart cloudnative-pg 0.29.1) | 2026-11 최신 |
| PostgreSQL | **16.15** (`ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm`) | Harbor 2.7 스키마 정상 생성 확인 |
| Harbor | **2.7.0** (chart harbor 1.11.0) | ChartMuseum 내장 마지막 계열 — 클래식 `helm repo add` 유지 |
| 랩 이미지 | `ghcr.io/octohelm/harbor/*:v2.7.0` | arm64 빌드. **운영(amd64)은 차트 기본 `goharbor/*:v2.7.0`** |

### 1. 폐쇄망 반입 (registry VM 에서 skopeo, k8s-core `mirror-images.sh` 규칙: 호스트 부분 제거)
- `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1` → `172.16.141.10:5000/cloudnative-pg/cloudnative-pg:1.30.1` (`--all`)
- `ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm` → 같은 규칙
- Harbor 2.7 이미지는 기존 harbor27 설치 때 반입돼 있음. 차트 tgz(cloudnative-pg-0.29.1.tgz, harbor-1.11.0.tgz)는 Mac 에서 받아 로컬 파일로 설치.
- 이 클러스터는 이번 반입 외 다른 설정 변경 없이 미러로 정상 pull.

### 2. CNPG 설치 + Harbor 용 PG 클러스터
- Helm 판: `helm install cnpg cloudnative-pg-0.29.1.tgz -n cnpg-system --create-namespace --set image.tag=1.30.1` → 8초 Running, CRD 11개.
- kubectl 판(검증만): `cnpg-1.30.1.yaml`(릴리스 매니페스트 1.29MB). **일반 `kubectl apply` 는 `metadata.annotations: Too long ... 262144 bytes` 로 실패 → `kubectl apply --server-side`** 필수. 리소스 이름이 Helm 판(`cnpg-cloudnative-pg`)과 달라(`cnpg-controller-manager`) **둘 중 하나만** 설치.
- `harbor-pg.yaml`: instances 1, bootstrap.initdb(database registry / owner harbor), local-path 2Gi, max_connections 200 → **30초에 healthy**. 서비스 `harbor-pg-rw/ro/r`, Secret `harbor-pg-app`(키 username/password/host/uri…).

### 3. Harbor 2.7 설치 (외부 DB = CNPG)
`values-harbor-cnpg.yaml` 핵심:
- `database.type: external`, `external.host: harbor-pg-rw.harbor-cnpg.svc`, `username: harbor`, `coreDatabase: registry`, **`existingSecret: harbor-pg-app`** (차트가 그 Secret 의 키 `password` 를 그대로 읽음 → 비밀번호 복사 불필요, CNPG 가 회전해도 Secret 하나만), **`sslmode: require`** (CNPG 기본 TLS)
- **`maxOpenConns: 50`, `maxIdleConns: 10`** — 차트 기본 900 은 PG max_connections 를 넘어서 부하 시 연결 고갈
- trivy/notary/metrics off, chartmuseum on, NodePort 30004
결과: 설치 후 40초에 전부 Running. PG 에 **테이블 49개, schema_migrations 100**, Harbor 연결 3개 모두 `ssl=t`. 첫 기동 때 jobservice 가 redis 준비 전이라 2회 재시작 후 안정(기동 순서 경합, 정상).

### 4. Harbor 사전 구성
프로젝트 `dlops`(이미지, 비공개)·`charts`(차트, 비공개). 시스템 로봇 `robot$migrator`: dlops = repository pull/push·artifact read·tag create/list, charts = helm-chart read·helm-chart-version create/read·repository pull.
**함정: 로봇 이름의 `$`** — 비밀값을 `ROBOT_NAME=robot$migrator` 로 저장해 `source` 하면 `$migrator` 가 셸 변수로 풀려 사용자명이 `robot` → docker 는 `trying to reuse blob … `(인증 실패), 차트 업로드는 401. 작은따옴표로 저장(`ROBOT_NAME='robot$migrator'`)하자 해결. CI 변수·Secret 생성 시에도 동일.
로봇은 차트 '전체 목록' API(`/api/chartrepo/charts/charts`)는 403, 개별 버전 조회·업로드·index.yaml·helm repo 는 정상.

### 5. 원본 데이터 (nexus6)
docker-hosted: dlops/app1:1.0·1.1·latest(셋 다 같은 digest, docker v2s2), dlops/app2:2.0(OCI), dlops/multi:1(OCI index arm64+amd64), dlops/pybase:3.12(python 3.12-alpine ≈60MB), 이후 증분용 dlops/web:1.0(nginx). helm-hosted: h27a/h27b/h27c × 0.1.0/0.2.0.

### 6. 이관 (`migrate-nexus-to-harbor.sh`, 셸: curl + python3 + skopeo)
- 목록: Nexus REST `GET /service/rest/v1/components?repository=<repo>` (continuationToken 끝까지) → docker 는 name/version, helm 은 .tgz 자산의 downloadUrl·sha256.
- docker: `skopeo copy --all --preserve-digests` Nexus 커넥터 → `<harbor>/<경로>:<태그>`. 경로 규칙: Nexus 이미지 이름의 첫 조각이 Harbor 프로젝트(`dlops/app1` → `harbor/dlops/app1`), 조각 없는 이름은 기본 프로젝트로. 복사 전후 manifest raw 의 sha256 을 비교(같으면 SKIP).
- helm: downloadUrl 로 받고 Nexus 가 준 sha256 으로 검증 → `POST /api/chartrepo/<project>/charts`(multipart, 필드명 `chart`) → 201. 이미 `GET /api/chartrepo/<project>/charts/<name>/<ver>` 가 200 이면 SKIP.
| 실행 | docker | helm |
|---|---|---|
| 1차(로봇 `$` 버그) | 실패 6 | 401 ×6 |
| 2차 | **복사 6, digest 전부 일치**(app1×3 4bdb4ac63839, app2 5ca6a002c5c3, multi index ba1199205458, pybase 5642cb13b1fc) | **업로드 6** |
| 3차(재실행) | SKIP 6 | SKIP 6 |
| 4차(원본에 web:1.0 추가 뒤 = 컷오버 직전 델타) | **복사 1, SKIP 6** | SKIP 6 |

### 7. 사용자 관점 검증
- helm(v4.3.0): `helm repo add hbcharts http://<harbor>/chartrepo/charts --username 'robot$migrator'` → `helm search repo -l` 6버전 → `helm pull` 6개 **원본과 바이트 동일 6/6**, index.yaml digest 도 원본 sha256 과 일치.
- 클러스터(containerd): 노드 `/etc/containerd/certs.d/172.16.141.11:30004/hosts.toml`(HTTP) 추가 — `config_path` 방식이라 containerd 재시작 불필요. 네임스페이스에 로봇으로 `imagePullSecret` 생성.
  - `helm upgrade --install web hbcharts/h27a --version 0.2.0 --set image.repository=<harbor>/dlops/web …` → **Running, 서비스 200**, imageID digest 63ffc0d1f14e = 이관 digest.
  - `dlops/pybase:3.12` 파드 → `pybase-ok aarch64 3.12.16`, Succeeded.
  - `dlops/multi:1`(태그) → repoDigest = index ba1199205458(원본과 동일), 노드가 arm64 선택. (컨테이너는 CMD 없는 더미라 start 실패 — 이관 무관)

### 8. 운영 점검
### 8.1 CNPG 파드 재시작(단일 인스턴스) 시 Harbor
| 설정 | 옛 파드 종료 | 새 파드 ready | pull 실패 | API·push 실패 |
|---|---|---|---|---|
| 기본(`smartShutdownTimeout` 180) | **182초** | 193초 | 11초 | 11초 |
| `smartShutdownTimeout: 15` | **16초** | 28초 | 3초 | 13초 |
- 기본에서 182초가 걸리는 이유: PG '스마트 종료'가 클라이언트 연결이 끊기길 기다리는데 Harbor 커넥션 풀은 스스로 끊지 않음 → 타임아웃까지 그냥 대기. 그동안은 기존 연결로 정상 동작.
- DB 가 실제로 없는 구간에는 **pull 도 401**(Harbor 인증·토큰 검증에 DB 필요) — DB 장애 = 레지스트리 장애. Harbor 파드는 재시작 없이 자동 복구.
- 운영 권장: instances 3(+ 노드 분산)으로 두고 계획 작업은 switchover(`kubectl cnpg promote`) — 단일이면 smartShutdownTimeout 축소.
### 8.2 DB 백업·복구
`kubectl exec harbor-pg-1 -c postgres -- pg_dump -U postgres -d registry -Fc` (Harbor 무중단) 156KB → 새 CNPG 클러스터(harbor-pg-restore, 20초 healthy)에 `pg_restore` → project 3 / repository 6 / artifact 8 / tag 150 / robot 1 / harbor_user 2 / schema 100 **원본과 동일**, 49 테이블 소유자 harbor 유지. 시험 후 삭제.
- **DB 만으로는 Harbor 백업이 아니다**: 이미지 blob 은 registry PVC(또는 S3), 차트는 chartmuseum PVC 에 있다 → DB + 두 저장소를 같은 시점으로 백업.

### 9. 랩 상태(종료 시점)
- 가동: cnpg-system(operator), harbor-cnpg(harbor-pg + harborcnpg 7개 파드, NodePort 30004). 시험 앱 ns migtest 삭제.
- **ns harbor(Harbor 2.13) 는 메모리 확보를 위해 replicas 0 으로 내려 둠** — 원래 replica 는 scratchpad `harbor-replicas.txt`(전부 1). 복원: `kubectl -n harbor scale deploy,sts --all --replicas=1` (단 harbor-cnpg 와 동시 가동 시 노드 가용 메모리 763MB 로 빠듯).
- cp1 containerd 에 `/etc/containerd/certs.d/172.16.141.11:30004/hosts.toml` 추가(지우면 원복).
- 비밀값(Harbor admin, 로봇 secret)은 scratchpad `hc.admin`, `hc.robot` 에만.

### 2차: Harbor 최신 세대(2.14.0, ChartMuseum 없음 → helm OCI) + CNPG 로 재이관 (2026-11-03 14:55~15:04)
사용자 결정: Harbor 는 최신으로. 공식 `goharbor/*:v2.15.4`(chart 1.19.4)는 **amd64 단일 아키**라 arm64 랩 노드에서 못 띄움 → 랩은 arm64 빌드가 있는 최신인 **2.14.0**(`ghcr.io/octohelm/harbor/*:v2.14.0`, chart 1.18.0). 운영(amd64)은 2.15.4 공식 이미지에 같은 values 키를 쓴다. 두 버전 모두 ChartMuseum 이 없는 세대라 이관·운영 방식은 동일.

### 1. 준비
- 2.7 환경(release harborcnpg, CNPG harbor-pg, PVC) 삭제 → 메모리 확보. 같은 `harbor-pg.yaml` 로 CNPG 클러스터 재생성(24초 healthy, Secret `harbor-pg-app`).
- 이미지 8종(core, jobservice, registry-photon, registryctl, portal, nginx-photon, redis-photon, exporter) `--override-os linux --override-arch arm64` 로 내부 레지스트리에 반입: 45초.
- chart 1.18.0 차이: `chartmuseum:` 섹션 없음, `existingSecretAdminPassword`/`existingSecretAdminPasswordKey` 로 관리자 비밀번호를 Secret 에서 읽음(1.11 에는 없던 키), `database.external.*` 키는 동일(`existingSecret`, `sslmode`, `maxOpenConns`).
- values: `values-harbor214-cnpg.yaml`. 관리자 Secret `harbor-admin`(키 HARBOR_ADMIN_PASSWORD) 먼저 생성.

### 2. 설치 결과
`helm install harbor214 harbor-1.18.0.tgz -n harbor-cnpg -f values-harbor214-cnpg.yaml` → 전 파드 Ready **61초**. jobservice 2회 재시작(redis 준비 전, 정상). systeminfo `harbor_version=v2.14.0`, `with_chartmuseum` 없음. PG: 테이블 49, **schema_migrations 170**(2.7 은 100), Harbor 연결 3/3 TLS.

### 3. Harbor 구성 (2.8+ 는 차트가 OCI 아티팩트 → 권한 모델이 이미지와 동일)
프로젝트 dlops(이미지)·charts(차트). 로봇 `robot$migrator` 권한: 두 프로젝트 모두 repository pull/push, artifact read/list, tag create/list. (2.7 의 helm-chart 리소스는 없음.) 비밀값 파일은 작은따옴표로.

### 4. 이관 (`migrate-nexus-to-harbor-oci.sh`)
docker 부분은 1차와 동일. helm 부분만 변경: 존재 확인은 `GET /api/v2.0/projects/charts/repositories/<차트명>/artifacts/<버전>`(200 이면 SKIP), 업로드는 `helm registry login` 후 **`helm push <tgz> oci://<harbor>/charts`**. helm ≥3.8 필요(랩 4.3.0, http 라 `--plain-http`).
| 실행 | docker | helm |
|---|---|---|
| 1차 | **복사 7, digest 전부 일치** (app1×3, app2, multi index ba1199205458, pybase, web) | **push 6** (OCI digest 는 tgz sha 와 다름 — 정상. Harbor 가 CHART 타입으로 인식, 태그=차트 버전) |
| 2차(재실행) | SKIP 7 | SKIP 6 |

### 5. 사용자 관점 검증
- `helm pull oci://<harbor>/charts/<이름> --version <버전>` 6개 → **원본 tgz 와 바이트 동일 6/6**. `helm show chart oci://…` 정상.
- **`helm repo add`/`helm search repo` 는 없다.** 버전 목록은 Harbor API(`/api/v2.0/projects/charts/repositories/<이름>/artifacts`) 또는 UI 로 본다. 로봇은 이 artifacts 목록 200, 프로젝트의 **repositories 목록은 403**(admin 은 200) — 전체 차트 목록을 긁는 스크립트는 admin 계정이나 별도 권한 필요.
- 클러스터: `helm upgrade --install web oci://<harbor>/charts/h27a --version 0.2.0 --set image.repository=<harbor>/dlops/web …` → Running, 서비스 200, imageID 63ffc0d1f14e(이관 digest). pybase 파드 `pybase-ok aarch64`. multi:1 repoDigest = index(…7201f6), arm64 선택.

### 6. 운영 점검 (2.14)
- CNPG 파드 재시작(`smartShutdownTimeout: 15`): 옛 파드 종료 16s, 새 파드 ready 28s, **pull·API·push 실패 구간 11초**(2.7 때와 동일 패턴; API 는 이번엔 500 으로 응답).
- `pg_dump -Fc` 무중단 157KB, project 3 / repository 9 / artifact 14 / schema 170.
- 2.7 과 달리 차트가 registry 저장소(blob)에 들어가므로 **백업 대상은 DB + registry PVC 두 곳**(chartmuseum PVC 없음).

### 7. 랩 상태
harbor-cnpg: harbor-pg + harbor214 7파드(NodePort 30004) 가동. ns harbor(2.13) 는 replicas 0 유지. 노드 가용 메모리 855MB. 비밀값은 scratchpad `hc.admin`, `hc.robot214`.

---

# 부록 B. 설정 파일

## B-1. CNPG Cluster (`harbor-pg.yaml`)

```yaml
# Harbor 전용 PostgreSQL (CloudNativePG)
# 랩: 단일 노드라 instances: 1. 운영은 3 (+ 노드 분산) 권장.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: harbor-pg
  namespace: harbor-cnpg
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm   # containerd 미러로 내부 레지스트리에서 받음
  primaryUpdateStrategy: unsupervised
  # Harbor 는 커넥션 풀을 계속 쥐고 있어 '스마트 종료'가 스스로 끝나지 않는다 → 기본 180초를 그냥 기다림.
  # 단일 인스턴스면 줄여서 재시작 시간을 단축(실측: 기본 182초 → 아래 값).
  smartShutdownTimeout: 15

  # Harbor core 가 쓰는 DB 하나를 처음부터 만든다.
  #   DB 이름 registry / 소유자 harbor
  #   비밀번호는 CNPG 가 생성해 Secret harbor-pg-app (키: username, password) 에 넣는다.
  bootstrap:
    initdb:
      database: registry
      owner: harbor

  postgresql:
    parameters:
      max_connections: "200"        # Harbor core/jobservice/exporter 커넥션 풀 합계 여유
      shared_buffers: "128MB"

  storage:
    storageClass: local-path
    size: 2Gi

  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {memory: 512Mi}
```

## B-2. Harbor 2.14/2.15 values (`values-harbor214-cnpg.yaml`)

```yaml
# Harbor chart 1.18.0 (Harbor 2.14.0, ChartMuseum 없음 → helm 은 OCI) + 외부 DB = CloudNativePG(harbor-pg)
# 랩(cp1 arm64): 이미지 ghcr.io/octohelm/harbor/*:v2.14.0 (arm64 빌드). containerd 가 ghcr.io → 172.16.141.10:5000 미러.
# 운영(amd64): 이미지 블록을 모두 지우고 차트 기본값(goharbor/*:v2.15.4, chart 1.19.4)을 쓴다. 나머지 키는 동일.
expose:
  type: nodePort
  tls:
    enabled: false
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: 30004
externalURL: http://172.16.141.11:30004

# 관리자 비밀번호: values 에 쓰지 않고 미리 만든 Secret 을 참조 (chart ≥1.17)
existingSecretAdminPassword: harbor-admin
existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD

persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:   {storageClass: local-path, size: 5Gi}
    jobservice:
      jobLog:   {storageClass: local-path, size: 1Gi}
    redis:      {storageClass: local-path, size: 1Gi}
    trivy:      {storageClass: local-path, size: 1Gi}

# ---- DB: CNPG ----
database:
  type: external
  external:
    host: harbor-pg-rw.harbor-cnpg.svc
    port: "5432"
    username: harbor
    coreDatabase: registry
    existingSecret: harbor-pg-app     # CNPG 생성 Secret, 키 'password'
    sslmode: require
  maxIdleConns: 10
  maxOpenConns: 50                    # 차트 기본 900 → PG max_connections(200) 안으로

trivy:   {enabled: false}
metrics: {enabled: false}

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
```

---

# 부록 C. 스크립트

## C-1. 프로젝트·로봇 생성 (`harbor214-setup.sh`)

```bash
#!/bin/bash
# Harbor 2.14 초기 구성: 프로젝트 2개 + 시스템 로봇. ChartMuseum 이 없으므로 차트도 OCI 아티팩트 → 권한은 이미지와 동일(repository pull/push)
set -uo pipefail
H=${H:-http://172.16.141.11:30004}
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
HA="admin:$(cat $S/hc.admin)"
OUT=~/nexus-lab/logs/harbor-cnpg/setup214.txt; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
log "Harbor 버전: $(curl -s -u "$HA" $H/api/v2.0/systeminfo | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("harbor_version"), "| chartmuseum:", d.get("with_chartmuseum"))')"
for p in dlops charts; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -u "$HA" -X POST "$H/api/v2.0/projects" -H 'Content-Type: application/json' -d "{\"project_name\":\"$p\",\"public\":false}")
  log "프로젝트 $p → $c"
done
body='{"name":"migrator","description":"Nexus→Harbor 이관 및 CI","duration":-1,"level":"system","disable":false,
 "permissions":[
  {"kind":"project","namespace":"dlops","access":[
     {"resource":"repository","action":"pull"},{"resource":"repository","action":"push"},
     {"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"},
     {"resource":"tag","action":"create"},{"resource":"tag","action":"list"}]},
  {"kind":"project","namespace":"charts","access":[
     {"resource":"repository","action":"pull"},{"resource":"repository","action":"push"},
     {"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"},
     {"resource":"tag","action":"create"},{"resource":"tag","action":"list"}]}
 ]}'
resp=$(curl -s -u "$HA" -X POST "$H/api/v2.0/robots" -H 'Content-Type: application/json' -d "$body")
name=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("name",""))' 2>/dev/null)
secret=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("secret",""))' 2>/dev/null)
if [ -n "$secret" ]; then
  printf "ROBOT_NAME='%s'\nROBOT_SECRET='%s'\n" "$name" "$secret" > $S/hc.robot214; chmod 600 $S/hc.robot214   # 이름에 $ 포함 → 작은따옴표 필수
  log "로봇 생성: $name (비밀값은 scratchpad/hc.robot214)"
else log "로봇 생성 응답: $(echo "$resp" | cut -c1-200)"; fi
log "프로젝트: $(curl -s -u "$HA" "$H/api/v2.0/projects" | python3 -c 'import sys,json;print([p["name"] for p in json.load(sys.stdin)])')"
```

## C-2. 이관 (`migrate-nexus-to-harbor-oci.sh`)

```bash
#!/bin/bash
# Nexus(docker-hosted, helm-hosted) → Harbor 2.8+ (ChartMuseum 없음: 차트는 OCI 아티팩트)
# 필요 도구: curl, python3, skopeo, helm ≥3.8 (OCI). 재실행 안전(이미 있으면 건너뜀).
set -uo pipefail
NX=${NX:-http://127.0.0.1:8096}; NX_DOCKER=${NX_DOCKER:-127.0.0.1:35600}
NX_DOCKER_REPO=${NX_DOCKER_REPO:-docker-hosted}; NX_HELM_REPO=${NX_HELM_REPO:-helm-hosted}
NXA=${NXA:?Nexus user:pass}
HB=${HB:-http://172.16.141.11:30004}; HB_REG=${HB_REG:-172.16.141.11:30004}
HB_CHART_PROJECT=${HB_CHART_PROJECT:-charts}; DEFAULT_PROJECT=${DEFAULT_PROJECT:-dlops}
HBA=${HBA:?Harbor user:pass (로봇)}
TLS=${TLS:---src-tls-verify=false --dest-tls-verify=false}; HELM_HTTP=${HELM_HTTP:---plain-http}   # 운영(https) 은 둘 다 빈 값
WORK=${WORK:-/tmp/nx2hb}; mkdir -p $WORK/charts; OUT=${OUT:-$WORK/migrate.log}; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
map_repo(){ case "$1" in */*) echo "$1";; *) echo "$DEFAULT_PROJECT/$1";; esac; }
nx_components(){ python3 - "$NX" "$NXA" "$1" <<'EOF'
import sys,json,urllib.request,base64
b,a,repo=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}; tok=None
while True:
    u=f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else "")
    d=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=h)))
    for c in d['items']:
        asset=next((x for x in c['assets'] if x['path'].endswith('.tgz')), c['assets'][0] if c['assets'] else {})
        print("\t".join([c['name'],c['version'],asset.get('checksum',{}).get('sha256',''),asset.get('downloadUrl','')]))
    tok=d.get('continuationToken')
    if not tok: break
EOF
}
digest_of(){ skopeo inspect --raw $1 "$2" 2>/dev/null | shasum -a 256 | cut -c1-64; }
HB_USER=${HBA%%:*}; HB_PASS=${HBA#*:}

log "===== 1. docker: $NX_DOCKER_REPO → $HB_REG"
nx_components $NX_DOCKER_REPO > $WORK/docker.lst; log "원본 이미지 태그 수: $(wc -l < $WORK/docker.lst | tr -d ' ')"
ok=0; skip=0; fail=0; : > $WORK/docker-result.tsv
while IFS=$'\t' read -r name ver _ _; do
  src="docker://$NX_DOCKER/$name:$ver"; dst="docker://$HB_REG/$(map_repo $name):$ver"
  sd=$(digest_of "--tls-verify=false --creds $NXA" "$src"); td=$(digest_of "--tls-verify=false --creds $HBA" "$dst")
  if [ -n "$td" ] && [ "$sd" = "$td" ]; then skip=$((skip+1)); printf '%s:%s\tSKIP\t%s\n' "$name" "$ver" "${sd:0:12}" >> $WORK/docker-result.tsv; continue; fi
  if skopeo copy -q --all --preserve-digests $TLS --src-creds "$NXA" --dest-creds "$HBA" "$src" "$dst" 2>$WORK/err; then
    td=$(digest_of "--tls-verify=false --creds $HBA" "$dst"); if [ "$sd" = "$td" ]; then ok=$((ok+1)); r=OK; else fail=$((fail+1)); r=DIGEST_MISMATCH; fi
  else fail=$((fail+1)); r="FAIL $(tail -1 $WORK/err | cut -c1-100)"; fi
  printf '%s:%s\t%s\t%s→%s\n' "$name" "$ver" "$r" "${sd:0:12}" "${td:0:12}" >> $WORK/docker-result.tsv
done < $WORK/docker.lst
log "docker 결과: 복사 $ok / 건너뜀 $skip / 실패 $fail"; sed 's/^/  /' $WORK/docker-result.tsv | tee -a $OUT

log "===== 2. helm(OCI): $NX_HELM_REPO → oci://$HB_REG/$HB_CHART_PROJECT"
nx_components $NX_HELM_REPO > $WORK/helm.lst; log "원본 차트 버전 수: $(wc -l < $WORK/helm.lst | tr -d ' ')"
helm registry login $HB_REG $HELM_HTTP --username "$HB_USER" --password "$HB_PASS" >/dev/null 2>&1 && log "helm registry login OK" || log "helm registry login 실패"
ok=0; skip=0; fail=0; : > $WORK/helm-result.tsv
while IFS=$'\t' read -r name ver sha url; do
  # 존재 확인: Harbor API (프로젝트 charts 의 저장소 <name>, 태그 <ver>)
  have=$(curl -s -o /dev/null -w '%{http_code}' -u "$HBA" "$HB/api/v2.0/projects/$HB_CHART_PROJECT/repositories/$name/artifacts/$ver")
  if [ "$have" = 200 ]; then skip=$((skip+1)); printf '%s-%s\tSKIP\n' "$name" "$ver" >> $WORK/helm-result.tsv; continue; fi
  f=$WORK/charts/$name-$ver.tgz
  curl -sf -u "$NXA" -o "$f" "$url" || { fail=$((fail+1)); printf '%s-%s\tDOWNLOAD_FAIL\n' "$name" "$ver" >> $WORK/helm-result.tsv; continue; }
  got=$(shasum -a 256 "$f" | cut -c1-64); [ -n "$sha" ] && [ "$got" != "$sha" ] && { fail=$((fail+1)); printf '%s-%s\tSHA_MISMATCH_SRC\n' "$name" "$ver" >> $WORK/helm-result.tsv; continue; }
  if out=$(helm push "$f" "oci://$HB_REG/$HB_CHART_PROJECT" $HELM_HTTP 2>&1); then
    dg=$(echo "$out" | grep -o 'Digest: sha256:[0-9a-f]*' | cut -d: -f3 | cut -c1-12); ok=$((ok+1)); r="OK oci-digest=$dg"
  else fail=$((fail+1)); r="PUSH_FAIL $(echo "$out" | tail -1 | cut -c1-120)"; fi
  printf '%s-%s\t%s\ttgz=%s\n' "$name" "$ver" "$r" "${got:0:12}" >> $WORK/helm-result.tsv
done < $WORK/helm.lst
log "helm 결과: push $ok / 건너뜀 $skip / 실패 $fail"; sed 's/^/  /' $WORK/helm-result.tsv | tee -a $OUT
```

## C-3. CNPG 재시작 영향 측정 (`pg-restart-test.sh`)

```bash
#!/bin/bash
# CNPG(단일 인스턴스) 파드 재시작 시 Harbor 영향 측정: pull / 관리 API / push 를 1초 간격으로
# 인자: $1 = 라벨
set -uo pipefail
export KUBECONFIG=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad/kubeconfig
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
. $S/hc.robot; HA="admin:$(cat $S/hc.admin)"; RA="$ROBOT_NAME:$ROBOT_SECRET"; H=http://172.16.141.11:30004
OUT=~/nexus-lab/logs/harbor-cnpg/ops.txt; P=$S/pgr-$1; rm -rf $P; mkdir -p $P; touch $P/run
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
( n=0; while [ -e $P/run ]; do n=$((n+1)); t=$(date +%H:%M:%S)
    m=$(curl -s -m 4 -o /dev/null -w '%{http_code}' -u "$RA" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' $H/v2/dlops/app1/manifests/1.1)
    a=$(curl -s -m 4 -o /dev/null -w '%{http_code}' -u "$HA" "$H/api/v2.0/projects/dlops/repositories?page_size=5")
    w=$(timeout 8 skopeo copy -q --src-tls-verify=false --dest-tls-verify=false --src-creds "$RA" --dest-creds "$RA" docker://172.16.141.11:30004/dlops/app1:1.1 docker://172.16.141.11:30004/dlops/probe:$1-$n >/dev/null 2>&1 && echo ok || echo fail)
    echo "$t pull=$m api=$a push=$w" >> $P/probe.log; sleep 1; done ) &
sleep 6
log "===== [$1] CNPG 파드 삭제"; T0=$(date +%s); kubectl -n harbor-cnpg delete pod harbor-pg-1 --wait=false >/dev/null
gone=""; for i in $(seq 1 400); do sleep 1
  st=$(kubectl -n harbor-cnpg get pod harbor-pg-1 -o jsonpath='{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}' 2>/dev/null)
  case "$st" in "|true") [ -n "$gone" ] && break;; ""|"|false"|"|") [ -z "$gone" ] && gone=$(( $(date +%s)-T0 ));; esac
done
T1=$(( $(date +%s)-T0 ))
log "[$1] 옛 파드 종료까지 ${gone:-?}s, 새 파드 ready 까지 ${T1}s"
sleep 15; rm -f $P/run; sleep 9
log "[$1] 타임라인(같은 상태 묶음: 횟수 시작시각 상태)"; awk '{print $1, $2, $3, $4}' $P/probe.log | uniq -f1 -c | sed 's/^/  /' | tee -a $OUT
python3 - $P/probe.log <<'EOF' | tee -a ~/nexus-lab/logs/harbor-cnpg/ops.txt
import sys
rows=[dict([("t",l.split()[0])]+[x.split("=") for x in l.split()[1:]]) for l in open(sys.argv[1])]
for k,good in (("pull","200"),("api","200"),("push","ok")):
    bad=[r["t"] for r in rows if r[k]!=good]
    print(f"  {k:5s} 실패 {len(bad):3d}/{len(rows)}" + (f"  ({bad[0]} ~ {bad[-1]})" if bad else ""))
EOF
```

---

# 부록 D. 관련 시험 요약

## D-1. Harbor proxy-cache 상류 장애 (Harbor 2.13 → 2.7, 12분 단절)

캐시된 태그 pull 전부 실패(404), 태그 목록 빈 배열, 로컬에 완전 저장된 아치별 digest 만 성공, endpoint 상태는 healthy 로 남음. 재검증 끄기·오프라인 모드 옵션 없음. 코드상 로컬 폴백은 상류가 429 를 줄 때뿐. Nexus docker proxy 는 같은 조건에서 캐시된 태그·멀티아치·digest·태그목록을 전부 제공. → Harbor 간 가용성은 proxy-cache 가 아니라 replication(pull) 또는 digest 고정 배포로.

## D-2. Harbor 2.7 ChartMuseum 경로

nginx(njs) 로 Nexus helm PUT 경로를 ChartMuseum multipart POST 로 치환해 기존 엔드포인트 유지 가능. 업로드 한도 20MiB→100MiB(ConfigMap MAX_UPLOAD_SIZE), ALLOW_OVERWRITE false 면 409. 최신 Harbor 채택으로 미사용.
