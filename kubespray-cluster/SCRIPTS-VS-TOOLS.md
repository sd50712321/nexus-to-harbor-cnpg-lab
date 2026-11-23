# 직접 만든 스크립트와 기성 도구: 무엇을 바꿀 수 있고 무엇이 남는가

이 리포에는 시험·설치용으로 직접 만든 셸·파이썬 스크립트가 71개 있다. 직접 만든 스크립트로 잰 수치는 "스크립트가 맞는가"부터 의심받는다. 그래서 각 스크립트를 공개된 기성 도구로 바꿀 수 있는지 분류했다.

**결론: 71개 중 49개는 기성 도구로 바꾸거나 없앨 수 있다. 남겨야 하는 것은 22개이고, 전부 Longhorn V2 장애를 재현하는 스크립트다.**

> **근거 수준.** 2026-11-23 기준 분류다. 스크립트 쪽은 각 파일의 용도를 보고 나눴다. 대체 도구 쪽은 각 프로젝트의 리포·문서에서 해당 기능이 있는 것까지 확인했고, **실제로 바꿔서 돌려 본 것은 없다.** 폐쇄망 반입 가능 여부, 현재 버전(Harbor 2.14/2.15, Longhorn 1.12, CNPG 1.30)과의 호환은 돌려 봐야 안다.

## 1. 바꾸거나 없앨 수 있는 것 (49개)

| 묶음 | 개수 | 해당 파일 | 대체 |
|---|---|---|---|
| 성능 측정 | 8 | `perf/*.sh` 7개, `perf/mkimage.py` | 2절 |
| 설치·구성 | 6 | `install.sh`, `reset.sh`, `scripts/10-cluster.sh`, `20-addons.sh`, `addon.sh`, `render-values.sh` | `ansible-playbook`(Kubespray), `helm` 을 직접 실행. 순서 관리가 필요하면 Helmfile |
| V2 노드 준비 | 1 | `scripts/v2-node-prep.sh` | Longhorn 공식 CLI: `longhornctl install preflight` |
| 기동 검증 | 1 | `scripts/30-verify.sh` | `cilium connectivity test`, `longhornctl check preflight`, `kubectl cnpg status`, Sonobuoy |
| 노드·파드 장애 | 12 | `scripts/40-failover.sh`, `50-more-tests.sh`, `60-db-node-loss.sh`, `61-db-move-instance.sh`, `62-ingress-failover.sh`, `v2test/b2.sh`, `c1.sh`, `c2.sh`, `d1.sh`, `e1.sh`, `move.sh`, `w-prep.sh` | Chaos Mesh 또는 LitmusChaos. VM 전원 끄기는 LitmusChaos 의 VMware 실험(`vm-poweroff`) |
| 상태 관찰 | 11 | `v2test/watch.sh`, `allwatch.sh`, `bigwatch.sh`, `diskwatch.sh`, `nodewatch.sh`, `recwatch.sh`, `state.sh`, `t1-snap.sh`, `u-snap.sh`, `u1-cpu.sh`, `probe-report.sh` | `kubectl get -w`, Prometheus + Grafana (Longhorn·CNPG 가 메트릭을 낸다) |
| V2 단순 장애 | 2 | `v2test/t-spdk-kill.sh`, `u-blackhole.sh` | Chaos Mesh 의 PodChaos(컨테이너 종료), NetworkChaos |
| 랩 전용 | 7 | `scripts/00-inventory.sh`, `lab-proxy.sh`, `rolling-reload.sh`, `v2-disks.sh`, `make-bundle.sh`, `harbor-env.sh`, `v2test/lh-reinstall.sh` | 대체 불필요. Vagrant·맥 환경 처리라 운영에 가지 않는다 |
| Nexus 로그 집계 | 1 | `tools/nexus-reqlog-report.sh` | GoAccess. IP·건수·바이트 집계는 되고, 저장소별 집계는 안 된다 |

주의:

- **장애 주입 도구를 들이면 설치물이 하나 늘어난다.** Chaos Mesh·LitmusChaos 는 클러스터에 컨트롤러와 노드별 데몬을 설치한다. 폐쇄망에서는 이미지 반입과 그 도구 자체의 검증이 따라온다. 장애 시험을 계속 반복할 계획이 아니면 지금 스크립트를 유지하는 쪽이 부담이 적다.
- **`t-spdk-kill.sh` 의 대체는 완전히 같지 않다.** Chaos Mesh 는 컨테이너를 죽이고, 이 스크립트는 인스턴스 매니저 컨테이너 **안의 `spdk_tgt` 프로세스 하나**를 죽인다. 실서버 증상에 더 가까운 것은 후자다.
- **상태 관찰을 메트릭으로 옮기면 "바뀐 시각"의 해상도가 떨어진다.** 스크립트는 1초 이하 간격으로 보고, Prometheus 는 보통 15~30초 간격이다. 초 단위 중단 시간을 재는 시험에는 맞지 않는다.

