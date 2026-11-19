# V2 볼륨 미부착: "떼는 순간" 가설 시험 (Longhorn 1.12.1 대 1.12.2)

[V2-SUSPENDED-DM-TESTS.md](V2-SUSPENDED-DM-TESTS.md) 다음 문서다. 앞 문서는 dm 을 손으로 멈추고 `spdk_tgt` 를 죽여 굳은 상태를 만들었다. 이 문서는 "떼는 순간에 무엇이 겹쳐야 굳는가"를 가설로 나눠 두 버전에서 시험한 기록이다. 시험일은 2026-11-18, 모든 시험은 1번씩이다.

## 1. 결론

- **`spdk_tgt` 가 죽지 않아도 굳는다.** 타깃이 멀쩡해도 dm 이 `Suspended` 로 남아 있고 그 위에 쓰는 프로세스가 있으면, 파드를 지울 때 컨테이너가 죽지 않고 볼륨이 떨어지지 않는다. 새 파드는 `FailedAttachVolume … Waiting for detach` 로 기다린다. 1.12.1 에서 15분, 1.12.2 에서 7분 동안 그대로였고(둘 다 시험을 끊은 시점), `dmsetup resume` 뒤에 바로 풀렸다.
- **Longhorn 은 남의 손에 멈춘 dm 을 스스로 풀지 않는다.** 3분 동안 볼륨은 `attached healthy`, 엔진 프런트엔드는 `running` 이었다. 두 버전 모두 같다.
- **버전 차이는 "멈춰 있는 시간"에서 났다.** 저장소가 느릴 때 Longhorn 이 스스로 거는 멈춤이 얼마나 오래 가는지가 다르다.

  | 느린 저장소(CPU 3%)에서 | 1.12.1 | 1.12.2 |
  |---|---|---|
  | 레플리카 재구축의 멈춤 명령 | 96초 | 3.8초, 4.9초 |
  | 스냅샷의 멈춤 명령 | 1개가 104초 동안 돌고 성공 | 약 31초에 3번 시간 초과, 버려진 `dmsetup` 이 5개까지 D 상태로 쌓임 |
  | 끝난 뒤 남은 dm | 없음 | 없음 |

- **그래서 1.12.2 가 줄이는 것은 "멈춰 있는 창"이다.** 멈춰 있는 동안 `spdk_tgt` 가 죽거나 볼륨이 옮겨 가면 굳는다(앞 문서 U4). 재구축 쪽 창은 1.12.2 에서 크게 줄었고, 스냅샷 쪽 창은 줄지 않았다.
- **dm 이 왜 멈춘 채 남았는지는 아직 실서버에서 확인할 일이다.** 랩에서 Longhorn 자체 동작만으로 멈춘 채 남은 것은 한 번이고(W3), 그 시험은 방법에 문제가 있었다(3.3절).

## 2. 가설

Longhorn 은 스냅샷 생성, 레플리카 재구축, 볼륨 확장 때 dm 을 멈춘다(`longhorn-spdk-engine` v1.12.1 `pkg/spdk/enginefrontend.go:2362`, `pkg/spdk/server.go:827`, `enginefrontend.go:1324`). 멈춤이 실패하면 재구축은 "proceeding without suspension" 으로 그냥 진행하고 resume 을 부르지 않는다(`server.go:826-843`). 스냅샷은 오류를 돌려주고 resume 을 부르지 않는다(`enginefrontend.go:2362-2364`).

| 가설 | 내용 | 시험 |
|---|---|---|
| G1 | 멈춤 명령이 오래 걸려 Longhorn 은 포기했는데, 버려진 `dmsetup suspend` 가 나중에 끝나 dm 이 멈춘 채 남는다 | W2, W3, W3b |
| G2 | 타깃이 멀쩡해도 dm 이 멈춘 채 남아 있으면 Longhorn 이 풀지 못하고, 떼는 동작이 끝나지 않는다 | W1 |
| G3 | 재구축이 거는 멈춤이 저장소가 느릴 때 길어진다. 한 노드의 `spdk_tgt` 가 죽으면 다른 노드에서 재구축이 돌므로 멈춤이 번진다 | W4 (번지는 것 자체는 시험하지 않음) |

## 3. 시험 기록

