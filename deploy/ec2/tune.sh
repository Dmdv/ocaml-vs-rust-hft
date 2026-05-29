#!/usr/bin/env bash
# Runtime low-jitter tuning for a pinned, single-core latency benchmark. Idempotent; run as root
# on the post-isolcpus reboot (phase 2). It prints a verification block to stdout so the run
# records the exact environment it measured in alongside the numbers.
#
# isolcpus / nohz_full / rcu_nocbs are NOT set here — they are kernel boot params applied in
# phase 1 (deploy/ec2/userdata.sh) and require the reboot that already happened.
set -uo pipefail

PIN_CORE="${PIN_CORE:-2}"
ISOL_CPUS="${ISOL_CPUS:-2,3}"
log() { printf '[tune] %s\n' "$*" >&2; }

# 1. Frequency: performance governor + turbo off => steady base clock (predictable, not peak).
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g performance >/dev/null 2>&1 || true
else
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance >"$g" 2>/dev/null || true
  done
fi
[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 >/sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

# 2. Transparent huge pages off (no khugepaged compaction jitter).
echo never >/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never >/sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# 3. Stop IRQ balancing and steer all IRQs onto the housekeeping cpu (0), off the isolated set.
systemctl stop irqbalance 2>/dev/null || true
for f in /proc/irq/*/smp_affinity_list; do echo 0 >"$f" 2>/dev/null || true; done

# 4. Give the pinned core its whole physical core: offline its SMT sibling(s).
sib_list=$(cat "/sys/devices/system/cpu/cpu${PIN_CORE}/topology/thread_siblings_list" 2>/dev/null || echo "")
for c in ${sib_list//,/ }; do
  if [ "$c" != "$PIN_CORE" ] && [ -w "/sys/devices/system/cpu/cpu$c/online" ]; then
    echo 0 >"/sys/devices/system/cpu/cpu$c/online" 2>/dev/null && log "offlined SMT sibling cpu$c"
  fi
done

# --- verification block (captured into the results as environment.txt) ---
echo "=== benchmark host environment ==="
echo "date_utc      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "kernel        : $(uname -r)"
echo "cmdline       : $(cat /proc/cmdline)"
echo "want isolated : ${ISOL_CPUS}"
echo "isolated      : $(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo '?')"
echo "nohz_full     : $(cat /sys/devices/system/cpu/nohz_full 2>/dev/null || echo '?')"
echo "pin core      : ${PIN_CORE}"
echo "governor      : $(cat "/sys/devices/system/cpu/cpu${PIN_CORE}/cpufreq/scaling_governor" 2>/dev/null || echo '?')"
echo "no_turbo      : $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo 'n/a')"
echo "cur_freq_kHz  : $(cat "/sys/devices/system/cpu/cpu${PIN_CORE}/cpufreq/scaling_cur_freq" 2>/dev/null || echo '?')"
echo "thp           : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
echo "--- lscpu ---"
lscpu 2>/dev/null | grep -E 'Model name|Architecture|Socket|Core|Thread|NUMA|^CPU\(s\)|max MHz|min MHz' || true
