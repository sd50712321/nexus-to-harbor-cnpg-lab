# VM 위의 Longhorn V2: 공개된 알려진 문제 모음

Longhorn V2(SPDK) 를 VM 위에서 돌릴 때 겪는 장애(파드 멈춤, 노드 굳음, `spdk_tgt` 사망)와 관련해 공개 자료를 모은 것이다. 조사일은 2026-11-26 이고, 대상은 Longhorn GitHub 이슈, Longhorn·Harvester 공식 문서와 KB, Broadcom(VMware) KB 다.

## 1. 결론

- **"Longhorn + vMotion"을 직접 다룬 공개 사례는 찾지 못했다.**
- **"리액터가 코어를 잡아서 노드가 굳는다"는 것은 SUSE 가 KB 로 낸 알려진 문제다.** 기본 설정이 CPU 0·1 을 잡고, 그 코어의 커널 작업이 굶는다. 설정만 바꿔서 해결한 실사례가 있다(2절).
- **`spdk_tgt` 가 죽는 버그 여러 건이 1.12.2 에서 고쳐졌다**(3절). 대부분 재구축 전후에 난다.
- **VMware 는 정지에 민감한 VM 을 DRS 에서 빼거나 호스트에 고정하라고 권한다**(4절). vMotion 의 정지 목표는 0.5초다.

이 문서에서 "자료에 적힌 것"과 "우리 환경에 대한 추론"은 구분해서 적었다. 추론은 5절에만 있다.

## 2. 리액터가 코어를 잡는 문제

SPDK 의 리액터 스레드는 일이 없어도 맡은 코어를 100% 쓴다(폴링 모드). 어느 코어를 쓸지는 `data-engine-cpu-mask` 설정이 정한다. `0x3` 은 CPU 0·1, `0xC` 는 CPU 2·3 이다.

