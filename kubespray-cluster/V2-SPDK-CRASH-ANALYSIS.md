# V2 볼륨이 안 붙는 문제: 원인 분석과 조치 (내부 LLM 전달용)

실서버에서 모은 관측을 정리하고, 원인 추정과 조치 순서를 적었다. 이 문서 하나만 내부 LLM 에 붙여 넣어도 되도록 앞뒤 사정을 모두 담았다. 앞 단계 문서는 [V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md), [V2-DELAY-HYPOTHESES.md](V2-DELAY-HYPOTHESES.md) 이다.

> **근거 수준 표시**
> - **관측**: 실서버에서 사람이 직접 본 출력이다. 이 문서 작성자는 실서버에 접근하지 못했고 전달받은 내용을 옮겼다.
> - **이슈**: Longhorn 공개 이슈에 적힌 내용이다.
> - **소스**: Longhorn 1.13.0 소스에서 읽은 동작이다. 실서버는 1.12.1 이라 다를 수 있다.
> - **랩**: 랩(Longhorn 1.13.0, 커널 6.8, arm64 VM)에서 직접 만든 결과다. 각 1번씩 했다.
> - **추정**: 위 넷을 이어 붙인 해석이다.

## 1. 한 줄 결론

Longhorn 1.12.1 의 알려진 버그로 `spdk_tgt` 가 죽은 것이 출발점일 가능성이 가장 높다 [추정]. 같은 계열 수정이 1.12.2(2026-11-09 출시)에 백포트 대상으로 표시되어 있다 [이슈]. 확정하려면 실서버 인스턴스 매니저 로그에서 `Assertion` 줄을 찾아야 한다(5절 1번).

## 2. 환경 [관측]

| 항목 | 값 |
|---|---|
| 플랫폼 | VMware ESXi 위 VM |
| 노드 | 마스터 3 (16 vCPU), 워커 7 (36 vCPU, 256GB) |
| OS / 커널 | RHEL 10.2 / 6.12.0-211.44.1.el10_2 |
| 런타임 / k8s | containerd 2.3.5 / Kubernetes 1.36.4 |
| Longhorn | 1.12.1, V1·V2 데이터 엔진 동시 사용 |
| V2 디스크 | 워커마다 `/dev/sdc` 2TB, block, aio, 태그 `longhorn-v2` |
| V2 설정 | hugepage 사용, 메모리 2048, CPU 코어 2 |
| CPU 격리 | 없음 (`cpuset` 비어 있음, `isolcpus` 없음) |
| 워크로드 | CNPG PostgreSQL 인스턴스 3개 |
| StorageClass | `dataEngine: v2`, `numberOfReplicas: "3"`, `dataLocality: best-effort`, `fsType: xfs`, `WaitForFirstConsumer` |

## 3. 증상과 관측 [관측]

**겉으로 보이는 것**

- V2 볼륨이 붙는 데 수 분에서 수십 분이 걸리거나 끝내 안 붙는다. 같은 볼륨도 매번 시간이 다르다.
- `FailedAttachVolume … DeadlineExceeded` 가 반복되고, 몇 분 뒤 `SuccessfulAttachVolume` 이 뜨기도 한다.
- CNPG 클러스터가 `Cluster is unrecoverable and needs manual intervention` 이 되고 파드가 하나도 안 뜬다.

**Longhorn 로그**

```
failed to disconnect target for NVMe/TCP initiator pvc-…:
  failed after 10 attempts to refresh stale namespace directory:
  timeout executing: nsenter … nvme disconnect -n nqn.2023-01.io.longhorn.spdk:volume-pvc-…
error sending message, method bdev_raid_create, params {Name:…-e-0 RaidLevel:1 BaseBdevs:[] …}:
  {"code": -22, "message": "Failed to create RAID bdev …: Invalid argument"}
found instance manager name conflict instance-manager-… vs instance-manager-… during engine frontend instance creation
failed to delete instance pvc-…: rpc error: code = DeadlineExceeded
Marking the instance as state ERROR since the starting instance manager … shouldn't contain the running instance pvc-…
Retrying NVMe/TCP target connect: … attempt=9/15 … could not add new controller: connection refused
```

**노드 상태**

