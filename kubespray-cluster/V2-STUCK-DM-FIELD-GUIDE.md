# 굳은 볼륨 장치(dm) 현장 대응: 확인에서 resume 까지

Longhorn V2 볼륨을 쓰는 파드가 `Terminating`·`ContainerCreating`·`Init` 에서 멈췄을 때, **노드를 재부팅하지 않고** 푸는 순서다. 명령은 손으로 칠 수 있게 짧게 줄였다.

- 네임스페이스는 실서버 값 `longhorn` 이다. 랩은 `longhorn-system`.
- `lhv`, `lhim` 은 Longhorn 이 등록해 둔 약칭이다(`volumes.longhorn.io`, `instancemanagers.longhorn.io`).
- 노드에서 치는 명령은 root 로 친다.
- `[랩 확인]` 은 랩에서 실제로 해 본 것, `[미확인]` 은 해 보지 않은 것이다. 랩은 맥 한 대 위의 VM 이고 커널·아키텍처가 실서버와 다르다. 순서와 "되는가"만 가져간다.

## 한 장 요약

```
파드가 멈춤
  │
  ├─ 1. 어느 파드, 어느 노드인가            kubectl get po -A -o wide | grep -Ev 'Running|Completed'
  ├─ 2. 그 노드에 들어가 멈춘 dm 이 있나     dmsetup info -c -o name,suspended,open | grep Susp
  │        10초 뒤 한 번 더. 두 번 다 나오면 굳은 것
  ├─ 3. 증거 남기기 (1분)                   4절
  ├─ 4. 풀기                                dmsetup resume <이름>
  ├─ 5. 풀렸나                              2번 명령이 아무것도 안 내면 풀린 것
  ├─ 6. 남은 dm 정리                        open 이 0 이고 볼륨이 다른 노드에 있으면 dmsetup remove
  └─ 7. 볼륨·DB 가 돌아왔나                 kubectl -n longhorn get lhv
```

## 1. 증상 확인: 어느 파드, 어느 노드

```bash
kubectl get po -A -o wide | grep -Ev 'Running|Completed'
```

볼 것: `Terminating`, `ContainerCreating`, `Init:0/1` 로 몇 분째 있는 파드와 그 `NODE` 열.

```bash
kubectl describe po <파드> -n <ns> | tail -15
```

아래 문구 중 하나가 있으면 이 문서의 대상이다.

| 이벤트 문구 | 뜻 | 봐야 할 노드 |
|---|---|---|
| `FailedAttachVolume … Waiting for detach` 또는 `already exclusively attached` | 볼륨이 **이전 노드**에서 안 떼어지고 있다 | 그 볼륨이 전에 붙어 있던 노드 |
| `KillPodSandbox … DeadlineExceeded`, `KillContainer … DeadlineExceeded` | 파드를 내리는 중에 멈췄다 | 그 파드의 노드 |
| `FailedMount … timed out` | 붙이는 중에 멈췄다 | 그 파드의 노드 |

이전 노드가 어디인지 모르면 볼륨 쪽에서 본다.

```bash
kubectl -n longhorn get lhv
```

볼 것: `STATE`(attached/detached), `ROBUSTNESS`(healthy/degraded/faulted), `NODE`(지금 붙어 있다고 Longhorn 이 아는 노드). **Longhorn 화면과 이 출력은 정상으로 보일 수 있다.** 굳은 것은 노드의 커널 쪽이라 여기 안 나타난다.

어느 노드인지 끝내 모르면 워커 전부에서 2절 첫 명령을 친다. 한 줄이라 오래 걸리지 않는다.

## 2. 노드에서 확인: 세 가지

### 2-1. 멈춘 dm 이 있는가

```bash
dmsetup info -c -o name,suspended,open | grep Susp
```

출력 예:

```
pvc-bd247636-ae79-43ca-a1e5-aa051d6f1a06 Suspended    1
```

| 열 | 뜻 |
|---|---|
| 첫째 | 볼륨 이름. `kubectl -n longhorn get lhv` 의 이름과 같다 |
| `Suspended` | 장치가 멈춰 있다. 이 장치로 가는 읽기·쓰기는 전부 기다린다 |
| 마지막 숫자(open) | 이 장치를 열고 있는 곳의 수. 1 이상이면 아직 마운트돼 있거나 쓰는 프로세스가 있다 |

