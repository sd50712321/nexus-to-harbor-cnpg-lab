# V2 볼륨이 6분~1시간 늦게 붙는 증상: 랩 시험 결과와 실서버에서 알아볼 것

다른 클러스터에서 들은 증상을 랩에서 케이스별로 만들어 보고, 무엇이 설명되고 무엇이 안 되는지 적었다. 원인을 확정한 문서가 아니다. 확정하려면 5절의 실서버 확인이 필요하다.

> **근거 수준.** 2026-11-17 랩 실측이다. 워커 3대(5GB, 2 vCPU, Ubuntu 24.04 커널 6.8), Longhorn 1.13.0 V2 엔진, CNPG 1.30.1. 케이스마다 1번씩 했다. 실서버 증상은 전해 들은 것이고 직접 보지 못했다. 기록 원문은 `v2test/results/k/`.

## 1. 들은 증상

- 파드를 내렸다 올리면 볼륨 detach/attach 와 파드 기동이 어긋나 오래 걸린다. 6분, 18분, 31분, 1시간쯤으로 들쭉날쭉하고, 기다리면 저절로 붙는다.
- 그동안 파드는 `Init` 으로 보인다. Longhorn 파드는 전부 `Running`, 노드는 그대로 `Ready`.
- 워커의 `dmesg` 에 `task kworker/u152… blocked for more than 122 seconds` 가 찍힌다.
- 저장소는 비어 있다(데이터가 거의 없다).

## 2. 결론

- **모양과 풀리는 방식이 모두 맞은 것은 하나다: 볼륨의 블록 장치에서 I/O 가 끝나지 않는 상태(K13).** 장치가 멈춰 있는 시간만큼 파드가 `Init` 또는 `Terminating` 에 걸리고, 풀리면 16~33초 안에 정상이 된다. 그동안 Longhorn 은 볼륨을 `attached / healthy` 로 표시하고 Longhorn 파드는 전부 `Running` 이다. `blocked for more than 122 seconds` 도 이 케이스에서만 나왔다.
- 따라서 지연 길이가 들쭉날쭉한 것은 **I/O 가 멈춰 있던 시간이 매번 달랐기 때문**으로 설명된다. Kubernetes·Longhorn 의 고정 타이머(6분 강제 detach, 30분 복제본 정리 등)로는 6분·18분·31분·1시간이 함께 설명되지 않는다.
- **실서버에서 I/O 를 멈추는 것이 무엇인지는 랩에서 알 수 없다.** 랩에서는 `dmsetup suspend` 로 일부러 멈췄다. 후보는 4절, 가려내는 방법은 5절이다.
- 원인이 아닌 것으로 본 것: CNPG 자체, 복제본 복사 시간, 디스크 크기, 커널 모듈 누락, 시계 어긋남, 노드 프로세스가 볼륨 안 파일을 잡고 있는 것.

## 3. 케이스별 결과

"이동"은 살아 있는 노드에서 파드를 지우고 다시 `Running 1/1` 이 되기까지의 시간이다.

