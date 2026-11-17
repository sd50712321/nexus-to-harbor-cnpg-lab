# V2 볼륨 지연 조사 묶음 (2026-11-17 ~ 11-18)

볼륨이 6분~1시간 늦게 붙는 증상을 조사하며 올린 것만 한 파일로 묶은 사본이다. 원본은 같은 폴더의 각 파일이고, 내용이 다르면 원본이 맞다.

| 부 | 내용 | 원본 |
|---|---|---|
| 1 | 랩 케이스 시험 결과와 실서버 확인 항목 | `V2-DELAY-INVESTIGATION.md` |
| 2 | 원인 후보 12개의 예상 출력, 판정표, 내부 LLM 지시문 | `V2-DELAY-HYPOTHESES.md` |
| 3 | 진단 기록 | `TROUBLESHOOTING.md` 30절 |
| 4 | 시험 스크립트 | `v2test/` |
| 5 | 기록 원문 | `v2test/results/k/`, `results/D1.log`, `results/E1.log` |

스크립트는 전부 랩 전용이다. 실서버에서 돌리면 안 된다.


---

# 1부. 랩 케이스 시험 결과

> 원본: `V2-DELAY-INVESTIGATION.md`

## V2 볼륨이 6분~1시간 늦게 붙는 증상: 랩 시험 결과와 실서버에서 알아볼 것

다른 클러스터에서 들은 증상을 랩에서 케이스별로 만들어 보고, 무엇이 설명되고 무엇이 안 되는지 적었다. 원인을 확정한 문서가 아니다. 확정하려면 5절의 실서버 확인이 필요하다.

> **근거 수준.** 2026-11-17 랩 실측이다. 워커 3대(5GB, 2 vCPU, Ubuntu 24.04 커널 6.8), Longhorn 1.13.0 V2 엔진, CNPG 1.30.1. 케이스마다 1번씩 했다. 실서버 증상은 전해 들은 것이고 직접 보지 못했다. 기록 원문은 `v2test/results/k/`.

### 1. 들은 증상

- 파드를 내렸다 올리면 볼륨 detach/attach 와 파드 기동이 어긋나 오래 걸린다. 6분, 18분, 31분, 1시간쯤으로 들쭉날쭉하고, 기다리면 저절로 붙는다.
- 그동안 파드는 `Init` 으로 보인다. Longhorn 파드는 전부 `Running`, 노드는 그대로 `Ready`.
- 워커의 `dmesg` 에 `task kworker/u152… blocked for more than 122 seconds` 가 찍힌다.
- 저장소는 비어 있다(데이터가 거의 없다).

### 2. 결론

- **모양과 풀리는 방식이 모두 맞은 것은 하나다: 볼륨의 블록 장치에서 I/O 가 끝나지 않는 상태(K13).** 장치가 멈춰 있는 시간만큼 파드가 `Init` 또는 `Terminating` 에 걸리고, 풀리면 16~33초 안에 정상이 된다. 그동안 Longhorn 은 볼륨을 `attached / healthy` 로 표시하고 Longhorn 파드는 전부 `Running` 이다. `blocked for more than 122 seconds` 도 이 케이스에서만 나왔다.
- 따라서 지연 길이가 들쭉날쭉한 것은 **I/O 가 멈춰 있던 시간이 매번 달랐기 때문**으로 설명된다. Kubernetes·Longhorn 의 고정 타이머(6분 강제 detach, 30분 복제본 정리 등)로는 6분·18분·31분·1시간이 함께 설명되지 않는다.
- **실서버에서 I/O 를 멈추는 것이 무엇인지는 랩에서 알 수 없다.** 랩에서는 `dmsetup suspend` 로 일부러 멈췄다. 후보는 4절, 가려내는 방법은 5절이다.
- 원인이 아닌 것으로 본 것: CNPG 자체, 복제본 복사 시간, 디스크 크기, 커널 모듈 누락, 시계 어긋남, 노드 프로세스가 볼륨 안 파일을 잡고 있는 것.

### 3. 케이스별 결과

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

### 4. 실서버에서 I/O 를 멈출 수 있는 후보

랩에서 확인한 것과 소스에서 읽은 것만 적는다. 어느 것인지는 5절로 가린다.

1. **Longhorn 이 스스로 장치를 멈춘 뒤 재개가 늦는 경우.** V2 엔진은 스냅샷 생성, 복제본 추가(재구축), 볼륨 확장 때 프런트엔드 장치를 `suspend` 했다가 `resume` 한다(`longhorn-spdk-engine` v1.13.0 `pkg/spdk/enginefrontend.go:2449`, `pkg/spdk/server.go:804`, `pkg/spdk/enginefrontend.go:1397`). 재개에 실패하면 장치가 멈춘 채 남을 수 있다고 주석에 적혀 있다. 랩에서 이 경로를 재현하지는 못했다.
2. **노드 안 nvme-tcp 연결이 끊겼다 붙는 경우.** V2 볼륨은 노드에서 nvme-tcp 장치로 보인다. 랩 값은 `ctrl_loss_tmo=30`, `reconnect_delay=2` 였고, 이 값이면 30초 뒤 I/O 가 실패로 끝나 오래 멈추지 않는다. 값이 다르면 결과가 달라진다.
3. **V2 디스크 아래 저장소가 느리거나 멈추는 경우.** 실서버 노드는 VM 이다. 하이퍼바이저 쪽 디스크가 멈추면 그 위의 모든 볼륨이 함께 멈춘다. K12 가 이 경우에 가깝다.
4. **V2 instance-manager 가 그 노드에서 뜨지 못한 경우(K7·K10).** 모양은 같지만 저절로 풀리지 않고 커널 기록도 없어서 순위가 낮다. 재부팅 직후에만 생긴다면 다시 봐야 한다.

운영은 V2 디스크를 파티션(`sdb1`)으로, 테스트 클러스터는 디스크 전체로 등록했다고 들었다. 이 차이가 지연과 관계있는지는 시험하지 않았다. `/dev/sdX` 이름이 재부팅 때 바뀌는 문제는 따로 있고 그 경우는 기다려도 붙지 않는다([LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md)).

### 5. 실서버에서 알아볼 것

모두 읽기만 하는 명령이다. **지연이 진행 중일 때** 받아야 의미가 있다. 위에서부터 중요하다.

#### 5.1 멈춘 파드가 무엇을 기다리는가

```bash
kubectl -n <네임스페이스> describe pod <Init 에 멈춘 파드> | sed -n '/Events:/,$p'
```

| 보이는 이벤트 | 뜻 | 가까운 케이스 |
|---|---|---|
| `FailedMount … MountDevice failed … DeadlineExceeded` | 볼륨은 붙었고 노드에서 장치를 읽지 못한다 | K13c |
| `FailedAttachVolume … Multi-Attach` 또는 `waiting on detach` | 옛 파드·옛 노드에서 볼륨이 안 풀렸다 | K13a, 노드 정지 |
| `FailedAttachVolume … is not ready for workloads` 가 계속 | Longhorn 이 볼륨을 못 띄운다 | K7·K10 |
| 이벤트 없음, 같은 이름의 옛 파드가 `Terminating` | 옛 파드 프로세스가 I/O 에 걸려 못 죽는다 | K13a·b |

#### 5.2 그 노드에서 장치가 멈춰 있는가

```bash
## 워커 노드에서
sudo dmsetup info -c -o name,suspended,open | grep pvc-      # Suspended 가 있으면 4절 1번
ps -eo stat,etime,args | awk '$1 ~ /^D/'                     # I/O 를 기다리며 멈춘 프로세스 (blkid, mount, umount, postgres)
sudo nvme list-subsys 2>/dev/null | grep -E 'nqn|live|connecting'   # connecting 이 있으면 4절 2번
```

#### 5.3 커널 멈춤 기록의 다음 줄

```bash
sudo dmesg -T | grep -A25 'blocked for more than' | grep -E 'blocked for more|Workqueue:|dm_|nvme|wb_|jbd2|ext4|xfs|fsnotify'
```

| `Workqueue:` 또는 호출 경로 | 뜻 |
|---|---|
| `writeback`, `wb_workfn`, `jbd2`, `ext4`/`xfs` | 파일시스템이 아래 장치를 기다린다 → 스토리지 경로 (K13 과 같은 종류) |
| `dm_`, `nvme_` | device-mapper 또는 nvme-tcp 에서 멈췄다 → 4절 1·2번 |
| `fsnotify_mark_destroy_workfn` 등 `fsnotify` | 파일 감시 도구 쪽이다. 볼륨 지연과 별개일 수 있다 |

기록이 찍힌 시각이 지연 구간 안인지, 지연이 없을 때도 찍히는지도 같이 본다.

