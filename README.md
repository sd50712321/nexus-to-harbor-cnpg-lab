# Nexus → Harbor + CloudNativePG 이관 실측 랩

폐쇄망에서 운영 중인 Nexus Repository(3.82 CE)의 **커스텀 docker 이미지·helm 차트만** Harbor 로 옮기고, Harbor 의 DB 를 CloudNativePG(CNPG) 로 두는 구성을 랩 클러스터에서 **처음부터 끝까지 실제로 구축·이관·검증**한 기록입니다. Nexus 는 그대로 유지합니다.

모든 수치는 이 랩에서 실측한 값이고, 겪은 이슈와 주의점을 해당 단계에 함께 적었습니다. **단, 수치는 랩 규모의 값이며 운영 규모로 전이되지 않습니다** — 바로 아래 절에서 무엇이 전이되고 무엇이 안 되는지를 먼저 구분합니다.

## 먼저 읽을 것: 이 문서의 결과를 어디까지 믿을 수 있나

이 랩은 **맥북 한 대 위의 VM 2대**(arm64, 각 2 vCPU / 약 3GB, 호스트 전용 가상 NIC) 입니다. 실제 대상은 수백 노드 규모의 폐쇄망이므로, 아래 두 종류를 반드시 구분해서 읽어야 합니다.

### 규모와 무관하게 그대로 유효한 것 (코드 경로의 성질)

- Harbor 의 token realm 이 `externalURL` 을 따라가므로 **진입점(스킴·호스트·포트)은 하나**여야 한다
- Spegel 은 `mirroredRegistries` 에 없는 레지스트리의 hosts.toml 을 `_backup` 으로 치우고, hosts.toml 을 다시 쓸 때 `ca=` 를 지우며, 피어가 가진 `latest` 를 옛 digest 로 해석할 수 있고, 비공개 이미지를 피어가 **무인증으로 서빙**한다
- containerd 2.x 는 schema1 을 거부한다, OCI 태그에 `+` 가 안 되어 `_` 로 바뀐다, `.prov` 는 별도 레이어로 들어간다
- 이관 스크립트의 멱등성·재개·델타 동작, Nexus `writePolicy: DENY` 가 막는 것과 못 막는 것
- Harbor 는 DB 가 없으면 **pull 도 401** 이다, CNPG `smartShutdownTimeout` 은 Harbor 커넥션 풀 때문에 끝까지 기다린다
- Cilium `gatewayAPI.enabled` 를 켠 뒤에는 **cilium-operator 를 재시작**해야 GatewayClass 가 Accepted 된다
- Harbor 차트 기본 `maxOpenConns`(900) 와 외부 PG 기본 `max_connections` 를 **서로 맞추지 않으면 연결이 고갈**된다

### 이 랩에서 나온 숫자는 가져가면 안 되는 것

- 소요 시간·처리량 전부: 213 이미지 74초, 382MB 17~22초, Gateway 경유 오버헤드 비율, Spegel 피어 서빙 배수, CNPG 재시작 28초, 서비스 끊김 11초
- CNPG 는 `instances: 1` — **진짜 페일오버(switchover/failover)는 한 번도 보지 않았다**
- Harbor core·jobservice·registry 전부 replicas 1, 스토리지 local-path — **HA 구성·공유 스토리지(S3 호환/RWX)·그 상태의 GC 는 미검증**
- 노드 2대 — 수백 노드 동시 pull(롤아웃 폭주) 에서 Gateway(Envoy)·Harbor registry·Spegel DHT 가 어떻게 거동하는지 미검증
- 커넥션 풀 `maxOpenConns: 50` / `maxIdleConns: 10` 은 **랩용 값**이다(아래 사이징 참고). 권장값이 아니다
- 네트워크: 호스트 전용 가상 NIC 이므로 실제 폐쇄망의 대역폭·지연·방화벽 경유와 무관

### Harbor ↔ PostgreSQL 커넥션 사이징 (운영에서 계산해야 할 것)

랩의 50 은 PG `max_connections=200` 아래로 두려고 잡은 값일 뿐입니다. 운영은 소비자 합계에서 거꾸로 계산합니다.

```
필요 연결 수 ≈ core 파드 수 × core maxOpenConns
             + jobservice 파드 수 × jobservice 풀
             + exporter + 예약(superuser_reserved_connections, CNPG 내부 사용)
예) core 3×100 + jobservice 3×50 + exporter 10 + 예약 20 ≈ 480
    → PG max_connections 는 여유 포함 600~800, 연결당 수 MB 를 잡아 PG 인스턴스 메모리 산정
```

- 차트 기본 900 은 Harbor 내장 PG 가 `max_connections=1024` 로 뜨는 것을 전제한 값. 외부 PG 를 쓰면 **PG 를 Harbor 에 맞춰 올리거나, Harbor 를 PG 에 맞춰 내리거나** 둘 중 하나를 의식적으로 해야 한다
- 연결 수가 커지면 CNPG **Pooler(PgBouncer)** 를 두는 것이 정석. 단 Harbor 가 prepared statement 를 쓰므로 transaction 모드와 충돌할 수 있어 **session 모드로 시작해 실측**한다 — 이 랩에서는 하지 않았다
- 최종값은 운영 부하에서 `pg_stat_activity` 를 보고 정한다. 미리 확정할 수 없다

### 운영(또는 운영과 같은 급의 검증 클러스터)에서 다시 재야 할 것

1. Harbor HA: core·jobservice·registry 다중 replica + 공유 스토리지(S3 호환/RWX) + Redis HA — 구성 자체와 GC 동작
2. CNPG `instances: 3` + 노드 분산: switchover/failover 시간, 그 동안 Harbor 영향, Pooler 유무
3. 롤아웃 폭주: 노드 N대 동시 pull — Gateway(Envoy) 처리량, Harbor registry 처리량, Spegel 효과와 DHT 안정성
4. 이관 처리량: 실제 이미지 총량·크기 분포로 `PAR` 를 올려 가며 시간 측정(스크립트는 병렬도에 따라 늘어나지만 수치는 거기서 나온다)
5. 네트워크: 방화벽 경유 Gateway, 사설 CA 배포 경로(노드 수백 대 OS 신뢰 저장소 — 노드 이미지/Ansible 에 넣어야 한다)

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

## 심화 이관 시험 (3차, 213 이미지 + 12 차트)

| 시험 | 결과 |
|---|---|
| 전체 이관 | **74초** (docker 204 복사·7 건너뜀, 382MB 이미지 17초, 병렬 4) / helm 6 push |
| 재실행 | 전부 SKIP — 완전 멱등 (schema1 은 "대상 존재" 로 SKIP) |
| 중단 후 재개 | 50태그 삭제 → 9초 뒤 kill(34/50) → 재실행 16 복사 → **50/50** |
| Nexus 읽기전용(컷오버) | `writePolicy: DENY` → docker push 차단(`blob upload invalid`)·pull 200, helm index/tgz 200·업로드 500. 델타 이관 전부 SKIP |
| 전수 대조 | docker MATCH 212 / DIFFERENT 1(schema1), helm MATCH 12, Harbor 에만 있는 것 없음 |
| 엣지 | 중첩 경로·조각 없는 이름(기본 프로젝트)·없는 프로젝트(자동 생성)·OCI 차트 in docker 저장소·`+build` 버전(`_` 태그)·`.prov`·subchart umbrella 설치 — 전부 통과 |

## 노출 방식: Cilium Gateway API(TLS 종단) vs NodePort — 실측

| 항목 | Gateway (hostNetwork, https :8443) | NodePort (http :30004) |
|---|---|---|
| 구성 | Gateway API v1.6.3 CRD + Cilium `gatewayAPI.enabled/hostNetwork` + Gateway/HTTPRoute + TLS Secret | 차트 `expose.type: nodePort` |
| 주소 | 모든 노드 IP:8443 (`addresses=[172.16.141.11 172.16.141.14]`) | 노드 IP:30004 |
| 프로토콜 | **HTTP/2**, 사설 CA 필수 | HTTP/1.1 평문 |
| push 382MB | 21.8s | 17.3s |
| docker/helm/노드 pull/파드 | 전부 OK | 전부 OK |
| **제약** | externalURL 을 Gateway 로 바꾸면 **NodePort 경로의 push 가 깨짐**(token realm 이 `https://…:30004` 로 나감) → 진입점은 하나로 | — |

함정: Cilium 에 gatewayAPI 를 켠 뒤 **오퍼레이터를 재시작**해야 한다(템플릿이 안 바뀌어 옛 설정으로 돌며 Envoy CRD 를 등록하지 않음 → 에이전트가 `Still waiting for Cilium Operator to register CRDs` 로 멈춤). 사설 CA 는 **노드 OS 신뢰 저장소에 설치**한다 — Spegel 이 hosts.toml 을 다시 쓰면서 `ca=` 줄을 지우기 때문.

## 재기동 복구 (Mac 재시작 후) — 자가 복구 여부

| 구성 | 결과 |
|---|---|
| CNPG `harbor-pg`, Harbor 2.14 전 파드, Spegel | **개입 없이 정상 복귀** |
| VM 3대 | VMware `.lck` 잠금 잔재로 전원 실패 → 삭제 후 기동 |
| 워커 w1 | VIP 수동 설정이 사라져 재부여 필요(랩 한정) |
| 로봇 secret / admin 비번 | 스크래치 소실 → API 재발급 / k8s Secret 에서 복구 |

## Spegel (노드 P2P 캐시) 실측 — 2노드

| 시험 | 결과 |
|---|---|
| 피어 서빙 | w1 pull 시 Harbor 요청 **0건**, digest 일치 |
| Harbor 완전 정지 | 클러스터에 있는 이미지는 pull 됨(인증 무관), 없는 이미지는 실패 |
| `latest` 재사용 | 덮어써도 피어의 **옛 digest** → `registryFilters [":latest$"]` 로 해결 |
| 무인증 pull | 비공개 이미지도 피어가 **자격증명 없이** 서빙(FAQ 경고 그대로) → 테넌트 격리 요구 시 부적합 |
| 피어 다운 폴백 | 13.6~13.9초(피어 경유 14.7초와 동일) — 지연 없음 |
| 382MB 전송 | Harbor 직접 20.6초 vs 피어 14.7초 |

## 겪은 이슈 (전부 해결)

