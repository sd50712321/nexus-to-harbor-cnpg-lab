# 구축 중 막힌 지점과 원인을 좁힌 과정

해법만이 아니라 어떻게 원인을 좁혔는지를 남긴다. 실서버에서도 같은 증상이 나올 수 있는 것은 [실서버 영향] 으로 표시.
그대로 붙여넣어 쓰는 명령·설정은 코드블럭으로 두었다. `<...>` 는 바꿔 넣을 값이다.

## 1. Kubespray 가 `system_packages` 직후 로그 없이 멈춤 [실서버 영향]

- 증상: `Gather OS information` 뒤로 5분 넘게 출력 없음. 두 번 재현.
- 처음 의심: macOS 컨트롤러의 fork 안전성 문제(ansible 알려진 이슈) → `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` 를 넣었지만 같은 지점에서 다시 멈춤 → 원인 아님(설정은 macOS 컨트롤러용으로 유지).
- 좁히기: 컨트롤러의 ssh 자식 프로세스는 살아 있음 → 원격에서 무엇이 도는지 확인 → 노드마다 `/usr/lib/apt/methods/http` 가 수 분째 실행 중. 로그에 다음 작업 이름이 안 찍힌 건 앞선 작업들이 skip 이라 출력이 없었기 때문이고, 실제로는 apt 캐시 갱신에서 멈춘 것.
- 원인 1: 노드가 인터넷에 못 나감 (2절).
- 원인 2: 프록시를 넣은 뒤에도 `apt-daily` 타이머가 프록시 없이 apt 를 돌려 잠금을 쥐고 멈춤. `pkill -f apt` 는 자기 셸까지 죽여서(명령줄에 apt 포함) `pkill -x http` 로, 남은 부모(Ansible 원격 모듈)까지 정리.
- 조치: `preflight.yml` 이 설치 전에 apt-daily·unattended-upgrades(RHEL 은 dnf-automatic)를 끈다. 실서버도 설치 중 자동 업데이트가 패키지 잠금을 잡으면 똑같이 멈춘다.

멈춘 노드에서 확인하고 푸는 명령:

```bash
ps -ef | grep -E 'apt|dpkg' | grep -v grep          # apt/methods/http 가 오래 돌고 있으면 이 증상
sudo pkill -x http                                   # pkill -f apt 는 쓰지 말 것 (자기 셸까지 죽는다)
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
```

## 2. 랩 VM 이 인터넷에 못 나감 (랩 전용)

- 증상: 노드에서 `curl ports.ubuntu.com` 타임아웃, DNS(192.168.149.2) 실패.
- 좁히기: 노드 기본 게이트웨이 192.168.149.2 의 ARP 가 `INCOMPLETE` → Mac 에 `vmnet-natd` 프로세스 없음(dhcpd 만 실행). `nat.conf` 는 정상, 바이너리도 있음. macOS 브리지 주소(.1)를 게이트웨이로 바꿔도 안 됨(IP forwarding 0). `vmnet-cli --status` 는 root 필요.
- 조치: sudo 없이 가능한 우회로 Mac host-only 주소(172.16.141.1:3128)에 HTTP 프록시(proxy.py)를 띄우고 Kubespray `http_proxy`/`https_proxy`/`additional_no_proxy` 로 설치. 사내 프록시 망 설치와 같은 경로라 그 검증을 겸한다.
- 근본 해결(사용자 sudo, Mac 에서):

```bash
sudo "/Applications/VMware Fusion.app/Contents/Library/vmnet-cli" --stop
sudo "/Applications/VMware Fusion.app/Contents/Library/vmnet-cli" --start
```

## 3. `kube_owner is set to 'kube', but cilium requires it to be 'root'` [실서버 영향]

- Kubespray 기본값과 샘플 인벤토리 모두 `kube_owner: kube`. Cilium 을 쓰면 직접 `root` 로 바꿔야 한다. 사전검사(assert)라 노드 변경 전에 멈춤.

```yaml
# inventory/<환경>/group_vars/k8s_cluster/*.yml
kube_owner: root
```

## 4. `'kube_proxy_strict_arp' is undefined` [실서버 영향]

- kube-vip + kube-proxy 제거 조합에서 kube-vip 사전검사 조건식이 이 변수를 읽는데 role 기본값이 없다(샘플 인벤토리에만 있음). 샘플을 통째로 복사하지 않고 필요한 값만 쓰는 인벤토리에서 걸린다. 명시한다.

```yaml
# inventory/<환경>/group_vars/k8s_cluster/*.yml
kube_proxy_strict_arp: false
```
- 교훈: Kubespray 인벤토리는 샘플(`inventory/sample/group_vars`)을 복사한 뒤 바꾸는 방식이 안전하다. 이 랩은 바꾼 값만 보이게 하려고 덮어쓰기 파일만 두었고, 그 대가로 위 두 건을 만났다.

## 5. etcd `--version` 실패 (무시됨, 정상)

- 최초 설치 시 etcd 바이너리가 아직 없어서 버전 확인이 실패하고 `...ignoring` 처리된다. 실패 아님.

## 6. CNPG 설치 중 helm `unexpected EOF`, API VIP 가 다른 control plane 으로 이동 [실서버 영향: CP 메모리]

