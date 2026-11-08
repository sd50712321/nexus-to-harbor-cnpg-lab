#!/bin/bash
# (랩 전용) vagrant ssh-config → inventory/lab/ssh.cfg (VM 재생성마다 키·주소가 바뀌므로 매번 다시 만든다)
set -euo pipefail
cd "$(dirname "$0")/.."
vagrant ssh-config > inventory/lab/ssh.cfg
grep -c '^Host ' inventory/lab/ssh.cfg | xargs echo "hosts:"
