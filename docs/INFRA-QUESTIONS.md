# Harbor 이관 테스트 전 인프라 확인 질문 목록 (개발 → 운영)

랩(2VM k8s + podman Nexus)을 만들면서 실제로 멈춰 서서 확인해야 했던 항목만 모았다. 각 줄의 "왜" 는 랩에서 그 항목 때문에 생긴 일이고, 답을 못 받으면 테스트 중 그 지점에서 다시 멈춘다. 수치는 운영 값을 받아 적는 칸이다.

표기: **[개발]** 개발 클러스터 테스트 전에 필요, **[운영]** 운영 이관 전에 추가로 필요. 표기 없으면 둘 다.

## 0. 먼저 받아 둘 "현황 자료" (질문보다 자료가 빠르다)

| 자료 | 왜 |
|---|---|
| 노드 목록(호스트명·IP·역할·OS·커널·CPU/RAM/디스크·아키텍처) | 1~8번 노드의 현재 용도가 문서와 다르다(7·8=Nexus, 1~6=개발 클러스터). 랩은 arm64 라 이미지 전부 다른 저장소(octohelm)에서 받아야 했다. x86 인지 arm 인지가 반입 이미지 목록을 바꾼다 |
| `kubectl get nodes -o wide`, `kubectl version`, `helm list -A`, `kubectl get sc,crd` 출력 | k8s 1.34 / containerd 2.2 / Cilium 1.20 / Gateway API CRD / cert-manager / 기본 StorageClass 유무가 Harbor 차트 값과 노드 설정 절차를 결정했다 |
| Nexus: 버전, 저장소 목록(`/service/rest/v1/repositories`), 포트 배치, blobstore 크기, `/service/rest/metrics/data` 의 `content_request_count`·`component_total_count` | 3.82 CE 는 20만 요청/일·10만 컴포넌트 한도. 이관 자체(전수 pull)가 카운터를 올린다. Harbor 프록시 첫 pull 은 직접 pull 의 3배 요청 |
| 네트워크 구성도(서브넷·VLAN·방화벽 존·DNS 서버·내부 CA) | VIP 방식(L2 vs BGP), 인증서 체인 배포 범위, 열어야 할 포트가 여기서 나온다 |

## 1. 서버·클러스터

| # | 질문 | 왜 (랩 근거) |
|---|---|---|
| 1-1 | Harbor 를 올릴 노드는 몇 대, CPU/RAM 은? Trivy 를 켤 것인가? | 랩 최소 구성이 core·jobservice·registry·portal·redis·nginx·trivy·CNPG 로 파드 8개. Trivy 만 메모리 1Gi 제한을 걸어야 했다. 노드 2대면 PVC 가 RWO 라 파드가 노드에 묶인다 |
| 1-2 | CPU 아키텍처(x86_64 / arm64), 혼합 여부 | arm64 라 공식 `goharbor/*` 이미지가 없어 대체 저장소를 썼다. 혼합이면 multi-arch 이미지 반입 필요 |
| 1-3 | containerd 버전 (`containerd --version`), 설정 파일 버전, `config_path` 값 | containerd 2.x 는 schema1(v1 매니페스트) 이미지 pull 을 거부한다. 노드 라우팅은 `/etc/containerd/certs.d` 가 켜져 있어야 재시작 없이 된다 |
| 1-4 | 노드 설정을 누가 어떻게 관리하나 (Ansible? 수동? 이미지 베이크?) `/etc/containerd/certs.d` 를 우리가 넣을 수 있나 | 퍼블릭=Nexus·사내=Harbor 라우팅은 노드 파일 배포가 전부다. 배포 경로가 없으면 DaemonSet 으로 넣어야 한다 |
| 1-5 | 7·8번 노드에 이전 클러스터 잔재(kubelet·kube-vip·iptables 규칙)가 남아 있나 | Nexus 가 쓰는 포트·VIP 와 충돌 가능. VIP 받기 전에 정리 확인 |
| 1-6 | **[운영]** 운영 클러스터 구성(컨트롤플레인 수, 워커 수, 노드 라벨/테인트), Harbor 전용 노드를 둘 수 있나 | 랩은 PVC 가 cp1 에 묶여 Harbor 가 컨트롤플레인에서 돌았다. 운영은 전용 노드+nodeSelector 가 필요 |
| 1-7 | 노드 시간 동기화(NTP 소스) | 토큰 만료·인증서 유효기간 판정이 시각에 의존. 폐쇄망은 내부 NTP 유무를 확인 |
| 1-8 | 커널 버전, cgroup v2 여부 | Cilium 1.20·kubeProxyReplacement 요구사항 |