- 증상: CNPG operator helm 설치가 VIP(.30) 경유로 끊김. 직후 VIP 보유 노드가 cp1 → cp2 로 바뀜.
- 좁히기: `kubectl top`/`describe node` 에서 CP 메모리 요청·사용이 할당 가능량의 137~150%. cp1 의 kube-vip 컨테이너가 재시작돼 리더 lease 를 놓쳤고, 그 순간 VIP 로 가던 연결이 끊긴 것.
- 조치: CP 메모리 1792 → 2560MB (Vagrantfile `CP_MEM`), 한 대씩 재기동. 실서버 CP 는 etcd+apiserver+Cilium operator+kube-vip 를 감안해 최소 4GB 를 권장.

확인 명령:

```bash
kubectl top nodes
kubectl describe node <cp 노드> | grep -A8 'Allocated resources'
kubectl -n kube-system get pods -o wide | grep kube-vip      # RESTARTS 가 늘면 lease 를 놓친 것
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'   # 지금 VIP 를 가진 CP
```

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

```yaml
# CNPG Cluster (templates/harbor-pg.yaml.j2)
spec:
  smartShutdownTimeout: 15
```

확인 명령 (Cluster 이름 `harbor-pg`, 네임스페이스 `harbor`):

```bash
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --since=10m | grep 'WAL receivers'
kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.currentPrimary}{"\n"}'
kubectl -n harbor get pods -l cnpg.io/cluster=harbor-pg -L cnpg.io/instanceRole -o wide
P=$(kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.currentPrimary}')
kubectl -n harbor exec $P -c postgres -- psql -Atc "select application_name, state, sync_state from pg_stat_replication"
```
- 범위: 파드 삭제·drain·롤링 업데이트 같은 **계획된 종료**에만 해당. 노드가 갑자기 죽으면 이 대기는 없다.
- 남은 관찰: 지운 인스턴스는 36s 에 WAL 스트리밍 재개, 44s 에 파드 Ready 였는데 Cluster `readyInstances=3` 은 326s 후에 반영. operator 로그는 `Cannot extract Pod status` → 약 4분 반 뒤 `Setting replica label`. 원인 미확인. 복구 판정은 Cluster 상태값보다 `pg_stat_replication` 이나 파드 Ready 를 같이 본다.

## 10. 노드 재기동 판정이 0~1초로 찍힘 (스크립트 버그, 수정함)

- 증상: rolling-reload 의 cp1, 장애 시험 A 의 cp2 가 "Ready 복귀 0s".
- 원인: 노드가 꺼져 있던 시간이 node-monitor grace(40s)보다 짧아 NotReady 로 바뀌지 않았고, 스크립트는 Ready 표시만 봤다.
- 조치: 기동 명령 시각 이후에 kubelet 이 `kube-node-lease` 의 lease 를 갱신했는지까지 확인(`40-failover.sh` 의 `node_back`, `rolling-reload.sh` 의 `renewed_after`).

## 11. 워커 정지 후 registry 파드 이동에 395초 [실서버 영향, 기본 동작]

- 측정: 워커 정지 → 다른 노드에서 registry Running 395s, 그 뒤 기존 이미지 pull 8s. Longhorn 볼륨은 복제본이 있던 노드로 재부착(healthy 유지).
- 원인: 쿠버네티스 기본값. 노드 NotReady 판정(~40s) 후 파드의 `node.kubernetes.io/unreachable` toleration **300s** 를 기다린 뒤에야 축출. Longhorn `nodeDownPodDeletionPolicy` 는 그 뒤 Terminating 에 걸린 파드를 정리해 주는 역할.
- 줄이려면: Harbor 파드에 `tolerationSeconds` 를 짧게(예 30~60s) 주거나 apiserver `--default-unreachable-toleration-seconds` 조정. 짧은 네트워크 단절에도 파드가 옮겨지는 대가가 있어 이 랩은 기본값 유지(아래는 미실측 예시).

```yaml
# Harbor values: core / registry / jobservice / portal / nginx 각각에 같은 블럭
core:
  tolerations:
    - key: node.kubernetes.io/unreachable
      operator: Exists
      effect: NoExecute
      tolerationSeconds: 60
    - key: node.kubernetes.io/not-ready
      operator: Exists
      effect: NoExecute
      tolerationSeconds: 60
```

## 12. Kubespray reset 의 `ipvsadm -C` 실패 (무시됨, 정상)

- `reset.yml` 이 노드마다 `fatal: ... ipvsadm -C rc=2` 를 찍지만 `...ignoring` 처리되고 PLAY RECAP 은 failed=0 이다. kube-proxy 를 빼고 Cilium 으로 대체한 구성이라 IPVS 테이블이 없어서 생기는 것.

## 13. `reset.sh apps` 가 없는 로컬 매니페스트를 지우려 함 (스크립트 버그, 수정함)

- 매니페스트는 addons.yml 이 첫 control plane 안에서 렌더링하는데, reset.sh 는 배포 호스트의 `manifests/` 를 `kubectl delete -f` 하고 있었다. 실행 전 코드 검토에서 발견. 이름으로 지우게 바꿨다(`service harbor-bgp`, `ciliuml2announcementpolicy lab-l2`).

## 14. 워커 1대 정지로 Harbor 전체가 9분 넘게 멈춤: Harbor 파드가 한 노드에 몰림 [실서버 영향]