#### 5.4 Longhorn 이 보는 상태

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io                 # v2 가 노드마다 running 인가
kubectl -n longhorn-system get volumes.longhorn.io <pv 이름> -o wide         # attached/healthy 인데 파드가 Init 이면 K13 종류
kubectl -n longhorn-system get engines.longhorn.io,replicas.longhorn.io | grep <pv 이름>
kubectl -n longhorn-system get enginefrontends.longhorn.io 2>/dev/null | grep <pv 이름>   # 1.13 이상. suspended 가 보이면 4절 1번
kubectl get node <노드> -o jsonpath='{.status.allocatable.hugepages-2Mi}{"\n"}'          # 0 이면 K7·K10
```

#### 5.5 풀린 순간에 무엇이 바뀌었는가

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

#### 5.6 한 번만 확인하면 되는 것

- Longhorn 버전, 커널 버전(`uname -r`), 노드 vCPU 수와 `data-engine-cpu-mask`.
- StorageClass 의 `numberOfReplicas`, `dataLocality`, `staleReplicaTimeout`.
- V2 디스크 아래가 무엇인지(VM 플랫폼, 공유 스토리지 여부), 같은 디스크의 다른 볼륨도 같은 시각에 느려지는지.
- 지연이 생기는 조건: 재부팅 직후만인지, 평소 파드 재시작에도 생기는지, 특정 노드만인지.

### 6. 판정 요령

| 실서버에서 본 것 | 판정 |
|---|---|
| `FailedMount … DeadlineExceeded` + `D` 상태 `blkid`/`mount` + 볼륨 `attached/healthy` | K13 종류. 5.2 로 어디서 멈췄는지 본다 |
| `dmsetup` 에 `Suspended` | Longhorn 이 멈춘 뒤 재개가 안 됨. 풀린 시각의 instance-manager 로그와 함께 Longhorn 에 보고할 사안 |
| nvme `connecting` 반복 | 노드 안 nvme-tcp 연결 또는 V2 instance-manager 재시작 |
| V2 instance-manager 가 `running` 이 아님, hugepage 0 | K7·K10. kubelet 재시작 순서와 hugepage 설정 |
| 위 어느 것도 아님 | 이 문서의 가정이 틀렸다. 5.1 과 5.5 원문으로 다시 시작한다 |

### 7. 못 본 것

- 실서버의 실제 원인. 랩은 I/O 를 일부러 멈췄다.
- Longhorn 이 스스로 `suspend` 한 장치가 재개되지 않는 경로의 재현.
- 파티션에 등록한 V2 디스크, `auto` 로 고른 디스크 드라이버.
- `kworker` 로 찍히는 멈춤 기록(랩은 `postgres`·`jbd2`·`manager`).
- 각 케이스의 반복. 모두 1번씩이다.

### 8. 다시 해 보려면

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

---

# 2부. 원인 후보별 예상 출력

> 원본: `V2-DELAY-HYPOTHESES.md`

## V2 볼륨 지연: 원인 후보별로 "이렇게 보여야 한다"

[V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md) 의 다음 단계다. 원인 후보를 넓게 늘어놓고, 각 후보가 맞다면 실서버에서 **무엇이 어떻게 보여야 하는지**를 적었다. 실서버 출력을 이 문서와 맞대어 후보를 지워 나가는 용도다.

> **읽는 법.** 후보마다 근거 수준을 붙였다.
> - **실측**: 랩(Longhorn 1.13.0 V2, 커널 6.8, CNPG 1.30.1)에서 직접 만들어 본 출력이다.
> - **소스**: Longhorn 1.13.0 소스에서 읽은 동작이다. 랩에서 만들지는 못했다.
> - **추정**: 일반 원리에서 끌어낸 것이다. 출력 예시는 형태만 맞고 글자는 다를 수 있다.
>
> 예시 출력의 이름(`pvc-1234…`, `worker-3`)은 지어낸 것이다. 실서버 Longhorn 버전이 1.13.0 과 다르면 리소스 이름과 로그 문구가 다를 수 있다.

### 1. 지금까지 확인된 것과 아닌 것

들은 증상: 파드 재기동 때 볼륨이 6분·18분·31분·1시간쯤 늦게 붙고 저절로 풀린다. 파드는 `Init`, Longhorn 파드는 전부 `Running`, 노드는 `Ready`, `dmesg` 에 `task kworker/u152… blocked for more than 122 seconds`, 저장소는 비어 있다.

| 구분 | 내용 |
|---|---|
| 랩에서 만든 케이스 | K1~K13, 17개 기록. 각 1번씩 |
| 모양이 맞은 것 | 볼륨 장치의 I/O 가 끝나지 않는 상태(K13c): `Init:0/1`, 볼륨 `attached/healthy`, Longhorn 파드 전부 Running |
| 커널 기록이 맞은 것 | K13a·b: `blocked for more than 122 seconds` (작업 이름은 `postgres`·`jbd2`, 실서버는 `kworker`) |
| 랩에서 안 된 것 | 저절로 풀리는 것. 랩은 일부러 멈추고 일부러 풀었다 |
| 영향 없다고 본 것 | CNPG 자체, 파일을 잡은 프로세스, fanotify 감시(커널 6.8), 커널 모듈, 디스크 크기(10GB 대 100GB), 시계 |
| 시험 못 한 것 | 3절의 H1, H2(값이 다른 경우), H3(실제 하이퍼바이저), H7, H8, H11, 파티션 등록 디스크 |

### 2. 먼저 가를 질문 세 개

후보가 많아 보여도 아래 세 가지로 대부분 갈린다.

| 질문 | 확인 | 갈림 |
|---|---|---|
| ① 볼륨이 **붙었는데** 못 쓰는가, **못 붙는가** | 파드 이벤트가 `FailedMount` 인가 `FailedAttachVolume` 인가 | `FailedMount` → H1·H2·H3·H8·H11. `FailedAttachVolume` → H4·H5·H6·H7 |
| ② 늦는 볼륨이 **새로 만든 것**인가 **쓰던 것**인가 | PVC 생성 시각과 지연 시각 | 새 볼륨에서만 → H8. 쓰던 볼륨도 → 나머지 |
| ③ 지연 길이가 **볼륨 크기**를 따라가는가 | 큰 볼륨일수록 오래 걸리는지 | 따라감 → H7·H8. 무관 → H1·H2·H3 |

### 3. 후보별 예상 출력

#### H1. Longhorn 이 스스로 장치를 멈춘 뒤 재개가 늦다 [소스 + 모양은 실측]

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

#### H2. 노드 안 nvme-tcp 연결이 끊겼다 다시 붙는다 [원리는 실측, 긴 지연은 추정]

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

#### H3. V2 디스크 아래 저장소가 느리거나 멈춘다 [K12 실측, 실제 하이퍼바이저는 추정]

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

#### H4. 그 노드에서 V2 instance-manager 가 뜨지 못한다 [실측 K7·K10]

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

#### H5. 재부팅 때 디스크 이름이 밀려 V2 디스크를 못 찾는다 [실측, LONGHORN-V2-DISK.md]

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

#### H6. 옛 파드·옛 노드에서 볼륨이 안 풀린다 [실측 B2·D1·K13a]

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

#### H7. 떼어 낸 볼륨을 Longhorn 이 재구축하려고 붙들고 있다 [소스, 미실측]

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

#### H8. 새 볼륨의 첫 마운트에서 파일시스템을 만드는 데 오래 걸린다 [추정, 미실측]

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

#### H9. 마운트 뒤 소유권 변경이 오래 걸린다 [추정, 가능성 낮음]

- **원리.** 파드에 `fsGroup` 이 있으면 kubelet 이 볼륨 안 모든 파일의 소유 그룹을 바꾼다. 파일이 수십만 개면 몇 분씩 걸린다. CNPG 파드는 `fsGroup` 을 쓴다.
- **맞다면.** 이벤트에 `FailedMount` 가 없고 kubelet 로그에 `Setting volume ownership … is taking longer than expected` 가 있다. 저장소가 비어 있으면 해당 없다.

#### H10. 파일 감시 도구가 커널 경로를 붙잡는다 [K3 실측: 커널 6.8 에서 영향 없음]

- **원리.** 백신·감사 도구가 fanotify 로 파일 열기를 허가제로 걸어 두고 응답하지 않으면 그 파일을 여는 쪽이 멈춘다.
- **랩 결과.** 응답 없는 감시를 파일시스템 전체에 걸어도 볼륨 이동은 32초였다.
- **맞다면.** `dmesg` 의 `Workqueue:` 줄이 `fsnotify_mark_destroy_workfn` 이고, 호출 경로에 `fsnotify`·`fanotify`·`srcu` 가 보인다. 이 경우 볼륨 지연과 커널 기록은 서로 다른 문제일 수 있다.
- **아니라면.** `Workqueue: writeback` 이다.

#### H11. 복제본이 다른 노드에 있고 노드 사이 통신이 끊긴다 [추정, 미실측]

- **원리.** 엔진(파드가 있는 노드)과 복제본(다른 노드)은 nvme-tcp 로 통신한다. 스토리지 네트워크가 잠깐씩 끊기면 엔진이 복제본을 실패 처리하고, 마지막 하나까지 끊기면 I/O 가 멈춘다.
- **맞다면.** 볼륨이 `degraded` ↔ `healthy` 를 오가고 복제본에 `failedAt` 이 찍힌다. `dataLocality: strict-local` 볼륨(복제본이 파드와 같은 노드)에서는 생기지 않는다.

```text
$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=N:.metadata.name,NODE:.spec.nodeID,FAILED:.spec.failedAt | grep pvc-1234
```

#### H12. 원인이 풀린 뒤에도 재시도 간격만큼 더 기다린다 [실측 + 소스, 원인이 아니라 덧붙는 시간]

- kubelet 의 마운트 재시도는 실패할 때마다 간격이 두 배로 늘어 최대 2분 2초다(K13c 실측: 2분마다 재시도).
- Longhorn CSI 의 attach/detach 대기는 한 번에 90초(`csi/controller_server.go:41`), instance-manager 재생성 재시도는 최대 2분 간격(`controller/utils.go:32`), 엔진 재시도는 최대 5분 간격(`controller/engine_controller.go:168`)이다.
- 따라서 원인이 사라진 뒤 **최대 몇 분**은 더 걸릴 수 있다. 30분·1시간은 이것만으로 안 나온다.

### 4. 한눈에 보는 판정표

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

### 5. 내부 LLM 에 시킬 것

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
## H2
sudo nvme list-subsys; sudo dmesg -T | grep -i 'nvme' | tail -20
for c in /sys/class/nvme/nvme*; do echo "$c $(cat $c/state) loss=$(cat $c/ctrl_loss_tmo 2>/dev/null)"; done
## H3
iostat -x 5 3
## H7
kubectl -n longhorn-system get volumeattachments.longhorn.io <pv 이름> -o yaml
kubectl -n longhorn-system get settings.longhorn.io offline-replica-rebuilding replica-replenishment-wait-interval concurrent-replica-rebuild-per-node-limit
## H8
ps -eo stat,etime,args | grep -E '[m]kfs|[b]lkid|[f]sck|[m]ount '
kubectl get sc <스토리지클래스> -o yaml | grep -A12 parameters
## H11
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=N:.metadata.name,NODE:.spec.nodeID,FAILED:.spec.failedAt,HEALTHY:.spec.healthyAt | grep <pv 이름>
```

### 6. 왜 랩에서 끝까지 재현이 안 되는가

- **멈추게 하는 것이 랩에 없다.** 실서버에서 I/O 를 멈추는 것은 하이퍼바이저의 디스크, 노드 사이 네트워크, 부하가 걸린 상태의 Longhorn 동작 중 하나일 가능성이 높다. 랩은 노트북 한 대의 VMware 위에서 로컬 디스크로 돈다. 그 층이 없다.
- **규모가 다르다.** 실서버 커널 기록의 `kworker/u152` 는 CPU 가 많은 노드라는 뜻이다. 랩 워커는 2 vCPU, 5GB 다. 볼륨 수와 크기도 다르다. 크기·동시성에 비례하는 후보(H7, H8)는 랩에서 차이가 안 난다.
- **구성이 다르다.** 실서버는 V2 디스크를 파티션으로 등록했고 디스크 드라이버를 `auto` 로 두었다고 들었다. 랩은 디스크 전체와 `aio` 다.
- **증상을 직접 보지 못했다.** 전해 들은 말로 케이스를 골랐다. 파드 이벤트 한 줄만 있어도 2절 ①에서 후보 절반이 지워진다.
- **그래서 랩이 한 일은 "이 모양이 되려면 무엇이 멈춰야 하는가"까지다.** 답은 "볼륨 장치의 I/O"였다. "무엇이 그것을 멈추는가"는 실서버 출력이 있어야 한다.

---

# 3부. 진단 기록

> 원본: `TROUBLESHOOTING.md` 30절

### 30. 파드가 `Init` 에서 몇 분씩 멈추는데 Longhorn 은 전부 정상으로 보인다: 볼륨 장치의 I/O 가 끝나지 않는다 [실서버 영향: 원인 미확정]

- 증상(다른 클러스터에서 들음): 파드 재기동 때 볼륨이 6분~1시간 늦게 붙고 저절로 풀린다. 파드는 `Init`, Longhorn 파드는 전부 `Running`, 노드 `Ready`. `dmesg` 에 `blocked for more than 122 seconds`.
- 좁히기: 고정 타이머부터 의심했다(6분 강제 detach, Longhorn 30분 복제본 정리). 하지만 6·18·31·60분이 한 타이머로 안 나온다. 그래서 "무엇이 다르면 이 모양이 되는가"를 하나씩 만들었다. 파일을 잡은 프로세스·fanotify·모듈·디스크 크기·시계는 이동 시간(32~38초)을 바꾸지 못했다. V2 instance-manager 가 못 뜨는 경우(hugepage 0)는 모양이 같았지만 40분이 지나도 안 풀렸고, 30분 정리는 동작했는데도 파드는 그대로였다. 디스크 I/O 를 늦추면 저절로 풀리지만 파드가 `CrashLoopBackOff` 였다. 마지막으로 볼륨의 device-mapper 장치를 멈추자(`dmsetup suspend`) 세 가지가 함께 맞았다: `Init:0/1`(또는 `Terminating`), 볼륨은 `attached/healthy`, 그리고 122·245·368초 멈춤 기록.
- 랩에서 확인한 것: 장치가 멈춘 시간만큼 걸리고, 풀리면 16~33초 안에 회복한다. 이벤트는 2분마다 `FailedMount … DeadlineExceeded`, 노드에는 `D` 상태 `blkid` 가 쌓인다.
- 남은 것: 실서버에서 무엇이 I/O 를 멈추는지는 모른다. Longhorn V2 가 스냅샷·복제본 추가·확장 때 스스로 장치를 멈춘다는 것은 소스에서 읽었지만 재개가 늦는 경로는 재현하지 못했다. 확인 명령과 판정표는 [V2-DELAY-INVESTIGATION.md](V2-DELAY-INVESTIGATION.md) 5·6절.

---

# 4부. 시험 스크립트


## `v2test/move.sh`