## 2. 네트워크

| # | 질문 | 왜 (랩 근거) |
|---|---|---|
| 2-1 | 노드 서브넷에서 VIP 로 쓸 IP 를 몇 개 받을 수 있나 (Nexus용 1 + 클러스터 LB 풀) | 랩 harbor.lab = Cilium LB IPAM + L2 공지로 /32 하나. Nexus 는 클러스터 밖이라 keepalived 용 별도 1개 |
| 2-2 | 스위치가 노드 포트에서 다른 IP 의 ARP 광고·장애 시 MAC 변경·VRRP 를 허용하나 (port security, DAI) | L2 VIP 와 keepalived 둘 다 이걸 전제로 한다. 막혀 있으면 BGP 로 가야 하고 네트워크팀 작업이 커진다 |
| 2-3 | BGP 피어링이 가능한가 (ASN, 피어 IP) **[운영]** | 운영에서 서브넷 제약 없는 VIP 대역을 원하면 이쪽 |
| 2-4 | 내부 DNS: 레코드를 누가 만들고 TTL 은 얼마인가, 와일드카드 가능한가 | Nexus 도메인이 노드 실제 IP 에 박혀 있다. VIP 전환 시 TTL 동안 영향. Harbor 도메인은 노드 `hosts.toml` 디렉터리 이름과 일치해야 한다 |
| 2-5 | 내부 CA: 누가 발급하나, 체인 구조, 발급 소요, SAN 에 IP 포함 가능 여부 | Harbor TLS 를 랩 CA 로 발급해 노드·Nexus·skopeo 에 각각 CA 를 넣어야 했다. Nexus→Harbor 방향은 Nexus truststore 에 CA 를 넣고 재시작 |
| 2-6 | 개발 클러스터 노드 → Nexus 포트(5001/12000), Harbor 노드 → Nexus, CI 러너 → Harbor 443: 방화벽 정책 | Harbor 가 Nexus 를 상류로 쓰려면 Harbor 파드 egress 가 Nexus 에 닿아야 한다. 랩은 socat 중계가 필요했다 |
| 2-7 | 노드에 `http_proxy`/`no_proxy` 환경변수가 설정돼 있나 | containerd·Harbor 가 내부 주소를 프록시로 보내면 pull 이 실패한다 |
| 2-8 | Cilium 설정: `kubeProxyReplacement`, `l2announcements.enabled`, Gateway API 사용 여부, 오버레이(VXLAN) 또는 네이티브 라우팅, MTU | L2 VIP 는 앞의 두 값이 켜져 있어야 한다. 랩은 Gateway 로 Harbor TLS 종단 |
| 2-9 | 사이트 간 대역폭·지연 **[운영]** | 운영 Nexus→Harbor 복제·전수 이관 시간 산정. 랩 212 태그 전수 대조가 17초였지만 2VM 로컬 값이다 |
| 2-10 | Nexus 앞에 리버스 프록시(nginx/LB)가 있나, X-Forwarded-For 를 넣나 | request.log 의 IP 열이 XFF 첫 값이라 프록시 유무에 따라 "누가 pull 했나" 분석 가능 여부가 갈린다 |
| 2-11 | 폐쇄망 반입 경로: 외부 이미지·차트·Trivy DB 를 어떻게 들여오나 (매체, 검사, 소요일) | Harbor 이미지 8종 + exporter + Trivy DB 를 사전 반입해야 한다. Trivy 는 `offlineScan`·DB 저장소를 Harbor 자체로 지정했다 |

## 3. 저장소

