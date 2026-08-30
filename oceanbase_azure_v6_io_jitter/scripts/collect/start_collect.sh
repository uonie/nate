#!/usr/bin/env bash
#
# start_collect.sh — 启动 OS 层观测采集管线
#
# 采集内容: iostat -x / vmstat / nvme error-log / dmesg / dm 状态
# 停止方式: stop_collect.sh 或 Ctrl-C
#
set -euo pipefail

OUTDIR="${1:-./data/collect_$(date +%Y%m%d_%H%M%S)}"
INTERVAL="${INTERVAL:-1}"
mkdir -p "$OUTDIR"

PIDFILE="$OUTDIR/collect.pids"
: > "$PIDFILE"

start() {
  local name="$1"; shift
  "$@" > "$OUTDIR/$name" 2>&1 &
  echo "$! $name" >> "$PIDFILE"
  echo "  started $name (pid $!)"
}

echo "=== OS 观测采集 -> $OUTDIR ==="
echo "host=$(hostname) start_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" | tee "$OUTDIR/meta.txt"

# 环境快照(一次性)
{
  echo "### uname"; uname -a
  echo; echo "### /proc/cmdline"; cat /proc/cmdline
  echo; echo "### nvme_core.io_timeout"
  cat /sys/module/nvme_core/parameters/io_timeout 2>/dev/null || echo "(N/A)"
  echo; echo "### lsblk"; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,SCHED,ROTA
  echo; echo "### findmnt"; findmnt -t xfs,ext4 -o TARGET,SOURCE,FSTYPE,OPTIONS
  echo; echo "### df -h"; df -h
  echo; echo "### swap"; swapon --show || echo "(no swap)"
  echo; echo "### dmsetup ls"; dmsetup ls
  echo; echo "### dmsetup table"; dmsetup table
  echo; echo "### pvs/vgs/lvs"; pvs 2>/dev/null; vgs 2>/dev/null; lvs -o +stripes,stripe_size 2>/dev/null
  echo; echo "### block queue"
  for q in /sys/block/nvme*/queue; do
    [[ -d "$q" ]] || continue
    echo "-- $q"
    for f in scheduler nr_requests rq_affinity max_sectors_kb read_ahead_kb nomerges; do
      [[ -r "$q/$f" ]] && printf '   %-18s %s\n' "$f" "$(cat "$q/$f")"
    done
  done
  echo; echo "### vm.dirty_*"
  sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs 2>/dev/null
  echo; echo "### THP"
  cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
} > "$OUTDIR/env_snapshot.txt" 2>&1
echo "  环境快照 -> env_snapshot.txt"

# 持续采集
command -v iostat >/dev/null && start "iostat.txt" iostat -x -t "$INTERVAL" \
  || echo "  WARN: iostat 不可用 (yum install sysstat)"
command -v vmstat >/dev/null && start "vmstat.txt" vmstat -t "$INTERVAL"
start "dmesg.txt" dmesg -wT

# nvme error-log 需轮询
if command -v nvme >/dev/null; then
  (
    while true; do
      echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      for d in /dev/nvme[0-9]*n1; do
        [[ -e "$d" ]] || continue
        echo "-- $d"
        nvme error-log "$d" 2>/dev/null | head -40
      done
      sleep 10
    done
  ) > "$OUTDIR/nvme_error.txt" 2>&1 &
  echo "$! nvme_error.txt" >> "$PIDFILE"
  echo "  started nvme_error.txt (pid $!)"
else
  echo "  WARN: nvme-cli 不可用"
fi

echo
echo "采集已启动。停止: $(dirname "$0")/stop_collect.sh $OUTDIR"
echo "$OUTDIR" > /tmp/ob_jitter_last_collect
