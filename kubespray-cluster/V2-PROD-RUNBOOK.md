# Longhorn V2 실서버 작업 절차 (랩 시험 X·Y·P 에서 나온 것)

실서버에서 무엇을 어떤 순서로 하면 되는지만 적는다. 근거가 된 시험은 7절에 있고, 원인을 좁힌 과정은 [V2-DETACH-HYPOTHESES.md](V2-DETACH-HYPOTHESES.md) 와 [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 30~34절에 있다.

- 명령의 네임스페이스는 실서버 값 `longhorn` 으로 적었다. 랩은 `longhorn-system` 이다.
- 랩은 맥 한 대 위의 VM 6대(워커 3대, 디스크 1개씩)다. **초 단위 수치는 실서버에 그대로 옮기지 않는다.** 순서와 "되는가 안 되는가"만 가져간다.
- 각 항목에 `[랩 확인]`(랩에서 실제로 해 본 것), `[공식]`(Longhorn 문서), `[미확인]`(해 보지 않은 것)을 붙였다.

## 1. 한눈에

| 상황 | 할 일 | 절 |
|---|---|---|
| 1.12.2 로 올린다 | helm 만으로는 V2 가 안 바뀐다. V2 볼륨을 전부 떼는 정지 시간을 잡는다 | 2 |
| 파드가 `Init`/`ContainerCreating`/`Terminating` 에서 멈춤 | 노드에서 `Suspended` dm 을 찾아 `dmsetup resume` | 3 |
| 인스턴스 매니저를 내렸다 올려야 한다 | 볼륨이 전부 `healthy` 일 때, 한 노드씩, 끝나고 다시 `healthy` 될 때까지 기다린다 | 4 |
| pg 복제본 하나가 `0/1 Running` 에서 안 올라옴 | 로그에 `pg_rewind … could not find common ancestor` 면 그 인스턴스의 PVC 와 파드를 지워 다시 복제시킨다 | 5 |
| 새 pg 클러스터가 `Init:0/1` 에서 영영 안 올라옴 | 이벤트에 `Structure needs cleaning` 이면 만들다 만 파일시스템이다. 그 클러스터를 지우고 다시 만든다 | 5 |
| 디스크가 `/dev/sdX` 로 등록돼 있다 | 볼륨이 붙은 채로 `by-id` 경로로 바꿀 수 있다 | 6 |

## 2. 1.12.1 → 1.12.2 올리기

### 알아 둘 것

- `[공식]` V2 는 라이브 업그레이드를 지원하지 않는다. 올리기 전에 V2 볼륨을 전부 떼고 replica 를 멈추라고 되어 있다. 또 한 번 올리면 내릴 수 없다(다운그레이드 미지원).
- `[랩 확인]` 볼륨을 붙인 채 `helm upgrade` 를 해도 실패하지 않고 쓰기도 끊기지 않는다(부하 616초 동안 중단 0번). **대신 V2 인스턴스 매니저는 1.12.1 그대로 남는다.** 1.12.2 인스턴스 매니저는 `stopped` 로 만들어지기만 한다. manager·UI·CSI·V1 인스턴스 매니저만 바뀐다.
- 그래서 helm 이 `deployed` 로 끝났다고 1.12.2 의 수정(rebuild 때 dm 을 짧게 멈추는 것)이 적용된 게 아니다. 아래 명령으로 V2 인스턴스 매니저의 이미지를 봐야 한다.

```bash
kubectl -n longhorn get instancemanagers.longhorn.io \
  -o custom-columns=NAME:.metadata.name,ENGINE:.spec.dataEngine,NODE:.spec.nodeID,IMAGE:.spec.image,STATE:.status.currentState
# ENGINE=v2 인 줄에서 IMAGE 가 v1.12.2 이고 STATE 가 running 이어야 올라간 것이다.
```

### 절차 (권장: 정지 시간을 잡고 한 번에)

1. 사전 확인: 볼륨 전부 `healthy`, `Faulted` 없음, 굳은 dm 없음(3절 명령), 백업 확인. 폐쇄망이면 1.12.2 이미지를 Nexus 에 먼저 올린다(목록: 릴리스의 `longhorn-images.txt`).
2. `helm upgrade longhorn <차트> -n longhorn --version 1.12.2 -f <기존 values 파일>`. `--reuse-values` 는 쓰지 않는다(옛 이미지 태그가 남는다).
3. V2 볼륨을 쓰는 워크로드를 전부 내린다. pg 는 `kubectl annotate cluster <이름> cnpg.io/hibernation=on --overwrite`, 나머지는 `replicas=0`.
4. 볼륨이 전부 `detached` 가 되면 Longhorn 이 옛 V2 인스턴스 매니저를 지우고 새 것을 띄운다. 위 명령으로 세 노드 모두 `v1.12.2 running` 인지 본다. `[랩 확인]` 랩에서는 내린 지 60~90초 안에 바뀌었다.
5. 워크로드를 다시 올린다(`cnpg.io/hibernation=off`, `replicas` 원복). `[랩 확인]` 랩에서는 73초 뒤 전부 `healthy`, pg 3/3, 데이터 점검 통과.

replica 가 노드마다 하나씩 있으면 어느 볼륨이든 모든 노드에 걸쳐 있다. 그래서 "한 노드만 비운다"가 안 되고, V2 를 쓰는 것 전체를 한 번에 내려야 한다.

### 정지 시간을 못 잡을 때

`[랩 확인]` helm 뒤에 옛 V2 인스턴스 매니저 파드를 지우면 그 노드에는 1.12.2 가 올라온다. 1.12.1 과 1.12.2 가 섞인 상태에서도 rebuild 가 끝나 `healthy` 로 돌아왔다(랩 4분).

하지만 이건 그 노드의 `spdk_tgt` 를 죽이는 것과 같다. 그 노드에 붙은 볼륨의 파드가 재시작하고, 모든 볼륨이 `degraded` 가 되어 rebuild 가 돈다. 4절의 규칙을 그대로 지켜야 하고, 공식 절차가 아니다. 가능하면 위의 정지 절차로 한다.

## 3. 굳은 dm 찾기와 풀기

증상: 파드가 `Init`·`ContainerCreating`·`Terminating` 에서 몇 분씩 멈춘다. 이벤트는 `FailedAttachVolume … Waiting for detach`, `KillPodSandbox`/`KillContainer … DeadlineExceeded`. Longhorn 화면은 정상으로 보일 수 있다.

```bash
# 각 워커에서. Suspended 가 몇 초 넘게 남아 있으면 굳은 것이다(정상적인 멈춤은 1초 안에 끝난다).
dmsetup info -c --noheadings -o name,suspended,open | grep '^pvc-' | grep Suspended
ps -eo stat,etimes,comm | awk '$1 ~ /^D/'          # 끝나지 않는 I/O 에 걸린 프로세스
dmesg | grep -i 'blocked for more than'

# 풀기
dmsetup resume <pvc-이름>
```

- `[랩 확인]` pg 는 굳은 노드의 인스턴스를 버리고 다른 노드로 failover 해 서비스가 이어질 수 있다(A5 에서 185초 뒤). 그래도 굳은 dm 은 남아 있으므로 찾아서 풀어야 한다.
- `[랩 확인]` `resume` 뒤 30초 안에 파드가 `Running` 이 됐고, 그 노드의 인스턴스 매니저도 그제서야 돌아왔다. 인스턴스 매니저 파드를 지우는 것만으로는 이미 굳은 dm 이 풀리지 않는다.
- `[랩 확인]` 1.12.1 에서는 풀고 난 뒤 옛 노드에 `Active open=0` 인 dm 이 남은 적이 있다. `dmsetup remove <이름>` 으로 지운다. `open` 이 0 인지 먼저 본다.
- 어떤 때 굳는가: 다른 노드 때문에 rebuild 가 도는 중(Longhorn 이 dm 을 잠깐 멈춘 순간)에 이 노드의 `spdk_tgt` 가 죽고, 파드가 다른 노드로 옮겨 갈 때. 파드가 같은 노드에 그대로 있으면 새 인스턴스 매니저가 다시 이어 주어 1분쯤 안에 저절로 풀렸다.
- `[랩 확인]` 시점을 맞추지 않고 `spdk_tgt` 를 무작위로 8번 죽였을 때는 한 번도 굳지 않았다. 드물게 맞아야 생기는 일이다. 실서버에서 반복된다면 `spdk_tgt` 가 왜 죽는지(인스턴스 매니저 파드의 이전 로그, 노드 `dmesg` 의 OOM·hugepage)가 먼저다.
- 주기 점검을 걸어 두려면 위 첫 줄을 5초 간격으로 두 번 돌려 두 번 다 나오는 이름만 알리면 된다. `[미확인]` 랩에서 자동화해 돌려 보지는 않았다.

## 4. 인스턴스 매니저를 내렸다 올릴 때

- 시작 전에 `kubectl -n longhorn get volumes.longhorn.io` 가 전부 `healthy` 인지 본다. `degraded` 가 하나라도 있으면 하지 않는다. `[랩 확인]` `degraded` 가 있을 때 한 번 더 죽인 경우가 쓰기 중단이 가장 길었다(184초, 다른 때는 11~76초).
- 한 번에 한 노드. 끝나고 전부 `healthy` 로 돌아온 뒤 다음 노드. `[랩 확인]` 한 번 죽인 뒤 `healthy` 까지 랩에서 35초~7분이었다. 대부분은 rebuild 시간이라 볼륨이 크면 더 걸린다.
- 그 노드에 pg primary 가 있으면 먼저 switchover 해 둔다. 안 하면 CNPG 가 failover 를 하고, 연달아 겹치면 5절의 `pg_rewind` 실패로 이어질 수 있다.
- 새 PVC 를 만드는 작업(pg 클러스터 생성, 인스턴스 추가)이 도는 동안에는 하지 않는다(5절 둘째 항목).

## 5. pg(CNPG) 쪽에서 저절로 안 돌아오는 두 경우

저장소는 `healthy` 인데 pg 가 안 올라오는 경우다. 둘 다 Longhorn 을 건드려서는 안 풀린다.

### 복제본이 `0/1 Running` 에서 멈춤: `pg_rewind` 실패

```bash
kubectl -n <ns> logs <파드> -c postgres --tail=50 | grep pg_rewind
# pg_rewind: error: could not find common ancestor of the source and target cluster's timelines
# pg_rewind: error: could not find previous WAL record at …
```

`[랩 확인]` primary 가 있던 노드의 저장소를 죽이는 일이 반복되어 primary 가 여러 번 바뀐 뒤 생겼다. 옛 primary 의 `pg_wal` 안 타임라인 history 파일 여러 개가 0바이트였다. `pg_rewind` 가 도는 중에 저장소가 다시 끊겨 파일을 만들다 만 것으로 본다(그 시점 로그는 파드가 바뀌며 사라져 확정하지 못했다). 15분 넘게 5초마다 같은 오류를 되풀이했다. 두 번째(A5)는 primary 가 있던 노드의 인스턴스 매니저가 내려가 failover 된 경우로, 옛 primary 가 `could not find previous WAL record` 로 못 돌아왔다. 두 번 다 "저장소가 끊기며 primary 에서 밀려난 인스턴스"였고, 데이터 손상은 primary 쪽 점검에서 나오지 않았다.

조치: primary 가 정상인 것을 확인하고, 그 인스턴스의 PVC 와 파드를 지운다. CNPG 가 primary 에서 새로 복제해 채운다. `[랩 확인]` 랩(150MB)에서 112초, rebuild 와 겹친 때는 328초.

```bash
kubectl -n <ns> get cluster <이름>                    # primary 가 누구인지, 지우려는 게 primary 가 아닌지
kubectl -n <ns> delete pvc <인스턴스 이름> --wait=false   # WAL 을 따로 둔 구성이면 <인스턴스 이름>-wal 도
kubectl -n <ns> delete pod <인스턴스 이름>
```

### 새 클러스터가 `Init:0/1` 에서 멈춤: 만들다 만 파일시스템

```bash
kubectl -n <ns> describe pod <파드> | grep -i 'structure needs cleaning'
```

`[랩 확인]` pg 클러스터를 만드는 동안 인스턴스 매니저가 내려가면 첫 포맷(`mkfs.xfs`)이 중간에 끊길 수 있다. 볼륨은 `attached healthy` 인데 마운트가 영영 안 된다(`xfs_repair -n` 이 "mkfs-in-progress bit set" 을 낸다). 15분을 기다려도 그대로였다.

조치: 아직 데이터가 없는 볼륨이므로 그 클러스터(또는 그 인스턴스의 PVC)를 지우고 다시 만든다. `[미확인]` 지우고 다시 만드는 것까지 랩에서 따로 재 보지는 않았다. 데이터가 든 볼륨에서 같은 메시지가 나오면 이 경우가 아니므로 지우지 않는다.

## 6. 디스크 경로를 바뀌지 않는 이름으로

재부팅 뒤 `sda`·`sdb` 순서가 바뀌어 디스크가 안 잡힌 일의 재발 방지다. 배경과 등록법은 [LONGHORN-V2-DISK.md](LONGHORN-V2-DISK.md).

```bash
# 지금 무엇으로 등록돼 있나
kubectl -n longhorn get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | .spec.disks | to_entries[] | "\($n) \(.key) \(.value.path)"'
# 그 장치의 고정 이름 (노드에서)
ls -l /dev/disk/by-id/ | grep -w 'sdb1'
```

- `[공식]` Longhorn 문서는 `/dev/disk/by-id/` 를 권한다(`/dev/sdb` 같은 이름은 피하라고 적혀 있다). by-path 는 언급이 없다.
- `[랩 확인]` 볼륨이 붙어 쓰기가 도는 중에 `kubectl edit` 으로 경로만 바꿔도 디스크 UUID 가 유지되고 볼륨은 `healthy` 그대로였다. 인스턴스 매니저를 재시작해도 새 경로로 다시 열었다.
- `[랩 확인]` 경로가 엉뚱한 장치를 가리킨 채 인스턴스 매니저가 뜨면 `cannot find lvstore with UUID` 로 실패만 하고 그 장치를 덮어쓰지는 않았다. 경로를 고친 뒤에는 인스턴스 매니저를 재시작해야 `Ready` 로 돌아왔다.
- `[미확인]` VMware 에서는 VM 설정 `disk.EnableUUID=TRUE` 가 없으면 `by-id` 에 `wwn-`/`scsi-` 링크가 안 생길 수 있다. 실서버에서 `ls /dev/disk/by-id/` 로 먼저 본다. 없으면 파티션에는 `/dev/disk/by-partuuid/` 를 쓸 수 있다.
- 바꾸는 순서: 한 노드씩, 볼륨 전부 `healthy` 일 때, 바꾼 뒤 디스크 `Ready` 와 UUID 가 그대로인지 확인.

## 7. 근거가 된 시험 (2026-11-19~20, 각 1회)

| 시험 | 한 일 | 결과 | 기록 |
|---|---|---|---|
| Y1 (1.12.1) | pgbench 접속 4 + 쓰기 부하 중 무작위 워커의 `spdk_tgt` 를 무작위 시점에 8번 `kill -9` | 굳은 dm 0번. 6번은 35~431초에 회복. 2번은 pg 복제본 하나가 `pg_rewind` 실패로 못 붙음(같은 원인이 이어진 것). 쓰기 중단 19번 합계 714초/2400초, 최장 184초. 끝난 뒤 잔액 합 일치, amcheck 통과 | `v2test/results/y/Y1-1121.log` |
| Y3 | 같은 부하 중 `helm upgrade` 1.12.1 → 1.12.2 | helm 97초, 쓰기 중단 0번. V2 인스턴스 매니저는 1.12.1 로 남음 | `v2test/results/y/Y3-1121to1122.log` |
| Y3 이어서 | 옛 V2 인스턴스 매니저 파드 하나 삭제 → 그 노드만 1.12.2. 그다음 전부 떼기 → 나머지 두 노드 60~90초에 1.12.2. 다시 올림 73초 | 데이터 점검 통과 | 이 문서 2절 |
| A5 (1.12.2) | pg 부하 중 X1b(rebuild 중 `spdk_tgt` 죽이고 파드 옮김) 한 번, `resume` 뒤 데이터 점검 | `resume` 전까지 6분 굳음. 그동안 pg 는 185초 뒤 다른 노드로 failover 해 쓰기를 이어 감. `resume` 뒤 볼륨 전부 `healthy`, 굳었던 볼륨의 복제본은 저절로 복귀, 잔액 합 일치·amcheck 통과. 옛 primary 복제본은 `pg_rewind` 실패로 다시 복제시킴(328초) | `v2test/results/x/X1b-load-1122.log` |
| X1·X1b | rebuild 로 dm 이 멈춘 순간 `spdk_tgt` 를 죽임 | 파드가 그 노드에 남으면 60초쯤에 회복, 옮기면 `resume` 전까지 6분 넘게 굳음(두 버전 같음) | `v2test/results/x/X1*.log` |
| X2 | pg 클러스터 생성 중 인스턴스 매니저를 40초 간격으로 6번 내림 | 1.12.2 에서 한 번은 `mkfs` 가 끊겨 영영 `Init`, 1.12.1 에서 한 번은 359초에 완료(기준 155~187초) | `v2test/results/x/X2*.log` |
| P1·P2 | 디스크 경로를 붙은 채 변경, 엉뚱한 장치 지정 | 6절 | `v2test/results/p/P1-1122.log` |

데이터 점검은 `v2test/y-lib.sh` 의 `pg_check` 다: pgbench 의 계좌·창구·지점 잔액 합과 history 합이 같은지, `amcheck` 로 인덱스·테이블 구조, 복제 상태.

## 8. 이 문서로 말할 수 없는 것

- 실서버에서 `spdk_tgt` 가 왜 죽었는지, dm 이 어떤 경로로 멈춘 채 남았는지는 여전히 모른다. 랩은 "이런 순서면 같은 증상이 난다"를 보였을 뿐이다.
- 모든 시험이 1회다. Y1 의 "8번 중 0번"은 굳는 일이 드물다는 정도이지 안 생긴다는 뜻이 아니다.
- 부하는 pgbench 접속 4개(80~100 tps)와 `dd` 다. 실서버의 볼륨 크기·replica 수·네트워크에서는 rebuild 시간과 쓰기 중단 길이가 다르다.
- 해 보지 않은 것: 여러 워커가 한꺼번에 돌아올 때, 노드 사이 네트워크 지연, Harbor 를 올린 상태에서의 같은 시험, 굳은 dm 자동 감지.
