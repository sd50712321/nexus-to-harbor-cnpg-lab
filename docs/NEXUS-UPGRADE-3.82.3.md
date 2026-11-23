# Nexus 3.82.0 → 3.82.3 올리기

운영 Nexus Repository(3.82.0 CE, 컨테이너)를 보안 패치 버전 3.82.3 으로 올리는 절차다. 앞부분은 랩에서 실제로 이미지를 바꿔 본 방법과 결과, 뒷부분은 운영에서 따라 할 순서다.

표기: **[랩 확인]** 은 랩에서 직접 해 본 것, **[공식]** 은 Sonatype·OpenJDK 문서에 적힌 것, **[미확인]** 은 해 보지 않은 것이다. 시험일은 2026-11-20 ~ 11-23 이다.

## 1. 결론

- 같은 데이터 볼륨을 그대로 물리고 **이미지 태그만 바꿔 띄우면 된다.** 별도 마이그레이션 명령은 없다. [랩 확인]
- **태그를 고를 때 함정이 하나 있다.** `3.82.0` 태그는 RHEL(UBI) 기반인데 `3.82.3` 태그는 Alpine 기반이다. 숫자만 바꾸면 기반 OS 가 통째로 바뀐다. 지금과 같은 기반을 유지하려면 `3.82.3-ubi` 를 쓴다(3절). [랩 확인]
- 올리는 이유는 Java 취약점 Java4Shell(CVE-2026-114938) 이다. 3.82.3 은 두 판 모두 기동 스크립트에서 취약 코드 경로를 끈다. Java 자체가 수정 버전으로 올라간 것은 Alpine 판뿐이다(3절). [랩 확인]
- 3.82.0 → 3.82.3 은 같은 3.82 안의 패치 버전이라 기능·한도·Groovy 스크립트 동작이 그대로다. [랩 확인]
- 3.82.3 이 쓴 데이터를 복원 없이 3.82.0 으로 다시 열어도 랩에서는 정상 동작했다(4절). 그래도 운영에서는 **올리기 전에 데이터 백업**을 떠 둔다. [랩 확인]

## 이미 `3.82.3` 태그로 올렸다면: 추가 확인 목록

`3.82.0` 에서 태그 숫자만 바꿔 `3.82.3` 으로 올리면 기반 OS 가 RHEL(UBI) 에서 Alpine 으로 바뀐다. 정상 기동했다면 `-ubi` 로 다시 바꿀 필요는 없다. Alpine 판은 Java 도 수정 버전이라 보안 면에서 더 낫고, UBI 로 만든 데이터를 그대로 읽는다(4절). 대신 기반이 바뀌면서 깨질 수 있는 아래 항목만 확인한다.

| # | 확인할 것 | 방법 | 정상 |
|---|---|---|---|
| 1 | Java4Shell 조치가 걸렸는지 | `podman exec <컨테이너> sh -c 'tr "\0" "\n" < /proc/1/cmdline \| grep BASE64'` | `-XX:-UseBASE64Intrinsics` 가 나온다 |
| 2 | Java 버전 | `podman exec <컨테이너> java -version` | `17.0.21.1` |
| 3 | 새 오류 로그 | `podman logs <컨테이너> 2>&1 \| grep ' ERROR '` | 올리기 전에 없던 줄이 없다 |
| 4 | 기존 이미지 pull, 새 태그 push | 클라이언트에서 한 번씩 | 둘 다 성공 |
| 5 | 밖으로 나가는 TLS 연결 | LDAPS 로그인, 프록시 리포지토리, 메일 발송을 쓰면 각각 한 번 | 성공. 실패하면 6번을 본다 |
| 6 | 사설 CA | 이전에 Java 인증서 저장소(`cacerts`)에 사설 CA 를 넣었거나 `/usr/lib/jvm/...` 아래로 파일을 마운트했는지 | Alpine 은 Java 경로가 `/usr/lib/jvm/java-17-openjdk`, 인증서 저장소가 `/etc/ssl/certs/java/cacerts` 로 다르다. 경로를 고쳐 다시 넣는다. Nexus UI 의 SSL Certificates 에 등록한 것은 `nexus-data` 에 있어 유지된다 |
| 7 | `bash` 를 부르는 것 | 헬스체크, 백업·운영 스크립트의 `podman exec ... bash` | Alpine 판에는 `bash` 가 없다. `sh` 로 바꾼다 |
| 8 | 이미지 안 파일을 고쳐 쓴 것 | 로그 보관 기간(`logback.xml`) 등 | 기본값으로 돌아갔으므로 다시 적용한다 |
| 9 | 등록해 둔 태스크·스크립트 | UI 의 Tasks, 스크립트 목록, 다음 예약 실행 결과 | 목록이 그대로이고 예약 실행이 성공한다 |
| 10 | 올리기 전 백업 | | 며칠 지켜본 뒤에 지운다 |

