# 구축 중 막힌 지점과 원인을 좁힌 과정

해법만이 아니라 어떻게 원인을 좁혔는지를 남긴다. 실서버에서도 같은 증상이 나올 수 있는 것은 [실서버 영향] 으로 표시.

## 1. Kubespray 가 `system_packages` 직후 로그 없이 멈춤 [실서버 영향]

- 증상: `Gather OS information` 뒤로 5분 넘게 출력 없음. 두 번 재현.
- 처음 의심: macOS 컨트롤러의 fork 안전성 문제(ansible 알려진 이슈) → `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` 를 넣었지만 같은 지점에서 다시 멈춤 → 원인 아님(설정은 macOS 컨트롤러용으로 유지).
- 좁히기: 컨트롤러의 ssh 자식 프로세스는 살아 있음 → 원격에서 무엇이 도는지 확인 → 노드마다 `/usr/lib/apt/methods/http` 가 수 분째 실행 중. 로그에 다음 작업 이름이 안 찍힌 건 앞선 작업들이 skip 이라 출력이 없었기 때문이고, 실제로는 apt 캐시 갱신에서 멈춘 것.
- 원인 1: 노드가 인터넷에 못 나감 (2절).
- 원인 2: 프록시를 넣은 뒤에도 `apt-daily` 타이머가 프록시 없이 apt 를 돌려 잠금을 쥐고 멈춤. `pkill -f apt` 는 자기 셸까지 죽여서(명령줄에 apt 포함) `pkill -x http` 로, 남은 부모(Ansible 원격 모듈)까지 정리.
- 조치: `preflight.yml` 이 설치 전에 apt-daily·unattended-upgrades(RHEL 은 dnf-automatic)를 끈다. 실서버도 설치 중 자동 업데이트가 패키지 잠금을 잡으면 똑같이 멈춘다.

## 2. 랩 VM 이 인터넷에 못 나감 (랩 전용)

- 증상: 노드에서 `curl ports.ubuntu.com` 타임아웃, DNS(192.168.149.2) 실패.
- 좁히기: 노드 기본 게이트웨이 192.168.149.2 의 ARP 가 `INCOMPLETE` → Mac 에 `vmnet-natd` 프로세스 없음(dhcpd 만 실행). `nat.conf` 는 정상, 바이너리도 있음. macOS 브리지 주소(.1)를 게이트웨이로 바꿔도 안 됨(IP forwarding 0). `vmnet-cli --status` 는 root 필요.
- 조치: sudo 없이 가능한 우회로 Mac host-only 주소(172.16.141.1:3128)에 HTTP 프록시(proxy.py)를 띄우고 Kubespray `http_proxy`/`https_proxy`/`additional_no_proxy` 로 설치. 사내 프록시 망 설치와 같은 경로라 그 검증을 겸한다.
- 근본 해결(사용자 sudo): `sudo vmnet-cli --stop && sudo vmnet-cli --start`.

## 3. `kube_owner is set to 'kube', but cilium requires it to be 'root'` [실서버 영향]

- Kubespray 기본값과 샘플 인벤토리 모두 `kube_owner: kube`. Cilium 을 쓰면 직접 `root` 로 바꿔야 한다. 사전검사(assert)라 노드 변경 전에 멈춤.

## 4. `'kube_proxy_strict_arp' is undefined` [실서버 영향]

- kube-vip + kube-proxy 제거 조합에서 kube-vip 사전검사 조건식이 이 변수를 읽는데 role 기본값이 없다(샘플 인벤토리에만 있음). 샘플을 통째로 복사하지 않고 필요한 값만 쓰는 인벤토리에서 걸린다. `kube_proxy_strict_arp: false` 명시.
- 교훈: Kubespray 인벤토리는 샘플(`inventory/sample/group_vars`)을 복사한 뒤 바꾸는 방식이 안전하다. 이 랩은 바꾼 값만 보이게 하려고 덮어쓰기 파일만 두었고, 그 대가로 위 두 건을 만났다.

## 5. etcd `--version` 실패 (무시됨, 정상)

- 최초 설치 시 etcd 바이너리가 아직 없어서 버전 확인이 실패하고 `...ignoring` 처리된다. 실패 아님.

## 6. CNPG 설치 중 helm `unexpected EOF`, API VIP 가 다른 control plane 으로 이동 [실서버 영향: CP 메모리]

