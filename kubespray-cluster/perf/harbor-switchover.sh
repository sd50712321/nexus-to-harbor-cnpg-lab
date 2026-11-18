#!/bin/bash
# Harbor 에 API 부하를 거는 도중에 Harbor DB(CNPG)를 계획 전환하고, 실패한 요청과 끊긴 구간을 잰다.
#   perf/harbor-switchover.sh [전체 초=60] [전환 시점=20]
cd "$(dirname "$0")/.."; export KUBECONFIG=${KUBECONFIG:-$PWD/inventory/lab/artifacts/admin.conf}
[ -z "${HARBOR_CREDS:-}" ] && { . scripts/harbor-env.sh; HARBOR_CREDS=$HA; HARBOR_HOST=$HH; }
H=$HARBOR_HOST; NS=${PG_NS:-harbor}; C=${PG_CLUSTER:-harbor-pg}; T=${1:-60}; AT=${2:-20}; W=/tmp/harbor-sw; rm -rf $W; mkdir -p $W
OLD=$(kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}')
NEW=$(kubectl -n $NS get pods -l cnpg.io/cluster=$C,role=replica -o jsonpath='{.items[0].metadata.name}')
echo "### Harbor DB switchover $OLD → $NEW 중 API 부하, $(date +%H:%M:%S)"
oha --no-tui -z ${T}s -c 10 --insecure -a "$HARBOR_CREDS" "https://$H/api/v2.0/projects" > $W/oha.txt 2>/dev/null &
( end=$((SECONDS+T)); while [ $SECONDS -lt $end ]; do echo "$(date +%H:%M:%S) $(curl -sk -m 3 -o /dev/null -w '%{http_code} %{time_total}' -u "$HARBOR_CREDS" "https://$H/api/v2.0/projects/perf/repositories?page_size=5")"; /bin/sleep 1; done ) > $W/curl.txt &
/bin/sleep $AT; echo "전환 시작 $(date +%H:%M:%S)"
if kubectl cnpg version >/dev/null 2>&1; then kubectl cnpg promote $C $NEW -n $NS
else kubectl -n $NS patch cluster $C --subresource=status --type merge -p "{\"status\":{\"targetPrimary\":\"$NEW\",\"targetPrimaryTimestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)\",\"phase\":\"Switchover in progress\",\"phaseReason\":\"Switching over to $NEW\"}}" >/dev/null; fi
wait
echo "oha: $(grep -E 'Success rate|Requests/sec' $W/oha.txt | xargs)"; echo "  상태 코드: $(grep -A8 'Status code' $W/oha.txt | grep -E '\[[0-9]+\]' | xargs)"; grep -A4 'Error distribution' $W/oha.txt | tail -n +2 | head -3 | cut -c1-120
echo "1초 간격 요청: 전체 $(wc -l < $W/curl.txt | xargs)번, 200 아님 $(grep -vc ' 200 ' $W/curl.txt)번"; grep -v ' 200 ' $W/curl.txt | head -12
echo "새 primary: $(kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}')"