```bash
#!/bin/bash
# 살아 있는 노드 사이에서 파드를 옮기며 볼륨이 다시 붙는 시간을 잰다.
#   move.sh <케이스 이름> <파드> <pvc> [옛 노드에서 실행할 준비 명령] [정리 명령]   — 명령 안의 $MNT 는 파드의 볼륨 마운트 경로로 바뀐다
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
CASE=$1; POD=$2; PVC=$3; PRE=${4:-}; POST=${5:-}; MAX=${MAX:-900}; NS=v2test
N=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}'); U=$(kubectl -n $NS get pod $POD -o jsonpath='{.metadata.uid}')
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}'); MNT=/var/lib/kubelet/pods/$U/volumes/kubernetes.io~csi/$PV/mount
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
echo "### $CASE $(date +%H:%M:%S) $POD @ $N pv=${PV:0:12}"
[ -n "$PRE" ] && { sshn "MNT=$MNT; $PRE"; /bin/sleep 3; echo "  준비: $PRE"; }
sshn 'sudo dmesg -C' 2>/dev/null
kubectl cordon $N >/dev/null; S=$(date +%s); kubectl -n $NS delete pod $POD --wait=false >/dev/null; last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  st=$(kubectl -n $NS get pod $POD -o wide --no-headers 2>/dev/null | awk '{print $3"("$2")@"$7}'); vol=$(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  b="pod ${st:-없음} | vol $vol"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $b"; last=$b; }
  echo "$st" | grep -q "Running(1/1)" && ! echo "$st" | grep -q "@$N" && break
  /bin/sleep 3
done
echo "  결과: $(( $(date +%s)-S ))s"
echo "  옛 노드: mounts=$(sshn "findmnt | grep -c $PV") umount=$(sshn "ps -eo stat,etime,args | grep '[u]mount' | head -2 | tr '\n' ';'") hung=$(sshn 'sudo dmesg | grep -c "blocked for more than"')"
sshn "sudo journalctl -u kubelet --since -$(( ($(date +%s)-S)/60+1 ))m | grep $PV | grep -iE 'busy|unmount.*fail|error' | tail -2 | cut -c1-260"
kubectl -n $NS get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "$POD|$PV" | grep -E "Multi-Attach|FailedAttach|SuccessfulAttach|FailedMount|Killing" | tail -6 | cut -c1-200
[ -n "$POST" ] && sshn "$POST"
kubectl uncordon $N >/dev/null
```

## `v2test/fan.py`

```python
#!/usr/bin/env python3
# 감시 에이전트 흉내: 마운트 하나에 fanotify 허가형(OPEN_PERM) 감시를 건다.
#   fan.py <마운트 경로> hang        이벤트를 읽지도 답하지도 않는다 (응답 없는 에이전트)
#   FAN_FS=1 을 주면 마운트 하나가 아니라 그 파일시스템 전체(컨테이너 안의 마운트 포함)를 감시한다
#   fan.py <마운트 경로> slow <초>   이벤트마다 <초> 뒤에 허용으로 답한다 (느린 에이전트)
import ctypes, os, struct, sys, time
libc = ctypes.CDLL("libc.so.6", use_errno=True)
FAN_CLASS_CONTENT, FAN_MARK_ADD, FAN_MARK_MOUNT, FAN_OPEN_PERM, FAN_ALLOW, AT_FDCWD = 0x4, 0x1, 0x10, 0x10000, 0x1, -100
path, mode = sys.argv[1], sys.argv[2]
fd = libc.fanotify_init(FAN_CLASS_CONTENT, os.O_RDONLY)
if fd < 0: sys.exit("fanotify_init errno %d" % ctypes.get_errno())
libc.fanotify_mark.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint64, ctypes.c_int, ctypes.c_char_p]
if libc.fanotify_mark(fd, FAN_MARK_ADD | (0x100 if os.environ.get("FAN_FS") else FAN_MARK_MOUNT), FAN_OPEN_PERM, AT_FDCWD, path.encode()) < 0:
    sys.exit("fanotify_mark errno %d" % ctypes.get_errno())
print("marked", path, mode, flush=True)
if mode == "hang":
    while True: time.sleep(3600)
delay = float(sys.argv[3])
while True:
    buf = os.read(fd, 4096); off = 0
    while off + 24 <= len(buf):
        elen, vers, _r, mlen, mask, efd, pid = struct.unpack_from("IBBHQii", buf, off); off += elen
        time.sleep(delay)
        os.write(fd, struct.pack("iI", efd, FAN_ALLOW)); os.close(efd)
```

## `v2test/k7.sh`

```bash
#!/bin/bash
# K7: 재부팅 뒤 hugepage 가 없는 채로 kubelet 이 뜬다 → 5분 관찰 → hugepage 만 잡는다 → 5분 관찰 → kubelet 재시작 → 회복까지
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
im(){ kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}'; }
snap(){ echo "  $(date +%H:%M:%S) hp(node)=$(kubectl get node $N -o jsonpath='{.status.allocatable.hugepages-2Mi}') hp(os)=$(sshn 'grep HugePages_Total /proc/meminfo' | awk '{print $2}') im-v2=$(im) impod=$(kubectl -n longhorn-system get pods -o wide --no-headers | grep instance-manager | awk -v n=$N '$7==n{printf "%s(%s) ",$3,$5}') | pods@$N: $(kubectl -n v2test get pods -o wide --no-headers | awk -v n=$N '$7==n{printf "%s=%s(%s) ",$1,$3,$2}')"; }
watch(){ S=$(date +%s); last=; while [ $(( $(date +%s)-S )) -lt $1 ]; do o=$(snap); b=${o#*hp(}; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s$o"; last=$b; }; [ -n "${2:-}" ] && echo "$o" | grep -qE "$2" && break; /bin/sleep 10; done; }
echo "### K7 $(date +%H:%M:%S) $N: hugepage 설정 파일을 치우고 재부팅"
sshn 'sudo mv /etc/sysctl.d/90-longhorn-v2-hugepages.conf /root/hp.conf.off'
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N >/dev/null 2>&1; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
watch 300
echo "### $(date +%H:%M:%S) hugepage 만 잡는다 (kubelet 은 그대로)"; sshn 'sudo sysctl -q -w vm.nr_hugepages=1024'
watch 300 'im-v2=running'
if [ "$(im)" != running ]; then echo "### $(date +%H:%M:%S) kubelet 재시작"; sshn 'sudo systemctl restart kubelet'; watch 420 'im-v2=running'; fi
sshn 'sudo mv /root/hp.conf.off /etc/sysctl.d/90-longhorn-v2-hugepages.conf'
kubectl -n longhorn-system get events --sort-by=.lastTimestamp | grep -i instance-manager | grep -iE "fail|insufficient|hugepage|Unschedul" | tail -3 | cut -c1-230
echo DONE
```

## `v2test/k10.sh`

```bash
#!/bin/bash
# K10 복합: 노드 강제 종료 → V2 를 못 쓰는 상태(hugepage 0)로 복귀 → HOLD 초 동안 손대지 않고 관찰 → hugepage 복구 + kubelet 재시작 → 회복 관찰
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; HOLD=${2:-2400}
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
snap(){
  vol=$(for v in $(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$2=="v2"{print $1}'); do
    echo -n "$(kubectl -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.status.kubernetesStatus.pvcName}:{.status.state}/{.status.robustness}' | sed -E 's/attached/att/; s/detached/det/; s/healthy/ok/; s/degraded/degr/')[$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=$v -o jsonpath='{range .items[*]}{.spec.nodeID}{.spec.failedAt},{end}' | sed -E 's/ks-//g; s/20[0-9-]+T[0-9:]+Z/!/g; s/,$//')] "; done)
  pod=$(kubectl -n v2test get pods --no-headers -o wide 2>/dev/null | awk '{printf "%s=%s(%s,r%s)@%s ",$1,$3,$2,$4,substr($7,4)}')
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}')
  echo "im=$im | $vol| $pod"; }
watch(){ S=$(date +%s); last=; while [ $(( $(date +%s)-S )) -lt $1 ]; do b=$(snap); [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }; [ -n "${2:-}" ] && echo "$b" | grep -qE "$2" && ! echo "$b" | grep -qE "Init|Pending|Creating|\(0/1|faulted|degr|unknown" && break; /bin/sleep 15; done; }
echo "### K10 $(date +%H:%M:%S) $N 강제 종료 → hugepage 0 으로 복귀, ${HOLD}초 방치"; snap
sshn 'sudo mv /etc/sysctl.d/90-longhorn-v2-hugepages.conf /root/hp.conf.off; sudo sync; sleep 2'
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"; /bin/sleep 60
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S) hp=$(sshn 'grep HugePages_Total /proc/meminfo' | awk '{print $2}')"
watch $HOLD
echo "### $(date +%H:%M:%S) hugepage 복구 + kubelet 재시작"
sshn 'sudo mv /root/hp.conf.off /etc/sysctl.d/90-longhorn-v2-hugepages.conf; sudo sysctl -q -p /etc/sysctl.d/90-longhorn-v2-hugepages.conf; sudo systemctl restart kubelet'
watch 1500 'im=running'
kubectl -n longhorn-system logs -l app=longhorn-manager --since=70m --tail=60000 2>/dev/null | grep -iE "failed too long ago" | cut -c7-26 | sort -u | head -6
echo DONE
```

## `v2test/k11b.sh`

```bash
#!/bin/bash
# K11b: 노드 강제 종료 → 시계가 SKEW 만큼 틀린 채 부팅(kubelet 보다 먼저 적용) → HOLD 초 방치 → 시계 복구 → 회복 관찰
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; SKEW=${2:-+9 hours}; HOLD=${3:-480}
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
echo "### K11b $(date +%H:%M:%S) $N 강제 종료 → 시계 '$SKEW' 로 부팅, ${HOLD}초 방치"
sshn "printf '[Unit]\nDescription=lab clock skew\nBefore=kubelet.service containerd.service\n[Service]\nType=oneshot\nExecStart=/bin/date -s \"$SKEW\"\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/lab-skew.service >/dev/null; sudo systemctl enable -q lab-skew; sudo systemctl disable -q --now systemd-timesyncd; sudo sync; sleep 2"
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"; /bin/sleep 45
V2_NODES=ks-w1,ks-w2,ks-w3 V2_BIG=ks-w1 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S) node-clock=$(sshn 'date -u +%m-%dT%H:%M:%S') real=$(date -u +%m-%dT%H:%M:%S) hp=$(sshn 'grep HugePages_Total /proc/meminfo' | awk '{print $2}')"
./v2test/allwatch.sh $N $HOLD
echo "--- 방치 끝 시점"; kubectl -n longhorn-system get events --sort-by=.lastTimestamp 2>/dev/null | grep -iE "$N|instance-manager" | grep -i warn | tail -3 | cut -c1-220
sshn 'sudo journalctl -u kubelet --since "-5 min" 2>/dev/null | grep -iE "x509|certificate|expired|not yet valid|clock|lease" | tail -3 | cut -c1-240'
echo "### $(date +%H:%M:%S) 시계 복구"
sshn 'sudo systemctl disable -q lab-skew; sudo rm -f /etc/systemd/system/lab-skew.service; sudo systemctl enable -q --now systemd-timesyncd; sleep 5; date -u +%m-%dT%H:%M:%S; timedatectl | grep synchronized'
./v2test/allwatch.sh $N 900 1
echo DONE
```

## `v2test/k12.sh`