| 케이스 | 만든 상황 | 파드 모양 | 걸린 시간 | 스스로 풀림 | 커널 멈춤 기록 | 실서버와 비교 |
|---|---|---|---|---|---|---|
| K1 | 방해 없음 (단순 파드, CNPG) | 잠깐 대기 | 35~38초 | - | 없음 | 기준선 |
| K2 | 노드 프로세스가 볼륨 안 파일을 열고 있음 | 같음 | 32초 | - | 없음 | 영향 없음 |
| K3 | 응답하지 않는 fanotify 감시(파일시스템 전체) | 같음 | 32초 | - | 없음 | 영향 없음 (커널 6.8) |
| K4·K6 | V2 I/O 프로세스(`spdk_tgt`)를 3분 정지 | 다른 파드까지 재시작, 하나는 `CrashLoopBackOff` | 164~168초 | 예 (instance-manager 파드가 교체됨) | 없음 | 긴 지연이 안 나옴 |
| K7·K10 | 재부팅 뒤 hugepage 가 0 → V2 instance-manager 가 못 뜸 | `Init:0/1`, Longhorn 파드 전부 Running(V2 것만 목록에 없음) | 40분 넘게 계속 | **아니오** | 없음 | 모양은 같고, 저절로 풀리지 않음 |
| K8 | 커널 모듈 자동 로드 빠짐 | 정상 | 79초 | - | 없음 | 영향 없음 |
| K9 | V2 디스크 10GB 와 100GB | 정상 | 둘 다 78초 | - | 없음 | 영향 없음 |
| K11 | 노드 시계 9시간 어긋남 (동작 중, 부팅 시) | 정상 | 145초 | - | 없음 | 영향 없음 |
| K12 | V2 디스크 I/O 를 6분간 1KB/s 로 제한 | `CrashLoopBackOff`, 볼륨은 `attached/healthy` | 제한 시간 + 28초 | 예 | 없음 | 풀림은 같고 모양이 다름 |
| K13a | 장치를 멈춘 채 파드를 다른 노드로 이동 (8분) | `Terminating`, 볼륨 `attached/healthy` | 멈춘 시간 + 33초 | 풀어 줘야 함 | **122·245·368초** (`postgres`, `manager`) | 기록 일치 |
| K13b | 장치를 멈춘 채 같은 노드에서 재기동 (5분) | `Terminating` | 멈춘 시간 + 17초 | 풀어 줘야 함 | **122·245초** (`postgres`, `jbd2`) | 기록 일치 |
| K13c | 새 파드가 마운트하기 직전에 장치가 멈춤 (7분) | **`Init:0/1`**, 볼륨 `attached/healthy`, Longhorn 파드 전부 Running | 멈춘 시간 + 16초 | 풀어 줘야 함 | 없음 | **모양 일치** |

덧붙임.

- K10 에서 Longhorn 의 오래된 복제본 정리(`staleReplicaTimeout`, 랩 값 30분)는 정확히 30분 11초에 동작했지만 파드는 `Init` 그대로였다. 이 타이머는 지연을 풀어 주지 않는다.
- K13c 의 파드 이벤트는 2분마다 `FailedMount … MountDevice failed … DeadlineExceeded` 였다. 노드에는 `blkid -p … /dev/longhorn/<pv>` 프로세스가 `D` 상태로 2분마다 하나씩 쌓였다.
- K13a·b 에서 Kubernetes 는 종료 유예 시간이 지나도 파드를 지우지 못했다. 프로세스가 I/O 를 기다리는 동안에는 강제 종료 신호가 듣지 않는다.
- 랩의 멈춤 기록은 `postgres`·`jbd2` 였고 실서버는 `kworker` 다. 버퍼에 쌓인 쓰기를 내려 쓰는 작업이 멈추면 `kworker` 로 찍히므로 같은 종류로 보지만, 실서버의 `Workqueue:` 줄을 봐야 확인된다.

## 4. 실서버에서 I/O 를 멈출 수 있는 후보

랩에서 확인한 것과 소스에서 읽은 것만 적는다. 어느 것인지는 5절로 가린다.

1. **Longhorn 이 스스로 장치를 멈춘 뒤 재개가 늦는 경우.** V2 엔진은 스냅샷 생성, 복제본 추가(재구축), 볼륨 확장 때 프런트엔드 장치를 `suspend` 했다가 `resume` 한다(`longhorn-spdk-engine` v1.13.0 `pkg/spdk/enginefrontend.go:2449`, `pkg/spdk/server.go:804`, `pkg/spdk/enginefrontend.go:1397`). 재개에 실패하면 장치가 멈춘 채 남을 수 있다고 주석에 적혀 있다. 랩에서 이 경로를 재현하지는 못했다.
2. **노드 안 nvme-tcp 연결이 끊겼다 붙는 경우.** V2 볼륨은 노드에서 nvme-tcp 장치로 보인다. 랩 값은 `ctrl_loss_tmo=30`, `reconnect_delay=2` 였고, 이 값이면 30초 뒤 I/O 가 실패로 끝나 오래 멈추지 않는다. 값이 다르면 결과가 달라진다.
3. **V2 디스크 아래 저장소가 느리거나 멈추는 경우.** 실서버 노드는 VM 이다. 하이퍼바이저 쪽 디스크가 멈추면 그 위의 모든 볼륨이 함께 멈춘다. K12 가 이 경우에 가깝다.
4. **V2 instance-manager 가 그 노드에서 뜨지 못한 경우(K7·K10).** 모양은 같지만 저절로 풀리지 않고 커널 기록도 없어서 순위가 낮다. 재부팅 직후에만 생긴다면 다시 봐야 한다.

