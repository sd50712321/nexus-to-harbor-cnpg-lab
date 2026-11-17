# V2 볼륨 지연: 원인 후보별로 "이렇게 보여야 한다"

[V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md) 의 다음 단계다. 원인 후보를 넓게 늘어놓고, 각 후보가 맞다면 실서버에서 **무엇이 어떻게 보여야 하는지**를 적었다. 실서버 출력을 이 문서와 맞대어 후보를 지워 나가는 용도다.

> **읽는 법.** 후보마다 근거 수준을 붙였다.
> - **실측**: 랩(Longhorn 1.13.0 V2, 커널 6.8, CNPG 1.30.1)에서 직접 만들어 본 출력이다.
> - **소스**: Longhorn 1.13.0 소스에서 읽은 동작이다. 랩에서 만들지는 못했다.
> - **추정**: 일반 원리에서 끌어낸 것이다. 출력 예시는 형태만 맞고 글자는 다를 수 있다.
>
> 예시 출력의 이름(`pvc-1234…`, `worker-3`)은 지어낸 것이다. 실서버 Longhorn 버전이 1.13.0 과 다르면 리소스 이름과 로그 문구가 다를 수 있다.

## 1. 지금까지 확인된 것과 아닌 것

들은 증상: 파드 재기동 때 볼륨이 6분·18분·31분·1시간쯤 늦게 붙고 저절로 풀린다. 파드는 `Init`, Longhorn 파드는 전부 `Running`, 노드는 `Ready`, `dmesg` 에 `task kworker/u152… blocked for more than 122 seconds`, 저장소는 비어 있다.

| 구분 | 내용 |
|---|---|
| 랩에서 만든 케이스 | K1~K13, 17개 기록. 각 1번씩 |
| 모양이 맞은 것 | 볼륨 장치의 I/O 가 끝나지 않는 상태(K13c): `Init:0/1`, 볼륨 `attached/healthy`, Longhorn 파드 전부 Running |
| 커널 기록이 맞은 것 | K13a·b: `blocked for more than 122 seconds` (작업 이름은 `postgres`·`jbd2`, 실서버는 `kworker`) |
| 랩에서 안 된 것 | 저절로 풀리는 것. 랩은 일부러 멈추고 일부러 풀었다 |
| 영향 없다고 본 것 | CNPG 자체, 파일을 잡은 프로세스, fanotify 감시(커널 6.8), 커널 모듈, 디스크 크기(10GB 대 100GB), 시계 |
| 시험 못 한 것 | 3절의 H1, H2(값이 다른 경우), H3(실제 하이퍼바이저), H7, H8, H11, 파티션 등록 디스크 |

## 2. 먼저 가를 질문 세 개

후보가 많아 보여도 아래 세 가지로 대부분 갈린다.

| 질문 | 확인 | 갈림 |
|---|---|---|
| ① 볼륨이 **붙었는데** 못 쓰는가, **못 붙는가** | 파드 이벤트가 `FailedMount` 인가 `FailedAttachVolume` 인가 | `FailedMount` → H1·H2·H3·H8·H11. `FailedAttachVolume` → H4·H5·H6·H7 |
| ② 늦는 볼륨이 **새로 만든 것**인가 **쓰던 것**인가 | PVC 생성 시각과 지연 시각 | 새 볼륨에서만 → H8. 쓰던 볼륨도 → 나머지 |
| ③ 지연 길이가 **볼륨 크기**를 따라가는가 | 큰 볼륨일수록 오래 걸리는지 | 따라감 → H7·H8. 무관 → H1·H2·H3 |

## 3. 후보별 예상 출력

### H1. Longhorn 이 스스로 장치를 멈춘 뒤 재개가 늦다 [소스 + 모양은 실측]