```bash
#!/bin/bash
# K12: 노드의 V2 디스크 I/O 를 STALL 초 동안 사실상 멈췄다가 푼다 (spdk_tgt 의 cgroup io.max 로 초당 1KB 제한) (하이퍼바이저 쪽 디스크 멈춤 흉내). 인자: 노드, 장치(sdc), STALL 초
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; DEV=${2:-sdc}; STALL=${3:-360}
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
echo "### K12 $(date +%H:%M:%S) (UTC $(date -u +%H:%M:%S)) $N 의 /dev/$DEV I/O 를 ${STALL}초 막음"
MM=$(sshn "lsblk -d -n -o MAJ:MIN /dev/$DEV" | tr -d ' ')
CGCMD='P=$(pgrep -f "spdk_tgt -L" | head -1); echo /sys/fs/cgroup$(cut -d: -f3 /proc/$P/cgroup)'
sshn "sudo dmesg -C; CG=\$($CGCMD); echo '$MM rbps=1024 wbps=1024' | sudo tee \$CG/io.max >/dev/null; cat \$CG/io.max"
./v2test/allwatch.sh $N $STALL
echo "--- 막힌 동안: hung=$(sshn 'sudo dmesg | grep -c "blocked for more than"') D상태=$(sshn 'ps -eLo stat,comm | awk "\$1 ~ /^D/" | sort | uniq -c | sort -rn | head -4 | tr "\n" ";"')"
sshn 'sudo dmesg -T | grep -A16 "blocked for more than" | grep -E "blocked for|Workqueue:" | head -6'
echo "### $(date +%H:%M:%S) I/O 재개"; sshn "CG=\$($CGCMD); echo '$MM rbps=max wbps=max riops=max wiops=max' | sudo tee \$CG/io.max >/dev/null; echo \"io.max: [\$(cat \$CG/io.max)]\""
./v2test/allwatch.sh $N 1200 1
PROBE=probe ./v2test/probe-report.sh 40m 2>/dev/null | tail -3
echo DONE
```

## `v2test/k13.sh`

```bash
#!/bin/bash
# K13: 파드가 쓰는 V2 볼륨의 device-mapper 장치를 멈춘(suspend) 채 파드를 지운다.
#   k13.sh <케이스> <파드> <pvc> <멈춰 둘 초> [cordon]
#   cordon 을 주면 다른 노드로 옮기는 경우, 안 주면 같은 노드에서 다시 뜨는 경우.
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
CASE=$1; POD=$2; PVC=$3; HOLD=$4; CORDON=${5:-}; NS=v2test
N=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}')
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
snap(){
  st=$(kubectl -n $NS get pod $POD -o wide --no-headers 2>/dev/null | awk '{print $3"("$2")@"$7}')
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers 2>/dev/null | grep " v2 " | grep " $N " | awk "{print \$3}")
  hung=$(sshn 'sudo dmesg | grep -c "blocked for more than"' 2>/dev/null)
  echo "pod ${st:-없음} | vol $vol | v2im $im | hung $hung"
}
echo "### $CASE $(date +%H:%M:%S) $POD @ $N pv=${PV:0:12} hold=${HOLD}s cordon=${CORDON:-no}"
sshn 'sudo dmesg -C'
sshn "sudo dmsetup suspend ${NOLOCKFS:+--nolockfs} $PV && sudo dmsetup info $PV | grep State"
[ -n "$CORDON" ] && kubectl cordon $N >/dev/null
S=$(date +%s); kubectl -n $NS delete pod $POD --wait=false >/dev/null; last=; resumed=
while :; do
  t=$(( $(date +%s)-S )); b=$(snap)
  [ "$b" != "$last" ] && { echo "+${t}s $b"; last=$b; }
  if [ -z "$resumed" ] && [ $t -ge $HOLD ]; then
    echo "+${t}s --- resume ---"; sshn "sudo dmsetup resume $PV 2>&1; sudo dmsetup info $PV 2>&1 | grep -E 'State|not'"; resumed=$t
  fi
  if echo "$b" | grep -q "Running(1/1)" && [ $t -gt 20 ]; then break; fi
  [ -n "$resumed" ] && [ $(( t-resumed )) -gt 600 ] && { echo "  resume 뒤 600초 넘게 미회복"; break; }
  /bin/sleep 5
done
echo "  결과: 총 $(( $(date +%s)-S ))s, resume 뒤 $(( $(date +%s)-S-${resumed:-0} ))s"
echo "  --- dmesg (멈춘 작업) ---"
sshn 'sudo dmesg | grep -A14 "blocked for more than" | grep -E "blocked for more|Workqueue|Call Trace|^\[.*\]  (dm_|__dm|submit_bio|wb_|jbd2|ext4_|blkdev_|sync|io_schedule|schedule)" | cut -c1-150 | head -40'
echo "  --- 파드 이벤트 ---"
kubectl -n $NS get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "$POD|$PV" | tail -8 | cut -c1-220
echo "  --- kubelet ---"
sshn "sudo journalctl -u kubelet --since -$(( ($(date +%s)-S)/60+1 ))m | grep -iE '$PV' | grep -iE 'fail|error|timeout|busy' | tail -4 | cut -c1-300"
[ -n "$CORDON" ] && kubectl uncordon $N >/dev/null
```

## `v2test/k13c.sh`

```bash
#!/bin/bash
# K13c: 파드를 지운 뒤, 새 파드가 볼륨을 마운트하기 직전에 장치를 멈춘다(suspend --nolockfs).
#   k13c.sh <케이스> <파드> <pvc> <멈춰 둘 초>      (파드가 같은 노드에 다시 뜨는 볼륨이어야 한다)
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
CASE=$1; POD=$2; PVC=$3; HOLD=$4; NS=v2test
N=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}')
sshn(){ ssh -F inventory/lab/ssh.cfg $N "$@"; }
snap(){
  st=$(kubectl -n $NS get pod $POD -o wide --no-headers 2>/dev/null | awk '{print $3"("$2")@"$7}')
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io $PV -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  x=$(sshn "echo dm=\$(sudo dmsetup info $PV 2>/dev/null | awk '/State/{print \$2}') mnt=\$(findmnt -rn | grep -c $PV) hung=\$(sudo dmesg | grep -c 'blocked for more than') trap=\$(systemctl is-active k13c)" 2>/dev/null)
  echo "pod ${st:-없음} | vol $vol | $x"
}
echo "### $CASE $(date +%H:%M:%S) $POD @ $N pv=${PV:0:12} hold=${HOLD}s"
sshn 'sudo dmesg -C; sudo systemctl reset-failed k13c 2>/dev/null'
# 노드에서 기다리다가: 마운트가 사라지고 → (장치가 없어졌다 다시 생기면 그때, 20초 안에 안 없어지면 바로) 멈춘다
sshn "sudo systemd-run --unit=k13c bash -c 'while findmnt -rn | grep -q $PV; do sleep 0.05; done; echo unmounted; i=0; while dmsetup info $PV >/dev/null 2>&1 && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done; echo gone-or-timeout \$i; until dmsetup suspend --nolockfs $PV 2>/dev/null; do sleep 0.02; done; echo suspended; sleep 3600'" 
S=$(date +%s); kubectl -n $NS delete pod $POD --wait=false >/dev/null; last=; resumed=
while :; do
  t=$(( $(date +%s)-S )); b=$(snap)
  [ "$b" != "$last" ] && { echo "+${t}s $b"; last=$b; }
  if [ -z "$resumed" ] && [ $t -ge $HOLD ]; then
    echo "+${t}s --- resume ---"; sshn "sudo systemctl stop k13c; sudo dmsetup resume $PV 2>&1; sudo dmsetup info $PV 2>&1 | grep -E 'State|not'"; resumed=$t
  fi
  if [ -n "$resumed" ] && echo "$b" | grep -q "Running(1/1)"; then break; fi
  [ -n "$resumed" ] && [ $(( t-resumed )) -gt 600 ] && { echo "  resume 뒤 600초 넘게 미회복"; break; }
  /bin/sleep 5
done
echo "  결과: 총 $(( $(date +%s)-S ))s, resume 뒤 $(( $(date +%s)-S-${resumed:-0} ))s"
echo "  --- 함정 로그 ---"; sshn 'sudo journalctl -u k13c --no-pager -o cat | tail -5'
echo "  --- dmesg (멈춘 작업) ---"
sshn 'sudo dmesg | grep -A16 "blocked for more than" | grep -E "blocked for more|Workqueue| (dm_|__dm|submit_bio|wb_|jbd2|ext4_|blkdev_|sync_|mount|do_mount|writeback)" | cut -c1-150 | head -40'
echo "  --- 파드 이벤트 ---"
kubectl -n $NS get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers | grep -E "$POD|$PV" | tail -8 | cut -c1-220
echo "  --- kubelet ---"
sshn "sudo journalctl -u kubelet --since -$(( ($(date +%s)-S)/60+1 ))m | grep -iE '$PV' | grep -iE 'fail|error|timeout|busy' | tail -4 | cut -c1-300"
echo "  --- longhorn csi plugin ---"
kubectl -n longhorn-system logs $(kubectl -n longhorn-system get pod -l app=longhorn-csi-plugin -o wide --no-headers | awk -v n=$N '$7==n{print $1}') -c longhorn-csi-plugin --since=$(( ($(date +%s)-S)/60+1 ))m 2>/dev/null | grep -iE "$PV" | grep -iE "error|fail|timeout|deadline" | tail -4 | cut -c1-300
```

## `v2test/d1.sh`

```bash
#!/bin/bash
# 데이터 3GB 가 든 3벌 V2 볼륨: 파드가 있는 노드 강제 정지 → DOWN 초 관찰 → 기동 → healthy 까지
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; DOWN=${1:-480}
N=$(kubectl -n v2test get pod big-0 -o jsonpath='{.spec.nodeName}')
echo "### $(date +%H:%M:%S) big-0 @ $N 강제 정지, ${DOWN}초 관찰"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"
./v2test/bigwatch.sh $DOWN
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/bigwatch.sh 1500 'vol attached/healthy.*pod Running\(1/1'
kubectl -n v2test logs big-0 --tail=400 2>/dev/null | grep -c WRITE-FAIL
kubectl -n v2test get events --sort-by=.lastTimestamp | grep big-0 | grep -iE "warn|kill|delet" | tail -8 | cut -c1-230
echo DONE
```

## `v2test/e1.sh`

```bash
#!/bin/bash
# 인자: 노드, 꺼 둘 초. 파드가 없는(복제본만 있는) 노드를 강제 정지 → 관찰 → 기동 → healthy 까지. staleReplicaTimeout 효과를 본다
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; DOWN=${2:-420}
V=$(kubectl -n v2test get pvc data-big-0 -o jsonpath='{.spec.volumeName}')
echo "### $(date +%H:%M:%S) $N 강제 정지 (big-0 은 $(kubectl -n v2test get pod big-0 -o jsonpath='{.spec.nodeName}')), ${DOWN}초. staleReplicaTimeout=$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.spec.staleReplicaTimeout}')분"
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant halt $N --force >/dev/null 2>&1; echo "killed $(date +%H:%M:%S)"
./v2test/bigwatch.sh $DOWN
echo "### 기동 $(date +%H:%M:%S)"; V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up $N >/dev/null 2>&1; echo "up $(date +%H:%M:%S)"
./v2test/bigwatch.sh 1200 'vol attached/healthy.*pod Running\(1/1'
kubectl -n longhorn-system logs -l app=longhorn-manager --since=25m --tail=6000 2>/dev/null | grep "$V" | grep -iE "staled|failed too long|Cleaning up" | cut -c1-40,100-330 | sort -u | head -4
echo "write fails: $(kubectl -n v2test logs big-0 --tail=2000 2>/dev/null | grep -c WRITE-FAIL)"
echo DONE
```

## `v2test/allwatch.sh`

