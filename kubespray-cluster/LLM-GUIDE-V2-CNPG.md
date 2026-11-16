# 운영 보조용 지침: Longhorn V2 디스크 · CNPG 장애 대응

이 문서는 사내 LLM 이 운영자의 질문에 답할 때 읽는 지침이다. 사람용 설명은 [LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md), [V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md) 에 있고, 이 문서는 그 내용을 "증상 → 확인 → 조치" 순서와 지켜야 할 규칙으로 다시 묶은 것이다.

## 0. 이 지침을 쓰는 방법

- 이 문서의 수치와 동작은 **랩 실측**이다(2026-11-16, Longhorn 1.13.0, CNPG operator 1.30.1, PostgreSQL 16, VM 워커 3대, SATA 가상 디스크). 실서버 값으로 단정하지 말고 "랩에서는 ~였다"로 전한다.
- 운영자가 출력을 주지 않았으면 **먼저 확인 명령을 주고 출력을 받은 뒤** 조치를 고른다. 출력 없이 조치부터 권하지 않는다.
- `[주의]` 가 붙은 조치는 실행 전에 조건을 운영자에게 확인받는다. 조건을 확인하지 못했으면 실행하라고 하지 않는다.
- 이 문서에 없는 상황(아래 7절)은 추측해서 답하지 말고 "검증되지 않았다"고 말한다.
- 명령의 `<…>` 는 운영자 환경 값으로 바꿔야 한다. 값을 지어내지 않는다.

## 1. 알아야 할 사실

### 1.1 Longhorn V2 디스크

- V2 엔진은 파티션·파일시스템이 없는 **블록 디스크 전체**를 쓴다(`diskType: block`).
- Longhorn 은 디스크를 등록한 **경로 문자열**로 찾는다. 디스크 안의 데이터(lvstore)는 **UUID** 로 식별한다.
- `/dev/sdX` 는 커널이 부팅 때 발견 순서대로 붙이는 이름이라 재부팅하면 바뀔 수 있다. 바뀌면 Longhorn 은 옛 경로에서 디스크를 못 찾는다.
- `/dev/disk/by-id/wwn-0x…` 는 디스크 고유값에서 만들어져 바뀌지 않는다.
- `/dev/disk/by-id/ata-…_<번호>`, `scsi-0ATA_…_<번호>` 의 끝 번호는 랩(VMware SATA)에서 **포트 번호**였다. 디스크를 다른 포트로 옮기면 바뀐다. **`wwn-` 을 우선한다.**
- `wwn-` 이 없으면 `/dev/disk/by-path/…` 를 쓴다. VM 의 디스크 슬롯 구성을 바꾸지 않는 한 고정이다.
- Longhorn 은 UUID 가 맞지 않는 디스크에 쓰지 않는다. 랩에서 `/dev/sdc` 가 빈 디스크를 가리켰을 때 그 디스크는 그대로 비어 있었다.

### 1.2 CNPG

- 쓰기를 받는 인스턴스(primary)는 **하나**다. 나머지는 읽기 전용 standby 다.
- 서비스: `<클러스터>-rw` → primary, `<클러스터>-ro` → standby, `<클러스터>-r` → 아무 인스턴스.
- primary 가 죽으면 **operator** 가 standby 하나를 승격시킨다. 파드를 수동으로 지울 필요는 없다. **operator 가 살아 있어야 승격된다.**
- 갑작스러운 장애에서 쓰기 중단 0 은 불가능하다. 줄일 수만 있다.

### 1.3 랩 실측 수치 (인스턴스 3개, 동기 복제)

| 상황 | 쓰기 중단 | 읽기 중단 |
|---|---|---|
| primary 노드 사망, operator 1개가 같은 노드에 있었음 | 6분 26초 | 없음 |
| primary 노드 사망, operator 2개(서로 다른 노드) | 58초 | 없음 |
| 위 + 노드 죽음 판정 40초 → 20초 | 34초 | 없음 |
| 계획된 전환(switchover) | 4~6초 | 없음 |
| standby 노드 사망 | 없음 | 없음 |

