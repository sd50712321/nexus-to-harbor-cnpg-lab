# 인프라 요구사항: 스위치 · BGP · 방화벽 · 주소 · VM

Kubespray + Cilium 클러스터(control plane 3, worker 5)와 ingress-nginx · Longhorn · CNPG · Harbor 를 실서버에 올릴 때 네트워크팀·보안팀·가상화 담당자에게 요청할 것을 모았다. 노드가 VM 일 때 따로 볼 것은 6절이다. 값은 자리표시자다. 포트는 공식 문서 기준이다(맨 아래 근거).

## 1. 주소 계획 — 네트워크팀에 받을 값

| 항목 | 크기 | 조건 | 인벤토리 변수 |
|---|---|---|---|
| 노드 서브넷 | 노드 8대(CP 3 + 워커 5) + 여유 | 고정 IP. DHCP 라면 예약 또는 범위 제외 | `ip=` (inventory.ini) |
| API VIP | IP 1개 | 노드 서브넷 안, **DHCP 범위 밖, IPAM 에 예약 등록** | `apiserver_vip` |
| L2 LB 풀 | IP 몇 개(/28 정도) | 노드 서브넷 안, DHCP 범위 밖, IPAM 예약 | `l2_pool_start`, `l2_pool_stop`, `ingress_vip` |
| ingress VIP | IP 1개 | L2 풀 안. **밖에서 들어오는 HTTP(S) 는 전부 이 주소 하나**로 받는다(ingress-nginx). 서비스가 늘어도 VIP 는 그대로, 호스트명만 는다 | `ingress_vip` |
| Harbor 호스트명 | DNS A 레코드 1개 | 이름 → ingress VIP. 사용자·CI·**전 노드**가 풀 수 있어야 한다 | `harbor_host` |
| Harbor 인증서 | 그 호스트명의 서버 인증서 + 키 | 사내 CA 발급. 노드와 CI 가 그 CA 를 신뢰해야 pull 이 된다 | `templates/harbor-values.yaml.j2` 의 `certSource` |
| BGP VIP 대역 | /24~/27 | 노드 서브넷 **밖**, 사내 어디와도 겹치지 않는 대역 | `bgp_pool_cidr`, `harbor_bgp_vip`(ingress-nginx 앞에 붙는다) |
| 노드 ASN / 스위치 ASN | 사설 ASN 2개 | 사내 BGP 설계와 충돌 없는 값 | `bgp_local_asn`, `bgp_peer_asn` |
| 스위치 피어 IP | IP 1개(또는 ToR 이중화면 2개) | 노드 서브넷의 게이트웨이/SVI | `bgp_peer_address` |
| 파드 대역 / 서비스 대역 | /18 씩 (기본 10.233.64.0/18, 10.233.0.0/18) | **사내망과 겹치면 안 됨**. 겹치면 그 대역으로 가는 사내 트래픽이 노드에서 클러스터로 빨려 들어간다 | `kube_pods_subnet`, `kube_service_addresses` |

파드·서비스 대역은 노드 밖으로 라우팅되지 않는다(VXLAN 캡슐화, SNAT). 그래서 방화벽 규칙에는 노드 IP 와 VIP 만 등장한다.

네트워크팀 요청용 문안 (복사해서 메일·티켓에 붙여넣는다):

```text
[요청] Kubernetes 클러스터(노드 8대) 구축용 주소·네트워크 할당

1. 노드 서브넷/VLAN       : 노드 8대 + 여유, 고정 IP (DHCP 사용 시 예약 또는 범위 제외)
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
9. DNS 레코드           : <Harbor 호스트명> → L2 LB 풀에서 고른 IP 1개(ingress VIP)
10. 서버 인증서          : <Harbor 호스트명> 용, 사내 CA 발급 (인증서 + 키)
```

받은 값은 `inventory/prod/group_vars/all/env.yml` 에 넣는다.

