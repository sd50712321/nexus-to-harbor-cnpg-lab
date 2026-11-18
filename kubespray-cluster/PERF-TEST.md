# 성능 시험: CNPG 와 Harbor 위주 (무엇을, 어떤 도구로, 어떻게)

CNPG(PostgreSQL)와 Harbor 의 성능을 재는 시험 목록, 도구, 실행 방법, 랩에서 돌려 본 결과다. 스토리지(Longhorn)는 비교 기준으로 한 번만 쟀다.

> **근거 수준.** 2026-11-18 랩 실측이다. 워커 2 vCPU(V2 엔진이 그중 1개를 계속 쓴다), 메모리 5GB(쓸 수 있는 것은 약 2GB), 노트북 한 대의 로컬 디스크. Longhorn 1.13.0, CNPG 1.30.1, PostgreSQL 16, Harbor 2.14.0. **각 시험은 1번씩만 돌렸다(전환 시험만 2번).** 숫자는 "이 방법으로 이런 모양의 결과가 나온다"는 예시이고 실서버 기준값이 아니다. 기록 원문은 `perf/results/`.

## 1. 시험 목록

| # | 무엇을 재나 | 도구 | 스크립트 | 랩에서 |
|---|---|---|---|---|
| C1 | PostgreSQL 쓰기·읽기 처리량과 지연 | `pgbench` | `perf/cnpg-suite.sh` | 실행 |
| C2 | 동기 복제가 커밋에 얹는 시간 | `pgbench` + `synchronous_commit=local` | 같은 스크립트 | 실행 |
| C3 | 접속 수를 늘렸을 때 | `pgbench -c` | 같은 스크립트 | 실행 |
| C4 | 부하 중 복제 지연 | `pg_stat_replication` | 같은 스크립트 | 실행 |
| C5 | 데이터 볼륨의 fsync 속도 | `pg_test_fsync` | 같은 스크립트 | 실행 |
| C6 | 부하 중 계획 전환(switchover)의 쓰기 중단 | `pgbench -P 1` + 전환 | `perf/switchover-load.sh` | 실행 (2번) |
| H1 | 큰 이미지 push·pull 속도 | `skopeo`, `perf/mkimage.py` | `perf/harbor-bench.sh` | 실행 |
| H2 | 동시 push | `skopeo` 여러 개 | 같은 스크립트 | 실행 |
| H3 | 작은 이미지 여러 개 (요청 수가 많은 경우) | `skopeo` | 같은 스크립트 | 실행 |
| H4 | Harbor API 처리량·지연 | `oha` | 같은 스크립트 | 실행 |
| H5 | Harbor 가 DB 에 거는 부하 | `pg_stat_database` 전후 차이 | 같은 스크립트 | 실행 |
| H6 | Harbor 사용 중 DB 전환 때 실패하는 요청 | `oha` + `curl` + 전환 | `perf/harbor-switchover.sh` | 실행 |
| S1 | Longhorn 볼륨 속도 (StorageClass 비교) | `fio` | `perf/fio.yaml`, `perf/fio-all.sh` | 실행 |
| S2 | 볼륨 크기별 첫 마운트 시간 | `kubectl` + 시간 기록 | `perf/attach-time.sh` | **미실행** |

도구는 모두 무료다. `pgbench`·`pg_test_fsync` 는 PostgreSQL 이미지에 들어 있어 따로 받을 것이 없다. `skopeo`·`oha` 는 시험을 거는 쪽 PC 에 설치한다(`oha` 대신 `ab` 도 된다). 폐쇄망에서는 `fio` 가 들어 있는 이미지를 내부 저장소에 올려야 한다.

## 2. 결과 요약 (랩)

### CNPG