```bash
#!/bin/bash
# 전체 상태(문제 노드의 V2 인스턴스 매니저·노드 Ready, 볼륨과 복제본, 파드)를 바뀔 때만 출력. 인자: 노드, 최대 초, [모두 정상이면 끝=1]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; MAX=${2:-600}; ENDOK=${3:-0}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  vol=$(for v in $(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$2=="v2"{print $1}'); do
    echo -n "$(kubectl -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.status.kubernetesStatus.pvcName}:{.status.state}/{.status.robustness}' | sed -E 's/attached/att/; s/detached/det/; s/healthy/ok/; s/degraded/degr/')[$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=$v -o jsonpath='{range .items[*]}{.spec.nodeID}{.spec.failedAt},{end}' | sed -E 's/ks-//g; s/20[0-9-]+T[0-9:]+Z/!/g; s/,$//')] "; done)
  pod=$(kubectl -n v2test get pods --no-headers -o wide 2>/dev/null | awk '{printf "%s=%s(%s,r%s)@%s ",$1,$3,$2,$4,substr($7,4)}')
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}'); nd=$(kubectl get node $N --no-headers | awk '{print $2}')
  b="node=$nd im=$im | $vol| $pod"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ "$ENDOK" = 1 ] && [ "$im" = running ] && ! echo "$b" | grep -qE "Init|Pending|Creating|\(0/1|faulted|degr|unknown|!|NotReady|Unknown|Crash|Error" && break
  /bin/sleep 12
done
```

## `v2test/nodewatch.sh`

```bash
#!/bin/bash
# 한 노드의 V2 준비 상태를 바뀔 때만 출력 (손대지 않고 저절로 풀리는지 보는 용). 인자: 노드, 최대 초, [끝 조건]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; MAX=${2:-3600}; END=${3:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  hpn=$(kubectl get node $N -o jsonpath='{.status.allocatable.hugepages-2Mi}'); os=$(ssh -F inventory/lab/ssh.cfg $N 'echo "hp=$(grep HugePages_Total /proc/meminfo | tr -s " " | cut -d" " -f2) mod=$(lsmod | grep -cE "^(nvme_tcp|vfio_pci|uio_pci_generic) ")/3"' 2>/dev/null)
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers | awk -v n=$N '$2=="v2" && $5==n{print $3}')
  impods=$(kubectl -n longhorn-system get pods -o wide --no-headers | grep instance-manager | awk -v n=$N '$7==n{c++} END{print c+0}')
  dk=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o jsonpath='{.status.diskStatus.v2-disk.conditions[?(@.type=="Ready")].status}')
  pods=$(kubectl -n v2test get pods -o wide --no-headers | awk -v n=$N '$7==n{printf "%s=%s(%s,r%s) ",$1,$3,$2,$4}')
  b="node-hp=$hpn os:$os im-v2=$im im-pods=$impods v2disk=$dk | $pods"
  [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && break
  /bin/sleep 15
done; echo DONE
```

## `v2test/diskwatch.sh`

```bash
#!/bin/bash
# 한 노드의 V2 인스턴스 매니저와 블록 디스크별 Ready 를 바뀔 때만 출력. 인자: 노드, 최대 초, [끝 조건]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; MAX=${2:-600}; END=${3:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  nd=$(kubectl get node $N --no-headers 2>/dev/null | awk '{print $2}')
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers 2>/dev/null | awk -v n=$N '$2=="v2" && $5==n{print $3}')
  dk=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)['status'].get('diskStatus',{})
print(' '.join('%s=%s'%(k,next((c['status'] for c in v.get('conditions',[]) if c['type']=='Ready'),'?')) for k,v in sorted(d.items()) if k.startswith('v2')))" 2>/dev/null)
  b="node=$nd im-v2=$im $dk"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && break
  /bin/sleep 3
done
```

## `v2test/recwatch.sh`

```bash
#!/bin/bash
# 전체 회복 관찰: V2 볼륨 상태와 v2test 파드 상태를 바뀔 때만 출력. 모두 정상이면 끝. 인자: 최대 초
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; MAX=${1:-3600}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk '$2=="v2"{printf "%s:%s/%s ",substr($1,5,4),substr($3,1,4),substr($4,1,4)}')
  pod=$(kubectl -n v2test get pods --no-headers -o wide 2>/dev/null | grep -v probe | awk '{printf "%s=%s(%s,r%s)@%s ",$1,$3,$2,$4,substr($7,4)}')
  b="$vol| $pod"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  echo "$vol" | grep -qvE "deta|faul|degr|unkn|atta:atta/unkn" && [ $(echo "$vol" | grep -o "heal" | wc -l) -ge 6 ] && ! echo "$pod" | grep -qE "\(0/1|Crash|Init|Pending|Terminating|Creating" && { echo "ALL-OK +$(( $(date +%s)-S ))s"; break; }
  /bin/sleep 10
done
echo DONE
```

## `v2test/bigwatch.sh`

```bash
#!/bin/bash
# big-0 의 볼륨·복제본·파드 상태를 바뀔 때만 출력. 인자: 최대 초, [끝 조건 grep 식]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
V=$(kubectl -n v2test get pvc data-big-0 -o jsonpath='{.spec.volumeName}'); MAX=${1:-300}; END=${2:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  vol=$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.state}/{.status.robustness}@{.status.currentNodeID}' 2>/dev/null)
  rep=$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=$V -o jsonpath='{range .items[*]}{.spec.nodeID}:{.status.currentState}{"("}{.spec.failedAt}{")"} {end}' 2>/dev/null | sed -E 's/\(\)//g; s/\(20[0-9-]+T([0-9:]+)Z\)/(failed \1)/g')
  pod=$(kubectl -n v2test get pod big-0 -o wide --no-headers 2>/dev/null | awk '{print $3"("$2",restarts="$4")@"$7}')
  nodes=$(kubectl get nodes ks-w1 ks-w2 ks-w3 --no-headers 2>/dev/null | awk '{printf "%s=%s ",$1,$2}')
  b="$nodes| vol $vol | rep $rep| pod $pod"
  [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && break
  /bin/sleep 5
done
```

## `v2test/big.yaml`

```yaml
# 데이터가 든 3벌 V2 볼륨: 3GB 를 써 넣고 1초마다 한 줄씩 쓴다. 재구축 시간과 그동안 파드가 흔들리는지 보는 용
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: big, namespace: v2test}
spec:
  serviceName: big
  replicas: 1
  selector: {matchLabels: {app: big}}
  template:
    metadata: {labels: {app: big}}
    spec:
      terminationGracePeriodSeconds: 5
      securityContext: {runAsUser: 26, runAsGroup: 26, fsGroup: 26}
      containers:
      - name: w
        image: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
        command: ["bash","-c"]
        args:
        - |
          [ -f /data/fill.done ] || { dd if=/dev/urandom of=/data/fill bs=1M count=3000 oflag=direct status=none && touch /data/fill.done; }
          echo "$(date -u +%H:%M:%S) start fill=$(du -m /data/fill | cut -f1)MB"
          while true; do date -u +%H:%M:%S >> /data/tick && sync /data/tick || echo "$(date -u +%H:%M:%S) WRITE-FAIL"; sleep 1; done
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec: {accessModes: [ReadWriteOnce], storageClassName: longhorn-v2, resources: {requests: {storage: 4Gi}}}
```

## `v2test/big-small.yaml`

```yaml
# 데이터가 든 3벌 V2 볼륨: 3GB 를 써 넣고 1초마다 한 줄씩 쓴다. 재구축 시간과 그동안 파드가 흔들리는지 보는 용
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: big, namespace: v2test}
spec:
  serviceName: big
  replicas: 1
  selector: {matchLabels: {app: big}}
  template:
    metadata: {labels: {app: big}}
    spec:
      terminationGracePeriodSeconds: 5
      securityContext: {runAsUser: 26, runAsGroup: 26, fsGroup: 26}
      containers:
      - name: w
        image: ghcr.io/cloudnative-pg/postgresql:16.15-minimal-bookworm
        command: ["bash","-c"]
        args:
        - |
          [ -f /data/fill.done ] || { dd if=/dev/urandom of=/data/fill bs=1M count=200 oflag=direct status=none && touch /data/fill.done; }
          echo "$(date -u +%H:%M:%S) start fill=$(du -m /data/fill | cut -f1)MB"
          while true; do date -u +%H:%M:%S >> /data/tick && sync /data/tick || echo "$(date -u +%H:%M:%S) WRITE-FAIL"; sleep 1; done
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec: {accessModes: [ReadWriteOnce], storageClassName: longhorn-v2, resources: {requests: {storage: 1Gi}}}
```

---

# 5부. 기록 원문


## `v2test/results/k/K1.log`

```text
### K1a-plain 18:35:02 big-0 @ ks-w2 pv=pvc-385a2311
+0s pod Terminating(1/1)@ks-w2 | vol attached/healthy@ks-w2
+6s pod ContainerCreating(0/1)@ks-w3 | vol attached/healthy@ks-w2
+13s pod ContainerCreating(0/1)@ks-w3 | vol detached/unknown@
+16s pod ContainerCreating(0/1)@ks-w3 | vol attaching/unknown@
+22s pod ContainerCreating(0/1)@ks-w3 | vol attached/healthy@ks-w3
+35s pod Running(1/1)@ks-w3 | vol attached/healthy@ks-w3
  결과: 35s
  옛 노드: mounts=0 umount= hung=0
2026-11-17T09:34:54Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
2026-11-17T09:35:09Z   FailedAttachVolume         Waiting for detach for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:35:25Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" : rpc error: code = Aborted desc = volume pvc-385a2311-8dda-4fd5-9fae
2026-11-17T09:35:34Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
### K1b-cnpg 18:35:59 pg-r3-2 @ ks-w2 pv=pvc-cf1fad2c
+0s pod Terminating(1/1)@ks-w2 | vol attached/healthy@ks-w2
+3s pod Init:0/1(0/1)@ks-w3 | vol attached/healthy@ks-w2
+6s pod Init:0/1(0/1)@ks-w3 | vol detaching/unknown@ks-w2
+9s pod Init:0/1(0/1)@ks-w3 | vol attaching/unknown@
+16s pod Init:0/1(0/1)@ks-w3 | vol attached/healthy@ks-w3
+28s pod Running(0/1)@ks-w3 | vol attached/healthy@ks-w3
+38s pod Running(1/1)@ks-w3 | vol attached/healthy@ks-w3
  결과: 38s
  옛 노드: mounts=0 umount= hung=0
2026-11-17T09:29:57Z   FailedAttachVolume         Waiting for detach for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:31:25Z   FailedAttachVolume         Waiting for detach for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:31:52Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" 
2026-11-17T09:36:01Z   FailedAttachVolume         Waiting for detach for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:36:16Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" : rpc error: code = Aborted desc = volume pvc-cf1fad2c-1633-4f07-9a96
2026-11-17T09:36:24Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-cf1fad2c-1633-4f07-9a96-8cab3b95ed21" 
```

## `v2test/results/k/K2.log`

```text
### K2-holder 18:38:51 big-0 @ ks-w3 pv=pvc-385a2311
+0s pod Terminating(1/1)@ks-w3 | vol attached/healthy@ks-w3
+6s pod ContainerCreating(0/1)@ks-w1 | vol attached/healthy@ks-w3
+10s pod ContainerCreating(0/1)@ks-w1 | vol detaching/unknown@ks-w3
+13s pod ContainerCreating(0/1)@ks-w1 | vol attaching/unknown@
+19s pod ContainerCreating(0/1)@ks-w1 | vol attaching/healthy@
+22s pod ContainerCreating(0/1)@ks-w1 | vol attached/healthy@ks-w1
+32s pod Running(1/1)@ks-w1 | vol attached/healthy@ks-w1
  결과: 32s
  옛 노드: mounts=0 umount= hung=0
2026-11-17T09:39:12Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" : rpc error: code = Aborted desc = volume pvc-385a2311-8dda-4fd5-9fae
2026-11-17T09:39:20Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
```

## `v2test/results/k/K3.log`

