# Longhorn V2 · CNPG 시험 묶음 (2026-11-16)

GitHub 에 최근 올린 V2 시험 커밋 세 개(`0a40c69`, `25ebb4c`, `c6066df`)를 한 파일로 묶었다. 사람이 읽는 문서, 사내 LLM 지침, 시험에 쓴 설정·스크립트, 로그 원문이 모두 들어 있다. 같은 디렉터리의 원본 파일들을 이어 붙여 만든 사본이므로, 고칠 때는 원본을 고치고 이 파일을 다시 만든다.

| 부 | 내용 |
|---|---|
| 1부 | 결론 요약 |
| 2부 | 문서 4개 + TROUBLESHOOTING 27~29절 |
| 3부 | 설정·스크립트 14개. 블럭을 터미널에 붙여넣으면 파일이 만들어진다(sha256 대조 포함) |
| 4부 | 로그 원문 15개 |

# 1부. 결론 요약

| 상황 | 할 일 | 랩 결과 (인스턴스 3개 기준) |
|---|---|---|
| 재부팅 뒤 V2 디스크가 안 붙음 | 디스크를 `/dev/disk/by-id/wwn-0x…` 로 등록. 이미 등록한 노드는 `path` 만 교체(디스크 비우지 않음) | 약 60초 뒤 복구, 데이터 유지. `by-id` 로 등록된 노드는 이름이 밀려도 그대로 복구 |
| 경로를 고쳐도 `cannot find lvstore with UUID` | 그 노드의 V2 instance-manager 파드 삭제 (그 노드 볼륨이 이미 faulted 일 때만) | 87초 뒤 복구 |
| primary 노드가 갑자기 죽음 | CNPG operator 2개를 서로 다른 노드에. 파드 삭제는 필요 없음 | 쓰기 중단 6분 26초 → 58초. 읽기 중단 없음 |
| 위에서 더 줄이기 (선택) | 노드 죽음 판정 40초 → 20초. 클러스터 전체에 적용, 짧은 끊김에도 승격 | 58초 → 34초 |
| 계획된 재부팅 | 먼저 `kubectl cnpg promote` 로 primary 넘기기 | 쓰기 중단 4~6초 |
| 죽은 노드가 안 돌아와 인스턴스가 안 옮겨 감 | 전원이 확실히 꺼졌을 때 `out-of-service` taint, 살린 뒤 제거 | 5초 뒤 다른 노드에 생성, 27초 뒤 Ready (3벌 볼륨) |
| 2 vCPU 노드에서 V2 가 안 뜸 | `data-engine-cpu-mask` 를 `{"v2":"0x1"}` 로 | 2분 뒤 running |

쓰기 중단 0 은 불가능하다(쓰기를 받는 인스턴스가 하나). 각 시험은 1번씩(switchover 만 3번) 쟀고, 랩은 VM·SATA 가상 디스크·Longhorn 1.13.0·CNPG 1.30.1 이다.

# 2부. 문서

<!-- 원본: kubespray-cluster/LLM-GUIDE-V2-CNPG.md -->

## 운영 보조용 지침: Longhorn V2 디스크 · CNPG 장애 대응

이 문서는 사내 LLM 이 운영자의 질문에 답할 때 읽는 지침이다. 사람용 설명은 [LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md), [V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md) 에 있고, 이 문서는 그 내용을 "증상 → 확인 → 조치" 순서와 지켜야 할 규칙으로 다시 묶은 것이다.

### 0. 이 지침을 쓰는 방법

- 이 문서의 수치와 동작은 **랩 실측**이다(2026-11-16, Longhorn 1.13.0, CNPG operator 1.30.1, PostgreSQL 16, VM 워커 3대, SATA 가상 디스크). 실서버 값으로 단정하지 말고 "랩에서는 ~였다"로 전한다.
- 운영자가 출력을 주지 않았으면 **먼저 확인 명령을 주고 출력을 받은 뒤** 조치를 고른다. 출력 없이 조치부터 권하지 않는다.
- `[주의]` 가 붙은 조치는 실행 전에 조건을 운영자에게 확인받는다. 조건을 확인하지 못했으면 실행하라고 하지 않는다.
- 이 문서에 없는 상황(아래 7절)은 추측해서 답하지 말고 "검증되지 않았다"고 말한다.
- 명령의 `<…>` 는 운영자 환경 값으로 바꿔야 한다. 값을 지어내지 않는다.

### 1. 알아야 할 사실

#### 1.1 Longhorn V2 디스크

- V2 엔진은 파티션·파일시스템이 없는 **블록 디스크 전체**를 쓴다(`diskType: block`).
- Longhorn 은 디스크를 등록한 **경로 문자열**로 찾는다. 디스크 안의 데이터(lvstore)는 **UUID** 로 식별한다.
- `/dev/sdX` 는 커널이 부팅 때 발견 순서대로 붙이는 이름이라 재부팅하면 바뀔 수 있다. 바뀌면 Longhorn 은 옛 경로에서 디스크를 못 찾는다.
- `/dev/disk/by-id/wwn-0x…` 는 디스크 고유값에서 만들어져 바뀌지 않는다.
- `/dev/disk/by-id/ata-…_<번호>`, `scsi-0ATA_…_<번호>` 의 끝 번호는 랩(VMware SATA)에서 **포트 번호**였다. 디스크를 다른 포트로 옮기면 바뀐다. **`wwn-` 을 우선한다.**
- `wwn-` 이 없으면 `/dev/disk/by-path/…` 를 쓴다. VM 의 디스크 슬롯 구성을 바꾸지 않는 한 고정이다.
- Longhorn 은 UUID 가 맞지 않는 디스크에 쓰지 않는다. 랩에서 `/dev/sdc` 가 빈 디스크를 가리켰을 때 그 디스크는 그대로 비어 있었다.

#### 1.2 CNPG

- 쓰기를 받는 인스턴스(primary)는 **하나**다. 나머지는 읽기 전용 standby 다.
- 서비스: `<클러스터>-rw` → primary, `<클러스터>-ro` → standby, `<클러스터>-r` → 아무 인스턴스.
- primary 가 죽으면 **operator** 가 standby 하나를 승격시킨다. 파드를 수동으로 지울 필요는 없다. **operator 가 살아 있어야 승격된다.**
- 갑작스러운 장애에서 쓰기 중단 0 은 불가능하다. 줄일 수만 있다.

#### 1.3 랩 실측 수치 (인스턴스 3개, 동기 복제)

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

### 2. 증상별 대응

#### 2.1 재부팅 뒤 V2 디스크가 `Ready=False`, 볼륨 `faulted`, CNPG 파드가 `Init` 에서 멈춤

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

#### 2.2 경로를 고정 경로로 바꾸기 (디스크를 비우지 않는다)

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

#### 2.3 경로를 고쳤는데 5분 넘게 `cannot find lvstore with UUID` `[주의]`

그 노드의 V2 instance-manager 가 잘못 잡은 디스크를 기억하고 있다. 파드를 지워 다시 띄운다.

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'     # 노드별 이름
kubectl -n longhorn-system delete pod <그 노드의 V2 instance-manager 이름>
```

- **조건:** 그 노드의 V2 볼륨이 이미 `faulted`/`detached` 일 때만. 정상 attached 볼륨이 있는 노드에서 지우면 그 볼륨이 끊긴다.
- 랩: 87초 뒤 복구, 데이터 유지.

#### 2.4 primary 노드가 죽었는데 승격이 안 된다

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

#### 2.5 노드가 죽어서 안 돌아오는데 그 노드의 CNPG 인스턴스가 옮겨 가지 않는다

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
## 노드를 살린 뒤 반드시
kubectl taint node <노드> node.kubernetes.io/out-of-service-
```

- **조건:** 그 노드의 전원이 꺼져 있거나 OS 가 확실히 죽었다는 것을 운영자가 확인했을 때만. 살아 있는 노드(네트워크만 끊긴 경우 포함)에 달면 같은 볼륨을 두 노드가 쓰게 될 수 있다.
- 볼륨 복제본이 1개(`numberOfReplicas: 1`, strict-local)면 데이터가 그 노드에만 있으므로 taint 를 달아도 옮겨 갈 수 없다. 이때는 노드 복구를 기다리거나, 그 인스턴스의 PVC 를 지워 CNPG 가 다른 노드에 새로 복제하게 한다. PVC 삭제는 그 인스턴스 데이터를 버리는 일이므로 다른 인스턴스 2개가 정상인지 먼저 확인한다.

#### 2.6 노드를 재부팅·패치해야 한다 (계획된 작업)

primary 가 그 노드에 있으면 먼저 넘긴다.

```bash
kubectl -n <ns> get pods -l cnpg.io/cluster=<클러스터> -L cnpg.io/instanceRole -o wide
kubectl cnpg promote <클러스터> <다른 노드의 replica 이름> -n <ns>          # kubectl-cnpg 플러그인
```

랩: 쓰기 중단 4~6초. 그 다음 노드를 재부팅하고, 2.1 처럼 디스크 Ready 와 인스턴스 Ready 를 확인한 뒤 다음 노드로 넘어간다. **두 노드를 동시에 내리지 않는다.**

#### 2.7 V2 를 켰는데 V2 instance-manager 가 `error`, 파드가 떴다 사라짐

```bash
kubectl -n longhorn-system get settings.longhorn.io data-engine-cpu-mask -o jsonpath='{.value}{"\n"}'
nproc        # 노드에서
```

마스크가 노드의 CPU 전부를 덮으면(예: 2 vCPU 에 `0x3`) Longhorn 이 기동을 거부한다(로그 `SPDK cpu mask 0x3 covers every online CPU`). 파드가 금방 사라져 로그가 안 보이면 2초 간격으로 `kubectl logs` 를 반복해 잡는다.

```bash
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
```

### 3. 처음 설치할 때 권할 것

1. V2 디스크는 처음부터 `/dev/disk/by-id/wwn-…` 로 등록한다.
2. 노드마다 커널 모듈(`vfio_pci`, `uio_pci_generic`, `nvme_tcp`)과 hugepage 2GiB(2MiB × 1024)를 영구 설정하고 kubelet 을 재시작한다.
3. vCPU 가 적으면 V2 CPU 마스크를 노드 CPU 보다 작게 잡는다.
4. CNPG operator 를 2개, 서로 다른 노드에 둔다(4.1).
5. CNPG 는 인스턴스 3개 + 동기 복제. 애플리케이션은 `-rw` 서비스 이름으로만 붙고 재접속하게 한다.

### 4. 설정

#### 4.1 CNPG operator 2개

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

#### 4.2 노드 죽음 판정 단축 `[주의]`

kube-controller-manager `--node-monitor-grace-period` (기본 40초). Kubespray 변수 `kube_controller_node_monitor_grace_period`. 랩에서 20초로 줄이면 쓰기 중단이 58초 → 34초.

- 클러스터 전체에 적용된다. 짧은 네트워크 끊김·노드 멈춤에도 NotReady 가 되어 승격과 파드 이동이 일어난다.
- **권하지 말고 선택지로만 설명한다.** 결정은 운영자가 한다.

#### 4.3 CNPG 클러스터에 넣을 값

```yaml
spec:
  instances: 3
  smartShutdownTimeout: 15        # 계획된 종료 시 승격이 기본 180초 늦어지는 것을 막는다 (V1 랩 실측: 173초 → 21초)
  affinity: {enablePodAntiAffinity: true, topologyKey: kubernetes.io/hostname, podAntiAffinityType: required}
  postgresql:
    synchronous: {method: any, number: 1}
```

### 5. 하지 말 것

- `diskType` 변경, 디스크 이름(키) 변경.
- V2 디스크에 `wipefs` 나 포맷 — 데이터가 사라진다. 2.2 의 경로 교체로 충분하다.
- 살아 있는 노드에 `out-of-service` taint.
- 정상 볼륨이 붙어 있는 노드의 V2 instance-manager 삭제.
- 승격시키려고 primary 파드 삭제. 필요 없고, 노드가 살아 있으면 오히려 계획된 종료 절차를 탄다.
- 두 노드를 동시에 재부팅.
- 랩 수치를 실서버 보장값처럼 말하기.

### 6. 버전

| 이슈 | 내용 | 수정 버전 |
|---|---|---|
| longhorn#12910 | `by-id` 경로 디스크에서 상태 수집 실패 로그 반복 | 1.12.0 (1.11.2 백포트) |
| longhorn#12406 | 노드를 차례로 재부팅하면 V2 볼륨이 attach/detach 반복 | 1.11.0 |
| longhorn#10112 | 노드 재부팅 뒤 V2 볼륨이 detaching/faulted 로 남음 | 1.10.0 |

운영자의 Longhorn 버전이 위보다 낮으면 2.2 를 해도 증상이 남을 수 있다고 알린다.

### 7. 검증되지 않은 것 — 추측으로 답하지 않는다

- 노드 주석(`node.longhorn.io/default-disks-config`)으로 블록 디스크 자동 등록.
- NVMe(BDF 등록)·VirtIO 디스크. 랩은 SATA 라 aio 드라이버였다.
- 실서버 하이퍼바이저에서 `wwn-` 항목이 보이는지.
- 축출 대기(`tolerationSeconds`, 기본 300초)를 줄였을 때의 효과.
- 네트워크만 끊긴 경우(노드는 살아 있음)의 승격과 옛 primary 동작.
- 부하가 걸린 상태에서의 승격 시간.

