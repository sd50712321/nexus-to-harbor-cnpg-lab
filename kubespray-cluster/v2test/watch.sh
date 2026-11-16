#!/bin/bash
# 상태가 바뀔 때만 한 줄 출력. 인자: 노드, 최대 초, [끝 조건 grep 식]
cd "$(dirname "$0")/.."; N=$1; MAX=${2:-300}; END=${3:-}; S=$(date +%s); last=
while [ $(( $(date +%s)-S )) -lt $MAX ]; do
  o=$(./v2test/state.sh $N); b=${o#* }
  [ "$b" != "$last" ] && { echo "+$(( $(date +%s)-S ))s $o"; last=$b; }
  [ -n "$END" ] && echo "$b" | grep -qE "$END" && ! echo "$b" | grep -q faulted && break
  /bin/sleep 5
done