```yaml
node_iface: <클러스터 NIC, 예 bond1>
cilium_node_devices: [<클러스터 NIC>]
apiserver_vip: <API VIP>
ingress_vip: <L2 풀 안의 IP>
harbor_expose: ingress
harbor_host: <Harbor 호스트명>
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
| 노드 8대를 같은 VLAN(같은 L2 도메인)에 | kube-vip(API VIP)와 Cilium L2 공지는 ARP 로 VIP 를 광고한다. 다른 VLAN 의 노드는 VIP 를 넘겨받을 수 없다 |
| 노드 포트에서 **자기 IP 가 아닌 VIP 의 ARP/GARP 응답 허용** | port-security, Dynamic ARP Inspection, IP Source Guard 가 켜져 있으면 VIP 응답이 버려진다. 해당 VIP 들을 예외로 등록 |
| **VIP 의 MAC 이동 허용** (장애 시 다른 노드가 같은 IP 를 광고) | MAC flapping 보호·ARP 캐시 고정이 있으면 장애 전환이 실패한다. 스위치 ARP 타임아웃이 길면 GARP 수신 여부 확인 |
| MTU 확인 | VXLAN 은 50바이트를 더 쓴다. 물리 MTU 1500 이면 Cilium 이 1450 으로 자동 조정(정상). 점보프레임을 쓰면 경로 전체가 같아야 한다 |
| (물리 서버만) bond(LACP) 를 쓰면 스위치 포트채널 설정 일치 | 노드가 `802.3ad` 인데 스위치에 포트채널이 없으면 링크가 반쪽만 동작 |
| 서비스용 NIC 이 여러 개면 어느 NIC 이 클러스터망인지 확정 | `node_iface`(kube-vip·L2 공지), `cilium_node_devices`(NodePort/LB 처리) 값 |

L2 방식은 VIP 하나당 노드 한 대가 응답한다(장애 시 이동, 부하분산 아님). 트래픽이 많은 VIP 는 BGP 방식으로.

## 3. BGP (L3)

워커 5대의 Cilium 이 ToR 스위치와 eBGP 를 맺고, LoadBalancer 서비스의 VIP 를 /32 경로로 광고한다. 스위치는 같은 /32 를 여러 노드에서 받아 ECMP 로 분산한다.

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

랩 ToR(FRR, 리눅스)에서 확인한 명령. 피어 5개(워커 수) Established, VIP 경로의 `nexthop` 이 워커 수만큼이면 정상이다. 실장비는 같은 의미의 장비 명령으로 본다.

```bash
sudo vtysh -c 'show bgp ipv4 unicast summary'
ip route show <harbor_bgp_vip>
```

주의:
- **상태 기반 방화벽과 ECMP**: 클라이언트와 VIP 사이에 상태 기반 방화벽이 있고 왕복 경로가 다른 노드를 지나면 세션이 끊길 수 있다. `externalTrafficPolicy: Cluster`(기본)는 노드에서 SNAT 하므로 응답이 같은 노드로 돌아와 안전하다. `Local` 로 바꿀 때 재검토.
- **클라이언트 IP**: `Cluster` 에서는 ingress-nginx 와 Harbor 로그에 클라이언트가 아니라 노드 주소가 찍힌다. VIP 를 알리는 노드에 컨트롤러 파드가 없어도 되는 것도 같은 이유다(받은 노드가 컨트롤러가 있는 노드로 넘긴다). 클라이언트 IP 가 필요하면 `Local` 로 바꾸는데, 그때는 컨트롤러 파드가 있는 노드만 VIP 를 알려야 한다(이 랩에서는 재지 않았다).
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
| TCP 443, 80 | 사용자·CI 러너·**전 노드** → ingress VIP (L2, BGP) | Harbor 이미지 push/pull 과 그 밖의 Ingress 전부. 노드도 pull 하므로 출발지에 노드 서브넷 포함. 80 은 443 으로 넘기기만 한다(308) |
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
사용자, CI 러너, 전 노드	ingress VIP (L2, BGP)	TCP	80, 443	Harbor 이미지 push/pull, 그 밖의 Ingress
워커 5대	ToR 스위치	TCP	179	BGP
사용자망	L2 LB 풀, BGP VIP 대역	TCP	서비스 포트	서비스 접근
전 노드	사내 DNS	TCP/UDP	53	이름 해석
전 노드	사내 NTP	UDP	123	시간 동기화
```

