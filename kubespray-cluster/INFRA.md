# 인프라 요구사항: 스위치 · BGP · 방화벽 · 주소

Kubespray + Cilium 클러스터(control plane 3, worker 7)와 Longhorn · CNPG · Harbor 를 실서버에 올릴 때 네트워크팀·보안팀에 요청할 것을 모았다. 값은 자리표시자다. 포트는 공식 문서 기준이다(맨 아래 근거).

## 1. 주소 계획 — 네트워크팀에 받을 값

| 항목 | 크기 | 조건 | 인벤토리 변수 |
|---|---|---|---|
| 노드 서브넷 | 노드 10대 + 여유 | 고정 IP. DHCP 라면 예약 또는 범위 제외 | `ip=` (inventory.ini) |
| API VIP | IP 1개 | 노드 서브넷 안, **DHCP 범위 밖, IPAM 에 예약 등록** | `apiserver_vip` |
| L2 LB 풀 | IP 몇 개(/28 정도) | 노드 서브넷 안, DHCP 범위 밖, IPAM 예약 | `l2_pool_start`, `l2_pool_stop`, `harbor_vip` |
| BGP VIP 대역 | /24~/27 | 노드 서브넷 **밖**, 사내 어디와도 겹치지 않는 대역 | `bgp_pool_cidr`, `harbor_bgp_vip` |
| 노드 ASN / 스위치 ASN | 사설 ASN 2개 | 사내 BGP 설계와 충돌 없는 값 | `bgp_local_asn`, `bgp_peer_asn` |
| 스위치 피어 IP | IP 1개(또는 ToR 이중화면 2개) | 노드 서브넷의 게이트웨이/SVI | `bgp_peer_address` |
| 파드 대역 / 서비스 대역 | /18 씩 (기본 10.233.64.0/18, 10.233.0.0/18) | **사내망과 겹치면 안 됨**. 겹치면 그 대역으로 가는 사내 트래픽이 노드에서 클러스터로 빨려 들어간다 | `kube_pods_subnet`, `kube_service_addresses` |

파드·서비스 대역은 노드 밖으로 라우팅되지 않는다(VXLAN 캡슐화, SNAT). 그래서 방화벽 규칙에는 노드 IP 와 VIP 만 등장한다.

네트워크팀 요청용 문안 (복사해서 메일·티켓에 붙여넣는다):

```text
[요청] Kubernetes 클러스터(노드 10대) 구축용 주소·네트워크 할당

1. 노드 서브넷/VLAN       : 노드 10대 + 여유, 고정 IP (DHCP 사용 시 예약 또는 범위 제외)
2. API VIP              : IP 1개, 노드 서브넷 안, DHCP 범위 밖, IPAM 예약
3. L2 LB 풀             : IP 연속 대역(/28 정도), 노드 서브넷 안, DHCP 범위 밖, IPAM 예약
4. BGP VIP 대역          : /24~/27, 노드 서브넷 밖, 사내 어디와도 겹치지 않는 대역
5. BGP ASN              : 노드용 사설 ASN 1개, 스위치 ASN 확인
6. BGP 피어 IP           : 노드 서브넷의 게이트웨이/SVI (ToR 이중화면 2개)
7. 사용 불가 대역 확인     : 아래 두 대역이 사내망과 겹치는지
                          - 파드 대역   10.233.64.0/18
                          - 서비스 대역 10.233.0.0/18
                          (겹치면 다른 /18 을 지정해 주십시오)
8. 스위치 설정           : 2절(L2), 3절(BGP) 표의 항목
```

받은 값은 `inventory/prod/group_vars/all/env.yml` 에 넣는다.

```yaml
node_iface: <클러스터 NIC, 예 bond1>
cilium_node_devices: [<클러스터 NIC>]
apiserver_vip: <API VIP>
harbor_vip: <L2 풀 안의 IP>
l2_pool_start: <L2 풀 시작>
l2_pool_stop: <L2 풀 끝>
bgp_enabled: true
bgp_local_asn: <노드 ASN>
bgp_peer_asn: <스위치 ASN>
bgp_peer_address: <스위치 피어 IP>
bgp_pool_cidr: <BGP VIP 대역>
harbor_bgp_vip: <BGP VIP 대역 안의 IP>
```

## 2. 스위치 (L2)