- 증상: VM 부터 새로 설치한 클러스터에서 장애 시험 C 의 pull 이 실패. registry 는 416s 에 다른 노드에서 Running 이었는데 pull 이 안 됨.
- 좁히기: 이벤트에 `TaintManagerEviction` 이 registry 외에 core·nginx·jobservice·redis 에도 찍힘 → 이번 설치에서는 Harbor 파드 5개가 정지한 ks-w3 한 노드에 있었다. Redis·jobservice 도 Longhorn 볼륨 재부착을 기다려야 해서 core 가 가장 늦게(정지 후 9분 18초) Ready. 첫 설치 때는 파드가 흩어져 있어 registry 만 옮겨 가면 됐다.
- 결론: Harbor 차트 기본값에는 컴포넌트 간 분산 규칙이 없고 각 1개라, 스케줄러가 한 노드에 몰아도 막지 않는다. 장애 영향이 설치마다 달라진다.
- 실서버 권장: core·portal·nginx·registry 는 replicas 2 이상 + `topologySpreadConstraints`(hostname). registry 를 2개 이상으로 하려면 RWX 스토리지나 S3 호환 저장소가 필요하다(Longhorn RWO 볼륨은 1개 노드에만 붙는다). Redis 는 외부 HA Redis(Sentinel) 로.

Harbor chart 1.18.0 values 예시(미실측). 차트가 `labelSelector` 를 컴포넌트별로 자동으로 붙이므로(`templates/core/core-dpl.yaml`), 이 설정은 **같은 컴포넌트의 복제본끼리** 다른 노드로 흩는다.

```yaml
core:
  replicas: 2
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
portal:
  replicas: 2
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
nginx:
  replicas: 2
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
```

지금 어느 노드에 몰려 있는지 확인:

```bash
kubectl -n harbor get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName | sort -k2
```
- 시험 스크립트: registry 가 떠도 Harbor 전체가 healthy 가 될 때까지 기다린 뒤 pull 하도록 고쳤다. 같은 노드에 있던 다른 Harbor 파드도 출력한다.

## 15. CP 1대 정지 17초 뒤 쓰기 1회 실패 `keepalive ping failed to receive ACK` (일시적)

- 장애 시험 A 를 네 번 돌려 한 번 나왔다. 오류는 apiserver → etcd gRPC 연결이 죽은 멤버에 붙어 있다가 keepalive 시간 초과로 끊긴 것(`rpc error: code = Unavailable`). 같은 상태에서 다시 돌렸을 땐 첫 시도에 성공해 재현되지 않았다.
- 판단: etcd 쿼럼(2/3)은 유지됐고, apiserver 의 etcd 클라이언트가 살아 있는 멤버로 옮겨 가는 사이의 일시 오류. 컨트롤러·kubectl·CI 처럼 API 를 쓰는 쪽은 재시도해야 한다.
- 시험 스크립트: 쓰기를 90초까지 재시도하고 첫 시도 성공 여부를 출력하게 바꿨다.

## 16. VM 전체를 껐다 켠 뒤 DB standby 2대가 스스로 못 돌아옴: 워커 메모리 부족 → Longhorn 퇴거 → `pg_rewind` 중단 [실서버 영향: 스토리지 노드 메모리 여유]

- 증상: VM 11대를 모두 꺼 둔 뒤 한꺼번에 켰다. CNPG 가 primary 1대만 Ready, standby 2대는 재시작을 반복. Harbor 조회는 되는데 프로젝트 생성(쓰기)이 응답 없음.
- 좁히기:
  1. 쓰기가 왜 멈추나 → primary 에서 `pg_stat_activity` 에 `SyncRep` 대기 세션 1개. 동기 복제(`any 1`)인데 붙은 standby 가 0이라 커밋이 끝나지 않는 것. 조회는 0.037초에 200, 쓰기는 15초 동안 무응답. 멈춰 있던 쓰기는 standby 가 다시 붙은 뒤 그대로 커밋됐다.
  2. standby 가 왜 못 붙나 → 로그가 `pg_rewind: error: could not find common ancestor of the source and target cluster's timelines` 반복. 처음 실패한 줄을 찾으니 `pg_rewind` 가 "340 MB 복사 필요" 로 시작한 18초 뒤 `could not open file "pg_wal/…" for reading: Input/output error` 로 끊겼다. 읽던 쪽은 primary 다.
  3. primary 볼륨이 왜 I/O 오류였나 → primary 노드 dmesg 에 같은 시각 `device offline error, dev sdb`, `Buffer I/O error`. Longhorn 이벤트에 그 노드 `instance-manager` 파드 `Evicted`: `The node was low on resource: memory. Threshold quantity: 100Mi, available: 46236Ki`.
  4. 메모리가 왜 모자랐나 → 콜드 부팅이라 먼저 Ready 가 된 워커 몇 대로 파드가 몰렸고, 그 위에서 DB 복구 I/O 가 돌았다.