| # | 질문 | 왜 (랩 근거) |
|---|---|---|
| 3-1 | StorageClass 종류(NFS / Ceph / 로컬 / 벤더 CSI), 기본 SC 지정 여부 | 랩 local-path 는 파드를 노드에 고정시키고 PVC 사용량 지표(`kubelet_volume_stats_*`)를 내지 않았다 |
| 3-2 | RWX 지원 여부 | registry 를 2개 이상 레플리카로 두려면 RWX 또는 S3 호환 스토리지. RWO 면 단일 레플리카 |
| 3-3 | 볼륨 확장(`allowVolumeExpansion`), 스냅샷, 복제 지원 | registry PVC 는 커지기만 한다. 확장 불가면 처음부터 크게 |
| 3-4 | 현재 Nexus blobstore 크기(docker / helm 별), 월 증가량 | Harbor registry PVC 와 CNPG PVC 크기 산정. 랩은 registry 5Gi·DB 2Gi 로 212 태그 |
| 3-5 | S3 호환 오브젝트 스토리지(MinIO 등)가 있나 | 있으면 registry 백엔드와 CNPG WAL 아카이브·백업 대상 둘 다 해결. 없으면 PVC 기반 백업 절차를 따로 만들어야 한다 |
| 3-6 | 백업 정책: 누가, 어디로, 보관 기간, 복구 훈련 주기 | CNPG 백업과 registry 데이터 백업이 짝이 맞아야 복구된다. 랩은 PITR 복구 연습만 했다 |
| 3-7 | 스토리지 IOPS·처리량 한계 | 전수 이관·동시 pull 때 병목. 랩 병렬 4 로 이관 |
| 3-8 | 기존 PostgreSQL 운영 조직이 있나, 외부 DB 를 써야 하나 | CNPG 자체 운영 vs 외부 DB. 외부면 Harbor `database.external` 값으로 전환 |
| 3-9 | **[운영]** PV 재사용(reclaim) 정책, 네임스페이스 삭제 시 데이터 보호 | 랩은 `resourcePolicy: keep` 으로 차트 삭제 시 PVC 보존 |

## 4. Nexus 쪽 (이관 원본)

| # | 질문 | 왜 (랩 근거) |
|---|---|---|
| 4-1 | 저장소별 종류(hosted/proxy/group)와 writePolicy, 익명 pull 허용 여부 | 컷오버 때 hosted 를 DENY 로 바꿔 push 차단·pull 유지를 확인했다. 익명 pull 은 노드 라우팅에서 imagePullSecrets 필요 여부를 가른다 |
| 4-2 | docker 커넥터 포트와 TLS 여부(http 인지, https 면 인증서 누구 것인지) | Harbor 엔드포인트 등록 시 `insecure` 값과 CA 반입이 달라진다 |
| 4-3 | `/v2/_catalog` 허용 여부 | Harbor pull 복제가 catalog 로 목록을 읽는다 |
| 4-4 | 이관용 계정: 전 저장소 read 가 가능한 계정을 받을 수 있나, LDAP 연동인가 | 전수 이관·대조 스크립트가 REST 컴포넌트 API 와 docker pull 둘 다 쓴다 |
| 4-5 | 고전 helm(index.yaml) 저장소 사용자와 CI 가 몇 곳인가 | Harbor 는 OCI 차트만 받는다. 사용자 쪽 `helm repo add` → `oci://` 전환이 필수 |
| 4-6 | schema1(v1 매니페스트) 이미지가 있나 (오래된 빌드) | containerd 2.x 노드에서 pull 거부. `skopeo copy --format oci` 변환 대상 목록이 필요 |
| 4-7 | 현재 일 요청 수(`last_24h`), 컴포넌트 수, 유예 상태·종료일 | 이관 작업이 20만/일을 넘기면 유예 뒤엔 새 push·프록시 캐시가 막힌다. 작업 창을 한도 안에서 잡는다 |
| 4-8 | request.log 보관 기간과 위치, 로테이션 설정 변경 가능 여부 | 기본 90일. 이관 전후 "누가 어디서 pull 하나" 분석의 유일한 자료 |
| 4-9 | 정리 정책(cleanup policy)·태스크 스케줄 | 이관 중 원본이 지워지면 대조가 깨진다. 이관 기간 동안 중지 |
| 4-10 | **[운영]** 프록시 저장소의 상류(docker.io, quay.io, ghcr.io, registry.k8s.io …) 목록과 group 구성 | 노드 `hosts.toml` 에 상류별로 미러를 적어야 한다. group 은 네임스페이스를 납작하게 만들어 이름 충돌 점검이 필요 |

## 5. 보안·정책

