#!/usr/bin/env bash
#
# ob_events.sh — 从 OceanBase 提取切主/停机事件与集群状态(切主的权威判据)
#
# 依赖: obclient (或 mysql 客户端)
#
set -euo pipefail

OB_HOST="${OB_HOST:-127.0.0.1}"
OB_PORT="${OB_PORT:-2881}"
OB_USER="${OB_USER:-root@sys}"
OB_PASS="${OB_PASS:-}"
OB_DB="${OB_DB:-oceanbase}"

FROM=""; TO=""; MODE="events"; OUT=""

usage() {
  cat <<'EOF'
用法:
  ob_events.sh -m <mode> [-f <from_utc>] [-t <to_utc>] [-o <outfile>]

模式 (-m):
  events    提取 DBA_OB_SERVER_EVENT_HISTORY 指定时间窗事件  ← 切主的权威判据
  leaders   导出当前各日志流 leader 分布 (GV$OB_LOG_STAT)
  params    导出全量参数基线 (GV$OB_PARAMETERS)
  io        导出 I/O 相关视图快照
  watch     持续轮询 leader 分布, 1s 一次 (注入期间使用)
  all       events + leaders + params + io

时间格式: 'YYYY-MM-DD HH:MM:SS' (数据库本地时区)

环境变量:
  OB_HOST / OB_PORT / OB_USER / OB_PASS / OB_DB

示例:
  OB_PASS=xxx ./ob_events.sh -m params -o baseline_params.tsv
  OB_PASS=xxx ./ob_events.sh -m events -f '2026-08-30 10:00:00' -t '2026-08-30 11:00:00'
  OB_PASS=xxx ./ob_events.sh -m watch -o leader_watch.tsv
EOF
}

while getopts "m:f:t:o:h" opt; do
  case "$opt" in
    m) MODE="$OPTARG" ;;
    f) FROM="$OPTARG" ;;
    t) TO="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

CLI="$(command -v obclient || command -v mysql || true)"
[[ -z "$CLI" ]] && { echo "ERROR: 未找到 obclient 或 mysql 客户端" >&2; exit 1; }

q() {
  "$CLI" -h"$OB_HOST" -P"$OB_PORT" -u"$OB_USER" ${OB_PASS:+-p"$OB_PASS"} \
    -D"$OB_DB" -A --batch --raw -e "$1"
}

emit() { if [[ -n "$OUT" ]]; then tee -a "$OUT"; else cat; fi; }

# ---- 事件历史: 切主 / 停机 / 磁盘状态变更 的权威来源 ----
sql_events() {
  local where="1=1"
  [[ -n "$FROM" ]] && where="$where AND gmt_create >= '$FROM'"
  [[ -n "$TO"   ]] && where="$where AND gmt_create <= '$TO'"
  cat <<EOF
SELECT * FROM oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE $where
ORDER BY gmt_create;
EOF
}

# ---- 日志流 leader 分布 ----
sql_leaders() {
  cat <<'EOF'
SELECT tenant_id, ls_id, svr_ip, svr_port, role, state,
       begin_lsn, end_lsn, paxos_member_list, paxos_replica_num
FROM oceanbase.GV$OB_LOG_STAT
ORDER BY tenant_id, ls_id, role DESC;
EOF
}

# ---- 参数基线 ----
sql_params() {
  cat <<'EOF'
SELECT svr_ip, svr_port, tenant_id, zone, scope, name, value, data_type, edit_level
FROM oceanbase.GV$OB_PARAMETERS
ORDER BY name, svr_ip;
EOF
}

# ---- 本次分析关注的关键参数速查 ----
sql_key_params() {
  cat <<'EOF'
SELECT svr_ip, name, value, edit_level
FROM oceanbase.GV$OB_PARAMETERS
WHERE name IN (
  '_data_storage_io_timeout',
  'data_storage_warning_tolerance_time',
  'data_storage_error_tolerance_time',
  'log_storage_warning_tolerance_time',
  'log_storage_warning_trigger_percentage',
  'log_disk_utilization_threshold',
  'log_disk_utilization_limit_threshold',
  'log_disk_throttling_percentage',
  'freeze_trigger_percentage',
  'memstore_limit_percentage',
  'enable_rebalance',
  'enable_transfer',
  'enable_async_syslog',
  'syslog_io_bandwidth_limit'
)
ORDER BY name, svr_ip;
EOF
}

case "$MODE" in
  events)
    echo "=== DBA_OB_SERVER_EVENT_HISTORY  [$FROM ~ $TO] ===" | emit
    q "$(sql_events)" | emit
    ;;
  leaders)
    echo "=== GV\$OB_LOG_STAT  @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | emit
    q "$(sql_leaders)" | emit
    ;;
  params)
    echo "=== 关键参数 @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | emit
    q "$(sql_key_params)" | emit
    echo | emit
    echo "=== 全量参数基线 ===" | emit
    q "$(sql_params)" | emit
    ;;
  io)
    echo "=== I/O 视图快照 @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | emit
    for v in 'GV$OB_IO_CALIBRATION_STATUS' 'GV$OB_IO_BENCHMARK' 'GV$OB_IO_QUOTA'; do
      echo "-- $v" | emit
      q "SELECT * FROM oceanbase.$v;" 2>/dev/null | emit || echo "(视图不存在或无权限)" | emit
    done
    ;;
  watch)
    echo -e "ts_utc\ttenant_id\tls_id\tsvr_ip\trole" | emit
    while true; do
      TS="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      q "SELECT tenant_id, ls_id, svr_ip, role FROM oceanbase.GV\$OB_LOG_STAT WHERE role='LEADER' ORDER BY tenant_id, ls_id;" \
        | tail -n +2 | while read -r line; do echo -e "$TS\t$line"; done | emit
      sleep 1
    done
    ;;
  all)
    "$0" -m events -f "$FROM" -t "$TO" ${OUT:+-o "$OUT"}
    "$0" -m leaders ${OUT:+-o "$OUT"}
    "$0" -m params  ${OUT:+-o "$OUT"}
    "$0" -m io      ${OUT:+-o "$OUT"}
    ;;
  *)
    usage; exit 1 ;;
esac