- 워커 7대 중 5대에 `Suspended` 인 dm 장치가 남아 있다. 전부 다른 사용자의 볼륨이다.
- 밑장치(`nvme1n1`)가 살아 있고 컨트롤러가 `live` 인데도 dm 만 `Suspended` 인 것이 있다.
- `blkid -p -s TYPE -s PTTYPE -o export /dev/longhorn/<pv>` 가 약 2분마다 새로 생기고 전부 `D` 상태다. 부모는 `longhorn-manager -d csi` 다. 한 노드에 31개, dm 의 Open 수와 일치한다.
- `D` 상태 스택: `nvme disconnect` 는 `nvme_sysfs_delete → nvme_delete_ctrl_sync → nvme_disable_ctrl → nvmf_reg_write32`, 다른 `nvme` 와 `kworker` 는 `__synchronize_srcu` (`nvme_ns_remove`, `fsnotify_mark_destroy_workfn`, `nvme_ana_work`), `blkid` 는 `folio_wait_bit_common`.

**커널 dmesg**

```
nvme nvme0: I/O tag 1 (f001) type 4 opcode 0x7f (Fabrics Cmd) QID 0 timeout
nvme nvme0: Property Set error: 881, offset 0x14
nvme nvme0: Property Set error: 880, offset 0x14
attempt to access beyond end of device  nvme0n1: … limit=0
XFS (dm-2): log I/O error -5 / Filesystem has been shut down due to log error
ata1: lost interrupt (Status 0x58)      ← 8번
NMI watchdog: Perf NMI watchdog permanently disabled
```

**문제 노드와 정상 노드를 같은 시각에 비교**

| 항목 | 문제 노드 | 정상 노드 |
|---|---|---|
| `spdk_tgt` 실행 시간 | 8분 | 1일 1시간 |
| 노드 uptime | 58일 | 58일 |
| reactor 스레드 | 2개, 각 99.9% | 2개, 각 99.9% |
| load average | 6.44 / 9.34 / 10.77 | 3.80 / 3.36 / 3.38 |
| steal, iowait 증가 (10초) | 없음 | 없음 |
| 여유 메모리 | 241GiB / 251GiB | 241GiB / 251GiB |

**같은 노드에서 같은 시각에 일어난 것**

- V1·V2 인스턴스 매니저와 engine-image 파드의 liveness 프로브가 함께 `timed out after 10s`.
- kubelet 저널에 `cannot exec in a stopped state`, `KillPodSandbox … DeadlineExceeded`.
- 파드 `restarts=0` 인 채 새로 만들어짐.

## 4. 원인 분석

### 4.1 추정 사슬

| 단계 | 내용 | 근거 |
|---|---|---|
| ① | 노드가 잠깐 멎거나 쓰기가 몰린다 | 관측: `ata1: lost interrupt`, V1 프로브까지 동시 실패. 무엇이 멎게 했는지는 모른다 |
| ② | Longhorn 이 건 `dmsetup suspend` 가 30초를 넘겨 실패한다 | 소스: V2 는 스냅샷·복제본 재구축·확장 때 프런트엔드 dm 을 멈춘다. `DmsetupTimeout` 30초 |
| ③ | 멈춤에 실패해도 그대로 진행하다 `spdk_tgt` 가 assertion 으로 죽는다 | 이슈 #14411, #14353. 실서버 로그에서 assertion 줄은 아직 못 봤다 |
| ④ | 죽은 타깃 때문에 커널 nvme-tcp 가 끊기고, 멈춘 dm 은 풀어 줄 쪽이 없어 `Suspended` 로 남는다 | 관측: 밑장치가 살아 있는데 dm 만 `Suspended` |
| ⑤ | `nvme disconnect` 와 `blkid` 가 `D` 상태로 쌓인다 | 관측. `blkid` 누적은 랩 K13c 와 같은 모양 |
| ⑥ | 다시 뜬 `spdk_tgt` 는 비어 있는데 CRD 는 예전 상태라 어긋난다 | 관측: `name conflict`, `BaseBdevs:[]`, `shouldn't contain the running instance` |

①→② 는 추정이다. ②→③ 은 이슈에 적힌 동작이다.

### 4.2 관련 Longhorn 이슈 [이슈]

