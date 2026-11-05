# Harbor 이관 테스트 전 인프라 확인 목록 (개발 → 운영)

랩(2VM k8s + podman Nexus)을 만들면서 실제로 멈춰 서서 확인해야 했던 항목만 모았다. **A 는 클러스터·노드·Nexus 에 직접 들어가서 명령으로 알 수 있는 것**, **B 는 사람에게 물어야만 아는 것**이다. A 를 먼저 끝내고 B 를 들고 가면 질문이 절반으로 준다. 각 항목의 "왜" 는 랩에서 그 항목 때문에 생긴 일이다.

표기: **[운영]** 은 개발 클러스터 테스트에는 없어도 되고 운영 이관 전에 필요한 항목.

---

## A. 직접 들어가서 확인할 수 있는 것

명령은 Ubuntu 계열 노드·kubeadm 클러스터 기준. 읽기 전용이고, 예외(테스트 PVC 1개 생성)는 표시했다.

### A-1. 클러스터·노드

| 확인 | 명령 | 왜 |
|---|---|---|
| 노드 수·역할·OS·커널·IP·CRI 버전 | `kubectl get nodes -o wide` | 한 줄에 containerd 버전까지 나온다. 2.x 면 schema1 이미지 pull 거부 |
| CPU/RAM/디스크 여유 | `kubectl describe nodes \| grep -A6 Allocated`, 노드에서 `free -g; df -h /var/lib/containerd` | 랩 최소 구성이 파드 8개. Trivy 만 1Gi 제한 필요 |
| 아키텍처 | `uname -m` (노드마다) | arm64 면 공식 goharbor 이미지 없음. 혼합이면 multi-arch 반입 |
| k8s 버전, 설치된 차트 | `kubectl version; helm list -A` | cert-manager·Cilium·기존 Harbor 유무 |
| CRD: Gateway API, Prometheus Operator, CNPG | `kubectl get crd \| grep -E 'gateway.networking\|monitoring.coreos\|postgresql.cnpg'` | Gateway 로 TLS 종단할지, ServiceMonitor 를 쓸 수 있을지 |
| cgroup v2 | `stat -fc %T /sys/fs/cgroup` → `cgroup2fs` | Cilium 1.20 요구사항 |
| containerd 레지스트리 설정 방식 | `containerd config dump \| grep -A4 'plugins."io.containerd.cri.v1.images".registry'` → `config_path` 값, `ls -R /etc/containerd/certs.d` | `certs.d` 방식이어야 재시작 없이 노드 라우팅 반영. 이미 미러가 있으면 충돌 점검 |
| 노드에 프록시 환경변수 | `cat /etc/environment; systemctl show containerd -p Environment; env \| grep -i proxy` | 내부 주소가 프록시로 나가면 pull 실패 |
| 시간 동기화 | `timedatectl; chronyc tracking` | 토큰·인증서 유효기간 판정 |
| 7·8번의 이전 클러스터 잔재 | `systemctl list-units --all \| grep -E 'kubelet\|kube-vip\|keepalived\|haproxy'; ss -lntp; iptables -S \| grep -c KUBE; ip -br a` | 새 VIP·포트와 충돌 가능 |

### A-2. 네트워크