```text
### K3-fanotify-hang 18:41:07 big-0 @ ks-w1 pv=pvc-385a2311
+0s pod Terminating(1/1)@ks-w1 | vol attached/healthy@ks-w1
+6s pod ContainerCreating(0/1)@ks-w3 | vol attached/healthy@ks-w1
+10s pod ContainerCreating(0/1)@ks-w3 | vol detaching/unknown@ks-w1
+13s pod ContainerCreating(0/1)@ks-w3 | vol attaching/unknown@
+19s pod ContainerCreating(0/1)@ks-w3 | vol attaching/healthy@
+22s pod ContainerCreating(0/1)@ks-w3 | vol attached/healthy@ks-w3
+32s pod Running(1/1)@ks-w3 | vol attached/healthy@ks-w3
  결과: 32s
  옛 노드: mounts=0 umount= hung=0
2026-11-17T09:41:13Z   FailedAttachVolume         Waiting for detach for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:41:28Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" : rpc error: code = Aborted desc = volume pvc-385a2311-8dda-4fd5-9fae
2026-11-17T09:41:36Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
```

## `v2test/results/k/K4-recovery.log`

```text
+0s 18:45:43 116e:atta/heal 385a:atta/degr 8484:deta/faul 9248:atta/degr aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r4)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(0/1,r1)@ pg-v2-3=Running(1/1,r1)@ 
+11s 18:45:54 116e:atta/heal 385a:atta/degr 8484:atta/unkn 9248:atta/degr aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r4)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(0/1,r1)@ pg-v2-3=Running(1/1,r1)@ 
+21s 18:46:04 116e:atta/heal 385a:atta/degr 8484:atta/heal 9248:atta/degr aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=Running(0/1,r5)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Terminating(0/1,r1)@ pg-v2-3=Running(1/1,r1)@ 
+31s 18:46:14 116e:atta/heal 385a:atta/degr 8484:atta/heal 9248:atta/degr aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r5)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Init:0/1(0/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
+42s 18:46:25 116e:atta/heal 385a:atta/degr 8484:atta/heal 9248:atta/degr aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r5)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(1/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
+52s 18:46:35 116e:atta/heal 385a:atta/heal 8484:atta/heal 9248:atta/degr aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r5)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(1/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
+73s 18:46:56 116e:atta/heal 385a:atta/heal 8484:atta/heal 9248:atta/heal aa88:atta/heal cf1f:atta/degr | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r5)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(1/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
+83s 18:47:06 116e:atta/heal 385a:atta/heal 8484:atta/heal 9248:atta/heal aa88:atta/heal cf1f:atta/heal | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r5)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(1/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
+186s 18:48:49 116e:atta/heal 385a:atta/heal 8484:atta/heal 9248:atta/heal aa88:atta/heal cf1f:atta/heal | big-0=Running(1/1,r0)@w1 pg-r3-1=Completed(0/1,r6)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(1/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
+196s 18:48:59 116e:atta/heal 385a:atta/heal 8484:atta/heal 9248:atta/heal aa88:atta/heal cf1f:atta/heal | big-0=Running(1/1,r0)@w1 pg-r3-1=CrashLoopBackOff(0/1,r6)@ pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w2 pg-v2-2=Running(1/1,r0)@w3 pg-v2-3=Running(1/1,r1)@ 
```

## `v2test/results/k/K4.log`

```text
### K4-spdk-stalled 18:42:24 big-0 @ ks-w3 pv=pvc-385a2311
+1s pod Terminating(1/1)@ks-w3 | vol attached/healthy@ks-w3
+23s pod ContainerCreating(0/1)@ks-w1 | vol attached/healthy@ks-w3
+32s pod ContainerCreating(0/1)@ks-w1 | vol detaching/unknown@ks-w3
+111s pod ContainerCreating(0/1)@ks-w1 | vol detached/unknown@
+155s pod ContainerCreating(0/1)@ks-w1 | vol attaching/unknown@
+161s pod ContainerCreating(0/1)@ks-w1 | vol attaching/degraded@
+164s pod ContainerCreating(0/1)@ks-w1 | vol attached/degraded@ks-w1
+168s pod Running(1/1)@ks-w1 | vol attached/degraded@ks-w1
  결과: 168s
  옛 노드: mounts=0 umount= hung=0
2026-11-17T09:42:45Z   FailedAttachVolume         Waiting for detach for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:44:05Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" : rpc error: code = Aborted desc = volume pvc-385a2311-8dda-4fd5-9fae
2026-11-17T09:45:10Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
resumed
```

## `v2test/results/k/K6.log`

```text
### K6-stall-no-giveup 18:53:45 big-0 @ ks-w1 pv=pvc-385a2311
+0s pod Terminating(1/1)@ks-w1 | vol attached/healthy@ks-w1
+22s pod ContainerCreating(0/1)@ks-w2 | vol attached/healthy@ks-w1
+29s pod ContainerCreating(0/1)@ks-w2 | vol detaching/unknown@ks-w1
+110s pod ContainerCreating(0/1)@ks-w2 | vol detached/unknown@
+151s pod ContainerCreating(0/1)@ks-w2 | vol attaching/unknown@
+158s pod ContainerCreating(0/1)@ks-w2 | vol attached/degraded@ks-w2
+164s pod Running(1/1)@ks-w2 | vol attached/degraded@ks-w2
  결과: 164s
  옛 노드: mounts=0 umount= hung=0
2026-11-17T09:42:45Z   FailedAttachVolume         Waiting for detach for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:44:05Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" : rpc error: code = Aborted desc = volume pvc-385a2311-8dda-4fd5-9fae
2026-11-17T09:45:10Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
2026-11-17T09:54:06Z   FailedAttachVolume         Waiting for detach for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" Volume is already exclusively attached to one node, waiting on detach before 
2026-11-17T09:55:21Z   FailedAttachVolume         AttachVolume.Attach failed for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" : rpc error: code = Aborted desc = volume pvc-385a2311-8dda-4fd5-9fae
2026-11-17T09:56:25Z   SuccessfulAttachVolume     AttachVolume.Attach succeeded for volume "pvc-385a2311-8dda-4fd5-9fae-69099fd2233b" 
resumed
```

## `v2test/results/k/K7-long.log`

```text
+0s 19:07:36 node-hp=0 os:hp=1024 mod=3/3 im-v2=error im-pods=1 v2disk=False | pg-r3-1=Init:0/1(0/1,r0) pg-v2-2=Init:0/1(0/1,r0) 
+48s 19:08:24 node-hp=0 os:hp=1024 mod=3/3 im-v2=error im-pods=1 v2disk=False | big-0=ContainerCreating(0/1,r0) pg-r3-1=Init:0/1(0/1,r0) pg-v2-2=Init:0/1(0/1,r0) 
+936s 19:23:12 node-hp=0 os:hp=1024 mod=3/3 im-v2=starting im-pods=1 v2disk=False | big-0=ContainerCreating(0/1,r0) pg-r3-1=Init:0/1(0/1,r0) pg-v2-2=Init:0/1(0/1,r0) 
+952s 19:23:28 node-hp=0 os:hp=1024 mod=3/3 im-v2=error im-pods=1 v2disk=False | big-0=ContainerCreating(0/1,r0) pg-r3-1=Init:0/1(0/1,r0) pg-v2-2=Init:0/1(0/1,r0) 
```

## `v2test/results/k/K7.log`

```text
### K7 18:57:29 ks-w3: hugepage 설정 파일을 치우고 재부팅
up 18:58:44
+0s  18:58:44 hp(node)=0 hp(os)=0 im-v2=error impod= | pods@ks-w3: 
+11s  18:58:54 hp(node)=0 hp(os)=0 im-v2=error impod= | pods@ks-w3: pg-v2-2=Init:0/1(0/1) 
+32s  18:59:16 hp(node)=0 hp(os)=0 im-v2=error impod=Running(9s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+43s  18:59:26 hp(node)=0 hp(os)=0 im-v2=error impod=Running(20s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+54s  18:59:37 hp(node)=0 hp(os)=0 im-v2=error impod=Running(31s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+65s  18:59:48 hp(node)=0 hp(os)=0 im-v2=error impod=Running(41s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+75s  18:59:59 hp(node)=0 hp(os)=0 im-v2=error impod=Running(52s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+86s  19:00:09 hp(node)=0 hp(os)=0 im-v2=error impod=Running(63s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+97s  19:00:20 hp(node)=0 hp(os)=0 im-v2=error impod=Running(74s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+107s  19:00:31 hp(node)=0 hp(os)=0 im-v2=error impod=Running(84s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+118s  19:00:41 hp(node)=0 hp(os)=0 im-v2=error impod=Running(95s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+129s  19:00:52 hp(node)=0 hp(os)=0 im-v2=error impod=Running(106s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+140s  19:01:03 hp(node)=0 hp(os)=0 im-v2=error impod=Running(117s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+150s  19:01:14 hp(node)=0 hp(os)=0 im-v2=error impod=Running(2m7s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+161s  19:01:24 hp(node)=0 hp(os)=0 im-v2=error impod=Running(2m18s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+172s  19:01:35 hp(node)=0 hp(os)=0 im-v2=error impod=Running(2m28s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+182s  19:01:46 hp(node)=0 hp(os)=0 im-v2=error impod=Running(2m39s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+193s  19:01:56 hp(node)=0 hp(os)=0 im-v2=error impod=Running(2m50s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+204s  19:02:07 hp(node)=0 hp(os)=0 im-v2=error impod=Running(3m1s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+214s  19:02:18 hp(node)=0 hp(os)=0 im-v2=error impod=Running(3m11s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+225s  19:02:28 hp(node)=0 hp(os)=0 im-v2=error impod=Running(3m22s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+236s  19:02:39 hp(node)=0 hp(os)=0 im-v2=error impod=Running(3m33s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+247s  19:02:50 hp(node)=0 hp(os)=0 im-v2=error impod=Running(3m44s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+258s  19:03:01 hp(node)=0 hp(os)=0 im-v2=error impod=Running(3m55s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+269s  19:03:12 hp(node)=0 hp(os)=0 im-v2=error impod=Running(4m5s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+279s  19:03:23 hp(node)=0 hp(os)=0 im-v2=error impod=Running(4m16s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+290s  19:03:33 hp(node)=0 hp(os)=0 im-v2=error impod=Running(4m27s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
### 19:03:44 hugepage 만 잡는다 (kubelet 은 그대로)
+1s  19:03:45 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(4m39s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+12s  19:03:56 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(4m50s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+22s  19:04:07 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(5m)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+33s  19:04:17 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(5m11s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+44s  19:04:28 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(5m22s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+55s  19:04:39 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(5m33s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+65s  19:04:50 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(5m43s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+76s  19:05:00 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(5m54s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+87s  19:05:11 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(6m5s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+97s  19:05:22 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(6m15s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+108s  19:05:32 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(6m26s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+119s  19:05:43 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(6m37s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+130s  19:05:54 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(6m48s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+140s  19:06:05 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(6m58s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+151s  19:06:15 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(7m9s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+162s  19:06:26 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(7m19s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+172s  19:06:37 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(7m30s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+183s  19:06:47 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(7m41s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+194s  19:06:58 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(7m52s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+205s  19:07:09 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(8m2s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+215s  19:07:20 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(8m13s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
+226s  19:07:30 hp(node)=0 hp(os)=1024 im-v2=error impod=Running(8m24s)  | pods@ks-w3: pg-r3-1=Init:0/1(0/1) pg-v2-2=Init:0/1(0/1) 
```

## `v2test/results/k/K8.log`

```text
+0s 19:08:59 node-hp=2Gi os:hp=1024 mod=0/3 im-v2=error im-pods=0 v2disk=False | 
+32s 19:09:31 node-hp=2Gi os:hp=1024 mod=0/3 im-v2=starting im-pods=2 v2disk=False | 
+47s 19:09:46 node-hp=2Gi os:hp=1024 mod=0/3 im-v2=running im-pods=2 v2disk=False | 
+79s 19:10:18 node-hp=2Gi os:hp=1024 mod=0/3 im-v2=running im-pods=2 v2disk=True | 
DONE
```

## `v2test/results/k/K9.log`