운영은 V2 디스크를 파티션(`sdb1`)으로, 테스트 클러스터는 디스크 전체로 등록했다고 들었다. 이 차이가 지연과 관계있는지는 시험하지 않았다. `/dev/sdX` 이름이 재부팅 때 바뀌는 문제는 따로 있고 그 경우는 기다려도 붙지 않는다([LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md)).

## 5. 실서버에서 알아볼 것

모두 읽기만 하는 명령이다. **지연이 진행 중일 때** 받아야 의미가 있다. 위에서부터 중요하다.

### 5.1 멈춘 파드가 무엇을 기다리는가

```bash
kubectl -n <네임스페이스> describe pod <Init 에 멈춘 파드> | sed -n '/Events:/,$p'
```

| 보이는 이벤트 | 뜻 | 가까운 케이스 |
|---|---|---|
| `FailedMount … MountDevice failed … DeadlineExceeded` | 볼륨은 붙었고 노드에서 장치를 읽지 못한다 | K13c |
| `FailedAttachVolume … Multi-Attach` 또는 `waiting on detach` | 옛 파드·옛 노드에서 볼륨이 안 풀렸다 | K13a, 노드 정지 |
| `FailedAttachVolume … is not ready for workloads` 가 계속 | Longhorn 이 볼륨을 못 띄운다 | K7·K10 |
| 이벤트 없음, 같은 이름의 옛 파드가 `Terminating` | 옛 파드 프로세스가 I/O 에 걸려 못 죽는다 | K13a·b |

### 5.2 그 노드에서 장치가 멈춰 있는가

```bash
# 워커 노드에서
sudo dmsetup info -c -o name,suspended,open | grep pvc-      # Suspended 가 있으면 4절 1번
ps -eo stat,etime,args | awk '$1 ~ /^D/'                     # I/O 를 기다리며 멈춘 프로세스 (blkid, mount, umount, postgres)
sudo nvme list-subsys 2>/dev/null | grep -E 'nqn|live|connecting'   # connecting 이 있으면 4절 2번
```

### 5.3 커널 멈춤 기록의 다음 줄

```bash
sudo dmesg -T | grep -A25 'blocked for more than' | grep -E 'blocked for more|Workqueue:|dm_|nvme|wb_|jbd2|ext4|xfs|fsnotify'
```

| `Workqueue:` 또는 호출 경로 | 뜻 |
|---|---|
| `writeback`, `wb_workfn`, `jbd2`, `ext4`/`xfs` | 파일시스템이 아래 장치를 기다린다 → 스토리지 경로 (K13 과 같은 종류) |
| `dm_`, `nvme_` | device-mapper 또는 nvme-tcp 에서 멈췄다 → 4절 1·2번 |
| `fsnotify_mark_destroy_workfn` 등 `fsnotify` | 파일 감시 도구 쪽이다. 볼륨 지연과 별개일 수 있다 |

기록이 찍힌 시각이 지연 구간 안인지, 지연이 없을 때도 찍히는지도 같이 본다.