- 1·2·3·4·9 는 랩에서 Alpine 판으로 확인한 항목이다. [랩 확인] 5·6·7·8 은 운영 구성에 달린 것이라 랩에서 볼 수 없었다. [미확인]
- 문제가 생겨 되돌려야 하면 5-6 을 따른다. 랩에서는 복원 없이 이미지만 `3.82.0` 으로 되돌려도 정상 기동했다.

## 2. 왜 올리나

| 버전 | 출시 | 내용 [공식] |
|---|---|---|
| 3.82.1 | 2025-08-26 | `Repair - Reconcile component database from blob store` 태스크가 Azure blob store 리포지토리의 콘텐츠를 잘못 지울 수 있던 버그 수정 (NEXUS-48217) |
| 3.82.2 | 2026-10-28 | eMudhra 인증기관 침해 대응. 이미지에서 해당 루트 인증서 신뢰 제거 |
| 3.82.3 | 2026-11-19 | Java4Shell(CVE-2026-114938) 보안 조치 |

### Java4Shell (CVE-2026-114938)

- OpenJDK 17 이상의 Base64 디코더 메모리 오염 결함이다. 로그인 없이 원격 코드 실행까지 가능하다고 보고됐다. Oracle 평가 8.1(CVSS 3.1), 발견자 평가 9.2(CVSS 4.0). [공식]
- 성립 조건은 **x86-64 CPU 이면서 AVX-512 VBMI 명령어를 지원**하는 것이다. Java 11·8 은 해당 없다. [공식]
- 3.82.0 이미지의 Java 는 17.0.15 로 취약 대상이다. 3.82.3 이 이를 어떻게 막는지는 판마다 다르다(3절). [랩 확인]
- 랩은 ARM 이라 취약 조건이 안 된다. 실제 공격이 막히는지는 시험하지 못했다. [미확인]

### eMudhra 인증서 (CVE-2026-91403, CVE-2026-114820)

- eMudhra 중간 인증서 8개의 개인키가 유출돼, 그 상위 루트를 신뢰하는 Java 는 가짜 인증서를 정상으로 받아들일 수 있다. Nexus 가 **밖으로** TLS 연결을 할 때(프록시 리포지토리, LDAPS 등) 중간자가 있어야 성립한다. [공식]
- OpenJDK 가 제거하라고 안내한 루트 4개를 두 이미지에서 직접 대조했다. [랩 확인]

| 루트 인증서 | 3.82.0 | 3.82.3 |
|---|---|---|
| emSign ECC Root CA - G3 | 있음 | 제거됨 |
| Comodo AAA Services Root | 있음 | 제거됨 |
| emSign Root CA - G2 | 없음 | 없음 |
| emSign Root CA - G1 | 있음 | **남아 있음** |

- 위 표는 `3.82.3`(Alpine) 과 `3.82.3-ubi` 가 같다. 둘 다 emSign 계열은 G1 하나만 남아 있다. [랩 확인]
- 두 판 모두 Java 가 OS 의 시스템 인증서 묶음을 쓰고, 거기에 G1 이 들어 있다. 남은 이유와 실제 악용 가능 여부는 확인하지 못했다. [미확인]
- 외부로 나가는 TLS 연결이 없는 폐쇄망이면 영향이 낮다. 외부 연결을 쓴다면 7절의 추가 조치를 검토한다.

## 3. 어느 태그를 쓸 것인가

Docker Hub 의 3.82.3 은 두 가지 판이 있다. 두 이미지를 직접 열어 비교했다. [랩 확인]