<!-- 원본: kubespray-cluster/LONGHORN-V2-DISK.md -->

## Longhorn V2: 노드 재부팅 뒤 디스크가 다시 안 붙을 때

V2 데이터 엔진을 쓰는 실서버에서, 워커 노드가 죽었다 살아난 뒤 Longhorn 디스크가 연결 실패로 남는 문제의 원인과 예방법이다.

> **이 문서의 근거 수준.** 2026-11-16 에 이 랩 워커 3대에 V2 엔진을 켜고 재현했다(Longhorn 1.13.0, VMware Fusion arm64 VM, SATA 가상 디스크). 실측 결과는 7절, 노드가 죽었을 때 CNPG 승격·재부착 시간은 [V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md) 에 있다. 랩에서 못 본 것은 `[확인]` 으로 남겼다. 근거 링크는 맨 아래에 있다.

### 1. 증상

- 노드에 디스크가 `sda` ~ `sde` 처럼 여러 개 있고, 그중 하나(예: `sde`)를 통째로 V2 디스크로 등록했다.
- 노드를 재부팅하면 Longhorn 노드 화면에서 그 디스크가 연결 실패로 남고, 그 노드의 복제본이 올라오지 않는다.

### 2. 원인

- `/dev/sdX` 이름은 디스크 고유의 이름이 아니다. 부팅할 때 커널이 디스크를 인식한 순서대로 붙이는 이름이라, 재부팅하면 `sde` 였던 디스크가 `sdd` 나 `sdf` 가 될 수 있다.
- Longhorn 은 등록된 경로(`path: /dev/sde`)를 그대로 다시 연다. 이름이 밀리면 다른 디스크를 열게 되고, 그 디스크에는 Longhorn 의 저장 영역이 없으므로 실패한다.
- **라벨로 해결되지 않는 이유.**
  - V2 디스크는 파일시스템 없이 원판을 통째로 쓴다. 그래서 `/dev/disk/by-label`, `/dev/disk/by-uuid` 항목이 생기지 않는다.
  - 쿠버네티스 노드 라벨과 Longhorn 디스크 태그는 볼륨을 어디에 둘지 고르는 용도다. 어느 장치가 그 디스크인지는 정해 주지 않는다.

### 3. 해결: 처음부터 바뀌지 않는 경로로 등록한다

리눅스는 디스크 고유 번호에 묶인 경로를 `/dev/disk/by-id/` 에 만들어 둔다. 이 경로는 재부팅해도 같은 디스크를 가리킨다. Longhorn 이슈 #12910 도 이 방식을 재부팅에 안정적인 권장 방식이라고 적고 있다.

#### 3.1 고정 경로 찾기 (노드에서)

지금 V2 로 쓰는 디스크가 `sde` 라면:

```bash
DEV=sde
for l in /dev/disk/by-id/*; do
  [ "$(readlink -f "$l")" = "/dev/$DEV" ] && echo "$l"
done | grep -v -- '-part'
```

- `wwn-…` 또는 `scsi-…` 로 시작하는 줄을 쓴다. 둘 다 디스크 고유 번호다.
- **아무것도 안 나오면** 하이퍼바이저가 디스크 고유 번호를 VM 에 넘겨주지 않는 것이다. 이때는 `/dev/disk/by-path/` 를 같은 방법으로 찾아 쓴다. VM 의 디스크 슬롯 구성을 바꾸지 않는 한 고정된다. `[확인]` 실서버 VM 에서 `by-id` 항목이 보이는지(랩의 VMware SATA 디스크는 보였다).
- **`wwn-` 으로 시작하는 이름을 쓴다.** 랩에서 `ata-…_03000000000000000001` 처럼 일련번호가 붙은 이름은 디스크가 아니라 **포트 번호**에서 만들어진 값이었다(세 노드가 전부 같은 값). 디스크를 다른 포트로 옮기면 이 이름도 따라 바뀐다. `wwn-0x…` 는 디스크마다 달랐고 포트를 바꿔도 그대로였다.
- 디스크가 맞는지는 `lsblk -o NAME,SIZE,SERIAL,WWN` 으로 크기와 시리얼을 대조한다.

#### 3.2 kubectl 판: 노드마다 등록

```bash
NODE=<노드 이름>
DISK=/dev/disk/by-id/<3.1 에서 찾은 이름>

kubectl -n longhorn-system patch node.longhorn.io "$NODE" --type merge -p "{
  \"spec\": {\"disks\": {\"v2-disk\": {
    \"path\": \"$DISK\", \"diskType\": \"block\",
    \"allowScheduling\": true, \"evictionRequested\": false,
    \"storageReserved\": 0, \"tags\": []
  }}}
}"

kubectl -n longhorn-system get node.longhorn.io "$NODE" -o jsonpath='{.status.diskStatus.v2-disk.conditions}'
```

#### 3.3 Helm 판: 노드를 추가할 때 자동으로 등록

Longhorn 은 노드의 라벨과 주석을 보고 디스크를 자동 등록하는 기능이 있다. 노드를 넣을 때마다 손으로 편집하지 않아도 된다.

values:

```yaml
defaultSettings:
  createDefaultDiskLabeledNodes: true
```

노드마다(Longhorn 이 그 노드를 처음 볼 때 적용된다):

```bash
kubectl label node "$NODE" node.longhorn.io/create-default-disk=config
kubectl annotate node "$NODE" node.longhorn.io/default-disks-config="[{\"name\":\"v2-disk\",\"path\":\"$DISK\",\"diskType\":\"block\",\"allowScheduling\":true}]"
```

- 이 주석은 **그 노드에 등록된 디스크와 태그가 하나도 없을 때만** 적용된다. 이미 디스크가 등록된 노드는 3.2 또는 4절로 바꾼다.
- 주석이 검증에 실패하면 통째로 무시된다. 적용 뒤 `node.longhorn.io` 의 `spec.disks` 에 들어갔는지 확인한다.
- `[확인]` 주석에 `diskType: block` 을 넣는 형태는 소스에 block 분기가 있는 것만 확인했다. 실서버에서 한 노드로 먼저 시험한다.

### 4. 이미 `/dev/sdX` 로 등록한 노드 바꾸기

1. Longhorn 노드 화면에서 그 디스크의 스케줄링을 끄고 복제본을 다른 노드로 비운다(Eviction Requested).
2. 디스크에 복제본이 0 이 되면 디스크를 제거한다. 스케줄링이 켜져 있거나 복제본이 남아 있으면 Longhorn 이 제거를 거부한다.
3. 3.2 의 명령으로 `by-id` 경로를 써서 다시 추가한다.

**더 간단한 방법: 디스크를 비우지 않고 `path` 만 고친다 (랩 실측, 7절).** 디스크 안의 데이터(lvstore)는 UUID 로 식별되므로 경로만 바꿔도 그대로 인식했다.

```bash
NODE=<노드>; DISK=/dev/disk/by-id/wwn-0x…        # 3.1 에서 찾은 값
kubectl -n longhorn-system patch nodes.longhorn.io "$NODE" --type merge \
  -p "{\"spec\":{\"disks\":{\"v2-disk\":{\"path\":\"$DISK\"}}}}"     # v2-disk = 등록할 때 쓴 디스크 이름
```

- 정상 동작 중인 노드(볼륨 attached, CNPG primary 보유): 6초 뒤 반영, 3초 간격 쓰기 30번 중 실패 0.
- 이름이 밀려 `Ready=False` 가 된 노드: 약 60초 뒤 디스크 Ready, 볼륨 attached, CNPG 3/3. 데이터 유지.
- **그래도 안 돌아오면 그 노드의 V2 instance-manager 파드를 지운다.** `/dev/sdX` 가 다른 디스크를 가리키게 된 경우(7절 A4), 경로를 고친 뒤에도 `cannot find lvstore with UUID …` 가 반복됐다. instance-manager 가 잘못 잡은 디스크를 기억하고 있어서다. 파드를 지우면 다시 떠서 87초 뒤 3/3 으로 돌아왔다. 그 노드의 V2 볼륨이 잠깐 끊기므로 이미 `faulted` 인 노드에서만 한다.

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'          # 노드별 V2 instance-manager 이름
kubectl -n longhorn-system delete pod <그 노드의 instance-manager 이름>
```

### 5. 재부팅 뒤 점검 순서

```bash
kubectl -n longhorn-system get node.longhorn.io <노드> -o yaml   # spec.disks 의 path, status.diskStatus 의 conditions 메시지
lsblk -o NAME,SIZE,SERIAL,WWN                                    # 노드에서: 등록된 경로의 장치가 원래 디스크인지
ls -l /dev/disk/by-id/ | grep -v -- '-part'                      # 노드에서: 고정 이름이 지금 어느 sdX 를 가리키는지
```

- 등록된 경로가 `/dev/sdX` 이고 그 장치의 크기나 시리얼이 원래 디스크와 다르면 이름이 밀린 것이다. 3절로 간다.
- 경로가 `by-id` 인데도 실패하면 이름 문제가 아니다. 6절의 버전 문제와 V2 전제 조건(hugepage, 커널 모듈이 부팅 때 올라오는지)을 본다.

### 6. 버전에 따른 주의

| 이슈 | 내용 | 수정 버전 |
|---|---|---|
| #12910 | `by-id` 경로로 등록한 V2 디스크의 상태 수집이 실패 로그를 반복한다 | 1.12.0, 1.11.2 |
| #12406 | 노드를 차례로 재부팅하면 V2 볼륨이 attach/detach 를 반복한다 | 1.11.0 |
| #10112 | 노드 재부팅 뒤 V2 볼륨이 detaching/faulted 로 남는다 | 1.10.0 |

`[확인]` 실서버의 Longhorn 버전. 위 수정 버전보다 낮으면 경로를 고친 뒤에도 재부팅 장애가 남을 수 있다.

### 7. 랩 실측 (2026-11-16)

구성: 워커 3대(5GB, 2 vCPU)에 빈 SATA 디스크 2개(1GB dummy, 10GB V2 용)를 붙였다. 게스트에서 `sda`=OS, `sdb`=dummy, `sdc`=V2. V2 볼륨 위에 CNPG 3 인스턴스(`v2test/pg-v2.yaml`, 스토리지 1벌 strict-local)를 올렸다. dummy 를 떼거나 포트를 맞바꿔 재부팅하면 이름이 밀린다(`Vagrantfile` 의 `V2_NO_DUMMY`, `V2_SWAP`). 기록 원문은 `v2test/results/`, 재현 순서는 [v2test/README.md](v2test/README.md).

| 시험 | 한 일 | 결과 |
|---|---|---|
| A1 | `/dev/sdc` 로 등록 → dummy 를 떼고 재부팅 (V2 디스크가 `sdb` 로) | 디스크 `Ready=False`(`failed to detect disk device /host/dev/sdc`), 볼륨 `faulted`, CNPG 파드 `Init` 에서 6분 넘게 정지. 30초마다 재시도만 반복 |
| A2 | A1 상태에서 `path` 만 `by-id` 로 교체 | 약 60초 뒤 3/3, 데이터 유지 |
| A3 | `by-id` 로 등록된 채 dummy 를 다시 붙여 재부팅 (`sdb` → `sdc`) | 손대지 않고 노드 기동 119초 뒤 3/3 |
| A4 | `/dev/sdc` 로 등록 → 포트를 맞바꿔 재부팅 (`/dev/sdc` = 빈 디스크) | Longhorn 이 거부(`cannot find lvstore with UUID …`). 빈 디스크에는 아무것도 쓰지 않았다(앞 4MB 가 전부 0) |
| A5 | A4 상태에서 `path` 만 `by-id` 로 교체 | 5분 동안 그대로 `Ready=False` |
| A6 | A5 뒤 그 노드의 V2 instance-manager 파드 삭제 | 87초 뒤 3/3, 데이터 유지 |
| A7 | 정상 노드(primary 보유)에서 `path` 만 `by-id` 로 교체 | 6초 뒤 반영, 쓰기 실패 0 |

V2 를 켤 때 걸린 것 하나: 워커가 2 vCPU 면 V2 instance-manager 가 뜨지 않는다. 기본 `data-engine-cpu-mask` 가 `0x3`(코어 2개)이라 `SPDK cpu mask 0x3 covers every online CPU` 로 거부한다. 코어 하나만 주면 뜬다.

```bash
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
## Helm 판: defaultSettings.dataEngineCpuMask 에 같은 값 — [확인] 차트 키 이름은 values.yaml 에서 확인한다
```

못 본 것: 3.3 의 주석 자동 등록(`diskType: block`), NVMe·VirtIO 디스크(랩은 SATA → aio 드라이버), 실서버 하이퍼바이저에서의 `by-id`.

### 8. 근거

- Longhorn 문서, V2 Data Engine Quick Start — "Add block-type Disks in Longhorn Nodes": https://longhorn.io/docs/1.10.0/v2-data-engine/quick-start/
- Longhorn 문서, Configuring Defaults for Nodes and Disks (라벨·주석으로 디스크 자동 등록): https://longhorn.io/docs/1.10.0/nodes-and-volumes/nodes/default-disk-and-node-config/
- Longhorn 이슈 #12910 (by-id 경로와 권장 방식 언급): https://github.com/longhorn/longhorn/issues/12910
- Longhorn 이슈 #12406, #10112 (재부팅 뒤 V2 볼륨 장애): https://github.com/longhorn/longhorn/issues/12406 , https://github.com/longhorn/longhorn/issues/10112
- longhorn-manager v1.10.0 `webhook/resources/node/validator.go` (디스크 제거 조건, 종류 변경 금지), `types/types.go` 의 `CreateDisksFromAnnotation` (주석의 block 분기)

<!-- 원본: kubespray-cluster/V2-CNPG-FAILOVER.md -->

## V2 볼륨 위의 CNPG: 노드가 죽었을 때 승격·쓰기 중단·재부착

노드가 갑자기 죽었을 때 세 가지를 쟀다. 쓰기가 얼마나 끊기는지, 새 primary 가 뜨려면 파드를 죽여 줘야 하는지, 죽은 노드의 인스턴스가 다시 붙는 데 왜 오래 걸리는지.

> **근거 수준.** 2026-11-16 랩 실측이다. 워커 3대(5GB, 2 vCPU), Longhorn 1.13.0 V2 엔진, CNPG operator 1.30.1, PostgreSQL 16. 각 시험은 1번씩만 했다(switchover 만 3번). 실서버는 노드 수·디스크·네트워크가 달라 숫자가 그대로 나오지 않는다. 기록 원문은 `v2test/results/`, 시험에 쓴 파일과 재현 순서는 [v2test/](v2test/README.md).

### 1. 결론

- **쓰기 중단 0 은 안 된다.** PostgreSQL 은 쓰기를 받는 인스턴스(primary)가 하나다. 그 노드가 죽으면 판정 → 승격 → `-rw` 서비스 전환이 끝날 때까지 쓰기를 받을 곳이 없다. 줄일 수는 있다.
- **승격에 파드 삭제는 필요 없다.** 아무것도 건드리지 않아도 operator 가 승격시킨다. 단, **operator 가 살아 있어야 한다.**
- **operator 가 죽은 노드에 같이 있으면 쓰기가 6분 넘게 끊긴다.** operator 를 2개로 늘려 다른 노드에 두면 1분 안팎으로 줄어든다.
- **읽기(`-ro`)는 standby 가 살아 있는 한 끊기지 않는다.**
- **죽은 노드의 인스턴스는 다른 노드로 옮겨 가지 않는다.** 파드가 `Terminating` 에 걸려 볼륨이 풀리지 않는다. 노드가 돌아오거나, 죽은 노드에 `out-of-service` taint 를 달아야 풀린다.

### 2. 쓰기 중단 실측

1초마다 `-rw` 서비스에 INSERT, `-ro` 서비스에 SELECT 를 한 번씩 하는 파드(`v2test/probe.yaml`)로 쟀다. 노드는 `vagrant halt --force`(전원 차단)로 껐고 파드는 건드리지 않았다.

| 시험 | 상황 | 쓰기 중단 | 읽기 중단 |
|---|---|---|---|
| C1 | primary 노드 정지. operator 1개가 **같은 노드**에 있었다 | 6분 26초 | 없음 |
| C2 | primary 노드 정지. operator 2개, 리더는 다른 노드 | 86초 | (아래 주) |
| C3 | primary 노드 정지. operator 2개, **리더가 같은 노드** | 58초 | 없음 |
| C4 | C2 와 같고 노드 죽음 판정을 40초 → 20초로 | 34초 | 없음 |
| S1~S3 | 계획된 전환(switchover) 3번 | 4~6초 | 없음 |

- C1 에서 일어난 일: operator 파드도 죽은 노드에 있어서 300초 축출 대기 뒤에야 다른 노드에 새로 떴다. 새 operator 가 리더가 된 직후(로그 `Current primary isn't healthy, initiating a failover`) 승격했다. 그 전 6분 동안 standby 둘은 멀쩡했지만 승격을 지시할 주체가 없었다.
- C3 가 C2 보다 짧은 이유는 확인하지 못했다. 1번씩만 쟀으므로 "operator 가 2개면 1분 안팎"으로만 읽는다.
- C2 의 주: 이 시험은 인스턴스 2개짜리 클러스터였다. 승격 뒤 standby 가 하나도 없어서 `-ro` 가 노드 복귀까지 4분 19초 동안 응답하지 않았다. 인스턴스 3개 클러스터(C1·C3·C4)에서는 읽기 실패가 없었다.

