# V2 볼륨 미부착 후속: 굳은 dm 재현과 해제, 1.12.1 대 1.12.2 비교

[V2-SPDK-CRASH-ANALYSIS.md](V2-SPDK-CRASH-ANALYSIS.md) 다음 문서다. 실서버 쪽 분석(내부 LLM)이 내놓은 주장과 질문을 랩에서 시험한 결과만 담았다. 시험일은 2026-11-18 이고 모든 시험은 1번씩 했다.

읽는 순서: 1절(결론) → 2절(주장별 판정) → 4절(질문에 대한 답) → 6절(내부 LLM 에 줄 지시문). 3절은 시험 기록, 5절은 실서버에서 쓸 절차다.

## 1. 결론

- **실서버의 굳은 상태를 랩에서 만들었다.** 조건은 세 가지가 겹치는 것이다. dm 이 `Suspended` 인 순간에, 그 노드의 `spdk_tgt` 가 죽고, 그 볼륨이 다른 노드로 옮겨 간다. 그러면 옛 노드에 `Suspended` + open 1 인 dm 과 D 상태 `umount` 가 남고, 8분 넘게 그대로였다(시험은 8분에서 끊었다).
- **`dmsetup resume` 한 번으로 풀린다.** `dmsetup remove` 는 `Device or resource busy` 로 거절된다. `resume` 뒤 3초 안에 `umount` 가 D 에서 나오고 open 이 0 이 되며, 그다음 `remove` 가 된다. 재기동은 필요 없었다.
- **1.12.2 로 올려도 이 상태는 똑같이 생긴다.** 같은 시험을 1.12.2 에서 하니 같은 시간(8분) 동안 매달렸고 같은 방법으로 풀렸다. 1.12.2 는 `spdk_tgt` 가 죽는 원인을 줄일 뿐, 죽은 뒤 남는 dm 을 치우지는 않는다.
- **Longhorn 이 살아서 그 볼륨을 계속 쥐고 있으면 스스로 푼다.** 타깃이 응답만 없는 경우와 볼륨이 그 노드에 남는 경우는 약 2분 안에 dm 을 풀거나 지웠다.
- **CPU 격리는 `Cpus_allowed_list` 로 확인할 수 없다.** 1.12.1 의 격리는 IRQ·워크큐·RPS 를 SPDK 코어에서 빼는 것이다. 확인할 값은 5.3절에 있다.

## 2. 주장별 판정

| 실서버 쪽 주장 | 판정 | 근거 |
|---|---|---|
| `Suspended` dm 은 재기동 없이 `dmsetup resume` 으로 풀린다 | 맞음 | U4b, U4-1122 |
| `remove` 는 open 이 0 이 아니면 BUSY 다 | 맞음 | U4, U4b, U4-1122 |
| `resume` 이 유일한 배수구다 | 고칠 것 | U4 에서 `dmsetup remove --force` 한 번으로도 풀렸다. `umount` 가 D 에서 나오고 dm 이 사라졌다 |
| `resume` 하면 매달린 I/O 가 오류로 끝나고 XFS 가 꺼진다 | 맞음 | `XFS log I/O error -5`, `Filesystem has been shut down` (U4, U4b, U4-1122) |
| dm 이 얼려면 노드에서 볼륨을 떼는 동작이 있어야 한다 | 맞음, 조건 추가 | 볼륨이 남으면 Longhorn 이 푼다(U3b). Longhorn 이 직접 떼도 지운다(U3c). `spdk_tgt` 가 죽으면서 볼륨이 떠날 때만 굳었다(U4) |
| 격리를 켰는데 `Cpus_allowed_list` 에 반영되지 않는다 | 확인 방법이 틀림 | 그 값은 원래 안 바뀐다(U1). 5.3절의 세 값을 봐야 한다 |
| 릴리스 노트에 커널 층을 고치는 항목이 없다 | 맞음 | v1.12.2 릴리스 노트 본문에서 `dmsetup`, `orphan`, `blkid`, `hung`, `srcu` 를 찾아도 없다 |
| `ata1: lost interrupt` 는 노드 정지의 근거가 못 된다 | 받아들임 | CD-ROM 이면 무관하다. 앞 문서의 "노드가 같이 멎는다"는 갈래는 이 항목에 기대고 있었으므로 증거 부족으로 내린다 |
| `__synchronize_srcu` 에 선 스레드가 `resume` 으로 풀리는지 | 모름 | 랩에서 그 상태를 만들지 못했다 |