| 요청 | 이유 |
|---|---|
| 노드 10대를 같은 VLAN(같은 L2 도메인)에 | kube-vip(API VIP)와 Cilium L2 공지는 ARP 로 VIP 를 광고한다. 다른 VLAN 의 노드는 VIP 를 넘겨받을 수 없다 |
| 노드 포트에서 **자기 IP 가 아닌 VIP 의 ARP/GARP 응답 허용** | port-security, Dynamic ARP Inspection, IP Source Guard 가 켜져 있으면 VIP 응답이 버려진다. 해당 VIP 들을 예외로 등록 |
| **VIP 의 MAC 이동 허용** (장애 시 다른 노드가 같은 IP 를 광고) | MAC flapping 보호·ARP 캐시 고정이 있으면 장애 전환이 실패한다. 스위치 ARP 타임아웃이 길면 GARP 수신 여부 확인 |
| MTU 확인 | VXLAN 은 50바이트를 더 쓴다. 물리 MTU 1500 이면 Cilium 이 1450 으로 자동 조정(정상). 점보프레임을 쓰면 경로 전체가 같아야 한다 |
| bond(LACP) 를 쓰면 스위치 포트채널 설정 일치 | 노드가 `802.3ad` 인데 스위치에 포트채널이 없으면 링크가 반쪽만 동작 |
| 서비스용 NIC 이 여러 개면 어느 NIC 이 클러스터망인지 확정 | `node_iface`(kube-vip·L2 공지), `cilium_node_devices`(NodePort/LB 처리) 값 |

L2 방식은 VIP 하나당 노드 한 대가 응답한다(장애 시 이동, 부하분산 아님). 트래픽이 많은 VIP 는 BGP 방식으로.

## 3. BGP (L3)

워커 7대의 Cilium 이 ToR 스위치와 eBGP 를 맺고, LoadBalancer 서비스의 VIP 를 /32 경로로 광고한다. 스위치는 같은 /32 를 여러 노드에서 받아 ECMP 로 분산한다.

| 요청 | 값 / 이유 |
|---|---|
| 피어링 | 스위치 AS `<peer_asn>` ↔ 노드 AS `<local_asn>`. 노드 IP 를 개별 neighbor 로 넣거나 `listen range <노드서브넷>` |
| 수신 필터 (필수) | 노드에서 받는 경로를 **BGP VIP 대역의 /32 만** 허용(`prefix-list ... ge 32`). 클러스터 설정 실수로 엉뚱한 경로가 사내망에 퍼지는 걸 막는다 |
| 송신 | 노드로는 아무 경로도 안 보내도 된다(노드는 기본 게이트웨이로 충분) |
| ECMP | `maximum-paths` 를 워커 수 이상으로 |
| 타이머 | 랩은 keepalive 3s / hold 9s(노드 다운 감지 ≈ 9초). 운영은 BFD 를 검토 |
| graceful restart | Cilium 재시작 중 경로 유지(랩 설정 restartTime 15s) |
| 상위 전파 | VIP 대역을 코어/방화벽 쪽으로 재광고할지, 정적 경로로 요약할지 네트워크팀 결정 |
| 방화벽 | 노드 ↔ 스위치 TCP 179 |

랩의 ToR 역할 FRR 설정(`tor.yml`)이 장비 설정의 견본이다. 아래는 랩에서 동작한 설정 전체에서 값만 자리표시자로 바꾼 것이다(FRR 문법. Cisco/Arista 는 문법이 비슷하지만 장비 문법으로 옮겨야 한다).

```text
router bgp <peer_asn>
 bgp router-id <스위치 IP>
 no bgp ebgp-requires-policy
 bgp bestpath as-path multipath-relax
 neighbor K8S peer-group
 neighbor K8S remote-as <local_asn>
 neighbor K8S timers 3 9
 bgp listen range <노드 서브넷> peer-group K8S
 !
 address-family ipv4 unicast
  neighbor K8S activate
  neighbor K8S soft-reconfiguration inbound
  neighbor K8S prefix-list K8S-IN in
  neighbor K8S prefix-list DENY-ALL out
  maximum-paths 16
 exit-address-family
!
ip prefix-list K8S-IN seq 10 permit <bgp_pool_cidr> ge 32
ip prefix-list DENY-ALL seq 10 deny any
```