- 원인: 워커 메모리 부족 → kubelet 이 Longhorn 의 `instance-manager` 를 퇴거 → 그 노드의 모든 Longhorn 볼륨이 순간 끊김 → 마침 돌던 `pg_rewind` 가 중간에 끊겨 standby 데이터 디렉터리가 반쯤 고쳐진 상태로 남음. 이 상태는 재시도로 낫지 않는다.
- 조치: primary 를 `pg_dumpall` 로 떠 둔 뒤(`secrets/` 아래, 커밋 금지), 깨진 standby 의 PVC + 파드를 지워 primary 에서 새로 받게 했다(17·18절에서 두 번 더 막혔다). 새로 만들기 시작부터 `Cluster in healthy state` 까지 102초(첫 standby 30초, 둘째 55초).
- 메모리가 어디로 갔나: 워커 1920MB 중 kubelet 이 868Mi 를 떼어 둔다(`kubeReserved` 256Mi + `systemReserved` 512Mi + 퇴거 기준 100Mi, 노드의 `/etc/kubernetes/kubelet-config.yaml`). 그래서 allocatable 이 985532Ki 였다. Kubespray 기본은 `kubelet_enforce_node_allocatable: ""`(`kubespray/roles/kubernetes/node/defaults/main.yml:13`)라 이 값은 스케줄링 계산에만 쓰이고, 퇴거는 노드 전체의 `memory.available < 100Mi` 로 일어난다. 여기에 노드마다 Cilium·Longhorn 데몬이 깔린다.
- 랩 조치: 워커를 7대 × 1920MB 에서 5대 × 2688MB 로 바꿨다(합계 같음, 20·21절). allocatable 1690836Ki.
- 교훈(실서버): Longhorn 을 올리는 노드는 메모리가 모자라면 "파드 몇 개가 죽는" 정도가 아니라 그 노드의 볼륨 전체가 끊긴다. Longhorn 파드는 메모리 request 가 0 이라 퇴거 순위가 앞이다. 실서버 수치는 이 랩에서 정할 수 없고, 같은 스크립트로 다시 잰다.

퇴거가 있었는지, 어느 노드가 메모리 부족인지:

```bash
kubectl get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail
kubectl get nodes -o 'custom-columns=N:.metadata.name,MEMP:.status.conditions[?(@.type=="MemoryPressure")].status,ALLOC:.status.allocatable.memory'
```

쓰기가 동기 복제를 기다리며 멈췄는지:

```bash
kubectl -n harbor exec <primary 파드> -c postgres -- psql -tAc "select count(*) from pg_stat_activity where wait_event='SyncRep'"
kubectl -n harbor exec <primary 파드> -c postgres -- psql -tAc "select application_name,state,sync_state from pg_stat_replication"
```

## 17. 깨진 standby 를 하나만 지우면 새 인스턴스가 안 생김 [실서버 영향]

- 증상: 16절에서 깨진 standby 2대 중 1대의 PVC + 파드를 지웠는데 600초 동안 새 인스턴스가 만들어지지 않음. 클러스터 phase 는 `Waiting for the instances to become active`.
- 검증: 남은 깨진 standby 의 PVC + 파드도 지우자 1초 안에 phase 가 `Creating a new replica` 로 바뀌고 join 작업이 시작됐다.
- 판단: operator 는 "아직 active 가 안 된 인스턴스" 가 있는 동안 새 인스턴스 만들기로 넘어가지 않는 것으로 보인다(관찰 기준, operator 소스로 확인하지는 않았다).
- 교훈: 여러 대가 깨졌으면 깨진 것을 모두 정리해야 재구성이 시작된다. 단, primary 가 멀쩡하고 백업을 떠 둔 뒤에만 한다.

## 18. 새 인스턴스 만들기(join) 중에 primary 파드가 사라지면 서로 기다림 [실서버 영향]

- 증상: join 작업이 도는 중 primary 파드가 없어졌다(primary 노드에서 메모리 부족이 한 번 더 났고, 누가 파드를 지웠는지는 확인하지 못했다). 13~14분 동안 join 작업은 primary(`harbor-pg-rw`)를 기다리고, operator 는 primary 파드를 다시 만들지 않음.
- 좁히기: 클러스터 status 에 `danglingPVC=["harbor-pg-3"]`(primary 의 PVC 는 멀쩡히 남음), `initializingPVC=["harbor-pg-1"]`(join 중인 빈 PVC). operator 가 초기화 중인 PVC 가 끝나기를 기다리는 동안 dangling PVC 로 파드를 되살리는 단계로 못 가는 모양새.
- 조치: join 작업과 그 빈 PVC 를 지움 → operator 가 primary 파드를 다시 만들었고 21초 뒤 1/1 Running. 그 뒤 standby 를 다시 만들게 했다.

```bash
kubectl -n harbor get cluster harbor-pg -o jsonpath='{.status.danglingPVC} {.status.initializingPVC}{"\n"}'
kubectl -n harbor delete job <인스턴스>-join
kubectl -n harbor delete pvc <인스턴스>          # join 이 만들던 빈 PVC 만. primary 의 PVC 는 건드리지 않는다
```

## 19. DB 인스턴스가 있던 워커가 돌아오지 않을 때: CNPG 는 스스로 다른 노드에 새로 만들지 않는다 [실서버 영향]

- 질문: 인스턴스 하나가 죽으면 새로운 곳에 만들어지나?
- 시험(`scripts/60-db-node-loss.sh`): standby 가 있는 워커를 강제 정지하고 420초 동안 손대지 않음.
  - 31초: primary 의 복제 연결 2 → 1. 61초: 노드 NotReady, ready 2/3.
  - 368초: 파드 `Terminating`(`TaintManagerEviction`). 그 전까지는 `Running` 으로 보인다.
  - 420초까지 새 인스턴스 없음. PVC 는 `Bound` 그대로.