- **원리.** V2 엔진은 스냅샷 생성, 복제본 추가(재구축), 볼륨 확장 때 프런트엔드 장치를 `suspend` 했다가 `resume` 한다(`longhorn-spdk-engine` `pkg/spdk/enginefrontend.go:2449`, `pkg/spdk/server.go:804`). 멈춘 동안 그 장치로 가는 I/O 는 줄을 서서 기다린다. 재개가 실패하면 멈춘 채 남을 수 있다고 소스 주석에 있다.
- **저절로 풀리는 이유(추정).** 뒤따르는 작업(재구축 완료, 다음 스냅샷, instance-manager 재시작)이 장치를 다시 만들거나 재개한다. 그래서 길이가 일정하지 않다.
- **맞다면 이렇게 보인다.**

```text
$ sudo dmsetup info -c -o name,suspended,open | grep pvc-
pvc-1234…   Suspended   1          ← 지연 중인 볼륨만 Suspended
pvc-5678…   Active      1

$ ps -eo stat,etime,args | awk '$1 ~ /^D/'
D   04:03 blkid -p -s TYPE -s PTTYPE -o export /dev/longhorn/pvc-1234…     ← 2분마다 하나씩 늘어난다 (실측)
D   02:02 blkid -p -s TYPE -s PTTYPE -o export /dev/longhorn/pvc-1234…

$ kubectl describe pod … (Events)
Warning FailedMount  MountVolume.MountDevice failed for volume "pvc-1234…" : rpc error: code = DeadlineExceeded desc = context deadline exceeded   ← 2분 간격 (실측)

$ kubectl -n longhorn-system get volumes.longhorn.io pvc-1234…
… attached   healthy …                                                  ← Longhorn 은 정상으로 본다 (실측)
```

  instance-manager 로그에는 `Suspending before the snapshot operation` 뒤에 짝이 되는 `Resumed after the snapshot operation` 이 없거나, `Failed to resume engine frontend` 가 있어야 한다.
- **아니라면.** `dmsetup` 에 `Suspended` 가 한 번도 안 보인다.
- **맞을 때 조치.** 지연 시각과 겹치는 스냅샷·백업 예약 작업(RecurringJob), 재구축을 찾는다. 재현 조건과 instance-manager 로그를 Longhorn 에 보고한다. 급할 때 `dmsetup resume` 을 직접 치는 것은 Longhorn 이 작업 중일 수 있어 권하지 않는다.

### H2. 노드 안 nvme-tcp 연결이 끊겼다 다시 붙는다 [원리는 실측, 긴 지연은 추정]

- **원리.** V2 볼륨은 노드에서 nvme-tcp 장치로 보이고 그 위에 device-mapper 장치(`/dev/longhorn/<pv>`)가 얹힌다. 상대편은 V2 instance-manager 안의 SPDK 프로세스다. 그 프로세스가 재시작하거나 응답이 늦으면 커널이 재접속을 되풀이한다.
- **랩 값.** `ctrl_loss_tmo=30`, `reconnect_delay=2`, `io_timeout=30`. 이 값이면 30초 뒤 I/O 가 실패로 끝나서 오래 멈추지 않는다(K4·K6 은 164~168초에 스스로 회복).
- **맞다면 이렇게 보인다.**

```text
$ sudo nvme list-subsys
nvme-subsys1 - NQN=nqn.2023-01.io.longhorn.spdk:pvc-1234…
\
 +- nvme1 tcp traddr=…,trsvcid=… connecting        ← live 가 아니라 connecting

$ sudo dmesg -T | grep -i nvme
nvme nvme1: I/O tag … timeout
nvme nvme1: starting error recovery
nvme nvme1: Reconnecting in 2 seconds...
nvme nvme1: failed to connect socket: -111           ← 되풀이

$ cat /sys/class/nvme/nvme1/ctrl_loss_tmo
-1 또는 큰 값                                          ← 30 이 아니면 오래 멈출 수 있다

$ kubectl -n longhorn-system get pods -o wide | grep instance-manager
instance-manager-…   1/1   Running   0   7m        ← 그 노드 V2 것의 AGE 가 다른 노드보다 짧다 (실측: 통째로 교체되어 RESTARTS 는 0)
```

