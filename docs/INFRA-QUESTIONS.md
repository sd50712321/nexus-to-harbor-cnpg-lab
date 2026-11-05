# Harbor 구축 전 인프라 확인 목록 (개발 → 운영 클러스터)

랩(2VM k8s, Cilium, CNPG)에 Harbor 를 올리면서 실제로 멈춰 서서 확인해야 했던 항목만 모았다. **A 는 클러스터에 직접 들어가서 명령으로 아는 것**, **B 는 사람에게 물어야만 아는 것**, **C 는 Nexus 를 Harbor 의 상류(프록시 캐시·복제 원본)로 둘지 정할 때만 보는 것**이다. Nexus 자체 운영과 이관 원본 점검은 이 문서 범위 밖이다(README 이관 절).

표기: **[운영]** 은 개발 클러스터에는 없어도 되고 운영 전에 필요한 항목.

---

## A. 직접 들어가서 확인할 수 있는 것

명령은 Ubuntu 노드·kubeadm 기준, 읽기 전용. 예외(테스트 PVC 1개)는 표시.

### A-1. 클러스터·노드

| 확인 | 명령 | 왜 (랩 근거) |
|---|---|---|
| 노드 수·역할·OS·커널·IP·containerd 버전 | `kubectl get nodes -o wide` | containerd 2.x 는 schema1 이미지 pull 거부. 노드 2대면 PVC(RWO)가 파드를 노드에 묶는다 |
| 자원 여유 | `kubectl describe nodes \| grep -A6 Allocated`; 노드에서 `free -g; df -h /var/lib/containerd` | 랩 최소 구성 파드 8개(core·jobservice·registry·portal·redis·nginx·trivy·DB). Trivy 만 메모리 1Gi 제한 필요 |
| 아키텍처 | `uname -m` | arm64 면 공식 goharbor 이미지가 없어 대체 저장소 필요. 혼합이면 multi-arch 반입 |
| k8s 버전, 설치된 차트 | `kubectl version; helm list -A` | cert-manager·Cilium·기존 Harbor 유무 |
| CRD: Gateway API, Prometheus Operator, CNPG | `kubectl get crd \| grep -E 'gateway.networking\|monitoring.coreos\|postgresql.cnpg'` | TLS 종단을 Gateway 로 할지 Ingress 로 할지, ServiceMonitor 사용 가능 여부, CNPG 설치 여부 |
| cgroup v2 | `stat -fc %T /sys/fs/cgroup` → `cgroup2fs` | Cilium 1.20 요구사항 |
| containerd 레지스트리 설정 방식 | `containerd config dump \| grep -A4 'registry'` 의 `config_path`; `ls -R /etc/containerd/certs.d` | `certs.d` 방식이면 Harbor 도메인용 `hosts.toml` 을 재시작 없이 넣을 수 있다. 기존 미러가 있으면 충돌 점검 |
| 노드 프록시 환경변수 | `cat /etc/environment; systemctl show containerd -p Environment` | 내부 주소가 프록시로 나가면 pull 실패 |
| 시간 동기화 | `timedatectl; chronyc tracking` | 토큰·인증서 유효기간 |
| **[운영]** 전용 노드로 쓸 라벨·테인트 | `kubectl get nodes --show-labels` | 랩은 Harbor 가 컨트롤플레인에서 돌았다. 운영은 nodeSelector |

### A-2. 네트워크

| 확인 | 명령 | 왜 (랩 근거) |
|---|---|---|
| Cilium 설정 | `cilium config view \| grep -E 'kube-proxy-replacement\|enable-l2-announcements\|routing-mode\|tunnel-protocol\|mtu\|enable-gateway-api'`; `helm get values cilium -n kube-system` | L2 VIP 는 `kubeProxyReplacement` + `l2announcements` 가 켜져 있어야 한다. 랩 값: 둘 다 true, Gateway API 사용 |
| 이미 있는 LB 풀·L2 정책·VIP | `kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy -o wide; kubectl get svc -A \| grep LoadBalancer` | Harbor VIP 를 기존 풀에서 쓸지 새 풀을 만들지. 랩은 /32 풀 하나 + Gateway 셀렉터 |
| 노드 NIC 이름·서브넷·MTU | `ip -br a; ip link \| grep mtu` | L2 정책의 `interfaces` 정규식, VXLAN 오버헤드 |
| Harbor 도메인 해석과 TTL | `dig +noall +answer harbor.<domain>` | 레코드가 있는지, 전환 시 영향 시간. 노드 `hosts.toml` 디렉터리 이름 = 도메인 |
| 노드에 내부 CA 가 신뢰돼 있나 | `ls /usr/local/share/ca-certificates/` | 없으면 `hosts.toml` 의 `ca` 로 지정하거나 노드에 CA 배포 |
| 사용자·CI 러너 → VIP 443 도달 | 러너 호스트에서 `nc -zv <harbor-vip> 443` | 방화벽 개방 대상 확인 |
| CI 러너 위치 | `kubectl get pods -A \| grep -iE 'runner\|gitlab\|jenkins\|argo'` | 클러스터 안이면 ClusterIP 로도 push 가능, 밖이면 VIP·방화벽 |

