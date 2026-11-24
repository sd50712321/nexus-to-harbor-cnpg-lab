# 테스트 클러스터에서 확인할 것: Nexus → Harbor 이관 전 시험 목록과 명령

CI/CD 이미지와 헬름 차트를 Nexus 에서 Harbor 로 옮기기 전에, 운영과 비슷하게 구성된 테스트 클러스터에서 확인할 항목이다. "Harbor 가 얼마나 빠른가"가 아니라 **"우리 사용 패턴에서 막히는 순간이 있는가"** 를 본다.

모든 시험은 기성 도구(`iperf3`, `fio`, `skopeo`, `helm`, `crictl`)와 `kubectl` 명령만 쓴다. 직접 만든 스크립트는 없다.

> **근거 수준.** 2026-11-24 작성. 명령은 랩에서 같은 도구로 돌려 본 것(`fio` 옵션, `pg_test_fsync`, CNPG 전환, 1초 간격 탐침)과 각 도구의 표준 사용법을 조합했다. **이 문서의 순서 그대로 테스트 클러스터에서 돌려 본 것은 아니다.** YAML 은 문법만 확인했다. 랩의 기존 시험([PERF-TEST.md](PERF-TEST.md))은 50MB 이미지·노드 2~3대 조건이라 여기 항목의 절반만 다뤘고, 노드 동시 pull·DB 급사·GC·네트워크·다른 클러스터 경로는 처음 하는 시험이다.

## 0. 시작 전에

### 정할 숫자 세 개

| 숫자 | 모르면 | 쓰는 곳 |
|---|---|---|
| 가장 큰 이미지 크기 | 지금 Nexus 에서 가장 큰 이미지를 그대로 쓴다 | H1, H3 |
| CI 가 동시에 push 하는 최대 개수 | 4 | H2 |
| 한 번에 pull 하는 노드 수 | 워커 전체 | H3, M2 |

### 채울 값

아래 명령의 `<...>` 는 환경 값이다.

| 표기 | 뜻 |
|---|---|
| `<harbor>` | Harbor 접속 주소 (모든 클라이언트가 쓰는 그 주소 하나) |
| `<nexus>` | 현재 Nexus docker 저장소 주소 |
| `<proj>` | 시험용 Harbor 프로젝트 (미리 만든다) |
| `<big>` | 가장 큰 이미지의 `저장소:태그` |
| `<harbor-ns>`, `<pg-ns>`, `<pg-cluster>` | Harbor 네임스페이스, CNPG 클러스터의 네임스페이스와 이름 |
| `<sc-registry>`, `<sc-db>` | 레지스트리 저장소와 DB 볼륨이 쓰는 StorageClass |
| `<iperf3 이미지>`, `<fio 이미지>` | 내부 저장소에 올려 둔 도구 이미지 |

### 준비

- `iperf3`, `fio` 가 든 이미지를 내부 저장소에 올린다. 폐쇄망이라 시험 때 받을 수 없다.
- 시험 PC(또는 CI 러너)에 `skopeo`, `helm` 이 있어야 한다. 비밀번호는 명령에 적지 않고 먼저 로그인해 둔다.
  ```bash
  skopeo login <harbor>
  skopeo login <nexus>
  helm registry login <harbor>
  ```
- F2·F3 은 테스트 Harbor 를 실제로 멈춘다. 다른 사람이 쓰지 않는 시간에 한다. **운영 클러스터와 운영 Harbor 에는 어떤 시험도 돌리지 않는다.**
- 각 시험은 3번 돌려 편차를 본다.

### 우선순위

시간이 부족하면 1순위만 한다.

| 순위 | 시험 | 이유 |
|---|---|---|
| 1 | H1, H3, F2, F3 | 이관 뒤 바로 체감되는 것: 큰 이미지 push, 롤아웃 때 동시 pull, DB·워커 장애 때 중단 시간 |
| 2 | N1, D1, D2 | 1순위 결과가 나쁠 때 원인을 가르는 기준값 |
| 3 | H2, H4, F1, F4, N2, N3, M1, M2 | 조건이 해당될 때 |

진행 순서는 N → D → H → F → M 이다. 앞 단계 수치가 뒤 단계의 해석 기준이 된다.

## 1. 네트워크

Longhorn 복제와 PostgreSQL 동기 복제는 쓰기마다 다른 노드의 응답을 기다린다. 노드 간 지연이 쓰기 속도의 상한이다.

### N1. 노드 간 대역폭

서버 파드를 워커 A 에, 클라이언트 파드를 워커 B 에 띄운다. `hostNetwork: true` 는 노드 경로를, 없으면 파드 경로(Cilium 을 거침)를 잰다. 두 가지를 다 잰다.

