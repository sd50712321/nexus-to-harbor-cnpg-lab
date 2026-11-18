# V2 볼륨이 안 붙는 문제: 원인 분석과 조치 (내부 LLM 전달용)

실서버에서 모은 관측을 정리하고, 원인 추정과 조치 순서를 적었다. 이 문서 하나만 내부 LLM 에 붙여 넣어도 되도록 앞뒤 사정을 모두 담았다. 앞 단계 문서는 [V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md), [V2-DELAY-HYPOTHESES.md](V2-DELAY-HYPOTHESES.md) 이다.

> **근거 수준 표시**
> - **관측**: 실서버에서 사람이 직접 본 출력이다. 이 문서 작성자는 실서버에 접근하지 못했고 전달받은 내용을 옮겼다.
> - **이슈**: Longhorn 공개 이슈에 적힌 내용이다.
> - **소스**: Longhorn 1.13.0 소스에서 읽은 동작이다. 실서버는 1.12.1 이라 다를 수 있다.
> - **랩**: 랩(커널 6.8, arm64 VM, 워커 2 vCPU)에서 직접 만든 결과다. T1·T2 는 Longhorn 1.13.0, T3~T7 은 실서버와 같은 1.12.1 이다. 각 1번씩 했다.
> - **추정**: 위 넷을 이어 붙인 해석이다.

## 1. 한 줄 결론

두 가지가 겹친 것으로 본다.

- **출발점**: Longhorn 1.12.1 의 알려진 버그로 `spdk_tgt` 가 죽거나 멎는다 [추정]. 같은 계열 수정이 1.12.2(2026-11-09 출시)에 백포트 대상으로 표시되어 있다 [이슈]. 확정하려면 실서버 인스턴스 매니저 로그에서 `Assertion` 줄을 찾아야 한다(5절 1번).
- **길게 굳는 이유**: 랩을 1.12.1 로 맞춰 `spdk_tgt` 를 죽이거나 멈춰 보면 실서버와 같은 로그와 고아 dm 이 나오지만 2분 30초 안에 회복한다 [랩]. 회복은 kubelet 이 프로브 실패로 파드를 죽이고 새로 만드는 데 달려 있다. 실서버는 그 프로브와 파드 정리까지 타임아웃이었다 [관측]. 노드가 같이 멎어 정리가 못 끝난 것으로 본다 [추정].

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

### 4.4 랩 시험: `spdk_tgt` 를 죽이거나 멈추면 [랩]

처음 두 번(T1·T2)은 Longhorn 1.13.0 에서 했다. 버전이 달라 의미가 약하므로 랩을 **1.12.1 로 새로 깔고** 실서버와 같은 StorageClass(`dataEngine: v2`, 3벌, `best-effort`, `xfs`, `diskSelector`, `nodeSelector`, aio 디스크)와 CNPG 3 인스턴스로 다시 했다(T3~T7). 각 1번씩이다. 기록은 `v2test/results/t/`.

| 시험 | 버전 | 한 일 | 결과 |
|---|---|---|---|
| T1 | 1.13.0 | dm `Active` 인 채 `kill -ABRT` | 약 90초에 회복. 남는 것 없음 |
| T2 | 1.13.0 | `dmsetup suspend` 직후 `kill -ABRT` | 약 75초에 회복. `Suspended` → `Active` |
| T3 | 1.12.1 | dm `Active` 인 채 `kill -ABRT` | 약 2분 30초에 회복. **XFS 가 꺼지고, 파드가 다른 노드로 옮겨 가고, 원래 노드에 고아 dm 이 남음** |
| T4 | 1.12.1 | `dmsetup suspend` 직후 `kill -ABRT` | 약 75초에 같은 노드에서 회복. `Suspended` → `Active` |
| T5 | 1.12.1 | T3 의 고아 dm 을 `Suspended` 로 두고 같은 볼륨을 그 노드에 다시 붙임 | 11초에 붙음. Longhorn 이 고아 dm 을 치웠다 (Open 0 이었다) |
| T6 | 1.12.1 | 쓰기 중에 `kill -STOP` (죽이지 않고 멈춤) | 약 2분에 회복. liveness 프로브가 실패해 kubelet 이 파드를 죽인 뒤에야 풀림 |
| T7 | 1.12.1 | `kill -STOP` 직후 파드를 지워 볼륨을 떼게 함 | 타깃이 멎어 있는 약 100초 동안 `umount` 가 `D` 상태. 파드가 죽은 뒤 풀림 |

**실서버 관측과 같은 것이 나온 항목**

| 실서버 관측 | 랩에서 나온 시험 | 랩 출력 |
|---|---|---|
| `dm-1 slaves=[nvme0n1]` 인데 `nvme0` 컨트롤러가 없음 | T3 | `pvc-…a02f… Active 0`, `slaves=[nvme0n1]`, `/sys/class/nvme/` 에는 `nvme1` 만 |
| `XFS (dm-N): log I/O error -5`, `Filesystem has been shut down due to log error (0x2)` | T3, T7 | 같은 문구 |
| `Property Set error: 880, offset 0x14` | T1~T7 전부 | 같은 문구. 회복하는 경우에도 나온다 |
| `I/O tag 1 (f001) type 4 opcode … QID 0 timeout` | T6, T7 | `opcode 0x18 (Admin Cmd)`. 실서버는 `0x7f (Fabrics Cmd)` |
| `attempt to access beyond end of device … limit=0` | T6 | `nvme0n1: rw=2048, sector=0, nr_sectors = 64 limit=0` |
| `Marking the instance as state ERROR since the starting instance manager … shouldn't contain the running instance` | T7 | 같은 문구 (engine, replica, engine frontend 각각) |
| V2 인스턴스 매니저 `Liveness probe failed` | T6, T7 | `Unhealthy` → `Killing` → `FailedPreStopHook` |
| CSI 쪽 프로세스가 `D` 상태 | T7 | `umount /var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/…` 가 100초 |

