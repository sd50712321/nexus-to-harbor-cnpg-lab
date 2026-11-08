#!/bin/bash
# (랩 전용) VMware NAT(vmnet-natd)가 안 될 때, Mac 의 host-only 주소에 HTTP 프록시를 띄워 노드가 인터넷에 나가게 한다.
# 인벤토리 http_proxy/https_proxy 가 이 주소를 가리킨다. Mac 재부팅 시 사라지므로 다시 실행. 근본 해결은 TROUBLESHOOTING 2절.
#   ./scripts/lab-proxy.sh          # 시작(이미 떠 있으면 그대로)
#   ./scripts/lab-proxy.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."
ADDR=${PROXY_ADDR:-172.16.141.1}; PORT=${PROXY_PORT:-3128}
if [ "${1:-}" = stop ]; then pkill -f "bin/proxy --hostname $ADDR --port $PORT" && echo "중지" || echo "떠 있지 않음"; exit 0; fi
if (exec 3<>/dev/tcp/$ADDR/$PORT) 2>/dev/null; then echo "이미 응답 중: $ADDR:$PORT"; exit 0; fi
. .venv/bin/activate
command -v proxy >/dev/null || pip -q install proxy.py
mkdir -p logs
nohup proxy --hostname $ADDR --port $PORT > logs/lab-proxy.log 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/$ADDR/$PORT) 2>/dev/null && { echo "프록시 시작: http://$ADDR:$PORT"; exit 0; }; sleep 1; done
echo "시작 실패: logs/lab-proxy.log 확인"; exit 1