- 증상: CNPG operator helm 설치가 VIP(.30) 경유로 끊김. 직후 VIP 보유 노드가 cp1 → cp2 로 바뀜.
- 좁히기: `kubectl top`/`describe node` 에서 CP 메모리 요청·사용이 할당 가능량의 137~150%. cp1 의 kube-vip 컨테이너가 재시작돼 리더 lease 를 놓쳤고, 그 순간 VIP 로 가던 연결이 끊긴 것.
- 조치: CP 메모리 1792 → 2560MB (Vagrantfile `CP_MEM`), 한 대씩 재기동. 실서버 CP 는 etcd+apiserver+Cilium operator+kube-vip 를 감안해 최소 4GB 를 권장.

## 7. Mac 디스크 가득 참(ENOSPC) → 모든 명령 중단 (랩 전용)

- 증상: Claude/vagrant/vmrun/brew 모두 임시 파일을 못 만들어 시작조차 안 됨. 여유 116MB.
- 좁히기: VM 프로세스를 강제 종료해도 여유가 1MB 만 늘었다 → 이 Mac(Fusion)은 VM 메모리를 디스크 파일로 두지 않는다(VM 폴더에 .vmem 없음). 공간을 먹은 건 VM 디스크(이 랩 11대 합계 56GB, 대당 5~6GB)와 다른 앱 데이터.
- 조치: 앱 캐시·빌드 산출물·안 쓰는 앱 데이터 정리로 54GB 확보. **랩 시작 전 여유 공간 80GB 이상** 권장(VM 디스크 ~56GB + Harbor 이미지 push 여유).

## 8. Mac 메모리·스왑 압박: 원인은 VM 이 아니라 Docker Desktop VM 이었다 (랩 전용)

- 증상: 스왑 10GB, 활동 모니터에서 VS Code 가 37GB 처럼 보임.
- 좁히기: VS Code 프로세스 실제 상주는 약 3GB. `top -o mem` 상위는 `com.apple.Virtualization`(Docker Desktop VM, 상주 8.2GB + 압축 11GB)과 랩 vmware-vmx(대당 표시 3.3~4GB, 설정 1920~2560MB). Docker 데몬은 응답하지 않는 상태였다.
- 확인: Docker Desktop 종료 후 랩 11대를 모두 켜도 `memory_pressure` 여유 56~59%, 스왑 증가 없음. vmware-vmx 의 표시 메모리는 실제 압박보다 크게 잡힌다(32GB Mac 에서 표시 합계 ~35GB 인데 여유 59%).
- 교훈: 32GB Mac 에서 이 랩(설정 합계 ~21GB)을 돌릴 땐 Docker Desktop·podman machine 등 다른 VM 을 끈다.

## 9. CNPG primary 파드 삭제 시 승격이 173초 걸림 [실서버 영향]

- 증상: 장애 시험 B 에서 새 primary 까지 173s.
- 좁히기: operator 로그가 `Waiting for all WAL receivers to be down to elect a new primary` 를 3분 가까이 반복. 삭제된 primary 가 종료 중에도 WAL 을 계속 보내고 있었다는 뜻. CRD 설명: `smartShutdownTimeout` = smart shutdown(클라이언트 접속 종료 대기) 시간, **기본 180초** → 측정치와 일치.
- 조치: `smartShutdownTimeout: 15` (변수 `cnpg_smart_shutdown_timeout`). 재측정: 새 primary 21s, Harbor DB 조회 복구 24s.
- 범위: 파드 삭제·drain·롤링 업데이트 같은 **계획된 종료**에만 해당. 노드가 갑자기 죽으면 이 대기는 없다.
- 남은 관찰: 지운 인스턴스는 36s 에 WAL 스트리밍 재개, 44s 에 파드 Ready 였는데 Cluster `readyInstances=3` 은 326s 후에 반영. operator 로그는 `Cannot extract Pod status` → 약 4분 반 뒤 `Setting replica label`. 원인 미확인. 복구 판정은 Cluster 상태값보다 `pg_stat_replication` 이나 파드 Ready 를 같이 본다.

## 10. 노드 재기동 판정이 0~1초로 찍힘 (스크립트 버그, 수정함)

- 증상: rolling-reload 의 cp1, 장애 시험 A 의 cp2 가 "Ready 복귀 0s".
- 원인: 노드가 꺼져 있던 시간이 node-monitor grace(40s)보다 짧아 NotReady 로 바뀌지 않았고, 스크립트는 Ready 표시만 봤다.
- 조치: 기동 명령 시각 이후에 kubelet 이 `kube-node-lease` 의 lease 를 갱신했는지까지 확인(`40-failover.sh` 의 `node_back`, `rolling-reload.sh` 의 `renewed_after`).

