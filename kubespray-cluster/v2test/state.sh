#!/bin/bash
# 한 줄 상태: 노드 / Longhorn 디스크 / 볼륨 / CNPG  (인자: 노드 이름)
N=$1; export KUBECONFIG=$(dirname "$0")/../inventory/lab/artifacts/admin.conf
nd=$(kubectl get node $N --no-headers 2>/dev/null | awk '{print $2}')
dk=$(kubectl -n longhorn-system get nodes.longhorn.io $N -o json 2>/dev/null | python3 -c "
import sys,json;s=json.load(sys.stdin)['status']['diskStatus'].get('v2-disk',{})
c={x['type']:x['status'] for x in s.get('conditions',[])};print('disk=%s/%s uuid=%s'%(c.get('Ready'),s.get('diskPath'),(s.get('diskUUID') or '-')[:8]))" 2>/dev/null)
vol=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null | awk -v f="${VOLF:-.}" '$2=="v2" && $0 ~ f{printf "%s/%s ",$3,$4}')
pg=$(kubectl -n v2test get cluster ${CL:-pg-v2} -o jsonpath='{.status.readyInstances}/{.status.instances} primary={.status.currentPrimary}' 2>/dev/null)
pods=$(kubectl -n v2test get pods -l cnpg.io/cluster=${CL:-pg-v2} -o wide --no-headers 2>/dev/null | awk '{printf "%s=%s(%s)@%s ",$1,$3,$2,$7}')
echo "$(date +%H:%M:%S) node=$nd $dk | vol: $vol| pg $pg | $pods"