| 상황 | 시간 |
|---|---|
| 노드 복귀 → V2 디스크 `Ready` | 81~98초 |
| 노드 복귀 → CNPG 인스턴스 Ready | 80~169초 |
| 노드가 안 돌아옴, 아무것도 안 함 | 13분이 지나도 파드가 옮겨 가지 않음 |
| 노드가 안 돌아옴, `out-of-service` taint | 5초 뒤 다른 노드에 파드 생성, 27초 뒤 Ready (3벌 볼륨일 때) |

각 시험은 1번씩(switchover 만 3번) 쟀다.

## 2. 증상별 대응

### 2.1 재부팅 뒤 V2 디스크가 `Ready=False`, 볼륨 `faulted`, CNPG 파드가 `Init` 에서 멈춤

확인:

```bash
kubectl -n longhorn-system get nodes.longhorn.io <노드> -o jsonpath='{range .status.diskStatus.*}{.diskName} {.diskPath} {.conditions[?(@.type=="Ready")].status} {.conditions[?(@.type=="Ready")].message}{"\n"}{end}'
kubectl -n longhorn-system get nodes.longhorn.io <노드> -o jsonpath='{.spec.disks}'
```

메시지로 갈린다.

| 메시지에 있는 말 | 뜻 | 조치 |
|---|---|---|
| `failed to detect disk device /host/dev/sdX` | 등록한 `/dev/sdX` 가 없어졌다 | 2.2 |
| `is already used by disk bdev` 또는 `cannot find lvstore with UUID` | `/dev/sdX` 가 다른 디스크를 가리킨다 | 2.2 → 안 되면 2.3 |
| 경로가 이미 `by-id`/`by-path` 인데 실패 | 이름 밀림이 원인이 아니다 | 6절(버전), 그 외는 검증되지 않음 |

### 2.2 경로를 고정 경로로 바꾸기 (디스크를 비우지 않는다)

노드에서 원래 V2 디스크를 찾는다. 크기와 `SPDKBLOB` 표식으로 판단한다.

```bash
lsblk -d -o NAME,SIZE,WWN,SERIAL
for d in /dev/sd?; do echo "$d $(sudo head -c 8 $d | tr -dc '[:print:]')"; done      # V2 디스크는 SPDKBLOB 으로 시작
DEV=sdb      # 위에서 찾은 V2 디스크
for l in /dev/disk/by-id/wwn-*; do [ "$(readlink -f "$l")" = "/dev/$DEV" ] && echo "$l"; done
```

```bash
kubectl -n longhorn-system patch nodes.longhorn.io <노드> --type merge \
  -p '{"spec":{"disks":{"<디스크 이름>":{"path":"/dev/disk/by-id/wwn-0x<값>"}}}}'
```

- `<디스크 이름>` 은 `spec.disks` 의 키다. 바꾸지 않는다(바꾸면 다른 디스크로 취급된다).
- `diskType` 은 바꾸지 않는다. Longhorn 이 거부한다.
- 랩: 약 60초 뒤 디스크 Ready, 볼륨 attached, 데이터 유지. 정상 동작 중인 노드에서 해도 6초 뒤 반영, 쓰기 실패 0.

### 2.3 경로를 고쳤는데 5분 넘게 `cannot find lvstore with UUID` `[주의]`