앞 문서에서 고칠 것:

- **1.12.2 에 관련 수정이 두 개 더 있다.** 앞 문서 4.2절 표에 없던 것이다.
  - #14373(원 이슈 #14327): 멎은 NVMe 장치 하나 때문에 무관한 V2 볼륨까지 검증에 실패해 다시 만들어진다. 이슈 본문은 커널 6.8 미만에서 재현했다고 적었다. 실서버는 6.12 라 그대로 해당하는지는 모른다.
  - #13764(원 이슈 #13761): `nvme list` 프로세스가 타임아웃 뒤에도 죽지 않고 쌓인다. 1.12.0/1.12.1 은 시간 초과한 자식 프로세스를 죽이지 않는다고 적혀 있다.
- **고아 dm 판정 기준이 틀렸다.** 앞 문서는 "`slaves=[nvme0n1]` 인데 `nvme0` 컨트롤러가 없다"를 고아의 표지로 썼다. 정상 볼륨에서도 컨트롤러는 `nvme1`, 장치는 `nvme0n2` 로 나왔다(U3a 사후). 장치 이름 앞 번호는 서브시스템 번호라 컨트롤러 번호와 다를 수 있다. 5.1절의 기준을 쓴다.

## 3. 시험 기록

환경: 랩 워커 3대(arm64, Ubuntu 24.04, 커널 6.8.0-86, vCPU 2). StorageClass 와 CNPG 3 인스턴스는 실서버 값과 같다(`v2test/sc-prodlike.yaml`, `v2test/pg-prod.yaml`). CPU 격리는 켰다. 실서버(RHEL 10.2, 커널 6.12, x86_64, ESXi)와 커널·아키텍처가 다르다.

| 시험 | 버전 | 한 일 | 결과 |
|---|---|---|---|
| U1 | 1.12.1 | `data-engine-cpu-isolation-enabled` 를 `{"v2":"true"}` 로 | 인스턴스 매니저 파드가 다시 떴고 인자에 `--enable-irq-affinity --enable-workqueue-affinity --enable-rps` 가 붙었다. 바뀐 값은 5.3절 |
| U3a | 1.12.1 | 타깃은 살린 채 엔진 프런트엔드 NVMe-TCP 포트만 DROP | 75초 뒤 컨트롤러 삭제, XFS 꺼짐. Longhorn 은 새 포트로 다시 붙이고 `attached healthy`. 파드는 `CreateContainerError` 로 남음. 파드를 지우니 20초에 회복 |
| U3b | 1.12.1 | dm 을 suspend 하고 포트 DROP | 약 2분 뒤 Longhorn 이 새 타깃으로 바꾸고 dm 을 풀었다. XFS 는 꺼지지 않았다 |
| U3c | 1.12.1 | U3b + 노드 cordon + 파드 삭제 | 약 2분 뒤 Longhorn 이 dm 을 지웠다. 남은 것 없음 |
| U4 | 1.12.1 | dm suspend 직후 `spdk_tgt` SIGKILL, 노드 cordon, 파드 삭제 | 옛 노드에 `Suspended` open 1, `umount` D 496초. `hung_task` 경고. 볼륨은 다른 노드에서 정상. `remove` BUSY, `remove --force` 로 풀림 |
| U4b | 1.12.1 | U4 를 다른 노드에서 반복, `resume` 만 사용 | `umount` D 177초에서 `remove` BUSY → `resume` → 3초 안에 D 없음, open 0 → `remove` 성공 |
| U4-1122 | 1.12.2 | U4b 와 같은 방법 | `umount` D 477초. `remove` BUSY → `resume` → 3초 안에 풀림 → `remove` 성공 |
| U5 | 1.12.1 | V2 인스턴스 매니저 3개 동시 삭제 ×3 | 매번 transport 1개, `spdk_tgt` 사망 없음. 회복 102, 102, 214초. 끝난 뒤 고아 0 |
| U5 | 1.12.2 | 같음 | 매번 transport 1개, 사망 없음. 회복 154, 184, 215초. 끝난 뒤 고아 0 |
| U6 | 1.12.1 | PV 패턴별 attach/detach ×3 | Delete 16~17초, Retain 15~17초, 정적 11~12초. 고아 0, D 0 |
| U6 | 1.12.2 | 같음 | Delete 16~17초, Retain 15~18초, 정적 9~10초와 138초 한 번. 고아 0, D 0 |