### 4-3. 설치 시 외부 접속 (인터넷이 되는 경우)

| 대상 | 용도 |
|---|---|
| `dl.k8s.io`, `github.com`(릴리스 다운로드, 리다이렉트로 `*.githubusercontent.com`), `get.helm.sh`, `storage.googleapis.com` | Kubespray 바이너리 (kubeadm, kubelet, etcd, cilium CLI, helm …) |
| `registry.k8s.io`, `quay.io`, `ghcr.io`, `docker.io`(`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) | 컨테이너 이미지 |
| `kubernetes.github.io`(ingress-nginx), `charts.longhorn.io`, `cloudnative-pg.github.io`, `helm.goharbor.io` | Helm 차트 |
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
- **Harbor 인증서**: TLS 는 ingress-nginx 에서 끝난다. 랩은 차트가 만든 자체 서명 인증서(`certSource: auto`)라 클라이언트가 검증을 끈다. 실서버는 사내 CA 인증서를 Secret 으로 넣고(`certSource: secret`), 노드 containerd 와 CI 가 그 CA 를 신뢰하게 한다. 노드가 이 호스트명으로 pull 하는 것은 이 랩에서 재지 않았다.
- **Ingress 의 요청 본문 크기**: ingress-nginx 기본값은 1m 이라 이미지 레이어 push 가 413 으로 거절된다. Harbor 차트는 Ingress 에 `proxy-body-size: "0"`(제한 없음)을 넣는다. 사내 정책으로 컨트롤러 전체에 상한을 걸면 Harbor Ingress 는 예외로 둔다(랩에서 1m 로 줄여 413 을 확인).
- **Harbor 전용 VIP 를 따로 두려면** `harbor_expose: loadBalancer` + `harbor_vip`. 이때는 ingress-nginx 를 거치지 않는다.

## 6. 노드가 VM 일 때

실서버 노드는 VM 이다. 이 랩의 노드 8대도 VM(VMware Fusion)이라 일부는 랩에서 직접 봤다. 회사 가상화 플랫폼의 종류와 설정은 보지 못했으므로, 플랫폼에 달린 항목은 단정하지 않고 가상화 담당자에게 물을 질문으로 적는다.

근거 표시: **[랩]** 이 랩에서 잰 것(운영 수치가 아니다) · **[문서]** 공식 문서(맨 아래 근거) · **[확인]** 회사 플랫폼에서 확인해야 하는 것.

### 6-1. 템플릿에서 복제한 VM 의 식별자

| 항목 | 내용 | 근거 |
|---|---|---|
| hostname · MAC · product_uuid | 노드마다 달라야 한다. kubeadm 설치 조건이고, 문서가 "일부 VM 은 값이 같을 수 있다" 고 적는다 | [문서] kubeadm 설치 |
| machine-id | 복제 후 다시 만들어졌는지. 같은 값이면 DHCP 임대·systemd 식별이 겹친다 | [랩] 8대 모두 다름 |
| iSCSI initiator 이름 | 템플릿에 open-iscsi 가 들어 있으면 복제본이 전부 같은 이름을 갖는다. **랩의 8대가 전부 같은 이름이었다**(Vagrant 박스 이미지에서 온 값). Longhorn 은 그 상태로 설치·장애 시험이 모두 됐다(각 노드가 자기 노드 안의 타깃에만 붙는다). 사내 iSCSI 스토리지를 같은 노드에 붙이면 스토리지 쪽에서 노드가 구분되지 않는다 | [랩] TROUBLESHOOTING 26절 |
| swap | kubelet 은 기본값에서 swap 이 있으면 뜨지 않는다. Kubespray 가 끄지만, 템플릿의 `/etc/fstab`·swapfile 이 재부팅 때 되살리지 않는지 본다 | [문서] kubeadm 설치 · [랩] swap 0 |
| open-iscsi 버전 | Longhorn 1.13 문서가 **open-iscsi 2.1.12 를 쓰지 말라**고 적는다(볼륨 부착 실패). 템플릿 OS 의 패키지 버전을 확인한다 | [문서] Longhorn 설치 · [랩] Ubuntu 24.04 는 2.1.9 |
| 노드 IP | 고정. 복제 후 DHCP 로 받은 주소가 바뀌면 etcd·인증서가 깨진다(5절) | — |

`preflight.yml` 이 설치 전에 본다: machine-id · product_uuid · 클러스터 NIC 의 MAC 이 겹치면 **중단**, iSCSI initiator 이름이 겹치거나 swap 이 켜져 있으면 **경고**, 그리고 노드별 가상화 종류·메모리·vCPU 를 출력한다. 랩에서 돌린 결과는 식별자 통과, initiator 이름 "1종 / 8대" 경고였다.

initiator 이름을 노드마다 새로 만드는 명령(Longhorn 설치 문서의 RHEL 절차에 있는 것과 같다). 볼륨이 붙어 있지 않은 설치 전에 한다:

```bash
echo "InitiatorName=$(/sbin/iscsi-iname)" | sudo tee /etc/iscsi/initiatorname.iscsi
sudo systemctl restart iscsid
```

### 6-2. 가상 스위치가 VIP 를 통과시키는가

API VIP(kube-vip)와 ingress VIP(Cilium L2 공지)는 **그 VM 에 배정되지 않은 IP** 를 ARP 로 광고한다. 장애가 나면 같은 IP 를 다른 VM 이 광고한다.

- [랩] VIP 의 ARP 응답에 실리는 MAC 은 그 순간 VIP 를 가진 노드 NIC 의 MAC 그대로다(ingress VIP → `ks-w5` 의 MAC, API VIP → `ks-cp3` 의 MAC). 가짜 MAC 을 쓰지 않으므로 필요한 것은 "MAC 위조 허용" 이 아니라 "**배정되지 않은 IP 의 허용**" 이다.
- [랩] VMware Fusion 의 host-only 망에는 이런 필터가 없어 그대로 동작했고, VIP 를 가진 노드를 끄면 다른 노드로 넘어갔다(README 시험 L). 필터가 있는 플랫폼에서는 재지 않았다.
- [확인] VM 포트에 등록된 IP·MAC 외의 트래픽을 막는 기능(IP 스푸핑 방지, ARP 검사, 허용 주소 목록 같은 것)이 켜져 있는가. 켜져 있으면 API VIP 와 L2 풀 전체를 CP 3대·워커 5대의 포트에 허용 주소로 넣어 달라고 한다. 2절의 물리 스위치 요청과 같은 내용을 가상 스위치에도 하는 것이다.
- 증상으로 구별: VIP 가 **같은 노드 안에서는 되고 다른 장비에서는 안 되면** 이 필터를 먼저 의심한다. `kubectl -n kube-system get lease | grep l2announce` 로 VIP 를 가진 노드를 찾고, 다른 장비에서 `arp -n <VIP>` 에 그 노드의 MAC 이 보이는지 본다.

### 6-3. 오버레이 위의 오버레이, MTU

- [랩] 노드 NIC MTU 1500, 파드 대역 경로 MTU 1450(Cilium 이 VXLAN 50바이트를 뺌), 노드 간 터널은 UDP 8472.
- [문서] VXLAN 모드에서는 모든 노드 사이에 UDP 8472 가 열려 있어야 한다(4-1 표).
- [확인] 가상 네트워크가 자체 오버레이(VXLAN·Geneve)를 쓰면 VM 에 보이는 MTU 가 1500 이어도 실제로 1500 바이트가 통과하는지 재 본다. 노드끼리 `ping -M do -s 1472 <다른 노드 IP>` 가 되면 1500 이 통과하는 것이다.
- [확인] 같은 서브넷의 VM 끼리도 막는 분산 방화벽·보안 그룹이 있으면 4-1 표 전체가 그 규칙에 들어가야 한다. 물리 방화벽만 열어서는 안 된다.
- 증상으로 구별: 작은 요청(로그인, 매니페스트)은 되는데 **큰 전송(이미지 레이어)만 멈추면** MTU 를 먼저 본다.

### 6-4. BGP

VM 은 물리 ToR 스위치와 직접 피어링할 수 없는 경우가 많다(가상 네트워크의 라우터가 사이에 있다). [확인] 피어링이 가능한지, 가능하면 상대 주소와 ASN 은 무엇인지. 안 되면 견본 기본값(`bgp_enabled: false`)대로 L2 만 쓴다. 밖에서 들어오는 주소가 ingress VIP 하나인 구조에서는 L2 로 충분하다. 다만 L2 는 VIP 하나를 노드 한 대가 받는다(2절).

### 6-5. NIC

게스트 안에서는 bond 를 묶지 않는다(이중화는 하이퍼바이저의 업링크가 한다). `node_iface` 와 `cilium_node_devices` 에는 노드에서 `ip -br addr` 로 본 실제 NIC 이름을 넣는다(예: `ens192`, `eth0`). 이름이 노드마다 다르면 `preflight.yml` 이 중단한다. 2절의 bond(LACP) 항목은 물리 서버일 때만 해당한다.

### 6-6. VM 이 어느 물리 호스트에 놓이는가

쿠버네티스는 노드(VM) 단위로만 분산한다. etcd 3대, DB 인스턴스 3개(`podAntiAffinity: required`), Longhorn 복제본 3벌이 서로 다른 VM 에 있어도 **그 VM 들이 같은 물리 호스트에 있으면 호스트 한 대로 같이 죽는다.**

- [확인] CP 3대를 서로 다른 물리 호스트에 두는 규칙(anti-affinity)을 걸 수 있는가. 워커 5대도 최소 3개 호스트에 나뉘는가. 자동 재배치(부하 분산 이동)가 이 규칙을 지키는가.
- [랩] 랩은 8대가 Mac 한 대에 있다. 호스트에 다른 부하가 걸리자 apiserver 3개가 한꺼번에 재시작했다(TROUBLESHOOTING 24절). 물리 호스트를 나누지 않으면 VM 을 3대로 나눈 의미가 줄어든다는 것을 보여 준 사례다.
- 이 리포는 물리 호스트 정보를 노드 라벨로 넣어 분산 조건에 쓰는 것까지는 하지 않았다.

### 6-7. 자원을 나눠 쓸 때 (오버커밋)

- [확인] 이 VM 들의 메모리가 예약(reservation)돼 있는가, 벌루닝·호스트 swap 대상인가. CPU 가 얼마나 겹쳐 배정돼 있는가.
- [랩] 메모리가 빠듯했을 때 실제로 일어난 일: 워커 메모리 부족 → Longhorn 파드 퇴거 → DB standby 가 스스로 못 돌아옴(TROUBLESHOOTING 16절), 다른 작업의 패키지 점검만으로 퇴거(21절). 게스트가 받은 메모리를 호스트가 다시 가져가면 같은 경로를 탄다.
- CPU 를 제때 못 받는지는 노드에서 `top` 의 `st`(steal)로 본다. etcd 는 제때 못 돌면 리더를 다시 뽑는다. Kubespray 기본값은 heartbeat 250ms, election timeout 5000ms 로 etcd 기본값(100ms, 1000ms)보다 느슨하다(`kubespray/roles/kubespray_defaults/defaults/main/main.yml:725-726`, [문서] etcd tuning).

### 6-8. 디스크

- **etcd**: [문서] etcd 는 디스크 쓰기 지연에 민감하다. `wal_fsync_duration_seconds` 의 p99 가 10ms 아래여야 한다. 공유 데이터스토어 위의 VM 은 다른 VM 의 I/O 에 따라 달라지므로 설치 후 CP 에서 재 본다:

  ```bash
  sudo curl -s --cacert /etc/ssl/etcd/ssl/ca.pem --cert /etc/ssl/etcd/ssl/admin-$(hostname).pem --key /etc/ssl/etcd/ssl/admin-$(hostname)-key.pem \
    https://127.0.0.1:2379/metrics | grep '^etcd_disk_wal_fsync_duration_seconds_bucket'
  ```

  `le="0.008"` 줄의 값 ÷ `le="+Inf"` 줄의 값이 0.99 이상이면 p99 가 8ms 이하다. [랩] `ks-cp1` 은 585,052회 중 582,097회(99.5%)가 8ms 이하였다(Mac 내장 SSD 위의 VM).
- **Longhorn 데이터 디스크**: [랩] 랩은 루트 디스크(30GB)를 같이 쓴다. 실서버는 `/var/lib/longhorn` 에 전용 가상 디스크를 붙여 달라고 한다(루트가 차면 kubelet 이 파드를 퇴거한다). 크기는 `harbor_registry_size` × 복제 수 3 이 워커 전체에 나뉘어 들어간다고 보고 정한다.
- **복제가 두 번 된다**: 데이터스토어가 이미 이중화돼 있어도 Longhorn 은 그 위에서 3벌을 또 만든다. 줄일지는 결정할 일이다. Longhorn 복제는 "워커 VM 이 죽어도 다른 워커에서 볼륨을 붙인다" 를 맡고, 데이터스토어 이중화는 "디스크가 죽어도 VM 이 산다" 를 맡는다. 이 랩의 장애 시험은 전부 3벌에서 쟀다.
- [확인] 가상 디스크가 씬 프로비저닝이면 데이터스토어가 가득 찼을 때 VM 이 멈춘다. 데이터스토어 여유를 누가 감시하는가.

### 6-9. VM 스냅샷 · 이미지 백업 · 라이브 마이그레이션

이 작업들은 VM 을 잠깐 멈춘다. 멈춤이 아래 시간을 넘으면 클러스터는 그 노드가 죽은 것으로 처리한다(멈춘 VM 이 그 역할을 맡고 있었을 때).

| 넘으면 | 시간 | 일어나는 일 | 근거 |
|---|---|---|---|
| etcd election timeout | 5초 | 멈춘 VM 이 etcd 리더였다면 리더 재선출. 그동안 API 쓰기 지연 | Kubespray 기본값(6-7) |
| L2 공지 lease | 15초 | 멈춘 VM 이 ingress VIP 를 갖고 있었다면 다른 워커로 넘어감 | [랩] `leaseDurationSeconds` 15, 시험 L |
| node-monitor-grace-period | 40초 | 노드 NotReady, 그 노드의 파드가 엔드포인트에서 빠짐 | `kubespray/roles/kubernetes/control-plane/defaults/main/main.yml:104`, 시험 M |

- [확인] 이 VM 들에 정기 스냅샷·이미지 백업이 걸려 있는가, 걸려 있으면 멈춤이 얼마나 되는가. 라이브 마이그레이션은 언제 일어나는가.
- **되돌리기는 VM 스냅샷으로 하지 않는다.** etcd 멤버 한 대만 과거 시점으로 돌아가면 나머지 두 대와 기록이 어긋난다. DB 인스턴스도 같다. 되돌릴 일이 있으면 etcd 스냅샷과 DB 백업으로 한다. 이 클러스터에서는 etcd 스냅샷 복구와 DB 백업·복구를 재지 않았다(README "아직 시험하지 않은 것").
- 랩에서는 VM 스냅샷·라이브 마이그레이션을 시험하지 않았다(Mac 한 대라 옮길 곳이 없다). 위 표는 "노드를 끈" 시험에서 나온 시간이다.

### 6-10. 시간

VM 은 멈췄다 풀리면 시계가 어긋날 수 있다. 템플릿의 NTP 가 사내 NTP 서버를 보는지 확인한다. Kubespray 는 기본값에서 NTP 를 건드리지 않는다(`ntp_enabled: false`, `kubespray/roles/kubespray_defaults/defaults/main/main.yml:805`). `preflight.yml` 이 노드별 동기 여부를 경고로 알려 준다.

### 6-11. 가상화 담당자에게 보낼 요청문

```text
쿠버네티스 노드용 VM 8대(control plane 3, worker 5) 관련 확인·요청드립니다.

1. 배치: control plane 3대를 서로 다른 물리 호스트에 두는 규칙(anti-affinity)을 걸어 주세요.
   worker 5대도 3개 이상 호스트에 나뉘게 해 주세요. 자동 재배치가 이 규칙을 지키는지 알려 주세요.
2. 자원: 8대 모두 메모리 전량 예약(벌루닝·호스트 swap 제외)이 가능한지, CPU 오버커밋 비율이 얼마인지 알려 주세요.
3. 가상 스위치: VM 포트에 등록되지 않은 IP 의 ARP·트래픽을 막는 기능이 켜져 있는지 알려 주세요.
   켜져 있으면 아래 주소를 control plane 3대·worker 5대 포트에 허용 주소로 등록해 주세요.
     - API VIP: <apiserver_vip>            (control plane 3대)
     - 서비스 VIP 대역: <l2_pool_start> ~ <l2_pool_stop>   (worker 5대)
   장애 시 같은 IP 를 다른 VM 이 광고합니다(MAC 은 각 VM 의 실제 MAC).
4. 네트워크: VM 이 보는 MTU 와 실제 통과 MTU, 같은 서브넷 VM 사이에 적용되는 방화벽(보안 그룹) 유무를 알려 주세요.
   노드 간 UDP 8472(VXLAN) 등 첨부 포트 표 전체가 VM 사이에서 열려 있어야 합니다.
5. BGP: 이 VM 들이 상위 라우터·스위치와 BGP 피어링을 할 수 있는지 알려 주세요(안 되면 쓰지 않습니다).
6. 디스크: control plane 3대는 쓰기 지연이 낮은 데이터스토어(SSD 계층)에 두어 주세요.
   worker 5대에는 데이터용 가상 디스크를 각 <크기> 추가해 주세요(/var/lib/longhorn 에 마운트).
   씬 프로비저닝 여부와 데이터스토어 여유 감시 주체를 알려 주세요.
7. 스냅샷·백업·라이브 마이그레이션: 이 VM 들에 걸린 정책과 그때 VM 이 멈추는 시간을 알려 주세요.
   5초 이상 멈추면 etcd 리더가 바뀌고, 15초 이상이면 서비스 VIP 가 다른 노드로 넘어갑니다.
8. 템플릿: 복제 후 hostname, machine-id, MAC, product_uuid, iSCSI initiator 이름이 VM 마다 다르게 만들어지는지,
   swap 이 꺼져 있는지, NTP 가 사내 서버를 보는지 확인 부탁드립니다. NIC 이름(예: ens192)도 알려 주세요.
```

## 근거

- Kubernetes Ports and Protocols: kubernetes/website `content/en/docs/reference/networking/ports-and-protocols.md`
- Cilium 1.20.2 System Requirements → Firewall Rules: cilium/cilium `Documentation/operations/system_requirements.rst`
- Longhorn 1.13 Networking: longhorn/website `content/docs/1.13.0/references/networking.md`
- Kubespray v2.32.0 다운로드 대상: `kubespray/roles/kubespray_defaults/defaults/main/download.yml`
- kubeadm 설치 조건(hostname·MAC·product_uuid 고유, swap): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- etcd 디스크·타이밍: https://etcd.io/docs/v3.6/op-guide/hardware/ , https://etcd.io/docs/v3.6/tuning/ , https://etcd.io/docs/v3.6/faq/ (`wal_fsync_duration_seconds` p99 10ms)
- Cilium VXLAN UDP 8472: https://docs.cilium.io/en/stable/operations/system_requirements/
- Longhorn 1.13 설치 요건(open-iscsi, initiator 이름 생성 명령, 2.1.12 비호환): https://longhorn.io/docs/1.13.0/deploy/install/