### 3. 죽은 노드의 인스턴스가 다시 붙기까지

#### 3.1 노드가 돌아오는 경우

노드 Ready 뒤 인스턴스가 다시 Ready 가 되기까지 80~169초였다(7번, 80초는 인스턴스 2개·3벌 볼륨인 C2). 디스크 상태까지 기록한 4번(A3·B1·B2·C1)을 나누면, V2 디스크가 `Ready` 가 되기까지 81~98초(V2 instance-manager 가 뜨고 디스크를 다시 읽는다), 그 뒤 볼륨 attach 와 PostgreSQL 기동·복제 재개까지 27~71초였다(71초는 파드가 `Terminating` 을 한 번 오간 B2).

디스크를 `/dev/sdX` 로 등록했고 이름이 밀렸다면 여기서 영영 안 돌아온다([LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md)).

#### 3.2 노드가 안 돌아오는 경우 (시험 B2, B3)

3벌 복제 V2 볼륨 위의 CNPG 인스턴스가 있는 노드를 끄고 13분 동안 두었다. 옮겨 갈 빈 노드가 있었는데도 옮겨 가지 않았다.

| 시각 | 상태 |
|---|---|
| +43초 | 노드 NotReady, 인스턴스 1개 빠짐 |
| +340초 | 파드 `Terminating` (300초 축출 대기 뒤) |
| +780초 | 여전히 `Terminating`. VolumeAttachment 가 죽은 노드에 그대로 |

- 원인: 죽은 노드의 kubelet 이 "파드를 내렸다"고 답하지 못해 파드 객체가 지워지지 않는다. 파드가 남아 있으니 볼륨도 그 노드에 붙어 있는 것으로 남고, CNPG 는 같은 이름의 새 파드를 만들지 못한다.
- Longhorn 의 `node-down-pod-deletion-policy` 는 `delete-both-statefulset-and-deployment-pod` 였는데도 지워 주지 않았다. CNPG 파드는 StatefulSet 도 Deployment 도 아니고 `Cluster` 가 직접 소유한다.
- **해결: 죽은 노드에 `out-of-service` taint.** 달자마자 5초 뒤 다른 노드에 파드가 생겼고 27초 뒤 Ready 였다.

```bash
## 그 노드의 전원이 확실히 꺼져 있을 때만. 살아 있는데 달면 같은 볼륨을 두 곳에서 쓰게 된다
kubectl taint node <죽은 노드> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
## 노드를 다시 살린 뒤에는 반드시 뗀다
kubectl taint node <노드> node.kubernetes.io/out-of-service-
```

- 스토리지가 1벌(strict-local)이면 볼륨이 그 노드에만 있으므로 taint 를 달아도 옮겨 갈 수 없다. 이때는 노드가 돌아오기를 기다리거나, 그 인스턴스의 PVC 를 지워 CNPG 가 다른 노드에 새로 복제하게 한다(랩 `scripts/61-db-move-instance.sh`, V1 에서 실측).
- 노드 복귀 뒤 3벌 볼륨은 약 2분 뒤 `degraded` → `healthy` 로 돌아왔다(2GB 볼륨, 복제본 재구축).

### 4. 줄이는 방법

효과가 큰 순서다.

#### 4.1 operator 를 2개로, 서로 다른 노드에 (6분대 → 1분 안팎)

Helm 판 (`v2test/cnpg-operator-ha.yaml`):

```yaml
replicaCount: 2
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: kubernetes.io/hostname
      labelSelector: {matchLabels: {app.kubernetes.io/name: cloudnative-pg}}
```

```bash
helm upgrade cnpg cnpg/cloudnative-pg -n cnpg-system --version 0.29.1 --reuse-values -f v2test/cnpg-operator-ha.yaml --wait
```

kubectl 판 (같은 결과, 랩에서는 Helm 판만 실행했다):

```bash
kubectl -n cnpg-system scale deploy cnpg-cloudnative-pg --replicas=2
kubectl -n cnpg-system patch deploy cnpg-cloudnative-pg --type merge -p '{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"topologyKey":"kubernetes.io/hostname","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"cloudnative-pg"}}}]}}}}}}'
```

operator 는 한 번에 하나만 일한다(리더 선출, lease 15초). 리더가 죽으면 다른 하나가 이어받는다.

#### 4.2 계획된 작업은 먼저 switchover (4~6초)

노드 재부팅·패치 전에 primary 를 다른 인스턴스로 넘긴다.

```bash
kubectl cnpg promote <클러스터> <새 primary 인스턴스> -n <네임스페이스>     # kubectl-cnpg 플러그인
```

랩에서는 플러그인 없이 같은 동작을 하는 status 패치로 쟀다(`v2test/results/S1.log`). 실서버에서는 플러그인 명령을 쓴다.

#### 4.3 노드 죽음 판정 시간 줄이기 (86초 → 34초)

kube-controller-manager 의 `--node-monitor-grace-period`(기본 40초)를 20초로 줄였을 때다. Kubespray 변수는 `kube_controller_node_monitor_grace_period` (`kubespray/roles/kubernetes/control-plane/defaults/main/main.yml:104`).

- 대가: 20초 넘는 네트워크 끊김·노드 멈춤에도 NotReady 가 되고 승격이 일어난다. 클러스터 전체에 적용되는 값이다.
- 랩에서는 control plane 3대의 매니페스트를 직접 고쳐 쟀고 시험 뒤 40초로 되돌렸다. 인벤토리에는 넣지 않았다.

#### 4.4 그 밖에

- **동기 복제는 켜 둔다**(`postgresql.synchronous`). 중단 시간은 못 줄이지만 승격 뒤에도 커밋된 쓰기가 남는다.
- **애플리케이션은 `-rw` 서비스 이름으로만 붙고 재접속하게 한다.** 승격이 끝나면 같은 이름이 새 primary 를 가리킨다. Harbor 는 재접속한다.
- **V2 디스크는 `by-id` 로 등록한다.** 아니면 3.1 의 재부착이 끝나지 않는다.

### 5. 못 본 것

- 각 시험 반복(1번씩만 쟀다), 부하가 걸린 상태에서의 승격 시간.
- 300초 축출 대기(`tolerationSeconds`)를 줄였을 때. operator 가 1개여도 이 값이 줄면 C1 의 6분이 줄어들 것으로 보이지만 재지 않았다.
- 네트워크만 끊긴 경우(노드는 살아 있고 통신만 안 됨). 옛 primary 가 계속 쓰기를 받는지는 다른 문제다.
- 실서버 하이퍼바이저·디스크에서의 V2 디스크 Ready 시간.

<!-- 원본: kubespray-cluster/v2test/README.md -->

## Longhorn V2 + CNPG 시험 재현 (2026-11-16)

[LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md) 7절과 [V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md) 의 숫자를 낸 시험을 그대로 다시 하는 순서다. 원본 기록은 [results/](v2test/results/) 에 있다.

### 0. 시험 구성

| 항목 | 값 |
|---|---|
| 호스트 | 32GB Apple Silicon Mac, VMware Fusion, Vagrant 2.4.9 |
| 노드 | ToR 1, control plane 3(2560MB), 워커 3(**5120MB**, 2 vCPU). ks-w4·w5 는 꺼 둠 |
| OS / 커널 | Ubuntu 24.04.3, 6.8.0-86-generic (arm64) |
| 쿠버네티스 | v1.36.4 (Kubespray), Cilium 1.20.2 |
| Longhorn | 1.13.0, V1 + V2 엔진 동시 사용 |
| CNPG | operator 1.30.1 (차트 0.29.1), PostgreSQL 16.15 |
| V2 디스크 | 워커마다 빈 SATA 가상 디스크 2개: dummy 1GB(`sdb`), V2 용 10GB(`sdc`). Longhorn 은 aio 드라이버로 잡았다 |

메모리 합계는 약 23.5GB. 시험 중 Docker Desktop 이 켜져 있었고 Mac 스왑은 3.7~3.9GB 로 늘지 않았다.

### 1. VM 준비

```bash
./scripts/v2-disks.sh ks-w1 ks-w2 ks-w3          # v2disks/<노드>-{dummy,data}.vmdk 생성 (VMware vdiskmanager)
vagrant up ks-tor ks-cp1 ks-cp2 ks-cp3
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up ks-w1 ks-w2 ks-w3
./scripts/lab-proxy.sh
```

`Vagrantfile` 의 V2 관련 환경 변수 (모두 기본은 꺼짐):

| 변수 | 하는 일 |
|---|---|
| `V2_NODES` | 적은 워커만 메모리를 `V2_MEM`(기본 5120)으로 올리고 디스크 2개를 SATA 포트 2·3 에 붙인다 |
| `V2_NO_DUMMY` | 적은 노드는 dummy(포트 2)를 뗀다 → V2 디스크가 `sdc` 에서 `sdb` 로 당겨진다 |
| `V2_SWAP` | 적은 노드는 포트 2·3 의 디스크를 맞바꾼다 → `/dev/sdc` 가 빈 dummy 를 가리킨다 |

**`V2_NODES` 를 빼고 `vagrant up/halt/reload` 하면 메모리가 2688MB 로 돌아가고 V2 디스크가 떨어진다.**

게스트에서 본 디스크 (ks-w1):

