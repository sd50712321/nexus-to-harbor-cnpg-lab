#!/bin/bash
# 한 노드의 V2 인스턴스 매니저와 블록 디스크별 Ready 를 바뀔 때만 출력. 인자: 노드, 최대 초, [끝 조건]
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf; N=$1; MAX=${2:-600}; END=${3:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  nd=$(kubectl get node $N --no-headers 2>/dev/null | awk '{print $2}')
  im=$(kubectl -n longhorn-system get instancemanagers.longhorn.io --no-headers 2>/dev/null | awk -v n=$N '$2=="v2" && $5==n{print $3}')
  dk=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)['status'].get('diskStatus',{})
print(' '.join('%s=%s'%(k,next((c['status'] for c in v.get('conditions',[]) if c['type']=='Ready'),'?')) for k,v in sorted(d.items()) if k.startswith('v2')))" 2>/dev/null)
  b="node=$nd im-v2=$im $dk"; [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $(date +%H:%M:%S) $b"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && break
  /bin/sleep 3
done