보충:

- **U3a 의 커널 로그는 죽음·멎음과 다르다.** 포트가 조용히 막히면 `failed to connect socket: -110` 이 약 5초 간격으로 15번 나온 뒤 `Removing controller` 다. 죽은 타깃은 `-111`, 멎은 타깃은 `failed to receive icresp` 였다(앞 문서 5절 2-1).
- **U3a 의 끝 상태는 Longhorn 만 보면 정상이다.** 볼륨은 `attached healthy` 인데 파드는 꺼진 XFS 마운트를 쥐고 있다. 원 이슈 #14327 이 적은 "볼륨이 detach 되지 않아 워크로드가 계속 I/O 오류를 받는다, 우회는 파드 삭제"와 같은 모습이다.
- **U4 에서 볼륨은 약 1분 뒤 새 노드에 붙었다.** 옛 노드의 굳은 dm 이 새 attach 를 막지는 않았다. 즉 같은 볼륨의 dm 이 두 노드에 동시에 있었다.
- **U4 뒤 `blkid -p` 는 랩에서 매달리지 않았다.** 10초 제한을 걸고 불렀는데 바로 돌아왔다. 실서버에서 D 로 쌓인 `blkid` 는 재현하지 못했다.
- **U5 는 동시성이 낮다.** 볼륨 4개, 노드 3대다. #14400 이 실서버에서 나지 않는다는 근거로 쓰지 않는다.
- **U6 의 138초는 정적 PV 를 곧바로 다시 붙일 때 났다.** 이벤트는 `volume … is not ready for workloads: waiting for the volume to fully detach` 였다. 1.12.1 의 세 번에서는 나지 않았다. 한 번뿐이라 버전 차이로 보지 않는다.
- **고아 dm(Active, open 0)은 두 버전 모두에서 남았다.** `spdk_tgt` 가 죽고 볼륨이 다른 노드로 간 경우다(U4 의 옆 볼륨, U4-1122 뒤 조사). I/O 를 쥔 프로세스가 없어 매달림은 없었다.

기록은 `v2test/results/u/`, 스크립트는 `v2test/u*.sh` 와 `v2test/dm-audit.sh` 다.

## 4. 질문에 대한 답

### 4.1 인스턴스 매니저 다섯이 같은 시각에 재생성된 것이 동시 attach(#14400)를 유발했을 수 있나

조건은 맞는다. 원 이슈 #14399 의 재현 조건이 "인스턴스 매니저가 막 떠서 transport 가 아직 없을 때, 여러 인스턴스가 동시에 bdev 를 노출한다"이다. 인스턴스 매니저가 재생성되면 그 노드의 엔진·레플리카가 한꺼번에 다시 뜬다.

랩에서는 나지 않았다(U5, 두 버전 3번씩). 볼륨이 4개뿐이라 반증은 못 된다.