```text
### K9a 19:30:07 ks-w1 정상 종료 후 기동
up 19:31:47
+1s 19:31:48 node=Ready im-v2=starting v2-big=False v2-disk=False
+20s 19:32:07 node=Ready im-v2=running v2-big=False v2-disk=False
+78s 19:33:05 node=Ready im-v2=running v2-big=True v2-disk=True
### K9b 19:33:05 ks-w1 강제 종료 후 기동
up 19:33:37
+0s 19:33:37 node=Ready im-v2=running v2-big=False v2-disk=False
+20s 19:33:57 node=Ready im-v2=starting v2-big=False v2-disk=False
+36s 19:34:13 node=Ready im-v2=running v2-big=False v2-disk=False
+78s 19:34:55 node=Ready im-v2=running v2-big=True v2-disk=True
```

## `v2test/results/k/K10.log`

```text
### K10 19:49:40 ks-w2 강제 종료 → hugepage 0 으로 복귀, 2400초 방치
im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w3,w2] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
killed 19:49:47
up 19:51:14 hp=0
+1s 19:51:15 im=unknown | pg-v2-2:att/unknown[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/unknown[w1,w3,w2] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Unknown(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+33s 19:51:47 im=error | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/unknown[w1,w3,w2!] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Unknown(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+65s 19:52:19 im=error | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/unknown[w1,w3,w2!] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Init:0/1(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+1815s 20:21:29 im=error | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/unknown[w1,w3,w2!] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Init:0/1(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+1863s 20:22:17 im=error | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/unknown[w1,w3] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Init:0/1(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
### 20:31:22 hugepage 복구 + kubelet 재시작
+1s 20:31:25 im=error | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/unknown[w1,w3] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Init:0/1(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+33s 20:31:57 im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/faulted[w1,w3] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Init:0/1(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+49s 20:32:13 im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w3] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+65s 20:32:29 im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w3] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+81s 20:32:45 im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w3] pg-r3-1:att/degr[w1,w3] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Init:0/1(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+98s 20:33:02 im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w3] pg-r3-1:att/degr[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+114s 20:33:18 im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w2,w3] pg-r3-1:att/degr[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+130s 20:33:34 im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
2026-11-17T11:21:25.
2026-11-17T11:22:02.
DONE
```

## `v2test/results/k/K11a.log`

```text
### K11a 20:34:02 ks-w2 시계를 9시간 앞으로 (재부팅 없음)
Tue Nov 17 08:34:03 PM UTC 2026
+1s 20:34:04 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
### 20:41:03 시계 복구
Tue Nov 17 11:41:06 AM UTC 2026
System clock synchronized: yes
+1s 20:41:07 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
```

## `v2test/results/k/K11b.log`

```text
### K11b 20:41:33 ks-w2 강제 종료 → 시계 '+9 hours' 로 부팅, 480초 방치
killed 20:41:40
up 20:42:55 node-clock=11-17T20:42:56 real=11-17T11:42:55 hp=1024
+1s 20:42:56 node=Ready im=running | pg-v2-2:att/unknown[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/unknown[w1,w2,w3] pg-r3-1:att/degr[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Unknown(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+27s 20:43:22 node=Ready im=starting | pg-v2-2:detaching/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:detaching/faulted[w1,w2!,w3] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Unknown(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+41s 20:43:36 node=Ready im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:attaching/unknown[w1,w2!,w3] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Unknown(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+54s 20:43:49 node=Ready im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w2!,w3] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Unknown(0/1,r0)@w2 pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+67s 20:44:02 node=Ready im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w2!,w3] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(0/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+80s 20:44:15 node=Ready im=running | pg-v2-2:det/faulted[w2!] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w2!,w3] pg-r3-1:att/degr[w1,w3,w2!] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+93s 20:44:28 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/degr[w1,w2,w3] pg-r3-1:att/degr[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+106s 20:44:41 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Unknown(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 
+132s 20:45:07 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(0/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 
+145s 20:45:20 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 
--- 방치 끝 시점
8m31s       Warning   Schedulable              node/ks-w2                                                                       Waiting for disk default-disk-a7531094fa8d6290 (/var/lib/longhorn/) on node ks-w2 to be sche
8m30s       Warning   NodeNotReady             pod/instance-manager-232daedaaa5f584bea7d1584db330005                            Node is not ready
<invalid>   Warning   FailedStopping           replica/pvc-cfdeee8d-8ca2-450e-b24f-07d591ff4be6-r-f2b0bff0                      Error stopping pvc-cfdeee8d-8ca2-450e-b24f-07d591ff4be6-r-f2b0bff0: failed to initialize ins
### 20:50:59 시계 복구
11-17T11:51:05
System clock synchronized: yes
+1s 20:51:06 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 
DONE
```

## `v2test/results/k/K12.log`

```text
### K12 21:00:24 (UTC 12:00:24) ks-w2 의 /dev/sdc I/O 를 360초 막음
8:32 rbps=1024 wbps=1024 riops=max wiops=max
+1s 21:00:25 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 probe=Running(1/1,r0)@w1 
+92s 21:01:56 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1+157s 21:01:59 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,+105s 21:02:09 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1+351s 21:05:13 node=Ready im=running | pg-v2-2:detaching/unknown[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=CrashLoopBackOff(0/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 probe=Running(1/1,r0)@w1 
)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=CrashLoopBackOff(0/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 probe=Running(1/1,r0)@w1 
--- 막힌 동안: hung=0 D상태=
### 21:06:28 I/O 재개
io.max: []
+2s 21:06:30 node=Ready im=running | pg-v2-2:detaching/faulted[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=CrashLoopBackOff(0/1,r1)@ pg-v2-3=Running(1/1,r0)@w3 probe=Running(1/1,r0)@w1 
+15s 21:06:43 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(0/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 probe=Running(1/1,r0)@w1 
+28s 21:06:56 node=Ready im=running | pg-v2-2:att/ok[w2] pg-v2-1:att/ok[w1] pg-v2-3:att/ok[w3] pg-r3-2:att/ok[w1,w2,w3] pg-r3-1:att/ok[w1,w3,w2] | pg-r3-1=Running(1/1,r0)@w1 pg-r3-2=Running(1/1,r1)@ pg-v2-1=Running(1/1,r0)@w1 pg-v2-2=Running(1/1,r0)@w2 pg-v2-3=Running(1/1,r0)@w3 probe=Running(1/1,r0)@w1 
samples 795 11:52:09 ~ 12:06:55
write fail runs: none
read fail runs: ['12:00:30~12:00:30 (1 samples)', '12:00:35~12:00:45 (4 samples)', '12:00:52~12:00:52 (1 samples)', '12:00:57~12:01:00 (2 samples)', '12:01:15~12:01:21 (3 samples)', '12:01:27~12:01:27 (1 samples)', '12:01:33~12:01:33 (1 samples)', '12:01:37~12:01:40 (2 samples)', '12:01:45~12:01:45 (1 samples)', '12:01:50~12:01:50 (1 samples)']
DONE
```

## `v2test/results/k/K13a.log`

```text
### K13a 22:14:25 pg-r3-2 @ ks-w2 pv=pvc-8a44b69b hold=480s cordon=cordon
State:             SUSPENDED
+1s pod Terminating(1/1)@142m | vol attached/healthy@ks-w2 | v2im  | hung 0
+44s pod Terminating(1/1)@143m | vol attached/healthy@ks-w2 | v2im  | hung 0
+104s pod Terminating(1/1)@144m | vol attached/healthy@ks-w2 | v2im  | hung 0
+153s pod Terminating(1/1)@144m | vol attached/healthy@ks-w2 | v2im  | hung 2
+164s pod Terminating(1/1)@145m | vol attached/healthy@ks-w2 | v2im  | hung 2
+223s pod Terminating(1/1)@146m | vol attached/healthy@ks-w2 | v2im  | hung 2
+277s pod Terminating(1/1)@146m | vol attached/healthy@ks-w2 | v2im  | hung 4
+283s pod Terminating(1/1)@147m | vol attached/healthy@ks-w2 | v2im  | hung 4
+342s pod Terminating(1/1)@148m | vol attached/healthy@ks-w2 | v2im  | hung 4
+402s pod Terminating(1/1)@149m | vol attached/healthy@ks-w2 | v2im  | hung 6
+467s pod Terminating(1/1)@150m | vol attached/healthy@ks-w2 | v2im  | hung 6
+483s --- resume ---
State:             ACTIVE
+488s pod Init:0/1(0/1)@ks-w3 | vol attached/healthy@ks-w2 | v2im  | hung 6
+494s pod Init:0/1(0/1)@ks-w3 | vol attaching/unknown@ | v2im  | hung 6
+499s pod Init:0/1(0/1)@ks-w3 | vol attaching/healthy@ | v2im  | hung 6
+505s pod Running(0/1)@ks-w3 | vol attached/healthy@ks-w3 | v2im  | hung 6
+515s pod Running(1/1)@ks-w3 | vol attached/healthy@ks-w3 | v2im  | hung 6
  결과: 총 516s, resume 뒤 33s
  --- dmesg (멈춘 작업) ---
[ 5653.399737] INFO: task manager:5794 blocked for more than 122 seconds.
[ 5653.404122]  schedule+0x40/0x168
[ 5653.404236] INFO: task postgres:5802 blocked for more than 122 seconds.
[ 5653.408690]  schedule+0x40/0x168
[ 5776.288200] INFO: task manager:5794 blocked for more than 245 seconds.
[ 5776.289712]  schedule+0x40/0x168
[ 5776.289770] INFO: task postgres:5802 blocked for more than 245 seconds.
[ 5776.290374]  schedule+0x40/0x168
[ 5899.172121] INFO: task manager:5794 blocked for more than 368 seconds.
[ 5899.176391]  schedule+0x40/0x168
[ 5899.176559] INFO: task postgres:5802 blocked for more than 368 seconds.
[ 5899.178002]  schedule+0x40/0x168
  --- 파드 이벤트 ---
2026-11-17T13:22:30Z   Scheduled                Successfully assigned v2test/pg-r3-2 to ks-w3
2026-11-17T13:22:30Z   FailedAttachVolume       Waiting for detach for volume "pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235" Volume is already exclusively attached to one node, waiting on detach before it can be attached to 
2026-11-17T13:22:42Z   FailedAttachVolume       AttachVolume.Attach failed for volume "pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235" : rpc error: code = Aborted desc = volume pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235 is not r
2026-11-17T13:22:46Z   SuccessfulAttachVolume   AttachVolume.Attach succeeded for volume "pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235" 
  --- kubelet ---
Nov 17 20:43:07 ks-w2 kubelet[1330]: E1117 20:43:07.200827    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235 podName: nodeName:}" failed. No retries permitted until 2026-11-17 20:43:23.200816968 +0000 UTC 
Nov 17 20:43:23 ks-w2 kubelet[1330]: E1117 20:43:23.553149    1330 csi_attacher.go:401] kubernetes.io/csi: attacher.MountDevice failed: rpc error: code = InvalidArgument desc = volume pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235 hasn't been attached yet
Nov 17 20:43:23 ks-w2 kubelet[1330]: I1117 20:43:23.554422    1330 operation_generator.go:681] "MountVolume.markDeviceErrorState leaving volume uncertain" volumeName="kubernetes.io/csi/driver.longhorn.io^pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235"
Nov 17 20:43:23 ks-w2 kubelet[1330]: E1117 20:43:23.554529    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-8a44b69b-a454-4c9d-83ee-03226f7f6235 podName: nodeName:}" failed. No retries permitted until 2026-11-17 20:43:55.554515059 +0000 UTC 
```

## `v2test/results/k/K13b.log`

