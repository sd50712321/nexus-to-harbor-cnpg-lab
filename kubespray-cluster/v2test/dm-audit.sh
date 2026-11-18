#!/bin/bash
# 노드마다 Longhorn dm 을 전수 조사해 "그 노드에 붙어 있지 않은데 남은 dm"(고아)을 센다.
#   dm-audit.sh [노드...]      출력: 노드 dm이름 상태 open 판정
cd "$(dirname "$0")/.."; export KUBECONFIG=$PWD/inventory/lab/artifacts/admin.conf
NODES=${@:-ks-w1 ks-w2 ks-w3}
ATT=$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.currentNodeID}{"\n"}{end}')
for n in $NODES; do
  vagrant ssh $n -c "sudo dmsetup info -c --noheadings -o name,suspended,open; echo D=\$(ps -eo stat | grep -c '^D')" 2>/dev/null | tr -d '\r' | while IFS=: read name sus open; do
    case "$name" in D=*) echo "$n $name";; pvc-*|u6-*) at=$(echo "$ATT" | grep "^$name=" | cut -d= -f2); j=정상; [ "$at" != "$n" ] && j="고아(볼륨은 ${at:-없음/분리})"; echo "$n $name $sus open=$open $j";; esac; done; done