- **아니라면.** 지연 내내 `live`, `dmesg` 에 nvme 줄이 없다.
- **맞을 때 조치.** instance-manager 가 왜 바뀌었는지 본다(이전 파드 로그, liveness 실패, 메모리·hugepage, CPU 마스크). 노드 간 스토리지 네트워크(MTU, 패킷 유실)도 본다.

### H3. V2 디스크 아래 저장소가 느리거나 멈춘다 [K12 실측, 실제 하이퍼바이저는 추정]

- **원리.** 실서버 노드는 VM 이다. 하이퍼바이저의 디스크(공유 스토리지, 스냅샷 통합, 백업 창)가 멈추면 그 디스크 위의 모든 V2 볼륨이 같이 멈춘다. SPDK 는 디스크에 `aio` 로 쓰므로 Longhorn 프로세스 자신은 멈춘 것으로 안 보인다.
- **랩 결과(K12).** 디스크 I/O 를 6분간 1KB/s 로 묶자 그 디스크에 하나뿐인 복제본을 둔 CNPG 인스턴스가 `CrashLoopBackOff` 가 됐고, Longhorn 은 볼륨을 `attached/healthy` 로 표시했다. 풀자 28초 뒤 회복.
- **맞다면 이렇게 보인다.**

```text
$ iostat -x 5 3            (sysstat 이 있을 때)
Device   r/s  w/s  …  w_await  aqu-sz  %util
sdc      0.0  0.2  …  30000+    64     100.0     ← V2 디스크만 await 가 초 단위, util 100%

$ sudo dmesg -T | grep -A20 'blocked for more than' | grep -E 'Workqueue|wb_|jbd2|ext4|xfs'
Workqueue: writeback wb_workfn (flush-252:3)       ← 252:x 는 Longhorn 볼륨 장치 번호
```

  같은 노드·같은 디스크의 **다른 볼륨도 같은 시각에** 느려진다. 3벌 복제 볼륨은 다른 노드의 복제본으로 버틴다(K12 실측: 3벌 볼륨의 파드는 영향 없음).
- **아니라면.** 한 볼륨만 늦고 같은 디스크의 다른 볼륨은 멀쩡하다. `await` 가 정상이다.
- **맞을 때 조치.** 플랫폼 담당에게 그 시각의 데이터스토어 지연, VM 스냅샷·백업 작업을 물어본다. Longhorn 설정으로 풀 문제가 아니다.

### H4. 그 노드에서 V2 instance-manager 가 뜨지 못한다 [실측 K7·K10]

- **원리.** V2 는 노드마다 instance-manager 파드 하나가 SPDK 를 돌린다. hugepage 가 모자라거나 CPU 마스크가 vCPU 수와 안 맞으면 이 파드가 못 뜬다. 그러면 그 노드에 있는 복제본을 쓸 수 없다.
- **랩 결과.** 재부팅 뒤 hugepage 가 0 이면 40분 넘게 그대로였다. kubelet 은 재시작 전까지 hugepage 변화를 알아채지 못했다(22분 넘게 관찰). 고친 뒤 kubelet 재시작 → 130초에 회복.
- **맞다면 이렇게 보인다.**

```text
$ kubectl -n longhorn-system get instancemanagers.longhorn.io
NAME                    DATA ENGINE   STATE     NODE       AGE
instance-manager-aaa…   v1            running   worker-3   …
instance-manager-bbb…   v2            error     worker-3   …    ← v2 만 error 또는 starting (실측)

$ kubectl -n longhorn-system get pods -o wide | grep instance-manager | grep worker-3
(v1 것만 보이고 v2 파드는 목록에 없다)                              ← "Longhorn 파드 전부 Running" 으로 보이는 이유 (실측)

$ kubectl get node worker-3 -o jsonpath='{.status.allocatable.hugepages-2Mi}'
0

$ kubectl -n longhorn-system get events | grep -i huge
… OutOfhugepages-2Mi …                                            ← 2분마다 (실측)

$ kubectl describe pod …
Warning FailedAttachVolume … is not ready for workloads            ← FailedMount 가 아니다
```

