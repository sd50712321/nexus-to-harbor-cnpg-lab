# Longhorn V2: 노드 재부팅 뒤 디스크가 다시 안 붙을 때

V2 데이터 엔진을 쓰는 실서버에서, 워커 노드가 죽었다 살아난 뒤 Longhorn 디스크가 연결 실패로 남는 문제의 원인과 예방법이다.

> **이 문서의 근거 수준.** 2026-11-16 에 이 랩 워커 3대에 V2 엔진을 켜고 재현했다(Longhorn 1.13.0, VMware Fusion arm64 VM, SATA 가상 디스크). 실측 결과는 7절, 노드가 죽었을 때 CNPG 승격·재부착 시간은 [V2-CNPG-FAILOVER.md](V2-CNPG-FAILOVER.md) 에 있다. 랩에서 못 본 것은 `[확인]` 으로 남겼다. 근거 링크는 맨 아래에 있다.

## 1. 증상

- 노드에 디스크가 `sda` ~ `sde` 처럼 여러 개 있고, 그중 하나(예: `sde`)를 통째로 V2 디스크로 등록했다.
- 노드를 재부팅하면 Longhorn 노드 화면에서 그 디스크가 연결 실패로 남고, 그 노드의 복제본이 올라오지 않는다.

## 2. 원인

- `/dev/sdX` 이름은 디스크 고유의 이름이 아니다. 부팅할 때 커널이 디스크를 인식한 순서대로 붙이는 이름이라, 재부팅하면 `sde` 였던 디스크가 `sdd` 나 `sdf` 가 될 수 있다.
- Longhorn 은 등록된 경로(`path: /dev/sde`)를 그대로 다시 연다. 이름이 밀리면 다른 디스크를 열게 되고, 그 디스크에는 Longhorn 의 저장 영역이 없으므로 실패한다.
- **라벨로 해결되지 않는 이유.**
  - V2 디스크는 파일시스템 없이 원판을 통째로 쓴다. 그래서 `/dev/disk/by-label`, `/dev/disk/by-uuid` 항목이 생기지 않는다.
  - 쿠버네티스 노드 라벨과 Longhorn 디스크 태그는 볼륨을 어디에 둘지 고르는 용도다. 어느 장치가 그 디스크인지는 정해 주지 않는다.

## 3. 해결: 처음부터 바뀌지 않는 경로로 등록한다

리눅스는 디스크 고유 번호에 묶인 경로를 `/dev/disk/by-id/` 에 만들어 둔다. 이 경로는 재부팅해도 같은 디스크를 가리킨다. Longhorn 이슈 #12910 도 이 방식을 재부팅에 안정적인 권장 방식이라고 적고 있다.

### 3.1 고정 경로 찾기 (노드에서)

지금 V2 로 쓰는 디스크가 `sde` 라면:

```bash
DEV=sde
for l in /dev/disk/by-id/*; do
  [ "$(readlink -f "$l")" = "/dev/$DEV" ] && echo "$l"
done | grep -v -- '-part'
```

- `wwn-…` 또는 `scsi-…` 로 시작하는 줄을 쓴다. 둘 다 디스크 고유 번호다.
- **아무것도 안 나오면** 하이퍼바이저가 디스크 고유 번호를 VM 에 넘겨주지 않는 것이다. 이때는 `/dev/disk/by-path/` 를 같은 방법으로 찾아 쓴다. VM 의 디스크 슬롯 구성을 바꾸지 않는 한 고정된다. `[확인]` 실서버 VM 에서 `by-id` 항목이 보이는지(랩의 VMware SATA 디스크는 보였다).
- **`wwn-` 으로 시작하는 이름을 쓴다.** 랩에서 `ata-…_03000000000000000001` 처럼 일련번호가 붙은 이름은 디스크가 아니라 **포트 번호**에서 만들어진 값이었다(세 노드가 전부 같은 값). 디스크를 다른 포트로 옮기면 이 이름도 따라 바뀐다. `wwn-0x…` 는 디스크마다 달랐고 포트를 바꿔도 그대로였다.
- 디스크가 맞는지는 `lsblk -o NAME,SIZE,SERIAL,WWN` 으로 크기와 시리얼을 대조한다.

### 3.2 kubectl 판: 노드마다 등록

```bash
NODE=<노드 이름>
DISK=/dev/disk/by-id/<3.1 에서 찾은 이름>

kubectl -n longhorn-system patch node.longhorn.io "$NODE" --type merge -p "{
  \"spec\": {\"disks\": {\"v2-disk\": {
    \"path\": \"$DISK\", \"diskType\": \"block\",
    \"allowScheduling\": true, \"evictionRequested\": false,
    \"storageReserved\": 0, \"tags\": []
  }}}
}"

kubectl -n longhorn-system get node.longhorn.io "$NODE" -o jsonpath='{.status.diskStatus.v2-disk.conditions}'
```

