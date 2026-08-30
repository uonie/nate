#!/usr/bin/env bash
#
# stop_collect.sh — 停止 start_collect.sh 启动的采集进程
#
set -euo pipefail

OUTDIR="${1:-$(cat /tmp/ob_jitter_last_collect 2>/dev/null || true)}"
[[ -z "$OUTDIR" ]] && { echo "用法: stop_collect.sh <采集目录>" >&2; exit 1; }

PIDFILE="$OUTDIR/collect.pids"
[[ -f "$PIDFILE" ]] || { echo "ERROR: 未找到 $PIDFILE" >&2; exit 1; }

echo "=== 停止采集 $OUTDIR ==="
while read -r pid name; do
  [[ -z "${pid:-}" ]] && continue
  if kill "$pid" 2>/dev/null; then
    echo "  stopped $name (pid $pid)"
  else
    echo "  $name (pid $pid) 已退出"
  fi
done < "$PIDFILE"

echo "stop_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >> "$OUTDIR/meta.txt"
rm -f "$PIDFILE"
echo "完成。数据在 $OUTDIR"