- **아니라면.** 지연 중에도 모든 노드의 v2 가 `running` 이다.
- **들은 증상과 안 맞는 점.** 저절로 풀리지 않았고 커널 기록이 없다. 누군가 kubelet 을 재시작하거나 노드를 다시 부팅했을 때만 풀린다.
- **맞을 때 조치.** hugepage 를 부팅 시 확보(`/etc/sysctl.d`, 또는 커널 인자)하고 kubelet 이 그 뒤에 뜨는지 확인. `data-engine-cpu-mask` 를 vCPU 수에 맞춘다.

### H5. 재부팅 때 디스크 이름이 밀려 V2 디스크를 못 찾는다 [실측, LONGHORN-V2-DISK.md]

- **원리.** 디스크를 `/dev/sdb` 같은 이름으로 등록했는데 재부팅 뒤 그 이름이 다른 디스크를 가리킨다. Longhorn 은 그 경로에서 lvstore(V2 가 디스크에 만든 저장 영역)를 UUID 로 찾다가 실패한다.
- **맞다면 이렇게 보인다.**

```text
$ kubectl -n longhorn-system get nodes.longhorn.io worker-3 -o yaml | grep -A6 'conditions' 
  message: … cannot find lvstore with UUID …                      ← (실측)
  status: "False"   type: Ready
$ lsblk -o NAME,SIZE,SERIAL,WWN     (재부팅 전후로 sdb·sdc 의 SERIAL 이 서로 바뀌어 있다)
```

- **들은 증상과 안 맞는 점.** 기다려도 붙지 않는다. 다시 부팅해서 이름이 우연히 돌아와야 풀린다. "재부팅 직후에만, 다음 재부팅까지" 라는 패턴이면 이 후보다.
- **맞을 때 조치.** 디스크를 `/dev/disk/by-id/…` 경로로 등록한다.

### H6. 옛 파드·옛 노드에서 볼륨이 안 풀린다 [실측 B2·D1·K13a]

- **원리.** RWO 볼륨은 한 노드에만 붙는다. 옛 파드가 `Terminating` 에 걸려 있거나 VolumeAttachment 가 옛 노드에 남으면 새 파드는 기다린다. 노드가 죽은 경우 Kubernetes 는 6분 뒤 강제로 뗀다. 파드 객체가 남아 있으면 그것도 안 한다.
- **맞다면 이렇게 보인다.**

```text
$ kubectl describe pod …
Warning FailedAttachVolume  Multi-Attach error for volume "pvc-1234…" Volume is already exclusively attached to one node and can't be attached to another
$ kubectl get volumeattachments | grep pvc-1234
csi-…   driver.longhorn.io   pvc-1234…   worker-2   true          ← 옛 노드 이름
$ kubectl get pod -A -o wide | grep Terminating
```

- **들은 증상과 안 맞는 점.** 노드가 그대로이고 파드가 같은 노드에서 다시 뜬다면 Multi-Attach 는 나지 않는다. 6분짜리 지연만 설명한다.
- **옛 파드가 왜 안 죽는지**는 H1·H2·H3 로 이어진다(K13a·b: 프로세스가 I/O 를 기다리면 종료 유예가 지나도 못 죽인다).

### H7. 떼어 낸 볼륨을 Longhorn 이 재구축하려고 붙들고 있다 [소스, 미실측]

- **원리.** 복제본이 모자란(`degraded`) 볼륨이 떼어지면, 설정에 따라 Longhorn 이 스스로 볼륨을 붙여 복제본을 다시 만든다(`offline-replica-rebuilding`, 기본 `false`, 볼륨별 설정 가능). 붙이는 주체는 `volumeattachments.longhorn.io` 의 티켓으로 남는다(`volume-rebuilding-controller`). 그동안 파드의 부착 요청(`csi-attacher`)은 기다릴 수 있다. 재구축 시간은 볼륨 크기와 동시 재구축 수에 따라 달라진다.
- **동료의 추정("복제본을 엔진 노드로 가져오느라 느리다")과 가장 가까운 후보다.** 저장소가 비어 있어도 볼륨이 크면 시간이 걸리는지는 확인하지 못했다.
- **맞다면 이렇게 보인다.**

