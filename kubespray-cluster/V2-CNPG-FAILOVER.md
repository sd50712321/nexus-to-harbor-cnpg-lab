# V2 볼륨 위의 CNPG: 노드가 죽었을 때 승격·쓰기 중단·재부착

노드가 갑자기 죽었을 때 세 가지를 쟀다. 쓰기가 얼마나 끊기는지, 새 primary 가 뜨려면 파드를 죽여 줘야 하는지, 죽은 노드의 인스턴스가 다시 붙는 데 왜 오래 걸리는지.

> **근거 수준.** 2026-11-16 랩 실측이다. 워커 3대(5GB, 2 vCPU), Longhorn 1.13.0 V2 엔진, CNPG operator 1.30.1, PostgreSQL 16. 각 시험은 1번씩만 했다(switchover 만 3번). 실서버는 노드 수·디스크·네트워크가 달라 숫자가 그대로 나오지 않는다. 기록 원문은 `v2test/results/`, 시험에 쓴 파일과 재현 순서는 [v2test/](v2test/README.md).

## 1. 결론

- **쓰기 중단 0 은 안 된다.** PostgreSQL 은 쓰기를 받는 인스턴스(primary)가 하나다. 그 노드가 죽으면 판정 → 승격 → `-rw` 서비스 전환이 끝날 때까지 쓰기를 받을 곳이 없다. 줄일 수는 있다.
- **승격에 파드 삭제는 필요 없다.** 아무것도 건드리지 않아도 operator 가 승격시킨다. 단, **operator 가 살아 있어야 한다.**
- **operator 가 죽은 노드에 같이 있으면 쓰기가 6분 넘게 끊긴다.** operator 를 2개로 늘려 다른 노드에 두면 1분 안팎으로 줄어든다.
- **읽기(`-ro`)는 standby 가 살아 있는 한 끊기지 않는다.**
- **죽은 노드의 인스턴스는 다른 노드로 옮겨 가지 않는다.** 파드가 `Terminating` 에 걸려 볼륨이 풀리지 않는다. 노드가 돌아오거나, 죽은 노드에 `out-of-service` taint 를 달아야 풀린다.

## 2. 쓰기 중단 실측

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

## 3. 죽은 노드의 인스턴스가 다시 붙기까지

### 3.1 노드가 돌아오는 경우

노드 Ready 뒤 인스턴스가 다시 Ready 가 되기까지 80~169초였다(7번, 80초는 인스턴스 2개·3벌 볼륨인 C2). 디스크 상태까지 기록한 4번(A3·B1·B2·C1)을 나누면, V2 디스크가 `Ready` 가 되기까지 81~98초(V2 instance-manager 가 뜨고 디스크를 다시 읽는다), 그 뒤 볼륨 attach 와 PostgreSQL 기동·복제 재개까지 27~71초였다(71초는 파드가 `Terminating` 을 한 번 오간 B2).

디스크를 `/dev/sdX` 로 등록했고 이름이 밀렸다면 여기서 영영 안 돌아온다([LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md)).

### 3.2 노드가 안 돌아오는 경우 (시험 B2, B3)

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
# 그 노드의 전원이 확실히 꺼져 있을 때만. 살아 있는데 달면 같은 볼륨을 두 곳에서 쓰게 된다
kubectl taint node <죽은 노드> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# 노드를 다시 살린 뒤에는 반드시 뗀다
kubectl taint node <노드> node.kubernetes.io/out-of-service-
```

- 스토리지가 1벌(strict-local)이면 볼륨이 그 노드에만 있으므로 taint 를 달아도 옮겨 갈 수 없다. 이때는 노드가 돌아오기를 기다리거나, 그 인스턴스의 PVC 를 지워 CNPG 가 다른 노드에 새로 복제하게 한다(랩 `scripts/61-db-move-instance.sh`, V1 에서 실측).
- 노드 복귀 뒤 3벌 볼륨은 약 2분 뒤 `degraded` → `healthy` 로 돌아왔다(2GB 볼륨, 복제본 재구축).

## 4. 줄이는 방법

효과가 큰 순서다.

### 4.1 operator 를 2개로, 서로 다른 노드에 (6분대 → 1분 안팎)

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

### 4.2 계획된 작업은 먼저 switchover (4~6초)

노드 재부팅·패치 전에 primary 를 다른 인스턴스로 넘긴다.

```bash
kubectl cnpg promote <클러스터> <새 primary 인스턴스> -n <네임스페이스>     # kubectl-cnpg 플러그인
```

랩에서는 플러그인 없이 같은 동작을 하는 status 패치로 쟀다(`v2test/results/S1.log`). 실서버에서는 플러그인 명령을 쓴다.

### 4.3 노드 죽음 판정 시간 줄이기 (86초 → 34초)

kube-controller-manager 의 `--node-monitor-grace-period`(기본 40초)를 20초로 줄였을 때다. Kubespray 변수는 `kube_controller_node_monitor_grace_period` (`kubespray/roles/kubernetes/control-plane/defaults/main/main.yml:104`).

- 대가: 20초 넘는 네트워크 끊김·노드 멈춤에도 NotReady 가 되고 승격이 일어난다. 클러스터 전체에 적용되는 값이다.
- 랩에서는 control plane 3대의 매니페스트를 직접 고쳐 쟀고 시험 뒤 40초로 되돌렸다. 인벤토리에는 넣지 않았다.

### 4.4 그 밖에

- **동기 복제는 켜 둔다**(`postgresql.synchronous`). 중단 시간은 못 줄이지만 승격 뒤에도 커밋된 쓰기가 남는다.
- **애플리케이션은 `-rw` 서비스 이름으로만 붙고 재접속하게 한다.** 승격이 끝나면 같은 이름이 새 primary 를 가리킨다. Harbor 는 재접속한다.
- **V2 디스크는 `by-id` 로 등록한다.** 아니면 3.1 의 재부착이 끝나지 않는다.

## 5. 못 본 것

- 각 시험 반복(1번씩만 쟀다), 부하가 걸린 상태에서의 승격 시간.
- 300초 축출 대기(`tolerationSeconds`)를 줄였을 때. operator 가 1개여도 이 값이 줄면 C1 의 6분이 줄어들 것으로 보이지만 재지 않았다.
- 네트워크만 끊긴 경우(노드는 살아 있고 통신만 안 됨). 옛 primary 가 계속 쓰기를 받는지는 다른 문제다.
- 실서버 하이퍼바이저·디스크에서의 V2 디스크 Ready 시간.
