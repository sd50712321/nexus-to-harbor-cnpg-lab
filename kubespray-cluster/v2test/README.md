# Longhorn V2 + CNPG 시험 재현 (2026-11-16)

[LONGHORN-V2-DISK.md](../LONGHORN-V2-DISK.md) 7절과 [V2-CNPG-FAILOVER.md](../V2-CNPG-FAILOVER.md) 의 숫자를 낸 시험을 그대로 다시 하는 순서다. 원본 기록은 [results/](results/) 에 있다.

## 0. 시험 구성

| 항목 | 값 |
|---|---|
| 호스트 | 32GB Apple Silicon Mac, VMware Fusion, Vagrant 2.4.9 |
| 노드 | ToR 1, control plane 3(2560MB), 워커 3(**5120MB**, 2 vCPU). ks-w4·w5 는 꺼 둠 |
| OS / 커널 | Ubuntu 24.04.3, 6.8.0-86-generic (arm64) |
| 쿠버네티스 | v1.36.4 (Kubespray), Cilium 1.20.2 |
| Longhorn | 1.13.0, V1 + V2 엔진 동시 사용 |
| CNPG | operator 1.30.1 (차트 0.29.1), PostgreSQL 16.15 |
| V2 디스크 | 워커마다 빈 SATA 가상 디스크 2개: dummy 1GB(`sdb`), V2 용 10GB(`sdc`). Longhorn 은 aio 드라이버로 잡았다 |

메모리 합계는 약 23.5GB. 시험 중 Docker Desktop 이 켜져 있었고 Mac 스왑은 3.7~3.9GB 로 늘지 않았다.

## 1. VM 준비

```bash
./scripts/v2-disks.sh ks-w1 ks-w2 ks-w3          # v2disks/<노드>-{dummy,data}.vmdk 생성 (VMware vdiskmanager)
vagrant up ks-tor ks-cp1 ks-cp2 ks-cp3
V2_NODES=ks-w1,ks-w2,ks-w3 vagrant up ks-w1 ks-w2 ks-w3
./scripts/lab-proxy.sh
```

`Vagrantfile` 의 V2 관련 환경 변수 (모두 기본은 꺼짐):

| 변수 | 하는 일 |
|---|---|
| `V2_NODES` | 적은 워커만 메모리를 `V2_MEM`(기본 5120)으로 올리고 디스크 2개를 SATA 포트 2·3 에 붙인다 |
| `V2_BIG` | 적은 워커에 `v2disks/<노드>-big.vmdk` 를 SATA 포트 4 에 하나 더 붙인다 (K9 디스크 크기 비교용) |
| `V2_NO_DUMMY` | 적은 노드는 dummy(포트 2)를 뗀다 → V2 디스크가 `sdc` 에서 `sdb` 로 당겨진다 |
| `V2_SWAP` | 적은 노드는 포트 2·3 의 디스크를 맞바꾼다 → `/dev/sdc` 가 빈 dummy 를 가리킨다 |

**`V2_NODES` 를 빼고 `vagrant up/halt/reload` 하면 메모리가 2688MB 로 돌아가고 V2 디스크가 떨어진다.**

게스트에서 본 디스크 (ks-w1):

```
sda 64G  wwn-0x5000c29bdbf10663   ← OS (세 노드가 같은 값: 같은 박스 이미지에서 복제)
sdb  1G  wwn-0x5000c292fc5b08d5   ← dummy
sdc 10G  wwn-0x5000c295b2303f66   ← V2
ata-VMware_Virtual_SATA_Hard_Drive_03000000000000000001 → sdc   ← 끝 번호는 포트 번호. 세 노드가 같다
pci-0000:01:00.0-ata-4 → sdc
```

## 2. 노드 준비 (Longhorn 1.13 문서 "V2 Data Engine Requirements")

```bash
./scripts/v2-node-prep.sh ks-w1 ks-w2 ks-w3
```

노드마다 하는 일:

```bash
apt-get install -y linux-modules-extra-$(uname -r)
printf 'vfio_pci\nuio_pci_generic\nnvme_tcp\n' > /etc/modules-load.d/longhorn-v2.conf
modprobe vfio_pci uio_pci_generic nvme_tcp
echo 'vm.nr_hugepages = 1024' > /etc/sysctl.d/90-longhorn-v2-hugepages.conf     # 2MiB × 1024 = 2GiB
sysctl -p /etc/sysctl.d/90-longhorn-v2-hugepages.conf
systemctl restart kubelet                                                       # 노드 allocatable 에 hugepages-2Mi: 2Gi 가 보여야 한다
```

문서는 GRUB 의 `hugepagesz=2M hugepages=1024` 로 영구 설정하라고 한다. 랩은 sysctl 로 넣었고 재부팅 뒤에도 1024 로 잡혔다(5GB 노드라 연속 메모리가 남아 있었다).