```
sda 64G  wwn-0x5000c29bdbf10663   ← OS (세 노드가 같은 값: 같은 박스 이미지에서 복제)
sdb  1G  wwn-0x5000c292fc5b08d5   ← dummy
sdc 10G  wwn-0x5000c295b2303f66   ← V2
ata-VMware_Virtual_SATA_Hard_Drive_03000000000000000001 → sdc   ← 끝 번호는 포트 번호. 세 노드가 같다
pci-0000:01:00.0-ata-4 → sdc
```

### 2. 노드 준비 (Longhorn 1.13 문서 "V2 Data Engine Requirements")

```bash
./scripts/v2-node-prep.sh ks-w1 ks-w2 ks-w3
```

노드마다 하는 일:

```bash
apt-get install -y linux-modules-extra-$(uname -r)
printf 'vfio_pci\nuio_pci_generic\nnvme_tcp\n' > /etc/modules-load.d/longhorn-v2.conf
modprobe vfio_pci uio_pci_generic nvme_tcp
echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/90-longhorn-v2-hugepages.conf     # 2MiB × 1024 = 2GiB
sysctl -p /etc/sysctl.d/90-longhorn-v2-hugepages.conf
systemctl restart kubelet                                                       # 노드 allocatable 에 hugepages-2Mi: 2Gi 가 보여야 한다
```

문서는 GRUB 의 `hugepagesz=2M hugepages=1024` 로 영구 설정하라고 한다. 랩은 sysctl 로 넣었고 재부팅 뒤에도 1024 로 잡혔다(5GB 노드라 연속 메모리가 남아 있었다).

### 3. 시험 전에 내려 둔 것

메모리를 비우려고 Harbor 를 멈췄다.

```bash
kubectl -n harbor scale deploy --all --replicas=0
kubectl -n harbor scale sts --all --replicas=0
kubectl -n harbor annotate cluster harbor-pg cnpg.io/hibernation=on --overwrite
```

되돌리기: ks-w4·w5 를 켜고 `cnpg.io/hibernation=off`, `./scripts/addon.sh harbor`.

### 4. Longhorn V2 켜기

```bash
kubectl -n longhorn-system patch settings.longhorn.io v2-data-engine --type merge -p '{"value":"true"}'
## 2 vCPU 노드는 아래가 없으면 V2 instance-manager 가 안 뜬다 (TROUBLESHOOTING 27절)
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'    # 세 노드 running
```

그대로 둔 V2 관련 기본값: `data-engine-hugepage-enabled={"v2":"true"}`, `data-engine-memory-size={"v2":"2048"}`, `data-engine-cpu-isolation-enabled={"v2":"true"}`, `engine-replica-timeout=8`, `node-down-pod-deletion-policy=delete-both-statefulset-and-deployment-pod`, `auto-delete-pod-when-volume-detached-unexpectedly=true`.

디스크 등록 (A 시험은 일부러 `/dev/sdc` 로 시작했다):

```bash
for n in ks-w1 ks-w2 ks-w3; do
  kubectl -n longhorn-system patch nodes.longhorn.io $n --type merge -p '{"spec":{"disks":{"v2-disk":{
    "path":"/dev/sdc","diskType":"block","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":[]}}}}'
done
```

### 5. 시험용 리소스

```bash
kubectl create ns v2test
kubectl apply -f v2test/sc-v2.yaml          # longhorn-v2-single(1벌, strict-local), longhorn-v2(3벌)
kubectl apply -f v2test/pg-v2.yaml          # 인스턴스 3, 동기 복제(any 1), 1벌 볼륨
kubectl apply -f v2test/pg-r3.yaml          # 인스턴스 2, 3벌 볼륨 (B2·B3 용: 옮겨 갈 빈 노드가 있다)
kubectl apply -f v2test/probe.yaml          # pg-v2 에 1초마다 -rw INSERT / -ro SELECT. ks-w1 고정
```

`probe2`(pg-r3 용)는 `probe.yaml` 에서 이름·노드(ks-w3)·서비스 이름만 바꿔 띄웠다:

```bash
sed -e 's/name: probe, /name: probe2, /' -e 's/nodeName: ks-w1/nodeName: ks-w3/' \
    -e 's/pg-v2-app/pg-r3-app/' -e 's/pg-v2-rw/pg-r3-rw/g' -e 's/pg-v2-ro/pg-r3-ro/g' v2test/probe.yaml | kubectl apply -f -
```

보조 스크립트:

| 파일 | 하는 일 |
|---|---|
| `state.sh <노드>` | 한 줄 상태: 노드 Ready, V2 디스크 Ready/경로/UUID, V2 볼륨, CNPG ready/primary, 파드. `CL`(클러스터), `VOLF`(볼륨 이름 필터) 환경 변수 |
| `watch.sh <노드> <최대 초> [끝 조건]` | `state.sh` 를 5초마다 돌려 바뀔 때만 출력 |
| `probe-report.sh [기간]` | 프로브 로그에서 쓰기/읽기 연속 실패 구간 추출. `PROBE=probe2` 로 다른 프로브 |

### 6. 디스크 이름 밀림 (A1~A7)

| 시험 | 명령 |
|---|---|
| A1 | `V2_NODES=… vagrant halt ks-w3; V2_NODES=… V2_NO_DUMMY=ks-w3 vagrant up ks-w3` 후 `watch.sh ks-w3 360` |
| A2 | `by-id` 찾기 → `path` 만 패치 (아래) |
| A3 | `V2_NODES=… vagrant halt ks-w3; V2_NODES=… vagrant up ks-w3` (dummy 다시 붙임) |
| A4 | `V2_NODES=… vagrant halt ks-w1; V2_NODES=… V2_SWAP=ks-w1 vagrant up ks-w1` |
| A5 | ks-w1 `path` 만 패치 |
| A6 | `kubectl -n longhorn-system delete pod <ks-w1 의 V2 instance-manager>` |
| A7 | 정상 노드 ks-w2 에서 `path` 만 패치, 3초 간격 INSERT 30번 |

`by-id` 찾기와 경로 교체:

```bash
W=$(ssh -F inventory/lab/ssh.cfg ks-w3 'for l in /dev/disk/by-id/wwn-*; do [ "$(readlink -f $l)" = /dev/sdb ] && echo $l; done')
kubectl -n longhorn-system patch nodes.longhorn.io ks-w3 --type merge -p "{\"spec\":{\"disks\":{\"v2-disk\":{\"path\":\"$W\"}}}}"
```

A4 뒤 빈 디스크에 쓰였는지 확인한 방법:

```bash
for d in sdb sdc; do echo "$d $(sudo head -c 8 /dev/$d | tr -dc '[:print:]') nonzero=$(sudo head -c 4194304 /dev/$d | tr -d '\000' | wc -c)"; done
## sdb SPDKBLOB nonzero=552   ← 원래 V2 디스크
## sdc          nonzero=0     ← 빈 디스크. 쓰이지 않았다
```

### 7. 노드 장애와 승격 (B1~B3, C1~C4, S1~S3)

| 시험 | 명령 | 그때 구성 |
|---|---|---|
| B1 | primary 노드 `vagrant halt --force`, 7분 뒤 `up` (프로브 전) | operator 1개 |
| B2·B3 | `v2test/b2.sh`: pg-r3-2 노드 강제 정지 → 13분 관찰 → `out-of-service` taint → 기동 후 taint 제거 | operator 1개 |
| C1 | `v2test/c1.sh`: pg-v2 primary 노드 강제 정지, 7분 관찰 | operator 1개(우연히 죽인 노드에 있었다) |
| C2 | `PROBE=probe2 v2test/c2.sh pg-r3 240` | operator 2개 (아래 4.1) |
| C3 | `PROBE=probe v2test/c2.sh pg-v2 240` | operator 2개, 리더가 죽인 노드에 있었다 |
| C4 | 판정 시간 20초로 바꾼 뒤 `v2test/c2.sh pg-v2 150` | operator 2개 |
| S1~S3 | 아래 switchover 패치 3번, 60초 간격 | operator 2개 |

operator 2개 (C2 부터):

```bash
helm repo update cnpg
helm upgrade cnpg cnpg/cloudnative-pg -n cnpg-system --version 0.29.1 --reuse-values -f v2test/cnpg-operator-ha.yaml --wait
```

노드 죽음 판정 40초 → 20초 (C4 만, 시험 뒤 되돌림):

```bash
for c in ks-cp1 ks-cp2 ks-cp3; do
  ssh -F inventory/lab/ssh.cfg $c 'sudo sed -i "s/--node-monitor-grace-period=40s/--node-monitor-grace-period=20s/" /etc/kubernetes/manifests/kube-controller-manager.yaml'
done
## 되돌리기: 20s → 40s 로 같은 명령. 영구 적용은 Kubespray 변수 kube_controller_node_monitor_grace_period
```

switchover (S1~S3). 실서버에서는 `kubectl cnpg promote <클러스터> <인스턴스>` 를 쓴다. 랩에서는 플러그인을 받지 않고 플러그인이 하는 것과 같은 status 패치를 했다:

```bash
T=<새 primary 로 만들 replica 이름>
kubectl -n v2test patch cluster pg-v2 --subresource=status --type merge -p "{\"status\":{
  \"targetPrimary\":\"$T\",\"targetPrimaryTimestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)\",
  \"phase\":\"Switchover in progress\",\"phaseReason\":\"Switching over to $T\"}}"
```

### 8. 결과 파일

| 파일 | 내용 |
|---|---|
| `results/boot.log` | VM 기동 시각 |
| `results/A1.log` ~ `A7.log` | 디스크 이름 밀림 시험. A1 에 오류 메시지 원문 |
| `results/B1.log`, `B2.log` | primary 노드 정지(프로브 전), 3벌 볼륨 13분 관찰 + taint |
| `results/C1.log` ~ `C4.log` | 승격 시험. 끝에 프로브 실패 구간(UTC) |
| `results/S1.log` | switchover 3번과 쓰기 실패 구간 |

로그의 시각은 KST, 프로브 구간만 UTC 다(9시간 차이). 같은 B2 이름으로 남은 첫 실행은 스크립트 종료 조건 실수로 노드가 30초만 꺼졌다 켜져 무효이고, `B2.log` 는 다시 돌린 것이다.

### 9. 정리

```bash
kubectl delete ns v2test
kubectl delete sc longhorn-v2 longhorn-v2-single
## V2 디스크를 Longhorn 노드에서 빼려면: allowScheduling=false → 복제본 0 확인 → spec.disks 에서 v2-disk 삭제
vagrant halt                                   # 다음에 켤 때도 워커 3대는 V2_NODES 를 붙인다
```

<!-- 원본: kubespray-cluster/TROUBLESHOOTING.md 27~29절 -->

## 진단 기록 (TROUBLESHOOTING 27~29절)

### 27. V2 엔진을 켰는데 instance-manager 가 뜨자마자 죽는다: 2 vCPU 노드와 기본 CPU 마스크 [실서버 영향: vCPU 가 적은 노드]

- 증상: `v2-data-engine=true` 로 바꾼 뒤 V2 `instancemanagers.longhorn.io` 가 6분 넘게 `error`. 파드는 만들어졌다 사라지기를 반복했다.
- 좁히기: 이벤트에는 `Created`·`Started` 만 있고 실패 이유가 없었다. 파드가 금방 지워져 로그도 안 남아서, 2초 간격으로 `kubectl logs` 를 반복해 떠 있는 순간의 로그를 잡았다. 마지막 줄이 `SPDK cpu mask 0x3 covers every online CPU (online_mask=0x3)` → `Aborting spdk_tgt start`.
- 원인: 기본 `data-engine-cpu-mask` 가 `{"v2":"0x3"}`(코어 0·1). 워커가 2 vCPU 라 SPDK 가 코어를 전부 가져가게 되고, Longhorn 이 그 상태로는 기동을 거부한다. hugepage(2Gi)와 커널 모듈은 정상이었다.
- 조치: 마스크를 `0x1` 로. 2분 뒤 세 노드 모두 `running`.

```bash
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'
```

### 28. V2 디스크 경로를 고쳤는데도 `cannot find lvstore with UUID`: instance-manager 가 잘못 잡은 디스크를 기억한다 [실서버 영향]

- 증상: `/dev/sdc` 로 등록한 노드에서 재부팅 뒤 `/dev/sdc` 가 다른(빈) 디스크를 가리켰다. 경로를 `by-id` 로 고쳤는데 5분이 지나도 디스크 `Ready=False`.
- 좁히기: 같은 조치가 다른 노드에서는 60초 만에 됐다(그 노드는 `/dev/sdc` 가 아예 없어진 경우). 차이는 오류 메시지였다. 없어진 경우는 `failed to detect disk device /host/dev/sdc`, 이번에는 처음에 `cannot find lvstore with UUID …` 한 번, 그 뒤로 `disk /dev/sdc is already used by disk bdev v2-disk`. 즉 instance-manager 안(SPDK)에 `/dev/sdc` 를 가리키는 `v2-disk` 가 이미 만들어져 있었다. 경로를 고친 뒤 메시지는 다시 `cannot find lvstore` 였다. 실제 디스크(`sdb`) 앞머리에는 `SPDKBLOB` 표식이 그대로 있었으므로 데이터 문제는 아니었다.
- 원인(추정): 같은 이름의 디스크 항목이 SPDK 에 남아 있어, 경로를 바꿔도 옛 장치를 다시 본다. 소스로 확인하지는 않았다.
- 조치: 그 노드의 V2 instance-manager 파드 삭제. 다시 뜬 뒤 66초에 디스크 Ready, 87초에 CNPG 3/3. 데이터 유지.
- 빈 디스크 쪽은 앞 4MB 가 전부 0 이었다. Longhorn 은 UUID 가 안 맞는 디스크에 쓰지 않았다.

