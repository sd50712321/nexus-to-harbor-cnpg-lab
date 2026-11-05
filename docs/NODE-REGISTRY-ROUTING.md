# 노드 레지스트리 라우팅 반영 절차 — 퍼블릭 = Nexus, 사내 빌드 = Harbor

클러스터 워크로드가 두 레지스트리를 쓰되 **매니페스트를 쓰는 사람은 구분하지 않게** 만드는 절차다. 원리는 하나: 이미지 참조의 첫 조각(레지스트리 호스트)을 containerd 가 `/etc/containerd/certs.d/<호스트>/hosts.toml` 로 찾아 거기 적힌 곳으로 보낸다. 사내 이미지는 CI 가 Harbor 에 push 하는 순간 이름이 `harbor.example.internal/...` 로 정해지고, 퍼블릭 이미지는 업스트림 이름 그대로 적되 `hosts.toml` 이 Nexus 로 보낸다. Spegel 없이 쓴다. (Spegel 을 넣으면 같은 파일을 Spegel 이 이어받는다.)

랩 근거(2026-11-05, containerd 2.2.1): 가짜 호스트 `nexus-test.internal/dlops/scale02:v1` 에 `hosts.toml` 로 Nexus 를 지정하니 pull 성공, Nexus request.log 에 `UA=containerd/2.2.1` 로 token·HEAD/GET manifest 가 찍힘. 파일을 지우자 같은 pull 이 DNS 단계에서 실패. containerd 상류 소스 확인 결과 `hosts.toml` 에 **경로 재작성(rewrite) 기능은 없다** (`override_path` 만 있음) → 상류 간 경로 충돌은 Nexus 쪽에서 저장소를 나눠 푼다.

---

## 0. 반영 전에 확정할 것

| 항목 | 선택지 | 권고 |
|---|---|---|
| Nexus 저장소 구조 | A. docker-group 1개(포트 1개)에 상류별 hosted/proxy 묶음 / B. 상류 호스트별 저장소 + 커넥터 포트 분리 | 경로 충돌 점검(1-2) 결과 충돌 없으면 A, 있으면 충돌 상류만 B |
| Nexus 익명 pull | 허용 / 비허용 | **허용**(퍼블릭 미러). 비허용이면 모든 Pod(시스템 포함)에 imagePullSecrets 가 필요하고, pull 당 Nexus 요청도 2건 늘어난다(`/v2/` 401 + token) |
| TLS | 사내 CA 인증서 (Nexus·Harbor 둘 다) | 노드 OS 신뢰 저장소에 CA 배포. `hosts.toml` 의 `ca =` 는 보조 |
| Harbor 비공개 프로젝트 인증 | 로봇 계정 + imagePullSecrets | 네임스페이스별 Secret, 5차 `harbor-robot` 방식 |
| 배포 수단 | Ansible 등 노드 구성 도구 / DaemonSet(hostPath) | 이미 노드 구성 도구가 있으면 그것. 없으면 DaemonSet |

## 1. Nexus 준비

1-1. 저장소: 반입 이미지는 상류 호스트별 docker-hosted 로 넣는다(`docker-io-hosted`, `quay-io-hosted`, `ghcr-io-hosted`, `k8s-io-hosted`…). 폐쇄망에 상류로 가는 길이 있으면 같은 이름의 docker-proxy. 이들을 `docker-public` group 으로 묶고 커넥터 포트(예 5000) 를 group 에만 연다.

1-2. **경로 충돌 점검** (group 은 멤버 순서상 먼저 맞는 저장소를 주므로, 같은 경로가 두 저장소에 있으면 한쪽이 가려진다):
```bash
NX=https://nexus.example.internal; A='user:pass'
for r in docker-io-hosted quay-io-hosted ghcr-io-hosted k8s-io-hosted; do
  python3 - "$NX" "$A" "$r" <<'EOF2' > /tmp/paths.$r
import sys,json,urllib.request,base64
b,a,repo=sys.argv[1:4]; h={'Authorization':'Basic '+base64.b64encode(a.encode()).decode()}; tok=None
while True:
    d=json.load(urllib.request.urlopen(urllib.request.Request(f"{b}/service/rest/v1/components?repository={repo}"+(f"&continuationToken={tok}" if tok else ""),headers=h)))
    for c in d['items']: print(c['name'])
    tok=d.get('continuationToken')
    if not tok: break
EOF2
done
sort /tmp/paths.* | uniq -d          # 출력이 있으면 충돌 → 그 상류는 B(별도 포트)로
```