| | `3.82.0` (현재) | `3.82.3-ubi` | `3.82.3` (= `3.82.3-alpine`) |
|---|---|---|---|
| 기반 OS | RHEL UBI 9.6 | RHEL UBI 9.9 | Alpine 3.24 |
| Java | 17.0.15 (Red Hat) | 17.0.21 (Red Hat, 2026-10-20) | 17.0.21.1+2 (Alpine, 2026-11-17) |
| Java4Shell 수정이 든 Java 인가 | 아니다 | **아니다** (공개 전 빌드) | 그렇다 (Temurin 공지의 수정 버전과 번호·빌드 동일) |
| 기동 스크립트의 `-XX:-UseBASE64Intrinsics` | 없음 | **있음** | **있음** |
| 실행 사용자 | uid 200 (nexus) | uid 200 | uid 200 |
| 진입점·포트·볼륨·환경변수 이름 | | 동일 | 동일 |
| `etc/` 기본 설정 파일 | | 3.82.0 과 내용 동일 | 3.82.0 과 내용 동일 |
| `bash` | 있음 | 있음 | **없음** (`sh` 만) |
| Java 설치 경로 | `/usr/lib/jvm/java-17-openjdk-17.0.15…` | `/usr/lib/jvm/java-17-openjdk-17.0.21…` | `/usr/lib/jvm/java-17-openjdk` |

- **두 판 모두** Nexus 기동 스크립트(`/opt/sonatype/nexus/bin/nexus`)가 `-XX:-UseBASE64Intrinsics` 를 넣는다. 실행 중인 JVM 의 명령줄에서 이 옵션이 실제로 걸린 것을 확인했다. Sonatype·Temurin 이 안내한 방식으로, 취약한 코드 경로를 끈다. [랩 확인]
- `3.82.3-ubi` 는 Java 버전이 수정 전 그대로라 **버전만 보는 보안 스캐너에는 계속 잡힌다.** Sonatype FAQ 도 이 경우를 설명한다. [공식]
- `3.82.3`(Alpine) 은 Java 도 수정 버전이고 옵션도 걸려 있다. 대신 기반 OS 가 바뀐다. 컨테이너 안에서 `bash` 를 부르는 스크립트, Java 설치 경로에 직접 마운트한 파일(사설 CA 를 넣은 `cacerts` 등)이 있으면 깨진다. [랩 확인: 차이 자체 / 미확인: 운영에 그런 것이 있는지]

고르는 기준:

- 변화를 최소로 하려면 **`3.82.3-ubi`**. 지금과 같은 기반이고 차이는 Java 소수점 버전과 기동 옵션 하나다.
- 스캐너·감사에서 Java 버전 자체가 올라가야 하면 **`3.82.3`**. 5-0 의 확인 항목을 먼저 본다.

현재 운영 이미지가 어느 기반인지는 `podman exec <컨테이너> cat /etc/os-release` 로 본다.

## 4. 랩에서 이미지를 어떻게 바꿨나

랩은 podman 으로 Nexus 를 띄운다. 3.82.0 을 빈 볼륨으로 띄워 리포지토리·이미지·스크립트를 만든 다음, 컨테이너만 지우고 같은 볼륨에 3.82.3 을 띄웠다.

```bash
# 1) 3.82.0 으로 기동 (볼륨 vt0 → /nexus-data)
podman run -d --name vt -p 127.0.0.1:8099:8081 -p 127.0.0.1:25099:5099 \
  -v vt0:/nexus-data \
  -e INSTALL4J_ADD_VM_PARAMS="-Xms2g -Xmx2g -XX:MaxDirectMemorySize=1g" \
  docker.io/sonatype/nexus3:3.82.0
#    → docker-hosted 리포지토리 생성, 이미지 push, Groovy 스크립트 등록

# 2) 정상 종료 후 컨테이너만 삭제 (볼륨은 남는다)
podman stop -t 60 vt
podman rm vt

# 3) 같은 볼륨, 같은 옵션, 태그만 3.82.3
podman run -d --name vt -p 127.0.0.1:8099:8081 -p 127.0.0.1:25099:5099 \
  -v vt0:/nexus-data \
  -e INSTALL4J_ADD_VM_PARAMS="-Xms2g -Xmx2g -XX:MaxDirectMemorySize=1g" \
  docker.io/sonatype/nexus3:3.82.3
```