- 이유: 볼륨이 그 노드에만 있는 것(`longhorn-single`, strict-local)이라 PVC 가 남아 있는 한 operator 는 그 PVC 로 다시 띄우려고 노드를 기다린다. CNPG 문서 `failure_modes.md`: "The Pod is restarted using its PVC if available; otherwise, a new Pod is created from a backup of the current primary".
- 노드를 못 살릴 때 절차: 그 인스턴스의 PVC 와 파드를 지운다(문서 `troubleshooting.md` "delete the PVC and let the operator rebuild the replica"). 3초 뒤 join 작업이 다른 워커에서 시작됐고, 지운 지 33초 뒤 새 인스턴스가 Ready, 복제 2개. 인스턴스 이름은 새 번호가 아니라 같은 이름을 다시 썼다.
- 남는 것: 옛 PV 는 `Released`(reclaim=Retain)로 남고 Longhorn 볼륨도 남는다. 지우지 않으면 20절의 문제가 된다.
- standby 1대가 없는 동안의 쓰기: 이 시험에서는 스크립트 버그(22절)로 못 쟀다. 같은 조건(standby 1대만 연결)인 20절의 옮기기 두 번에서 쓰기 22번이 모두 성공했다.

```bash
kubectl -n harbor delete pvc <인스턴스> --wait=false
kubectl -n harbor delete pod <인스턴스> --force --grace-period=0     # 노드가 꺼져 있을 때만 --force
```

## 20. 워커 제거: 옛 DB 볼륨이 drain 을 막고, 복제본 비우기 요청은 strict-local 볼륨에서 멈춘다 [실서버 영향]

워커를 7대에서 5대로 줄이며 겪은 것. 순서는 "그 노드의 DB 인스턴스를 다른 워커에 다시 만들기 → 3벌 볼륨의 복제본 옮기기 → Kubespray `remove-node.yml` → VM 정지" 였다.

- DB 인스턴스 옮기기(`scripts/61-db-move-instance.sh`): 노드를 cordon 하고 그 standby 의 PVC + 파드를 지운다. 41초, 49초 만에 다른 워커에서 Ready + 복제 2개. 그동안 2~4초 간격 쓰기 10/10, 12/12 성공. 볼륨이 노드 로컬이라 "이동" 이 아니라 "다시 만들기" 다.
- 막힌 것 1: `kubectl drain` 이 `instance-manager` 파드에서 `Cannot evict pod as it would violate the pod's disruption budget` 로 끝나지 않음.
  - 원인: 방금 옮기고 남은 옛 볼륨(Released)의 복제본이 그 노드에 1벌뿐이다. Longhorn 설정 `node-drain-policy: block-if-contains-last-replica` 가 마지막 복제본이 있는 노드의 drain 을 막는다. 떼어진 볼륨도 해당한다.
  - 실서버 절차: 새 인스턴스가 정상인지 확인한 뒤 옛 PV 와 Longhorn 볼륨을 지우고 drain 한다.
  - 랩에서 한 것: 옛 볼륨을 지우지 않고 남겨 두려고 설정을 잠시 `always-allow` 로 바꿨다가 끝난 뒤 되돌렸다. 두 VM 은 끄기만 해서 데이터는 VM 디스크에 남아 있다.
- 막힌 것 2: drain 전에 Longhorn 노드에 `evictionRequested: true` 를 걸었더니 옛 볼륨이 그 노드에 다시 붙은 채 멈춤.
  - 좁히기: manager 로그 `removing ks-w7 PDB is blocked: some volumes are still attached`. 볼륨 attachment 에 `volume-eviction-controller` 티켓. 복제본이 2개(하나는 노드 미배정)로 늘어 있었고, 요청을 취소해도 `admission webhook "validator.longhorn.io" denied the request: BUG: replica should be 1 for strict-local volume` 로 정리가 안 됨.
  - 원인: strict-local 볼륨은 복제본이 엔진과 같은 노드에 1벌이어야 하는데, 비우기 요청이 옮겨 갈 복제본을 하나 더 만들었다. 옮길 수도 없고, 2벌이라 검증에 걸려 되돌릴 수도 없다.
  - 조치: `evictionRequested: false` 로 되돌리고, 노드·디스크·데이터 경로가 비어 있는 미배정 복제본 기록을 지움 → 8초 뒤 볼륨이 떼어지고 PDB 가 사라짐.
  - 교훈: strict-local 볼륨이 있는 노드는 Longhorn 비우기 요청으로 비울 수 없다. 위쪽(DB)에서 다시 만들게 한다. 3벌 볼륨은 그 노드의 스케줄을 끄고(`allowScheduling: false`) 그 노드 복제본을 지우면 다른 노드에 다시 만든다(registry 볼륨 약 32초).
- `kubectl delete node` 뒤에도 Longhorn 의 노드 기록(`nodes.longhorn.io`)은 Ready=False 로 남는다. 옛 볼륨의 복제본이 거기 걸려 있어 그대로 두었다.

```bash
kubectl -n longhorn-system get settings.longhorn.io node-drain-policy -o jsonpath='{.value}{"\n"}'
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=VOL:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState | grep <노드>
kubectl -n longhorn-system get volumeattachments.longhorn.io <볼륨> -o jsonpath='{range .spec.attachmentTickets.*}{.type} {.nodeID}{"\n"}{end}'
```