그 노드의 V2 instance-manager 가 잘못 잡은 디스크를 기억하고 있다. 파드를 지워 다시 띄운다.

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'     # 노드별 이름
kubectl -n longhorn-system delete pod <그 노드의 V2 instance-manager 이름>
```

- **조건:** 그 노드의 V2 볼륨이 이미 `faulted`/`detached` 일 때만. 정상 attached 볼륨이 있는 노드에서 지우면 그 볼륨이 끊긴다.
- 랩: 87초 뒤 복구, 데이터 유지.

### 2.4 primary 노드가 죽었는데 승격이 안 된다

확인:

```bash
kubectl -n <ns> get cluster <클러스터> -o jsonpath='{.status.phase} {.status.currentPrimary} {.status.readyInstances}/{.status.instances}{"\n"}'
kubectl -n cnpg-system get pods -o wide            # operator 가 어느 노드에 있는가, Running 인가
kubectl -n cnpg-system logs deploy/<operator 이름> --since=10m | grep -E "failover|Failing over|acquired lease"
```

- operator 가 죽은 노드에 있었으면 그것이 원인이다. 축출 대기(기본 300초) 뒤 다른 노드에 다시 뜨면 곧 승격된다. 기다리면 된다.
- 다시 생기지 않도록 4.1(operator 2개)을 권한다.
- operator 가 살아 있는데 1~2분이 지나도 승격이 안 되면 이 문서 범위 밖이다. operator 로그를 운영자에게 받아 판단한다.
- **파드를 지우라고 권하지 않는다.** 승격에 필요하지 않았다.

### 2.5 노드가 죽어서 안 돌아오는데 그 노드의 CNPG 인스턴스가 옮겨 가지 않는다

확인:

```bash
kubectl -n <ns> get pods -l cnpg.io/cluster=<클러스터> -o wide       # 죽은 노드의 파드가 Terminating
kubectl get volumeattachment | grep <pv 이름>                         # 죽은 노드에 남아 있음
kubectl -n longhorn-system get volumes.longhorn.io <pv 이름> -o jsonpath='{.spec.numberOfReplicas}{"\n"}'
```

원인: 죽은 노드의 kubelet 이 응답하지 않아 파드 객체가 지워지지 않고, 볼륨이 그 노드에 붙은 것으로 남는다. Longhorn 의 `node-down-pod-deletion-policy` 는 StatefulSet·Deployment 파드만 지우는데 CNPG 파드는 둘 다 아니다.

조치 `[주의]`:

```bash
kubectl taint node <죽은 노드> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# 노드를 살린 뒤 반드시
kubectl taint node <노드> node.kubernetes.io/out-of-service-
```

- **조건:** 그 노드의 전원이 꺼져 있거나 OS 가 확실히 죽었다는 것을 운영자가 확인했을 때만. 살아 있는 노드(네트워크만 끊긴 경우 포함)에 달면 같은 볼륨을 두 노드가 쓰게 될 수 있다.
- 볼륨 복제본이 1개(`numberOfReplicas: 1`, strict-local)면 데이터가 그 노드에만 있으므로 taint 를 달아도 옮겨 갈 수 없다. 이때는 노드 복구를 기다리거나, 그 인스턴스의 PVC 를 지워 CNPG 가 다른 노드에 새로 복제하게 한다. PVC 삭제는 그 인스턴스 데이터를 버리는 일이므로 다른 인스턴스 2개가 정상인지 먼저 확인한다.

### 2.6 노드를 재부팅·패치해야 한다 (계획된 작업)

primary 가 그 노드에 있으면 먼저 넘긴다.

```bash
kubectl -n <ns> get pods -l cnpg.io/cluster=<클러스터> -L cnpg.io/instanceRole -o wide
kubectl cnpg promote <클러스터> <다른 노드의 replica 이름> -n <ns>          # kubectl-cnpg 플러그인
```

랩: 쓰기 중단 4~6초. 그 다음 노드를 재부팅하고, 2.1 처럼 디스크 Ready 와 인스턴스 Ready 를 확인한 뒤 다음 노드로 넘어간다. **두 노드를 동시에 내리지 않는다.**

### 2.7 V2 를 켰는데 V2 instance-manager 가 `error`, 파드가 떴다 사라짐

```bash
kubectl -n longhorn-system get settings.longhorn.io data-engine-cpu-mask -o jsonpath='{.value}{"\n"}'
nproc        # 노드에서
```

마스크가 노드의 CPU 전부를 덮으면(예: 2 vCPU 에 `0x3`) Longhorn 이 기동을 거부한다(로그 `SPDK cpu mask 0x3 covers every online CPU`). 파드가 금방 사라져 로그가 안 보이면 2초 간격으로 `kubectl logs` 를 반복해 잡는다.

```bash
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
```

## 3. 처음 설치할 때 권할 것

1. V2 디스크는 처음부터 `/dev/disk/by-id/wwn-…` 로 등록한다.
2. 노드마다 커널 모듈(`vfio_pci`, `uio_pci_generic`, `nvme_tcp`)과 hugepage 2GiB(2MiB × 1024)를 영구 설정하고 kubelet 을 재시작한다.
3. vCPU 가 적으면 V2 CPU 마스크를 노드 CPU 보다 작게 잡는다.
4. CNPG operator 를 2개, 서로 다른 노드에 둔다(4.1).
5. CNPG 는 인스턴스 3개 + 동기 복제. 애플리케이션은 `-rw` 서비스 이름으로만 붙고 재접속하게 한다.

## 4. 설정

### 4.1 CNPG operator 2개

Helm:

```yaml
replicaCount: 2
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: kubernetes.io/hostname
      labelSelector: {matchLabels: {app.kubernetes.io/name: cloudnative-pg}}