| 이슈 | 원인 | 해결 |
|---|---|---|
| 1차 이관 docker 전부 `trying to reuse blob`, 차트 401 | 로봇 이름 `robot$migrator` 의 `$` 가 셸 변수로 풀려 사용자명이 `robot` | 비밀값 파일을 작은따옴표로 저장 |
| `kubectl apply` CNPG 매니페스트 실패 `annotations: Too long` | CRD 크기 | `kubectl apply --server-side` |
| Harbor 차트 `maxOpenConns` 기본 900 | PG `max_connections` 200 초과 | 랩에서는 50 으로 조정(랩용 값, 운영 사이징은 서두 절 참고) |
| jobservice 초기 2회 재시작 | redis 준비 전 기동 | 정상, 조치 불필요 |
| 로봇으로 프로젝트 저장소 목록 API 403 | 로봇 권한 범위 | 개별 아티팩트 목록은 200; 전체 목록은 admin 으로 |
| 공식 goharbor 2.15 이미지 arm64 없음 | amd64 단일 아키 | arm64 랩은 2.14.0(octohelm) |
| 새 프로젝트로 push 실패 `trying to reuse blob … at destination` | admin 이 프로젝트는 만들었지만 로봇에 권한 없음 | 시스템 로봇 `namespace: "*"` (PUT /robots/{id} 는 GET JSON 에서 id·시각 필드 제거 후 permissions 교체) |
| schema1 이미지 digest 불일치·재실행마다 재push | 서명 재직렬화로 digest 가 매번 바뀜. containerd 2.x 는 pull 자체 거부 | `--format oci` 변환 후 1회만, 이후 "대상 존재" 로 SKIP. 운영에선 변환 or 폐기 |
| `.prov` 동반 차트가 재실행마다 재push | OCI manifest 의 layers[0] 이 prov 라서 내용 비교 어긋남 | 차트 레이어를 mediaType(`…chart.content.v1.tar+gzip`)으로 선택 |
| macOS 에서 결과 필터 미출력 | BSD grep 에 `-P` 없음 | `grep -E $'\t…'` |
| Spegel 설치 후 docker.io pull 실패(폐쇄망 미러 단절) | `mirroredRegistries` 에 없는 레지스트리 hosts.toml 을 `_backup` 으로 이동 | 노드의 모든 미러 레지스트리를 목록에 명시 |
| Spegel: `latest` 덮어써도 옛 이미지 | 피어가 태그를 처음 digest 로 해석 | `registryFilters: [":latest$"]` 또는 digest 고정 배포 |
| 워커 조인 실패(VIP 불통) | 랩 cp1 에 kube-vip 정적 파드 없음 | cp1 eth1 에 VIP 수동 부여 후 `kubeadm join --config` (랩 한정) |
| Cilium gatewayAPI 켠 뒤 에이전트 0/2, GatewayClass Unknown | 오퍼레이터 파드가 옛 설정으로 계속 실행 → Envoy CRD 미등록 | `rollout restart deploy/cilium-operator` |
| externalURL 을 Gateway 로 바꾸자 NodePort push 실패 | token realm 이 요청 호스트 + externalURL 스킴 → `https://…:30004` | 진입점 하나로 통일(또는 같은 스킴·호스트) |
| Spegel 추가 후 사설 CA 레지스트리 폴백 TLS 실패 | Spegel 이 hosts.toml 재작성 시 `ca=` 삭제 | CA 를 노드 OS 신뢰 저장소에 설치 + containerd 재시작 |
| VM 전원 실패 `Cannot open the disk … Directory not empty` | 비정상 종료 잔재 `*.vmdk.lck` | 잠금 디렉터리 삭제 |
| `vagrant up` 이 `machine is locked` 로 중단 | 병행 `vagrant ssh` 가 머신 락 점유 | 동시 vagrant 명령 금지, 노드별 단독 기동 |

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

---

## 운영 폐쇄망 인프라 사전 결정 사항 (랩 미검증 — 설계 단계에서 확정해야 할 것)

이 랩은 IP 직결(`172.16.141.11:8443`)·사설 CA 수동 배포·단일 노드 스토리지로 돌렸습니다. 운영 폐쇄망에서는 아래 항목이 **Harbor 설치보다 먼저** 정해져야 하고, 대부분은 나중에 바꾸기 어렵습니다.

### 1. 이름과 주소 — 가장 먼저, 가장 바꾸기 어려운 것

- **`externalURL` 은 영구적인 DNS 이름으로.** 이 값이 모든 이미지 참조(`harbor.<도메인>/project/img:tag`)·Helm values·CI 파이프라인·containerd hosts.toml·Spegel `mirroredRegistries` 에 박힌다. IP 를 쓰면 IP 변경 = 전부 재태깅. 토큰 realm 도 이 값을 따르므로 **이름·스킴·포트는 하나**(4차 실측 제약).
- **포트는 443.** `:8443` 처럼 포트가 붙으면 모든 참조에 포트가 따라붙는다. Gateway 가 hostNetwork 8443 에 뜨더라도 앞단 VIP/LB 에서 443 → 8443 으로 받거나, Gateway 리스너를 443 으로 둔다.
- **해석 주체가 둘이다.** 파드가 아니라 **노드의 containerd** 가 이미지를 당기므로 그 이름은 노드 OS resolver(`/etc/resolv.conf`, 사내 DNS)에서 풀려야 한다. CoreDNS 에만 넣으면 안 된다. CI 러너·개발 PC·다른 클러스터 노드에서도 같은 이름이 같은 VIP 로 풀려야 한다(split-horizon 이면 안팎 값이 일치하는지 확인).
- **VIP/L4 진입점.** Gateway hostNetwork 는 Envoy 가 뜬 노드 IP 마다 열린다. 앞에 VIP 가 필요: 하드웨어 LB, 또는 Cilium 자체 기능(LB IPAM + L2 Announcement 또는 BGP 컨트롤플레인), 또는 kube-vip. 폐쇄망이면 BGP 를 네트워크팀이 열어주는지가 선택을 가른다. Envoy 를 올릴 노드를 `gatewayAPI.hostNetwork.nodes.matchLabels` 로 고정하고 LB 헬스체크 대상으로 삼는다.
- **대역 계획.** 노드 대역·Pod CIDR·Service CIDR·LB IP 풀·VIP 가 사내 대역(CI 서버, 다른 클러스터, 스토리지, NAS)과 겹치지 않아야 한다. Harbor 는 클러스터 밖에서 들어오는 트래픽이 많아 겹치면 바로 드러난다.
- **MTU.** Cilium 터널(VXLAN/Geneve) 이면 50바이트 오버헤드. 사내 구간 MTU(1500 또는 점보)와 PMTUD 차단 방화벽 조합에서 **큰 blob push 가 중간에 멈추는** 전형적 증상이 난다. 네이티브 라우팅이 가능한지, 아니면 Cilium `MTU` 를 명시할지 결정.

### 2. PKI·시간

- 사설 CA 로 Harbor 인증서 발급. SAN 에 DNS 이름(필요 시 VIP IP 도). 체인(중간 CA) 포함 여부 확인.
- **신뢰 배포 경로 4곳**: (a) 노드 OS 신뢰 저장소 — Spegel 이 hosts.toml 의 `ca=` 를 지우므로 필수(4차 실측), 노드 이미지/Ansible 로 배포 (b) CI 러너·빌드 호스트 (c) 개발 PC (d) 다른 클러스터 노드. 어느 하나라도 빠지면 그쪽만 `x509` 로 실패한다.
- 인증서 갱신: Gateway TLS Secret 을 cert-manager(CA Issuer)로 자동 갱신하거나 만료 알람을 둔다. Cilium Envoy 는 Secret 교체를 자동 반영.
- **NTP.** 폐쇄망 내부 NTP 가 없으면 TLS 유효기간과 Harbor 토큰(JWT, 짧은 만료)에서 시계 오차로 **401 이 간헐적으로** 난다. 노드·Harbor·CI 호스트가 같은 NTP 를 보도록.
- 사내 프록시가 있는 환경이면 노드·Harbor 파드의 `HTTP_PROXY/NO_PROXY` 를 점검(Harbor 내부 호출이 프록시로 새면 실패).

### 3. 방화벽 규칙 (최소 목록)

| 방향 | 포트 | 용도 |
|---|---|---|
| 클라이언트(노드·CI·PC) → VIP | 443 | Harbor 전체(UI/API/registry/OCI 차트) |
| LB → Envoy 노드 | 8443(또는 443) | Gateway hostNetwork 리스너 |
| 노드 ↔ 노드 | Spegel router 5001(파드 네트워크), registry NodePort 30020(노드 로컬) | P2P 이미지 서빙 |
| 노드 → Nexus | 기존 Nexus 포트 | 공개 이미지 프록시는 Nexus 가 계속 담당 |
| 클러스터 내부 | PG 5432, Redis 6379 | Harbor ↔ CNPG ↔ Redis (Cilium NetworkPolicy 로 네임스페이스 한정) |
| Harbor → 외부 | 없음 | **Trivy DB 갱신이 인터넷을 요구** — 오프라인 DB 반입 절차를 두거나 스캐너를 끈다 |

Spegel 은 피어가 비공개 이미지를 **무인증으로** 준다(실측). 5001/30020 은 클러스터 노드끼리만 열리도록 Cilium 정책 또는 방화벽으로 한정한다.

### 4. 스토리지

- **registry 저장소**: HA 를 하려면 공유 스토리지. S3 호환(사내 오브젝트 스토리지/MinIO/Ceph RGW) 이 정석이고, NFS(Isilon) 로 가면 GC·대량 삭제·락 동작을 반드시 실측(Nexus H2 랩에서 NFS soft 마운트가 파일을 깨뜨린 것과 같은 계열의 위험). 용량 = 이관 총량 + 성장률 + GC 주기 동안의 미회수분.
- **CNPG PVC**: 블록 스토리지 CSI(fsync 지연이 짧은 것). local-path 는 랩용. CSI 드라이버 이미지도 반입 대상.
- **CNPG 백업**: WAL 아카이브 + base backup 의 목적지(S3 호환) 가 폐쇄망 안에 있어야 한다. 없으면 볼륨 스냅샷이나 `pg_dump` 크론으로 대체하되 PITR 은 포기하는 것임을 명시.
- Harbor 내장 Redis 는 단일 파드. HA 면 외부 Redis(Sentinel) 를 누가 운영하는지 결정.

### 5. 이미지 반입과 부트스트랩 순서 (닭과 달걀)

- Harbor·CNPG 오퍼레이터·PostgreSQL·Cilium·Spegel·Trivy 이미지는 **Harbor 에서 받을 수 없다**(아직 없으므로). 랩처럼 **Nexus(docker proxy/hosted)가 부트스트랩 레지스트리** 역할을 하고 containerd 미러가 `ghcr.io/quay.io/docker.io → Nexus` 로 잡혀 있어야 한다. 순서: Nexus 에 반입 → 노드가 Nexus 에서 Harbor 이미지 pull → Harbor 기동 → 커스텀 이미지 이관.
- 반입 목록은 **digest 로 고정**(태그 아님)해 문서에 남긴다. 반입 도구(`skopeo sync`, hauler, zarf 등)와 반입 절차(매체·승인)를 정한다.
- 버전 고정: Harbor 2.15.4 / chart 1.19.4, CNPG 1.30.1 / PG 16.15, Cilium 1.20.1, Spegel 0.8.1, Gateway API CRD v1.6.3 — 업그레이드도 같은 반입 경로를 탄다.

### 6. 계정·정책

- 인증: 사내 LDAP/AD 또는 OIDC. Harbor 로컬 계정은 관리자·로봇만.
- 노드 pull 자격: `imagePullSecrets` vs containerd 노드 레벨 인증(hosts.toml) 중 하나로 통일. 노드 레벨이면 Ansible 로 배포하고 로봇 토큰 회전 절차 필요.
- 프로젝트 구조·할당량·보존 정책·**태그 불변성**(릴리스 태그 immutable; `latest` 는 가변으로 두되 Spegel `registryFilters` 로 피어 해석 제외 — 3차 실측).
- 여러 클러스터가 한 Harbor 를 공유할지, 클러스터별 Harbor 간 replication 을 둘지.

### 7. 관측·DR

- 메트릭: Harbor exporter, CNPG(`pg_stat_activity` 로 커넥션 풀 포화 감시 — 위 사이징의 실측 근거), Gateway/Envoy. 알람: 인증서 만료, 디스크, GC 실패, DB 복제 지연.
- DR 런북: **DB 백업과 registry 저장소 백업을 한 쌍**으로 복구(실측: 둘 다 있어야 한다). 컷오버 뒤에도 Nexus 의 docker/helm 저장소는 읽기전용으로 N주 보존해 롤백 경로를 남긴다.

### 랩에서 추가로 검증 가능한 항목

IP 대신 DNS 이름 + cert-manager CA Issuer 인증서, Cilium L2 Announcement/kube-vip VIP 로 443 진입, 포트 443 리스너, NTP 오차 → 401 재현, Spegel 포트 Cilium NetworkPolicy 한정, Trivy 오프라인 DB, OpenLDAP 연동, MTU 를 줄인 상태에서 대용량 push. 이것들은 규모와 무관한 **동작 성질**이라 랩 결과가 그대로 유효하다. HA·페일오버·처리량은 위 "다시 재야 할 것" 대로 운영급 클러스터에서.


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
- **`maxOpenConns: 50`, `maxIdleConns: 10`** — 차트 기본 900 은 PG max_connections 를 넘어서 부하 시 연결 고갈. 50 은 랩용 값이며 운영은 파드 수 × 풀 합계로 다시 계산(서두 "커넥션 사이징")
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

