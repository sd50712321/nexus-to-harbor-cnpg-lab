#!/bin/bash
# 노드에서 실행: <초> 동안 0.5초마다 Longhorn dm 상태를 보고, dm 상태가 바뀌거나 dmsetup 프로세스 수가 최고치를 넘을 때만 한 줄 찍는다. 끝에 Suspended 로 있던 최장 구간.
#   u-dmwatch.sh <초>
END=$(( $(date +%s) + $1 )); prev=; declare -A since maxs
while [ $(date +%s) -lt $END ]; do
  now=$(date +%s.%N | cut -c1-12); cur=$(dmsetup info -c --noheadings -o name,suspended,open 2>/dev/null | grep '^pvc-' | sed 's/^pvc-\(........\)[^:]*/\1/' | tr '\n' ' ')
  d=$(ps -eo stat,comm --no-headers | awk '$1~/^D/{print $2}' | sort | uniq -c | tr -s ' ' | tr '\n' ',')
  nd=$(pgrep -c dmsetup); [ "$nd" -gt "${maxd:-0}" ] && { maxd=$nd; echo "$(date -u +%H:%M:%S.%N | cut -c1-10) dmsetup 프로세스 $nd개 | D:$d"; }
  [ "$cur" != "$prev" ] && { echo "$(date -u +%H:%M:%S.%N | cut -c1-10) $cur| D:$d"; prev=$cur; }
  for e in $cur; do n=${e%%:*}; if echo "$e" | grep -q Suspended; then [ -z "${since[$n]}" ] && since[$n]=$now; else if [ -n "${since[$n]}" ]; then dur=$(echo "$now - ${since[$n]}" | bc); [ $(echo "$dur > ${maxs[$n]:-0}" | bc) = 1 ] && maxs[$n]=$dur; since[$n]=; fi; fi; done
  sleep 0.5; done
for n in "${!since[@]}"; do [ -n "${since[$n]}" ] && echo "끝까지 Suspended: $n ($(echo "$(date +%s) - ${since[$n]}" | bc)초째)"; done
for n in "${!maxs[@]}"; do echo "최장 Suspended 구간: $n ${maxs[$n]}초"; done
echo "dmsetup 프로세스: $(pgrep -a dmsetup | tr '\n' ';')"