**10초 뒤에 같은 명령을 한 번 더 친다.** Longhorn 은 스냅샷·복제본 재구축 때 dm 을 잠깐 멈췄다 푼다. 정상적인 멈춤은 1초 안에 끝난다 `[랩 확인]`.

| 결과 | 판정 |
|---|---|
| 아무것도 안 나옴 | 이 노드는 아니다. 다른 노드를 보거나 6절로 |
| 첫 번째만 나오고 두 번째는 안 나옴 | 정상적인 멈춤이 지나간 것이다. 굳지 않았다 |
| **두 번 다 같은 이름이 나옴** | **굳었다.** 2-2 로 |

### 2-2. 기다리다 멈춘 프로세스가 있는가

```bash
ps -eo stat,etimes,pid,comm | grep ^D
```

출력 예:

```
D       477   40359 umount
```

| 열 | 뜻 |
|---|---|
| `D` | 디스크 응답을 기다리는 중이고, 신호(kill)가 듣지 않는 상태 |
| 둘째 | 그 프로세스가 뜬 지 몇 초인가. 수십 초를 넘으면 정상이 아니다 |
| 넷째 | 무엇인가. `umount`, `dmsetup`, `postgres`, `xfs…`, `kworker` 가 흔하다 |

`D` 인 `umount` 가 있으면 파드를 내리는 쪽이 멈춘 장치에 걸려 있는 것이다. 이 프로세스는 죽일 수 없다. dm 을 풀어야 끝난다.

### 2-3. 커널이 남긴 기록

```bash
dmesg -T | grep 'blocked for' | tail -3
```

`task umount:40359 blocked for more than 122 seconds` 같은 줄이 있으면 2-2 와 같은 이야기다. 시각을 적어 둔다(4절).

### 2-4. 이 노드의 저장소 프로세스가 살아 있는가

```bash
pgrep -a spdk_tgt
```

- 나오면 살아 있다.
- 안 나오면 죽었거나 인스턴스 매니저가 다시 뜨는 중이다.

**어느 쪽이든 다음 순서는 같다.** 풀고 나서 볼 것이 달라질 뿐이다(5절).

## 3. 풀기 전에: 기다려도 되는 경우

| 상황 | 할 일 |
|---|---|
| 파드가 **그 노드에 그대로** 있고(다른 노드로 안 옮겨 감), 멈춘 지 2분이 안 됐다 | 2분까지 기다린다. `[랩 확인]` 이 경우는 새 인스턴스 매니저가 다시 이어 주어 1분쯤에 저절로 풀렸다 |
| 파드가 다른 노드로 옮겨 갔거나, 2분이 지났다 | 기다려도 안 풀린다. 4절로. `[랩 확인]` 6분 넘게 그대로였고 손으로 풀어야 했다 |

파드가 옮겨 갔는지는 1절의 `kubectl get po -o wide` 에서 같은 이름의 새 파드가 다른 노드에 `Pending`/`ContainerCreating` 으로 있는지로 안다.

## 4. 증거 남기기 (1분)

풀고 나면 흔적이 사라진다. 원인을 가르려면 풀기 **전**의 상태가 필요하다. 노드에서:

```bash
date
dmsetup info -c > /tmp/dm.txt
ps -eo stat,etimes,pid,comm | grep ^D > /tmp/d.txt
dmesg -T | tail -300 > /tmp/dmesg.txt
```

시험 PC 에서(그 노드의 V2 인스턴스 매니저 이름을 먼저 찾는다):

```bash
kubectl -n longhorn get lhim | grep v2
kubectl -n longhorn logs <이름> --previous > im-prev.log
kubectl -n longhorn logs <이름> > im-now.log
```

`--previous` 는 재시작 전 컨테이너의 로그다. 재시작한 적이 없으면 오류가 나는데 무시한다.