### A-3. 저장소·모니터링

| 확인 | 명령 | 왜 (랩 근거) |
|---|---|---|
| StorageClass 종류·확장·회수·바인딩 | `kubectl get sc -o custom-columns=NAME:.metadata.name,PROV:.provisioner,EXPAND:.allowVolumeExpansion,RECLAIM:.reclaimPolicy,BIND:.volumeBindingMode` | local-path 는 파드를 노드에 고정하고 지표도 없다. 확장 불가면 registry PVC 를 처음부터 크게 |
| RWX 가능 여부 (**생성 1회**) | `accessModes: [ReadWriteMany]` PVC 하나 → Bound 확인 → 삭제 | registry 레플리카 2 이상의 조건. 안 되면 단일 레플리카 또는 S3 백엔드 |
| PVC 사용량 지표 노출 | `kubectl get --raw /api/v1/nodes/<node>/proxy/metrics \| grep -c kubelet_volume_stats` | 0 이면 용량 경보를 다른 방법으로. Harbor API 의 volumes 는 k8s 에서 빈 값 |
| 백엔드 여유 용량 | `kubectl get pv; df -h` (백엔드 마운트) | 랩 212 태그가 registry 5Gi·DB 2Gi |
| 모니터링 스택 | `kubectl get pods -A \| grep -iE 'prometheus\|grafana\|loki\|alertmanager'` | Harbor 는 `metrics.enabled` 한 줄로 지표를 내지만 수집기가 없으면 의미 없다. CNPG 는 설정 없이 9187 포트로 노출 |
| 기존 PostgreSQL 운영 여부 | `kubectl get cluster -A` (CNPG), 외부 DB 서비스 유무 | CNPG 자체 운영 vs `database.external` |

---

## B. 물어봐야만 아는 것

### B-1. 네트워크팀

| 질문 | 왜 |
|---|---|
| VIP 대역에서 Harbor 가 쓸 IP(또는 풀 범위) 지정 | Cilium LB IPAM 풀에 적을 값 |
| VIP 대역이 DHCP 범위에서 제외돼 있나 (한 줄 확인) | 포함돼 있으면 DHCP 가 그 IP 를 다른 장비에 줄 수 있다 |
| 스위치가 노드 포트의 ARP 광고와 장애 시 MAC 변경을 허용하나 (port security, DAI) | L2 공지 방식의 전제. 막혀 있으면 BGP 또는 하드웨어 LB |
| 하드웨어 L4 LB 가 있나 | 있으면 LB 의 VIP → NodePort 로 가고 Cilium L2 가 필요 없다 |
| **[운영]** BGP 피어링 가능 여부(ASN·피어 IP) | 서브넷 제약 없는 VIP |
| 방화벽 개방 절차·소요: 사용자·러너 → VIP 443, 노드 → VIP 443(노드 pull) | A-2 도달 테스트 실패 구간의 해결 경로 |
| **[운영]** 개발↔운영 사이트 간 대역폭·지연 | Harbor→Harbor 복제(승격) 시간 |

### B-2. DNS 담당

| 질문 | 왜 |
|---|---|
| Harbor 도메인(필요하면 와일드카드) 레코드 생성과 권한·절차 | 노드 `hosts.toml` 디렉터리 이름과 인증서 SAN 이 여기에 맞춰진다 |
| TTL 을 5분 정도로 둘 수 있나 | VIP 변경·비상 전환 시 영향 시간 |

### B-3. 보안 / PKI

| 질문 | 왜 |
|---|---|
| 내부 CA 발급 절차·소요, SAN 에 IP 포함 가능 여부, 갱신 주기 | Harbor TLS. 노드·러너·사용자 PC 에 체인 배포 |
| Harbor 인증 방식(LDAP/OIDC/로컬)과 그룹→프로젝트 매핑 규칙 | 프로젝트·로봇 계정 설계 |
| 비밀값 보관처(Vault 등) | 차트 값에는 `existingSecret` 참조만 두고 비밀을 안 적는다 |
| 취약점 스캔 의무, Trivy DB 반입 경로·주기 | 폐쇄망 Trivy 는 DB 를 반입해 Harbor 자체 저장소에 올리고 `offlineScan` |
| 이미지 서명(cosign 등) 요구 여부 | 복제 시 서명 동반 여부, 정책 설정 |
| 감사 로그 보관 요건 | Harbor 감사 로그 보존 기간 |
| 노드 pull 자격: 네임스페이스 기본 SA 에 imagePullSecrets 자동 주입 가능 여부 | 사설 프로젝트 pull 조건 |
| **[운영]** 변경 승인 절차와 작업 창 | 노드 라우팅·DNS 전환 모두 승인 대상 |

