# Nexus 3.82.0-08 CE — 하루 20만 요청을 넘겼을 때 pull/push 가 되는가 (유예 전·중·후 실측)

질문: "기한 안내(유예 종료일) 전까지는 20만 요청을 넘어도 pull·push 가 되는가?"
답: **된다.** 그리고 유예가 끝난 뒤에도 "그날 20만을 넘긴 상태" 에서만 새 컴포넌트 push 와 프록시 신규 캐시가 막히고, 기존 pull 은 계속 된다. 다음 날 요청 수가 한도 아래로 내려가면 push 도 다시 된다.

근거: 랩 nexus2 (3.82.0-08 COMMUNITY, H2) 에 2026-10-02 처음 21만 건을 넣은 뒤 **매시간** 4가지 동작을 자동 기록(`logs/periodic/checks.tsv`, 793행, 10-02 → 11-04). 부하(21만 GET, oha) 는 10-02·10-03·10-04·10-07·10-31·11-01 에만 넣었다. CE 한도를 우회하는 조작(시계·DB·코드)은 하지 않았다.

## 1. 타임라인

| 시각(UTC) | 그날 요청 수 | 상태 | 기존 pull | 새 push(hosted) | 프록시 신규 캐시 | UI 상태값 |
|---|---|---|---|---|---|---|
| 10-02 01:44 | 0 | 평시 | 성공 | 성공 | 성공 | 판정 없음 |
| 10-02 02:01 | 210,956 | **첫 초과 판정** (`UsageTracker.trackUsageLimitsExceeded`) | 성공 | 성공 | 성공 | `gracePeriodEnds = 2026-11-01T02:01:00` (판정 +30일) |
| 10-03 ~ 10-30 | 한도 아래/위 반복 | 유예 중 | 성공 | 성공 | 성공 | 유예 종료일 **변하지 않음** (10-05·06 한도 아래로 내려갔다 10-07 재초과해도 동일) |
| 10-31 01:05 ~ 11-01 01:05 | 210,840 | 유예 마지막 날, 한도 초과 | 성공 | 성공 | 성공 | `throttlingStatus = Over limits` |
| **11-01 02:05** | 210,932 | **유예 종료 + 한도 초과** | **성공** | **실패 403** `PAYMENT REQUIRED` | **실패** (`manifest unknown` 으로 보임) | `grace_period_status = ENDED` |
| 11-01 03:05 ~ 11-02 00:05 | 210,608~210,986 | 유예 종료 + 초과 지속 | 성공 | 실패 403 | 실패 | 동일 |
| **11-02 01:05** | 590 | 유예 종료, **한도 아래** | 성공 | **성공** | **성공** | `throttlingStatus = Under limits` |
| 11-02 ~ 11-05 | 400~840 | 유예 종료, 한도 아래 | 성공 | 성공 | 성공 | 동일 (11-05 수동 재확인: 새 push 성공, 유예 중 push 된 태그 pull 성공) |

"그날 요청 수" 는 `content_request_count.last_24h` (= `/repository/*` 요청 전부, 401 포함; docs/NEXUS-HARBOR.md 2절).

## 2. 막힐 때의 실제 응답

- hosted push: blob 업로드 시작 `POST /v2/<repo>/blobs/uploads/` 가 **HTTP 403**, 본문:
  `PAYMENT REQUIRED: At current usage levels, Sonatype Nexus Repository Community Edition requires a paid license to publish or cache new components. Contact your repository administrator to resolve. INSTANCE ID: …`
  nexus.log 에는 `com.sonatype.nexus.community.analytics.handler.ThrottlingContributedHandler - PAYMENT REQUIRED: …` WARN. REST 업로드(`POST /service/rest/v1/components`)는 **402**.
- 프록시(docker-proxy)로 상류에 새로 생긴 이미지 pull: 클라이언트에는 `manifest unknown` 으로 보인다. "cache new components" 가 막힌 것이라 이미 캐시된 것은 계속 나간다.
- 기존 컴포넌트 pull(hosted·proxy 캐시): 막히지 않았다. `blocked_requests_count`·`throttled_requests` 게이지는 끝까지 0 (이 게이지는 다른 용도).

## 3. 상태를 읽는 곳 (3.82)

| 값 | 위치 |
|---|---|
| 한도 수치 | UI 상태 `nexus.community.usageLimits` = `{"Total Components":100000,"Max Requests per 24 Hours":200000}` (`POST /service/extdirect/poll/rapture_State_get`) |
| 유예 종료일 | `nexus.community.gracePeriodEnds` (첫 판정 +30일) |
| 지금 초과 여부 | `nexus.community.throttlingStatus` = `Under limits` / `Over limits` |
| 마지막 초과일 | `nexus.community.requestPer24HoursLimitDateLastExceeded` |
| 유예 상태 | `/service/rest/metrics/data` → `nexus.analytics.grace_period_status` (`""` → `ENDED`) |
| 그날 요청 수 | 같은 곳 `content_request_count.last_24h` / UI `usage-metrics` 의 `requests_per_last_24h` |

주의: 초과 **판정은 즉시가 아니다.** 부하 뒤 카운터가 0 으로 보이다가 매시 01분 집계 때 반영됐다(10-02 01:16 부하 끝 → 02:01 판정). 유예 종료 시각도 그 판정 시각 기준이다.

## 4. 운영에 옮길 성질

- 유예 30일 동안은 넘겨도 아무것도 안 막힌다. 유예 종료일은 **처음 넘긴 날 +30일로 고정**되고, 중간에 한도 아래로 내려가도 당겨지거나 리셋되지 않는다.
- 유예가 끝난 뒤의 제재는 "그날 20만 초과" 와 결합해서만 작동한다. 넘긴 날은 push·신규 캐시가 막히고, 다음 날 24시간 창이 내려가면 자동으로 풀린다. 즉 **pull 만 하는 소비자는 영향이 없고, CI push 와 처음 당기는 퍼블릭 이미지가 그날 깨진다.**
- 따라서 20만 가까운 운영이라면 "유예 안내 전" 보다 "유예 끝난 뒤 넘기는 날" 이 문제다. 노드 캐시(Spegel)·digest 참조·익명 pull 로 요청 수를 줄이고, 6차 스크립트로 어느 대역이 요청을 만드는지 본다.
- 랩은 H2 단일 인스턴스, 부하는 manifest GET 뿐이다. 수치(판정 지연 ~45분, 집계 매시 01분) 는 랩 값이고, "무엇이 막히고 무엇이 안 막히나" 가 전이 대상이다.
- 이 문서의 모든 동작은 CE 정상 경로에서 관측한 것이다. 한도·유예를 우회하는 방법은 다루지 않는다.

## 5. 원본
- `~/nexus-lab/logs/periodic/checks.tsv` (매시 기록), `burst.log` (부하 일자), `e3-*/e4-*.err` (실패 원문), `scratch/periodic.sh` (기록 스크립트)
- `~/nexus-lab/logs/load382/summary.txt` (10-02 첫 초과 당일)
- nexus2 `nexus-2026-11-01.log.gz` PAYMENT REQUIRED 92건, `request-2026-11-01.log.gz` 403/402
