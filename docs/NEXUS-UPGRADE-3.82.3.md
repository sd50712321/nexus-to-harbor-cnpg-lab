# Nexus 3.82.0 → 3.82.3 올리기

운영 Nexus Repository(3.82.0 CE, 컨테이너)를 보안 패치 버전 3.82.3 으로 올리는 절차다. 앞부분은 랩에서 실제로 이미지를 바꿔 본 방법과 결과, 뒷부분은 운영에서 따라 할 순서다.

표기: **[랩 확인]** 은 랩에서 직접 해 본 것, **[공식]** 은 Sonatype·OpenJDK 문서에 적힌 것, **[미확인]** 은 해 보지 않은 것이다. 시험일은 2026-11-20 ~ 11-23 이다.

## 1. 결론

- 같은 데이터 볼륨을 그대로 물리고 **이미지 태그만 3.82.3 으로 바꿔 띄우면 된다.** 별도 마이그레이션 명령은 없다. [랩 확인]
- 올리는 이유는 Java 취약점 Java4Shell(CVE-2026-114938) 이다. 3.82.3 이미지에는 수정된 Java 가 들어 있다.
- 3.82.0 → 3.82.3 은 같은 3.82 안의 패치 버전이라 기능·한도·Groovy 스크립트 동작이 그대로다. [랩 확인]
- 되돌릴 수단은 **올리기 전에 떠 둔 데이터 백업**이다. 3.82.3 이 쓴 데이터를 3.82.0 으로 다시 여는 시험은 하지 않았다. [미확인]

## 2. 왜 올리나

| 버전 | 출시 | 내용 [공식] |
|---|---|---|
| 3.82.1 | 2025-08-26 | `Repair - Reconcile component database from blob store` 태스크가 Azure blob store 리포지토리의 콘텐츠를 잘못 지울 수 있던 버그 수정 (NEXUS-48217) |
| 3.82.2 | 2026-10-28 | eMudhra 인증기관 침해 대응. 이미지에서 해당 루트 인증서 신뢰 제거 |
| 3.82.3 | 2026-11-19 | Java4Shell(CVE-2026-114938) 보안 조치 |

### Java4Shell (CVE-2026-114938)

- OpenJDK 17 이상의 Base64 디코더 메모리 오염 결함이다. 로그인 없이 원격 코드 실행까지 가능하다고 보고됐다. Oracle 평가 8.1(CVSS 3.1), 발견자 평가 9.2(CVSS 4.0). [공식]
- 성립 조건은 **x86-64 CPU 이면서 AVX-512 VBMI 명령어를 지원**하는 것이다. Java 11·8 은 해당 없다. [공식]
- 3.82.0 이미지의 Java 는 17.0.15 로 취약 대상이고, 3.82.3 이미지는 `17.0.21.1+2` 로 수정 버전과 번호·빌드가 같다. [랩 확인] 수정 버전 번호는 Eclipse Temurin 공지 기준이다(JDK 17.0.21.1+2). 이미지에 든 것은 Alpine 배포판 빌드이며 Alpine 쪽 공지는 따로 확인하지 않았다.
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

- 3.82.3 의 Java 는 Alpine 시스템 인증서 묶음(`ca-certificates` 20261020)을 쓰고, 거기에 G1 이 들어 있다. 남은 이유와 실제 악용 가능 여부는 확인하지 못했다. [미확인]
- 외부로 나가는 TLS 연결이 없는 폐쇄망이면 영향이 낮다. 외부 연결을 쓴다면 6절의 추가 조치를 검토한다.

## 3. 랩에서 이미지를 어떻게 바꿨나

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

랩 시험의 한계: 데이터가 거의 없는 내장 DB(H2) 인스턴스로 한 번 했다. 데이터가 큰 인스턴스의 기동 시간, PostgreSQL 을 쓰는 구성은 보지 않았다. [미확인]

## 4. 운영 절차

명령은 podman 기준이다. docker 를 쓰면 `podman` 을 `docker` 로 바꾼다. `<...>` 는 환경에 맞게 채운다.

### 4-0. 사전 확인

```bash
# 현재 버전
curl -sI http://<nexus>:8081/service/rest/v1/status | grep -i '^server'

# 현재 컨테이너의 실행 옵션을 그대로 적어 둔다 (포트, 볼륨, 환경변수)
podman inspect <컨테이너> --format '{{.Config.Image}}{{"\n"}}{{.Config.Env}}{{"\n"}}{{.HostConfig.PortBindings}}{{"\n"}}{{.Mounts}}'

# 이 서버 CPU 가 Java4Shell 조건에 해당하는지 (0 이면 비해당)
grep -c avx512_vbmi /proc/cpuinfo

# 데이터 크기와 백업 받을 곳의 여유
du -sh <nexus-data 경로>; df -h <백업 경로>
```

이미지 안 파일을 직접 고친 것이 있으면 따로 적어 둔다. 대표적으로 로그 보관 기간(`logback.xml`)이다. 이미지를 바꾸면 기본값으로 돌아간다. `nexus-data` 안의 설정(`etc/nexus.properties` 등)은 유지된다.

### 4-1. 이미지 반입

Nexus 자신이 레지스트리이므로, 새 이미지는 Nexus 를 거치지 않고 **서버에 직접 넣는다.**

```bash
# 인터넷 되는 곳에서 (운영 서버 아키텍처에 맞춰 받는다)
podman pull --platform linux/amd64 docker.io/sonatype/nexus3:3.82.3
podman save -o nexus3-3.82.3.tar docker.io/sonatype/nexus3:3.82.3
sha256sum nexus3-3.82.3.tar

# 운영 서버에서
sha256sum nexus3-3.82.3.tar        # 위 값과 같은지 확인
podman load -i nexus3-3.82.3.tar
podman images | grep nexus3
```