결과 [랩 확인]:

| 확인 항목 | 결과 |
|---|---|
| 기동 | `Server: Nexus/3.82.3-01 (COMMUNITY)`, 기동 로그에 UPGRADE 단계가 자동으로 돌았다 |
| 로그의 ERROR 줄 | 0 |
| 리포지토리·태스크·스크립트 | 전부 유지 (리포지토리 8개, 태스크 7개, 스크립트 1개) |
| 3.82.0 때 올린 이미지 pull | 성공 |
| 새 태그 push | 성공 |
| 3.82.0 때 만든 Groovy 스크립트 실행 | HTTP 200, 결과 정상 |
| 사용 한도 | 컴포넌트 100,000 / 하루 요청 200,000 으로 동일 |

두 버전을 각각 빈 데이터로 띄워 비교한 것 [랩 확인]:

| 항목 | 3.82.0 | 3.82.3 |
|---|---|---|
| Java | 17.0.15 (Red Hat 빌드) | 17.0.21.1+2 (Alpine 빌드) |
| 이미지 안 nginx | 없음 | 없음 |
| CE 한도 | 100,000 / 200,000 | 동일 |
| 하루 요청 한도를 넘긴 뒤 | 유예 시작, pull·push 계속 됨 | 동일 |
| Groovy 스크립트 생성(기본 설정) | HTTP 410 (막힘) | 동일 |
| `nexus.scripts.allowCreation=true` 설정 후 | 생성 204, 실행 200 | 동일 |

### 판을 섞어 올리고 되돌리기

한 볼륨으로 3.82.0 → 3.82.3-ubi → 3.82.0 → 3.82.3(Alpine) 순서로 이미지만 바꿔 가며 띄웠다. 단계마다 raw 리포지토리에 파일을 하나씩 올리고, 앞 단계에서 올린 파일을 내려받았다. [랩 확인, 2026-11-23]

| 단계 | 기동 | ERROR 줄 | 앞 단계 파일 내려받기 | 새 파일 올리기 |
|---|---|---|---|---|
| 3.82.0 (빈 데이터) | 27초 | 호스트명 경고 1건 | | 성공 |
| → 3.82.3-ubi | 25초 | 호스트명 경고 1건 | 성공 | 성공 |
| → 3.82.0 (복원 없이 되돌림) | 25초 | 호스트명 경고 1건 + `Missing trigger for key` 1건 | 전부 성공 (3.82.3 에서 올린 것 포함) | 성공 |
| → 3.82.3 (Alpine) | 26초 | 0 | 전부 성공 | 성공 |

- 리포지토리 8개, 태스크 6개는 모든 단계에서 유지됐다.
- "호스트명 경고"는 `Failed to determine hostname, using nodeId instead` 로, 시험 컨테이너에 호스트명을 주지 않아 빈 데이터의 3.82.0 에서도 나온다. 업그레이드와 무관하다.
- 되돌렸을 때 나온 `Missing trigger for key` 는 스케줄러가 태스크 하나의 트리거를 못 찾았다는 뜻이다. 태스크 수는 그대로였고 그 뒤 동작에 문제는 없었다. 어떤 태스크였는지는 추적하지 않았다. [미확인]
- UBI 에서 만든 데이터를 Alpine 이 그대로 읽었다. 실행 사용자가 둘 다 uid 200 이라 파일 소유권 문제가 없다.

랩 시험의 한계: 데이터가 거의 없는 내장 DB(H2) 인스턴스로 한 번 했다. 데이터가 큰 인스턴스의 기동 시간, PostgreSQL 을 쓰는 구성은 보지 않았다. [미확인]

## 5. 운영 절차

명령은 podman 기준이다. docker 를 쓰면 `podman` 을 `docker` 로 바꾼다. `<...>` 는 환경에 맞게 채운다.

### 5-0. 사전 확인

