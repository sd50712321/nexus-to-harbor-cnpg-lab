#!/bin/bash
# 노드에서 실행: CPU 격리가 실제로 걸렸는지 본다 (설정값이 아니라 적용 결과).
P=$(pgrep -f '^spdk_tgt' | head -1)
echo "nproc=$(nproc) spdk_tgt pid=$P"
[ -n "$P" ] && { tr '\0' ' ' < /proc/$P/cmdline | cut -c1-200; echo; grep Cpus_allowed_list /proc/$P/status
  echo "spdk threads:"; for t in /proc/$P/task/*; do echo "  $(cat $t/comm) $(grep Cpus_allowed_list $t/status | awk '{print $2}')"; done | sort | uniq -c; }
echo "other procs Cpus_allowed_list:"; for n in kubelet containerd longhorn-manager; do q=$(pgrep -o $n); [ -n "$q" ] && echo "  $n $(grep Cpus_allowed_list /proc/$q/status | awk '{print $2}')"; done
echo "workqueue cpumask (unbound): $(cat /sys/devices/virtual/workqueue/cpumask)"
echo "irq default_smp_affinity: $(cat /proc/irq/default_smp_affinity)"
echo "irq smp_affinity_list 분포:"; cat /proc/irq/*/smp_affinity_list 2>/dev/null | sort | uniq -c
echo "rps_cpus:"; for f in /sys/class/net/e*/queues/rx-*/rps_cpus; do echo "  $f $(cat $f)"; done
echo "isolcpus cmdline: $(grep -o 'isolcpus=[^ ]*\|nohz_full=[^ ]*' /proc/cmdline)"
ls /var/lib/longhorn/ 2>/dev/null | tr '\n' ' '; echo