### 29. primary 노드가 죽었는데 승격이 6분 넘게 안 됨: operator 가 같은 노드에 있었다 [실서버 영향]

- 증상: primary 가 있는 워커를 껐더니 쓰기가 6분 26초 실패. 같은 시험을 앞서 했을 때는 70초 만에 새 primary 였다.
- 좁히기: 두 번의 차이를 찾았다. 느렸던 쪽은 Cluster 상태가 370초까지 `3/3` 그대로였다. 상태를 고치는 주체가 일을 안 했다는 뜻이라 operator 를 봤다. operator 파드가 3분 53초 전에 새로 떠 있었고, 로그는 `Successfully acquired lease` 바로 다음 줄이 `Current primary isn't healthy, initiating a failover` 였다. 죽은 노드에 operator 가 같이 있었던 것이다.
- 원인: operator 는 1개였고, 죽은 노드의 파드는 300초 축출 대기 뒤에야 다른 노드에 다시 만들어진다. 그동안 승격을 지시할 주체가 없다.
- 조치: operator 2개 + 서로 다른 노드(`v2test/cnpg-operator-ha.yaml`). 리더가 죽은 노드에 있던 경우도 58초, 다른 노드에 있던 경우 86초. 자세한 수치는 [V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md).

# 3부. 설정·스크립트 (붙여넣기로 복원)

빈 디렉터리에서 아래 블럭을 위에서부터 붙여넣는다. 블럭 하나가 파일 하나를 만든다. `Vagrantfile`·`scripts/v2-*.sh` 는 랩(VMware) 전용이고, 실서버에 쓸 것은 `v2test/*.yaml` 과 문서의 명령이다.

| # | 파일 | 줄 수 |
|---|---|---|
| 1 | `Vagrantfile` | 80 |
| 2 | `scripts/v2-disks.sh` | 11 |
| 3 | `scripts/v2-node-prep.sh` | 19 |
| 4 | `v2test/b2.sh` | 17 |
| 5 | `v2test/c1.sh` | 12 |
| 6 | `v2test/c2.sh` | 11 |
| 7 | `v2test/cnpg-operator-ha.yaml` | 7 |
| 8 | `v2test/pg-r3.yaml` | 11 |
| 9 | `v2test/pg-v2.yaml` | 12 |
| 10 | `v2test/probe-report.sh` | 17 |
| 11 | `v2test/probe.yaml` | 24 |
| 12 | `v2test/sc-v2.yaml` | 20 |
| 13 | `v2test/state.sh` | 11 |
| 14 | `v2test/watch.sh` | 9 |

## 3.1 Vagrantfile

```bash
cat > 'Vagrantfile' <<'__V2_EOF__'
# -*- mode: ruby -*-
# Kubespray HA 클러스터 랩: control plane 3 (etcd 쿼럼 2) + worker 5
# 환경: macOS Apple Silicon + VMware Fusion + vagrant-vmware-desktop, bento/ubuntu-24.04 arm64
#
#   vagrant up                       # VM 9대 기동 (프로비저닝 없음, 클러스터는 Kubespray 로)
#   ./scripts/00-inventory.sh        # vagrant ssh-config → inventory/lab/ssh.cfg
#   ./scripts/10-cluster.sh          # Kubespray cluster.yml
#
# 메모리 합계 = 3 × CP_MEM + W_COUNT × W_MEM + TOR (기본 3×2560 + 5×2688 + 512 MB = 약 21 GB). CP 1792MB 는 etcd+apiserver 로 메모리 150% → kube-vip 리스 실패(VIP 이동)를 겪어 2560 으로 올림. 32 GB Mac 에서 다른 VM/podman 을 끄고 돌린다.
# 워커는 처음에 7대 × 1920MB 였다. kubelet 이 노드마다 868Mi 를 떼어 두고(kubeReserved 256 + systemReserved 512 + eviction 100) Cilium·Longhorn 데몬이 또 깔려서,
# DB 복구처럼 I/O 가 몰리면 memory.available < 100Mi → Longhorn 파드 퇴거 → 그 노드 볼륨 정지가 반복됐다(TROUBLESHOOTING 16절). 같은 합계로 5대 × 2688MB 로 바꿨다.
# 7대로 되돌리려면 W_COUNT=7 W_MEM=1920 을 주고 vagrant up 으로 ks-w6·ks-w7 을 새로 만든 뒤 scale.yml 로 넣는다(두 VM 은 2026-11-13 에 디스크 확보를 위해 지웠다).

CP_COUNT = Integer(ENV.fetch("CP_COUNT", 3))      # 3 = etcd 쿼럼 2. 2 는 쓰지 않는다(한 대만 죽어도 쿼럼 상실)
W_COUNT  = Integer(ENV.fetch("W_COUNT", 5))
CP_MEM   = Integer(ENV.fetch("CP_MEM", 2560))
W_MEM    = Integer(ENV.fetch("W_MEM", 2688))
TOR_MEM  = Integer(ENV.fetch("TOR_MEM", 512))
# Longhorn V2(SPDK) 시험용 — 기본은 꺼짐. V2_NODES 에 적은 워커만 메모리를 V2_MEM 으로 올리고 빈 SATA 디스크를 붙인다(LONGHORN-V2-DISK.md 8절).
#   V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up ks-w1 ks-w2 ks-w3
#   게스트에서 sda=OS, sdb=dummy(1GB, 이름을 밀어내는 용), sdc=V2 디스크(10GB). V2_NO_DUMMY 에 적은 노드는 dummy 를 떼어 V2 디스크가 sdb 로 당겨진다.
#   디스크 파일은 v2disks/<노드>-{dummy,data}.vmdk (scripts/v2-disks.sh 가 만든다)
V2_NODES    = ENV.fetch("V2_NODES", "").split(",")
V2_NO_DUMMY = ENV.fetch("V2_NO_DUMMY", "").split(",")
V2_SWAP     = ENV.fetch("V2_SWAP", "").split(",")     # 적은 노드는 dummy 와 V2 디스크의 포트를 맞바꾼다 → /dev/sdc 가 엉뚱한(빈) 디스크를 가리킨다
V2_MEM      = Integer(ENV.fetch("V2_MEM", 5120))
V2_DISK_DIR = File.expand_path("v2disks", __dir__)
BOX          = "bento/ubuntu-24.04"
BOX_VERSION  = "202510.26.0"

# Apple Silicon Fusion 은 Vagrant 가 새 vmnet 을 못 만든다 → Fusion 이 잡아 둔 host-only(vmnet1) 대역을 재사용
FUSION_NET_CONF = "/Library/Preferences/VMware Fusion/networking"
NET = File.read(FUSION_NET_CONF)[/VNET_1_HOSTONLY_SUBNET (\d+\.\d+\.\d+)\.\d+/, 1] or abort("vmnet1 host-only 서브넷을 못 읽음")

# 주소 계획 (같은 vmnet1 의 기존 k8s-core 랩 .10~.16/.100/.200 과 겹치지 않게)
#   .29        ks-tor   — ToR(상단) 스위치/라우터 역할. FRR 로 BGP(AS 65000), 노드들(AS 65010)과 피어링
#   .30        API VIP (kube-vip, ARP)
#   .31~.33    ks-cp1~3
#   .41~.45    ks-w1~5 (.46·.47 = ks-w6·7 자리, VM 은 지움)
#   .210~.219  Cilium LB 풀 "L2" — 노드 서브넷 안 VIP, ARP 로 광고 (Harbor = .210)
#   10.250.0.0/24  Cilium LB 풀 "BGP" — 노드 서브넷 밖 VIP 대역, BGP 로 ToR 에 경로 광고 (ECMP)
NODES = [{ name: "ks-tor", ip: "#{NET}.29", mem: TOR_MEM }] +
        (1..CP_COUNT).map { |i| { name: "ks-cp#{i}", ip: "#{NET}.#{30 + i}", mem: CP_MEM } } +
        (1..W_COUNT).map  { |i| { name: "ks-w#{i}",  ip: "#{NET}.#{40 + i}", mem: W_MEM } }

Vagrant.configure("2") do |config|
  config.vm.box              = BOX
  config.vm.box_version      = BOX_VERSION
  config.vm.box_architecture = "arm64"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |n|
    config.vm.define n[:name] do |m|
      m.vm.hostname = n[:name]
      m.vm.network "private_network", ip: n[:ip]
      m.vm.provider "vmware_desktop" do |v|
        v.gui    = false
        v.memory = n[:mem]
        v.cpus   = 2
        v.linked_clone = true
        v.vmx["displayName"] = n[:name]
        # suspend 금지 + Tools 시간 동기화 끔: resume/RTC(KST) 로 시계가 튀면 etcd 리스·프로브가 깨진다 (k8s-core TROUBLESHOOTING 참고)
        v.vmx["suspend.disabled"] = "TRUE"
        %w[tools.synctime time.synchronize.continue time.synchronize.restore time.synchronize.resume.disk
           time.synchronize.shrink time.synchronize.tools.startup time.synchronize.tools.enable].each { |k| v.vmx[k] = "FALSE" }
        # Fusion 무료화 이후 라이선스 오인식으로 private_network 가 무시되는 문제 회피
        v.force_vmware_license = "professional"
        if V2_NODES.include?(n[:name])
          v.memory = V2_MEM
          dummy = !V2_NO_DUMMY.include?(n[:name])
          v.vmx["sata0:2.present"]  = dummy ? "TRUE" : "FALSE"
          first, second = V2_SWAP.include?(n[:name]) ? %w[data dummy] : %w[dummy data]
          v.vmx["sata0:2.filename"] = "#{V2_DISK_DIR}/#{n[:name]}-#{first}.vmdk"
          v.vmx["sata0:3.present"]  = "TRUE"
          v.vmx["sata0:3.filename"] = "#{V2_DISK_DIR}/#{n[:name]}-#{second}.vmdk"
        end
      end
    end
  end
end
__V2_EOF__
```

## 3.2 scripts/v2-disks.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/v2-disks.sh' <<'__V2_EOF__'
#!/bin/bash
# (랩) Longhorn V2 시험용 빈 디스크 만들기: v2disks/<노드>-dummy.vmdk(1GB), <노드>-data.vmdk(10GB). 이미 있으면 건너뛴다.
#   ./scripts/v2-disks.sh ks-w1 ks-w2 ks-w3
set -euo pipefail
cd "$(dirname "$0")/.."; mkdir -p v2disks
VDM="/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager"
for n in "$@"; do
  [ -f v2disks/$n-dummy.vmdk ] || "$VDM" -c -s 1GB  -a lsilogic -t 0 v2disks/$n-dummy.vmdk
  [ -f v2disks/$n-data.vmdk ]  || "$VDM" -c -s 10GB -a lsilogic -t 0 v2disks/$n-data.vmdk
done
ls -lh v2disks
__V2_EOF__
chmod +x 'scripts/v2-disks.sh'
```

## 3.3 scripts/v2-node-prep.sh

```bash
mkdir -p 'scripts'
cat > 'scripts/v2-node-prep.sh' <<'__V2_EOF__'
#!/bin/bash
# Longhorn V2 를 쓸 노드 준비 (Longhorn 1.13 문서 "V2 Data Engine Requirements"): 커널 모듈 3개 + hugepage 2GiB + kubelet 재시작
#   ./scripts/v2-node-prep.sh ks-w1 ks-w2 ks-w3
set -uo pipefail
cd "$(dirname "$0")/.."
for n in "$@"; do
  echo "== $n"
  ssh -F inventory/lab/ssh.cfg $n 'sudo bash -s' <<'REMOTE'
set -e
export DEBIAN_FRONTEND=noninteractive
dpkg -s linux-modules-extra-$(uname -r) >/dev/null 2>&1 || apt-get install -y -q linux-modules-extra-$(uname -r) >/dev/null
printf 'vfio_pci\nuio_pci_generic\nnvme_tcp\n' > /etc/modules-load.d/longhorn-v2.conf
for m in vfio_pci uio_pci_generic nvme_tcp; do modprobe $m; done
echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/90-longhorn-v2-hugepages.conf
sysctl -q -p /etc/sysctl.d/90-longhorn-v2-hugepages.conf
systemctl restart kubelet
echo "modules: $(lsmod | grep -cE '^(vfio_pci|uio_pci_generic|nvme_tcp) ')/3  hugepages: $(grep HugePages_Total /proc/meminfo | awk '{print $2}')"
REMOTE
done
__V2_EOF__
chmod +x 'scripts/v2-node-prep.sh'
```

## 3.4 v2test/b2.sh

```bash
mkdir -p 'v2test'
cat > 'v2test/b2.sh' <<'__V2_EOF__'
#!/bin/bash
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf CL=pg-r3 VOLF='pvc-(9248|cf1f)'
N=$(kubectl -n v2test get pod pg-r3-2 -o jsonpath='{.spec.nodeName}')
echo "### B2 $(date +%H:%M:%S) $N(pg-r3-2, 3벌 복제 볼륨) 강제 정지 — 아무것도 안 하고 13분 관찰"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"
./v2test/watch.sh $N 780
echo "--- 13분 시점"; kubectl -n v2test get pods -l cnpg.io/cluster=pg-r3 -o wide --no-headers | awk '{print " ",$1,$2,$3,$7}'
kubectl get volumeattachment --no-headers | grep -E "9248|cf1f" | awk '{print " ",$3,$4,$5}'
kubectl -n v2test get events --sort-by=.lastTimestamp | grep pg-r3 | grep -i warn | tail -4 | cut -c1-280
if [ "$(kubectl -n v2test get cluster pg-r3 -o jsonpath='{.status.readyInstances}')" != 2 ]; then
  echo "### B3 $(date +%H:%M:%S) out-of-service taint 적용"; kubectl taint node $N node.kubernetes.io/out-of-service=nodeshutdown:NoExecute | tail -1
  ./v2test/watch.sh $N 420 'pg 2/2'
  kubectl -n v2test get pods -l cnpg.io/cluster=pg-r3 -o wide --no-headers | awk '{print " ",$1,$2,$3,$7}'