## 21. `remove-node.yml` 이 빼지 않는 노드에서도 패키지 점검을 돌림 → 메모리가 빠듯한 노드에서 퇴거 (랩 메모리)

- 증상: `ks-w7` 을 빼는 중에 방금 DB 인스턴스를 옮겨 받은 `ks-w2` 가 MemoryPressure. Longhorn `instance-manager` 가 퇴거되어 `harbor-pg-2` 가 내려감. CP 2대도 MemoryPressure 표시.
- 좁히기: PLAY RECAP 에 제거 대상이 아닌 노드도 `ok=21`. 플레이북이 모든 노드에서 facts 수집과 `bootstrap_os`·`system_packages`(apt) 를 돈다. 그 시점 `ks-w2` 에 `packagekitd`·`fwupd` 가 떠 있었다.
- 결과: 메모리 부족 표시가 풀린 뒤 `harbor-pg-2` 는 같은 볼륨으로 스스로 다시 붙었다(이번에는 `pg_rewind` 중이 아니라 데이터가 깨지지 않았다). 그동안 다른 standby 1대가 붙어 있어 쓰기는 유지.
- 랩 조치: 먼저 뺀 VM 의 메모리만큼 남은 워커 2대를 올린 뒤 다음 노드를 뺐다. 메모리를 아직 못 올린 노드는 플레이북 직전에 페이지 캐시를 비웠다(`echo 1 > /proc/sys/vm/drop_caches`). 두 번째 제거에서는 퇴거가 없었다.
- 교훈: 노드 추가·제거 플레이북도 전체 노드에 부하를 준다. DB 를 막 옮긴 직후에 바로 돌리지 않는다.

## 22. 시험 스크립트가 "실패" 로 잘못 적음: macOS bash 3.2 따옴표, join 파드 이름 (스크립트 버그, 수정함)

- 증상 1: `60-db-node-loss.sh` 가 매번 `[: too many arguments` 를 내고 "DB 쓰기 실패" 로 기록.
  - 원인: macOS 기본 `/bin/bash` 3.2 는 `"$( … \"…\" … )"` 안의 이스케이프 따옴표를 잘못 쪼갠다. curl 본문과 응답 코드를 변수에 받아 비교하도록 고쳤다.
- 증상 2: 새 인스턴스가 33초에 Ready 였는데 "900초 안에 Ready 안 됨" 으로 기록.
  - 원인: "새 파드" 를 이름으로 찾았는데 join 작업 파드(`<인스턴스>-join-xxxxx`)가 먼저 걸렸고, CNPG 는 인스턴스 이름을 다시 쓴다. 인스턴스 파드는 라벨 `cnpg.io/podRole=instance` 와 파드 UID 로, join 작업은 라벨 `cnpg.io/jobRole` 로 구분하게 고쳤다. 실제 시간은 파드 타임스탬프에서 다시 뽑았다.
- 교훈: [NG] 가 찍히면 시험 대상보다 스크립트의 판정 줄을 먼저 의심한다(10절과 같은 종류).

## 23. Harbor 를 ingress 로 바꾸는 `helm upgrade` 가 끝나지 않음: registry 새 파드가 볼륨을 못 붙임 [실서버 영향]

- 증상: `./scripts/addon.sh harbor`(`helm upgrade --wait`)가 끝나지 않음. 새 registry 파드가 `ContainerCreating` 에서 멈춰 있었다. 6분 15초에 `UPGRADE FAILED: Get "https://…:6443/…"` 로 끝났는데, 이 종료 자체는 24절(API 끊김) 때문이다.
- 좁히기: `kubectl -n harbor describe pod <새 registry 파드>` 의 이벤트가 `FailedAttachVolume … Volume is already used by pod(s) harbor-registry-…`. 옛 파드는 `ks-w1`, 새 파드는 `ks-w2` 였다. Deployment 전략은 `RollingUpdate`.
- 원인: registry 볼륨은 RWO(Longhorn)라 한 노드에만 붙는다. `RollingUpdate` 는 새 파드가 Ready 가 된 뒤에 옛 파드를 내리는데, 새 파드가 다른 노드에 잡히면 옛 파드가 볼륨을 쥐고 있어 영영 Ready 가 안 된다. 같은 노드에 잡히면 지나간다. 이전 업그레이드들이 통과한 이유는 따로 확인하지 않았다.
- 조치: `templates/harbor-values.yaml.j2` 에 `updateStrategy.type: Recreate`. 옛 파드를 먼저 내린다. 차트 values 의 설명도 "RWM 을 지원하지 않는 볼륨이면 Recreate" 다.
- 대가: 업그레이드할 때마다 registry·jobservice 가 잠깐 내려간다(파드 1개라 원래도 무중단은 아니다).
- 같이 겪은 것: release 가 `pending-upgrade`(revision 2)로 남았다. 업그레이드 도중 API 서버가 끊겨(24절) helm 이 실패 기록을 못 남긴 경우다. 이 상태에서는 다음 `helm upgrade` 가 진행 중인 작업이 있다며 거절한다(Helm 동작, 이번에 다시 실행해 확인하지는 않고 바로 정리했다).
  - 조치: 멈춘 revision 의 Secret 을 지우고 다시 실행 → 39초에 끝남. `helm rollback` 도 방법이지만 바꾸려던 값이 되돌아간다.