```text
$ kubectl -n longhorn-system get volumeattachments.longhorn.io pvc-1234… -o yaml | grep -B2 -A6 'type:'
    type: volume-rebuilding-controller        ← 파드가 아니라 Longhorn 이 붙였다
    nodeID: worker-1
    …
    type: csi-attacher                        ← 파드 쪽 요청, satisfied: false
    nodeID: worker-3

$ kubectl -n longhorn-system get replicas.longhorn.io | grep pvc-1234
… rebuilding 또는 새로 생긴 복제본(AGE 가 짧다)

$ kubectl -n longhorn-system get settings.longhorn.io offline-replica-rebuilding
$ kubectl -n longhorn-system get volumes.longhorn.io pvc-1234… -o jsonpath='{.spec.offlineRebuilding}'
```

  지연 길이가 볼륨 크기를 따라가고, 지연 직전에 그 볼륨이 `degraded` 였어야 한다.
- **아니라면.** 설정이 `false`/`disabled` 이거나 티켓에 `csi-attacher` 만 있다.
- **맞을 때 조치.** 왜 `degraded` 가 되는지가 먼저다(파드를 내릴 때마다 복제본이 실패 처리되는가). 복제본 수, `replica-replenishment-wait-interval`, `concurrent-replica-rebuild-per-node-limit` 을 본다.

### H8. 새 볼륨의 첫 마운트에서 파일시스템을 만드는 데 오래 걸린다 [추정, 미실측]

- **원리.** 처음 쓰는 볼륨은 노드에서 `mkfs` 로 파일시스템을 만든다. `mkfs.ext4` 는 기본으로 장치 전체에 discard(빈 공간 반납)를 먼저 보낸다. V2 장치에서 이것이 느리면 볼륨 크기에 비례해 오래 걸린다. StorageClass 의 `mkfsParams` 로 옵션을 줄 수 있다(`longhorn-manager` `csi/node_server.go:1138`).
- **"저장소가 비어 있는데도", "만들어지는 데 1시간"** 이라는 말과 맞을 수 있다. 쓰던 볼륨의 재부착에서도 생긴다면 이 후보는 아니다.
- **맞다면 이렇게 보인다.**

```text
$ ps -eo stat,etime,args | grep '[m]kfs'
D   17:42 mkfs.ext4 -F -m0 … /dev/longhorn/pvc-1234…      ← 새 볼륨에서만, 볼륨이 클수록 오래

$ kubectl describe pod …
Warning FailedMount … MountDevice failed … DeadlineExceeded     ← H1 과 같은 이벤트. 프로세스 이름으로 구분한다
```

  PVC 가 방금 만들어진 것이고, 두 번째 기동부터는 빠르다.
- **맞을 때 조치.** 시험 클러스터에서 작은 볼륨과 큰 볼륨의 첫 마운트 시간을 비교한다. 차이가 크면 `mkfsParams: "-E nodiscard"` 를 검토한다(적용 전 Longhorn 문서 확인).

### H9. 마운트 뒤 소유권 변경이 오래 걸린다 [추정, 가능성 낮음]

- **원리.** 파드에 `fsGroup` 이 있으면 kubelet 이 볼륨 안 모든 파일의 소유 그룹을 바꾼다. 파일이 수십만 개면 몇 분씩 걸린다. CNPG 파드는 `fsGroup` 을 쓴다.
- **맞다면.** 이벤트에 `FailedMount` 가 없고 kubelet 로그에 `Setting volume ownership … is taking longer than expected` 가 있다. 저장소가 비어 있으면 해당 없다.

### H10. 파일 감시 도구가 커널 경로를 붙잡는다 [K3 실측: 커널 6.8 에서 영향 없음]