1-3. 익명 pull: Security → Anonymous Access 활성 + `nx-anonymous` 에 해당 저장소 read 권한. 커넥터 포트의 "Allow anonymous docker pull" 체크. 확인:
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://nexus.example.internal:5000/v2/   # 200 이면 익명 OK, 401 이면 미허용
```

1-4. 반입 경로 규칙: 반입 스테이션에서 `skopeo copy docker://docker.io/library/nginx:1.27 docker://nexus:5000/library/nginx:1.27` 처럼 **상류 경로를 그대로 보존**해서 넣는다(`docker.io/library/nginx` → `library/nginx`). 이름을 바꾸면 매니페스트의 참조와 어긋나 라우팅이 깨진다. schema1 이미지는 `--format oci` 로 변환해서 넣는다(노드 containerd 2.x 가 거부, docs/NEXUS-HARBOR.md 4절).

## 2. Harbor 준비
- 프로젝트(팀 단위), 로봇 계정(pull 전용), Trivy·불변 태그·보존 정책은 5차 그대로.
- `externalURL` 은 노드가 쓰는 이름과 같아야 한다(`https://harbor.example.internal`). 포트 443 권고 — 참조에 포트가 붙지 않는다.
- CI 러너는 Harbor 로만 push 하도록 자격을 준다. Nexus docker-hosted 에는 CI 쓰기 권한을 주지 않는다(사내 이미지가 Nexus 로 새는 경로 차단).

## 3. CA 배포 (노드 전체, 1회)
```bash
# Ubuntu/Debian
sudo cp corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt && sudo update-ca-certificates
# RHEL 계열
sudo cp corp-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
# 확인 (둘 다 "Verify return code: 0")
openssl s_client -connect nexus.example.internal:5000 -servername nexus.example.internal </dev/null 2>/dev/null | grep 'Verify return'
openssl s_client -connect harbor.example.internal:443  -servername harbor.example.internal  </dev/null 2>/dev/null | grep 'Verify return'
```
containerd 는 OS 신뢰 저장소를 쓴다. 재시작 불필요(다음 pull 부터 적용).

## 4. hosts.toml 작성

4-1. containerd 설정 확인(2.x 기본값. 1.x 는 아래 줄을 넣고 1회 재시작):
```bash
sudo grep -n "config_path" /etc/containerd/config.toml      # config_path = '/etc/containerd/certs.d'
containerd --version
```

4-2. 패턴 A (group 1포트) — 상류 호스트마다 디렉터리, 내용 동일:
```bash
for h in docker.io quay.io ghcr.io registry.k8s.io public.ecr.aws; do
  sudo mkdir -p /etc/containerd/certs.d/$h
  sudo tee /etc/containerd/certs.d/$h/hosts.toml >/dev/null <<'EOF2'
server = "https://nexus.example.internal:5000"

[host."https://nexus.example.internal:5000"]
  capabilities = ["pull", "resolve"]
EOF2
done
```
`server` 를 업스트림 원본(`https://registry-1.docker.io`)으로 두면 미러 실패 시 인터넷으로 나가려다 DNS 에서 실패한다. 폐쇄망에선 **server 도 Nexus 로** 두어 "마지막 시도" 까지 사내에 머물게 하는 편이 로그가 깨끗하다.

4-3. 패턴 B (충돌 상류만 별도 포트):
```toml
# /etc/containerd/certs.d/quay.io/hosts.toml
server = "https://nexus.example.internal:5001"
[host."https://nexus.example.internal:5001"]
  capabilities = ["pull", "resolve"]
```

4-4. Harbor:
```toml
# /etc/containerd/certs.d/harbor.example.internal/hosts.toml
server = "https://harbor.example.internal"
```
CA 가 OS 에 있으면 이 파일은 없어도 된다(이름 그대로 직행). 두는 이유는 나중에 미러(Spegel 등)를 끼울 자리를 만들어 두는 것.

4-5. 문법 주의: 호스트 키는 따옴표 포함 `[host."https://..."]`; `capabilities` 에 `resolve` 가 없으면 태그 해석을 미러에서 못 해 server 로 간다; `push` 는 넣지 않는다; TOML 오류는 containerd 가 조용히 무시하고 server 로 가므로 5절 검증을 반드시 한다. 디렉터리 이름은 참조의 호스트와 **정확히** 일치해야 한다(`docker.io` 이지 `registry-1.docker.io` 가 아님).