랩 ToR(FRR, 리눅스)에서 확인한 명령. 피어 7개 Established, VIP 경로의 `nexthop` 이 워커 수만큼이면 정상이다. 실장비는 같은 의미의 장비 명령으로 본다.

```bash
sudo vtysh -c 'show bgp ipv4 unicast summary'
ip route show <harbor_bgp_vip>
```

주의:
- **상태 기반 방화벽과 ECMP**: 클라이언트와 VIP 사이에 상태 기반 방화벽이 있고 왕복 경로가 다른 노드를 지나면 세션이 끊길 수 있다. `externalTrafficPolicy: Cluster`(기본)는 노드에서 SNAT 하므로 응답이 같은 노드로 돌아와 안전하다. `Local` 로 바꿀 때 재검토.
- API VIP 는 kube-vip ARP 방식이다. 노드가 여러 VLAN 에 흩어져야 한다면 kube-vip BGP 모드로 바꾸고 같은 피어링을 쓴다.

## 4. 방화벽 포트 표

출발지 → 목적지 기준. "노드 간" 은 노드 서브넷 내부라 보통 방화벽을 안 지나지만, 노드에 firewalld/ufw 가 켜져 있으면 노드마다 열어야 한다.

### 4-1. 노드 간 (control plane CP, worker W)

| 프로토콜/포트 | 출발 → 목적 | 용도 | 근거 |
|---|---|---|---|
| TCP 6443 | 전 노드 → CP, **API VIP** | kube-apiserver | k8s |
| TCP 2379-2380 | CP ↔ CP | etcd (클라이언트·피어) | k8s |
| TCP 10250 | CP → 전 노드 | kubelet API (logs/exec) | k8s |
| TCP 10257, 10259 | 자기 자신 | controller-manager, scheduler | k8s |
| UDP 8472 | 전 노드 ↔ 전 노드 | Cilium VXLAN (파드 간 트래픽 전부가 이 안에 실린다) | Cilium |
| TCP 4240 | 전 노드 ↔ 전 노드 | cilium-health | Cilium |
| ICMP echo (type 8/0) | 전 노드 ↔ 전 노드 | cilium-health. **ICMP 를 막으면 헬스가 실패로 보인다** | Cilium |
| TCP 4244 | 전 노드 ↔ 전 노드 | Hubble (켤 때) | Cilium |
| UDP 51871 | 전 노드 ↔ 전 노드 | WireGuard 암호화 (켤 때) | Cilium |
| TCP/UDP 30000-32767 | LB·클라이언트 → 전 노드 | NodePort (쓸 때) | k8s |

kube-proxy 를 쓰지 않으므로 10256 은 필요 없다. Longhorn 의 9500-9503, 8500-8504, 10000-30000, 3260, 2049 는 **파드 간 통신**이라 VXLAN(8472) 안으로 지나간다. Cilium 을 native routing 으로 바꾸거나 NetworkPolicy 를 걸 때만 따로 연다.

노드에 firewalld/ufw 를 켜지 않는 경우(일반적) 노드마다 끈다.

```bash
sudo ufw disable                              # Ubuntu
sudo systemctl disable --now firewalld        # RHEL 계열
```

### 4-2. 클러스터 바깥 ↔ 클러스터

| 프로토콜/포트 | 출발 → 목적 | 용도 |
|---|---|---|
| TCP 22 | 배포 호스트 → 전 노드 | Ansible(Kubespray) |
| TCP 6443 | 배포 호스트·관리자·CI → API VIP | kubectl, helm |
| TCP 443 (TLS 적용 시) / 80 | 사용자·CI 러너·**전 노드** → Harbor VIP | 이미지 push/pull. 노드도 pull 하므로 출발지에 노드 서브넷 포함 |
| TCP 179 | 워커 ↔ ToR 스위치 | BGP |
| VIP 대역 (L2 풀, BGP 대역) | 사용자망 → VIP | 서비스 접근. 방화벽 객체를 "VIP 대역" 으로 만들어 두면 서비스 추가 때마다 신청하지 않아도 된다 |
| UDP/TCP 53, UDP 123 | 전 노드 → 사내 DNS / NTP | 이름 해석, 시간 동기화(etcd·인증서) |

방화벽 신청서용 (4-1·4-2 를 한 표로, 탭 구분. 복사해 엑셀에 붙여넣으면 칸이 나뉜다. 켤 때만 필요한 Hubble·WireGuard·NodePort 는 뺐다):