| # | 질문 | 왜 (랩 근거) |
|---|---|---|
| 5-1 | Harbor 인증: 로컬 DB / LDAP / OIDC 중 무엇, LDAP 라면 그룹→프로젝트 매핑 규칙 | 로봇 계정·프로젝트 권한 설계가 여기서 시작 |
| 5-2 | 이미지 네이밍 규칙과 팀별 프로젝트 경계, 공개 프로젝트 허용 여부 | 이관 스크립트의 `프로젝트/저장소` 매핑 규칙을 먼저 정해야 한다. 랩은 프로젝트 조각 없는 이름을 기본 프로젝트로 보냈다 |
| 5-3 | 취약점 스캔 의무 여부, Trivy DB 갱신 주기와 반입 경로 | 폐쇄망 Trivy 는 DB 를 반입해 Harbor 에 올리고 `skipUpdate`/`offlineScan` 설정 |
| 5-4 | 이미지 서명(cosign/notation) 요구 여부 | 복제·프록시 시 서명 아티팩트 동반 여부가 달라진다 |
| 5-5 | 비밀값 보관 위치(Vault 등), Harbor admin·로봇 토큰·DB 비밀번호를 어디에 둘지 | 랩은 k8s Secret 참조(`existingSecret*`)로 차트 값에 비밀을 안 적었다 |
| 5-6 | 감사 로그·접근 로그 보관 요건 | Harbor 감사 로그 보존 기간, request 로그 수집 대상 여부 |
| 5-7 | 노드의 `imagePullSecrets` 정책: 네임스페이스 기본 SA 에 자동 주입할 수 있나 | 사설 프로젝트 pull 은 시크릿이 필요. 랩에서 로봇 범위 문제로 NotFound 를 한 번 겪었다 |
| 5-8 | **[운영]** 변경 승인 절차와 작업 창 | 노드 라우팅 반영·DNS 전환·Nexus DENY 전환은 모두 승인 대상 |

## 6. 운영·모니터링

| # | 질문 | 왜 (랩 근거) |
|---|---|---|
| 6-1 | 프로메테우스/그라파나가 있나, Operator(ServiceMonitor CRD) 방식인가 | Harbor 는 `metrics.enabled` 한 줄로 지표를 내지만 수집기가 없으면 의미 없다. CNPG 는 이미 9187 로 노출 |
| 6-2 | 로그 수집기(Loki/ELK) 유무와 수집 대상 추가 절차 | Harbor core·registry 로그, Nexus request.log |
| 6-3 | Nexus 20만 카운터를 어디에 그릴 것인가 | 프로메테우스 엔드포인트에 안 나온다. `/service/rest/metrics/data` JSON 을 따로 떠야 한다 |
| 6-4 | 알림 채널(메일·메신저)과 당직 체계 | 상류 health 표시는 지연된다. 합성 pull 프로브 실패를 바로 사람에게 보내야 한다 |
| 6-5 | CI 러너 위치(클러스터 안/밖), push 에 쓰는 자격증명 관리 방식 | 컷오버 때 러너의 push 대상을 Harbor 로 바꾸는 일이 가장 많은 손이 간다 |
| 6-6 | 롤백 기준과 담당 | 노드 라우팅은 파일 삭제로, DNS 는 레코드 복귀로, Nexus 는 ALLOW 복귀로 각각 되돌린다. 누가 어느 순간 결정하나 |

## 7. 개발 → 운영 순서에서 추가로 묻는 것 **[운영]**

| # | 질문 | 왜 |
|---|---|---|
| 7-1 | 운영 클러스터에서 개발 Harbor 를 복제 원본으로 쓸 수 있나 (운영→개발 단방향? 양방향?) | 승격(promotion) 경로 설계. Harbor→Harbor 복제는 `harbor` 어댑터로 된다 |
| 7-2 | 운영 Nexus 와 개발 Nexus 가 같은 인스턴스인가 | 같으면 이관 테스트의 pull 이 운영 카운터를 올린다 |
| 7-3 | 운영 이관 때 "읽기 전용 기간" 을 얼마나 허용하나 | 컷오버 = Nexus DENY → 델타 이관 → 대조 → DNS/러너 전환. 랩은 수 분이지만 운영은 전수 대조 시간이 지배 |
| 7-4 | 재해 복구 목표(RPO/RTO) | CNPG 백업 주기와 registry 백업 방식이 여기서 결정된다 |

## 8. 랩에서 못 재서 운영 값으로만 확인되는 것

- Nexus "Usage nearing limits" 가 켜지는 서버 측 임계(75% 추정).
- 실제 CSI 의 PVC 사용량 지표 노출 여부, RWX 성능.
- 사이트 간 복제 처리량.
- LDAP 그룹 매핑, 하드웨어 LB·BGP 연동.