### 3차: 이관 심화 시험 — 엣지케이스·규모·중단재개·컷오버·전수대조 (2026-11-04 09:21~09:32)
원본 nexus6 에 fixture 를 추가(`seed-edge.sh`)한 뒤 **`migrate-v3.sh`** 로 이관. v3 추가 기능: 프로젝트 자동 생성(admin), docker 병렬 복사(PAR=4), schema1 자동 변환·표시, helm 은 Nexus tgz sha256 ↔ Harbor 차트 레이어 digest 비교(같은 버전 다른 내용 감지), `+`→`_` 태그 규칙, `.prov` 동반 push, 결과 TSV·소요 시간. 검증은 **`verify-v3.sh`**(읽기 전용 전수 대조).

### 1. fixture (전부 Nexus 가 수용)
| 구분 | 항목 |
|---|---|
| docker | schema1(v2s1) `dlops/legacy:s1` · 중첩 경로 `dlops/team-a/svc:1.0` · 프로젝트 조각 없는 `rootapp:1.0` · Harbor 에 없는 프로젝트 `newteam/app:1.0` · 대용량 `dlops/big:3.12`(python:3.12 debian arm64, **382MB 7레이어**) · 규모 `dlops/scale01~20:v1~10`(200태그, push 17초) · docker-hosted 에 OCI 차트 `helm push oci://nexus/dlops/ocicharts`(수용됨) |
| helm | `edgever` 1.0.0-rc.1 / **1.0.0+build.5** / 2.0.0-SNAPSHOT · `umbrella`(dependencies 가 Nexus helm repo 를 가리킴, subchart h27b 포함) · `withprov`(.prov 동반) · `dupver`(helm-hosted2 writePolicy ALLOW, 같은 버전 내용 바꿔 재업로드 → Nexus 는 마지막 sha 만 보유) |
원본 총량: docker-hosted **213 태그**, helm-hosted 11 + helm-hosted2 1.

### 2. 이관 결과
| 실행 | docker(213) | helm(12) | 소요 |
|---|---|---|---|
| run1 | OK 204 · SKIP 7 · **FAIL 1**(newteam/app: 로봇에 newteam 권한 없음) · **DIGEST_MISMATCH 1**(legacy:s1) | OK 6 · SKIP 6 | **74초**(docker 67초, big 17.3초) |
| run2(로봇 `*` 권한 후) | OK 1(newteam) · CONVERTED_SCHEMA1 1 · SKIP 211 | OK 1(**withprov 재push** — prov 레이어가 layers[0] 이라 비교 오류) · SKIP 11 | 16초 |
| run3(보정 후) | SKIP 212 · SKIP(schema1, 대상 존재) 1 | SKIP 12 | 23초 — **완전 멱등** |
| 중단 후 재개 | Harbor 에서 scale01~05(50태그) 삭제 → 시작 9초 뒤 kill(34/50 복사됨) → 재실행 OK 16 · SKIP 197 → **50/50** | SKIP 12 | 24초 |
| 컷오버 델타 | SKIP 213 | SKIP 12 | 18초 |
전수 대조(`verify-v3.sh`): docker **MATCH 212 / DIFFERENT_DIGEST 1(legacy:s1)**, helm **MATCH 12**, Harbor 에만 있는 것 없음.

### 3. 엣지케이스별 결론
- **schema1**: Nexus 도 Harbor 도 저장은 받아 주지만 digest 가 매번 바뀌고(서명 재직렬화), **containerd 2.x 는 pull 자체를 거부**(`schema 1 image manifests are no longer supported`). 즉 노드에서 쓸 수 없는 이미지 → 이관 전에 `--format oci` 로 변환해 다시 태그하거나 폐기. v3 는 변환 표시 후 재실행 시 건너뜀.
- **중첩 경로 / 조각 없는 이름**: `dlops/team-a/svc` 는 그대로, `rootapp` 은 기본 프로젝트 `dlops/rootapp` 로 — 둘 다 digest 일치. 경로 규칙을 공지해야 함.
- **없는 프로젝트**: admin 으로 자동 생성은 되지만 **로봇에 그 프로젝트 권한이 없으면 push 실패**(`trying to reuse blob … at destination`). 시스템 로봇을 `namespace: "*"` 로 만들거나(PUT /robots/{id} 는 GET 한 JSON 에서 id·시각 필드를 뺀 뒤 permissions 만 바꿔 보내야 200) 프로젝트 생성 시 권한을 함께 부여.
- **대용량 382MB**: 17.3초(≈22MB/s, 랩 VM 네트워크). 운영은 PAR 조정으로 선형 확장.
- **OCI 차트가 docker 저장소에 있던 경우**: skopeo 가 그대로 복사, Harbor 가 CHART 로 인식.
- **helm `+build.5`**: OCI 태그 `1.0.0_build.5` 로 저장되고 `helm pull --version 1.0.0+build.5` 가 알아서 찾음(안내 문구 출력).
- **.prov**: `helm push` 가 같은 폴더의 `.tgz.prov` 를 함께 올림, `helm pull --prov` 로 회수. 단 manifest 의 레이어 순서가 prov 먼저일 수 있어 내용 비교는 mediaType `…chart.content.v1.tar+gzip` 레이어로.
- **의존성 차트**: Nexus repo 를 가리키던 `umbrella` 를 OCI 로 올리고 `helm install oci://…/umbrella` → subchart 포함 파드 2개 Running. (subchart 는 패키지 안에 들어 있으므로 Chart.yaml 의 repository 주소는 설치 시 쓰이지 않음. `helm dependency update` 를 다시 돌릴 개발자는 repository 를 `oci://<harbor>/charts` 로 바꿔야 함.)
- **같은 버전 다른 내용**: Nexus 가 마지막 내용만 보유 → Harbor 로 그것이 올라가고, 이후 내용이 또 바뀌면 v3 가 "기존 내용 → 교체" 로 덮어씀(Harbor 태그 불변 규칙이 없을 때).

### 4. 컷오버(Nexus 읽기 전용) 실측
`PUT /service/rest/v1/repositories/docker/hosted/<repo>` 로 `storage.writePolicy: DENY`(204). 결과: **docker push 차단**(`blob upload invalid`), **docker pull 200**(manifest·blob), **helm index.yaml 200·tgz 200**, helm 업로드 **500**(차단은 되지만 코드가 500). 정책 변경 직후 수 초간 index.yaml 이 400 을 낸 적 있음 → 변경 후 잠시 대기. 이 상태에서 델타 이관 → 전부 SKIP(변경 없음 확인).

### 5. 남은 주의
- Harbor 에서 **삭제는 전파되지 않음**(단방향). Nexus 에서 지운 태그는 verify 의 "Harbor 에만 있는 것" 으로 잡힌다.
- 태그 없는(digest 만의) manifest 는 Nexus components 목록에 없으므로 이관 대상이 아님.
- 로봇은 프로젝트 저장소 목록 API 403 → verify 의 "Harbor 에만 있는 것" 은 admin 계정으로 돌리는 편이 정확.

### 4차: 랩 재기동 복구 + Cilium Gateway API 로 Harbor 노출 (2026-11-04 22:37~23:20)

## A. 재기동 복구 (Mac 재시작 뒤)
증상: `kubectl` 연결 거부, `vagrant status` 3대 모두 not running, podman 컨테이너 0개, 세션 스크래치(kubeconfig·Harbor 로봇 secret·admin 비번 파일) 소실.
| 이슈 | 원인 | 조치 |
|---|---|---|
| registry VM 전원 켜기 실패 `Cannot open the disk … Directory not empty` | 비정상 종료로 남은 `disk-cl1.vmdk.lck` 잠금 디렉터리(3대 모두) | VMware 프로세스 없음을 확인한 뒤 `.lck` 디렉터리 삭제 → 정상 기동 |
| `vagrant up` 이 cp1 에서 `machine is locked` 로 중단, w1 미기동 | 복구 대기 스크립트가 동시에 `vagrant ssh/status` 를 돌려 머신 락 경합 | w1 을 단독으로 `vagrant up w1` |
| w1 조인 상태 유지 여부 | cp1 의 VIP(172.16.141.100) 수동 설정은 재부팅 시 사라짐 | 부팅 후 `ip addr add 172.16.141.100/24 dev eth1` 재부여 → w1 kubelet 이 VIP 로 다시 붙어 **Ready** |
| Harbor 로봇 secret 분실 | 스크래치 디렉터리 초기화 | `PATCH /api/v2.0/robots/{id}` 로 secret 재발급(이름 유지) |
| Harbor admin 비번 | 동일 | k8s Secret `harbor-admin` 에서 복구 |
| lab-ldap 컨테이너 기동 실패 | 바인드 마운트 원본(스크래치 경로)이 사라짐 | 미사용(zot-ldap 사용 중)이라 방치 |
| podman 머신·컨테이너 | 재시작 정책 없음 | 머신 start 후 nexus1/2/3/6, zot-ldap 수동 start |
**재부팅 후 개입 없이 정상 복귀한 것**: CNPG `harbor-pg`(healthy), Harbor 2.14 전 파드(Running, jobservice 재시작 8회 누적), Spegel. 즉 Harbor+CNPG 는 노드 재부팅에 자가 복구.

## B. Cilium Gateway API (hostNetwork, TLS 종단) 구성
환경: Cilium 1.20.1, `kubeProxyReplacement=true`(kube-proxy 없음), 노드 2대. Gateway API **v1.6.3** CRD(standard 7종) `kubectl apply --server-side`. Cilium `helm upgrade --reuse-values` 로 `gatewayAPI.enabled=true, hostNetwork.enabled=true, enableAlpn=true, enableAppProtocol=true`.
| 이슈 | 원인 | 조치 |
|---|---|---|
| upgrade 후 cilium 에이전트 0/2 Ready 로 5분 타임아웃, GatewayClass `Accepted=Unknown (Waiting for controller)` | 에이전트 로그 `Still waiting for Cilium Operator to register CRDs [ciliumenvoyconfigs, ciliumclusterwideenvoyconfigs]`. **오퍼레이터 Deployment 템플릿이 안 바뀌어 기존 파드가 옛 설정(`gateway-api-hostnetwork-enabled=false`)으로 계속 실행** → Envoy CRD 미등록 | `kubectl -n kube-system rollout restart deploy/cilium-operator` → 5초 내 에이전트 2/2, GatewayClass Accepted, Gateway Programmed |
구성: `Gateway harbor-gw`(gatewayClassName cilium, HTTPS 8443, TLS Terminate, Secret `harbor-tls` = 랩 CA 서명·SAN harbor.lab+노드IP) + `HTTPRoute harbor` → Service `harbor`(차트 nginx, NodePort 30004 와 공유) port 80. 결과: `addresses=[172.16.141.11 172.16.141.14]`(hostNetwork 라 모든 노드 IP), 두 노드 `cilium-envoy` 가 0.0.0.0:8443 LISTEN. Harbor `externalURL=https://172.16.141.11:8443` 로 변경(25초 롤아웃).

## C. Gateway 경유 실측
| 항목 | 결과 |
|---|---|
| `GET /v2/` (CA 검증) | 401, **HTTP/2**, `realm="https://172.16.141.11:8443/service/token"` |
| CA 없이 | TLS 실패(000) — 사설 CA 배포 필수 |
| docker inspect / push 소형 | 0.2s / 0.3s |
| **push 382MB(Nexus→Gateway)** | 21.8s (NodePort http 때 17.3s) — Envoy 경유 TLS 로 ~25% 추가 |
| pull 382MB | 14.5s |
| helm registry login(--ca-file) / push / pull | 전부 OK |
| 노드 containerd pull(로봇) | OK — hosts.toml `ca=` 로 신뢰 |
| 파드(w1) 가 Gateway 주소 이미지로 기동 | Running, imageID 일치 |
| digest | Gateway 경유 push 본 = 원본 (5ca6a002c5c3) |