## 11. 워커 정지 후 registry 파드 이동에 395초 [실서버 영향, 기본 동작]

- 측정: 워커 정지 → 다른 노드에서 registry Running 395s, 그 뒤 기존 이미지 pull 8s. Longhorn 볼륨은 복제본이 있던 노드로 재부착(healthy 유지).
- 원인: 쿠버네티스 기본값. 노드 NotReady 판정(~40s) 후 파드의 `node.kubernetes.io/unreachable` toleration **300s** 를 기다린 뒤에야 축출. Longhorn `nodeDownPodDeletionPolicy` 는 그 뒤 Terminating 에 걸린 파드를 정리해 주는 역할.
- 줄이려면: Harbor 파드에 `tolerationSeconds` 를 짧게(예 30~60s) 주거나 apiserver `--default-unreachable-toleration-seconds` 조정. 짧은 네트워크 단절에도 파드가 옮겨지는 대가가 있어 이 랩은 기본값 유지.

## 12. Kubespray reset 의 `ipvsadm -C` 실패 (무시됨, 정상)

- `reset.yml` 이 노드마다 `fatal: ... ipvsadm -C rc=2` 를 찍지만 `...ignoring` 처리되고 PLAY RECAP 은 failed=0 이다. kube-proxy 를 빼고 Cilium 으로 대체한 구성이라 IPVS 테이블이 없어서 생기는 것.

## 13. `reset.sh apps` 가 없는 로컬 매니페스트를 지우려 함 (스크립트 버그, 수정함)

- 매니페스트는 addons.yml 이 첫 control plane 안에서 렌더링하는데, reset.sh 는 배포 호스트의 `manifests/` 를 `kubectl delete -f` 하고 있었다. 실행 전 코드 검토에서 발견. 이름으로 지우게 바꿨다(`service harbor-bgp`, `ciliuml2announcementpolicy lab-l2`).

## 14. 워커 1대 정지로 Harbor 전체가 9분 넘게 멈춤: Harbor 파드가 한 노드에 몰림 [실서버 영향]

- 증상: VM 부터 새로 설치한 클러스터에서 장애 시험 C 의 pull 이 실패. registry 는 416s 에 다른 노드에서 Running 이었는데 pull 이 안 됨.
- 좁히기: 이벤트에 `TaintManagerEviction` 이 registry 외에 core·nginx·jobservice·redis 에도 찍힘 → 이번 설치에서는 Harbor 파드 5개가 정지한 ks-w3 한 노드에 있었다. Redis·jobservice 도 Longhorn 볼륨 재부착을 기다려야 해서 core 가 가장 늦게(정지 후 9분 18초) Ready. 첫 설치 때는 파드가 흩어져 있어 registry 만 옮겨 가면 됐다.
- 결론: Harbor 차트 기본값에는 컴포넌트 간 분산 규칙이 없고 각 1개라, 스케줄러가 한 노드에 몰아도 막지 않는다. 장애 영향이 설치마다 달라진다.
- 실서버 권장: core·portal·nginx·registry 는 replicas 2 이상 + `topologySpreadConstraints`(hostname). registry 를 2개 이상으로 하려면 RWX 스토리지나 S3 호환 저장소가 필요하다(Longhorn RWO 볼륨은 1개 노드에만 붙는다). Redis 는 외부 HA Redis(Sentinel) 로.
- 시험 스크립트: registry 가 떠도 Harbor 전체가 healthy 가 될 때까지 기다린 뒤 pull 하도록 고쳤다. 같은 노드에 있던 다른 Harbor 파드도 출력한다.

## 15. CP 1대 정지 17초 뒤 쓰기 1회 실패 `keepalive ping failed to receive ACK` (일시적)

- 장애 시험 A 를 네 번 돌려 한 번 나왔다. 오류는 apiserver → etcd gRPC 연결이 죽은 멤버에 붙어 있다가 keepalive 시간 초과로 끊긴 것(`rpc error: code = Unavailable`). 같은 상태에서 다시 돌렸을 땐 첫 시도에 성공해 재현되지 않았다.
- 판단: etcd 쿼럼(2/3)은 유지됐고, apiserver 의 etcd 클라이언트가 살아 있는 멤버로 옮겨 가는 사이의 일시 오류. 컨트롤러·kubectl·CI 처럼 API 를 쓰는 쪽은 재시도해야 한다.
- 시험 스크립트: 쓰기를 90초까지 재시도하고 첫 시도 성공 여부를 출력하게 바꿨다.