실서버에서 가르는 방법: 그 시각의 V2 인스턴스 매니저 로그(`--previous` 포함)에서 `iobuf` 와 `transport` 를 찾고, 살아 있는 노드에서 아래를 본다. 2 이상이면 이 버그다.

```
kubectl -n longhorn-system exec <V2 instance-manager 파드> -- go-spdk-helper nvmf transport-get | grep -c trtype
```

다섯이 동시에 재생성된 원인은 따로 찾아야 한다. #14400 은 재생성 뒤에 생기는 일이다.

### 4.2 1.12.2 로 올리면 커널 층 멈춤이 줄어드나

생기는 횟수는 줄 수 있고, 생긴 뒤의 모습은 그대로다.

- 굳는 조건의 한 축이 `spdk_tgt` 의 죽음이다. 1.12.2 는 죽는 원인 여러 개를 고쳤으므로 그만큼 기회가 준다(추정, 재지 않았다).
- 조건이 갖춰지면 1.12.2 에서도 똑같이 굳는다(U4-1122).
- `__synchronize_srcu` 대기는 랩에서 만들지 못해 답할 수 없다.

### 4.3 Retain 정책과 PVC 재생성이 고아 dm 을 만드는 주 경로인가

랩에서는 아니었다. Retain + 같은 이름 PVC 재생성으로 `Released` PV 가 같은 claimRef 로 3개 쌓였지만 고아 dm 은 0개였다(U6, 두 버전).

같은 claimRef 이름의 PV 가 둘씩 보이는 것은 Retain 에서 PVC 를 지우고 다시 만들면 생기는 정상 모습이다. 고아 dm 은 "정상적인 detach 가 끝나지 못한 경우"에만 남았다. 실서버에서 Retain 볼륨이 고아를 더 가진다면, PV 패턴보다 그 볼륨들이 겪은 `spdk_tgt` 사망 횟수를 먼저 본다.

### 4.4 정적 PV 와 동적 PV 의 위험도가 다른가

랩에서 차이는 하나였다. 정적 PV 는 같은 Longhorn 볼륨을 곧바로 다시 붙이므로, 앞선 detach 가 덜 끝났으면 기다린다(U6 1.12.2 의 138초). 동적 PV 는 매번 새 볼륨이라 이 경합이 없다. 고아 dm 은 둘 다 0개였다.

정적 PV 는 볼륨이 지워지지 않으므로, 한 번 굳은 dm 이 생기면 같은 이름으로 계속 남는다. 동적 Delete 는 볼륨이 지워져도 옛 노드의 dm 은 남는다(U4 에서 확인한 것은 Delete 정책 볼륨이다). 그래서 남는 것 자체는 정책과 무관하다.

### 4.5 A 에서 1.12.2 를 먼저 검증하는 설계, 재현이 안 되면 어떻게 판정하나

`numberOfReplicas` 와 `dataLocality` 를 바꿔 가며 attach/detach 만 반복해서는 재현되지 않을 가능성이 높다. 랩에서 정상 attach/detach 는 18번 모두 깨끗했다(U6). 굳으려면 `spdk_tgt` 가 죽어야 한다.

저절로 나기를 기다리지 말고 고장을 넣는다. 판정을 두 층으로 나눈다.

| 층 | 묻는 것 | 넣는 것 | 1.12.1 과 1.12.2 에서 비교할 값 |
|---|---|---|---|
| 죽음 | `spdk_tgt` 가 스스로 죽는가 | 부하만 준다: 쓰기 부하 중 스냅샷 생성·삭제, 레플리카 재구축(레플리카 삭제), 볼륨 여러 개 동시 attach | V2 인스턴스 매니저 재시작 횟수, 로그의 `Assertion` 줄 수, transport 개수 |
| 뒤처리 | 죽은 뒤 무엇이 남는가 | `v2test/u4-orphan.sh` 와 같은 순서: dm suspend → `spdk_tgt` kill → 파드를 다른 노드로 | 옛 노드의 `Suspended` dm 수, D 상태 프로세스 수와 지속 시간 |