| 시험 | pg-v2 (인스턴스 3, 동기 `ANY 1`, V2 1벌 strict-local) | pg-r3 (인스턴스 2, 비동기, V2 3벌) |
|---|---|---|
| 데이터 만들기 (scale 20, 307MB) | 12.4초 | 41.0초 |
| C1 읽기·쓰기, 접속 8 | 754 tps, 평균 10.3ms | 616 tps, 평균 12.7ms |
| C1 읽기 전용, 접속 8 | 7,999 tps, 평균 0.8ms | 6,427 tps, 평균 1.1ms |
| C2 standby 를 안 기다릴 때 | 1,026 tps, 평균 7.4ms | 710 tps, 평균 10.9ms |
| C3 읽기·쓰기, 접속 32 | 804 tps, 평균 38.2ms | 1,008 tps, 평균 30.0ms |
| C4 부하 중 복제 지연 | 두 standby 모두 65kB 뒤 | 1,073kB 뒤, 4ms |
| C5 `pg_test_fsync` (open_datasync) | 4,273 회/초 | 538 회/초 |

읽는 법.

- **동기 복제의 비용(C2).** pg-v2 에서 standby 를 기다리지 않으면 754 → 1,026 tps 였다. 동기 복제가 커밋마다 약 3ms 를 얹은 셈이다. 대신 승격 뒤에도 커밋된 쓰기가 남는다.
- **접속 수(C3).** 8 → 32 로 늘려도 pg-v2 는 754 → 804 tps 로 거의 그대로이고 지연만 10 → 38ms 로 늘었다. 이 노드에서는 접속 8개에서 이미 한계였다는 뜻이다. 접속 수를 늘리는 것으로는 처리량이 늘지 않는다.
- **스토리지 복제 수(C5).** Longhorn 3벌 볼륨의 fsync 는 1벌의 8분의 1이었다. 그런데 TPS 차이는 그만큼 크지 않다(754 대 616). PostgreSQL 은 여러 접속의 커밋을 한 번의 fsync 로 묶기 때문이다. 데이터 적재처럼 한 접속이 계속 쓰는 작업은 차이가 그대로 드러난다(12초 대 41초).
- pg-v2 와 pg-r3 는 인스턴스 수와 동기 설정도 달라서 "스토리지 복제 수만의 차이"로 읽으면 안 된다.

### C6 부하 중 계획 전환

| 회차 | 쓰기 중단 (1초 단위) | 비고 |
|---|---|---|
| 1 | 약 18초 | pgbench 가 재접속할 때 vacuum 을 해서 길게 나옴 |
| 2 | 약 14초 | vacuum 을 뺌(`-n`) |

부하가 없을 때 랩에서 쟀던 값은 4~6초였다([V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md)). 부하가 걸리면 옛 primary 가 열려 있는 접속을 정리하고 내려가는 데 시간이 더 든다. `smartShutdownTimeout` 은 15초였다. 이 값과의 관계는 따로 재지 않았다.

### Harbor

| 시험 | 결과 |
|---|---|
| H1 50MB 이미지 push | 6.5초 (7.7MB/s) |
| H1 50MB 이미지 pull | 2.3초 (21.7MB/s) |
| H2 50MB 이미지 4개 동시 push | 27.7초 (합계 7.2MB/s) |
| H3 1MB 이미지 30개 차례로 push | 39.6초 (이미지당 1.32초) |
| H4 `/api/v2.0/projects` | 135 요청/초, 중앙값 109ms, 99% 497ms |
| H4 `/projects/perf/repositories` | 319 요청/초, 중앙값 49ms, 99% 189ms |
| H4 `/repositories/small/artifacts` | 94 요청/초, 중앙값 200ms, 99% 361ms |

Harbor 가 DB 에 건 부하(H5).

| 작업 | DB 커밋 수 | 행 변경 | 한 건당 |
|---|---|---|---|
| 50MB 이미지 push 1개 | 76 | 26 | |
| 1MB 이미지 push 30개 | 2,419 | 598 | 이미지당 커밋 약 80 |
| 프로젝트 목록 500번 | 12,194 | 1 | 요청당 커밋 약 24 |
| 아티팩트 목록 500번 | 46,941 | 0 | 요청당 커밋 약 94 |