- **원리.** 백신·감사 도구가 fanotify 로 파일 열기를 허가제로 걸어 두고 응답하지 않으면 그 파일을 여는 쪽이 멈춘다.
- **랩 결과.** 응답 없는 감시를 파일시스템 전체에 걸어도 볼륨 이동은 32초였다.
- **맞다면.** `dmesg` 의 `Workqueue:` 줄이 `fsnotify_mark_destroy_workfn` 이고, 호출 경로에 `fsnotify`·`fanotify`·`srcu` 가 보인다. 이 경우 볼륨 지연과 커널 기록은 서로 다른 문제일 수 있다.
- **아니라면.** `Workqueue: writeback` 이다.

### H11. 복제본이 다른 노드에 있고 노드 사이 통신이 끊긴다 [추정, 미실측]

- **원리.** 엔진(파드가 있는 노드)과 복제본(다른 노드)은 nvme-tcp 로 통신한다. 스토리지 네트워크가 잠깐씩 끊기면 엔진이 복제본을 실패 처리하고, 마지막 하나까지 끊기면 I/O 가 멈춘다.
- **맞다면.** 볼륨이 `degraded` ↔ `healthy` 를 오가고 복제본에 `failedAt` 이 찍힌다. `dataLocality: strict-local` 볼륨(복제본이 파드와 같은 노드)에서는 생기지 않는다.

```text
$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=N:.metadata.name,NODE:.spec.nodeID,FAILED:.spec.failedAt | grep pvc-1234
```

### H12. 원인이 풀린 뒤에도 재시도 간격만큼 더 기다린다 [실측 + 소스, 원인이 아니라 덧붙는 시간]

- kubelet 의 마운트 재시도는 실패할 때마다 간격이 두 배로 늘어 최대 2분 2초다(K13c 실측: 2분마다 재시도).
- Longhorn CSI 의 attach/detach 대기는 한 번에 90초(`csi/controller_server.go:41`), instance-manager 재생성 재시도는 최대 2분 간격(`controller/utils.go:32`), 엔진 재시도는 최대 5분 간격(`controller/engine_controller.go:168`)이다.
- 따라서 원인이 사라진 뒤 **최대 몇 분**은 더 걸릴 수 있다. 30분·1시간은 이것만으로 안 나온다.

## 4. 한눈에 보는 판정표

| 지연 중에 본 것 | 가리키는 후보 |
|---|---|
| `dmsetup` 에 `Suspended` | H1 |
| `nvme list-subsys` 에 `connecting`, `dmesg` 에 nvme 재접속 | H2 |
| V2 디스크만 `await` 초 단위, 같은 디스크의 다른 볼륨도 느림 | H3 |
| v2 instance-manager 가 `running` 아님, hugepage 0 | H4 |
| Longhorn 노드의 디스크 조건이 `Ready=False`, `cannot find lvstore` | H5 |
| `Multi-Attach`, 옛 파드 `Terminating` | H6 (왜 안 죽는지는 H1~H3) |
| 볼륨 티켓에 `volume-rebuilding-controller`, 복제본 재구축 중 | H7 |
| 노드에 `mkfs` 가 오래 돌고 있음, 새 볼륨에서만 | H8 |
| `Workqueue:` 가 `fsnotify…` | H10 |
| 볼륨이 `degraded` 를 오감, 복제본 `failedAt` | H11 |
| 위 전부 아님 | V2-DELAY-INVESTIGATION.md 5.1·5.5 의 원문부터 다시. 이 문서의 가정이 틀렸다 |

## 5. 내부 LLM 에 시킬 것

이 문서와 [V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md) 를 같이 넣고 아래를 그대로 준다. 실서버 출력에는 내부 주소·도메인이 들어 있으니 외부로 내보내지 않는다.