## 3. 시험 전에 내려 둔 것

메모리를 비우려고 Harbor 를 멈췄다.

```bash
kubectl -n harbor scale deploy --all --replicas=0
kubectl -n harbor scale sts --all --replicas=0
kubectl -n harbor annotate cluster harbor-pg cnpg.io/hibernation=on --overwrite
```

되돌리기: ks-w4·w5 를 켜고 `cnpg.io/hibernation=off`, `./scripts/addon.sh harbor`.

## 4. Longhorn V2 켜기

```bash
kubectl -n longhorn-system patch settings.longhorn.io v2-data-engine --type merge -p '{"value":"true"}'
# 2 vCPU 노드는 아래가 없으면 V2 instance-manager 가 안 뜬다 (TROUBLESHOOTING 27절)
kubectl -n longhorn-system patch settings.longhorn.io data-engine-cpu-mask --type merge -p '{"value":"{\"v2\":\"0x1\"}"}'
kubectl -n longhorn-system get instancemanagers.longhorn.io | awk '$2=="v2"'    # 세 노드 running
```

그대로 둔 V2 관련 기본값: `data-engine-hugepage-enabled={"v2":"true"}`, `data-engine-memory-size={"v2":"2048"}`, `data-engine-cpu-isolation-enabled={"v2":"true"}`, `engine-replica-timeout=8`, `node-down-pod-deletion-policy=delete-both-statefulset-and-deployment-pod`, `auto-delete-pod-when-volume-detached-unexpectedly=true`.

디스크 등록 (A 시험은 일부러 `/dev/sdc` 로 시작했다):

```bash
for n in ks-w1 ks-w2 ks-w3; do
  kubectl -n longhorn-system patch nodes.longhorn.io $n --type merge -p '{"spec":{"disks":{"v2-disk":{
    "path":"/dev/sdc","diskType":"block","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":[]}}}}'
done
```

## 5. 시험용 리소스

```bash
kubectl create ns v2test
kubectl apply -f v2test/sc-v2.yaml          # longhorn-v2-single(1벌, strict-local), longhorn-v2(3벌)
kubectl apply -f v2test/pg-v2.yaml          # 인스턴스 3, 동기 복제(any 1), 1벌 볼륨
kubectl apply -f v2test/pg-r3.yaml          # 인스턴스 2, 3벌 볼륨 (B2·B3 용: 옮겨 갈 빈 노드가 있다)
kubectl apply -f v2test/probe.yaml          # pg-v2 에 1초마다 -rw INSERT / -ro SELECT. ks-w1 고정
```

`probe2`(pg-r3 용)는 `probe.yaml` 에서 이름·노드(ks-w3)·서비스 이름만 바꿔 띄웠다:

```bash
sed -e 's/name: probe, /name: probe2, /' -e 's/nodeName: ks-w1/nodeName: ks-w3/' \
    -e 's/pg-v2-app/pg-r3-app/' -e 's/pg-v2-rw/pg-r3-rw/g' -e 's/pg-v2-ro/pg-r3-ro/g' v2test/probe.yaml | kubectl apply -f -
```

보조 스크립트:

| 파일 | 하는 일 |
|---|---|
| `state.sh <노드>` | 한 줄 상태: 노드 Ready, V2 디스크 Ready/경로/UUID, V2 볼륨, CNPG ready/primary, 파드. `CL`(클러스터), `VOLF`(볼륨 이름 필터) 환경 변수 |
| `watch.sh <노드> <최대 초> [끝 조건]` | `state.sh` 를 5초마다 돌려 바뀔 때만 출력 |
| `probe-report.sh [기간]` | 프로브 로그에서 쓰기/읽기 연속 실패 구간 추출. `PROBE=probe2` 로 다른 프로브 |

## 6. 디스크 이름 밀림 (A1~A7)

| 시험 | 명령 |
|---|---|
| A1 | `V2_NODES=… vagrant halt ks-w3; V2_NODES=… V2_NO_DUMMY=ks-w3 vagrant up ks-w3` 후 `watch.sh ks-w3 360` |
| A2 | `by-id` 찾기 → `path` 만 패치 (아래) |
| A3 | `V2_NODES=… vagrant halt ks-w3; V2_NODES=… vagrant up ks-w3` (dummy 다시 붙임) |
| A4 | `V2_NODES=… vagrant halt ks-w1; V2_NODES=… V2_SWAP=ks-w1 vagrant up ks-w1` |
| A5 | ks-w1 `path` 만 패치 |
| A6 | `kubectl -n longhorn-system delete pod <ks-w1 의 V2 instance-manager>` |
| A7 | 정상 노드 ks-w2 에서 `path` 만 패치, 3초 간격 INSERT 30번 |

`by-id` 찾기와 경로 교체:

```bash
W=$(ssh -F inventory/lab/ssh.cfg ks-w3 'for l in /dev/disk/by-id/wwn-*; do [ "$(readlink -f $l)" = /dev/sdb ] && echo $l; done')
kubectl -n longhorn-system patch nodes.longhorn.io ks-w3 --type merge -p "{\"spec\":{\"disks\":{\"v2-disk\":{\"path\":\"$W\"}}}}"
```

A4 뒤 빈 디스크에 쓰였는지 확인한 방법:

```bash
for d in sdb sdc; do echo "$d $(sudo head -c 8 /dev/$d | tr -dc '[:print:]') nonzero=$(sudo head -c 4194304 /dev/$d | tr -d '\000' | wc -c)"; done
# sdb SPDKBLOB nonzero=552   ← 원래 V2 디스크
# sdc          nonzero=0     ← 빈 디스크. 쓰이지 않았다
```

## 7. 노드 장애와 승격 (B1~B3, C1~C4, S1~S3)

| 시험 | 명령 | 그때 구성 |
|---|---|---|
| B1 | primary 노드 `vagrant halt --force`, 7분 뒤 `up` (프로브 전) | operator 1개 |
| B2·B3 | `v2test/b2.sh`: pg-r3-2 노드 강제 정지 → 13분 관찰 → `out-of-service` taint → 기동 후 taint 제거 | operator 1개 |
| C1 | `v2test/c1.sh`: pg-v2 primary 노드 강제 정지, 7분 관찰 | operator 1개(우연히 죽인 노드에 있었다) |
| C2 | `PROBE=probe2 v2test/c2.sh pg-r3 240` | operator 2개 (아래 4.1) |
| C3 | `PROBE=probe v2test/c2.sh pg-v2 240` | operator 2개, 리더가 죽인 노드에 있었다 |
| C4 | 판정 시간 20초로 바꾼 뒤 `v2test/c2.sh pg-v2 150` | operator 2개 |
| S1~S3 | 아래 switchover 패치 3번, 60초 간격 | operator 2개 |

operator 2개 (C2 부터):

```bash
helm repo update cnpg
helm upgrade cnpg cnpg/cloudnative-pg -n cnpg-system --version 0.29.1 --reuse-values -f v2test/cnpg-operator-ha.yaml --wait
```

노드 죽음 판정 40초 → 20초 (C4 만, 시험 뒤 되돌림):

```bash
for c in ks-cp1 ks-cp2 ks-cp3; do
  ssh -F inventory/lab/ssh.cfg $c 'sudo sed -i "s/--node-monitor-grace-period=40s/--node-monitor-grace-period=20s/" /etc/kubernetes/manifests/kube-controller-manager.yaml'
done
# 되돌리기: 20s → 40s 로 같은 명령. 영구 적용은 Kubespray 변수 kube_controller_node_monitor_grace_period
```

switchover (S1~S3). 실서버에서는 `kubectl cnpg promote <클러스터> <인스턴스>` 를 쓴다. 랩에서는 플러그인을 받지 않고 플러그인이 하는 것과 같은 status 패치를 했다:

```bash
T=<새 primary 로 만들 replica 이름>
kubectl -n v2test patch cluster pg-v2 --subresource=status --type merge -p "{\"status\":{
  \"targetPrimary\":\"$T\",\"targetPrimaryTimestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)\",
  \"phase\":\"Switchover in progress\",\"phaseReason\":\"Switching over to $T\"}}"
```

## 8. 결과 파일

| 파일 | 내용 |
|---|---|
| `results/boot.log` | VM 기동 시각 |
| `results/A1.log` ~ `A7.log` | 디스크 이름 밀림 시험. A1 에 오류 메시지 원문 |
| `results/B1.log`, `B2.log` | primary 노드 정지(프로브 전), 3벌 볼륨 13분 관찰 + taint |
| `results/k/K1.log` ~ `K13c.log`, `results/D1.log`, `E1.log` | 볼륨이 늦게 붙는 증상 케이스 시험. 설명은 [V2-DELAY-INVESTIGATION.md](../V2-DELAY-INVESTIGATION.md) |
| `results/C1.log` ~ `C4.log` | 승격 시험. 끝에 프로브 실패 구간(UTC) |
| `results/S1.log` | switchover 3번과 쓰기 실패 구간 |

로그의 시각은 KST, 프로브 구간만 UTC 다(9시간 차이). 같은 B2 이름으로 남은 첫 실행은 스크립트 종료 조건 실수로 노드가 30초만 꺼졌다 켜져 무효이고, `B2.log` 는 다시 돌린 것이다.

## 9. 정리

```bash
kubectl delete ns v2test
kubectl delete sc longhorn-v2 longhorn-v2-single
# V2 디스크를 Longhorn 노드에서 빼려면: allowScheduling=false → 복제본 0 확인 → spec.disks 에서 v2-disk 삭제
vagrant halt                                   # 다음에 켤 때도 워커 3대는 V2_NODES 를 붙인다
```