읽는 법.

- **push 는 DB 가 아니라 저장소와 네트워크가 정한다.** 동시에 4개를 올려도 합계 속도가 그대로였다(7.7 → 7.2MB/s). 50MB 를 올리는 동안 DB 는 76번 커밋했을 뿐이다.
- **이미지 크기와 상관없이 push 한 번에 1초 남짓의 고정 비용이 있다**(H3). 작은 이미지가 많은 이관은 용량보다 개수가 시간을 정한다.
- **API 는 요청 하나가 DB 질의 수십 개다.** 아티팩트 목록 한 번에 약 94번 커밋(읽기 질의도 커밋으로 센다)이 나갔다. 목록 화면·스캔·복제 정책처럼 조회가 많은 작업이 DB 를 가장 많이 쓴다.
- **DB 접속은 12개였다**(`max_connections` 200). 이 부하에서는 접속 수가 문제되지 않았다.
- DB 크기는 시험 내내 11MB 였다. Harbor 의 DB 는 작고, 이미지 본체는 registry 볼륨에 있다.

### H6 Harbor 사용 중 DB 전환

| 항목 | 결과 |
|---|---|
| 10 동시 부하 60초 | 200 응답 17,934건, **500 응답 2,677건** |
| 1초 간격 요청 | 54번 중 8번이 500. 전환 1초 뒤부터 **9초 구간** |
| 그 뒤 | 아무것도 안 해도 정상으로 돌아옴 |

Harbor 는 DB 가 바뀌는 동안 요청을 기다리게 하지 않고 바로 500 으로 답한다. 계획 전환은 push·pull 이 없는 시간에 하고, 이관 스크립트에는 재시도를 넣는다.

### S1 Longhorn 볼륨 (참고)

| StorageClass | 4k 랜덤 읽기 | 4k 랜덤 쓰기 | 1M 순차 읽기 | 1M 순차 쓰기 | fsync 8k |
|---|---|---|---|---|---|
| `longhorn-v2-single` (V2, 1벌) | 18.6k IOPS | 12.7k IOPS | 970MiB/s | 747MiB/s | 2,598 IOPS, 0.37ms |
| `longhorn-v2` (V2, 3벌) | 18.6k IOPS | 6,760 IOPS | 283MiB/s | 67MiB/s | 622 IOPS, 1.58ms |
| `longhorn` (V1, 3벌) | 4,620 IOPS | 2,086 IOPS | 50MiB/s | 39MiB/s | 677 IOPS, 1.45ms |

파일 2GB, 항목당 20초. 3벌 볼륨은 쓰기마다 다른 노드로 보내므로 랩의 가상 네트워크가 한계를 정한다. 실서버 네트워크에서는 비율이 달라진다.

## 3. 실행 방법

모두 `kubespray-lab` 디렉터리에서 실행한다. 랩 밖에서는 `KUBECONFIG` 를 먼저 내보낸다. 스크립트는 그 값이 있으면 그대로 쓴다.

### 3.1 CNPG (C1~C5)

```bash
perf/cnpg-suite.sh <네임스페이스> <클러스터> [scale=20] [접속 수=8] [초=60]
# 예
perf/cnpg-suite.sh v2test pg-v2
```

하는 일: 클러스터와 같은 네임스페이스에 부하용 파드(`pgbench-<클러스터>`)를 띄워 `-rw` 서비스로 붙는다. DB 파드 안에서 돌리면 부하 도구가 DB 의 CPU 를 같이 쓰기 때문이다. 접속 정보는 CNPG 가 만든 `<클러스터>-app` 시크릿에서 읽는다.

직접 하려면:

```bash
perf/pgbench.sh <ns> <클러스터> init 20                 # 데이터 만들기. scale 1 ≈ 15MB
perf/pgbench.sh <ns> <클러스터> run 8 60                # 읽기·쓰기, 접속 8, 60초
perf/pgbench.sh <ns> <클러스터> run 8 60 -S             # 읽기 전용
PGOPTIONS="-c synchronous_commit=local" perf/pgbench.sh <ns> <클러스터> run 8 60    # standby 를 기다리지 않음

# 부하 중 복제 지연 (primary 에서)
kubectl -n <ns> exec <primary> -c postgres -- psql -c "select application_name, sync_state, replay_lag, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) from pg_stat_replication"

# fsync 속도 (primary 의 데이터 볼륨)
kubectl -n <ns> exec <primary> -c postgres -- pg_test_fsync -s 2 -f /var/lib/postgresql/data/pgdata/fsync.tmp
```

볼 숫자.

| 출력 | 뜻 |
|---|---|
| `tps` | 초당 처리한 트랜잭션. 높을수록 좋다 |
| `latency average` / `stddev` | 트랜잭션 하나의 평균 시간과 흔들림. stddev 가 평균보다 크면 가끔 크게 늦는다는 뜻 |
| `progress:` 줄 | 10초마다의 tps. 주기적으로 꺼지면 체크포인트를 의심한다 |
| `number of failed transactions` | 0 이어야 한다 |

실서버에서 바꿀 것: scale 을 DB 크기가 메모리(`shared_buffers` 가 아니라 노드 메모리)보다 커지도록 잡는다. 60초가 아니라 10분 이상 돌려 체크포인트가 여러 번 지나가게 한다. 3번 돌려 가운데 값을 쓴다.

### 3.2 부하 중 전환 (C6)

```bash
perf/switchover-load.sh <네임스페이스> <클러스터> [접속 수=8] [전체 초=90] [전환 시점=30]
```

`pgbench -P 1` 로 1초마다 tps 를 찍으면서 전환하고, 마지막 정상 줄과 다시 정상인 첫 줄 사이를 쓰기 중단으로 센다. pgbench 는 접속이 끊기면 끝나므로 반복문으로 다시 붙인다. `kubectl-cnpg` 플러그인이 있으면 `kubectl cnpg promote` 를, 없으면 같은 동작의 status 패치를 쓴다.

### 3.3 Harbor (H1~H5)

```bash
# 랩
perf/harbor-bench.sh
# 다른 환경
HARBOR_HOST=<호스트> HARBOR_CREDS=<계정:비밀번호> PG_NS=<DB 네임스페이스> PG_CLUSTER=<DB 클러스터> perf/harbor-bench.sh
```

- `perf/mkimage.py <디렉터리> <MB>` 가 난수로 채운 레이어 하나짜리 이미지를 만든다. 난수라서 압축과 중복 제거가 되지 않아 매번 실제로 전송된다.
- push 는 `skopeo copy oci:<디렉터리> docker://<호스트>/perf/<이름>`, pull 은 반대 방향으로 `dir:` 에 받는다.
- API 는 `oha -n 500 -c 20` 으로 세 주소를 친다.
- 단계마다 Harbor DB 의 `pg_stat_database` 를 앞뒤로 읽어 커밋 수와 행 변경 수의 차이를 낸다.
- `perf` 프로젝트를 만들고 그 안에 이미지를 올린다. 랩 기준 약 300MB 가 남는다. 끝나면 Harbor 에서 프로젝트를 지운다.

비밀번호는 환경 변수로만 넘기고 스크립트나 기록에 적지 않는다.

### 3.4 Harbor 사용 중 DB 전환 (H6)

```bash
perf/harbor-switchover.sh [전체 초=60] [전환 시점=20]
```

`oha` 로 계속 요청을 보내 성공·실패 건수를 세고, 따로 1초마다 한 번씩 요청해 실패한 시각을 적는다.

### 3.5 Longhorn 볼륨 (S1)

```bash
NODE=<노드> perf/fio-all.sh longhorn-v2-single longhorn-v2 longhorn
```