| 자료 | 내용 |
|---|---|
| [Harvester KB: Longhorn V2 Data Engine Kernel Workqueue Lockup](https://harvesterhci.io/kb/longhorn-v2-workqueue-lockup/) (2026-07-27) | 리액터가 코어를 다 쓰는 동안 같은 코어의 인터럽트·커널 작업이 굶는다. 커널 로그에 `BUG: workqueue lockup` 이 반복되고, kubelet·Longhorn 이 멈추고, `sudo -i` 조차 느려진다. "주로 베어메탈 노드"라고 적혀 있다 |
| [longhorn#13237](https://github.com/longhorn/longhorn/issues/13237) | 1.12.0 에서 기본 mask 가 `0x1` → `0x3` 으로 바뀌었다. 리액터 하나로는 관리 요청(gRPC)이 밀려 타임아웃이 났기 때문이다 |
| [longhorn#14035](https://github.com/longhorn/longhorn/issues/14035) | 1.12.1 실사례. `0x3` 은 CPU0 을 포함하는데, CPU0 은 부팅 코어이고 인터럽트와 주기적 커널 작업이 몰린다. mask 만 `0xC` 로 옮기자 CPU0 사용률이 99.5% → 6.9%, lockup 이 반복 → 0 이 됐다. 기본값 변경 요청은 받아들여지지 않았다(wontfix) |
| [longhorn#13417](https://github.com/longhorn/longhorn/issues/13417) | `data-engine-cpu-isolation-enabled` 설정 추가(1.13.0). 인터럽트와 커널 작업 큐를 리액터 코어 밖으로 옮긴다. #14036 에는 1.12.1 에 백포트됐다고 적혀 있다 |
| [longhorn#14036](https://github.com/longhorn/longhorn/issues/14036) | 위 설정의 한계. 코어에 묶인(per-CPU) 커널 작업은 어떤 설정으로도 못 옮긴다. 완화책이지 구조적 해결이 아니다 |
| [longhorn#13248](https://github.com/longhorn/longhorn/issues/13248) | kubelet CPU Manager(static)로 리액터 코어를 전용 배정하는 방식(`data-engine-number-of-cpu-cores`, 1.13.0). 다른 파드가 그 코어에 못 올라온다 |
| [longhorn#14190](https://github.com/longhorn/longhorn/issues/14190), [#14632](https://github.com/longhorn/longhorn/issues/14632) | 1.12.2·1.13.1 부터 mask 의 가장 낮은 코어를 관리용 리액터 전용으로 떼어 둔다. 2코어 mask 면 I/O 는 1코어만 처리한다 |
| [인터럽트 모드 문서 (1.12.1)](https://longhorn.io/docs/1.12.1/advanced-resources/v2-data-engine/interrupt-mode/) | 폴링을 하지 않아 코어를 잡지 않는 모드. 1.10 부터 있다. V2 볼륨이 하나도 붙어 있지 않을 때만 바꿀 수 있다 |
| [longhorn#14378](https://github.com/longhorn/longhorn/issues/14378) (미수정), [#14095](https://github.com/longhorn/longhorn/issues/14095) | 인터럽트 모드에서 I/O 가 조용히 멈추거나 `spdk_tgt` 가 죽은 사례 |
| [longhorn#14485](https://github.com/longhorn/longhorn/issues/14485) | 1.14.0 에서 인터럽트 모드를 기본값으로 바꿀 예정 |

KB 가 적은 추가 사실 두 가지.

- V2 볼륨이 하나도 붙어 있지 않아도 리액터는 코어를 다 쓴다.
- mask 를 바꿔도 V2 인스턴스 매니저 파드가 다시 만들어지기 전에는 적용되지 않는다.

## 3. `spdk_tgt` 가 죽거나 I/O 가 멈추는 버그

`spdk_tgt` 가 죽으면 그 노드의 V2 볼륨이 전부 내려간다.

| 이슈 | 내용 | 수정 |
|---|---|---|
| [#14411](https://github.com/longhorn/longhorn/issues/14411) | 재구축을 마무리하는 중 assertion 으로 죽는다. `dmsetup suspend` 가 30초를 넘기면 "멈춤 없이 진행"한 뒤 발생 | 닫힘 |
| [#14353](https://github.com/longhorn/longhorn/issues/14353) | extent page 경합으로 assertion 사망 | 닫힘 |
| [#14482](https://github.com/longhorn/longhorn/issues/14482) | 재구축 전후에 `double free or corruption (fasttop)` 으로 죽는다. 재구축 I/O 가 몰려 메모리 요청이 밀릴 때 난다 | 1.12.2, 1.13.1 |
| [#14344](https://github.com/longhorn/longhorn/issues/14344) | 디스크 복구 실패로 V2 인스턴스 매니저가 죽는다 | 1.12.2, 1.13.1 |
| [#14399](https://github.com/longhorn/longhorn/issues/14399) | 볼륨 여러 개가 동시에 붙을 때 죽는다 | 1.12.2, 1.13.1 |
| [#14474](https://github.com/longhorn/longhorn/issues/14474) | 스냅샷 삭제가 실패하거나 중간에 끊기면 데이터가 깨지거나, 죽거나, 디스크를 못 읽게 된다 | 미수정 (1.14.0 예정) |
| [#14458](https://github.com/longhorn/longhorn/issues/14458) | 볼륨은 `healthy` 인데 워크로드가 I/O 오류를 받는다. 커널 로그에 `failed to send request -13`, 약 15초 뒤 `failfast expired` | 미수정 |
| [#13215](https://github.com/longhorn/longhorn/issues/13215) | 인스턴스 매니저가 재시작된 뒤 볼륨이 `Degraded` 에 머문다 | 닫힘 |
| [#13404](https://github.com/longhorn/longhorn/issues/13404) | SPDK 의 비정상 종료 대비를 보강하는 묶음 작업 | 진행 중 |

## 4. vMotion (Broadcom 공식)

| 자료 | 내용 |
|---|---|
| [KB 407273: Sensitive Virtual Machines become impacted by vMotion stun time](https://knowledge.broadcom.com/external/article/407273/sensitive-virtual-machines-become-impact.html) | 이동 중 VM 이 잠깐 정지한다. 대부분은 영향이 없지만 DB 같은 민감한 애플리케이션은 죽거나 성능 저하가 남을 수 있다. 권고는 **DRS 에서 제외하거나 affinity 규칙으로 호스트에 고정**하는 것이다 |
| [KB 436882: How to identify vMotion stun time](https://knowledge.broadcom.com/external/article/436882/how-to-identify-vmotion-stun-time.html) | 정지 목표는 500ms. 실제 값은 ESXi `hostd.log` 에서 본다. 출발 호스트의 `Migrate: VM starting stun...` 시각, 도착 호스트의 `vmDowntime`(마이크로초). 호스트 사이 왕복 지연(`vmotionRTT`)이 10ms 를 넘으면 정지가 크게 길어진다 |

## 5. 우리 환경에 대한 추론

여기부터는 자료에 적힌 것이 아니라 추론이다.

- **vMotion 의 정지 자체는 방아쇠로 약하다.** 공식 목표가 0.5초이고, 랩에서 워커 VM 을 통째로 멈췄을 때 15초까지는 복제본이 떨어지지 않았다.
- **더 그럴듯한 그림은 리액터가 CPU 0·1 을 잡아 평소에도 여유가 없는 노드에 vMotion 이 겹치는 것이다.** VM 에서는 하이퍼바이저가 vCPU 를 빼앗는 시간이 더해지므로 2절의 굶주림이 베어메탈보다 심할 수 있다. 이 연결을 확인한 공개 자료는 없다.
- **재구축이 위험 구간이다.** 3절의 사망 버그 대부분이 재구축 전후에 나고, 랩에서도 굳은 dm 과 데이터 불일치가 재구축 중에 나왔다.

## 6. 확인 명령 (읽기만 한다)

운영 네임스페이스는 `longhorn`, 랩은 `longhorn-system` 이다.

```
journalctl -k | grep -E "workqueue lockup|soft lockup"
kubectl -n longhorn get settings.longhorn.io data-engine-cpu-mask
kubectl -n longhorn get settings.longhorn.io data-engine-cpu-isolation-enabled
kubectl -n longhorn get settings.longhorn.io data-engine-interrupt-mode-enabled
nproc
```

| 본 것 | 뜻 |
|---|---|
| `workqueue lockup - pool cpus=0`(또는 mask 에 든 다른 코어) | 2절의 문제 그대로다 |
| mask 가 `0x3` 이고 `nproc` 이 4 이하 | 코어의 절반 이상을 리액터가 가져갔다 |
| 설정 이름이 없다고 나옴 | 그 버전에 해당 설정이 없다 |

리액터가 실제로 밀려나는지는 스레드의 비자발적 문맥 전환 수로 본다. 10초 간격으로 두 번 보고 빠르게 늘면 밀려나고 있다.

```
pgrep -a spdk_tgt
ps -T -p <spdk_tgt pid> -o tid,psr,pcpu,comm
grep nonvoluntary /proc/<리액터 tid>/status
```

vMotion 정지 시간은 인프라에 KB 436882 를 주고, 사고 시각의 `vmDowntime` 을 요청한다.

## 7. 조치 후보

| 순서 | 조치 | 근거 | 주의 |
|---|---|---|---|
| 1 | mask 를 CPU0 을 피한 코어로 옮긴다 (예: `0xC`) | #14035 | vCPU 가 4개 이상이어야 한다. 인스턴스 매니저가 다시 만들어져야 적용된다 |
| 2 | `data-engine-cpu-isolation-enabled` 를 켠다 | #13417, Harvester KB | 완화책이다(#14036). 운영 버전에 설정이 있는지 먼저 확인한다 |
| 3 | 1.12.2 로 올린다 | #14482, #14344, #14399 | V2 는 무중단 업그레이드가 안 된다 |
| 4 | 워커 VM 을 DRS 에서 제외하거나 호스트에 고정한다 | Broadcom KB 407273 | 호스트 정비 때는 수동으로 옮겨야 한다 |

1~3 은 V2 볼륨을 내리거나 인스턴스 매니저가 재시작되므로 정비 시간에 한다. 인터럽트 모드는 미수정 버그(#14378)가 있어 1.12 에서는 권하지 않는다.

## 8. 찾지 못한 것

- vMotion 과 Longhorn 장애를 직접 연결한 공개 보고.
- VM 위에서 2절의 workqueue lockup 이 난 공개 보고(KB 는 베어메탈 기준).
- 랩에서 한 번 본 "재구축 중 데이터 불일치"와 같은 증상의 보고.