### 4-2. 정상 종료

```bash
podman stop -t 120 <컨테이너>
```

종료 대기를 넉넉히 준다. 강제 종료되면 내장 DB 가 손상될 수 있다. 이 시점부터 Nexus 를 쓰는 pull·push 가 전부 멈춘다.

### 4-3. 데이터 백업

멈춘 상태에서 `nexus-data` 를 통째로 복사한다. 이것이 유일한 롤백 수단이다.

```bash
cp -a <nexus-data 경로> <백업 경로>/nexus-data-3.82.0-$(date +%Y%m%d)
```

데이터가 커서 통째 복사가 어렵다면 스토리지 스냅샷 등 다른 방법으로 **멈춘 상태의 사본**을 확보한다. 사본 없이 진행하지 않는다.

### 4-4. 태그만 바꿔 기동

4-0 에서 적어 둔 옵션을 그대로 쓰고 이미지 태그만 바꾼다.

```bash
podman rm <컨테이너>
podman run -d --name <컨테이너> <기존 포트·볼륨·환경변수 옵션 그대로> \
  docker.io/sonatype/nexus3:3.82.3
```

compose 로 띄운다면 이미지 태그만 `3.82.3` 으로 고치고 `up -d` 한다.

### 4-5. 확인

```bash
# 버전
curl -sI http://<nexus>:8081/service/rest/v1/status | grep -i '^server'     # Nexus/3.82.3-01

# Java
podman exec <컨테이너> java -version                                         # 17.0.21.1

# 로그
podman logs <컨테이너> 2>&1 | grep -c ' ERROR '                              # 0 이어야 한다
```

이어서 UI 로그인, 리포지토리 목록, 기존 이미지 pull 한 번, 새 태그 push 한 번, 등록해 둔 태스크·스크립트가 남아 있는지 본다. 4-0 에서 적어 둔 이미지 안 설정(logback 등)이 있었다면 다시 적용한다.

### 4-6. 되돌리기

```bash
podman stop -t 120 <컨테이너> && podman rm <컨테이너>
mv <nexus-data 경로> <nexus-data 경로>.failed
cp -a <백업 경로>/nexus-data-3.82.0-<날짜> <nexus-data 경로>
podman run -d --name <컨테이너> <기존 옵션 그대로> docker.io/sonatype/nexus3:3.82.0
```

백업 이후에 push 된 것은 사라진다. 3.82.3 이 쓴 데이터를 복원 없이 3.82.0 으로 여는 것은 시험하지 않았다. [미확인]

## 5. 업그레이드가 늦어질 때의 임시 조치

Sonatype 안내 [공식]: JVM 옵션 `-XX:-UseBASE64Intrinsics` 를 주고 재시작한다. 컨테이너에서는 `INSTALL4J_ADD_VM_PARAMS` 에 넣는다. 이 변수를 이미 쓰고 있으면 기존 값 뒤에 덧붙인다.

```bash
-e INSTALL4J_ADD_VM_PARAMS="<기존 값> -XX:-UseBASE64Intrinsics"
```

취약한 코드 경로만 끄는 것이라 Java 버전은 그대로다. 보안 스캐너에는 계속 잡힐 수 있다. 랩에서 이 옵션을 준 상태의 동작은 확인하지 않았다. [미확인]

## 6. 남는 것과 주의

- **emSign Root CA - G1**: 3.82.3 이미지에도 남아 있다(2절). Nexus 가 외부 TLS 연결을 쓴다면 OpenJDK 안내대로 `keytool -delete -cacerts -alias <별칭>` 으로 지울 수 있지만, 컨테이너 안 파일이라 컨테이너를 다시 만들면 되돌아간다. 이미지를 따로 만들거나 인증서 저장소를 마운트해야 유지된다. 이 조치는 랩에서 해 보지 않았다. [미확인]
- **3.98 계열로 가는 것은 별개 작업이다.** Groovy 실행이 기본으로 꺼지는 등 동작이 달라진다. 이 문서의 절차를 그대로 쓰지 않는다.
- **Sonatype 의 Java4Shell FAQ** 가 나열한 조치 버전에는 3.92 이상만 있고 3.82.3 은 없다. 3.82.3 이 조치 버전이라는 근거는 3.82 릴리스 노트와 이미지 안의 Java 버전이다.
- CE 한도를 넘긴 뒤 유예 기간이 **끝난 다음**의 동작은 이번 시험에서 보지 않았다. 유예 전·중·후 기록은 [NEXUS-CE-LIMIT-3.82.md](NEXUS-CE-LIMIT-3.82.md) 에 있다.

## 7. 출처

- Sonatype Nexus Repository 3.82.0 - 3.82.3 Release Notes: https://help.sonatype.com/en/sonatype-nexus-repository-3-82-0-release-notes.html
- Sonatype, Java4Shell FAQ for Sonatype Products: https://support.sonatype.com/hc/en-us/articles/57683907326355-Java4Shell-FAQ-for-Sonatype-Products
- Sonatype, Critical OpenJDK RCE CVE-2026-114938: https://www.sonatype.com/blog/critical-openjdk-rce-cve-2026-114938-what-to-know
- Eclipse Temurin guidance for CVE-2026-114938: https://adoptium.net/news/2026/11/temurin-november-2026-cspu-java4shell
- OpenJDK, Compromised Certificates and OpenJDK Java Runtimes: https://openjdk.org/emudhra
- Red Hat, CVE-2026-91403: https://access.redhat.com/security/cve/cve-2026-91403