```text
너는 Longhorn V2 볼륨 지연의 원인을 좁히는 일을 돕는다. 첨부한 두 문서가 기준이다.

규칙
1. 내가 붙여 주는 실서버 출력만 근거로 삼는다. 출력에 없는 것을 있다고 하지 않는다.
2. 후보 H1~H12 각각에 대해 "지지 / 반박 / 판단 불가"를 표로 답하고, 근거가 된 출력 줄을 그대로 인용한다.
3. 문서의 "예상 출력"과 글자가 달라도 뜻이 같으면 같다고 보고, 다르다고 판단한 이유를 적는다.
4. 판단 불가인 후보에는 그것을 가를 읽기 전용 명령을 하나씩만 제안한다.
5. 실서버 상태를 바꾸는 명령(delete, patch, restart, dmsetup resume, 재부팅 등)은 제안하지 않는다. 필요하다고 보면 "사람이 결정할 일"로 따로 적는다.
6. 랩 숫자(초 단위 시간)를 실서버에 그대로 적용하지 않는다.
7. 한 후보로 모든 관찰이 설명되지 않으면 그렇게 말하고, 설명 안 되는 관찰을 따로 적는다.

먼저 물어볼 것 (내가 아직 안 준 것만)
- Longhorn 버전, 커널 버전, 노드 vCPU 수
- 파드 이벤트 원문 (FailedMount 인지 FailedAttachVolume 인지)
- 늦는 볼륨이 새로 만든 것인지 쓰던 것인지, 볼륨 크기
- 지연이 재부팅 직후에만 생기는지
- dmesg 의 blocked 줄 아래 Workqueue 줄과 호출 경로
```

수집 순서는 [V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md) 5절이다. 여기에 이번 문서에서 늘어난 것을 더한다.

```bash
# H2
sudo nvme list-subsys; sudo dmesg -T | grep -i 'nvme' | tail -20
for c in /sys/class/nvme/nvme*; do echo "$c $(cat $c/state) loss=$(cat $c/ctrl_loss_tmo 2>/dev/null)"; done
# H3
iostat -x 5 3
# H7
kubectl -n longhorn-system get volumeattachments.longhorn.io <pv 이름> -o yaml
kubectl -n longhorn-system get settings.longhorn.io offline-replica-rebuilding replica-replenishment-wait-interval concurrent-replica-rebuild-per-node-limit
# H8
ps -eo stat,etime,args | grep -E '[m]kfs|[b]lkid|[f]sck|[m]ount '
kubectl get sc <스토리지클래스> -o yaml | grep -A12 parameters
# H11
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=N:.metadata.name,NODE:.spec.nodeID,FAILED:.spec.failedAt,HEALTHY:.spec.healthyAt | grep <pv 이름>
```

## 6. 왜 랩에서 끝까지 재현이 안 되는가

- **멈추게 하는 것이 랩에 없다.** 실서버에서 I/O 를 멈추는 것은 하이퍼바이저의 디스크, 노드 사이 네트워크, 부하가 걸린 상태의 Longhorn 동작 중 하나일 가능성이 높다. 랩은 노트북 한 대의 VMware 위에서 로컬 디스크로 돈다. 그 층이 없다.
- **규모가 다르다.** 실서버 커널 기록의 `kworker/u152` 는 CPU 가 많은 노드라는 뜻이다. 랩 워커는 2 vCPU, 5GB 다. 볼륨 수와 크기도 다르다. 크기·동시성에 비례하는 후보(H7, H8)는 랩에서 차이가 안 난다.
- **구성이 다르다.** 실서버는 V2 디스크를 파티션으로 등록했고 디스크 드라이버를 `auto` 로 두었다고 들었다. 랩은 디스크 전체와 `aio` 다.
- **증상을 직접 보지 못했다.** 전해 들은 말로 케이스를 골랐다. 파드 이벤트 한 줄만 있어도 2절 ①에서 후보 절반이 지워진다.
- **그래서 랩이 한 일은 "이 모양이 되려면 무엇이 멈춰야 하는가"까지다.** 답은 "볼륨 장치의 I/O"였다. "무엇이 그것을 멈추는가"는 실서버 출력이 있어야 한다.