```yaml
apiVersion: v1
kind: Pod
metadata: {name: iperf-s, namespace: default}
spec:
  nodeName: <워커 A>
  hostNetwork: true        # 파드 경로를 잴 때는 이 줄을 지운다
  containers:
  - name: s
    image: <iperf3 이미지>
    command: ["iperf3", "-s"]
---
apiVersion: v1
kind: Pod
metadata: {name: iperf-c, namespace: default}
spec:
  nodeName: <워커 B>
  hostNetwork: true        # 파드 경로를 잴 때는 이 줄을 지운다
  containers:
  - name: c
    image: <iperf3 이미지>
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f iperf.yaml
S=$(kubectl get pod iperf-s -o jsonpath='{.status.podIP}')
kubectl exec iperf-c -- iperf3 -c $S -t 30          # 연결 1개
kubectl exec iperf-c -- iperf3 -c $S -t 30 -P 4     # 연결 4개
kubectl delete -f iperf.yaml
```

볼 것: 마지막 `receiver` 줄의 Gbit/s. NIC 속도에 가까운지, 파드 경로가 노드 경로보다 얼마나 낮은지, `Retr`(재전송) 수가 큰지.

### N2. 노드 간 지연

```bash
ping -c 100 <다른 노드 IP>      # 노드에서
```

볼 것: 마지막 줄의 `avg` 와 `max`. `max` 가 `avg` 의 몇 배로 튀는지.

### N3. MTU

```bash
ping -M do -s 1472 -c 3 <다른 노드 IP>      # 노드에서. 1472 + 헤더 28 = 1500
```

- 통과하면 경로 MTU 가 1500 이상이다. `message too long` 이나 응답 없음이면 숫자를 줄여 가며 통과하는 최대 크기를 찾는다.
- 같은 명령을 파드 안에서 다른 노드의 파드 IP 로 한 번 더 한다. Cilium 이 터널을 쓰면 통과 크기가 그만큼 작게 나온다.

볼 것: 노드 경로와 파드 경로의 최대 크기. 파드 쪽이 예상보다 훨씬 작거나, 큰 크기에서만 응답이 없으면 경로 어딘가의 MTU 가 맞지 않는 것이다.

## 2. 디스크