```text
출발지	목적지	프로토콜	포트	용도
전 노드	CP 3대, API VIP	TCP	6443	kube-apiserver
CP 3대	CP 3대	TCP	2379-2380	etcd
CP 3대	전 노드	TCP	10250	kubelet
전 노드	전 노드	UDP	8472	Cilium VXLAN
전 노드	전 노드	TCP	4240	cilium-health
전 노드	전 노드	ICMP	echo request/reply	cilium-health
배포 호스트	전 노드	TCP	22	Ansible
배포 호스트, 관리자, CI	API VIP	TCP	6443	kubectl, helm
사용자, CI 러너, 전 노드	Harbor VIP (L2, BGP)	TCP	80, 443	이미지 push/pull
워커 7대	ToR 스위치	TCP	179	BGP
사용자망	L2 LB 풀, BGP VIP 대역	TCP	서비스 포트	서비스 접근
전 노드	사내 DNS	TCP/UDP	53	이름 해석
전 노드	사내 NTP	UDP	123	시간 동기화
```

### 4-3. 설치 시 외부 접속 (인터넷이 되는 경우)

| 대상 | 용도 |
|---|---|
| `dl.k8s.io`, `github.com`(릴리스 다운로드, 리다이렉트로 `*.githubusercontent.com`), `get.helm.sh`, `storage.googleapis.com` | Kubespray 바이너리 (kubeadm, kubelet, etcd, cilium CLI, helm …) |
| `registry.k8s.io`, `quay.io`, `ghcr.io`, `docker.io`(`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) | 컨테이너 이미지 |
| `charts.longhorn.io`, `cloudnative-pg.github.io`, `helm.goharbor.io` | Helm 차트 |
| OS 패키지 미러 (Ubuntu `archive/ports.ubuntu.com`, RHEL/Rocky 미러, EPEL) | 노드 패키지 |

인터넷이 안 되면 Kubespray 오프라인 절차(`kubespray/contrib/offline`)로 바이너리·이미지를 사내 미러(Nexus/Harbor)에 올리고 `*_image_repo`, `files_repo` 를 미러로 바꾼다. HTTP 프록시만 되면 `http_proxy`/`https_proxy` 를 인벤토리에 넣는다(`inventory/prod-sample/group_vars/all/env.yml`).

## 5. 놓치기 쉬운 것

- **VIP·풀은 DHCP 범위 밖 + IPAM 예약**. DHCP 가 같은 IP 를 다른 장비에 주면 ARP 충돌로 간헐 장애가 난다.
- **노드 IP 는 바뀌면 안 된다**. etcd 멤버·인증서·kubelet 이 IP 에 묶인다.
- **firewalld/ufw**: 켜 두려면 4-1 전체를 노드마다 열어야 하고, Cilium 이 iptables 규칙을 쓰므로 충돌 여부를 확인한다. 보통은 끄고 경계 방화벽으로 통제한다.
- **SELinux**(RHEL): Kubespray 기본값은 permissive 로 바꾼다(`preinstall_selinux_state`). 보안 정책상 enforcing 이 필요하면 사전 협의.
- **시간 동기화**: NTP 가 안 되면 etcd 리더 선출과 인증서 검증이 깨진다.
- **스위치 ARP 보안 예외는 VIP 를 추가할 때마다** 필요하다. 풀 전체를 미리 예외로 등록해 두는 게 운영이 편하다.
- **장기 세션**: etcd(2379-2380), BGP(179), API watch(6443)는 오래 열린 TCP 다. 중간 방화벽의 세션 타임아웃이 짧으면 끊긴다.
- **Harbor 를 http 로 둘 경우** 노드 containerd 에 insecure 레지스트리 설정이 필요하다. 운영은 TLS(사내 CA) 권장.

## 근거

- Kubernetes Ports and Protocols: kubernetes/website `content/en/docs/reference/networking/ports-and-protocols.md`
- Cilium 1.20.2 System Requirements → Firewall Rules: cilium/cilium `Documentation/operations/system_requirements.rst`
- Longhorn 1.13 Networking: longhorn/website `content/docs/1.13.0/references/networking.md`
- Kubespray v2.32.0 다운로드 대상: `kubespray/roles/kubespray_defaults/defaults/main/download.yml`
