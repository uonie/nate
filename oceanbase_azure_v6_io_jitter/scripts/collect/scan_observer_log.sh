#!/usr/bin/env bash
#
# scan_observer_log.sh — 从 observer.log / election.log 提取本次分析关注的关键签名
#
# 最重要的用途: 区分切主是由哪条路径触发的 —— 这是 H1/H2 假设判定的辅助佐证
#   * PALF 选举租约路径 (硬编码 4s, 不可调)   -> LeaseExpiredToRevoke / lease_expired
#   * failure detector 路径 (可调至 300s)     -> log/data disk 故障事件
#
set -euo pipefail

LOGDIR="${LOGDIR:-/home/admin/oceanbase/log}"
FROM=""; TO=""; OUT=""

usage() {
  cat <<'EOF'
用法:
  scan_observer_log.sh [-l <logdir>] [-f 'YYYY-MM-DD HH:MM:SS'] [-t 'YYYY-MM-DD HH:MM:SS'] [-o <outfile>]

默认 logdir: /home/admin/oceanbase/log  (可用环境变量 LOGDIR 覆盖)

输出分组:
  [A] I/O 超时与慢 I/O            -4389 / io result wait too long / result_delay
  [B] 磁盘状态变更                 disk status / WARNING / ERROR
  [C] PALF 选举租约               lease expired / LeaseExpiredToRevoke  ← H2 证据
  [D] failure detector            failure detector / has_disk_hang     ← H1 证据
  [E] 切主与角色变更               role change / revoke / takeover
  [F] 慢 I/O 耗时分解统计          submit_used / return_used / enqueue_used
EOF
}

while getopts "l:f:t:o:h" opt; do
  case "$opt" in
    l) LOGDIR="$OPTARG" ;;
    f) FROM="$OPTARG" ;;
    t) TO="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[[ -d "$LOGDIR" ]] || { echo "ERROR: 日志目录不存在: $LOGDIR" >&2; exit 1; }

FILES=()
for f in observer.log observer.log.wf election.log rootservice.log; do
  [[ -f "$LOGDIR/$f" ]] && FILES+=("$LOGDIR/$f")
done
[[ ${#FILES[@]} -eq 0 ]] && { echo "ERROR: $LOGDIR 下未找到 observer.log 等日志" >&2; exit 1; }

# 时间窗过滤: OB 日志行首为 [YYYY-MM-DD HH:MM:SS.ffffff]
timefilter() {
  if [[ -z "$FROM" && -z "$TO" ]]; then cat; return; fi
  awk -v from="$FROM" -v to="$TO" '
    {
      ts = ""
      if (match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr($0, 2, 19)
      }
      if (ts == "") next
      if (from != "" && ts < from) next
      if (to   != "" && ts > to)   next
      print
    }'
}

emit() { if [[ -n "$OUT" ]]; then tee -a "$OUT"; else cat; fi; }

section() {
  local title="$1"; shift
  local pattern="$1"
  {
    echo
    echo "==================== $title ===================="
    local n
    n=$(grep -h -E "$pattern" "${FILES[@]}" 2>/dev/null | timefilter | wc -l || true)
    n="${n:-0}"
    echo "匹配行数: $n"
    [[ "$n" -eq 0 ]] && { echo "(无匹配)"; return 0; }
    grep -h -E "$pattern" "${FILES[@]}" 2>/dev/null | timefilter | head -200 || true
    [[ "$n" -gt 200 ]] && echo "... (共 $n 行, 仅显示前 200 行)"
    return 0
  } | emit
}

{
  echo "=== observer.log 签名扫描 ==="
  echo "logdir=$LOGDIR"
  echo "files=${FILES[*]}"
  echo "window=[${FROM:-*} ~ ${TO:-*}]"
  echo "host=$(hostname) scan_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | emit

section "[A] I/O 超时与慢 I/O" \
  '\-4389|io result wait too long|result_delay|OB_IO_ERROR|IO_TIMEOUT'

section "[B] 磁盘状态变更 (WARNING / ERROR)" \
  'disk[_ ]status|device_health|DISK_WARNING|DISK_ERROR|set_disk_(warning|error)|data_storage_(warning|error)'

section "[C] PALF 选举租约  <-- H2 证据" \
  'LeaseExpiredToRevoke|lease.?expired|leader_lease|renew_lease|MAX_TST|election.*revoke'

section "[D] failure detector  <-- H1 证据" \
  'failure_detector|FailureDetector|has_disk_hang|disk_hang|log_storage_warning|clog disk'

section "[E] 切主与角色变更" \
  'role[_ ]change|switch_leader|revoke|takeover|change_leader|LEADER.*FOLLOWER|FOLLOWER.*LEADER'

section "[F] 慢 I/O 耗时分解 (定位阻塞位置)" \
  'submit_used|return_used|enqueue_used|dequeue_used'

# 汇总: result_delay 分布
{
  echo
  echo "==================== [汇总] result_delay 分布 (µs) ===================="
  grep -h -oE 'result_delay[=:][0-9]+' "${FILES[@]}" 2>/dev/null \
    | grep -oE '[0-9]+' \
    | sort -n \
    | awk '
      { v[NR]=$1; s+=$1 }
      END {
        if (NR==0) { print "(无数据)"; exit }
        printf "count=%d\n", NR
        printf "min  =%.3f s\n", v[1]/1e6
        printf "p50  =%.3f s\n", v[int(NR*0.50)+((NR*0.50)==int(NR*0.50)?0:1)]/1e6
        printf "p90  =%.3f s\n", v[int(NR*0.90)+((NR*0.90)==int(NR*0.90)?0:1)]/1e6
        printf "p99  =%.3f s\n", v[int(NR*0.99)+((NR*0.99)==int(NR*0.99)?0:1)]/1e6
        printf "max  =%.3f s\n", v[NR]/1e6
        printf "avg  =%.3f s\n", (s/NR)/1e6
        over5=0; over10=0
        for (i=1;i<=NR;i++) { if (v[i]>5e6) over5++; if (v[i]>1e7) over10++ }
        printf "超过 5s  (warning 阈值) 的次数: %d\n", over5
        printf "超过 10s (io_timeout 阈值) 的次数: %d\n", over10
      }' || true
} | emit

echo | emit
echo "扫描完成。${OUT:+输出: $OUT}" | emit