같이 적어 둘 것: 이 일이 시작된 시각, 그 무렵 이 VM 이나 다른 워커 VM 에 vMotion·스냅샷·백업이 있었는지(인프라 담당에게 시각을 받는다). 나중에 `im-prev.log` 의 `Suspending engine frontend` 시각, `dmesg.txt` 의 `nvme` 줄 시각과 나란히 놓고 본다.

## 5. 풀기

이름을 손으로 치기 길면 변수에 담는다.

```bash
D=$(dmsetup info -c --noheadings -o name,suspended | grep Susp | cut -d: -f1)
echo $D
```

`echo` 로 나온 이름이 2-1 에서 본 것과 같은지 확인하고:

```bash
for d in $D; do dmsetup resume $d; done
```

하나만 풀려면 `dmsetup resume <이름>` 이다.

- `resume` 은 멈춤만 푼다. 장치도 데이터도 지우지 않는다.
- 풀면 기다리던 읽기·쓰기가 한꺼번에 진행된다. 저장소 프로세스가 죽어 있었다면 그 요청들은 오류로 끝난다. 그 볼륨은 이미 다른 노드에서 쓰려고 떼는 중이었으므로, 오류로 끝나야 떼기가 진행된다.
- `[랩 확인]` 굳은 채 6분 둔 뒤 `resume` 했을 때 PostgreSQL 데이터 점검(잔액 합계 일치, `amcheck`)이 통과했다. 한 번 한 시험이다.

## 6. 풀렸는지 확인

노드에서 2절의 명령을 다시 친다.

```bash
dmsetup info -c -o name,suspended,open | grep Susp
ps -eo stat,etimes,pid,comm | grep ^D
```

| 결과 | 판정 |
|---|---|
| 둘 다 아무것도 안 나옴 | 풀렸다. 7절로 |
| `Susp` 는 없는데 `D` 가 남음 | 30초 기다렸다 다시 본다. 쌓인 요청이 끝나는 데 시간이 걸릴 수 있다. 그래도 남으면 9절 |
| `Susp` 가 다시 나옴 | Longhorn 이 다시 멈춘 것일 수 있다(재구축 중). 10초 간격으로 두 번 더 본다. 계속 같은 이름이면 9절 |

시험 PC 에서:

```bash
kubectl get po -A -o wide | grep -Ev 'Running|Completed'
```

`[랩 확인]` `resume` 뒤 30초 안에 멈췄던 파드가 `Running` 이 됐고, 그 노드의 인스턴스 매니저도 그제서야 돌아왔다.

## 7. 남은 dm 정리

파드가 다른 노드로 옮겨 간 경우, 이전 노드에 쓰이지 않는 dm 이 남을 수 있다 `[랩 확인: 1.12.1]`.

```bash
dmsetup info -c -o name,suspended,open | grep pvc
```

각 줄에 대해 아래 **두 가지가 모두** 맞을 때만 지운다.

| 확인 | 방법 | 지워도 되는 값 |
|---|---|---|
| 아무도 열고 있지 않다 | 위 출력의 마지막 열 | `0` |
| 볼륨이 이 노드에 붙어 있지 않다 | `kubectl -n longhorn get lhv <이름>` 의 `NODE` | 다른 노드이거나 비어 있음 |

```bash
dmsetup remove <이름>
```

- `Device or resource busy` 가 나오면 아직 누가 쓰고 있는 것이다. 지우지 않는다. `--force` 는 쓰지 않는다.
- 하나라도 확신이 없으면 그대로 둔다. 남은 dm 은 그 볼륨이 이 노드로 다시 올 때 문제가 될 수 있지만 급한 것은 아니다.

## 8. 그 뒤에 볼 것

```bash
kubectl -n longhorn get lhv
```

- `degraded` 는 복제본을 다시 채우는 중이다. 기다리면 `healthy` 가 된다. **`healthy` 가 되기 전에 다른 노드를 건드리지 않는다.** `[랩 확인]` 아직 `degraded` 일 때 한 번 더 저장소가 끊긴 경우가 중단이 가장 길었다.
- `faulted` 는 이 문서의 범위가 아니다.

PostgreSQL(CNPG)을 쓰면:

```bash
kubectl get cluster -A
```

- `READY` 가 인스턴스 수와 같아야 한다.
- 인스턴스 하나가 `0/1 Running` 에서 안 올라오면 [V2-PROD-RUNBOOK.md](V2-PROD-RUNBOOK.md) 5절(`pg_rewind` 실패)을 본다. 저장소가 끊기며 primary 에서 밀려난 인스턴스에서 생긴다.

## 9. 안 풀릴 때

| 상황 | 할 일 |
|---|---|
| `dmsetup resume` 이 끝나지 않고 멈춤 | `[미확인]` 랩에서는 본 적 없다. 다른 터미널에서 `ps -eo stat,etimes,pid,comm \| grep ^D` 로 `dmsetup` 이 `D` 인지 본다. 그 노드의 V2 인스턴스 매니저 상태(`kubectl -n longhorn get lhim`)를 기록하고, 이때는 재부팅을 검토한다 |
| `resume` 은 됐는데 `D` 프로세스가 2분 넘게 남음 | `dmesg -T \| tail -30` 에서 `nvme` 줄을 본다. `Reconnecting`/`failed to connect` 가 계속 나오면 저장소 프로세스가 안 돌아온 것이다. `pgrep -a spdk_tgt` 와 인스턴스 매니저 파드 상태를 본다 |
| 같은 이름이 계속 `Suspended` 로 돌아옴 | Longhorn 이 멈추고 못 푸는 일이 반복되는 것이다. 인스턴스 매니저 로그에서 `timeout executing` 을 찾는다. `kubectl -n longhorn logs <이름> \| grep -c 'timeout executing'` |
| 여러 노드가 동시에 이렇다 | 한 노드씩 푼다. 전부 한꺼번에 재부팅하지 않는다 |

인스턴스 매니저 파드를 지우는 것으로는 이미 굳은 dm 이 풀리지 않는다 `[랩 확인]`.

## 10. 재부팅과의 비교

| | `dmsetup resume` | 노드 재부팅 |
|---|---|---|
| 걸리는 시간 | 명령 한 줄. 랩에서 30초 안에 파드 복귀 | 노드 기동 + 그 노드의 모든 볼륨 재구축 |
| 영향 범위 | 그 볼륨 하나 | 그 노드의 모든 파드, 그 노드에 복제본을 둔 모든 볼륨이 `degraded` |
| 부작용 | 없음(멈춤만 푼다) | 디스크가 `/dev/sdX` 로 등록돼 있으면 이름이 바뀌어 수동으로 고쳐야 한다. 재구축이 도는 동안 다른 노드가 흔들리면 다시 굳는 조건이 된다 |

재부팅 뒤 디스크가 안 잡히는 문제는 디스크 경로를 `/dev/disk/by-id/…` 또는 `/dev/disk/by-path/…` 로 바꾸면 없어진다. 볼륨이 붙은 채로 바꿀 수 있다. [V2-PROD-RUNBOOK.md](V2-PROD-RUNBOOK.md) 6절.

## 11. 근거

| 내용 | 랩 시험 | 기록 |
|---|---|---|
| dm 이 멈춘 채 저장소 프로세스가 죽고 파드가 옮겨 가면 이전 노드에 `Suspended` dm 과 `D` 상태 `umount` 가 남는다 | U4 | `v2test/results/u/U4.log` |
| 파드가 그 노드에 남으면 60초쯤에 저절로 풀리고, 옮겨 가면 `resume` 전까지 6분 넘게 굳는다 (1.12.1, 1.12.2 같음) | X1, X1b | `v2test/results/x/X1*.log` |
| `resume` 뒤 30초 안에 복귀, 데이터 점검 통과 | A5 | `v2test/results/x/X1b-load-1122.log` |
| 풀고 난 뒤 이전 노드에 `Active open=0` dm 이 남는다 | U4, U5 | `v2test/results/u/` |

각 시험은 1회다. 실서버에서 dm 이 어떤 경로로 멈춘 채 남는지는 확인하지 못했다. 이 문서는 "그 상태가 됐을 때 푸는 방법"이고, 재발을 막는 방법이 아니다.