- 죽음 층은 1.12.2 에서 줄어야 한다. 줄지 않으면 원인이 고쳐진 버그들 밖에 있다.
- 뒤처리 층은 1.12.2 에서 줄지 않는다(랩 결과). 그래서 올린 뒤에도 5.2절의 해제 절차와 5.1절의 정기 조사가 필요하다.
- 죽음 층이 1.12.1 에서도 재현되지 않으면 1.12.2 의 효과는 판정할 수 없다. 그때는 "올린 뒤 N주 동안 V2 인스턴스 매니저 재시작 0회"를 기준으로 삼는다.

1.12.1 → 1.12.2 는 V2 볼륨을 전부 뗀 뒤에 올렸다(랩). V2 볼륨이 붙은 채 올리는 것은 이 랩에서 해 보지 않았다. 릴리스 노트는 1.12.2 → 1.13.0 라이브 업그레이드가 지원되지 않고, 1.13.1 이상으로는 지원된다고 적고 있다. 1.13.1 은 2026-11-18 현재 나오지 않았다.

Helm 으로 올릴 때 `--reuse-values` 를 쓰면 차트 버전만 바뀌고 이미지가 1.12.1 로 남는다(랩에서 겪음). 값 파일을 다시 주거나 `--reset-then-reuse-values` 를 쓴다. 올린 뒤 `longhorn-manager` 와 `instance-manager` 파드의 이미지 태그를 확인한다.

## 5. 실서버에서 쓸 절차

실서버 작업은 사람이 결정하고 실행한다. 아래는 랩에서 통한 순서다.

### 5.1 굳은 dm 과 고아 dm 찾기 (읽기만)

노드마다 실행한다.

```
dmsetup info -c --noheadings -o name,suspended,open | grep '^pvc-'
ps -eo pid,ppid,stat,etimes,comm,args | awk '$3 ~ /^D/'
```

그 노드에 붙어 있는 볼륨 목록과 비교한다.

```
kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.currentNodeID}{"\n"}{end}'
```

| dm 상태 | open | 볼륨의 현재 노드 | 뜻 | 할 일 |
|---|---|---|---|---|
| Active | 1 이상 | 이 노드 | 정상 | 없음 |
| Suspended | 1 이상 | 이 노드 | Longhorn 이 작업 중이거나 풀지 못함 | 몇 분 지켜본다. 그대로면 5.2 |
| Suspended | 1 이상 | 다른 노드 또는 없음 | 굳은 고아. D 상태 프로세스가 붙어 있다 | 5.2 |
| Active 또는 Suspended | 0 | 다른 노드 또는 없음 | 고아. 매달린 것은 없다 | `dmsetup remove` (Suspended 면 `resume` 먼저) |

랩에서는 이 조사를 `v2test/dm-audit.sh` 로 했다.

### 5.2 굳은 dm 풀기

먼저 그 dm 위에 살아 있는 파일시스템이 없는지 본다. `resume` 은 매달린 I/O 를 오류로 끝내므로, 쓰는 중인 워크로드가 있으면 그 파일시스템이 꺼진다.

```
findmnt -S /dev/mapper/<pvc 이름>          # 마운트가 남아 있는지
fuser -vm /dev/mapper/<pvc 이름>           # 쥐고 있는 프로세스
kubectl -n longhorn-system get volumes.longhorn.io <pvc 이름> -o jsonpath='{.status.currentNodeID}'
```

볼륨의 현재 노드가 이 노드가 아닐 때만 진행한다. 이 노드에 붙어 있는 볼륨이면 파드를 먼저 내리거나 Longhorn 이 스스로 풀기를 기다린다.

```
dmsetup resume <pvc 이름>
dmsetup info -c --noheadings -o name,suspended,open <pvc 이름>     # Active, open 0 이 될 때까지
dmsetup remove <pvc 이름>
```