`perf/fio.yaml` 이 PVC 와 Job 을 만들어 fio 다섯 가지(4k 랜덤 읽기·쓰기, 1M 순차 읽기·쓰기, 8k fsync)를 돌린다. 랩은 `alpine` 에 fio 를 그때 설치한다. 폐쇄망에서는 fio 가 들어 있는 이미지로 바꾸고 `apk` 줄을 지운다. 한 번에 하나씩, 같은 노드에서 돌린다.

### 3.6 볼륨 크기별 첫 마운트 시간 (S2, 미실행)

```bash
perf/attach-time.sh <StorageClass> <노드> 2Gi 20Gi 100Gi
```

크기만 다른 새 PVC 로 파드를 띄워 `Running` 까지의 시간을 재고, 같은 볼륨을 다시 붙이는 시간도 잰다. 기다리는 동안 노드에 `mkfs`·`blkid` 가 돌고 있으면 찍는다. 볼륨 지연 조사의 후보 H8(큰 새 볼륨의 첫 `mkfs`)을 확인하는 시험이다([V2-DELAY-HYPOTHESES.md](V2-DELAY-HYPOTHESES.md)). **스크립트만 만들었고 돌려 보지 않았다.**

## 4. 시험하다 걸린 것

- **파드를 `nodeName` 으로 노드에 고정하면 PVC 가 `Pending` 에 머문다.** `nodeName` 은 스케줄러를 건너뛰는데, `WaitForFirstConsumer` 볼륨은 스케줄러가 노드를 정해 줘야 만들어진다. `nodeSelector` 로 바꿨다.
- **`longhornio/kbench` 이미지는 랩(arm64)에서 받아지지 않았다**(`unexpected media type text/html`). 원인은 확인하지 않았고 같은 일을 하는 fio Job 으로 바꿨다. amd64 실서버에서는 kbench 를 그대로 써도 된다.
- **pgbench 출력의 시각이 전부 같게 찍혔다.** `grep` 이 출력을 모아서 내보냈기 때문이다. `grep --line-buffered` 로 고쳤다. 고치기 전 실행은 버렸고, `results/switchover-1.log`(1회차)와 `results/switchover.log`(2회차)는 고친 뒤의 기록이다.
- **`pg_stat_checkpointer` 는 PostgreSQL 17 부터 있다.** 16 에서는 `pg_stat_bgwriter` 의 `checkpoints_timed`, `checkpoints_req` 를 본다. `results/cnpg.log` 끝의 오류가 이것이고 스크립트는 고쳤다.
- **Harbor DB 를 깨울 때 인스턴스 하나의 볼륨이 꺼 둔 노드에 있어서 클러스터가 올라오지 않았다.** 볼륨이 1벌 strict-local 이면 그 노드가 켜져 있어야 한다.

## 5. 못 본 것

- 각 시험의 반복. 1번씩이라 흔들림을 모른다.
- 긴 시간 부하(체크포인트 여러 번, autovacuum, WAL 보관 공간).
- 접속 풀(PgBouncer, CNPG `Pooler`)을 넣었을 때.
- 백업이 도는 동안의 영향.
- Harbor 의 스캔(Trivy), 가비지 컬렉션, 복제 정책이 도는 동안의 영향.
- Harbor core·registry 를 2개 이상으로 늘렸을 때. 랩은 1개씩이었다.
- 부하 중 노드가 갑자기 죽는 경우. 계획 전환만 쟀다.
- 수 GB 짜리 이미지, 레이어가 수십 개인 이미지.

## 6. 운영에서 할 때

- **운영 중인 클러스터와 Harbor 에는 돌리지 않는다.** pgbench 는 테이블을 만들고 지우고, fio 는 디스크를 꽉 채워 쓰고, Harbor 시험은 프로젝트를 만든다. 시험 클러스터에서 한다.
- 조건을 같이 적는다: 노드 사양, 인스턴스 수, 동기 복제 설정, StorageClass, 복제본 수, 같은 시각에 돌던 다른 부하.
- 한 번에 한 가지만 바꾼다. 인스턴스 수와 복제본 수를 같이 바꾸면 무엇의 효과인지 알 수 없다.