```bash
# 현재 버전
curl -sI http://<nexus>:8081/service/rest/v1/status | grep -i '^server'

# 현재 컨테이너의 실행 옵션을 그대로 적어 둔다 (포트, 볼륨, 환경변수)
podman inspect <컨테이너> --format '{{.Config.Image}}{{"\n"}}{{.Config.Env}}{{"\n"}}{{.HostConfig.PortBindings}}{{"\n"}}{{.Mounts}}'

# 이 서버 CPU 가 Java4Shell 조건에 해당하는지 (0 이면 비해당)
grep -c avx512_vbmi /proc/cpuinfo

# 현재 이미지의 기반 OS (3절의 태그 선택에 쓴다)
podman exec <컨테이너> cat /etc/os-release | head -2

# 데이터 크기와 백업 받을 곳의 여유
du -sh <nexus-data 경로>; df -h <백업 경로>
```

이미지 안 파일을 직접 고친 것이 있으면 따로 적어 둔다. 대표적으로 로그 보관 기간(`logback.xml`)이다. 이미지를 바꾸면 기본값으로 돌아간다. `nexus-data` 안의 설정(`etc/nexus.properties` 등)은 유지된다.

Alpine 판(`3.82.3`)으로 갈 때는 추가로 본다: 컨테이너 안에서 `bash` 를 부르는 것(헬스체크, 운영 스크립트의 `exec ... bash`), `/usr/lib/jvm/...` 아래로 마운트한 파일. 있으면 `3.82.3-ubi` 를 쓰거나 그 부분을 먼저 고친다.

### 5-1. 이미지 반입

Nexus 자신이 레지스트리이므로, 새 이미지는 Nexus 를 거치지 않고 **서버에 직접 넣는다.**

```bash
# 인터넷 되는 곳에서 (운영 서버 아키텍처에 맞춰 받는다). 태그는 3절에서 고른 것: 3.82.3-ubi 또는 3.82.3
TAG=3.82.3-ubi
podman pull --platform linux/amd64 docker.io/sonatype/nexus3:$TAG
podman save -o nexus3-3.82.3.tar docker.io/sonatype/nexus3:$TAG
sha256sum nexus3-3.82.3.tar

# 운영 서버에서
sha256sum nexus3-3.82.3.tar        # 위 값과 같은지 확인
podman load -i nexus3-3.82.3.tar
podman images | grep nexus3
```

### 5-2. 정상 종료

```bash
podman stop -t 120 <컨테이너>
```

종료 대기를 넉넉히 준다. 강제 종료되면 내장 DB 가 손상될 수 있다. 이 시점부터 Nexus 를 쓰는 pull·push 가 전부 멈춘다.

### 5-3. 데이터 백업

멈춘 상태에서 `nexus-data` 를 통째로 복사한다. 랩에서는 복원 없이도 되돌아갔지만(4절), 데이터가 작은 인스턴스에서 한 번 본 것이라 운영에서는 백업을 기준으로 삼는다.

```bash
cp -a <nexus-data 경로> <백업 경로>/nexus-data-3.82.0-$(date +%Y%m%d)
```

데이터가 커서 통째 복사가 어렵다면 스토리지 스냅샷 등 다른 방법으로 **멈춘 상태의 사본**을 확보한다. 사본 없이 진행하지 않는다.

### 5-4. 태그만 바꿔 기동

5-0 에서 적어 둔 옵션을 그대로 쓰고 이미지 태그만 바꾼다.

```bash
podman rm <컨테이너>
podman run -d --name <컨테이너> <기존 포트·볼륨·환경변수 옵션 그대로> \
  docker.io/sonatype/nexus3:<고른 태그>
```

compose 로 띄운다면 이미지 태그만 고치고 `up -d` 한다.

### 5-5. 확인

```bash
# 버전
curl -sI http://<nexus>:8081/service/rest/v1/status | grep -i '^server'     # Nexus/3.82.3-01

# Java (ubi 판: 17.0.21 / Alpine 판: 17.0.21.1)
podman exec <컨테이너> java -version

# Java4Shell 조치가 실제로 걸렸는지: -XX:-UseBASE64Intrinsics 가 나와야 한다
podman exec <컨테이너> sh -c 'tr "\0" "\n" < /proc/1/cmdline | grep BASE64'

# 로그
podman logs <컨테이너> 2>&1 | grep ' ERROR '                                 # 올리기 전에 없던 줄이 생겼는지 본다
```