## 5. 카나리 노드 검증 (파일을 둔 노드 1대)
```bash
# (1) 퍼블릭 이름 그대로 pull — 노드에 없는 태그로
sudo crictl pull docker.io/library/busybox:1.36.1
# (2) 어느 호스트로 갔는지: Nexus request.log 에서 노드 IP 와 UA containerd 확인 (프록시 뒤면 XFF 로 노드 IP 가 보인다)
tools/nexus-reqlog-report.sh -a containerd -s '2026-11-05 09:00' -S ip,component
# (3) 부정 검증: hosts.toml 을 잠시 치우면 같은 pull 이 실패해야 한다 (우회 경로가 없다는 증거)
sudo mv /etc/containerd/certs.d/docker.io{,.off}; sudo crictl rmi docker.io/library/busybox:1.36.1; sudo crictl pull docker.io/library/busybox:1.36.1; sudo mv /etc/containerd/certs.d/docker.io{.off,}
# (4) Harbor 비공개 프로젝트: imagePullSecrets 를 가진 테스트 Pod 가 그 노드에서 Running
kubectl run t --image=harbor.example.internal/team/app:1.0 --overrides='{"spec":{"nodeName":"<카나리>","imagePullSecrets":[{"name":"harbor-robot"}]}}' --restart=Never
# (5) ctr 로 hosts 디렉터리를 명시해 같은 결과가 나는지 (CRI 경로와 분리해 확인)
sudo ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d docker.io/library/busybox:1.36.1
```
전부 통과해야 다음 단계. (3) 이 실패하지 않으면 노드가 다른 경로(인터넷, 다른 미러)로 나가고 있다는 뜻이다.

## 6. 전체 반영
- Ansible 예:
```yaml
- name: containerd registry hosts
  copy: { src: "certs.d/{{ item }}/hosts.toml", dest: "/etc/containerd/certs.d/{{ item }}/hosts.toml", mode: "0644" }
  loop: [docker.io, quay.io, ghcr.io, registry.k8s.io, public.ecr.aws, harbor.example.internal]
  # 재시작 핸들러 불필요: hosts.toml 은 pull 때마다 읽힌다
```
- DaemonSet 대안: hostPath `/etc/containerd/certs.d` 를 마운트한 init 컨테이너가 파일을 쓰고 pause. 노드 추가 시 자동 적용되는 장점. 단, 그 DaemonSet 의 이미지 자체가 Harbor 에 있어야 하고 첫 pull 은 라우팅 없이 Harbor 직행이므로 CA 만 먼저 깔려 있으면 된다.
- 순서: 카나리 1대 → 워커 풀의 10% → 전체 → 컨트롤플레인. 롤아웃 중 이미지 참조를 바꾸지 않으므로 Pod 재시작은 없다. 적용 확인은 5절 (1)(2) 를 노드 표본에 반복.

## 7. 롤백
- 파일 삭제가 롤백이다(`rm -rf /etc/containerd/certs.d/<호스트>`). 즉시 효력, 재시작 없음. 이미 pull 된 이미지는 노드에 남아 있어 실행 중 Pod 는 영향 없다.
- 운영 도구가 덮어쓰기 전 원본을 `_backup/` 에 보관한다(Spegel 이 쓰는 관행과 같음).

## 8. 반영 후 운영 규칙
1. 사내 빌드는 Harbor 에만 push. Nexus docker-hosted 에 CI 쓰기 권한 없음.
2. 퍼블릭 이미지 참조는 업스트림 이름 그대로. `nexus.example.internal/...` 로 고쳐 쓴 참조는 PR 리뷰에서 막는다.
3. 새 업스트림 호스트가 필요하면: Nexus 에 hosted(or proxy) 추가 → group 에 편입(또는 B 패턴 포트) → 충돌 점검(1-2) → 디렉터리 하나 추가 배포.
4. Nexus 카운터: 노드 pull 1회 = `POST /v2/token`(404, containerd 가 OAuth 를 먼저 시도) + `GET token` + manifest HEAD + GET + blob×N. 익명 허용이면 token 왕복이 빠진다. 월간 추이는 `tools/nexus-reqlog-report.sh -a containerd -S subnet,component` 로 노드 대역별로 본다.
5. 반입 시 schema1 변환, `+build` 버전 차트는 OCI 태그 `_` 규칙.

## 9. 증상 → 원인

| 증상 | 원인 | 확인 |
|---|---|---|
| `dial tcp: lookup registry-1.docker.io` 류 DNS 실패 | 해당 호스트 디렉터리 없음·이름 오타·TOML 문법 오류로 server 로 떨어짐 | `ls /etc/containerd/certs.d/`, `ctr images pull --hosts-dir` |
| `x509: certificate signed by unknown authority` | CA 미배포 | 3절 openssl 확인 |
| `401 Unauthorized` (퍼블릭 이미지) | Nexus 익명 pull 미허용 | `curl .../v2/` 가 401 |
| `pull access denied` / `not found` (Harbor) | 비공개 프로젝트에 imagePullSecrets 없음 또는 로봇 권한 범위 밖 | 로봇으로 `skopeo inspect` |
| `schema 1 image manifests are no longer supported` | 구식 이미지 | 반입 시 `--format oci` 변환 |
| API 는 되는데 큰 blob 만 멈춤 | MTU 블랙홀 | README 5차 MTU 절 |
| 미러에 있는데 server 로 감 | `capabilities` 에 `resolve` 누락 | hosts.toml 확인 |
| group 에서 엉뚱한 이미지가 나옴 | 상류 간 경로 충돌 | 1-2 점검 → B 패턴 |
