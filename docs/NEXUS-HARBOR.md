# Nexus ↔ Harbor 상호운용 실측 정리 (Nexus 3.82 CE · Harbor 2.14, 2026-11-05)

Nexus 는 남기고 커스텀 이미지·차트만 Harbor 로 옮기는 구성에서, 두 시스템이 서로를 어떻게 볼 수 있는지와 Nexus CE 카운터에 무엇이 영향을 주는지를 랩에서 잰 결과만 모았다. 수치는 2VM 랩 값이고 성질(되는가/안 되는가, 왜)이 전이 대상이다. 원문 로그: `~/nexus-lab/logs/reqlog/`, `~/nexus-lab/logs/harbor-nexus-proxy/`. README 의 6차·7차 절과 부록 H·I 가 같은 내용의 긴 판이다.

## 1. 한눈에

| 질문 | 답 | 근거 |
|---|---|---|
| Harbor 가 Nexus 를 proxy cache 상류로 볼 수 있나 | **된다** — 범용 `docker-registry` 어댑터로 Nexus docker-hosted(커넥터 포트) 등록 | ping 200, 노드 `crictl`·skopeo·`helm pull oci://` 전부 성공, digest 동일 |
| Harbor 가 Nexus 에서 pull 복제(replication) 할 수 있나 | **된다** — 같은 엔드포인트, name/tag 필터 | `dlops/app1` 1.0·1.1 → `nexus-repl/app1` Succeed |
| Nexus `helm-hosted`(index.yaml 방식) 차트를 Harbor 가 끌어올 수 있나 | **안 된다** — Harbor 어댑터는 전부 OCI 레지스트리, 차트 저장소 어댑터 없음(2.8 에서 ChartMuseum 과 함께 제거) | 어댑터 목록: ali-acr, aws-ecr, azure-acr, docker-hub, docker-registry, github-ghcr, google-gcr, harbor, huawei-SWR, jfrog-artifactory, tencent-tcr, volcengine-cr |
| Nexus docker-hosted 에 OCI 로 올린 차트는 | **된다** (이미지와 동일 경로) | `oci://harbor.lab/nexus-proxy/dlops/ocicharts/h27a:0.1.0` pull OK, CHART 로 캐시 |
| schema1(v1 매니페스트) 이미지는 | Nexus·Harbor 저장/프록시/복제 전부 됨. **노드 containerd 2.x 가 pull 거부** → 변환 필요 | 아래 4절 |
| Harbor 프록시를 두면 Nexus 카운터가 주나 | **태그 pull 은 안 준다**(첫 pull 3배, 반복 동률). digest pull 만 0 | 아래 3절 |
| Nexus 카운터는 정확히 무엇을 세나 | `/repository/` 로 시작하는 요청 전부, 상태코드 무관(401 포함). REST·UI·Jetty 거부 요청 제외 | 로그 집계와 버킷 단위로 1:1 일치 |

## 2. Nexus request.log 로 카운터 귀속 (누가·어느 대역이·무엇을)

- 파일: `<data>/log/request.log` + `request-YYYY-MM-DD.log.gz` (90일 보관, 트래픽 없는 날은 파일 없음).
- 포맷(기본 `jetty-requestlog.xml`): `IP - user [시각] "METHOD PATH HTTP" STATUS 요청Content-Length 보낸바이트 소요ms "UA" [thread]`. 7열 경로, 10열 업로드 바이트, 11열 다운로드 바이트. docker 커넥터 포트 요청도 `/repository/<repo>/v2/...` 로 찍힌다.
- IP 열은 **X-Forwarded-For 맨 앞 값**(3.82 기본 `ForwardedRequestCustomizer`). 프록시 뒤면 실제 클라이언트가 보이고, 직접 접근이 열려 있으면 위조 가능.
- 카운터 대조 (`/service/rest/metrics/data` → `nexus.analytics.content_request_count.hour[시]`):

| 버킷 | 카운터 | 로그 `/repository/*` | 로그 전체 | 제외된 것 |
|---|---|---|---|---|
| 11-04 00시 | 6164 | 6164 | 8024 | `/badMessage` 400 1799(skopeo 가 https 먼저 시도한 흔적), REST 61 |
| 11-04 14시 | 18 | 18 | 21 | badMessage 3 |
| 11월 합계 | 10426 | 10426 | | |

- docker pull 1회 = `/v2/`(401) + token + manifest + blob×N 이 각각 1건. 랩 00시 버킷은 핸드셰이크가 60%.
- 카운터는 DB 에 남아 재시작을 넘긴다. `hour[]` 는 hour-of-day 버킷, `last_24h` 는 24 버킷 합.
- 스크립트 `tools/nexus-reqlog-report.sh` (bash+gzip+awk+sort, busybox awk·mawk 확인): IP·/24 대역·저장소·IP×저장소·컴포넌트(이미지/디렉터리)·push 이벤트·시간대·UA·상태·카운터 대조. `-i 대역접두 -r 저장소 -a UA정규식 -s/-u 시각 -S 섹션`.

```bash
L=/nexus-data/log; cat_all(){ for f in $L/request-*.log.gz $L/request.log; do [ -f "$f" ] && gzip -dcf "$f"; done; }
cat_all | awk '$7 ~ /^\/repository\// {c[substr($4,2,14)]++} END{for(h in c) print h, c[h]}' | sort        # 카운터가 세는 것만 시간대별
cat_all | awk '{split($1,o,"."); s=o[1]"."o[2]"."o[3]".0/24"; c[s]++; b[s]+=($11=="-"?0:$11)} END{for(s in c) printf "%d\t%.1f MB\t%s\n", c[s], b[s]/1e6, s}' | sort -nr   # 대역별
cat_all | awk '$7 ~ /\/v2\/.*\/(blobs|manifests)\// {n=$7; sub(/^\/repository\//,"",n); sub(/\/v2\//," ",n); sub(/\/(blobs|manifests)\/.*/,"",n); b[n]+=($11=="-"?0:$11)} END{for(k in b) printf "%.1f MB\t%s\n", b[k]/1e6, k}' | sort -nr | head   # 이미지별 전송량
```
macOS 는 `zcat` 대신 `gzip -dcf`. 로그 시각은 Nexus 프로세스 TZ.