- 교훈: RWO 볼륨을 쓰는 Deployment 는 전략을 먼저 본다. `--wait` 가 오래 걸리면 타임아웃을 기다리지 말고 새 파드 이벤트를 본다.

```bash
kubectl -n harbor get deploy -o custom-columns=NAME:.metadata.name,STRATEGY:.spec.strategy.type
kubectl -n harbor get events --field-selector reason=FailedAttachVolume
helm -n harbor history harbor | tail -3
kubectl -n harbor get secret -l owner=helm,name=harbor,status=pending-upgrade     # 멈춘 revision
```

## 24. 업그레이드 도중 API VIP 가 `connection refused`: Mac 에서 다른 VM(Docker Desktop 빌드)이 같이 돌았다 (랩 호스트 한계)

- 증상: 23절의 업그레이드 도중 `kubectl` 이 `172.16.141.30:6443: connect: connection refused`. 약 1분 뒤 스스로 돌아옴.
- 좁히기:
  - CP 세 대의 kube-apiserver 컨테이너가 모두 방금 재시작. `ks-cp1` 의 직전 컨테이너는 종료 코드 137. kubelet 로그에 apiserver liveness·readiness 실패.
  - 그보다 10분 전부터 etcd 로그의 `apply request took too long` 이 늘고 있었고 CP 의 load average 가 15 안팎. CP 안에서 CPU·메모리를 많이 쓰는 프로세스는 없었다.
  - VM 안에 원인이 없어 호스트를 봤다. Docker Desktop 이 00:16:53 에 떠 있었고 `docker build` 가 돌고 있었다. 호스트 스왑 9.5GB 사용, load average 17~26.
- 원인: 호스트 메모리·CPU 를 다른 VM 과 나눠 쓰면서 etcd 디스크 쓰기가 느려졌다. apiserver 가 liveness 시간 안에 답하지 못해 kubelet 이 세 대를 거의 동시에 죽였다. API VIP 를 누가 갖든 뒤에 살아 있는 apiserver 가 없었다.
- 조치: 없음. 빌드가 끝나자 load 가 내려갔다. Docker Desktop 은 다른 작업이 띄운 것이라 끄지 않았다.
- 교훈: 7·8절과 같은 종류다. 랩에서 CP 세 대가 같이 흔들리면 클러스터보다 호스트(`uptime`, `sysctl vm.swapusage`, 다른 하이퍼바이저)를 먼저 본다. 그동안 잰 시간은 버린다. 실서버에서 대응되는 것은 CP 세 대가 같은 스토리지·같은 하이퍼바이저를 나눠 쓰는 경우다.

## 25. 컨트롤러가 있는 워커가 죽으면 40여 초 동안 요청 일부가 실패, 그리고 "복구됨" 뒤에도 registry 는 내려가 있었다 [실서버 영향]

진입점 시험(`scripts/62-ingress-failover.sh`)에서 본 것 두 가지.

- 증상 1: ingress-nginx 컨트롤러 3개 중 하나가 있는 워커를 강제로 끄면, VIP 는 그대로인데 요청이 띄엄띄엄 2초 타임아웃. 두 번 재서 정지 후 43초, 46초까지 이어졌고 그 뒤로는 실패가 없었다. 그 구간의 요청 38번·40번 중 13번·11번 실패.
  - 좁히기: VIP 를 알리는 노드는 바뀌지 않았다. 실패가 멈춘 시점이 노드가 NotReady 로 바뀐 시점과 같다. `node-monitor-grace-period` 는 40s(kubeadm-config).
  - 원인: `externalTrafficPolicy: Cluster` 에서 VIP 를 받은 노드는 컨트롤러 파드 3개에 나눠 보낸다. 노드가 죽어도 NotReady 판정 전까지는 죽은 파드가 서비스 뒤에 남아 있어, 그쪽으로 간 연결만 실패한다.
  - 비교: VIP 를 알리던 워커(컨트롤러 없음)를 껐을 때는 약 15초 동안 **전부** 실패하고 끝났다. L2 공지 lease 의 `leaseDurationSeconds` 가 15 다.
  - 실서버: 클라이언트(containerd, CI)가 재시도하면 넘어가는 길이다. 줄이려면 노드 판정 시간을 줄여야 하는데 클러스터 전체에 영향이 있어 이 랩은 기본값 그대로 두었다.
- 증상 2: 같은 시험 직후 BGP 경로 시험(F)이 pull·push 모두 실패. 시험 스크립트는 그 전에 "DB 3/3, 컨트롤러 3개 Running" 을 찍고 끝난 상태였다.
  - 좁히기: `GET /api/v2.0/health` 가 `unhealthy`, 구성요소 `registry`·`registryctl`·`jobservice`. 끈 워커에 registry·jobservice 파드가 있었다. 노드가 150초 만에 돌아와 파드는 축출되지 않았는데(300초 전), 돌아온 노드에서 볼륨 마운트가 실패(`MountVolume.MountDevice failed … driver name driver.longhorn.io not found` → `volume … hasn't been attached yet`)했고, 약 50초 뒤 두 파드가 지워져 다른 워커에 새로 생겼다. 볼륨을 옮겨 붙이고 healthy 까지 노드 복귀 후 약 2분, 정지부터는 약 5분.
  - 원인: 파드를 지운 주체는 로그에서 확인하지 못했다. Longhorn 설정 `auto-delete-pod-when-volume-detached-unexpectedly`(값 `true`)가 하는 일과 일치한다. 볼륨이 예기치 않게 떨어지면 그 볼륨을 쓰는 파드를 지워 다시 붙게 한다.
  - 스크립트 쪽 원인: 탐침이 Harbor `ping` 뿐이었다. ping 은 core 까지만 간다. registry 가 없어도 200 이다.
  - 조치: 상태 줄과 마무리 판정에 health API(구성요소별)를 넣었다. 두 번째 측정에서는 끈 노드에 portal 만 있었고 `unhealthy(portal)` 이 정지 48초 뒤부터 찍혔다.