### 3.3 Helm 판: 노드를 추가할 때 자동으로 등록

Longhorn 은 노드의 라벨과 주석을 보고 디스크를 자동 등록하는 기능이 있다. 노드를 넣을 때마다 손으로 편집하지 않아도 된다.

values:

```yaml
defaultSettings:
  createDefaultDiskLabeledNodes: true
```

노드마다(Longhorn 이 그 노드를 처음 볼 때 적용된다):

```bash
kubectl label node "$NODE" node.longhorn.io/create-default-disk=config
kubectl annotate node "$NODE" node.longhorn.io/default-disks-config="[{\"name\":\"v2-disk\",\"path\":\"$DISK\",\"diskType\":\"block\",\"allowScheduling\":true}]"
```

- 이 주석은 **그 노드에 등록된 디스크와 태그가 하나도 없을 때만** 적용된다. 이미 디스크가 등록된 노드는 3.2 또는 4절로 바꾼다.
- 주석이 검증에 실패하면 통째로 무시된다. 적용 뒤 `node.longhorn.io` 의 `spec.disks` 에 들어갔는지 확인한다.
- `[확인]` 주석에 `diskType: block` 을 넣는 형태는 소스에 block 분기가 있는 것만 확인했다. 실서버에서 한 노드로 먼저 시험한다.

## 4. 이미 `/dev/sdX` 로 등록한 노드 바꾸기

1. Longhorn 노드 화면에서 그 디스크의 스케줄링을 끄고 복제본을 다른 노드로 비운다(Eviction Requested).
2. 디스크에 복제본이 0 이 되면 디스크를 제거한다. 스케줄링이 켜져 있거나 복제본이 남아 있으면 Longhorn 이 제거를 거부한다.
3. 3.2 의 명령으로 `by-id` 경로를 써서 다시 추가한다.

**더 간단한 방법: 디스크를 비우지 않고 `path` 만 고친다 (랩 실측, 7절).** 디스크 안의 데이터(lvstore)는 UUID 로 식별되므로 경로만 바꿔도 그대로 인식했다.

```bash
NODE=<노드>; DISK=/dev/disk/by-id/wwn-0x…        # 3.1 에서 찾은 값
kubectl -n longhorn-system patch nodes.longhorn.io "$NODE" --type merge \
  -p "{\"spec\":{\"disks\":{\"v2-disk\":{\"path\":\"$DISK\"}}}}"     # v2-disk = 등록할 때 쓴 디스크 이름
```