| 확인 | 명령 | 왜 |
|---|---|---|
| 노드 IP 가 DHCP 인지 고정인지 | `grep -rE 'dhcp4\|addresses' /etc/netplan/; networkctl status \| grep -iE 'address\|lease'` | Nexus 노드가 DHCP 임대 위에 있으면 IP 가 바뀔 수 있다. **7·8번부터 확인** |
| 서브넷·NIC 이름·MTU | `ip -br a; ip link \| grep mtu` | L2 VIP 정책의 `interfaces` 값, VXLAN 오버헤드 |
| Nexus·Harbor 도메인 해석과 TTL | `dig +noall +answer nexus.<domain>` (TTL 열), `resolvectl status` | A 레코드가 노드 IP 인지 VIP 인지, 전환 시 영향 시간 |
| 노드 → Nexus 포트 도달 | `nc -zv <nexus> 5001; nc -zv <nexus> 12000; curl -sI https://<nexus>:5001/v2/` | 라우팅 미러 대상이 닿는지. 응답 헤더로 http/https·인증 방식 확인 |
| 파드 → Nexus 도달 (Harbor 가 Nexus 를 상류로 쓸 때) | `kubectl run nt --rm -it --image=<반입된 busybox> -- nc -zv <nexus> 5001` | 랩은 socat 중계가 필요했다. 노드와 파드의 egress 정책이 다를 수 있음 |
| Nexus 커넥터 TLS 와 체인 | `openssl s_client -connect <nexus>:5001 -showcerts </dev/null \| grep -E 'issuer\|subject'` | Harbor 엔드포인트 `insecure` 값과 CA 반입 여부 |
| 노드에 내부 CA 가 이미 신뢰돼 있나 | `ls /usr/local/share/ca-certificates/; grep -c BEGIN /etc/ssl/certs/ca-certificates.crt` | Harbor TLS 를 내부 CA 로 발급할 때 노드 `hosts.toml` 의 `ca` 지정 필요 여부 |
| Cilium 설정 | `cilium config view \| grep -E 'kube-proxy-replacement\|enable-l2-announcements\|routing-mode\|tunnel-protocol\|mtu\|enable-gateway-api'`, `helm get values cilium -n kube-system` | L2 VIP 는 kubeProxyReplacement + l2announcements 가 켜져 있어야 한다 |
| 이미 쓰는 LB 풀과 VIP | `kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy -o wide; kubectl get svc -A \| grep LoadBalancer` | 풀 범위가 Nexus 노드 IP 를 포함하는지 |
| 기존 Nexus 프록시 저장소의 상류 목록 | A-4 의 저장소 목록 JSON 에서 `attributes.proxy.remoteUrl` | 노드 `hosts.toml` 을 상류별로 써야 한다 |

### A-3. 저장소

| 확인 | 명령 | 왜 |
|---|---|---|
| StorageClass 종류·확장·회수 정책 | `kubectl get sc -o custom-columns=NAME:.metadata.name,PROV:.provisioner,EXPAND:.allowVolumeExpansion,RECLAIM:.reclaimPolicy,BIND:.volumeBindingMode` | local-path 는 파드를 노드에 고정. 확장 불가면 처음부터 크게 |
| RWX 가능 여부 (**생성 1회**) | `accessModes: [ReadWriteMany]` PVC 하나 만들어 Bound 되는지 → 삭제 | registry 레플리카 2 이상의 조건 |
| PVC 사용량 지표 노출 | `kubectl get --raw /api/v1/nodes/<node>/proxy/metrics \| grep -c kubelet_volume_stats` | 0 이면 용량 경보를 다른 방법으로(랩 local-path 가 0) |
| 기존 PV 사용량 | `kubectl get pv; df -h` (백엔드 마운트) | 여유 용량 |
| 모니터링 스택 유무 | `kubectl get pods -A \| grep -iE 'prometheus\|grafana\|loki\|alertmanager'` | Harbor `metrics.enabled` 를 켤 의미가 있는지 |
| CI 러너가 클러스터 안에 있나 | `kubectl get pods -A \| grep -iE 'runner\|gitlab\|jenkins\|argo'` | 컷오버 때 push 대상 변경 범위 |

### A-4. Nexus (관리자 API, 읽기 전용)

`B=https://<nexus>:8081` 등 관리 URL, `A=user:pass` 로 가정.

| 확인 | 명령 | 왜 |
|---|---|---|
| 버전 | `curl -s -u $A $B/service/rest/v1/status/check \| head -c 200` 또는 로그인 화면 하단 | 3.82 CE 한도 규칙 전제 |
| 저장소 목록·종류·writePolicy·프록시 상류 | `curl -s -u $A $B/service/rest/v1/repositories \| python3 -m json.tool` | hosted/group/proxy 구성, 컷오버 때 DENY 대상, 노드 미러 상류 |
| 익명 접근 | `curl -s -u $A $B/service/rest/v1/security/anonymous` | 노드 pull 에 imagePullSecrets 필요 여부 |
| 인증 렐름(LDAP 여부) | `curl -s -u $A $B/service/rest/v1/security/realms/active` | 이관 계정 발급 경로 |
| blobstore 크기 | `curl -s -u $A $B/service/rest/v1/blobstores` (`totalSizeInBytes`) | Harbor PVC 산정 |
| 컴포넌트 수·일 요청 수·유예 상태 | `curl -s -u $A $B/service/rest/metrics/data \| python3 -c 'import sys,json;g=json.load(sys.stdin)["gauges"];print(g["nexus.analytics.content_request_count"]["value"]["last_24h"], g["nexus.analytics.component_total_count"]["value"])'` | 이관 pull 이 20만/일을 넘기지 않게 작업 창 산정 |
| `_catalog` 허용 | `curl -s -u $A https://<nexus>:5001/v2/_catalog \| head -c 200` | Harbor pull 복제가 catalog 로 목록을 읽는다 |
| request.log 보관 범위 | 서버에서 `ls <data>/log/request-*.log.gz \| head -1; ls … \| tail -1` | "누가 어디서 pull 하나" 분석 자료의 기간 |
| Nexus 앞 리버스 프록시 유무 | `curl -sI https://<nexus>:5001/v2/ \| grep -iE 'server\|via\|x-forwarded'`; request.log 의 IP 열이 한 대의 IP 로만 찍히는지 | XFF 유무에 따라 IP 분석 가능 여부 |
| 고전 helm 저장소와 사용량 | 저장소 목록에서 `format: helm`; request.log 에서 `/repository/<helm>/index.yaml` 요청 IP 수 | Harbor 는 OCI 차트만 받는다. 사용처 수 = 전환 작업량 |
| schema1 이미지 목록 | 태그마다 `skopeo inspect --raw docker://<nexus>:5001/<repo>:<tag> \| python3 -c 'import sys,json;print(json.load(sys.stdin).get("schemaVersion"))'` 를 돌려 1 인 것 | containerd 2.x 노드에서 pull 거부 → 변환 대상 |
| 정리 정책·예약 태스크 | `curl -s -u $A $B/service/rest/v1/tasks` | 이관 중 원본이 지워지면 대조가 깨진다 |
| 개발·운영이 같은 Nexus 인가 | 두 환경의 Nexus 도메인이 같은 IP 로 해석되는지 `dig` | 같으면 테스트 pull 이 운영 카운터를 올린다 |