fi
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; kubectl taint node $N node.kubernetes.io/out-of-service- 2>&1 | tail -1; echo "up $(date +%H:%M:%S)"
VOLF=. CL=pg-v2 ./v2test/watch.sh $N 480 'pg 3/3'
echo DONE
__V2_EOF__
chmod +x 'v2test/b2.sh'
```

## 3.5 v2test/c1.sh

```bash
mkdir -p 'v2test'
cat > 'v2test/c1.sh' <<'__V2_EOF__'
#!/bin/bash
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf CL=pg-v2 VOLF=.
P=$(kubectl -n v2test get cluster pg-v2 -o jsonpath='{.status.currentPrimary}'); N=$(kubectl -n v2test get pod $P -o jsonpath='{.spec.nodeName}')
echo "### C1 $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S)) primary=$P 가 있는 $N 강제 정지 — 파드는 건드리지 않음, 7분 관찰"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S))"
./v2test/watch.sh $N 420
kubectl -n v2test get pods -l cnpg.io/cluster=pg-v2 -L cnpg.io/instanceRole -o wide --no-headers | awk '{print " ",$1,$3,$7,$NF}'
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/watch.sh $N 480 'pg 3/3'
kubectl -n v2test get pods -l cnpg.io/cluster=pg-v2 -L cnpg.io/instanceRole -o wide --no-headers | awk '{print " ",$1,$3,$7,$NF}'
./v2test/probe-report.sh 20m
echo DONE
__V2_EOF__
chmod +x 'v2test/c1.sh'
```

## 3.6 v2test/c2.sh

```bash
mkdir -p 'v2test'
cat > 'v2test/c2.sh' <<'__V2_EOF__'
#!/bin/bash
# 인자: 클러스터 이름, 관찰 초.  primary 가 있는 노드를 강제 정지하고 건드리지 않는다
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf CL=$1 VOLF=.
P=$(kubectl -n v2test get cluster $CL -o jsonpath='{.status.currentPrimary}'); N=$(kubectl -n v2test get pod $P -o jsonpath='{.spec.nodeName}')
echo "### $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S)) $CL primary=$P @ $N 강제 정지. operator: $(kubectl -n cnpg-system get pods -o wide --no-headers | awk '$3=="Running"{printf "%s ",$7}') leader=$(kubectl -n cnpg-system get lease db9c8771.cnpg.io -o jsonpath='{.spec.holderIdentity}' | cut -c1-35)"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S))"
./v2test/watch.sh $N ${2:-300} | sed -E 's/disk=[^|]*\| vol: [^|]*//; s/node=//'
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/watch.sh $N 480 "pg $(kubectl -n v2test get cluster $CL -o jsonpath='{.spec.instances}')/" | sed -E 's/disk=[^|]*\| vol: [^|]*//; s/node=//'
PROBE=${PROBE:-probe} ./v2test/probe-report.sh 15m
echo DONE
__V2_EOF__
chmod +x 'v2test/c2.sh'
```

## 3.7 v2test/cnpg-operator-ha.yaml

```bash
mkdir -p 'v2test'
cat > 'v2test/cnpg-operator-ha.yaml' <<'__V2_EOF__'
# CNPG operator 를 2개로 — 한 노드에 몰리지 않게. operator 가 죽은 노드에 있으면 그 파드가 다시 뜰 때까지(기본 300초 축출 대기) 승격이 시작되지 않는다
replicaCount: 2
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: kubernetes.io/hostname
      labelSelector: {matchLabels: {app.kubernetes.io/name: cloudnative-pg}}
__V2_EOF__
```

## 3.8 v2test/pg-r3.yaml

```bash
mkdir -p 'v2test'
cat > 'v2test/pg-r3.yaml' <<'__V2_EOF__'
# 3벌 복제 V2 볼륨 위의 CNPG 2 인스턴스 — 워커 3대 중 한 대가 비어 있어 파드가 옮겨 갈 자리가 있다
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: pg-r3, namespace: v2test}
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
  smartShutdownTimeout: 15
  affinity: {enablePodAntiAffinity: true, topologyKey: kubernetes.io/hostname, podAntiAffinityType: required}
  storage: {storageClass: longhorn-v2, size: 2Gi}
  resources: {requests: {cpu: 50m, memory: 192Mi}, limits: {memory: 384Mi}}
__V2_EOF__
```

## 3.9 v2test/pg-v2.yaml

```bash
mkdir -p 'v2test'
cat > 'v2test/pg-v2.yaml' <<'__V2_EOF__'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: pg-v2, namespace: v2test}
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
  smartShutdownTimeout: 15
  affinity: {enablePodAntiAffinity: true, topologyKey: kubernetes.io/hostname, podAntiAffinityType: required}
  postgresql:
    synchronous: {method: any, number: 1}
  storage: {storageClass: longhorn-v2-single, size: 2Gi}
  resources: {requests: {cpu: 50m, memory: 192Mi}, limits: {memory: 384Mi}}
__V2_EOF__
```

## 3.10 v2test/probe-report.sh

```bash
mkdir -p 'v2test'
cat > 'v2test/probe-report.sh' <<'__V2_EOF__'
#!/bin/bash
# 프로브 로그에서 쓰기/읽기 실패 구간을 뽑는다 (시각은 UTC)
export KUBECONFIG=$(dirname "$0")/../inventory/lab/artifacts/admin.conf
kubectl -n v2test logs ${PROBE:-probe} --since=${1:-30m} | python3 -c "
import sys
L=[l.split() for l in sys.stdin if ' W=' in l]
print('samples',len(L),L[0][0],'~',L[-1][0])
for k,name in ((1,'write'),(2,'read')):
    run=None;out=[]
    for t,w,r in L:
        bad=(w,r)[k-1].endswith('X')
        if bad and run is None: run=[t,t,1]
        elif bad: run[1]=t;run[2]+=1
        elif run: out.append(run);run=None
    if run: out.append(run)
    print(name,'fail runs:',[f'{a}~{b} ({n} samples)' for a,b,n in out] or 'none')
"
__V2_EOF__
chmod +x 'v2test/probe-report.sh'
```

## 3.11 v2test/probe.yaml

```bash
mkdir -p 'v2test'
cat > 'v2test/probe.yaml' <<'__V2_EOF__'
# 1초마다 pg-v2 에 쓰기(-rw 서비스)와 읽기(-ro 서비스)를 한 번씩 해 보고 성공/실패를 찍는다. 죽이지 않을 노드에 고정
apiVersion: v1
kind: Pod
metadata: {name: probe, namespace: v2test}
spec:
  nodeName: ks-w1
  restartPolicy: Always
  terminationGracePeriodSeconds: 1
  containers:
  - name: probe
    image: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
    env:
    - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: pg-v2-app, key: password}}}
    - {name: PGCONNECT_TIMEOUT, value: "2"}
    command: ["bash","-c"]
    args:
    - |
      psql -h pg-v2-rw -U app -d app -qc "create table if not exists p(id bigserial primary key, at timestamptz default now())" 
      while true; do
        w=$(timeout 3 psql -h pg-v2-rw -U app -d app -qAtc "insert into p default values returning 1" 2>/dev/null | head -1)
        r=$(timeout 3 psql -h pg-v2-ro -U app -d app -qAtc "select 1" 2>/dev/null | head -1)
        echo "$(date +%H:%M:%S) W=${w:-X} R=${r:-X}"
        sleep 1
      done