## 3. Harbor → Nexus 상류 (proxy cache / 복제)

등록: `POST /api/v2.0/registries` `{type: docker-registry, url: http://<nexus docker 커넥터>, insecure, basic 자격}` → proxy 프로젝트에 `registry_id` 지정. 랩은 Harbor(k8s)가 Mac 의 nexus6 에 닿도록 socat 으로 172.16.141.1:35601 → 127.0.0.1:35600 중계.

캐시에 없던 blob 2개짜리 `dlops/scale01:v1` 로 Nexus 요청 수(= 카운터 증가)를 깨끗하게 측정:

| 시나리오 | Nexus 요청 | 내역 |
|---|---|---|
| 직접 pull(skopeo → Nexus) | 5 | 401, token, manifest, blob×2 |
| 프록시 첫 pull(태그) | **15** | 401×3, token×6 (요청마다 토큰 재발급), manifest HEAD+GET, **blob×4 — 스트리밍용 1회 + 캐시용 1회** |
| 프록시 두 번째 pull(태그) | **5** | 401, token×2, manifest HEAD+GET. blob 만 캐시 |
| 프록시 pull(digest 지정) | **0** | |
| 상류 차단 + 캐시된 태그 | 성공 | schema1 포함 |
| 상류 차단 + 없는 태그 | 실패 `unknown: repository` | |

- Nexus 로그에서 Harbor 는 UA `Go-http-client/1.1`(인증 핸드셰이크) + `harbor-registry-client`(데이터) 로 보인다. socat 때문에 IP 는 podman 게이트웨이.
- 캐시 적재 조건: blob 까지 받은 pull. 매니페스트만 읽은 `inspect` 나 노드에 레이어가 이미 있던 pull 은 아티팩트를 안 남겼다. 적재는 pull 후 ~15초 지연.
- 복제: `dest_namespace_replace_count: 1` 이면 `dlops/app1` → `nexus-repl/app1` 로 첫 조각이 바뀐다. 이름 필터 없이 걸면 Nexus `_catalog` + 태그 목록 요청이 전부 카운트된다.
- 결론: Harbor 프록시는 **바이트는 줄이지만 요청 수는 못 줄인다**. 카운터를 줄이려면 digest 고정 참조나 노드 캐시(Spegel)가 앞에 있어야 한다. 점검 중 캐시 태그 유지 용도로는 유효.
- 반대 방향(Nexus docker-proxy → Harbor)은 Nexus truststore 에 CA 등록(재시작)이 필요해 이번엔 안 했다.

## 4. schema1(v1 매니페스트) 이미지

fixture `dlops/legacy:s1` (`application/vnd.docker.distribution.manifest.v1+prettyjws`, digest 569cfaaa…).

| 경로 | 결과 |
|---|---|
| Nexus → Harbor 직접 push, `--preserve-digests`, **같은 경로** `dlops/legacy:s1` | 성공, Harbor 가 주는 digest 569cfaaa… **동일** |
| 직접 push, **다른 이름** `dlops/legacy-direct:s1` | `--preserve-digests` 는 거부("embedded Docker reference … would change the manifest"), 기본 모드는 성공하되 digest 957324b4… 로 바뀜 — schema1 은 매니페스트 안에 name/tag 가 박혀 있어 이름이 바뀌면 재서명 |
| Harbor proxy cache 경유 pull | 성공, v1+prettyjws 그대로 캐시, digest 동일 |
| Harbor pull 복제 → `nexus-repl/legacy:s1` | Succeed, digest 동일(복제는 바이트 그대로 복사) |
| **노드 containerd 2.2.1 `crictl pull`** | **거부** `schema 1 image manifests are no longer supported` (공개 프로젝트에서 확인, 자격 문제 아님) |
| `skopeo copy --format oci` 로 변환해 push (`dlops/legacy:s1-oci`) | OCI 매니페스트로 저장, 노드 pull 성공 |

결론: 저장소 쪽(Nexus·Harbor)은 schema1 을 다 받아 주므로 이관은 통과하지만 **노드에서 못 쓴다**. 이관 전에 schema1 목록을 뽑아(`skopeo inspect --raw … | jq .schemaVersion`) OCI/schema2 로 변환해 다시 태그하거나 폐기해야 하고, 변환하면 digest 가 바뀌니 digest 고정 참조를 함께 고친다. Nexus 가 지금도 schema1 push 를 받으므로 구식 docker 로 push 하는 CI 가 남아 있는지도 같이 본다.

## 5. 랩 상태
- 남김: Harbor 엔드포인트 `nexus6-docker`, 프로젝트 `nexus-proxy`(public)·`nexus-repl`, 정책 `nexus6-pull-app1`·`nexus6-pull-legacy`, `dlops/legacy-direct:s1`·`dlops/legacy:s1-oci`, Mac socat(재부팅 시 사라짐 → 엔드포인트 unhealthy).
- 되돌리기: `pkill -f 'socat TCP-LISTEN:35601'`, Harbor 에서 정책·프로젝트·엔드포인트 삭제(승인 후).