환경은 앞 문서와 같다(랩 워커 3대, 커널 6.8, arm64, CPU 격리 켬, 실서버와 같은 StorageClass). 시험 볼륨은 디플로이먼트 `u4` 의 1Gi 볼륨이고, 파드가 `dd` 로 계속 쓴다.

### 3.1 G2: 멈춘 채 남은 dm (W1)

정상 볼륨의 dm 에 `dmsetup suspend --noflush --nolockfs` 만 하고 3분 둔 뒤, 그 노드를 cordon 하고 파드를 지웠다.

| 볼 것 | 1.12.1 | 1.12.2 |
|---|---|---|
| 3분 동안 Longhorn 이 풀었나 | 아니다. 볼륨 `attached healthy`, `dd` 는 D 상태 | 같음 |
| 파드를 지운 뒤 옛 파드 | `Terminating`, `KillContainer … DeadlineExceeded`, `KillPodSandbox` 실패 | 같음 |
| 새 파드 | `ContainerCreating`, `FailedAttachVolume … Waiting for detach … Volume is already used by pod(s)` | 같음 |
| 지켜본 시간 | 15분 | 7분 |
| `dmsetup resume` 뒤 | 36초에 새 파드 `Running`. XFS 는 꺼지지 않았다 | 새 파드 `Running` (시간은 재지 않음) |

- 타깃이 살아 있으므로 `resume` 하면 매달렸던 I/O 가 정상으로 끝난다. 앞 문서 U4 와 달리 파일시스템이 꺼지지 않았다.
- 쓰는 프로세스가 없을 때는 달랐다(`W1-1122-nowrite.log`, 1.12.2). 볼륨은 51초 만에 다른 노드에 붙었고, 옛 노드에 `Suspended` open 1 과 D 상태 `umount` 가 남았다. 앞 문서 U4 의 끝 상태와 같다. 즉 쓰는 프로세스가 있으면 attach 가 막히고, 없으면 attach 는 되지만 옛 노드에 굳은 dm 이 남는다.

### 3.2 G3: 느린 저장소에서 재구축의 멈춤 (W4)

`spdk_tgt` 컨테이너의 `cpu.max` 를 3% 로 조여 "살아 있지만 느린" 타깃을 만들고(쓰기 약 4MB/s), 버퍼 쓰기 800MB 를 건 직후 다른 노드의 레플리카 하나를 지웠다.

| 볼 것 | 1.12.1 | 1.12.2 |
|---|---|---|
| 재구축 시작 때 멈춤 명령이 걸린 시간 | 95.8초 (11:33:11 → 11:34:46) | 3.8초 |
| 재구축 끝 때 | 0.05초 (느린 구간이 끝난 뒤였다) | 4.9초 |
| dm 이 `Suspended` 로 보인 최장 구간 | 9.4초 | 11.5초 |
| 끝난 뒤 | `Active`, 남은 것 없음 | 같음 |

1.12.2 의 #14419(재구축 멈춤에서 파일시스템 동기화를 뺌)가 실제로 듣는 것을 확인했다. 1.12.1 의 96초 동안은 dm 이 아직 `Active` 지만 파일시스템이 얼어 가는 중이라 그 볼륨의 쓰기가 전부 멈춘다.

### 3.3 G1: 버려진 멈춤 명령 (W2, W3, W3b)

| 시험 | 버전 | 방법 | 결과 |
|---|---|---|---|
| W2 | 1.12.2 | NVMe-TCP 포트를 45초 막고 스냅샷 요청 | `dmsetup suspend` 가 18초 D 상태. 15초에 커널이 I/O 를 실패 처리(`failfast expired`)해 XFS 가 꺼지고 `Filesystem freeze failed`. dm 은 `Active` 로 남았다. 볼륨은 `attached healthy` 인데 파일시스템은 죽은 상태 |
| W3 | 1.12.2 | `spdk_tgt` 를 0.95초 멈춤/0.05초 실행으로 반복하며 스냅샷 요청 | 멈춤 명령이 30초에 2번 시간 초과. 버려진 `dmsetup suspend` 2개가 9분 넘게 D 상태, 그 볼륨의 쓰기 전부 D 상태. XFS 재시도를 끄자 얼리기가 끝나면서 **dm 이 `Suspended` 로 바뀌어 남았다** |
| W3b | 1.12.1 | CPU 3% 로 조이고 스냅샷 요청 | 멈춤 명령 1개가 104초 돌고 성공, 곧바로 resume. 남은 것 없음 |
| W3b | 1.12.2 | 같음 | 약 31초에 3번 시간 초과(`Failed to suspend the dm device elapsedMs=31798`). 버려진 `dmsetup` 이 5개까지 쌓임. 느린 구간이 끝나자 5번째 시도가 성공하고 resume. 남은 것 없음 |