__V2_EOF__
```

## 3.12 v2test/sc-v2.yaml

```bash
mkdir -p 'v2test'
cat > 'v2test/sc-v2.yaml' <<'__V2_EOF__'
# Longhorn V2 시험용 StorageClass 두 개
#   longhorn-v2-single: CNPG 용. DB 가 스스로 3벌 복제하므로 스토리지는 1벌
#   longhorn-v2       : 3벌 복제 (노드가 죽어도 볼륨이 살아 있는 경우를 보는 용)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: longhorn-v2-single}
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters: {dataEngine: v2, numberOfReplicas: "1", dataLocality: strict-local, staleReplicaTimeout: "30"}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: longhorn-v2}
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters: {dataEngine: v2, numberOfReplicas: "3", staleReplicaTimeout: "30"}
__V2_EOF__
```

## 3.13 v2test/state.sh

```bash
mkdir -p 'v2test'
cat > 'v2test/state.sh' <<'__V2_EOF__'
#!/bin/bash
# 한 줄 상태: 노드 / Longhorn 디스크 / 볼륨 / CNPG  (인자: 노드 이름)
N=$1; export KUBECONFIG=$(dirname "$0")/../inventory/lab/artifacts/admin.conf
nd=$(kubectl get node $N --no-headers 2>/dev/null | awk '{print $2}')
dk=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o json 2>/dev/null | python3 -c "
import sys,json;s=json.load(sys.stdin)['status']['diskStatus'].get('v2-disk',{})
c={x['type']:x['status'] for x in s.get('conditions',[])};print('disk=%s/%s uuid=%s'%(c.get('Ready'),s.get('diskPath'),(s.get('diskUUID') or '-')[:8]))" 2>/dev/null)
vol=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk -v f="${VOLF:-.}" '$2=="v2" && $0 ~ f{printf "%s/%s ",$3,$4}')
pg=$(kubectl -n v2test get cluster ${CL:-pg-v2} -o jsonpath='{.status.readyInstances}/{.status.instances} primary={.status.currentPrimary}' 2>/dev/null)
pods=$(kubectl -n v2test get pods -l cnpg.io/cluster=${CL:-pg-v2} -o wide --no-headers 2>/dev/null | awk '{printf "%s=%s(%s)@%s ",$1,$3,$2,$7}')
echo "$(date +%H:%M:%S) node=$nd $dk | vol: $vol| pg $pg | $pods"
__V2_EOF__
chmod +x 'v2test/state.sh'
```

## 3.14 v2test/watch.sh

```bash
mkdir -p 'v2test'
cat > 'v2test/watch.sh' <<'__V2_EOF__'
#!/bin/bash
# 상태가 바뀔 때만 한 줄 출력. 인자: 노드, 최대 초, [끝 조건 grep 식]
cd "$(dirname "$0")/.."; N=$1; MAX=${2:-300}; END=${3:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  o=$(./v2test/state.sh $N); b=${o#* }
  [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $o"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && ! echo "$b" | grep -q faulted && break
  /bin/sleep 5
done
__V2_EOF__
chmod +x 'v2test/watch.sh'
```

## 3.x sha256 대조

리눅스는 `sha256sum -c`, macOS 는 `shasum -a 256 -c`. 모든 줄이 `OK` 여야 한다.

```bash
sha256sum -c <<'__V2_EOF__'
d82e3cfedb357d0db179e0d11ef72f1890abb65aee037738c89dc3afe9e496e5  Vagrantfile
b204d9385e1096a26e4c4976441ffc07030a90b004c1b1c63bb7b6284957a3b3  scripts/v2-disks.sh
304f59a09508a20f1ed5cb80f5d9e58d428b0cfe64d6d1e6f48362ac231dac36  scripts/v2-node-prep.sh
6677c9485b9c129991872dd131853d013e7754bb6da4eb3b4874b497ae2c7af6  v2test/b2.sh
cbf943118ea685722cde979b192422279f7307481f016eea05e9ab30bafcccdc  v2test/c1.sh
1beabfcf19b762a2501259b7610f1d95324ba123259f5f44fb5a56a89ab52dac  v2test/c2.sh
b55ecf5f4868ef8cbbd30ce5c6585abc935c46637507b16e26b98de98927d49b  v2test/cnpg-operator-ha.yaml
988f16bad51eec1dd6c0533e8cbb3c9605a10d891d5ab5f6f02194df8ff70f53  v2test/pg-r3.yaml
e35b1e6870ba20b3e0b602ba8599be1951de3933d820707688c77c3f86d753b9  v2test/pg-v2.yaml
88f82d6d557f97d3b178b5380d3f87feb7dd3397f3bb8987f568e1b00d2f6755  v2test/probe-report.sh
a533b83c482eaec085f316c511cf263fe7ec5e0b82ad588584b70d1a5262dac5  v2test/probe.yaml
91410acdccf827d0cb9ea6b937cb789a4e045cfd03bfb0315770819ca703e4e5  v2test/sc-v2.yaml
023dd30ca67162f7a59be35a41a6b58da4c45bc31add7ccc4cbb2976910cce7a  v2test/state.sh
56ff1a3bd5b4495a22fbba490e934c7e8e2a1ad669eade888c999c28ea70c37b  v2test/watch.sh
__V2_EOF__
```

# 4부. 로그 원문

시각은 KST, 프로브 실패 구간만 UTC(9시간 차이). 무엇을 한 시험인지는 2부 "시험 재현 순서와 설정" 6~8절.

## A1.log

```text
### A1 19:12:36 ks-w3 정상 종료 후 dummy 디스크를 떼고 기동 (V2 디스크 sdc → sdb)
halted 19:13:19
19:13:19 node=NotReady disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Pending(0/1) pg-v2-3=Running(1/1) 
up 19:13:48
sda    64G 0x5000c29bdbf10663
sdb    10G 0x5000c2944851f80e
19:13:48 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Pending(0/1) pg-v2-3=Running(1/1)
19:14:04 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Pending(0/1) pg-v2-3=Running(1/1)
19:14:20 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:14:35 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:14:51 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:15:06 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:15:22 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:15:37 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:15:53 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:16:08 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:16:24 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:16:39 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:16:55 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:17:10 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:17:26 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:17:41 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:17:57 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:18:13 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:18:28 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:18:44 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:18:59 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:19:15 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:19:30 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:19:46 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
```

## A2.log

```text
### A1 증상 메시지
  Ready False Disk v2-disk(/dev/sdc) on node ks-w3 is not ready: errors: disk is not in ready state, current state: creating, message: rpc error: code = Internal desc = failed to add disk block device: failed to validate disk creation: failed to get disk device number: fail
  Schedulable False Disk v2-disk (/dev/sdc) on the node ks-w3 is not ready
9m11s       Warning   FailedAttachVolume            pod/pg-v2-2                         AttachVolume.Attach failed for volume "pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2" : rpc error: code = Aborted desc = volume pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2 is not ready for workloads: waiting for the volume to fully detach. current st
6m27s       Warning   FailedScheduling              pod/pg-v2-2                         0/8 nodes are available: 2 node(s) didn't match PersistentVolume's node affinity, 6 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/8 nodes are available: 8 Preemption is not helpful for scheduling.
5m55s       Warning   FailedMount                   pod/pg-v2-2                         MountVolume.MountDevice failed for volume "pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2" : kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient: driver name driver.longhorn.io not found in the list of registered CSI drivers
time="2026-11-16T10:18:48.726306535Z" level=warning msg="Retrying the creation of disk v2-disk(/dev/sdc) on node ks-w3 after a previous failure: rpc error: code = Internal desc = failed to add disk block device: failed to validate disk creation: failed to get disk device number: failed to detect disk device /host/dev/sdc: failed
time="2026-11-16T10:19:18.72851643Z" level=warning msg="Retrying the creation of disk v2-disk(/dev/sdc) on node ks-w3 after a previous failure: rpc error: code = Internal desc = failed to add disk block device: failed to validate disk creation: failed to get disk device number: failed to detect disk device /host/dev/sdc: failed 
time="2026-11-16T10:19:48.729123513Z" level=warning msg="Retrying the creation of disk v2-disk(/dev/sdc) on node ks-w3 after a previous failure: rpc error: code = Internal desc = failed to add disk block device: failed to validate disk creation: failed to get disk device number: failed to detect disk device /host/dev/sdc: failed
### A2 19:20:11 경로만 교체: /dev/sdc → /dev/disk/by-id/wwn-0x5000c2944851f80e
node.longhorn.io/ks-w3 patched
19:20:12 node=Ready disk=False//dev/sdc uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:20:54 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attaching/unknown attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1)
19:21:04 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(0/1) pg-v2-3=Running(1/1)
19:21:15 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1)
```

## A3.log

```text
data check: 1|t
### A3 19:21:30 ks-w3: by-id 로 등록된 상태에서 dummy 를 다시 붙여 재부팅 (sdb → sdc 로 다시 밀림)
up 19:22:40 sda    64G sdb     1G sdc    10G 
+0s 19:22:41 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Pending(0/1) pg-v2-3=Running(1/1) 
+22s 19:23:03 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1) 
+92s 19:24:13 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attaching/unknown attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1) 
+97s 19:24:18 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Init:0/1(0/1) pg-v2-3=Running(1/1) 
+114s 19:24:35 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(0/1) pg-v2-3=Running(1/1) 
+119s 19:24:40 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
```

## A4.log

```text
### A4 19:24:49 ks-w1: /dev/sdc 로 등록된 채 디스크 포트를 맞바꿔 재부팅 (/dev/sdc = 빈 1GB 디스크)
up 19:25:59 sda    64G sdb    10G sdc     1G 
+0s 19:25:59 node=Ready disk=False//dev/sdc uuid=0fbf007f | vol: attached/healthy attached/healthy detached/faulted | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Pending(0/1) 
+27s 19:26:26 node=Ready disk=False//dev/sdc uuid=0fbf007f | vol: attached/healthy attached/healthy detached/faulted | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Init:0/1(0/1) 
 uuid 0fbf007f-9a0c-4ecf-b108-7989725f2125 max 0
  Ready False Disk v2-disk(/dev/sdc) on node ks-w1 is not ready: errors: disk is not in ready state, current state: creating, message: rpc error: code = Internal desc = failed to add disk block device: failed to validate disk creation: disk /dev/sdc is already used by disk bdev v2-disk
  Schedulable False Disk v2-disk (/dev/sdc) on the node ks-w1 is not ready
```

## A5.log

```text
sdb first-16-bytes: 5350444b424c4f420300000000100000  ascii: SPDKBLOB  nonzero-in-first-4MB: 552
sdc first-16-bytes: 00000000000000000000000000000000  ascii:   nonzero-in-first-4MB: 0
  11 evel=warning msg="Failed to sync with disk monitor due to mismatching disks" func="controller.(*NodeController).syncNode" file="node_controller.go:501" controller=longhorn-node error="mismatching disks in node resource object and monitor collected data" node=ks-w1
   7 evel=warning msg="Retrying the creation of disk v2-disk(/dev/sdc) on node ks-w1 after a previous failure: rpc error: code = Internal desc = failed to add disk block device: failed to validate disk creation: disk /dev/sdc is already used by disk bdev v2-disk" func="monitor.(*DiskMonitor).collectDiskData" file="disk_monitor.go:332" controller=longhorn-node node=ks-w1
   1 vel=warning msg="Failed to sync with disk monitor due to mismatching disks" func="controller.(*NodeController).syncNode" file="node_controller.go:501" controller=longhorn-node error="mismatching disks in node resource object and monitor collected data" node=ks-w1
   1 evel=warning msg="Retrying the creation of disk v2-disk(/dev/sdc) on node ks-w1 after a previous failure: rpc error: code = Internal desc = failed to add disk block device: rpc error: code = NotFound desc = cannot find lvstore with UUID 0fbf007f-9a0c-4ecf-b108-7989725f2125" func="monitor.(*DiskMonitor).collectDiskData" file="disk_monitor.go:332" controller=longhorn-node node=ks-
### A5 19:31:11 ks-w1 경로 교체 → /dev/disk/by-id/wwn-0x5000c295b2303f66
node.longhorn.io/ks-w1 patched
+1s 19:31:12 node=Ready disk=False//dev/sdc uuid=0fbf007f | vol: attached/healthy attached/healthy detached/faulted | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Init:0/1(0/1) 
error: unable to upgrade connection: container not found ("postgres")
rows on pg-v2-3: 
```

## A6.log

```text
### A6 19:36:27 ks-w1 의 V2 instance-manager 파드 삭제(재기동)
pod "instance-manager-3e4a4190fdbc93758009d451933bdde8" deleted from longhorn-system namespace
+1s 19:36:28 node=Ready disk=False//dev/sdc uuid=0fbf007f | vol: attached/healthy attached/healthy detached/faulted | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Init:0/1(0/1) 
+66s 19:37:33 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c295b2303f66 uuid=0fbf007f | vol: attached/healthy attached/healthy attaching/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Init:0/1(0/1) 
+71s 19:37:38 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c295b2303f66 uuid=0fbf007f | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Init:0/1(0/1) 
+77s 19:37:44 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c295b2303f66 uuid=0fbf007f | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(0/1) 
+87s 19:37:54 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c295b2303f66 uuid=0fbf007f | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
rows on pg-v2-3: 1
```

## A7.log

```text
### A7 19:38:08 ks-w2(정상, primary 보유, 볼륨 attached) 경로만 교체 → /dev/disk/by-id/wwn-0x5000c29037894912
node.longhorn.io/ks-w2 patched
.+1s 19:38:09 node=Ready disk=True//dev/sdc uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
.+6s 19:38:14 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
............................
 spec path /dev/disk/by-id/wwn-0x5000c29037894912
 status path /dev/disk/by-id/wwn-0x5000c29037894912
  Ready True Disk v2-disk(/dev/disk/by-id/wwn-0x5000c29037894912) on node ks-w2 is ready
  Schedulable True Disk v2-disk(/dev/disk/by-id/wwn-0x5000c29037894912) on node ks-w2 is schedulable