랩에서 `resume` 뒤 3초 안에 open 이 0 이 됐다. `dmsetup remove --force` 한 번으로도 풀렸지만(U4, 1번), 실서버 쪽이 이미 확인한 `resume` → `remove` 순서를 쓴다.

`__synchronize_srcu` 나 `nvme_delete_ctrl_sync` 에 선 프로세스는 이 방법으로 풀리는지 모른다. 풀기 전후로 그 프로세스의 `/proc/<pid>/stack` 을 남긴다.

### 5.3 CPU 격리가 실제로 걸렸는지

`Cpus_allowed_list` 는 보지 않는다. 1.12.1 의 격리는 다른 프로세스를 SPDK 코어에서 내쫓지 않는다(`types/setting.go` 의 설명: IRQ, unbound 워크큐, RPS 를 옮긴다).

| 볼 것 | 명령 | 랩에서 켜기 전 → 켠 뒤 (SPDK 코어 0, 노드 CPU 2개) |
|---|---|---|
| 파드 인자 | `kubectl -n longhorn-system get pod <V2 instance-manager> -o jsonpath='{.spec.containers[0].args}'` | 없음 → `--enable-irq-affinity --enable-workqueue-affinity --enable-rps` |
| 워크큐 | `cat /sys/devices/virtual/workqueue/cpumask` | `3` → `2` |
| IRQ 기본값 | `cat /proc/irq/default_smp_affinity` | `3` → `2` |
| IRQ 분포 | `cat /proc/irq/*/smp_affinity_list \| sort \| uniq -c` | `0-1` 61개 → `1` 49개, `0-1` 12개 |
| RPS | `cat /sys/class/net/<NIC>/queues/rx-*/rps_cpus` | `0` → `2` |

설정을 바꾸면 Longhorn 은 볼륨이 전부 떨어진 인스턴스 매니저만 다시 띄운다(설정 설명). 볼륨이 붙어 있는 노드는 설정값만 `true` 이고 파드 인자에는 없을 수 있다. 파드 인자가 판정 기준이다.

## 6. 내부 LLM 에 줄 지시문

아래를 그대로 붙여 넣는다.