## 2. 성능 측정의 대체 (스크립트 없이 명령만)

| 재는 것 | 지금 | 대체 | 만든 곳 |
|---|---|---|---|
| Harbor API·push·pull | `harbor-bench.sh` (skopeo + oha), `mkimage.py` | `go run mage.go prepare` → `go run mage.go` | Harbor 프로젝트 ([goharbor/perf](https://github.com/goharbor/perf), k6 + xk6-harbor) |
| PostgreSQL 처리량·지연 | `pgbench.sh`, `cnpg-suite.sh` | `kubectl cnpg pgbench <클러스터> -- --time 60 --client 8` | CNPG 공식 플러그인. pgbench Job 을 만들어 준다 |
| DB 볼륨 속도 | `cnpg-suite.sh` 의 `pg_test_fsync` | `kubectl cnpg fio <이름> --storageClass <SC>` | CNPG 공식 플러그인 |
| Longhorn 볼륨 속도 | `fio-all.sh` + `fio.yaml` | kbench 의 `fio.yaml` 을 `kubectl apply` | [yasker/kbench](https://github.com/yasker/kbench) (Longhorn 개발자) |
| 볼륨 첫 마운트 시간 | `attach-time.sh` | 기성 도구 없음. PVC 와 파드를 만들고 이벤트 시각을 읽는다 | |
| 부하 중 계획 전환 | `switchover-load.sh`, `harbor-switchover.sh` | 터미널 두 개에서 손으로: 부하 명령 + `kubectl cnpg promote <클러스터> <인스턴스>` | |

goharbor/perf 를 쓸 때 알아둘 것:

- **시험용 Harbor 에만 쓴다.** `prepare` 가 프로젝트·사용자·아티팩트를 대량으로 만든다.
- **반입물이 있다.** Go 툴체인, Go 모듈, k6 바이너리.
- **k6 바이너리(xk6-harbor)는 amd64 만 배포된다.** ARM 에서는 직접 빌드해야 한다.
- **갱신이 느리다.** goharbor/perf 마지막 변경 2025-12, xk6-harbor 2024-06. 현재 Harbor 버전에서 시나리오가 전부 도는지는 미확인이다.

`kubectl cnpg` 플러그인은 랩에 설치돼 있지 않아 위 명령을 돌려 보지 못했다. 명령 형식은 CNPG 문서의 Benchmarking 장 기준이다.

## 3. 남겨야 하는 것 (22개)

기성 도구에 해당 기능이 없다. 모두 `v2test/` 아래에 있고, 각 20~50줄이며, 안에서 부르는 것은 `dmsetup`, `kill`, `kubectl`, cgroup 파일 쓰기 같은 OS·쿠버네티스 기본 명령이다.

### 3-1. 볼륨 장치(dm)를 멈춘 상태를 만드는 것 — 5개

`k13.sh`, `k13c.sh`, `u4-orphan.sh`, `w1-suspend-healthy.sh`, `w2-suspend-timeout.sh`

실서버 증상(굳은 dm)의 직접 재현이다. `dmsetup suspend` 를 특정 시점(파드 삭제 직전, 마운트 직전, 스냅샷 요청 직전)에 거는 일은 어떤 장애 주입 도구도 지원하지 않는다.

### 3-2. "살아 있지만 느린" 저장소를 만드는 것 — 4개

`w3-slow-suspend.sh`, `w3b-cpu-throttle.sh`, `w4-rebuild-suspend.sh`, `k12.sh`

`spdk_tgt` 프로세스 하나를 골라 SIGSTOP/SIGCONT 로 멈췄다 풀거나, 그 컨테이너의 cgroup(`cpu.max`, `io.max`)을 조인다. Chaos Mesh 의 IOChaos 는 파일시스템 볼륨에 지연을 넣는 방식이라 SPDK 가 직접 잡는 블록 장치에는 걸리지 않는다. StressChaos 는 부하를 더하는 것이고 특정 프로세스의 할당을 줄이는 것이 아니다.

### 3-3. 부팅 직후 상태를 조작하는 것 — 3개

`k7.sh`, `k10.sh`, `k11b.sh`

hugepage 없이 kubelet 이 뜨는 경우, 시계가 틀린 채 부팅하는 경우다. 노드 부팅 순서에 끼어드는 일이라 클러스터 안에서 도는 도구로는 못 한다. Chaos Mesh 의 TimeChaos 는 지정한 프로세스의 시계만 바꾸고 노드 시계는 그대로 둔다.

### 3-4. 여러 단계를 정해진 시점에 엮는 것 — 7개

`x1-im-during-rebuild.sh`, `x2-pg-create-im-restart.sh`, `y1-random-kill.sh`, `y3-upgrade-under-load.sh`, `u5-im-restart.sh`, `u6-pv-cycle.sh`, `y-lib.sh`

"재구축이 도는 중에 인스턴스 매니저를 내린다", "CNPG 가 볼륨을 연달아 떼고 붙이는 중에 재시작한다"처럼 Longhorn 내부 상태를 보고 다음 동작을 정하는 순서다. `y-lib.sh` 에는 시험 뒤 PostgreSQL 데이터가 온전한지 보는 검사(pgbench 잔액 합계 대조, `amcheck`, 복제 상태)가 들어 있다.

### 3-5. dm 상태를 보는 것 — 2개

`dm-audit.sh`, `u-dmwatch.sh`

dm 이 Suspended 인지, 붙어 있지 않은데 남았는지(고아)는 Longhorn 메트릭에도 node-exporter 에도 없다. 실서버 점검([V2-PROD-RUNBOOK.md](V2-PROD-RUNBOOK.md) 3절)에도 같은 방법을 쓴다.

### 3-6. 보안 에이전트 흉내 — 1개

`v2test/fan.py`

파일 열기를 가로채는 감시 에이전트(fanotify 허가형)가 원인인지 보려는 것이다. 실제 에이전트 제품을 랩에 설치할 수 없어서 만들었다.

## 4. 어떻게 읽을 것인가

- **성능 수치와 일반 장애 시험은 기성 도구로 옮길 수 있다.** 결과를 다른 사람에게 설명할 때 근거가 되는 부분이 이쪽이다. 우선순위는 Harbor(goharbor/perf), PostgreSQL(`kubectl cnpg pgbench`), 스토리지(kbench) 순이다.
- **남는 22개는 도구가 아니라 실험 절차의 기록이다.** "어떤 순서로 무엇을 했더니 실서버와 같은 상태가 됐다"를 그대로 다시 할 수 있게 적어 둔 것이다. 수치의 신뢰가 아니라 재현 여부가 목적이다.
- **대체한다고 기존 결과가 틀렸다는 뜻은 아니다.** 기존 성능 시험([PERF-TEST.md](PERF-TEST.md))도 측정 자체는 pgbench·fio·skopeo·oha 가 했고, 스크립트는 그 명령들을 순서대로 불렀다. 대체의 이점은 시나리오까지 남이 만든 것이 된다는 점이다.

## 5. 참고한 프로젝트

| 도구 | 리포 | 라이선스 | 마지막 변경 (2026-11-23 조회) |
|---|---|---|---|
| goharbor/perf | https://github.com/goharbor/perf | Apache-2.0 | 2025-12 |
| k6 | https://github.com/grafana/k6 | AGPL-3.0 | 2026-11 |
| CNPG 플러그인 (`kubectl cnpg`) | https://github.com/cloudnative-pg/cloudnative-pg (`docs/src/benchmarking.md`) | Apache-2.0 | 2026-11 |
| kbench | https://github.com/yasker/kbench | Apache-2.0 | 2024-10 |
| longhornctl | https://github.com/longhorn/cli | Apache-2.0 | 2026-11 |
| Chaos Mesh | https://github.com/chaos-mesh/chaos-mesh | Apache-2.0 | 2026-11 |
| LitmusChaos | https://github.com/litmuschaos/litmus | Apache-2.0 | 2026-11 |
| Sonobuoy | https://github.com/vmware-tanzu/sonobuoy | Apache-2.0 | 2026-11 |
| cilium-cli | https://github.com/cilium/cilium-cli | Apache-2.0 | 2026-11 |
| Helmfile | https://github.com/helmfile/helmfile | MIT | 2026-11 |
| GoAccess | https://github.com/allinurl/goaccess | MIT | 2026-11 |