- **W3 의 결과는 방법 탓이 섞였다.** `spdk_tgt` 가 정지(T) 상태로 보여 생존 검사가 실패했고(`spdk_tgt process … is in T`), 인스턴스 매니저가 죽으면서 장치가 사라졌다(`limit=0`). 그래서 얼리기가 끝나지 못했다. "버려진 멈춤이 나중에 끝나 dm 이 멈춘 채 남는다"는 것 자체는 한 번 봤지만, 실서버에서 그대로 일어난다는 근거로는 약하다.
- **W3b 에서는 남지 않았다.** Longhorn 이 스냅샷을 계속 재시도했고, 마지막 시도가 성공하면서 resume 을 불렀기 때문이다. 재시도가 멈추는 경우(스냅샷 요청이 지워지거나 포기되는 경우)는 시험하지 않았다.
- **1.12.2 는 시간 초과한 `dmsetup` 을 죽이지 못했다.** D 상태라 신호가 듣지 않는다. 30초마다 하나씩 쌓였다.
- W2 와 W3 은 1.12.2 에서만 했다.

기록은 `v2test/results/w/`, 스크립트는 `v2test/w*.sh` 와 `v2test/u-dmwatch.sh` 다.

## 4. 실서버에 대해 말할 수 있는 것

- **굳는 조건을 다시 쓴다.** "dm 이 `Suspended` 로 남아 있다"가 필요조건이다. `spdk_tgt` 의 죽음은 dm 을 멈춘 채 남기는 여러 길 중 하나다.
- **실서버 증상과 맞는 것**: `FailedAttachVolume`, `KillPodSandbox DeadlineExceeded`, 밑장치(nvme)가 살아 있는데 `Suspended` 인 dm, 그 볼륨만 안 붙고 Longhorn 은 정상으로 보이는 것. 앞의 두 문서는 "살아 있는 nvme 위의 `Suspended` dm"을 설명하지 못했는데, W1 이 그 모습이다.
- **추정**: 실서버(1.12.1)는 저장소가 느려질 때 멈춤 창이 분 단위로 길어진다(랩 96초, 104초). 그 사이에 `spdk_tgt` 가 죽거나 인스턴스 매니저가 재생성되면 resume 을 부를 주체가 사라진다. 워커 5대에 `Suspended` dm 이 남은 것은 이 경로로 설명된다. 확인하지 않았다.

실서버에서 확인할 것(읽기만):

| 볼 것 | 방법 | 뜻 |
|---|---|---|
| 멈춤이 걸린 시간 | V2 인스턴스 매니저 로그에서 `Suspending engine frontend` 와 `Suspended engine frontend` 의 시각 차 | 수십 초 이상이면 저장소가 느린 것이다 |
| 짝 없는 멈춤 | `Suspending` 뒤에 `Resumed` 가 없는 볼륨 | 그 볼륨의 dm 이 멈춘 채 남았을 수 있다 |
| 멈춤 직후의 재시작 | `Suspending` 시각과 인스턴스 매니저 재시작 시각 | 겹치면 앞 문서 U4 의 경로다 |
| 굳은 dm 위의 프로세스 | `fuser -vm /dev/mapper/<pvc>` 와 D 상태 프로세스 | 쓰는 프로세스가 있으면 W1, 없고 `umount` 만 있으면 U4 |
| 스냅샷·백업 시각 | RecurringJob 일정과 사고 시각 | 스냅샷은 두 버전 모두 멈춤 창이 길다 |

조치:

