#!/bin/bash
# 프로브 로그에서 쓰기/읽기 실패 구간을 뽑는다 (시각은 UTC)
export KUBECONFIG=$(dirname "$0")/../inventory/lab/artifacts/admin.conf
kubectl -n v2test logs ${PROBE:-probe} --since=${1:-30m} | python3 -c "
import sys
L=[l.split() for l in sys.stdin if ' W=' in l]
print('samples',len(L),L[0][0],'~',L[-1][0])
for k,name in ((1,'write'),(2,'read')):
    run=None;out=[]
    for t,w,r in L:
        bad=(w,r)[k-1].endswith('X')
        if bad and run is None: run=[t,t,1]
        elif bad: run[1]=t;run[2]+=1
        elif run: out.append(run);run=None
    if run: out.append(run)
    print(name,'fail runs:',[f'{a}~{b} ({n} samples)' for a,b,n in out] or 'none')
"