### 5.4 Longhorn 이 보는 상태

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io                 # v2 가 노드마다 running 인가
kubectl -n longhorn-system get volumes.longhorn.io <pv 이름> -o wide         # attached/healthy 인데 파드가 Init 이면 K13 종류
kubectl -n longhorn-system get engines.longhorn.io,replicas.longhorn.io | grep <pv 이름>
kubectl -n longhorn-system get enginefrontends.longhorn.io 2>/dev/null | grep <pv 이름>   # 1.13 이상. suspended 가 보이면 4절 1번
kubectl get node <노드> -o jsonpath='{.status.allocatable.hugepages-2Mi}{"\n"}'          # 0 이면 K7·K10
```

### 5.5 풀린 순간에 무엇이 바뀌었는가

풀린 시각을 분 단위로 적어 두고 그 앞뒤 2분을 본다.

```bash
kubectl -n longhorn-system get events --sort-by=.lastTimestamp | tail -40
kubectl -n longhorn-system logs -l app=longhorn-manager --since=10m --tail=-1 | grep -E '<pv 이름>' | grep -iE 'suspend|resum|rebuil|snapshot|salvage|failed too long|detach|attach'
kubectl -n longhorn-system logs <그 노드의 v2 instance-manager 파드> --since=10m | grep -iE 'suspend|resum|reconnect|timeout|error'
sudo journalctl -u kubelet --since -10m | grep <pv 이름> | grep -iE 'fail|error|deadline'
```

스냅샷·백업 예약 작업(RecurringJob)이나 복제본 재구축이 지연 구간과 겹치는지도 본다.

```bash
kubectl -n longhorn-system get recurringjobs.longhorn.io
kubectl -n longhorn-system get snapshots.longhorn.io --sort-by=.metadata.creationTimestamp | tail
```

### 5.6 한 번만 확인하면 되는 것

- Longhorn 버전, 커널 버전(`uname -r`), 노드 vCPU 수와 `data-engine-cpu-mask`.
- StorageClass 의 `numberOfReplicas`, `dataLocality`, `staleReplicaTimeout`.
- V2 디스크 아래가 무엇인지(VM 플랫폼, 공유 스토리지 여부), 같은 디스크의 다른 볼륨도 같은 시각에 느려지는지.
- 지연이 생기는 조건: 재부팅 직후만인지, 평소 파드 재시작에도 생기는지, 특정 노드만인지.

## 6. 판정 요령

| 실서버에서 본 것 | 판정 |
|---|---|
| `FailedMount … DeadlineExceeded` + `D` 상태 `blkid`/`mount` + 볼륨 `attached/healthy` | K13 종류. 5.2 로 어디서 멈췄는지 본다 |
| `dmsetup` 에 `Suspended` | Longhorn 이 멈춘 뒤 재개가 안 됨. 풀린 시각의 instance-manager 로그와 함께 Longhorn 에 보고할 사안 |
| nvme `connecting` 반복 | 노드 안 nvme-tcp 연결 또는 V2 instance-manager 재시작 |
| V2 instance-manager 가 `running` 이 아님, hugepage 0 | K7·K10. kubelet 재시작 순서와 hugepage 설정 |
| 위 어느 것도 아님 | 이 문서의 가정이 틀렸다. 5.1 과 5.5 원문으로 다시 시작한다 |

## 7. 못 본 것

- 실서버의 실제 원인. 랩은 I/O 를 일부러 멈췄다.
- Longhorn 이 스스로 `suspend` 한 장치가 재개되지 않는 경로의 재현.
- 파티션에 등록한 V2 디스크, `auto` 로 고른 디스크 드라이버.
- `kworker` 로 찍히는 멈춤 기록(랩은 `postgres`·`jbd2`·`manager`).
- 각 케이스의 반복. 모두 1번씩이다.

## 8. 다시 해 보려면

`v2test/` 의 스크립트다. 전부 랩 전용이고 실서버에서 돌리면 안 된다.

| 파일 | 케이스 |
|---|---|
| `move.sh` | K1~K3, K8: 살아 있는 노드 사이 이동 시간 |
| `fan.py` | K3: 응답 없는 fanotify 감시 |
| `k7.sh`, `k10.sh` | hugepage 없이 재부팅 |
| `k11b.sh` | 시계 어긋난 채 부팅 |
| `k12.sh` | V2 디스크 I/O 제한 |
| `k13.sh`, `k13c.sh` | 장치 멈춤 (`NOLOCKFS=1` 이면 파일시스템 동결 없이) |
| `d1.sh`, `e1.sh` | 3벌 볼륨 노드 정지, 오래된 복제본 정리 타이머 |