---

## B. 물어봐야만 아는 것

### B-1. 네트워크팀

| 질문 | 왜 |
|---|---|
| 7·8번 IP 와 1~6번 IP 가 DHCP 범위인가, 예약·제외가 걸려 있나 | A-2 에서 DHCP 로 나오면 임대 만료·재부팅에 IP 가 바뀔 수 있다. 고정은 DHCP 서버 쪽 작업 |
| IPAM(IP 장부)에 7·8번이 무슨 용도로 적혀 있나 → "운영 Nexus, 회수 금지" 로 변경 | "안 쓰는 개발 노드" 로 남아 있으면 회수·재배정 위험 |
| 노드 서브넷에서 VIP 로 IP 몇 개를 받을 수 있나 (Nexus 1개 + 클러스터 LB 풀) | 랩 Harbor VIP = Cilium LB IPAM + L2. Nexus 는 클러스터 밖이라 keepalived 용 별도 |
| 스위치가 노드 포트의 ARP 광고·장애 시 MAC 변경·VRRP 멀티캐스트를 허용하나 (port security, DAI) | L2 VIP 와 keepalived 의 전제. 막혀 있으면 BGP 또는 하드웨어 LB |
| 하드웨어 L4 LB 가 있나, 있으면 VIP 를 거기서 받을 수 있나 | 있으면 서버 쪽 keepalived 없이 7·8번을 백엔드로 묶는다 |
| **[운영]** BGP 피어링 가능 여부(ASN·피어 IP) | 서브넷 제약 없는 VIP 대역 |
| 방화벽 개방 절차와 소요: 노드→Nexus(5001/12000), Harbor 파드→Nexus, 러너→Harbor 443, 사용자→Harbor 443 | A-2 도달 테스트가 실패한 구간의 해결 경로 |
| **[운영]** 사이트 간 대역폭·지연 | 복제·전수 이관 시간. 랩 수치는 로컬 값이라 못 쓴다 |

### B-2. AD / DNS 담당

| 질문 | 왜 |
|---|---|
| Nexus A 레코드가 정적 레코드인가 DHCP 가 등록한 동적 레코드인가 | 동적이면 스캐빈징으로 지워질 수 있다 |
| 레코드 TTL 을 5분 정도로 낮출 수 있나, 레코드 생성·변경 권한과 절차 | VIP 전환·비상 변경 시 영향 시간 |
| Harbor 도메인(필요하면 와일드카드) 생성 | 노드 `hosts.toml` 디렉터리 이름 = 도메인 |

### B-3. 보안 / PKI