- **굳은 볼륨은 `dmsetup resume` 으로 푼다.** 절차는 앞 문서 5.2절이다. 타깃이 살아 있는 경우(W1)는 데이터 손실 없이 풀렸다.
- **1.12.2 로 올린다.** 재구축 쪽 멈춤 창이 96초에서 4초로 줄었다. 스냅샷 쪽은 줄지 않으므로 쓰기가 많은 시간대의 스냅샷·백업 작업은 계속 피한다.
- **`Suspended` 가 1분 넘게 이어지는 dm 을 감시한다.** 랩에서 정상 동작 중 `Suspended` 는 최장 11.5초였다. `dmsetup info -c --noheadings -o name,suspended` 를 주기적으로 봐서 연속 두 번 `Suspended` 면 알린다.
- **저장소가 왜 느려지는지 본다.** ESXi 의 CPU Ready, 데이터스토어 지연. 랩은 CPU 를 조여 느리게 만들었다.

## 5. 내부 LLM 에 줄 지시문

```
랩(Longhorn 1.12.1 과 1.12.2, 커널 6.8, arm64) 시험 결과다. 각 1번씩이다. 실서버에 명령을 실행하지 말고, 사람이 실행할 명령과 판정 기준만 제시하라.

확인된 것
1. spdk_tgt 가 죽지 않아도 굳는다. 타깃이 멀쩡한 볼륨의 dm 을 Suspended 로 두면 Longhorn 은 3분 동안 attached healthy 로만 보고 풀지 않는다. 그 상태에서 파드를 지우면 옛 파드는 KillContainer DeadlineExceeded, 새 파드는 FailedAttachVolume "Waiting for detach" 로 15분(1.12.1), 7분(1.12.2) 동안 그대로였다. dmsetup resume 뒤 36초에 정상이 됐고 XFS 는 꺼지지 않았다.
2. 저장소가 느릴 때(CPU 3% 제한) Longhorn 이 스스로 거는 dm 멈춤의 길이: 재구축은 1.12.1 에서 96초, 1.12.2 에서 4초. 스냅샷은 1.12.1 에서 104초(성공), 1.12.2 에서 31초마다 시간 초과하며 dmsetup 프로세스가 D 상태로 5개까지 쌓였다. 두 버전 모두 끝난 뒤 dm 은 Active 였다.
3. Longhorn 자체 동작만으로 dm 이 Suspended 로 남은 것은 1번이고 시험 방법에 문제가 있었다. 근거로 쓰지 마라.

해 줄 것
A. 사고 시각 전후의 V2 instance-manager 로그에서 "Suspending engine frontend", "Suspended engine frontend", "Resuming", "Resumed", "Suspending before the snapshot operation", "proceeding without suspension" 을 뽑아 볼륨별 시간표를 만들어라. Suspending 과 Suspended 의 시각 차, Resumed 가 없는 Suspending 을 표시하라.
B. 그 시간표에 instance-manager 재시작 시각, RecurringJob(스냅샷·백업) 시각, 레플리카 재구축 시각을 겹쳐라.
C. 지금 Suspended 인 dm 마다: 밑장치 nvme 가 살아 있는지, fuser -vm 으로 쥔 프로세스가 무엇인지, 그 볼륨의 Longhorn currentNodeID 가 그 노드인지를 표로 만들어라. 쓰는 프로세스가 있으면 1번의 경우다.
D. ESXi CPU Ready 와 데이터스토어 지연을 사고 시각에 맞춰 요청하라. 멈춤이 수십 초 이상 걸린 시각과 맞는지 본다.
```

## 6. 한계

- 모든 시험은 1번씩이다. W2, W3 은 1.12.2 에서만 했다.
- dm 을 멈춘 채 남기는 실제 경로는 확인하지 못했다. W1 은 손으로 멈췄다.
- G3 의 "멈춤이 다른 노드로 번진다"는 시험하지 않았다. 재구축 한 번의 멈춤 시간만 쟀다.
- 느린 저장소는 CPU 를 조여 만들었다. 디스크나 네트워크가 느린 경우와 같다는 보장이 없다.
- 랩 커널은 6.8(arm64), 실서버는 6.12(RHEL 10.2, x86_64)다.
- 앞 문서 U4 계열 시험에서 `u4` 파드는 권한 문제로 실제로는 쓰지 못하고 있었다(이번에 고침). 그 시험의 `umount` 매달림은 쓰기 부하 없이 난 것이다.