## D. 발견한 제약 2가지 (중요)
1. **externalURL 은 하나 — 진입점을 섞을 수 없다.** externalURL 을 Gateway(https:8443)로 바꾸자 **NodePort(http:30004) 경로의 docker push 가 깨짐**: Harbor 가 내려주는 token realm 이 요청 호스트 + externalURL 스킴으로 조합돼 `https://…:30004/service/token` 이 되고, 30004 는 평문이라 TLS 핸드셰이크 실패. → API Gateway 로 갈 거면 NodePort 는 끄고, 둘 다 열어야 하면 같은 스킴·호스트(예: 둘 다 TLS, 같은 도메인)로 맞춘다.
2. **Spegel 이 hosts.toml 의 `ca=` 를 지운다.** Gateway 레지스트리를 Spegel `mirroredRegistries` 에 넣자 Spegel 이 그 hosts.toml 을 다시 써서 `[host] ca = …` 블록이 사라지고 `server` + Spegel 호스트만 남음 → 사설 CA 레지스트리로의 폴백이 TLS 오류. 목록에서 빼면 `_backup` 으로 치워지는 문제(§Spegel)가 다시 생김. **해결: 사설 CA 를 노드 OS 신뢰 저장소에 설치**(`/usr/local/share/ca-certificates/*.crt` → `update-ca-certificates` → containerd 재시작). 이후 hosts.toml 에 ca 줄이 없어도 폴백 pull 정상, 피어 서빙도 정상(cp1 pull 후 w1 무인증 pull OK).
(실험 순서 실수: 1차 재시험이 스크립트 9단계 정리로 저장소·네임스페이스가 지워진 뒤 돌아 NotFound 로 보였음 → 새 이미지 gwonly:1 로 다시 검증해 OK.)

## E. 랩 현재 상태
Harbor externalURL = `https://172.16.141.11:8443`(Gateway). NodePort 30004 서비스는 남아 있으나 docker push 는 realm 문제로 불가(조회·API 는 가능). 노드 OS 에 랩 CA 설치됨. Spegel `mirroredRegistries` 에 Gateway 레지스트리 추가·`registryFilters [":latest$"]` 유지. 산출물 `~/nexus-lab/gateway/`(cilium-gateway-values.yaml, harbor-gateway.yaml, harbor-externalurl-gateway.yaml, gateway-test.sh), 로그 `logs/gateway/test.txt`.


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
      max_connections: "200"        # 랩용. 운영은 core/jobservice/exporter 풀 합계 + 예약으로 역산(README 서두 사이징)
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
  maxOpenConns: 50                    # 랩용. 차트 기본 900 은 내장 PG(1024) 전제 → 외부 PG 한도에 맞춰 반드시 재계산

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

## B-3. Cilium Gateway API 활성 values (`cilium-gateway-values.yaml`)

```yaml
# Cilium 1.20.1 에 Gateway API 컨트롤러 추가 (기존 값 유지: helm upgrade --reuse-values -f 이 파일)
# 전제: kubeProxyReplacement=true, Gateway API v1.6.3 CRD 가 먼저 설치돼 있어야 함
gatewayAPI:
  enabled: true
  # 베어메탈·폐쇄망: LoadBalancer 구현(LB IPAM/L2) 없이 노드 IP 에 직접 리스너를 연다
  hostNetwork:
    enabled: true
  enableAlpn: true          # HTTP/2 협상(docker 클라이언트·helm 모두 h2 사용 가능)
  enableAppProtocol: true

```

## B-4. Gateway + HTTPRoute (`harbor-gateway.yaml`)

```yaml
# Harbor 를 Cilium Gateway(hostNetwork, 노드 IP:8443, TLS 종단) 로 노출
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: harbor-gw
  namespace: harbor-cnpg
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      protocol: HTTPS
      port: 8443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: harbor-tls          # tls.crt / tls.key (랩 CA 서명, SAN harbor.lab + 노드 IP)
      allowedRoutes:
        namespaces: { from: Same }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: harbor
  namespace: harbor-cnpg
spec:
  parentRefs:
    - name: harbor-gw
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: harbor                 # Harbor 차트의 nginx 서비스(expose.nodePort.name) — NodePort 30004 와 공유
          port: 80

```

## B-5. Harbor externalURL(Gateway) 덮어쓰기 (`harbor-externalurl-gateway.yaml`)