- 교훈: "API 가 200" 과 "push/pull 이 된다" 는 다른 말이다. 장애 시험의 복구 판정은 실제 경로(레지스트리)까지 본다. 14절(Harbor 파드가 한 노드에 몰림)과 같은 약점이 여기서도 나온다. 컨트롤러는 3개라 버티는데 그 뒤의 registry 는 1개다.

```bash
kubectl -n kube-system get lease cilium-l2announce-ingress-nginx-ingress-nginx-controller -o jsonpath='{.spec.holderIdentity} {.spec.leaseDurationSeconds}{"\n"}'
curl -sk https://<harbor_host>/api/v2.0/health          # 구성요소별 상태
kubectl -n longhorn-system get settings.longhorn.io auto-delete-pod-when-volume-detached-unexpectedly -o jsonpath='{.value}{"\n"}'
```

## 26. 노드 8대의 iSCSI initiator 이름이 전부 같았다: 템플릿(박스 이미지)에서 복제한 VM [실서버 영향: VM 템플릿]

**증상**: 없었다. 장애가 나서 찾은 것이 아니라, "실서버가 VM 이면 템플릿 복제에서 무엇이 겹칠 수 있나" 를 랩 노드에서 하나씩 대조하다 나왔다.

**좁히기**
1. kubeadm 설치 문서가 고유해야 한다고 적는 값부터 봤다. hostname, 클러스터 NIC(`eth1`)의 MAC, `/sys/class/dmi/id/product_uuid`, 그리고 `/etc/machine-id` → 8대 모두 서로 달랐다. Vagrant·VMware 가 복제할 때 새로 만든다.
2. 같은 방식으로 "OS 설치 때 한 번 만들어지고 그 뒤로 안 바뀌는 값" 을 더 찾았다. Longhorn 이 쓰는 open-iscsi 의 `/etc/iscsi/initiatorname.iscsi` → **8대 모두 `InitiatorName=iqn.2004-10.com.ubuntu:01:…` 로 같은 값**이었다.
3. 어디서 온 값인가: 파일 수정 시각이 8대 모두 2025-08-06 15:27 로 같다. VM 을 만든 날이 아니라 박스 이미지를 만든 날이다. 이미지에 open-iscsi 가 설치돼 있었고 그때 만든 이름이 복제본에 그대로 실렸다. `addons.yml` 의 Longhorn 사전 조건은 패키지가 이미 있으니 아무것도 바꾸지 않았다.
4. 그런데 왜 Longhorn 은 멀쩡했나: 워커에서 `iscsiadm -m session -P1` 을 보면 붙어 있는 타깃의 주소가 **같은 노드에 있는 `instance-manager` 파드의 IP** 다(`ks-w2` → `ks-w2` 의 instance-manager, `ks-w5` → `ks-w5` 의 것). 타깃 이름은 볼륨마다 따로다(`iqn.2019-10.io.longhorn:pvc-…`). 노드마다 자기 노드 안의 타깃에만 로그인하므로 initiator 이름이 같아도 한 타깃에 같은 이름 둘이 붙는 일이 없다.

**원인**: 템플릿(이미지)에 open-iscsi 가 들어 있으면 복제한 VM 이 같은 initiator 이름을 갖는다. machine-id 와 달리 복제 도구가 다시 만들어 주지 않는다.

**실서버에서 문제가 되는 경우**: 같은 노드에 사내 iSCSI 스토리지(외장 스토리지의 LUN)를 붙일 때다. 스토리지는 initiator 이름으로 호스트를 구분하고 접근을 허용하므로, 이름이 같으면 노드를 구분할 수 없다. 이 경우는 랩에 그런 스토리지가 없어 재현하지 않았다.

**조치**: 랩은 그대로 두었다(볼륨이 붙어 있는 상태에서 이름을 바꾸고 iscsid 를 재시작하면 세션이 끊긴다). 대신
- `preflight.yml` 에 검사를 넣었다. 겹치면 경고하고, machine-id · product_uuid · MAC 이 겹치면 중단한다. 랩 결과: "initiator 이름 1종 / 이름이 있는 노드 8대".
- 실서버는 **설치 전에** 템플릿이나 각 VM 에서 이름을 새로 만든다. 명령은 INFRA.md 6-1.

**교훈**: 장애가 없다고 설정이 맞는 것은 아니다. "복제해도 되는 값인가" 는 값마다 따로 봐야 하고, 문서가 적어 둔 목록(MAC, product_uuid)이 전부가 아니다.

