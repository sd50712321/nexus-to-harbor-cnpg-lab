#!/bin/bash
# 노드에서 실행: 엔진 프런트엔드 NVMe-TCP 포트를 조용히 버린다 (타깃은 살아 있고 응답만 없음).
#   u-blackhole.sh on|off <port>
P=$(pgrep -f '^spdk_tgt' | head -1); A=-I; [ "$1" = off ] && A=-D
nsenter -t $P -n iptables $A INPUT  -p tcp --dport $2 -j DROP
nsenter -t $P -n iptables $A OUTPUT -p tcp --sport $2 -j DROP
nsenter -t $P -n iptables -S | grep DROP