```yaml
# Harbor values 덮어쓰기: 사용자 접점이 Gateway(https://harbor.lab:8443) 가 되므로 externalURL 만 바꾼다.
# TLS 는 Gateway 에서 끝나므로 expose.tls 는 그대로 false. NodePort 30004 서비스는 유지(비교용).
externalURL: https://172.16.141.11:8443   # 랩: DNS 없이 IP SAN 인증서. 운영은 https://harbor.<도메인>

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

## C-2. 이관 v3 (`migrate-v3.sh`)

```bash
#!/bin/bash
# Nexus → Harbor(2.8+, OCI 차트) 이관 v3
#  - 프로젝트 자동 생성(admin 계정), docker 병렬 복사(PAR), digest 대조, schema1 자동 변환(옵션)
#  - helm: Nexus tgz sha256 ↔ Harbor 차트 layer digest 비교(같은 버전 다른 내용 감지), '+' → '_' 태그 규칙, .prov 동반
#  - 재실행 안전, 결과 TSV + 소요 시간
set -uo pipefail
NX=${NX:-http://127.0.0.1:8096}; NX_DOCKER=${NX_DOCKER:-127.0.0.1:35600}
NX_DOCKER_REPO=${NX_DOCKER_REPO:-docker-hosted}; NX_HELM_REPOS=${NX_HELM_REPOS:-helm-hosted}   # 공백 구분 여러 개 가능
NXA=${NXA:?Nexus user:pass}
HB=${HB:-http://172.16.141.11:30004}; HB_REG=${HB_REG:-172.16.141.11:30004}
HB_CHART_PROJECT=${HB_CHART_PROJECT:-charts}; DEFAULT_PROJECT=${DEFAULT_PROJECT:-dlops}
HBA=${HBA:?Harbor 이관용 계정(로봇) user:pass}; HB_ADMIN=${HB_ADMIN:-}     # 프로젝트 자동 생성에만 admin 사용(없으면 생성 생략)
PAR=${PAR:-4}; CONVERT_SCHEMA1=${CONVERT_SCHEMA1:-1}
TLS=${TLS:---src-tls-verify=false --dest-tls-verify=false}; HELM_HTTP=${HELM_HTTP:---plain-http}
WORK=${WORK:-/tmp/nx2hb3}; mkdir -p $WORK/charts; OUT=${OUT:-$WORK/migrate.log}; : > $OUT
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
map_repo(){ case "$1" in */*) echo "$1";; *) echo "$DEFAULT_PROJECT/$1";; esac; }
export NX NXA HB HB_REG HBA TLS WORK CONVERT_SCHEMA1 DEFAULT_PROJECT
nx_components(){ python3 - "$NX" "$NXA" "$1" <<'EOF'
import sys,json,urllib.request,base64
b,a,repo=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}; tok=None
while True:
    u=f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else "")
    d=json.load(urllib.request.urlopen(urllib.request.Request(u,headers=h)))
    for c in d['items']:
        tgz=next((x for x in c['assets'] if x['path'].endswith('.tgz')),None)
        prov=next((x for x in c['assets'] if x['path'].endswith('.prov')),None)
        print("\t".join([c['name'],c['version'],(tgz or {}).get('checksum',{}).get('sha256',''),(tgz or {}).get('downloadUrl',''),(prov or {}).get('downloadUrl','')]))
    tok=d.get('continuationToken')
    if not tok: break
EOF
}

# ---------- 0. 프로젝트 준비 ----------
T_ALL=$(date +%s)
log "===== 0. 목록 수집"
nx_components $NX_DOCKER_REPO > $WORK/docker.lst; : > $WORK/helm.lst; for r in $NX_HELM_REPOS; do nx_components $r | sed "s/^/$r\t/" >> $WORK/helm.lst; done
log "docker 태그 $(wc -l < $WORK/docker.lst | tr -d ' ')개 / helm 버전 $(wc -l < $WORK/helm.lst | tr -d ' ')개"
projects=$( { cut -f1 $WORK/docker.lst | while read -r n; do map_repo "$n" | cut -d/ -f1; done; echo $HB_CHART_PROJECT; } | sort -u)
log "필요 프로젝트: $(echo $projects | tr '\n' ' ')"
if [ -n "$HB_ADMIN" ]; then for p in $projects; do c=$(curl -s -o /dev/null -w '%{http_code}' -u "$HB_ADMIN" -X POST "$HB/api/v2.0/projects" -H 'Content-Type: application/json' -d "{\"project_name\":\"$p\",\"public\":false}"); log "  프로젝트 $p → $c (201 생성 / 409 있음)"; done
else log "  HB_ADMIN 없음 → 프로젝트 생성 생략(없는 프로젝트로의 push 는 실패로 기록됨)"; fi

# ---------- 1. docker (병렬) ----------
log "===== 1. docker → $HB_REG (병렬 $PAR)"
cat > $WORK/one.sh <<'EOS'
#!/bin/bash
# 인자: name version → 한 줄 TSV 출력
name=$1; ver=$2
case "$name" in */*) repo=$name;; *) repo=$DEFAULT_PROJECT/$name;; esac
src="docker://$NX_DOCKER/$name:$ver"; dst="docker://$HB_REG/$repo:$ver"
dg(){ skopeo inspect --raw $1 "$2" 2>/dev/null | shasum -a 256 | cut -c1-64; }
raw(){ skopeo inspect --raw --tls-verify=false --creds "$NXA" "$src" 2>/dev/null; }
sd=$(dg "--tls-verify=false --creds $NXA" "$src"); td=$(dg "--tls-verify=false --creds $HBA" "$dst")
t0=$(date +%s.%N)
if [ -n "$td" ] && [ "$sd" = "$td" ]; then printf '%s:%s\tSKIP\t%s\t%s\n' "$name" "$ver" "${sd:0:12}" 0; exit 0; fi
if [ -n "$td" ] && [ "$td" != e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then sv0=$(raw | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("schemaVersion"))' 2>/dev/null); [ "$sv0" = 1 ] && { printf '%s:%s\tSKIP(schema1, 대상 존재)\t%s\t%s\n' "$name" "$ver" "${sd:0:12}" 0; exit 0; }; fi
err=$(skopeo copy -q --all --preserve-digests $TLS --src-creds "$NXA" --dest-creds "$HBA" "$src" "$dst" 2>&1); rc=$?
if [ $rc = 0 ]; then td=$(dg "--tls-verify=false --creds $HBA" "$dst")
  if [ "$sd" = "$td" ]; then r=OK
  else sv=$(raw | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("schemaVersion"))' 2>/dev/null); [ "$sv" = 1 ] && r="CONVERTED_SCHEMA1(digest 변경, 정상)" || r=DIGEST_MISMATCH; fi
else
  sv=$(raw | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("schemaVersion"))' 2>/dev/null)
  if [ "$sv" = 1 ] && [ "$CONVERT_SCHEMA1" = 1 ]; then
    err2=$(skopeo copy -q --format oci $TLS --src-creds "$NXA" --dest-creds "$HBA" "$src" "$dst" 2>&1) && r="CONVERTED_SCHEMA1(digest 변경)" || r="FAIL_SCHEMA1 $(echo "$err2" | tail -1 | cut -c1-90)"
  else r="FAIL $(echo "$err" | tail -1 | sed -E 's/.*msg="//' | cut -c1-110)"; fi
fi
printf '%s:%s\t%s\t%s→%s\t%.1f\n' "$name" "$ver" "$r" "${sd:0:12}" "${td:0:12}" "$(echo "$(date +%s.%N) - $t0" | bc)"
EOS
chmod +x $WORK/one.sh; export NX_DOCKER
T0=$(date +%s); awk -F'\t' '{print $1, $2}' $WORK/docker.lst | xargs -P $PAR -n 2 $WORK/one.sh > $WORK/docker-result.tsv 2>$WORK/docker.err; T1=$(( $(date +%s)-T0 ))
log "docker 결과($T1 s): $(cut -f2 $WORK/docker-result.tsv | awk '{print $1}' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')"
grep -vE $'\t(SKIP|OK)\t' $WORK/docker-result.tsv | sed 's/^/  /' | tee -a $OUT
log "  (대용량·주요 항목 소요) $(grep -E '^dlops/(big|pybase|multi)' $WORK/docker-result.tsv | awk -F'\t' '{printf "%s %s %ss; ", $1, $2, $4}')"

# ---------- 2. helm (OCI) ----------
log "===== 2. helm → oci://$HB_REG/$HB_CHART_PROJECT"
HB_USER=${HBA%%:*}; HB_PASS=${HBA#*:}; helm registry login $HB_REG $HELM_HTTP --username "$HB_USER" --password "$HB_PASS" >/dev/null 2>&1 || log "helm registry login 실패"
: > $WORK/helm-result.tsv; T0=$(date +%s)
while IFS=$'\t' read -r repo name ver sha url prov; do
  tag=${ver//+/_}      # OCI 태그에 '+' 불가 → helm 규칙과 동일하게 '_'
  have=$(curl -s -u "$HBA" -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$HB/v2/$HB_CHART_PROJECT/$name/manifests/$tag" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(next(l["digest"][7:] for l in d["layers"] if l["mediaType"]=="application/vnd.cncf.helm.chart.content.v1.tar+gzip"))
except Exception: print("")' 2>/dev/null)
  if [ -n "$have" ] && [ "$have" = "$sha" ]; then printf '%s\t%s-%s\tSKIP(동일 내용)\t%s\n' "$repo" "$name" "$ver" "${sha:0:12}" >> $WORK/helm-result.tsv; continue; fi
  f=$WORK/charts/$name-$ver.tgz; curl -sf -u "$NXA" -o "$f" "$url" || { printf '%s\t%s-%s\tDOWNLOAD_FAIL\n' "$repo" "$name" "$ver" >> $WORK/helm-result.tsv; continue; }
  got=$(shasum -a 256 "$f" | cut -c1-64); [ -n "$sha" ] && [ "$got" != "$sha" ] && { printf '%s\t%s-%s\tSHA_MISMATCH_SRC\n' "$repo" "$name" "$ver" >> $WORK/helm-result.tsv; continue; }
  [ -n "$prov" ] && curl -sf -u "$NXA" -o "$f.prov" "$prov" || rm -f "$f.prov"
  note=""; [ -n "$have" ] && note=" (기존 내용 ${have:0:12} → 교체)"
  if out=$(helm push "$f" "oci://$HB_REG/$HB_CHART_PROJECT" $HELM_HTTP 2>&1); then
    r="OK$note"; [ -f "$f.prov" ] && r="$r +prov"
    [ "$tag" != "$ver" ] && r="$r tag=$tag"
  else r="PUSH_FAIL $(echo "$out" | tail -1 | cut -c1-120)"; fi
  printf '%s\t%s-%s\t%s\t%s\n' "$repo" "$name" "$ver" "$r" "${got:0:12}" >> $WORK/helm-result.tsv
done < $WORK/helm.lst
log "helm 결과($(( $(date +%s)-T0 )) s): $(cut -f3 $WORK/helm-result.tsv | awk '{print $1}' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')"
grep -vE $'\tSKIP' $WORK/helm-result.tsv | sed 's/^/  /' | tee -a $OUT
log "전체 소요 $(( $(date +%s)-T_ALL )) s"

```

## C-3. 전수 대조 (`verify-v3.sh`)

```bash
#!/bin/bash
# 이관 전수 대조 리포트: Nexus(docker/helm) ↔ Harbor. 변경 없음(읽기 전용). 컷오버 전·후 사인오프용.
set -uo pipefail
NX=${NX:-http://127.0.0.1:8096}; NX_DOCKER=${NX_DOCKER:-127.0.0.1:35600}; NX_DOCKER_REPO=${NX_DOCKER_REPO:-docker-hosted}; NX_HELM_REPOS=${NX_HELM_REPOS:-helm-hosted}
NXA=${NXA:?}; HB=${HB:-http://172.16.141.11:30004}; HB_REG=${HB_REG:-172.16.141.11:30004}; HBA=${HBA:?}; HB_CHART_PROJECT=${HB_CHART_PROJECT:-charts}; DEFAULT_PROJECT=${DEFAULT_PROJECT:-dlops}
PAR=${PAR:-6}; WORK=${WORK:-/tmp/nx2hb-verify}; mkdir -p $WORK
nx_components(){ python3 - "$NX" "$NXA" "$1" <<'EOF'
import sys,json,urllib.request,base64
b,a,repo=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}; tok=None
while True:
    d=json.load(urllib.request.urlopen(urllib.request.Request(f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else ""),headers=h)))
    for c in d['items']:
        tgz=next((x for x in c['assets'] if x['path'].endswith('.tgz')),None)
        print("\t".join([c['name'],c['version'],(tgz or {}).get('checksum',{}).get('sha256','')]))
    tok=d.get('continuationToken')
    if not tok: break
EOF
}
export NX_DOCKER HB_REG NXA HBA DEFAULT_PROJECT
cat > $WORK/cmp.sh <<'EOS'
#!/bin/bash
name=$1; ver=$2; case "$name" in */*) repo=$name;; *) repo=$DEFAULT_PROJECT/$name;; esac
s=$(skopeo inspect --raw --tls-verify=false --creds "$NXA" docker://$NX_DOCKER/$name:$ver 2>/dev/null | shasum -a 256 | cut -c1-64)
t=$(skopeo inspect --raw --tls-verify=false --creds "$HBA" docker://$HB_REG/$repo:$ver 2>/dev/null | shasum -a 256 | cut -c1-64)
if [ -z "$t" ] || [ "$t" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then r=MISSING_IN_HARBOR; elif [ "$s" = "$t" ]; then r=MATCH; else r=DIFFERENT_DIGEST; fi
printf '%s:%s\t%s\t%s\t%s\n' "$name" "$ver" "$r" "${s:0:12}" "${t:0:12}"
EOS
chmod +x $WORK/cmp.sh
echo "== docker"; nx_components $NX_DOCKER_REPO > $WORK/d.lst; awk -F'\t' '{print $1, $2}' $WORK/d.lst | xargs -P $PAR -n 2 $WORK/cmp.sh > $WORK/d.tsv
cut -f2 $WORK/d.tsv | sort | uniq -c | awk '{printf "  %s=%s\n", $2, $1}'; grep -v MATCH $WORK/d.tsv | sed 's/^/  /'
echo "== helm"; : > $WORK/h.tsv
for r in $NX_HELM_REPOS; do nx_components $r | while IFS=$'\t' read -r name ver sha; do tag=${ver//+/_}
  have=$(curl -s -u "$HBA" -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$HB/v2/$HB_CHART_PROJECT/$name/manifests/$tag" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(next(l["digest"][7:] for l in d["layers"] if l["mediaType"]=="application/vnd.cncf.helm.chart.content.v1.tar+gzip"))
except Exception: print("")' 2>/dev/null)
  if [ -z "$have" ]; then res=MISSING_IN_HARBOR; elif [ "$have" = "$sha" ]; then res=MATCH; else res=DIFFERENT_CONTENT; fi
  printf '%s\t%s-%s\t%s\t%s\t%s\n' "$r" "$name" "$ver" "$res" "${sha:0:12}" "${have:0:12}" >> $WORK/h.tsv; done; done
cut -f3 $WORK/h.tsv | sort | uniq -c | awk '{printf "  %s=%s\n", $2, $1}'; grep -v MATCH $WORK/h.tsv | sed 's/^/  /'
echo "== Harbor 에만 있는 것(이관 범위 밖 / 삭제분)"; python3 - "$HB" "$HBA" "$WORK" <<'EOF'
import sys,json,urllib.request,base64
hb,a,w=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}
def get(u):
    try: return json.load(urllib.request.urlopen(urllib.request.Request(u,headers=h)))
    except Exception as e: return []
src=set(l.split('\t')[0] for l in open(f'{w}/d.tsv'))
extra=[]
for p in ('dlops','newteam'):
    for r in get(f"{hb}/api/v2.0/projects/{p}/repositories?page_size=100"):
        name=r['name']
        for art in get(f"{hb}/api/v2.0/projects/{p}/repositories/{name.split('/',1)[1].replace('/','%252F')}/artifacts?page_size=100"):
            for t in art.get('tags') or []:
                key=f"{name}:{t['name']}" if '/' in name.split('/',1)[1] or p!='dlops' else f"{name}:{t['name']}"
                if f"{name}:{t['name']}" not in src and f"{name.split('/',1)[1]}:{t['name']}" not in src: extra.append(f"{name}:{t['name']}")
print('  '+(', '.join(sorted(extra)) if extra else '없음'))
EOF

```

## C-4. 엣지케이스 fixture (`seed-edge.sh`)

```bash
#!/bin/bash
# 이관 엣지케이스 fixture 를 원본 nexus6 에 심는다 (docker-hosted 127.0.0.1:35600, helm-hosted / helm-hosted2 8096)
set -uo pipefail
cd ~/nexus-lab; B=http://127.0.0.1:8096; A="admin:$(cat data/nexus6/admin.password)"; D=127.0.0.1:35600
OUT=logs/harbor-cnpg/seed-edge.txt; : > $OUT; log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
cp_img(){ local dst=$1; shift; if out=$(skopeo copy -q --src-tls-verify=false --dest-tls-verify=false --dest-creds "$A" "$@" "docker://$D/$dst" 2>&1); then log "  OK   $dst"; else log "  FAIL $dst: $(echo "$out" | tail -1 | cut -c1-150)"; fi; }

log "===== docker 엣지"
log "[D1] schema1(v2s1) 이미지 — Nexus 가 받는가"; cp_img dlops/legacy:s1 --format v2s1 dir:scratch/zalp
log "[D2] 중첩 경로 / 프로젝트 조각 없는 이름 / Harbor 에 없는 프로젝트"; cp_img dlops/team-a/svc:1.0 --format oci dir:scratch/zalp; cp_img rootapp:1.0 --format oci dir:scratch/zalp; cp_img newteam/app:1.0 --format oci dir:scratch/zalp
log "[D3] 대용량(python:3.12 debian, arm64)"; s=$(date +%s); cp_img dlops/big:3.12 --override-os linux --override-arch arm64 docker://docker.io/library/python:3.12; log "  소요 $(( $(date +%s)-s ))s, 크기: $(skopeo inspect --tls-verify=false --creds "$A" docker://$D/dlops/big:3.12 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(round(sum(l.get("Size",0) for l in d.get("LayersData",[]))/1048576),"MB,",len(d["Layers"]),"layers")')"
log "[D4] 규모: 저장소 20개 × 태그 10개 = 200 태그(작은 이미지)"; s=$(date +%s); n=0; for r in $(seq -w 1 20); do for t in $(seq 1 10); do skopeo copy -q --dest-tls-verify=false --dest-creds "$A" --format oci dir:scratch/zalp docker://$D/dlops/scale$r:v$t >/dev/null 2>&1 && n=$((n+1)); done; done; log "  push 성공 $n/200, 소요 $(( $(date +%s)-s ))s"
log "[D5] docker-hosted 에 OCI 차트(helm push oci://nexus) — 받아주는가"; export HELM_REGISTRY_CONFIG=/tmp/helm-nx.json; helm registry login $D --plain-http --username admin --password "$(cat data/nexus6/admin.password)" >/dev/null 2>&1; helm package logs/harbor27/charts/h27a -d /tmp >/dev/null; r=$(helm push /tmp/h27a-0.1.0.tgz oci://$D/dlops/ocicharts --plain-http 2>&1 | tail -1 | cut -c1-120); log "  $r"

log "===== helm 엣지"
T=$(mktemp -d)
mk(){ # mk <이름> <버전> → $T/<이름>-<버전>.tgz
  rm -rf $T/src; cp -r logs/harbor27/charts/h27a $T/src; sed -i '' -E "s/^name:.*/name: $1/; s/^version:.*/version: $2/" $T/src/Chart.yaml; helm package $T/src -d $T >/dev/null 2>&1; ls $T/$1-$2.tgz; }
up(){ # up <repo> <file>  → Nexus helm hosted 에 업로드
  curl -s -o /dev/null -w '%{http_code}' -u "$A" --upload-file "$2" "$B/repository/$1/$(basename $2)"; }
log "[H1] 프리릴리스/빌드메타 버전"; for v in 1.0.0-rc.1 1.0.0+build.5 2.0.0-SNAPSHOT; do f=$(mk edgever $v); log "  edgever-$v → Nexus $(up helm-hosted $f) (파일명 $(basename $f))"; done
log "[H2] 의존성(subchart) 차트 — Chart.yaml dependencies 가 Nexus helm repo 를 가리킴"; rm -rf $T/umb; cp -r logs/harbor27/charts/h27a $T/umb; sed -i '' -E 's/^name:.*/name: umbrella/; s/^version:.*/version: 0.1.0/' $T/umb/Chart.yaml; printf 'dependencies:\n  - name: h27b\n    version: 0.1.0\n    repository: http://127.0.0.1:8096/repository/helm-hosted/\n' >> $T/umb/Chart.yaml; export HELM_REPOSITORY_CONFIG=/tmp/helm-nx-repos.yaml HELM_REPOSITORY_CACHE=/tmp/helm-nx-cache; helm repo add nxhelm http://127.0.0.1:8096/repository/helm-hosted/ --username admin --password "$(cat data/nexus6/admin.password)" >/dev/null 2>&1; (cd $T/umb && helm dependency update >/dev/null 2>&1 && ls charts/); helm package $T/umb -d $T >/dev/null 2>&1; log "  umbrella-0.1.0 (charts/h27b 포함 $(tar tzf $T/umbrella-0.1.0.tgz | grep -c 'charts/h27b')개 항목) → Nexus $(up helm-hosted $T/umbrella-0.1.0.tgz)"
log "[H3] .prov 동반 차트"; f=$(mk withprov 0.1.0); printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nname: withprov\nversion: 0.1.0\nfiles:\n  withprov-0.1.0.tgz: sha256:%s\n-----BEGIN PGP SIGNATURE-----\nlab-fake\n-----END PGP SIGNATURE-----\n' "$(shasum -a 256 $f | cut -c1-64)" > $f.prov; log "  withprov-0.1.0.tgz → $(up helm-hosted $f) / .prov → $(up helm-hosted $f.prov)"
log "[H4] 같은 버전 다른 내용 재업로드 (helm-hosted2, writePolicy ALLOW)"; curl -s -o /dev/null -w '  helm-hosted2 생성 %{http_code}\n' -u "$A" -X POST $B/service/rest/v1/repositories/helm/hosted -H 'Content-Type: application/json' -d '{"name":"helm-hosted2","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}' | tee -a $OUT
f=$(mk dupver 0.1.0); s1=$(shasum -a 256 $f | cut -c1-12); c1=$(up helm-hosted2 $f); rm -rf $T/src; cp -r logs/harbor27/charts/h27a $T/src; sed -i '' -E 's/^name:.*/name: dupver/; s/^version:.*/version: 0.1.0/; s/^description:.*/description: CHANGED CONTENT/' $T/src/Chart.yaml; helm package $T/src -d $T >/dev/null 2>&1; s2=$(shasum -a 256 $f | cut -c1-12); c2=$(up helm-hosted2 $f); log "  1차 $s1 → $c1 / 2차(내용 변경) $s2 → $c2 / Nexus 가 보고하는 sha: $(curl -s -u "$A" "$B/service/rest/v1/components?repository=helm-hosted2" | python3 -c 'import sys,json;print([a["checksum"]["sha256"][:12] for c in json.load(sys.stdin)["items"] for a in c["assets"] if a["path"].endswith(".tgz")])')"
rm -rf $T
log "===== 원본 현황"; for r in docker-hosted helm-hosted helm-hosted2; do log "  $r: $(python3 - "$A" "$B" "$r" <<'EOF'
import sys,json,urllib.request,base64
a,b,repo=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}; tok=None; n=0
while True:
    d=json.load(urllib.request.urlopen(urllib.request.Request(f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else ""),headers=h)))
    n+=len(d['items']); tok=d.get('continuationToken')
    if not tok: break
print(n,'컴포넌트')
EOF
)"; done

```

## C-5. CNPG 재시작 영향 측정 (`pg-restart-test.sh`)

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

## C-6. Gateway API 구성·시험 (`gateway-test.sh`)

```bash
#!/bin/bash
# Cilium Gateway API(hostNetwork, TLS 종단) 로 Harbor 노출 — 구성 + docker/helm 실측, NodePort 경로와 비교
set -uo pipefail
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
export KUBECONFIG=$S/kubeconfig; HA="admin:$(cat $S/hc.admin)"; G=172.16.141.11:8443; NP=172.16.141.11:30004
OUT=~/nexus-lab/logs/gateway/test.txt; mkdir -p ~/nexus-lab/logs/gateway; : > $OUT; cd ~/nexus-lab/gateway
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
vs(){ (cd ~/Desktop/k8s-core && timeout 180 vagrant ssh $1 -c "$2" 2>/dev/null | grep -v 'Warning: Permanently' | tr -d '\r'); }

log "===== 1. 전제: Cilium 설정"
log "kubeProxyReplacement=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}') / kube-proxy 파드: $(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | awk '{print $2}' || echo 없음) / cilium 버전 $(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')"
log "===== 2. Gateway API v1.6.3 CRD (server-side apply)"; kubectl apply --server-side -f $S/gw/crd/ 2>&1 | awk '{print "  "$1, $2}' | tee -a $OUT
log "===== 3. Cilium 에 gatewayAPI 활성(hostNetwork) — helm upgrade --reuse-values"
helm upgrade cilium ./cilium-1.20.1.tgz -n kube-system --reuse-values -f cilium-gateway-values.yaml 2>&1 | grep -E 'STATUS|Error|WARN' | tee -a $OUT
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=240s 2>&1 | tail -1 | tee -a $OUT; kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | tail -1 | tee -a $OUT
sleep 10; log "GatewayClass: $(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
log "===== 4. TLS Secret + Gateway + HTTPRoute"
kubectl -n harbor-cnpg create secret tls harbor-tls --cert=$S/gw/tls/harbor.crt --key=$S/gw/tls/harbor.key --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f harbor-gateway.yaml | sed 's/^/  /' | tee -a $OUT
for i in $(seq 1 36); do sleep 5; p=$(kubectl -n harbor-cnpg get gateway harbor-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null); [ "$p" = True ] && break; done
log "Gateway Programmed=$p ($((i*5))s) addresses=$(kubectl -n harbor-cnpg get gateway harbor-gw -o jsonpath='{.status.addresses[*].value}') listeners=$(kubectl -n harbor-cnpg get gateway harbor-gw -o jsonpath='{.status.listeners[*].conditions[?(@.type=="Programmed")].status}')"
log "HTTPRoute Accepted=$(kubectl -n harbor-cnpg get httproute harbor -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}') ResolvedRefs=$(kubectl -n harbor-cnpg get httproute harbor -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"
log "노드 8443 리스닝: cp1=$(vs cp1 'sudo ss -tlnp | grep -c ":8443 "') w1=$(vs w1 'sudo ss -tlnp | grep -c ":8443 "')"
log "===== 5. Harbor externalURL → https://$G"
helm upgrade harbor214 ../harbor-cnpg/harbor-1.18.0.tgz -n harbor-cnpg -f ../harbor-cnpg/values-harbor214-cnpg.yaml -f harbor-externalurl-gateway.yaml --timeout 5m 2>&1 | grep -E 'STATUS|Error' | tee -a $OUT
for i in $(seq 1 60); do sleep 5; nr=$(kubectl -n harbor-cnpg get pods --no-headers | awk '{split($2,a,"/"); if (a[1]!=a[2]) n++} END{print n+0}'); [ "$nr" = 0 ] && break; done; log "Harbor 파드 준비 $((i*5))s"
log "===== 6. Gateway 경유 기본 동작(사설 CA 검증)"
log "GET /v2/ (CA 검증): $(curl -s --cacert $S/gw/tls/ca.crt -o /dev/null -w '%{http_code} proto=%{http_version}' https://$G/v2/) / realm: $(curl -s --cacert $S/gw/tls/ca.crt -I https://$G/v2/ | grep -i www-authenticate | grep -o 'realm="[^"]*"')"
log "GET /v2/ (CA 없이): $(curl -s -o /dev/null -w '%{http_code}' https://$G/v2/ 2>&1; curl -s https://$G/v2/ 2>&1 | grep -o 'self-signed\|unable to get local issuer[^,]*' | head -1)"
log "NodePort(http) 의 realm 도 externalURL 을 따라감: $(curl -s -I http://$NP/v2/ | grep -i www-authenticate | grep -o 'realm="[^"]*"')"
log "===== 7. 로봇 재생성(스크래치 소실) + docker/helm 실측"
R=$(curl -s -u "$HA" "http://$NP/api/v2.0/robots?q=name%3Dmigrator" | python3 -c 'import sys,json;print([r["id"] for r in json.load(sys.stdin) if r["name"].endswith("migrator")][0])')
SEC=$(curl -s -u "$HA" -X PATCH "http://$NP/api/v2.0/robots/$R" -H 'Content-Type: application/json' -d '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("secret",""))'); printf "ROBOT_NAME='robot\$migrator'\nROBOT_SECRET='%s'\n" "$SEC" > $S/hc.robot214; chmod 600 $S/hc.robot214; . $S/hc.robot214; RA="$ROBOT_NAME:$ROBOT_SECRET"; log "로봇 secret 재발급: $([ -n "$SEC" ] && echo OK || echo 실패)"
CD=$S/gw/certdir; mkdir -p $CD; cp $S/gw/tls/ca.crt $CD/ca.crt
t(){ local s=$(python3 -c 'import time;print(time.time())'); "$@" >/tmp/gw.out 2>&1; local rc=$?; python3 -c "import time;print('rc=$rc', round(time.time()-$s,1),'s')"; }
log "[GW]  inspect(app1:1.0): $(t skopeo inspect --raw --cert-dir $CD --creds "$RA" docker://$G/dlops/app1:1.0) $(python3 -c 'import json;print(json.load(open("/tmp/gw.out")).get("mediaType",""))' 2>/dev/null)"
log "[GW]  push 소형(zalp → gwtest:1): $(t skopeo copy --dest-cert-dir $CD --dest-creds "$RA" --format oci dir:$HOME/nexus-lab/scratch/zalp docker://$G/dlops/gwtest:1)"
log "[GW]  push 대용량 382MB(nexus6 big → gwbig:1): $(t skopeo copy --all --src-tls-verify=false --src-creds "admin:$(cat $HOME/nexus-lab/data/nexus6/admin.password)" --dest-cert-dir $CD --dest-creds "$RA" docker://127.0.0.1:35600/dlops/big:3.12 docker://$G/dlops/gwbig:1) $(tail -1 /tmp/gw.out | cut -c1-100)"
log "[NP]  push 대용량 382MB(비교, http NodePort): $(t skopeo copy --all --src-tls-verify=false --src-creds "admin:$(cat $HOME/nexus-lab/data/nexus6/admin.password)" --dest-tls-verify=false --dest-creds "$RA" docker://127.0.0.1:35600/dlops/big:3.12 docker://$NP/dlops/npbig:1)"
log "[GW]  pull 대용량 → dir: $(t skopeo copy --src-cert-dir $CD --src-creds "$RA" docker://$G/dlops/gwbig:1 dir:$S/gw/pulled-big) digest 동일=$([ "$(skopeo inspect --raw --cert-dir $CD --creds "$RA" docker://$G/dlops/gwbig:1 | shasum -a 256 | cut -c1-12)" = "$(skopeo inspect --raw --tls-verify=false --creds "$RA" docker://$NP/dlops/gwbig:1 | shasum -a 256 | cut -c1-12)" ] && echo yes || echo no)"; rm -rf $S/gw/pulled-big
export HELM_REGISTRY_CONFIG=$S/helm-registry-gw.json
log "[GW]  helm registry login(CA): $(helm registry login $G --ca-file $S/gw/tls/ca.crt --username "$ROBOT_NAME" --password "$ROBOT_SECRET" 2>&1 | tail -1)"
helm package ~/nexus-lab/logs/harbor27/charts/h27a -d $S/gw >/dev/null 2>&1
log "[GW]  helm push: $(helm push $S/gw/h27a-0.1.0.tgz oci://$G/charts --ca-file $S/gw/tls/ca.crt 2>&1 | grep -E 'Pushed|Error' | head -1)"
log "[GW]  helm pull: $(cd $S/gw && rm -f h27a-0.1.0.tgz && helm pull oci://$G/charts/h27a --version 0.1.0 --ca-file $S/gw/tls/ca.crt 2>&1 | tail -1; ls h27a-0.1.0.tgz 2>/dev/null)"
log "===== 8. 클러스터 노드가 Gateway 주소로 pull (containerd CA + Spegel 공존)"
for n in cp1 w1; do vs $n "sudo mkdir -p '/etc/containerd/certs.d/$G' && printf 'server = \"https://$G\"\n\n[host.\"https://$G\"]\n  capabilities = [\"pull\", \"resolve\"]\n  ca = \"/etc/containerd/certs.d/$G/ca.crt\"\n' | sudo tee '/etc/containerd/certs.d/$G/hosts.toml' >/dev/null" >/dev/null; cat $S/gw/tls/ca.crt | vs $n "sudo tee '/etc/containerd/certs.d/$G/ca.crt' >/dev/null" >/dev/null; done; log "노드 hosts.toml+ca 배치"
log "w1 crictl pull(Gateway, 로봇): $(vs w1 "sudo crictl pull --creds '$RA' $G/dlops/gwtest:1 2>&1 | tail -1 | cut -c1-120")"
helm upgrade spegel ~/nexus-lab/spegel/spegel-0.8.1.tgz -n spegel -f ~/nexus-lab/spegel/values-spegel.yaml --set 'spegel.registryFilters[0]=:latest$' --set "spegel.mirroredRegistries[7]=https://$G" --wait --timeout 3m >/dev/null 2>&1; kubectl -n spegel rollout status ds/spegel --timeout=120s >/dev/null 2>&1
log "Spegel 에 Gateway 레지스트리 추가 후 hosts.toml(w1): $(vs w1 "cat '/etc/containerd/certs.d/$G/hosts.toml' | tr '\n' ' ' | cut -c1-220")"
log "w1 crictl pull(Spegel 경유, CA 유지?): $(vs w1 "sudo crictl rmi $G/dlops/gwtest:1 >/dev/null 2>&1; sudo crictl pull --creds '$RA' $G/dlops/gwtest:1 2>&1 | tail -1 | cut -c1-120")"
kubectl create ns gwtest --dry-run=client -o yaml | kubectl apply -f - >/dev/null; kubectl -n gwtest create secret docker-registry hb-pull --docker-server=$G --docker-username="$ROBOT_NAME" --docker-password="$ROBOT_SECRET" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n gwtest run gwweb --restart=Never --image=$G/dlops/web:1.0 --overrides='{"spec":{"imagePullSecrets":[{"name":"hb-pull"}],"nodeSelector":{"kubernetes.io/hostname":"w1"}}}' >/dev/null 2>&1; sleep 25; log "파드(w1, 이미지 $G/dlops/web:1.0): $(kubectl -n gwtest get pod gwweb -o jsonpath='{.status.phase} {.status.containerStatuses[0].imageID}' | sed 's/sha256:\(.\{12\}\).*/sha256:\1/')"
log "===== 9. 정리"; kubectl delete ns gwtest --wait=false >/dev/null 2>&1; for r in gwtest gwbig npbig; do curl -s -o /dev/null -u "$HA" -X DELETE "http://$NP/api/v2.0/projects/dlops/repositories/$r"; done; log "끝"

```



---

# 부록 D. Spegel

## Spegel 0.8.1 실측 (2026-11-04 09:17~09:31) — 2노드(cp1·w1), 레지스트리 = Harbor 2.14 (비공개 프로젝트 dlops)
노드 준비: Vagrant `w1`(3GB) 생성 → Ansible 조인이 **VIP(172.16.141.100) 불통**으로 실패(kube-vip 정적 파드가 cp1 에 없음) → cp1 eth1 에 VIP 를 수동 부여(`ip addr add 172.16.141.100/24 dev eth1`) 후 `kubeadm join --config`(apiServerEndpoint=VIP, node-ip=172.16.141.14) 로 20초 만에 Ready. (랩 복구용 조치, 되돌리려면 `ip addr del`.)
사전 조건 충족 확인: containerd 2.2.1, `config_path=/etc/containerd/certs.d`, `discard_unpacked_layers=false`. 이미지 `ghcr.io/spegel-org/spegel:v0.8.1`(arm64 있음) 내부 레지스트리 반입, 차트 `oci://ghcr.io/spegel-org/helm-charts/spegel` 0.8.1.

### 1. 설치에서 겪은 문제 — 기존 미러 설정 소실
`mirroredRegistries: [Harbor, 내부레지스트리]` + `prependExisting: true` 로 설치하자 **목록에 없는 docker.io/ghcr.io/quay.io/registry.k8s.io 의 hosts.toml 이 `_backup/` 으로 옮겨져 사라짐** → w1 에서 `docker.io/library/busybox` pull 이 registry-1.docker.io 로 나가 실패(폐쇄망 미러 단절). `prependExisting` 은 "목록에 있는 레지스트리의 기존 설정을 보존" 이지 "목록 밖을 건드리지 않음" 이 아니다.
해결: 노드에 있는 **모든** 미러 레지스트리를 `mirroredRegistries` 에 명시(docker.io, ghcr.io, quay.io, registry.k8s.io, public.ecr.aws, 내부 레지스트리, Harbor). upgrade 후 각 hosts.toml 이 `[Spegel 30020] → [내부 레지스트리]` 순서로 복원되고 docker.io pull 정상.

### 2. 시험 결과 (`spegel-test.sh`, `spegel-test2.sh`)
| 시험 | 결과 |
|---|---|
| T1 피어 서빙 | cp1 이 Harbor 에서 받은 pybase(60MB)를 w1 이 pull → **Harbor 로 간 요청 0건**, Spegel 메트릭 w1 `cache=hit`, digest 일치 |
| T2 Harbor 완전 정지(core·nginx 0) | cp1 보유 이미지는 w1 이 **정상 pull**(인증 유무 무관), 클러스터에 없는 이미지는 실패. 복구 21초 |
| T3 **latest 재사용** | Harbor 의 `lt:latest` 를 A→B 로 덮어쓴 뒤 w1 pull → **옛 A 를 받음**(cp1 피어가 태그를 A 로 해석). cp1 재pull 도 A. `registryFilters: [":latest$"]` 적용 후 w1 → **B** |
| T4 무인증 pull | 비공개 프로젝트 이미지를 w1 이 **자격증명 없이** 받음(cp1 보유 시). 클러스터에 없으면 Harbor 가 거부. Spegel FAQ 가 경고하는 그대로 — 멀티테넌트에서 이미지 격리 불가 |
| T5 Spegel 파드 재시작 | 재시작 뒤 w1 pull Harbor 요청 0건(광고 복원) |
| T6 피어 다운 폴백 | cp1 Spegel 재시작 중 / cp1:30020 차단 중 w1 pull → **Harbor 로 폴백, 13.6~13.9초**(피어 경유 14.7초와 차이 없음, resolve 타임아웃 20ms) |
| T7 대용량 382MB | Harbor 직접 20.6초 vs 피어 14.7초 |
| T8 자원 | 디스크 `/var/lib/spegel` 8KB(저장소 없음), 메모리 limit 128Mi |

### 3. 판단
- 효과: 같은 클러스터에 한 번 들어온 이미지는 레지스트리(Harbor) 장애와 무관하게 pull 되고, Harbor/Nexus 요청이 줄어든다. 설치는 DaemonSet 하나, 저장소 없음.
- 반드시 할 것: ① `mirroredRegistries` 에 노드의 모든 미러 레지스트리 명시(안 하면 폐쇄망 미러 단절) ② `latest` 등 가변 태그는 `registryFilters` 로 제외하거나 digest 고정 배포 ③ 비공개 이미지 격리가 요구되면 부적합(무인증 피어 서빙).
- 첫 pull·클러스터 밖 소비자는 혜택 없음(그 자리는 레지스트리/미러의 몫).

## D-values. Spegel values (`values-spegel.yaml`)

```yaml
# Spegel 0.8.1 — 랩 2노드(cp1, w1). 이미지는 containerd 미러(ghcr.io → 내부 레지스트리)로 받는다.
image:
  repository: ghcr.io/spegel-org/spegel
  tag: v0.8.1
spegel:
  # Harbor(이관 대상)와 내부 미러 레지스트리만 Spegel 을 거치게 한다
  # 주의: 여기 없는 레지스트리의 hosts.toml 은 Spegel 이 _backup 으로 옮겨 버린다(prependExisting 와 무관).
  #       폐쇄망 미러(docker.io 등 → 내부 레지스트리)가 끊기므로 노드에 있는 모든 미러 레지스트리를 전부 적는다.
  mirroredRegistries:
    - http://172.16.141.11:30004
    - https://172.16.141.10:5000
    - https://docker.io
    - https://ghcr.io
    - https://quay.io
    - https://registry.k8s.io
    - https://public.ecr.aws
  # 기존 hosts.toml(내부 미러 설정)을 지우지 않고 Spegel 을 앞에 붙인다 — 기본값 false 면 덮어씀
  prependExisting: true
  resolveTags: true          # 1차: 기본값 그대로 두고 latest 재사용 문제를 재현한다
  mirrorResolveTimeout: "20ms"
  mirrorResolveRetries: 3
resources:
  requests: {cpu: 50m, memory: 64Mi}
  limits: {memory: 128Mi}

```

## D-test1. 피어·장애·latest·무인증·재시작 (`spegel-test.sh`)

```bash
#!/bin/bash
# Spegel 0.8.1 실측: 2노드(cp1, w1), 레지스트리 = Harbor 2.14 (172.16.141.11:30004, 프로젝트 dlops 비공개)
# T1 피어 서빙  T2 Harbor 장애 중 pull  T3 latest 재사용(스테일)  T4 무인증 pull  T5 Spegel 재시작
set -uo pipefail
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
export KUBECONFIG=$S/kubeconfig; . $S/hc.robot214; HA="admin:$(cat $S/hc.admin)"; RA="$ROBOT_NAME:$ROBOT_SECRET"
HB=172.16.141.11:30004; OUT=~/nexus-lab/logs/spegel/test.txt; : > $OUT
cd ~/Desktop/k8s-core
log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
vs(){ timeout 180 vagrant ssh $1 -c "$2" 2>/dev/null | grep -v 'Warning: Permanently' | tr -d '\r'; }
pull(){ # pull <node> <image> [creds]  → "rc=.. Ns"  (creds 생략 = 무인증)
  local c=""; [ -n "${3:-}" ] && c="--creds '$3'"
  vs $1 "s=\$(date +%s.%N); sudo crictl pull $c $2 >/tmp/pull.out 2>&1; rc=\$?; e=\$(date +%s.%N); printf 'rc=%s %.1fs %s\n' \$rc \$(echo \"\$e - \$s\" | bc) \"\$(tail -1 /tmp/pull.out | cut -c1-110)\""; }
rmi(){ vs $1 "sudo crictl rmi $2 >/dev/null 2>&1; echo removed"; }
imgid(){ vs $1 "sudo crictl inspecti $2 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[\"status\"][\"repoDigests\"][0].split(\"@\")[1][7:19])' 2>/dev/null || echo none"; }
spegel_metrics(){ # 노드별 spegel 파드의 mirror 요청 카운터
  for n in cp1 w1; do pod=$(kubectl -n spegel get pods -o wide --no-headers | awk -v n=$n '$7==n{print $1}'); ip=$(kubectl -n spegel get pod $pod -o jsonpath='{.status.podIP}')
    echo "  [$n] $(vs cp1 "curl -s http://$ip:9090/metrics" | grep -E '^spegel_mirror_requests_total' | sed -E 's/spegel_mirror_requests_total//' | tr '\n' ' ' | cut -c1-300)"; done; }
harbor_hits(){ # Harbor nginx 로그에서 w1(172.16.141.14) 의 blob/manifest 요청 수 (since 초)
  kubectl -n harbor-cnpg logs deploy/harbor214-nginx --since=${1}s 2>/dev/null | grep -E '172\.16\.141\.14' | grep -cE 'GET /v2/.*(blobs|manifests)'; }

IMG=$HB/dlops/pybase:3.12   # 60MB, 레이어 4개
log "===== 준비: 양쪽 노드에서 시험 이미지 제거"; rmi cp1 $IMG >/dev/null; rmi w1 $IMG >/dev/null; rmi cp1 $HB/dlops/app2:2.0 >/dev/null; rmi w1 $HB/dlops/app2:2.0 >/dev/null
log "Spegel 파드: $(kubectl -n spegel get pods -o wide --no-headers | awk '{print $1"@"$7":"$3}' | tr '\n' ' ')"

log "===== T1. 피어 서빙: cp1 이 Harbor 에서 받은 뒤 w1 이 받으면 cp1 에서 오는가"
log "cp1 pull(Harbor 에서): $(pull cp1 $IMG "$RA")"
sleep 3; T0=$(date +%s)
log "w1 pull(인증 포함): $(pull w1 $IMG "$RA")"
sleep 2; log "  w1 → Harbor 로 간 blob/manifest 요청: $(harbor_hits $(( $(date +%s)-T0+2 )))건 (0 이면 전부 피어에서)"
log "  Spegel 메트릭:"; spegel_metrics | tee -a $OUT
log "  digest 일치: cp1=$(imgid cp1 $IMG) w1=$(imgid w1 $IMG)"

log "===== T2. Harbor 전체 정지 중: cp1 에 있는 이미지는 w1 이 받고, 없는 이미지는 실패하는가"
log "cp1 에 app2 미리: $(pull cp1 $HB/dlops/app2:2.0 "$RA")"; rmi w1 $HB/dlops/app2:2.0 >/dev/null; rmi w1 $IMG >/dev/null
kubectl -n harbor-cnpg scale deploy harbor214-nginx harbor214-core --replicas=0 >/dev/null; sleep 8
log "Harbor 상태: $(curl -s -m 3 -o /dev/null -w '%{http_code}' http://$HB/api/v2.0/ping) (000=다운)"
log "w1 pull pybase(cp1 보유, 인증): $(pull w1 $IMG "$RA")"
log "w1 pull app2(cp1 보유, 무인증): $(pull w1 $HB/dlops/app2:2.0)"
log "w1 pull app1:1.1(클러스터에 없음): $(pull w1 $HB/dlops/app1:1.1 "$RA")"
kubectl -n harbor-cnpg scale deploy harbor214-nginx harbor214-core --replicas=1 >/dev/null; for i in $(seq 1 30); do sleep 3; [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://$HB/api/v2.0/ping)" = 200 ] && break; done; log "Harbor 복구 $((i*3))s"

log "===== T4. 무인증 pull: w1 이 자격증명 없이 비공개 프로젝트 이미지를 받는가(Spegel FAQ 경고 항목)"
rmi w1 $IMG >/dev/null; log "w1 pull pybase 무인증(cp1 보유): $(pull w1 $IMG)"
rmi w1 $HB/dlops/web:1.0 >/dev/null; rmi cp1 $HB/dlops/web:1.0 >/dev/null; log "w1 pull web:1.0 무인증(클러스터 미보유 → Harbor 가 거부해야): $(pull w1 $HB/dlops/web:1.0)"

log "===== T3. latest 재사용: 같은 태그에 다른 이미지를 올리면 피어가 옛 digest 를 주는가"
skopeo copy -q --dest-tls-verify=false --dest-creds "$RA" --format oci dir:$HOME/nexus-lab/scratch/zalp docker://$HB/dlops/lt:latest && A=$(skopeo inspect --raw --tls-verify=false --creds "$RA" docker://$HB/dlops/lt:latest | shasum -a 256 | cut -c1-12); log "Harbor lt:latest = A($A)"
rmi cp1 $HB/dlops/lt:latest >/dev/null; rmi w1 $HB/dlops/lt:latest >/dev/null
log "cp1 pull latest: $(pull cp1 $HB/dlops/lt:latest "$RA") → $(imgid cp1 $HB/dlops/lt:latest)"
skopeo copy -q --dest-tls-verify=false --dest-creds "$RA" --override-os linux --override-arch arm64 docker://docker.io/library/busybox:1.36 docker://$HB/dlops/lt:latest && B=$(skopeo inspect --raw --tls-verify=false --creds "$RA" docker://$HB/dlops/lt:latest | shasum -a 256 | cut -c1-12); log "Harbor lt:latest 를 B($B) 로 덮어씀"
log "w1 pull latest (기대: Harbor 의 B, 스테일이면 A): $(pull w1 $HB/dlops/lt:latest "$RA") → $(imgid w1 $HB/dlops/lt:latest)"
log "cp1 다시 pull latest: $(pull cp1 $HB/dlops/lt:latest "$RA") → $(imgid cp1 $HB/dlops/lt:latest)"
log "-- registryFilters [':latest$'] 적용(latest 는 Spegel 이 태그 해석 안 함)"
helm upgrade spegel ~/nexus-lab/spegel/spegel-0.8.1.tgz -n spegel -f ~/nexus-lab/spegel/values-spegel.yaml --set 'spegel.registryFilters[0]=:latest$' --wait --timeout 3m >/dev/null 2>&1; kubectl -n spegel rollout status ds/spegel --timeout=120s >/dev/null 2>&1
rmi w1 $HB/dlops/lt:latest >/dev/null
log "w1 pull latest (필터 후, 기대 B): $(pull w1 $HB/dlops/lt:latest "$RA") → $(imgid w1 $HB/dlops/lt:latest)"
log "w1 pull latest 무인증(필터 후 → 태그 해석은 Harbor 가 하므로 거부돼야): $(rmi w1 $HB/dlops/lt:latest >/dev/null; pull w1 $HB/dlops/lt:latest)"

log "===== T5. Spegel 파드 재시작 뒤 피어 서빙 유지"
kubectl -n spegel delete pod -l app.kubernetes.io/name=spegel --wait=true >/dev/null 2>&1; kubectl -n spegel rollout status ds/spegel --timeout=120s >/dev/null 2>&1; sleep 5
rmi w1 $IMG >/dev/null; T0=$(date +%s); log "w1 pull pybase(cp1 보유): $(pull w1 $IMG "$RA") / Harbor 요청 $(sleep 2; harbor_hits $(( $(date +%s)-T0+2 )))건"
log "===== 정리"; curl -s -o /dev/null -w "lt 저장소 삭제 %{http_code}\n" -u "$HA" -X DELETE http://$HB/api/v2.0/projects/dlops/repositories/lt | tee -a $OUT
log "끝"

```

## D-test2. 폴백·대용량·자원 (`spegel-test2.sh`)

```bash
#!/bin/bash
# Spegel 추가: T6 피어 다운 시 폴백(지연), T7 대용량(382MB) 피어 vs Harbor 전송 시간, T8 자원 사용
set -uo pipefail
S=/private/tmp/claude-502/-Users-isangmin-Desktop-k8s-core/15083b2b-daf4-4c3e-9697-806fdbc7b2e3/scratchpad
export KUBECONFIG=$S/kubeconfig; . $S/hc.robot214; RA="$ROBOT_NAME:$ROBOT_SECRET"; HB=172.16.141.11:30004; OUT=~/nexus-lab/logs/spegel/test2.txt; : > $OUT
cd ~/Desktop/k8s-core; log(){ echo "$(date +%H:%M:%S) $*" | tee -a $OUT; }
vs(){ timeout 300 vagrant ssh $1 -c "$2" 2>/dev/null | grep -v 'Warning: Permanently' | tr -d '\r'; }
pull(){ vs $1 "s=\$(date +%s.%N); sudo crictl pull --creds '$RA' $2 >/tmp/p.out 2>&1; rc=\$?; e=\$(date +%s.%N); printf 'rc=%s %.1fs\n' \$rc \$(echo \"\$e - \$s\" | bc)"; }
rmi(){ vs $1 "sudo crictl rmi $2 >/dev/null 2>&1; true"; }
BIG=$HB/dlops/big:3.12
log "===== T7. 대용량 382MB: Harbor 직접 vs 피어"
rmi cp1 $BIG; rmi w1 $BIG
log "cp1 ← Harbor: $(pull cp1 $BIG)"
log "w1  ← 피어(cp1): $(pull w1 $BIG)"
rmi w1 $BIG; kubectl -n spegel delete pod -l app.kubernetes.io/name=spegel --field-selector spec.nodeName=cp1 --wait=false >/dev/null 2>&1
log "===== T6. 피어(cp1) Spegel 다운 중 w1 pull → Harbor 폴백 지연"
sleep 2; log "cp1 spegel: $(kubectl -n spegel get pods -o wide --no-headers | awk '$7=="cp1"{print $3}' | tr '\n' ' ')"
log "w1 ← (cp1 spegel 재시작 중) : $(pull w1 $BIG)"
kubectl -n spegel rollout status ds/spegel --timeout=120s >/dev/null 2>&1; rmi w1 $BIG
log "cp1 노드 자체 차단(w1→cp1:30020 DROP) 후 w1 pull: $(vs w1 "sudo iptables -I OUTPUT -d 172.16.141.11 -p tcp --dport 30020 -j DROP; true" >/dev/null; pull w1 $BIG)"; vs w1 "sudo iptables -D OUTPUT -d 172.16.141.11 -p tcp --dport 30020 -j DROP; true" >/dev/null
log "===== T8. Spegel 자원"; kubectl -n spegel top pods --containers 2>/dev/null | tail -n +2 | awk '{print "  "$1, $2, $3, $4}' | tee -a $OUT; vs cp1 'du -sh /var/lib/spegel 2>/dev/null' | sed 's/^/  spegel 데이터: /' | tee -a $OUT
log "끝"

```



---

# 부록 E. 관련 시험 요약

## D-1. Harbor proxy-cache 상류 장애 (Harbor 2.13 → 2.7, 12분 단절)

캐시된 태그 pull 전부 실패(404), 태그 목록 빈 배열, 로컬에 완전 저장된 아치별 digest 만 성공, endpoint 상태는 healthy 로 남음. 재검증 끄기·오프라인 모드 옵션 없음. 코드상 로컬 폴백은 상류가 429 를 줄 때뿐. Nexus docker proxy 는 같은 조건에서 캐시된 태그·멀티아치·digest·태그목록을 전부 제공. → Harbor 간 가용성은 proxy-cache 가 아니라 replication(pull) 또는 digest 고정 배포로.

## D-2. Harbor 2.7 ChartMuseum 경로

nginx(njs) 로 Nexus helm PUT 경로를 ChartMuseum multipart POST 로 치환해 기존 엔드포인트 유지 가능. 업로드 한도 20MiB→100MiB(ConfigMap MAX_UPLOAD_SIZE), ALLOW_OVERWRITE false 면 409. 최신 Harbor 채택으로 미사용.