**랩에서 나오지 않은 것**

- 몇 분 넘게 굳는 것. 가장 긴 것이 T3 의 2분 30초다.
- `opcode 0x7f (Fabrics Cmd) timeout`, `Property Set error: 881`
- `nvme disconnect` 가 `D` 로 남는 것, `__synchronize_srcu` 대기
- `found instance manager name conflict`, `bdev_raid_create … BaseBdevs:[]`
- V1 인스턴스 매니저 프로브까지 같이 실패하는 노드 단위 멈춤

**여기서 읽을 수 있는 것**

1. **죽은 타깃은 금방 정리되고, 멎은 타깃은 멎어 있는 동안 계속 붙잡는다.** `kill -ABRT` 는 커널이 `connection refused` 를 받고 30초 뒤 포기한다. `kill -STOP` 은 TCP 는 붙는데 응답이 없어, 타깃이 사라질 때까지 `umount` 가 `D` 로 기다렸다 [랩 T6·T7].
2. **랩이 2분에 풀린 것은 kubelet 이 멎은 `spdk_tgt` 를 죽였기 때문이다.** 프로브 6번 실패(약 60초) 뒤 파드를 죽이고 새로 만든다. 실서버는 그 프로브 실행 자체가 `timed out` 이었고 `KillPodSandbox` 도 `DeadlineExceeded` 였다. 즉 정리하는 손이 같이 멎었다 [추정].
3. **따라서 실서버가 길게 굳는 조건은 "`spdk_tgt` 가 죽은 것"만으로는 부족하다.** `spdk_tgt` 가 응답 없이 살아 있거나, 죽인 뒤 정리가 못 끝나는 시간이 길어야 한다. 그 시간은 노드가 멎는 길이를 따라가므로 매번 다르다 [추정].
4. **고아 dm 은 1.12.1 에서 실제로 남는다.** 다만 여는 프로세스가 없으면 다음 부착 때 치워진다. 실서버의 고아 dm 은 `blkid` 가 열고 있어(Open 수 = `blkid` 수) 치워지지 못하는 것으로 보인다 [T5 + 추정].

## 5. 실서버에서 확인할 것 (전부 읽기 전용)

| # | 알고 싶은 것 | 명령 | 판정 |
|---|---|---|---|
| 1 | `spdk_tgt` 가 왜 죽었나 | `kubectl -n longhorn-system logs <v2 instance-manager 파드> \| grep -E "Assertion\|proceeding without suspension\|Failed to suspend\|Performing recovery"` 와 노드에서 `coredumpctl list`, `journalctl -k \| grep -E "reactor_\|ABRT\|coredump"` | `Assertion` 줄이 있으면 4.2 의 이슈와 같은 문제다. 파일·줄 번호로 어느 이슈인지 가른다 |
| 2 | `spdk_tgt` 가 죽었나, 멎었나. 파드는 그대로였나 | `kubectl -n longhorn-system get pod <파드> -o jsonpath='{.metadata.creationTimestamp} {.status.containerStatuses[0].restartCount}'` 와 노드에서 `ps -o pid,etime,cmd -C spdk_tgt` | 파드 생성 시각이 `spdk_tgt` 시작보다 훨씬 앞이면 파드 안에서만 다시 뜬 것이다 |
| 2-1 | 멎어 있던 흔적이 있나 | 노드에서 `journalctl -k \| grep -E "QID 0 timeout\|failed to receive icresp\|Failed reconnect attempt"` | `icresp` 실패와 12초 간격 재시도면 타깃이 응답 없이 살아 있었다(랩 T6). `failed to connect socket: -111` 과 2초 간격이면 타깃이 죽어 있었다(랩 T3) |
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
6. 랩은 Longhorn 버전만 실서버와 같다(1.12.1). 커널, CPU 종류, 노드 크기가 달라 랩의 시간 값을 실서버에 그대로 적용하지 않는다.

먼저 할 일
- 5절 1번과 2번의 출력을 요청한다.
```

## 8. 아직 모르는 것

- `spdk_tgt` 를 실제로 죽인 것이 무엇인지 (assertion 줄 미확인)
- 노드가 멎는 원인이 하이퍼바이저인지, 굳은 장치가 커널을 붙잡아서인지
- `spdk_tgt` 가 죽은 것인지 응답 없이 멎어 있던 것인지, 멎었다면 얼마나 오래였는지
- 랩에서 못 만든 `Fabrics Cmd timeout`, `name conflict`, `BaseBdevs:[]` 가 어떤 조건에서 나오는지
- 1.12.2 가 실서버 환경에서 실제로 이 증상을 없애는지