```
랩(Longhorn 1.12.1 과 1.12.2, 커널 6.8, arm64)에서 시험한 결과다. 각 1번씩이고 실서버와 커널이 다르다. 실서버에 명령을 실행하지 말고, 사람이 실행할 명령과 판정 기준만 제시하라.

확인된 것
1. 굳는 조건: dm 이 Suspended 인 순간 + 그 노드의 spdk_tgt 사망 + 볼륨이 다른 노드로 이동. 옛 노드에 Suspended/open 1 dm 과 D 상태 umount 가 8분 넘게 남았다.
2. 해제: dmsetup remove 는 BUSY. dmsetup resume 뒤 3초 안에 open 0, 그다음 remove 성공. 재기동 불필요. "resume 이 유일한 배수구"는 틀리다. remove --force 로도 풀렸다(1번).
3. 1.12.2 에서 같은 시험을 하면 같은 시간 매달리고 같은 방법으로 풀린다. 1.12.2 는 죽음을 줄일 뿐 남은 dm 을 치우지 않는다.
4. Longhorn 이 그 볼륨을 계속 쥐고 있으면(타깃 무응답, 볼륨이 노드에 남음) 약 2분 안에 스스로 dm 을 풀거나 지운다.
5. CPU 격리는 Cpus_allowed_list 로 확인할 수 없다. V2 instance-manager 파드 인자의 --enable-irq-affinity/--enable-workqueue-affinity/--enable-rps, /sys/devices/virtual/workqueue/cpumask, /proc/irq/*/smp_affinity_list, rps_cpus 를 봐야 한다. 볼륨이 붙은 노드는 설정만 true 이고 적용이 안 됐을 수 있다.
6. "slaves=[nvme0n1] 인데 nvme0 컨트롤러가 없다"는 고아의 근거가 아니다. 정상 볼륨도 컨트롤러 nvme1, 장치 nvme0n2 였다. 고아 판정은 "그 dm 의 볼륨이 Longhorn 상 이 노드에 붙어 있는가"로 한다.
7. Retain + 같은 이름 PVC 재생성, 정적 PV 반복 attach/detach 는 고아 dm 을 만들지 않았다(두 버전, 각 3번).
8. V2 instance-manager 3개 동시 삭제를 3번씩 해도 transport 는 1개였고 spdk_tgt 는 죽지 않았다. 볼륨이 4개뿐이라 #14400 의 반증은 아니다.
9. 1.12.2 에는 앞서 빠뜨린 관련 수정이 있다: #14373(멎은 NVMe 장치가 무관한 볼륨의 프런트엔드 검증을 실패시킴), #13764(nvme list 프로세스 누적).

모르는 것
- __synchronize_srcu, nvme_delete_ctrl_sync 에 선 프로세스가 resume 으로 풀리는지.
- 실서버에서 spdk_tgt 가 실제로 죽은 원인(Assertion 줄).
- blkid 가 D 로 쌓이는 것(랩에서는 바로 돌아왔다).

해 줄 것
A. 두 클러스터의 워커 전부에 대해 dm 전수표를 만들어라: 노드, dm 이름, Suspended/Active, open, 그 볼륨의 Longhorn currentNodeID, D 상태 프로세스. 문서 5.1절 표로 분류하라.
B. "Suspended + open 1 이상 + 볼륨이 다른 노드"인 dm 마다, 그 볼륨이 노드를 떠난 시각과 그 노드 V2 instance-manager 의 재시작 시각을 맞춰 보라. 1번의 조건과 맞는지 확인하는 것이다.
C. V2 instance-manager 의 이전 컨테이너 로그에서 Assertion, iobuf, transport 줄을 찾아라. 살아 있는 노드에서 go-spdk-helper nvmf transport-get 의 trtype 개수를 세어라(2 이상이면 #14400).
D. resume 으로 풀 때마다 전후의 /proc/<pid>/stack 을 남겨라. 특히 __synchronize_srcu 에 선 것이 풀리는지 기록하라.
E. 1.12.2 검증은 두 층으로 판정하라: (죽음) 부하 중 V2 instance-manager 재시작 횟수와 Assertion 줄, (뒤처리) dm suspend → spdk_tgt kill → 파드 이동 뒤 남는 Suspended dm 과 D 프로세스. 뒤처리 층은 1.12.2 에서도 남는 것이 예상 결과다.
F. Helm 으로 올릴 때 --reuse-values 를 쓰지 마라. 차트만 바뀌고 이미지가 1.12.1 로 남는다. 올린 뒤 이미지 태그를 확인하라.
```

## 7. 모르는 것과 한계

- 모든 시험은 1번씩이다. 시간 값은 그 한 번의 값이다.
- 랩 커널은 6.8(Ubuntu, arm64), 실서버는 6.12(RHEL 10.2, x86_64)다. dm·NVMe 커널 경로가 같다는 보장이 없다.
- `__synchronize_srcu`, `nvme_delete_ctrl_sync` 대기, D 로 쌓이는 `blkid`, `Fabrics Cmd timeout`, `name conflict`, `BaseBdevs:[]` 는 여전히 재현하지 못했다.
- 랩의 dm suspend 는 손으로 넣었다(`dmsetup suspend --noflush --nolockfs`). 실서버에서 Longhorn 의 어떤 동작이 suspend 를 걸었는지는 보지 않았다. 후보는 스냅샷, 레플리카 재구축, 볼륨 확장이다(#14417, #14045).
- 실서버에서 `spdk_tgt` 가 죽은 원인은 아직 모른다.
- 어드민 클러스터(V1 을 쓰지 않는 쪽)의 구성은 랩에서 따로 만들지 않았다. 랩은 V1 인스턴스 매니저가 떠 있다.