| 이슈 | 내용 | 표시 |
|---|---|---|
| [#14411](https://github.com/longhorn/longhorn/issues/14411) | 재구축 마무리에서 `dmsetup suspend` 가 30초를 넘기면 멈춤 없이 진행하고, I/O 가 흐르는 채 parent 를 바꾸다 `spdk_tgt` abort (`bdev_channel_destroy_resource`) | backport/1.12.2 |
| [#14353](https://github.com/longhorn/longhorn/issues/14353) | 쓰기 중 스냅샷(재구축 스냅샷 포함)과 겹치면 `spdk_tgt` abort (`blob_insert_cluster_msg`). 이슈에 실린 로그 문구가 실서버 것과 같다: `failed to suspend linear dm device … failed after 10 attempts to refresh stale namespace directory: timeout executing … dmsetup suspend` | backport/1.12.2 |
| [#14344](https://github.com/longhorn/longhorn/issues/14344) | 1.12.1 에서 디스크를 다시 읽을 때 `spdk_tgt` abort 가 반복된다. 확장 뒤 스냅샷을 지운 볼륨이 계기다 | backport/1.12.2 |
| [#14417](https://github.com/longhorn/longhorn/issues/14417) | 재구축용 suspend 가 파일시스템 sync 를 기다리지 않도록 변경 (`--noflush --nolockfs`) | backport/1.12.2 |
| [#13331](https://github.com/longhorn/longhorn/issues/13331) | 1.12.0 에서 백업·스냅샷 뒤 NVMe/TCP 프런트엔드나 dm 이 낡은 채 남아 파드가 EIO. CNPG 사례 포함 | backport/1.12.1 (실서버 버전에 이미 포함) |

백포트 라벨만 확인했다. 1.12.2 릴리스 노트 본문과는 대조하지 않았다.

한 노드의 V2 디스크는 전부 `spdk_tgt` 하나가 맡는다. 그래서 하나가 죽으면 그 노드에 복제본을 둔 V2 볼륨이 모두 영향을 받는다 [이슈 #14353, #14344].

### 4.3 읽을 때 주의할 로그

- **`failed after 10 attempts to refresh stale namespace directory` 는 10번 재시도했다는 뜻이 아니다.** 재시도는 `nsenter: cannot open … No such file or directory` 일 때만 한다. 그 밖의 오류(타임아웃 포함)는 한 번에 끝나는데도 이 문구가 덧붙는다. 진짜 오류는 뒤의 `timeout executing` 이다 [소스 `go-common-libs/ns/executor.go:144-176`].
- **reactor 2개가 각각 99.9% 인 것은 정상이다.** 폴링 모드는 일이 없어도 CPU 를 다 쓴다. CPU 기아가 없었다는 증거로 쓸 수 없다.
- **`Property Set error: 880, offset 0x14` 는 타깃이 죽으면 정상 회복 과정에서도 나온다** [랩 T1·T2]. 이 줄만으로 고장이라고 볼 수 없다. `Fabrics Cmd … timeout` 과 `881` 은 랩에서 나오지 않았다.
- **exec 프로브 실패는 네트워크 문제가 아닐 수 있다.** exec 프로브는 containerd 가 컨테이너 안에 프로세스를 띄워야 한다. `cannot exec in a stopped state`, `KillPodSandbox DeadlineExceeded` 는 런타임이 느려졌다는 쪽을 가리킨다.
- **`ata1` 이 어느 디스크인지 모른다.** V2 디스크가 아닐 수 있다.

### 4.4 랩 시험: `spdk_tgt` 를 강제로 죽이면 [랩]

3중 복제 V2 볼륨이 붙어 있고 PostgreSQL 이 도는 노드에서 `kill -ABRT` 로 `spdk_tgt` 를 죽였다. 기록은 `v2test/results/t/`.

| 시험 | 한 일 | 결과 |
|---|---|---|
| T1 | dm `Active` 인 채 죽임 | 약 90초에 회복. dm 은 계속 `Active`, `D` 상태 없음 |
| T2 | `dmsetup suspend` 직후 죽임 | 약 75초에 회복. dm 이 `Suspended` 였다가 `Active` 로 돌아옴, `D` 상태 없음 |

두 시험 모두 같은 순서로 회복했다.

1. 커널이 2초 간격으로 15번 다시 붙으려다(`ctrl-loss-tmo` 30초) 컨트롤러를 지운다. 이때 `Property Set error: 880, offset 0x14` 가 한 번 나온다.
2. **인스턴스 매니저 파드가 통째로 새로 만들어진다** (파드 IP 가 바뀐다).
3. Longhorn 이 새 타깃에 다시 붙이고 dm 을 재개한다. 볼륨은 다시 마운트되고 복제본은 재구축된다.

**실서버와 다른 점**: 실서버는 파드가 그대로인데 `spdk_tgt` 만 새로 떴다고 관측됐다. 랩(1.13.0)은 파드가 새로 만들어졌고 그 뒤 정리가 끝까지 됐다. 이 차이가 버전 차이인지, 실서버 관측이 다시 확인이 필요한 것인지는 모른다(5절 2번).

**랩이 못 만든 것**: `nvme disconnect` 가 `D` 로 굳는 것, `Fabrics Cmd timeout`, `synchronize_srcu` 대기, CRD 이름 충돌, 노드 단위 프로브 실패. 랩은 타깃이 한 번 깨끗이 죽은 경우만 봤다. 실서버는 여러 볼륨이 붙은 채, 노드가 느려진 상황에서, 1.12.1 로 일어났다.

## 5. 실서버에서 확인할 것 (전부 읽기 전용)

| # | 알고 싶은 것 | 명령 | 판정 |
|---|---|---|---|
| 1 | `spdk_tgt` 가 왜 죽었나 | `kubectl -n longhorn-system logs <v2 instance-manager 파드> \| grep -E "Assertion\|proceeding without suspension\|Failed to suspend\|Performing recovery"` 와 노드에서 `coredumpctl list`, `journalctl -k \| grep -E "reactor_\|ABRT\|coredump"` | `Assertion` 줄이 있으면 4.2 의 이슈와 같은 문제다. 파일·줄 번호로 어느 이슈인지 가른다 |
| 2 | 파드가 정말 그대로였나 | `kubectl -n longhorn-system get pod <파드> -o jsonpath='{.metadata.creationTimestamp} {.status.containerStatuses[0].restartCount}'` 와 노드에서 `ps -o pid,etime,cmd -C spdk_tgt` | 파드 생성 시각이 `spdk_tgt` 시작보다 훨씬 앞이면 파드 안에서만 다시 뜬 것이다 |
| 3 | 문제 노드 5대가 모두 같은가 | 각 노드에서 `ps -o etime,cmd -C spdk_tgt` | 5대 모두 최근에 다시 떴으면 `spdk_tgt` 죽음이 공통 원인이다 |
| 4 | 죽기 직전에 무엇이 돌았나 | `kubectl -n longhorn-system get recurringjobs,snapshots,backups` 와 `kubectl get events -A \| grep -E "Rebuilding\|Rebuilt\|snapshot"` | 스냅샷·재구축·확장 시각이 `spdk_tgt` 시작 직전이면 ②③ 단계를 지지한다 |
| 5 | `ata1` 이 무엇인가 | `lsscsi`, `ls -l /sys/block/*/device` | 루트 디스크나 V2 디스크면 저장소 지연 쪽, CD-ROM 이면 무시해도 된다 |
| 6 | 하이퍼바이저가 VM 을 멈췄나 | 인프라 담당에게 같은 시간대의 CPU Ready, Co-stop, 데이터스토어 지연 요청 | 값이 튀면 ① 단계의 원인이다. 36 vCPU VM 은 Co-stop 이 생기기 쉽다 |
| 7 | CPU 를 뺏겼나 | `grep ctxt /proc/<reactor 스레드 tid>/status` 를 10초 간격으로 두 번 | `nonvoluntary_ctxt_switches` 가 빠르게 늘면 reactor 가 밀려나고 있다 |

## 6. 조치

### 6.1 지금 막힌 노드 풀기

다른 사용자의 볼륨이므로 소유자 동의가 먼저다. 아래 순서로 한 노드에서 먼저 해 본다.

1. **그 노드에 새 볼륨이 붙지 않게 한다.** `kubectl cordon <노드>`.
2. **밑장치가 살아 있는 dm 은 재개한다.** `dmsetup resume <이름>`. 랩 K13 에서는 재개 뒤 16~33초에 풀렸다.
3. **밑장치가 없거나 크기가 0 인 dm** 은 테이블을 `error` 타깃으로 바꾸고 재개하면 대기 중인 I/O 가 EIO 로 끝난다. `blkid` 가 풀리는지 본다. 실서버에서 해 보지 않은 방법이다.
4. **`nvme_delete_ctrl`, `__synchronize_srcu` 에 걸린 프로세스**는 시그널을 받지 않는다. 재부팅 말고 푸는 방법을 모른다. 정상 종료가 unmount 에서 걸리면 강제 재시작이 필요하다.
5. **재부팅 뒤 CRD 가 어긋나 있으면** etcd 를 직접 고치지 않는다. 워크로드를 내려 볼륨이 `detached` 가 될 때까지 기다린 뒤 다시 올린다.

### 6.2 재발 막기

| 조치 | 기대 효과 | 한계 |
|---|---|---|
| **1.12.2 로 올린다** | `spdk_tgt` abort 3건과 suspend 타임아웃 완화가 들어간다 | 릴리스 노트로 포함 여부를 먼저 확인한다 |
| 쓰기가 많은 시간대의 스냅샷·백업 반복 작업을 끈다 | ②③ 단계의 계기를 줄인다 | 임시 조치다 |
| `dataLocality: best-effort` → `disabled` | 파드가 옮겨 갈 때마다 생기는 재구축을 없앤다 | 기존 볼륨에는 볼륨 설정을 따로 바꿔야 한다 |
| CPU 격리 설정을 켠다 | reactor 가 인터럽트·커널 작업에 밀리는 일을 줄여 suspend 타임아웃 가능성을 낮춘다 | assertion 버그 자체는 못 고친다. 1.12.1 에 이 설정이 있는지 확인이 필요하다 |
| ESXi CPU 예약 | CPU Ready·Co-stop 이 높을 때만 효과가 있다 | 값을 먼저 재야 한다 |
| `instance-manager-pod-liveness-probe-timeout` 을 늘린다 | 잠깐 멎었을 때 파드가 죽는 일을 줄인다 | 증상을 가릴 뿐이다 [소스: 기본 10초, 실패 6번] |

### 6.3 복제본 1개 구성

CNPG 가 인스턴스 3개로 복제하므로 스토리지 복제는 겹친다. `numberOfReplicas: "1"` 로 두면 재구축이 없어져 이번 문제의 계기 하나가 사라진다. 랩에서는 `pg_test_fsync` 가 초당 538번에서 4,273번으로 올랐다 [랩, PERF-TEST.md].

조건은 다음과 같다.

- 인스턴스 3개가 서로 다른 노드에 있어야 한다.
- 동기 복제와 클러스터 밖 백업이 있어야 한다.
- 노드 하나를 잃으면 그 인스턴스는 처음부터 다시 복제한다. 데이터가 크면 오래 걸린다.

V2 에서 `dataLocality: strict-local` 이 되는지는 확인하지 못했다.

## 7. 내부 LLM 에 줄 지시문

아래를 이 문서와 함께 붙여 넣는다.

```
너는 Longhorn V2 장애 분석을 돕는다. 위 문서가 지금까지 알려진 전부다.

규칙
1. 내가 붙여 넣는 실서버 출력만 증거로 쓴다. 문서의 [추정] 은 증거가 아니다.
2. 출력마다 4.1 의 단계 ①~⑥ 중 무엇을 지지·반박하는지 표로 답한다. 판단할 수 없으면 "판단 불가"라고 쓴다.
3. 판단 불가인 단계마다 5절에서 읽기 전용 명령 하나만 고른다. 5절에 없으면 새로 제안하되 읽기 전용이어야 한다.
4. 상태를 바꾸는 명령(dmsetup resume, reload, kubectl delete, patch, 재부팅)은 내가 요청할 때만 내고, 무엇이 바뀌고 되돌릴 수 있는지 함께 쓴다.
5. Assertion 줄이 나오면 파일 이름과 줄 번호로 4.2 의 어느 이슈인지 말한다. 맞는 것이 없으면 없다고 쓴다.
6. 랩 결과는 Longhorn 1.13.0 기준이다. 실서버 1.12.1 에 그대로 적용하지 않는다.

먼저 할 일
- 5절 1번과 2번의 출력을 요청한다.
```

## 8. 아직 모르는 것

- `spdk_tgt` 를 실제로 죽인 것이 무엇인지 (assertion 줄 미확인)
- 노드가 멎는 원인이 하이퍼바이저인지, 굳은 장치가 커널을 붙잡아서인지
- 1.12.1 에서 `spdk_tgt` 가 죽은 뒤 인스턴스 매니저가 어떻게 동작하는지 (랩은 1.13.0)
- 1.12.2 가 실서버 환경에서 실제로 이 증상을 없애는지