이어서 UI 로그인, 리포지토리 목록, 기존 이미지 pull 한 번, 새 태그 push 한 번, 등록해 둔 태스크·스크립트가 남아 있는지 본다. 5-0 에서 적어 둔 이미지 안 설정(logback 등)이 있었다면 다시 적용한다.

### 5-6. 되돌리기

```bash
podman stop -t 120 <컨테이너> && podman rm <컨테이너>
mv <nexus-data 경로> <nexus-data 경로>.failed
cp -a <백업 경로>/nexus-data-3.82.0-<날짜> <nexus-data 경로>
podman run -d --name <컨테이너> <기존 옵션 그대로> docker.io/sonatype/nexus3:3.82.0
```

백업을 복원하면 백업 이후에 push 된 것은 사라진다. 랩에서는 복원 없이 이미지만 3.82.0 으로 되돌려도 정상 기동했고 3.82.3 에서 올린 파일도 읽혔다(4절). 그 사이 올라온 것을 살려야 하면 이 방법을 먼저 시도하고, 안 되면 백업을 복원한다. [랩 확인: 소규모 1회]

## 6. 업그레이드가 늦어질 때의 임시 조치

Sonatype 안내 [공식]: JVM 옵션 `-XX:-UseBASE64Intrinsics` 를 주고 재시작한다. 컨테이너에서는 `INSTALL4J_ADD_VM_PARAMS` 에 넣는다. 이 변수를 이미 쓰고 있으면 기존 값 뒤에 덧붙인다.

```bash
-e INSTALL4J_ADD_VM_PARAMS="<기존 값> -XX:-UseBASE64Intrinsics"
```

취약한 코드 경로만 끄는 것이라 Java 버전은 그대로다. 보안 스캐너에는 계속 잡힐 수 있다. 3.82.3 이 기동 스크립트에서 하는 조치가 바로 이 옵션이다(3절). 3.82.0 에 이 옵션을 직접 준 상태의 동작은 랩에서 확인하지 않았다. [미확인]

## 7. 남는 것과 주의

- **emSign Root CA - G1**: 3.82.3 이미지에도 남아 있다(2절, 두 판 모두). Nexus 가 외부 TLS 연결을 쓴다면 OpenJDK 안내대로 `keytool -delete -cacerts -alias <별칭>` 으로 지울 수 있지만, 컨테이너 안 파일이라 컨테이너를 다시 만들면 되돌아간다. 이미지를 따로 만들거나 인증서 저장소를 마운트해야 유지된다. 이 조치는 랩에서 해 보지 않았다. [미확인]
- **3.98 계열로 가는 것은 별개 작업이다.** Groovy 실행이 기본으로 꺼지는 등 동작이 달라진다. 이 문서의 절차를 그대로 쓰지 않는다.
- **Sonatype 의 Java4Shell FAQ** 가 나열한 조치 버전에는 3.92 이상만 있고 3.82.3 은 없다. 3.82.3 이 조치 버전이라는 근거는 3.82 릴리스 노트와 이미지 안의 Java 버전이다.
- CE 한도를 넘긴 뒤 유예 기간이 **끝난 다음**의 동작은 이번 시험에서 보지 않았다. 유예 전·중·후 기록은 [NEXUS-CE-LIMIT-3.82.md](NEXUS-CE-LIMIT-3.82.md) 에 있다.

## 8. 출처

- Sonatype Nexus Repository 3.82.0 - 3.82.3 Release Notes: https://help.sonatype.com/en/sonatype-nexus-repository-3-82-0-release-notes.html
- Sonatype, Java4Shell FAQ for Sonatype Products: https://support.sonatype.com/hc/en-us/articles/57683907326355-Java4Shell-FAQ-for-Sonatype-Products
- Sonatype, Critical OpenJDK RCE CVE-2026-114938: https://www.sonatype.com/blog/critical-openjdk-rce-cve-2026-114938-what-to-know
- Eclipse Temurin guidance for CVE-2026-114938: https://adoptium.net/news/2026/11/temurin-november-2026-cspu-java4shell
- OpenJDK, Compromised Certificates and OpenJDK Java Runtimes: https://openjdk.org/emudhra
- Red Hat, CVE-2026-91403: https://access.redhat.com/security/cve/cve-2026-91403