### B-4. 스토리지팀

| 질문 | 왜 |
|---|---|
| 필요 용량(현재 이미지 총량 + 증가량) 할당과 증설 절차 | registry PVC·DB PVC |
| RWX 를 정책상 줘도 되나 | A-3 에서 기술적으로 됐더라도 |
| 스냅샷·백업 서비스와 복구 절차 | CNPG 백업과 registry 백업을 짝 맞춰야 복구된다 |
| S3 호환 오브젝트 스토리지(MinIO 등) 유무 | 있으면 registry 백엔드와 CNPG WAL 아카이브 둘 다 해결 |
| IOPS·처리량 상한 | 동시 pull 병목 |

### B-5. 서버·자산 / 반입

| 질문 | 왜 |
|---|---|
| **[운영]** Harbor 전용 노드 확보 가능 여부와 스펙 | PVC 고정·격리 |
| 폐쇄망 반입 절차: 매체, 검사, 소요일 | Harbor 이미지 8종 + exporter + Trivy DB + 테스트 이미지 |
| 내부 NTP 소스 | A-1 에서 동기화가 안 돼 있을 때 |

### B-6. 클러스터 구축자 / 플랫폼

| 질문 | 왜 |
|---|---|
| 노드 설정 관리 방식(Ansible·수동·이미지 베이크), `/etc/containerd/certs.d` 를 우리가 넣어도 되나 | Harbor 도메인 CA·미러 설정은 노드 파일 배포가 전부. 경로 없으면 DaemonSet |
| Cilium 값을 바꿔도 되나 (`l2announcements` 켜기는 에이전트 재시작) | A-2 에서 꺼져 있을 때 |
| 1~6번 재구축·네트워크 변경 계획 | 있으면 Harbor 데이터(PVC `keep`) 보존 절차 |
| 개발 Harbor 를 운영 Harbor 의 복제 원본으로 쓸 것인가(승격 경로, 단방향/양방향) | Harbor→Harbor 복제 설계 |
| 롤백 결정권자와 기준 | 노드 라우팅=파일 삭제, DNS=레코드 복귀 |
| **[운영]** RPO/RTO, 알림 채널, 당직 | 백업 주기와 pull 프로브 경보 설계 |

---

## C. Nexus 를 Harbor 상류(프록시 캐시 / 복제 원본)로 둘 때만

Harbor 가 Nexus 를 상류로 보는 구성(퍼블릭 이미지를 Nexus 가 계속 들고 있고 Harbor 가 캐시·복제하는 경우)을 택할 때만 본다. 안 택하면 이 절은 건너뛴다.

| 확인·질문 | 방법 | 왜 (랩 근거) |
|---|---|---|
| Harbor 파드 → Nexus docker 커넥터 도달 | `kubectl run nt --rm -it --image=<반입 busybox> -- nc -zv <nexus> 5001` | 노드가 닿아도 파드 egress 는 다를 수 있다. 랩은 중계가 필요했다 |
| 커넥터가 http 인지 https 인지, 인증서 체인 | `openssl s_client -connect <nexus>:5001 -showcerts </dev/null` | 엔드포인트 `insecure` 값, CA 반입 |
| `_catalog` 허용 | `curl -s -u user:pass https://<nexus>:5001/v2/_catalog` | pull 복제가 catalog 로 목록을 읽는다. 이름 필터 없이 걸면 전체 목록 요청이 카운터에 들어간다 |
| 익명 pull 허용 | `GET /service/rest/v1/security/anonymous` | 엔드포인트에 자격증명을 넣을지 |
| 현재 일 요청 수와 CE 한도 여유 | `GET /service/rest/metrics/data` → `content_request_count.last_24h` | Harbor 프록시 첫 pull 은 직접 pull 의 3배 요청, 반복 pull 은 동률. 캐시 예열·복제가 20만/일을 넘기지 않게 |
| (물어볼 것) 상류용 read 계정 발급 | Nexus 운영자 | 엔드포인트 자격증명 |
| (물어볼 것) 캐시 보존 기간 합의 | 운영 정책 | 프록시 프로젝트 기본 7일 후 미사용 캐시 삭제. 상류 장애 대비면 늘리거나 끈다 |

---

## D. 랩에서 못 재서 운영 값으로만 확인되는 것

- 실제 CSI 의 PVC 사용량 지표 노출 여부, RWX 성능.
- 사이트 간 복제 처리량.
- LDAP 그룹 매핑, 하드웨어 LB·BGP 연동.