| 질문 | 왜 |
|---|---|
| 내부 CA 발급 절차·소요·SAN 에 IP 포함 가능 여부·갱신 주기 | Harbor TLS. 노드·Nexus·CI 모두에 체인 배포 필요 |
| Harbor 인증 방식(LDAP/OIDC/로컬)과 그룹→프로젝트 매핑 규칙 | 로봇 계정·권한 설계 |
| 비밀값 보관처(Vault 등): admin 비밀번호·로봇 토큰·DB 비밀번호 | 차트 값에는 `existingSecret` 참조만 |
| 취약점 스캔 의무, Trivy DB 반입 경로·주기 | 폐쇄망 Trivy 는 DB 를 반입해 Harbor 에 올림 |
| 이미지 서명(cosign 등) 요구 여부 | 복제 시 서명 동반 여부 |
| 감사 로그·접근 로그 보관 요건 | Harbor 감사 로그 보존, request 로그 수집 |
| **[운영]** 변경 승인 절차와 작업 창 | 노드 라우팅·DNS·Nexus DENY 전환 모두 승인 대상 |

### B-4. 스토리지팀

| 질문 | 왜 |
|---|---|
| CSI 백엔드 여유 용량과 증설 절차 | A-4 blobstore 크기 + 증가량으로 산정한 값을 받을 수 있나 |
| RWX 를 정책상 줘도 되나 (A-3 에서 기술적으로 됐더라도) | registry 레플리카 |
| 스냅샷·백업 서비스 제공 여부와 복구 절차 | CNPG 백업 + registry 백업 짝 맞추기 |
| S3 호환 오브젝트 스토리지(MinIO 등) 유무 | 있으면 registry 백엔드와 CNPG WAL 아카이브 둘 다 해결 |
| IOPS·처리량 상한 | 전수 이관·동시 pull 병목 |
| 기존 PostgreSQL 운영 조직이 있나, 외부 DB 를 써야 하나 | CNPG 자체 운영 vs `database.external` |

### B-5. 서버·자산 / 반입

| 질문 | 왜 |
|---|---|
| 7·8번 자산 분류를 "운영 Nexus" 로 변경 | 장부가 "미사용 개발" 이면 재설치 위험 |
| **[운영]** Harbor 전용 노드 확보 가능 여부와 스펙 | 랩은 PVC 가 컨트롤플레인에 묶였다 |
| 폐쇄망 반입 절차: 매체, 검사, 소요일, 반입 목록 형식 | Harbor 이미지 8종 + exporter + Trivy DB + 테스트 이미지 |
| 내부 NTP 소스 | A-1 에서 동기화가 안 돼 있으면 |

### B-6. 클러스터 구축자 / 플랫폼

| 질문 | 왜 |
|---|---|
| 노드 설정을 무엇으로 관리하나(Ansible·수동·이미지 베이크), `/etc/containerd/certs.d` 를 우리가 넣어도 되나 | 노드 라우팅은 파일 배포가 전부. 경로 없으면 DaemonSet |
| Cilium 값을 바꿔도 되나 (`l2announcements` 켜기는 에이전트 재시작) | A-2 에서 꺼져 있을 때 |
| 1~6번을 운영 클러스터로 재구축하거나 네트워크를 바꿀 계획이 있나 | 있으면 Nexus 쪽 영향 분리를 고려 |
| 개발 Harbor 를 운영 Harbor 의 복제 원본으로 쓸 것인가(승격 경로) | Harbor→Harbor 복제 설계 |
| 롤백 결정권자와 기준 | 노드 라우팅=파일 삭제, DNS=레코드 복귀, Nexus=ALLOW 복귀 |

### B-7. Nexus 운영자 / 사용 팀

| 질문 | 왜 |
|---|---|
| 전 저장소 read 가 가능한 이관 계정 발급 | 전수 이관·대조 스크립트 |
| 이관 기간 동안 정리 정책·태스크 중지 허용 | A-4 에서 태스크가 있을 때 |
| 고전 helm 저장소를 쓰는 팀·CI 목록 | `oci://` 전환 대상 |
| CI 러너의 push 자격증명 관리 방식과 담당 | 컷오버에서 손이 가장 많이 가는 부분 |
| 이미지 네이밍·프로젝트 경계 합의, 공개 프로젝트 허용 여부 | 이관 스크립트의 매핑 규칙 |
| **[운영]** 컷오버 때 읽기 전용 허용 시간 | Nexus DENY → 델타 이관 → 대조 → 전환 |
| **[운영]** RPO/RTO, 알림 채널, 당직 | 백업 주기와 프로브 경보 설계 |

---

## C. 랩에서 못 재서 운영 값으로만 확인되는 것

- Nexus "Usage nearing limits" 가 켜지는 서버 측 임계(75% 추정).
- 실제 CSI 의 PVC 사용량 지표 노출 여부, RWX 성능.
- 사이트 간 복제 처리량.
- LDAP 그룹 매핑, 하드웨어 LB·BGP 연동.