Harbor 는 성격이 다른 디스크 두 개를 쓴다. 각각 한 가지만 잰다. 실제로 Harbor 가 쓰는 StorageClass 로 새 볼륨을 만들어 잰다.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: fio-vol, namespace: default}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: <sc-registry>      # D2 에서는 <sc-db>
  resources: {requests: {storage: 10Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: fio, namespace: default}
spec:
  containers:
  - name: fio
    image: <fio 이미지>
    command: ["sleep", "7200"]
    volumeMounts: [{name: vol, mountPath: /vol}]
  volumes: [{name: vol, persistentVolumeClaim: {claimName: fio-vol}}]
```

### D1. 레지스트리 저장소: 큰 파일 연속 쓰기·읽기

```bash
kubectl apply -f fio.yaml
kubectl exec fio -- fio --name=w --filename=/vol/t --size=4G --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=16 --runtime=60 --time_based
kubectl exec fio -- fio --name=r --filename=/vol/t --size=4G --rw=read  --bs=1M --direct=1 --ioengine=libaio --iodepth=16 --runtime=60 --time_based
```

볼 것: `WRITE: bw=` 와 `READ: bw=` 의 MB/s. 이 값이 N1 의 대역폭(1Gbit/s ≈ 119MB/s)보다 낮으면 디스크가 push·pull 속도의 상한이다.

### D2. DB 볼륨: 작은 쓰기를 하나씩 확정하는 속도

`storageClassName` 을 `<sc-db>` 로 바꿔 볼륨을 다시 만든 뒤:

```bash
kubectl exec fio -- fio --name=f --filename=/vol/t --size=1G --rw=write --bs=8k --ioengine=sync --fdatasync=1 --runtime=60 --time_based
kubectl delete -f fio.yaml
```

볼 것: `write: IOPS=` 와, `fsync/fdatasync/sync_file_range` 아래의 `99.00th` 값. 평균보다 99번째 값이 크게 튀면 DB 쓰기가 가끔 멈춘다는 뜻이다.

같은 것을 PostgreSQL 도구로 실제 DB 볼륨에서 재려면:

```bash
P=$(kubectl -n <pg-ns> get cluster <pg-cluster> -o jsonpath='{.status.currentPrimary}')
kubectl -n <pg-ns> exec $P -c postgres -- pg_test_fsync -s 2 -f /var/lib/postgresql/data/pgdata/fsync.tmp
```

볼 것: `fdatasync` 줄의 초당 횟수.

## 3. Harbor 평상시

### H1. 가장 큰 이미지 push

실제 CI 러너가 있는 위치에서 한다. 러너와 Harbor 사이 경로가 결과에 들어가야 하기 때문이다.

```bash
time skopeo copy docker://<nexus>/<big> docker://<harbor>/<proj>/<big>
```

볼 것: `real` 시간이 CI 타임아웃 안인지. 이미지 크기 ÷ 시간(MB/s)을 D1·N1 과 견준다.

### H2. 동시 push

실제 파이프라인을 동시 개수만큼 한꺼번에 실행하는 것이 가장 정확하다. 파이프라인을 쓸 수 없으면 터미널을 그 개수만큼 열어 H1 명령을 태그만 다르게 동시에 실행한다.

볼 것: 전부 성공하는지, 하나당 시간이 H1 보다 얼마나 늘어나는지.

### H3. 노드 동시 pull

큰 이미지를 쓰는 DaemonSet 을 배포하면 모든 워커가 동시에 받는다.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: pulltest, namespace: default}
spec:
  selector: {matchLabels: {app: pulltest}}
  template:
    metadata: {labels: {app: pulltest}}
    spec:
      terminationGracePeriodSeconds: 1
      imagePullSecrets: [{name: <harbor 인증 시크릿>}]      # 공개 프로젝트면 이 줄을 지운다
      containers:
      - name: c
        image: <harbor>/<proj>/<big>
        imagePullPolicy: Always
        command: ["sleep", "3600"]
```

```bash
kubectl apply -f pulltest.yaml
time kubectl rollout status ds/pulltest --timeout=30m
kubectl get events --field-selector reason=Pulled --sort-by=.lastTimestamp \
  -o custom-columns=NODE:.source.host,MSG:.message | grep pulltest -i
```

볼 것: `rollout status` 가 끝나는 시간(전체), 이벤트의 `Successfully pulled image ... in 12.3s` (노드별). 노드 한 대만 받았을 때(아래 "다시 할 때" 참고)와 견줘 동시일 때 얼마나 늘어나는지.

다시 할 때: 노드에 이미지가 남아 있으면 받지 않는다. 시험마다 지운다.

```bash
kubectl delete ds pulltest
crictl rmi <harbor>/<proj>/<big>      # 각 워커에서
```

한 대만 받는 기준값은 DaemonSet 의 `spec.template.spec` 에 `nodeName: <워커 하나>` 를 넣어 잰다.

### H4. 헬름 차트

```bash
helm pull <기존 Nexus 헬름 저장소>/<차트> --version <버전>       # 원본 받기
helm push <차트>-<버전>.tgz oci://<harbor>/<proj>
helm pull oci://<harbor>/<proj>/<차트> --version <버전> -d /tmp/h
sha256sum <차트>-<버전>.tgz /tmp/h/<차트>-<버전>.tgz             # 두 값이 같아야 한다
helm install t oci://<harbor>/<proj>/<차트> --version <버전> -n default --dry-run
```

볼 것: 받은 파일이 원본과 같은지, CD 가 쓰는 방식(`oci://`)으로 설치가 되는지. 속도는 볼 필요 없다.

## 4. Harbor 장애 시

Harbor 는 DB 가 없으면 pull 도 실패한다(랩에서 401 로 확인). 그래서 DB 와 Harbor 파드의 장애가 곧 레지스트리 장애다. 여기서 재는 것은 **실패하는 구간이 몇 초인가, 저절로 돌아오는가** 다.

### 탐침: 터미널 하나에 띄워 둔다

```bash
read -s -p "Harbor 계정:비밀번호 " HC; echo
while true; do
  echo "$(date +%T) $(curl -sk -m 3 -o /dev/null -w '%{http_code} %{time_total}' -u "$HC" "https://<harbor>/api/v2.0/projects?page_size=1")"
  sleep 1
done | tee probe-$(date +%H%M).txt
```

`200` 이 아닌 줄이 실패 구간이다. 첫 실패와 마지막 실패의 시각 차이가 중단 시간이다. 더 실제에 가깝게 보려면 탐침과 함께 H3 의 DaemonSet 을 다시 배포해 놓고, 도는 중에 아래 동작을 한다.

### F1. DB 계획 전환

```bash
kubectl -n <pg-ns> get cluster <pg-cluster> -o jsonpath='{.status.currentPrimary}{"\n"}'
kubectl -n <pg-ns> get pods -l cnpg.io/cluster=<pg-cluster>,role=replica
kubectl cnpg promote <pg-cluster> <replica 파드 이름> -n <pg-ns>
```

`kubectl cnpg` 플러그인이 없으면 설치한 뒤 한다. 랩에서는 플러그인 없이 같은 동작의 status 패치를 썼는데(`perf/harbor-switchover.sh` 14번째 줄), 손으로 치기에는 길다.

볼 것: 탐침의 실패 구간(초). 랩에서는 CNPG `smartShutdownTimeout` 기본값(180초)이면 전환이 3분 늦어졌다. 값을 확인한다.

### F2. DB primary 가 갑자기 죽음

```bash
P=$(kubectl -n <pg-ns> get cluster <pg-cluster> -o jsonpath='{.status.currentPrimary}')
date +%T; kubectl -n <pg-ns> delete pod $P --force --grace-period=0
kubectl -n <pg-ns> get cluster <pg-cluster> -w        # 새 primary 가 정해질 때까지 본다
```

볼 것: 탐침의 실패 구간, F1 보다 얼마나 긴지, 죽은 인스턴스가 standby 로 저절로 돌아오는지(`kubectl -n <pg-ns> get pods`). 저절로 안 돌아오는 두 경우와 조치는 [V2-PROD-RUNBOOK.md](V2-PROD-RUNBOOK.md) 5절에 있다.

### F3. Harbor 파드가 있는 워커가 빠짐

```bash
kubectl -n <harbor-ns> get pods -o wide          # core, registry, jobservice 가 어느 워커에 있나
date +%T; kubectl drain <그 워커> --ignore-daemonsets --delete-emptydir-data
kubectl -n <harbor-ns> get pods -o wide -w
kubectl uncordon <그 워커>                        # 끝나면 되돌린다
```

볼 것: 탐침의 실패 구간, 파드가 다른 워커에서 뜨는 시간. core·registry 가 한 워커에 몰려 있으면 전체가 멈춘다. 랩에서는 Harbor 차트 기본값에 분산 규칙이 없어 워커 1대 정지로 최대 10분 멈췄다.

`drain` 은 계획된 경우다. 갑자기 죽는 경우는 그 워커 VM 의 전원을 끄는 것인데, Longhorn 볼륨이 다른 노드로 넘어가는 시간까지 더해지므로 `drain` 결과보다 길게 나온다. 가능하면 둘 다 한다.

### F4. 정리 작업(GC) 중 push

Harbor UI 의 Administration → Clean Up → Garbage Collection 에서 지금 실행을 누르고, 도는 동안 H1 을 반복한다.

볼 것: push 가 실패하거나 멈추는지, GC 가 끝나는 시간. GC 가 지울 것이 있어야 의미가 있으므로, 먼저 시험 이미지 여러 개를 올리고 태그를 지운 뒤 한다.

## 5. 다른 클러스터에서

매시로 묶인 다른 클러스터의 노드도 이 Harbor 에서 받는 경우다.

### M1. 다른 클러스터 노드의 pull

```bash
time crictl pull <harbor>/<proj>/<big>       # 다른 클러스터의 노드에서
```

볼 것: 인증서 오류(`x509`) 없이 되는지, 시간이 H3 의 노드별 시간과 얼마나 다른지. 크게 느리면 클러스터 사이 구간이 좁은 것이다. 그 노드와 Harbor 진입점 사이로 N1·N3 을 한 번 더 잰다.

### M2. 전 클러스터 동시 pull

각 클러스터에 H3 의 DaemonSet 을 같은 시각에 배포한다.

볼 것: H3 보다 얼마나 늘어나는지, Harbor 의 registry 파드가 재시작되거나 탐침이 실패하는지.

## 6. 비어 있을 때와 이관이 끝났을 때: 두 번 재야 하는 것

전부를 두 번 잴 필요는 없다. 저장된 양에 따라 결과가 달라지는 것만 이관 전(비어 있을 때)과 시험 이관 뒤(전체가 들어갔을 때)에 한 번씩 잰다.

| 시험 | 두 번 재나 | 이유 |
|---|---|---|
| N1~N3 네트워크 | 아니다 | 저장된 양과 무관하다 |
| D1 레지스트리 저장소 | **그렇다** | 새 볼륨은 처음 쓰는 영역을 할당하면서 쓰기 때문에, 한 번 채워진 뒤와 속도가 다를 수 있다. 랩의 fio 가 측정 전에 볼륨을 먼저 채운 것도 이 때문이다. 이관 뒤에는 실제 레지스트리 볼륨의 남은 공간에 대고 잰다 |
| D2 DB 볼륨 | 아니다 | Harbor 의 DB 는 이관 뒤에도 작다 |
| H1 push, H3 동시 pull | 한 번 더 확인만 | 이미지는 파일 하나씩 따로 저장돼서 양이 늘어도 속도는 거의 같아야 한다. 달라지면 그 자체가 이상 신호다 |
| F1, F2 DB 장애 | 아니다 | DB 크기가 작아 차이가 없다 |
| F3 워커가 빠짐 | **그렇다** | 볼륨이 다른 노드로 넘어간 뒤 복제본을 다시 채우는 시간이 데이터 양에 따라 늘어난다. 그동안은 복제본이 하나 부족한 상태다 |
| F4 GC | **그렇다** | GC 시간은 저장된 이미지 수에 따라 늘어난다. 비어 있을 때의 결과는 의미가 없다 |

이관 뒤에만 잴 수 있는 것:

| 볼 것 | 방법 |
|---|---|
| 실제로 차지한 용량 | `kubectl -n <harbor-ns> exec <registry 파드> -- df -h /storage`. Nexus 에서 차지하던 양과 견준다. 볼륨 크기의 80% 를 넘으면 볼륨을 키우고 시작한다 |
| 복제본 하나를 다시 채우는 시간 | Longhorn UI 에서 레지스트리 볼륨의 복제본 하나를 지우고 `healthy` 로 돌아올 때까지 시간을 잰다. 이 시간이 "노드 한 대가 죽은 뒤 다시 안전해지기까지"의 시간이다 |
| 백업·스냅샷에 걸리는 시간 | 쓰는 백업 방식으로 레지스트리 볼륨과 DB 를 한 번 받아 본다 |
| 하루에 늘어나는 양 | 며칠 간격으로 위 `df` 를 다시 본다. 볼륨이 차는 날짜를 계산한다 |

- 복제본을 다시 채우는 시간이 데이터 양에 비례하는지는 랩에서 큰 데이터로 재 보지 않았다. 여기서 처음 확인하는 값이다.
- 레지스트리 저장 경로(`/storage`)는 Harbor 차트 기본값이다. 다르면 `kubectl -n <harbor-ns> describe pod <registry 파드>` 의 마운트 경로를 쓴다.
- 순서는 "비어 있을 때 1~5절 → 테스트 클러스터에 전체 시험 이관 → 위 표의 항목만 다시" 다.

## 7. 결과 기록

시험마다 한 줄씩 적는다. 조건을 같이 적지 않은 숫자는 나중에 쓸 수 없다.

| 시험 | 날짜·시각 | 조건 (이미지 크기, 동시 수, 노드 수, StorageClass) | 1회 | 2회 | 3회 | 메모 |
|---|---|---|---|---|---|---|
| N1 노드 경로 | | | | | | |
| N1 파드 경로 | | | | | | |
| D1 쓰기 / 읽기 | | | | | | |
| D2 IOPS / p99 | | | | | | |
| H1 | | | | | | |
| H3 전체 / 노드별 최대 | | | | | | |
| F1 실패 구간(초) | | | | | | |
| F2 실패 구간(초) | | | | | | |
| F3 실패 구간(초) | | | | | | |

## 8. 합격 기준

기준값은 운영 쪽에서 정한다. 이 문서는 비워 둔다.

| 시험 | 기준이 되는 것 |
|---|---|
| H1 | CI 의 push 단계 타임아웃 |
| H3, M2 | 허용하는 롤아웃 시간. kubelet 의 이미지 pull 제한 시간 안인지 |
| F1, F2, F3 | 허용하는 레지스트리 중단 시간. 그 사이 재시작되는 파드는 이미지를 못 받아 뜨지 못한다 |
| D2 | 기준값보다 편차. p99 가 평균의 수십 배면 원인을 먼저 찾는다 |

## 9. 여기서 다루지 않는 것

- Longhorn V2 자체의 장애(굳은 dm, 인스턴스 매니저 재시작, 버전 올리기): [V2-PROD-RUNBOOK.md](V2-PROD-RUNBOOK.md)
- PostgreSQL 자체의 처리량(pgbench): [PERF-TEST.md](PERF-TEST.md). Harbor 가 DB 에 거는 부하는 가벼워서 이관 판정에는 필요 없다.
- 이관 절차(이미지·차트를 옮기는 방법, 컷오버): 리포 루트의 [README.md](../README.md)
- Harbor core·registry 파드를 여러 개로 늘린 구성. 레지스트리 저장소가 여러 파드에서 동시에 붙을 수 있어야 하는데(공유 볼륨 또는 S3 호환 저장소), 랩에서 해 보지 못했다. 테스트 클러스터가 그 구성이면 F3 결과가 랩과 크게 다를 것이다.