```text
### K13b 22:24:55 pg-v2-2 @ ks-w2 pv=pvc-2308cb8c hold=300s cordon=no
State:             SUSPENDED
+0s pod Terminating(1/1)@ks-w2 | vol attached/healthy@ks-w2 | v2im running | hung 0
+136s pod Terminating(1/1)@ks-w2 | vol attached/healthy@ks-w2 | v2im running | hung 2
+261s pod Terminating(1/1)@ks-w2 | vol attached/healthy@ks-w2 | v2im running | hung 4
+304s --- resume ---
State:             ACTIVE
+310s pod Running(0/1)@ks-w2 | vol attached/healthy@ks-w2 | v2im running | hung 4
+320s pod Running(1/1)@ks-w2 | vol attached/healthy@ks-w2 | v2im running | hung 4
  결과: 총 321s, resume 뒤 17s
  --- dmesg (멈춘 작업) ---
[ 6267.819965] INFO: task manager:24223 blocked for more than 122 seconds.
[ 6267.821780]  schedule+0x40/0x168
[ 6267.821781]  io_schedule+0x48/0x80
[ 6267.821802]  ext4_sync_file+0x80/0x430
[ 6267.821838] INFO: task postgres:24275 blocked for more than 122 seconds.
[ 6267.822344]  schedule+0x40/0x168
[ 6267.822345]  io_schedule+0x48/0x80
[ 6267.822352]  ext4_sync_file+0x80/0x430
[ 6390.703759] INFO: task jbd2/dm-2-8:24047 blocked for more than 122 seconds.
[ 6390.706034]  schedule+0x40/0x168
[ 6390.706035]  io_schedule+0x48/0x80
[ 6390.706062]  jbd2_journal_commit_transaction+0xe3c/0x1720
[ 6390.706092] INFO: task manager:24223 blocked for more than 245 seconds.
[ 6390.706669]  schedule+0x40/0x168
[ 6390.706670]  io_schedule+0x48/0x80
[ 6390.706682]  ext4_sync_file+0x80/0x430
  --- 파드 이벤트 ---
2026-11-17T13:30:02Z   Scheduled                Successfully assigned v2test/pg-v2-2 to ks-w2
  --- kubelet ---
Nov 17 20:43:23 ks-w2 kubelet[1330]: E1117 20:43:23.347760    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 podName: nodeName:}" failed. No retries permitted until 2026-11-17 20:43:55.347711351 +0000 UTC 
Nov 17 20:43:55 ks-w2 kubelet[1330]: E1117 20:43:55.461377    1330 csi_attacher.go:401] kubernetes.io/csi: attacher.MountDevice failed: rpc error: code = InvalidArgument desc = volume pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 hasn't been attached yet
Nov 17 20:43:55 ks-w2 kubelet[1330]: I1117 20:43:55.461666    1330 operation_generator.go:681] "MountVolume.markDeviceErrorState leaving volume uncertain" volumeName="kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5"
Nov 17 20:43:55 ks-w2 kubelet[1330]: E1117 20:43:55.461749    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 podName: nodeName:}" failed. No retries permitted until 2026-11-17 20:44:59.461737824 +0000 UTC 
```

## `v2test/results/k/K13c.log`

```text
### K13c 22:31:44 pg-v2-2 @ ks-w2 pv=pvc-2308cb8c hold=420s
Running as unit: k13c.service; invocation ID: 63c1f4aecea9415c8d820f83741d287a
+0s pod Terminating(1/1)@ks-w2 | vol attached/healthy@ks-w2 | dm=ACTIVE mnt=2 hung=0 trap=active
+5s pod Init:0/1(0/1)@ks-w2 | vol attaching/unknown@ | dm= mnt=0 hung=0 trap=active
+11s pod Init:0/1(0/1)@ks-w2 | vol attaching/unknown@ | dm=SUSPENDED mnt=0 hung=0 trap=active
+16s pod Init:0/1(0/1)@ks-w2 | vol attached/healthy@ks-w2 | dm=SUSPENDED mnt=0 hung=0 trap=active
+424s --- resume ---
State:             ACTIVE
+429s pod Init:0/1(0/1)@ks-w2 | vol attached/healthy@ks-w2 | dm=ACTIVE mnt=2 hung=0 trap=inactive
+435s pod Running(0/1)@ks-w2 | vol attached/healthy@ks-w2 | dm=ACTIVE mnt=2 hung=0 trap=inactive
+440s pod Running(1/1)@ks-w2 | vol attached/healthy@ks-w2 | dm=ACTIVE mnt=2 hung=0 trap=inactive
  결과: 총 440s, resume 뒤 16s
  --- 함정 로그 ---
gone-or-timeout 16
suspended
Stopping k13c.service - /usr/bin/bash -c "while findmnt -rn | grep -q pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5; do sleep 0.05; done; echo unmounted; i=0; while dmsetup info pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 >/dev/null 2>&1 && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done; echo gone-or-timeout \$i; until dmsetup suspend --nolockfs pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 2>/dev/null; do sleep 0.02; done; echo suspended; sleep 3600"...
k13c.service: Deactivated successfully.
Stopped k13c.service - /usr/bin/bash -c "while findmnt -rn | grep -q pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5; do sleep 0.05; done; echo unmounted; i=0; while dmsetup info pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 >/dev/null 2>&1 && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done; echo gone-or-timeout \$i; until dmsetup suspend --nolockfs pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 2>/dev/null; do sleep 0.02; done; echo suspended; sleep 3600".
  --- dmesg (멈춘 작업) ---
  --- 파드 이벤트 ---
2026-11-17T13:30:02Z   Scheduled                Successfully assigned v2test/pg-v2-2 to ks-w2
2026-11-17T13:31:45Z   Scheduled                Successfully assigned v2test/pg-v2-2 to ks-w2
2026-11-17T13:31:58Z   FailedAttachVolume       AttachVolume.Attach failed for volume "pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5" : rpc error: code = Aborted desc = volume pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 is not r
2026-11-17T13:32:07Z   SuccessfulAttachVolume   AttachVolume.Attach succeeded for volume "pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5" 
2026-11-17T13:38:08Z   FailedMount              MountVolume.MountDevice failed for volume "pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5" : rpc error: code = DeadlineExceeded desc = context deadline exceeded
2026-11-17T13:38:48Z   FailedMount              MountVolume.MountDevice failed for volume "pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5" : rpc error: code = Internal desc = mount failed: exit status 32
Mounting arguments: -t ext4 -o defaults /dev/longhorn/pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 /var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/61429405b60a33cf6a3f9976c807dc82ced55699e3deb827665cca5c368da4b
Output: mount: /var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/61429405b60a33cf6a3f9976c807dc82ced55699e3deb827665cca5c368da4b7/globalmount: /dev/longhorn/pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 already mo
  --- kubelet ---
Nov 17 13:34:07 ks-w2 kubelet[1330]: E1117 13:34:07.318736    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 podName: nodeName:}" failed. No retries permitted until 2026-11-17 13:34:07.818409875 +0000 UTC 
Nov 17 13:36:07 ks-w2 kubelet[1330]: E1117 13:36:07.925975    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 podName: nodeName:}" failed. No retries permitted until 2026-11-17 13:36:08.925945364 +0000 UTC 
Nov 17 13:38:08 ks-w2 kubelet[1330]: E1117 13:38:08.968066    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 podName: nodeName:}" failed. No retries permitted until 2026-11-17 13:38:10.968035755 +0000 UTC 
Nov 17 13:38:48 ks-w2 kubelet[1330]: E1117 13:38:48.985795    1330 nestedpendingoperations.go:348] Operation for "{volumeName:kubernetes.io/csi/driver.longhorn.io^pvc-2308cb8c-6dc7-45b0-b88f-5bfe69a743d5 podName: nodeName:}" failed. No retries permitted until 2026-11-17 13:38:52.985036723 +0000 UTC 
  --- longhorn csi plugin ---
```

## `v2test/results/D1.log`

```text
### 15:07:28 big-0 @ ks-w1 강제 정지, 480초 관찰
killed 15:07:32
+0s 15:07:33 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/healthy@ks-w1 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w1
+47s 15:08:20 ks-w1=NotReady ks-w2=Ready ks-w3=Ready | vol attached/unknown@ks-w1 | rep ks-w2:running ks-w1:unknown ks-w3:running | pod Running(1/1,restarts=0)@ks-w1
+351s 15:13:24 ks-w1=NotReady ks-w2=Ready ks-w3=Ready | vol attached/faulted@ks-w1 | rep ks-w2:running ks-w1:stopped(failed 06:13:22) ks-w3:running | pod Terminating(1/1,restarts=0)@ks-w1
+356s 15:13:29 ks-w1=NotReady ks-w2=Ready ks-w3=Ready | vol attaching/unknown@ | rep ks-w2:running ks-w1:stopped(failed 06:13:22) ks-w3:running | pod Terminating(1/1,restarts=0)@ks-w1
+377s 15:13:50 ks-w1=NotReady ks-w2=Ready ks-w3=Ready | vol detached/unknown@ | rep ks-w2:stopped ks-w1:stopped(failed 06:13:22) ks-w3:stopped | pod Terminating(1/1,restarts=0)@ks-w1
### 기동 15:15:35
up 15:16:05
+0s 15:16:06 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/healthy@ks-w3 | rep ks-w2:running ks-w1:stopped(failed 06:13:22) ks-w3:running | pod ContainerCreating(0/1,restarts=0)@ks-w3
+5s 15:16:11 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:running ks-w1:stopped(failed 06:13:22) ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+86s 15:17:32 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+230s 15:19:56 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/healthy@ks-w3 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
0
11m         Warning   NodeNotReady               pod/big-0                           Node is not ready
6m38s       Normal    TaintManagerEviction       pod/big-0                           Marking for deletion Pod v2test/big-0
5m9s        Warning   FailedAttachVolume         pod/big-0                           AttachVolume.Attach failed for volume "pvc-2e0ddb7d-72a2-43c3-a547-99448b0829ca" : rpc error: code = Internal desc = Bad response statusCode [500
4m37s       Warning   FailedAttachVolume         pod/big-0                           AttachVolume.Attach failed for volume "pvc-2e0ddb7d-72a2-43c3-a547-99448b0829ca" : rpc error: code = Internal desc = Bad response statusCode [500
DONE
```

## `v2test/results/E1.log`

```text
### 15:20:47 ks-w2 강제 정지 (big-0 은 ks-w3), 420초. staleReplicaTimeout=3분
killed 15:20:51
+1s 15:20:52 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/healthy@ks-w3 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+22s 15:21:13 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:running(failed 06:21:12) ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+32s 15:21:23 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+43s 15:21:34 ks-w1=Ready ks-w2=NotReady ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:stopped ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+90s 15:22:21 ks-w1=Ready ks-w2=NotReady ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:stopped(failed 06:22:20) ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+289s 15:25:40 ks-w1=Ready ks-w2=NotReady ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
### 기동 15:27:52
up 15:28:24
+0s 15:28:24 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+735s 15:40:39 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:stopped ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+741s 15:40:45 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/degraded@ks-w3 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
+810s 15:41:54 ks-w1=Ready ks-w2=Ready ks-w3=Ready | vol attached/healthy@ks-w3 | rep ks-w2:running ks-w1:running ks-w3:running | pod Running(1/1,restarts=0)@ks-w3
time="2026-11-17T06:25:38.687099827Z" ledb7d-72a2-43c3-a547-99448b0829ca-r-a591d5ae in instance manager instance-manager-232daedaaa5f584bea7d1584db330005" func="controller.(*ReplicaController).DeleteInstance" file="replica_controller.go:608" controller=longhorn-replica n
time="2026-11-17T06:25:38.769671426Z" le0829ca-r-a591d5ae failed too long ago to be useful during a rebuild" func="controller.(*VolumeController).shouldCleanUpFailedReplica" file="volume_controller.go:7527" accessMode=rwo controller=longhorn-volume frontend=blockdev migr
time="2026-11-17T06:25:38.769719138Z" lecontroller.(*VolumeController).cleanupCorruptedOrStaleReplicas" file="volume_controller.go:1358" accessMode=rwo controller=longhorn-volume frontend=blockdev migratable=false node=ks-w3 owner=ks-w3 replica=pvc-2e0ddb7d-72a2-43c3-a54
write fails: 0
DONE
```