```

## B1.log

```text
### B1 19:39:57 ks-w2(primary) 강제 정지 → 7분 뒤 기동
killed 19:40:01
+1s 19:40:02 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+48s 19:40:49 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/unknown attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+70s 19:41:11 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/unknown attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+351s 19:45:52 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/faulted attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Terminating(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
--- down 상태 스냅샷
  pg-v2-1 1/1 Terminating ks-w2
  pg-v2-2 1/1 Running ks-w3
  pg-v2-3 1/1 Running ks-w1
  pvc-116ef239-12c4-4685-a7df-b1a1ec7949dc ks-w2 true
  pvc-aa8851f4-11fb-412b-9573-813db66c3895 ks-w1 true
  pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2 ks-w3 true
### 기동 19:47:01
up 19:47:30
+0s 19:47:30 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/faulted attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Terminating(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+11s 19:47:41 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/faulted attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+27s 19:47:57 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/faulted attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+81s 19:48:51 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attaching/unknown attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+87s 19:48:57 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+92s 19:49:02 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Terminating(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+98s 19:49:08 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+103s 19:49:13 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(0/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
+114s 19:49:24 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1) pg-v2-2=Running(1/1) pg-v2-3=Running(1/1) 
35m         Warning   FailedScheduling              pod/pg-v2-2                         0/8 nodes are available: 2 node(s) didn't match PersistentVolume's node affinity, 6 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/8 nodes are
35m         Warning   FailedMount                   pod/pg-v2-2                         MountVolume.MountDevice failed for volume "pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2" : kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient: driver n
28m         Warning   FailedMount                   pod/pg-v2-2                         MountVolume.MountDevice failed for volume "pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2" : rpc error: code = InvalidArgument desc = volume pvc-848440d6-5c32-483b-836d-e4b57e4e3
26m         Warning   FailedScheduling              pod/pg-v2-2                         0/8 nodes are available: 2 node(s) didn't match PersistentVolume's node affinity, 6 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/8 nodes are
26m         Warning   FailedMount                   pod/pg-v2-2                         MountVolume.MountDevice failed for volume "pvc-848440d6-5c32-483b-836d-e4b57e4e3cc2" : kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient: driver n
23m         Warning   FailedScheduling              pod/pg-v2-3                         0/8 nodes are available: 2 node(s) didn't match PersistentVolume's node affinity, 6 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/8 nodes are
22m         Warning   FailedMount                   pod/pg-v2-3                         MountVolume.MountDevice failed for volume "pvc-aa8851f4-11fb-412b-9573-813db66c3895" : kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient: driver n
12m         Warning   FailedMount                   pod/pg-v2-3                         MountVolume.MountDevice failed for volume "pvc-aa8851f4-11fb-412b-9573-813db66c3895" : rpc error: code = InvalidArgument desc = volume pvc-aa8851f4-11fb-412b-9573-813db66c3
8m35s       Warning   NodeNotReady                  pod/pg-v2-1                         Node is not ready
110s        Warning   FailedMount                   pod/pg-v2-1                         MountVolume.MountDevice failed for volume "pvc-116ef239-12c4-4685-a7df-b1a1ec7949dc" : kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient: driver n
110s        Warning   FailedMount                   pod/pg-v2-1                         MountVolume.SetUp failed for volume "kube-api-access-blgfs" : object "v2test"/"kube-root-ca.crt" not registered
55s         Warning   FailedMount                   pod/pg-v2-1                         MountVolume.MountDevice failed for volume "pvc-116ef239-12c4-4685-a7df-b1a1ec7949dc" : rpc error: code = InvalidArgument desc = volume pvc-116ef239-12c4-4685-a7df-b1a1ec794
```

## B2.log

```text
### B2 19:53:58 ks-w2(pg-r3-2, 3벌 복제 볼륨) 강제 정지 — 아무것도 안 하고 13분 관찰
killed 19:54:02
+1s 19:54:03 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy | pg 2/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w2 
+27s 19:54:29 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attached/healthy | pg 2/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w2 
+38s 19:54:40 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attached/healthy | pg 2/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w2 
+43s 19:54:45 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attached/unknown | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w2 
+340s 19:59:42 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attaching/unknown | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Terminating(1/1)@ks-w2 
--- 13분 시점
  pg-r3-1 1/1 Running ks-w1
  pg-r3-2 1/1 Terminating ks-w2
  pvc-92489207-301c-4de1-a69e-3e5c159e941d ks-w1 true
  pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21 ks-w2 true
16m         Warning   FailedScheduling              pod/pg-r3-2-join-4hhqg              0/8 nodes are available: persistentvolumeclaim "pg-r3-2" not found. not found
14m         Warning   FailedMount                   pod/pg-r3-2                         MountVolume.MountDevice failed for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" : kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient: driver name driver.longhorn.
14m         Warning   FailedMount                   pod/pg-r3-2                         MountVolume.MountDevice failed for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" : rpc error: code = InvalidArgument desc = volume pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21 hasn't been atta
12m         Warning   NodeNotReady                  pod/pg-r3-2                         Node is not ready
### B3 20:07:03 out-of-service taint 적용
node/ks-w2 tainted
+0s 20:07:03 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attaching/unknown | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Terminating(1/1)@ks-w2 
+5s 20:07:08 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded detaching/unknown | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Init:0/1(0/1)@ks-w3 
+11s 20:07:14 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attaching/healthy | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Init:0/1(0/1)@ks-w3 
+16s 20:07:19 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attached/degraded | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(0/1)@ks-w3 
+27s 20:07:30 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/degraded attached/degraded | pg 2/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
  pg-r3-1 1/1 Running ks-w1
  pg-r3-2 1/1 Running ks-w3
### 기동 20:07:30
node/ks-w2 untainted
up 20:08:04
+0s 20:08:04 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/faulted attached/healthy attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-2 | pg-v2-1=Pending(0/1)@<none> pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+27s 20:08:31 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/faulted attached/healthy attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+98s 20:09:42 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/unknown attached/healthy attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+125s 20:10:09 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/unknown attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Terminating(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+130s 20:10:14 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: detached/unknown attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+141s 20:10:25 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attaching/unknown attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+146s 20:10:30 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/unknown attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+152s 20:10:36 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+163s 20:10:47 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+169s 20:10:53 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c29037894912 uuid=4eda0d98 | vol: attached/healthy attached/healthy attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
DONE
```

## C1.log

```text
### C1 20:11:15 (UTC 11:11:15) primary=pg-v2-2 가 있는 ks-w3 강제 정지 — 파드는 건드리지 않음, 7분 관찰
killed 20:11:20 (UTC 11:11:20)
+0s 20:11:20 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+42s 20:12:02 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/degraded attached/healthy attached/healthy | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+47s 20:12:07 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/unknown attached/degraded attached/healthy attached/unknown | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+349s 20:17:09 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attaching/unknown | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Terminating(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+370s 20:17:30 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attaching/unknown | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Terminating(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+386s 20:17:46 node=NotReady disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attaching/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Terminating(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
  pg-v2-1 Running ks-w2 primary
  pg-v2-2 Terminating ks-w3 unhealthy
  pg-v2-3 Running ks-w1 replica
### 기동 20:18:23
up 20:18:54
+0s 20:18:54 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attaching/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Terminating(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+11s 20:19:05 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attaching/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Unknown(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+27s 20:19:21 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attaching/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+38s 20:19:32 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy detaching/faulted | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+44s 20:19:38 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy detaching/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+49s 20:19:43 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attached/unknown | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+55s 20:19:49 node=Ready disk=False//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/faulted attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+82s 20:20:16 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy detached/unknown attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+87s 20:20:21 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/unknown attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+92s 20:20:26 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Init:0/1(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+103s 20:20:37 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/degraded attached/healthy attached/degraded | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+109s 20:20:43 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy attached/healthy attached/healthy | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(0/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+114s 20:20:48 node=Ready disk=True//dev/disk/by-id/wwn-0x5000c2944851f80e uuid=1d0ae6f0 | vol: attached/healthy attached/healthy attached/healthy attached/healthy attached/healthy | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
  pg-v2-1 Running ks-w2 primary
  pg-v2-2 Running ks-w3 replica
  pg-v2-3 Running ks-w1 replica
samples 996 11:00:49 ~ 11:20:48
write fail runs: ['11:11:22~11:17:48 (336 samples)']
read fail runs: none
DONE
```

## C2.log

```text
### 20:22:18 (UTC 11:22:18) pg-r3 primary=pg-r3-1 @ ks-w1 강제 정지. operator: ks-w3 ks-w2  leader=cnpg-cloudnative-pg-75c894985d-vqpb
killed 20:22:22 (UTC 11:22:22)
+1s 20:22:23 Ready | pg 2/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+22s 20:22:44 Ready | pg 2/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+48s 20:23:10 NotReady | pg 1/2 primary=pg-r3-1 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+85s 20:23:47 NotReady | pg 1/2 primary=pg-r3-2 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
### 기동 20:26:26
up 20:26:53
+0s 20:26:54 Ready | pg 1/2 primary=pg-r3-2 | pg-r3-1=Unknown(0/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+32s 20:27:26 Ready | pg 1/2 primary=pg-r3-2 | pg-r3-1=Unknown(0/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+48s 20:27:42 Ready | pg 1/2 primary=pg-r3-2 | pg-r3-1=Unknown(0/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+54s 20:27:48 Ready | pg 1/2 primary=pg-r3-2 | pg-r3-1=Unknown(0/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+64s 20:27:58 Ready | pg 1/2 primary=pg-r3-2 | pg-r3-1=Init:0/1(0/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+70s 20:28:04 Ready | pg 1/2 primary=pg-r3-2 | pg-r3-1=Running(0/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+80s 20:28:14 Ready | pg 2/2 primary=pg-r3-2 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
+91s 20:28:25 Ready | pg 2/2 primary=pg-r3-2 | pg-r3-1=Running(1/1)@ks-w1 pg-r3-2=Running(1/1)@ks-w3 
samples 346 11:21:48 ~ 11:28:25
write fail runs: ['11:22:25~11:23:51 (56 samples)']
read fail runs: ['11:23:52~11:28:11 (245 samples)']
DONE
```

## C3.log

```text
### 20:28:56 (UTC 11:28:56) pg-v2 primary=pg-v2-1 @ ks-w2 강제 정지. operator: ks-w3 ks-w2  leader=cnpg-cloudnative-pg-75c894985d-vqpb
killed 20:29:00 (UTC 11:29:00)
+1s 20:29:01 Ready | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+32s 20:29:32 Ready | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+38s 20:29:38 NotReady | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+43s 20:29:43 NotReady | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+59s 20:29:59 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
### 기동 20:33:04
up 20:33:32
+0s 20:33:32 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+43s 20:34:15 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+49s 20:34:21 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+102s 20:35:14 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+108s 20:35:20 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+129s 20:35:41 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+135s 20:35:47 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+140s 20:35:52 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(0/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
+162s 20:36:14 Ready | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@ks-w3 pg-v2-3=Running(1/1)@ks-w1 
samples 470 11:27:11 ~ 11:36:14
write fail runs: ['11:29:02~11:30:00 (33 samples)']
read fail runs: none
DONE
```

## C4.log

```text
### 20:40:51 (UTC 11:40:51) pg-v2 primary=pg-v2-1 @ ks-w2 강제 정지. operator: ks-w3 19m  leader=cnpg-cloudnative-pg-75c894985d-6jgw
killed 20:40:56 (UTC 11:40:56)
+0s 20:40:56 Ready | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m13s pg-v2-2=Running(1/1)@20m pg-v2-3=Running(1/1)@ks-w1 
+5s 20:41:01 Ready | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m18s pg-v2-2=Running(1/1)@20m pg-v2-3=Running(1/1)@ks-w1 
+11s 20:41:07 Ready | pg 3/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m24s pg-v2-2=Running(1/1)@20m pg-v2-3=Running(1/1)@ks-w1 
+16s 20:41:12 NotReady | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m29s pg-v2-2=Running(1/1)@20m pg-v2-3=Running(1/1)@ks-w1 
+21s 20:41:17 NotReady | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m34s pg-v2-2=Running(1/1)@20m pg-v2-3=Running(1/1)@ks-w1 
+27s 20:41:23 NotReady | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m40s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+32s 20:41:28 NotReady | pg 2/3 primary=pg-v2-1 | pg-v2-1=Running(1/1)@5m45s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+37s 20:41:33 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@5m50s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+42s 20:41:38 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@5m56s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+48s 20:41:44 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m1s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+53s 20:41:49 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m6s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+58s 20:41:54 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m11s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+64s 20:42:00 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m17s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+69s 20:42:05 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m22s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+74s 20:42:10 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m27s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+80s 20:42:16 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m33s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+85s 20:42:21 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m38s pg-v2-2=Running(1/1)@21m pg-v2-3=Running(1/1)@ks-w1 
+90s 20:42:26 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m43s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+95s 20:42:31 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m49s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+101s 20:42:37 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m54s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+106s 20:42:42 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@6m59s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+111s 20:42:47 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m4s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+117s 20:42:53 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m10s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+122s 20:42:58 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m15s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+127s 20:43:03 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m20s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+133s 20:43:09 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m26s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+138s 20:43:14 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m31s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+143s 20:43:19 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m36s pg-v2-2=Running(1/1)@22m pg-v2-3=Running(1/1)@ks-w1 
+148s 20:43:24 NotReady | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@7m42s pg-v2-2=Running(1/1)@23m pg-v2-3=Running(1/1)@ks-w1 
### 기동 20:43:29
up 20:43:57
+0s 20:43:57 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m14s pg-v2-2=Running(1/1)@23m pg-v2-3=Running(1/1)@ks-w1 
+5s 20:44:02 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m20s pg-v2-2=Running(1/1)@23m pg-v2-3=Running(1/1)@ks-w1 
+11s 20:44:08 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m25s pg-v2-2=Running(1/1)@23m pg-v2-3=Running(1/1)@ks-w1 
+16s 20:44:13 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m30s pg-v2-2=Running(1/1)@23m pg-v2-3=Running(1/1)@ks-w1 
+22s 20:44:19 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m36s pg-v2-2=Running(1/1)@23m pg-v2-3=Running(1/1)@ks-w1 
+27s 20:44:24 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m41s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+32s 20:44:29 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m47s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+38s 20:44:35 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m52s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+43s 20:44:40 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@8m57s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+48s 20:44:45 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m3s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+54s 20:44:51 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m8s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+59s 20:44:56 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m13s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+65s 20:45:02 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m19s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+70s 20:45:07 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m24s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+75s 20:45:12 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m29s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+81s 20:45:18 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m35s pg-v2-2=Running(1/1)@24m pg-v2-3=Running(1/1)@ks-w1 
+86s 20:45:23 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m40s pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
+92s 20:45:29 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m46s pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
+97s 20:45:34 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m51s pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
+103s 20:45:40 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Unknown(0/1)@9m57s pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
+108s 20:45:45 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Init:0/1(0/1)@ks-w2 pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
+113s 20:45:50 Ready | pg 2/3 primary=pg-v2-2 | pg-v2-1=Running(0/1)@ks-w2 pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
+135s 20:46:12 Ready | pg 3/3 primary=pg-v2-2 | pg-v2-1=Running(1/1)@ks-w2 pg-v2-2=Running(1/1)@25m pg-v2-3=Running(1/1)@ks-w1 
samples 807 11:31:13 ~ 11:46:11
write fail runs: ['11:36:48~11:36:53 (6 samples)', '11:37:48~11:37:53 (6 samples)', '11:38:49~11:38:53 (4 samples)', '11:40:58~11:41:32 (24 samples)']
read fail runs: none
DONE
```

## S1.log

```text
### S1 11:36:47UTC switchover pg-v2-2 → pg-v2-1
cluster.postgresql.cnpg.io/pg-v2 patched
Cluster in healthy state 3 primary=pg-v2-1
### S2 11:37:47UTC switchover pg-v2-1 → pg-v2-2
cluster.postgresql.cnpg.io/pg-v2 patched
Cluster in healthy state 3 primary=pg-v2-2
### S3 11:38:48UTC switchover pg-v2-2 → pg-v2-1
cluster.postgresql.cnpg.io/pg-v2 patched
Cluster in healthy state 3 primary=pg-v2-1
samples 213 11:35:49 ~ 11:39:47
write fail runs: ['11:36:48~11:36:53 (6 samples)', '11:37:48~11:37:53 (6 samples)', '11:38:49~11:38:53 (4 samples)']
read fail runs: none
```

## boot.log

```text
Mon Nov 16 18:54:05 KST 2026
==> ks-tor: Machine booted and ready!
==> ks-tor: Machine already provisioned. Run `vagrant provision` or use the `--provision`
==> ks-cp1: Machine booted and ready!
==> ks-cp1: Machine already provisioned. Run `vagrant provision` or use the `--provision`
==> ks-cp2: Machine booted and ready!
==> ks-cp2: Machine already provisioned. Run `vagrant provision` or use the `--provision`
==> ks-cp3: Machine booted and ready!
==> ks-cp3: Machine already provisioned. Run `vagrant provision` or use the `--provision`
Mon Nov 16 18:56:06 KST 2026
==> ks-w1: Machine booted and ready!
==> ks-w1: Machine already provisioned. Run `vagrant provision` or use the `--provision`
==> ks-w2: Machine booted and ready!
==> ks-w2: Machine already provisioned. Run `vagrant provision` or use the `--provision`
==> ks-w3: Machine booted and ready!
==> ks-w3: Machine already provisioned. Run `vagrant provision` or use the `--provision`
Mon Nov 16 18:57:19 KST 2026
프록시 시작: http://172.16.141.1:3128
vm.swapusage: total = 5120.00M  used = 3854.00M  free = 1266.00M  (encrypted)
```