```

```bash
helm upgrade <릴리스> cnpg/cloudnative-pg -n cnpg-system --version <차트 버전> --reuse-values -f <위 파일> --wait
```

kubectl (랩에서 실행하지 않았다):

```bash
kubectl -n cnpg-system scale deploy <operator 이름> --replicas=2
kubectl -n cnpg-system patch deploy <operator 이름> --type merge -p '{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"topologyKey":"kubernetes.io/hostname","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"cloudnative-pg"}}}]}}}}}}'
```

### 4.2 노드 죽음 판정 단축 `[주의]`

kube-controller-manager `--node-monitor-grace-period` (기본 40초). Kubespray 변수 `kube_controller_node_monitor_grace_period`. 랩에서 20초로 줄이면 쓰기 중단이 58초 → 34초.

- 클러스터 전체에 적용된다. 짧은 네트워크 끊김·노드 멈춤에도 NotReady 가 되어 승격과 파드 이동이 일어난다.
- **권하지 말고 선택지로만 설명한다.** 결정은 운영자가 한다.

### 4.3 CNPG 클러스터에 넣을 값

```yaml
spec:
  instances: 3
  smartShutdownTimeout: 15        # 계획된 종료 시 승격이 기본 180초 늦어지는 것을 막는다 (V1 랩 실측: 173초 → 21초)
  affinity: {enablePodAntiAffinity: true, topologyKey: kubernetes.io/hostname, podAntiAffinityType: required}
  postgresql:
    synchronous: {method: any, number: 1}
```

## 5. 하지 말 것

- `diskType` 변경, 디스크 이름(키) 변경.
- V2 디스크에 `wipefs` 나 포맷 — 데이터가 사라진다. 2.2 의 경로 교체로 충분하다.
- 살아 있는 노드에 `out-of-service` taint.
- 정상 볼륨이 붙어 있는 노드의 V2 instance-manager 삭제.
- 승격시키려고 primary 파드 삭제. 필요 없고, 노드가 살아 있으면 오히려 계획된 종료 절차를 탄다.
- 두 노드를 동시에 재부팅.
- 랩 수치를 실서버 보장값처럼 말하기.

## 6. 버전

| 이슈 | 내용 | 수정 버전 |
|---|---|---|
| longhorn#12910 | `by-id` 경로 디스크에서 상태 수집 실패 로그 반복 | 1.12.0 (1.11.2 백포트) |
| longhorn#12406 | 노드를 차례로 재부팅하면 V2 볼륨이 attach/detach 반복 | 1.11.0 |
| longhorn#10112 | 노드 재부팅 뒤 V2 볼륨이 detaching/faulted 로 남음 | 1.10.0 |

운영자의 Longhorn 버전이 위보다 낮으면 2.2 를 해도 증상이 남을 수 있다고 알린다.

## 7. 검증되지 않은 것 — 추측으로 답하지 않는다

- 노드 주석(`node.longhorn.io/default-disks-config`)으로 블록 디스크 자동 등록.
- NVMe(BDF 등록)·VirtIO 디스크. 랩은 SATA 라 aio 드라이버였다.
- 실서버 하이퍼바이저에서 `wwn-` 항목이 보이는지.
- 축출 대기(`tolerationSeconds`, 기본 300초)를 줄였을 때의 효과.
- 네트워크만 끊긴 경우(노드는 살아 있음)의 승격과 옛 primary 동작.
- 부하가 걸린 상태에서의 승격 시간.