- 정상 동작 중인 노드(볼륨 attached, CNPG primary 보유): 6초 뒤 반영, 3초 간격 쓰기 30번 중 실패 0.
- 이름이 밀려 `Ready=False` 가 된 노드: 약 60초 뒤 디스크 Ready, 볼륨 attached, CNPG 3/3. 데이터 유지.
- **그래도 안 돌아오면 그 노드의 V2 instance-manager 파드를 지운다.** `/dev/sdX` 가 다른 디스크를 가리키게 된 경우(7절 A4), 경로를 고친 뒤에도 `cannot find lvstore with UUID …` 가 반복됐다. instance-manager 가 잘못 잡은 디스크를 기억하고 있어서다. 파드를 지우면 다시 떠서 87초 뒤 3/3 으로 돌아왔다. 그 노드의 V2 볼륨이 잠깐 끊기므로 이미 `faulted` 인 노드에서만 한다.

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'          # 노드별 V2 instance-manager 이름
kubectl -n longhorn-system delete pod <그 노드의 instance-manager 이름>
```

## 5. 재부팅 뒤 점검 순서

```bash
kubectl -n longhorn-system get node.longhorn.io <노드> -o yaml   # spec.disks 의 path, status.diskStatus 의 conditions 메시지
lsblk -o NAME,SIZE,SERIAL,WWN                                    # 노드에서: 등록된 경로의 장치가 원래 디스크인지
ls -l /dev/disk/by-id/ | grep -v -- '-part'                      # 노드에서: 고정 이름이 지금 어느 sdX 를 가리키는지
```

- 등록된 경로가 `/dev/sdX` 이고 그 장치의 크기나 시리얼이 원래 디스크와 다르면 이름이 밀린 것이다. 3절로 간다.
- 경로가 `by-id` 인데도 실패하면 이름 문제가 아니다. 6절의 버전 문제와 V2 전제 조건(hugepage, 커널 모듈이 부팅 때 올라오는지)을 본다.

## 6. 버전에 따른 주의

| 이슈 | 내용 | 수정 버전 |
|---|---|---|
| #12910 | `by-id` 경로로 등록한 V2 디스크의 상태 수집이 실패 로그를 반복한다 | 1.12.0, 1.11.2 |
| #12406 | 노드를 차례로 재부팅하면 V2 볼륨이 attach/detach 를 반복한다 | 1.11.0 |
| #10112 | 노드 재부팅 뒤 V2 볼륨이 detaching/faulted 로 남는다 | 1.10.0 |

`[확인]` 실서버의 Longhorn 버전. 위 수정 버전보다 낮으면 경로를 고친 뒤에도 재부팅 장애가 남을 수 있다.

## 7. 랩 실측 (2026-11-16)

구성: 워커 3대(5GB, 2 vCPU)에 빈 SATA 디스크 2개(1GB dummy, 10GB V2 용)를 붙였다. 게스트에서 `sda`=OS, `sdb`=dummy, `sdc`=V2. V2 볼륨 위에 CNPG 3 인스턴스(`v2test/pg-v2.yaml`, 스토리지 1벌 strict-local)를 올렸다. dummy 를 떼거나 포트를 맞바꿔 재부팅하면 이름이 밀린다(`Vagrantfile` 의 `V2_NO_DUMMY`, `V2_SWAP`). 기록은 `logs/v2/`.

| 시험 | 한 일 | 결과 |
|---|---|---|
| A1 | `/dev/sdc` 로 등록 → dummy 를 떼고 재부팅 (V2 디스크가 `sdb` 로) | 디스크 `Ready=False`(`failed to detect disk device /host/dev/sdc`), 볼륨 `faulted`, CNPG 파드 `Init` 에서 6분 넘게 정지. 30초마다 재시도만 반복 |
| A2 | A1 상태에서 `path` 만 `by-id` 로 교체 | 약 60초 뒤 3/3, 데이터 유지 |
| A3 | `by-id` 로 등록된 채 dummy 를 다시 붙여 재부팅 (`sdb` → `sdc`) | 손대지 않고 노드 기동 119초 뒤 3/3 |
| A4 | `/dev/sdc` 로 등록 → 포트를 맞바꿔 재부팅 (`/dev/sdc` = 빈 디스크) | Longhorn 이 거부(`cannot find lvstore with UUID …`). 빈 디스크에는 아무것도 쓰지 않았다(앞 4MB 가 전부 0) |
| A5 | A4 상태에서 `path` 만 `by-id` 로 교체 | 5분 동안 그대로 `Ready=False` |
| A6 | A5 뒤 그 노드의 V2 instance-manager 파드 삭제 | 87초 뒤 3/3, 데이터 유지 |
| A7 | 정상 노드(primary 보유)에서 `path` 만 `by-id` 로 교체 | 6초 뒤 반영, 쓰기 실패 0 |

V2 를 켤 때 걸린 것 하나: 워커가 2 vCPU 면 V2 instance-manager 가 뜨지 않는다. 기본 `data-engine-cpu-mask` 가 `0x3`(코어 2개)이라 `SPDK cpu mask 0x3 covers every online CPU` 로 거부한다. 코어 하나만 주면 뜬다.

```bash
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
# Helm 판: defaultSettings.dataEngineCpuMask 에 같은 값 — [확인] 차트 키 이름은 values.yaml 에서 확인한다
```

못 본 것: 3.3 의 주석 자동 등록(`diskType: block`), NVMe·VirtIO 디스크(랩은 SATA → aio 드라이버), 실서버 하이퍼바이저에서의 `by-id`.

## 8. 근거

- Longhorn 문서, V2 Data Engine Quick Start — "Add block-type Disks in Longhorn Nodes": https://longhorn.io/docs/1.10.0/v2-data-engine/quick-start/
- Longhorn 문서, Configuring Defaults for Nodes and Disks (라벨·주석으로 디스크 자동 등록): https://longhorn.io/docs/1.10.0/nodes-and-volumes/nodes/default-disk-and-node-config/
- Longhorn 이슈 #12910 (by-id 경로와 권장 방식 언급): https://github.com/longhorn/longhorn/issues/12910
- Longhorn 이슈 #12406, #10112 (재부팅 뒤 V2 볼륨 장애): https://github.com/longhorn/longhorn/issues/12406 , https://github.com/longhorn/longhorn/issues/10112
- longhorn-manager v1.10.0 `webhook/resources/node/validator.go` (디스크 제거 조건, 종류 변경 금지), `types/types.go` 의 `CreateDisksFromAnnotation` (주석의 block 분기)
