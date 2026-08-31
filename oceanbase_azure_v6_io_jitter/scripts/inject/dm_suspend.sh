#!/usr/bin/env bash
#
# dm_suspend.sh — 通过 dmsetup suspend/resume 对指定磁盘域注入精确时长的 I/O 停顿
#
# 原理：suspend 后所有到达该 device-mapper 设备的 I/O 全量排队，N 秒后 resume 一次性放行。
#       与现场日志中 submit_used / return_used 两侧同时阻塞的特征一致。
#
# !! 测试环境专用，严禁在生产环境执行 !!
#
set -euo pipefail

DOMAIN=""
DURATION=""
TARGET_DEV=""
TAG="${TAG:-manual}"
OUTDIR="${OUTDIR:-./data}"

usage() {
  cat <<'EOF'
用法:
  dm_suspend.sh -d <domain> -t <seconds> [-D <dm-device>] [-g <tag>]

参数:
  -d  磁盘域: data | clog | admin | dev(配合 -D 指定任意设备)
  -t  停顿时长(秒), 支持小数
  -D  直接指定 dm 设备名或路径 (例如 oblogvg-obloglv 或 /dev/mapper/oblogvg-obloglv)
  -g  场景标签, 用于归档目录命名, 默认 manual
  -h  显示帮助

域到设备的默认映射(可用环境变量覆盖):
  data   -> $DM_DATA   (默认 obdatavg-obdatalv)
  clog   -> $DM_CLOG   (默认 oblogvg-obloglv)
  admin  -> $DM_ADMIN  (默认 obadminvg-obadminlv)

示例:
  ./dm_suspend.sh -d clog -t 15 -g S1
  ./dm_suspend.sh -d data -t 6  -g S2
  ./dm_suspend.sh -D /dev/mapper/oblogvg-obloglv -t 8

安全机制:
  脚本会派生一个看门狗进程, 在 (停顿时长 + 30s) 后强制 resume,
  防止主进程异常退出导致设备永久处于 suspend 状态。
EOF
}

while getopts "d:t:D:g:h" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    t) DURATION="$OPTARG" ;;
    D) TARGET_DEV="$OPTARG" ;;
    g) TAG="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[[ -z "$DURATION" ]] && { echo "ERROR: 必须指定 -t <seconds>" >&2; usage; exit 1; }
[[ $EUID -ne 0 ]] && { echo "ERROR: 需要 root 权限" >&2; exit 1; }

DM_DATA="${DM_DATA:-obdatavg-obdatalv}"
DM_CLOG="${DM_CLOG:-oblogvg-obloglv}"
DM_ADMIN="${DM_ADMIN:-obadminvg-obadminlv}"

if [[ -z "$TARGET_DEV" ]]; then
  case "$DOMAIN" in
    data)  TARGET_DEV="$DM_DATA" ;;
    clog)  TARGET_DEV="$DM_CLOG" ;;
    admin) TARGET_DEV="$DM_ADMIN" ;;
    *) echo "ERROR: 未知磁盘域 '$DOMAIN', 或请用 -D 直接指定设备" >&2; exit 1 ;;
  esac
fi

# 归一化为 dmsetup 认识的名称
DM_NAME="$(basename "$TARGET_DEV")"

if ! dmsetup info "$DM_NAME" >/dev/null 2>&1; then
  echo "ERROR: dm 设备不存在: $DM_NAME" >&2
  echo "当前可用设备:" >&2
  dmsetup ls >&2
  exit 1
fi

mkdir -p "$OUTDIR"
LOG="$OUTDIR/inject_${TAG}_${DOMAIN:-dev}_${DURATION}s_$(date +%Y%m%d_%H%M%S).log"

# 看门狗: 超时强制 resume, 防止脚本崩溃导致设备永久 suspend
WATCHDOG_TIMEOUT=$(awk "BEGIN{printf \"%d\", $DURATION + 30}")
(
  sleep "$WATCHDOG_TIMEOUT"
  if dmsetup info "$DM_NAME" 2>/dev/null | grep -q 'State:.*SUSPENDED'; then
    echo "[WATCHDOG] 检测到设备仍处于 SUSPENDED, 强制 resume" | tee -a "$LOG"
    dmsetup resume "$DM_NAME" || true
  fi
) &
WATCHDOG_PID=$!
# shellcheck disable=SC2064
trap "kill $WATCHDOG_PID 2>/dev/null || true; dmsetup resume '$DM_NAME' 2>/dev/null || true" EXIT

{
  echo "=== dm_suspend 注入 ==="
  echo "tag=$TAG domain=${DOMAIN:-dev} device=$DM_NAME duration=${DURATION}s"
  echo "host=$(hostname)"
} | tee -a "$LOG"

T_START="$(date +%s.%N)"
echo "SUSPEND_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) epoch=$T_START" | tee -a "$LOG"

dmsetup suspend --noflush --nolockfs "$DM_NAME"

sleep "$DURATION"

dmsetup resume "$DM_NAME"

T_END="$(date +%s.%N)"
echo "RESUME_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) epoch=$T_END" | tee -a "$LOG"
echo "ACTUAL_DURATION=$(awk "BEGIN{printf \"%.3f\", $T_END - $T_START}")s" | tee -a "$LOG"

kill "$WATCHDOG_PID" 2>/dev/null || true
trap - EXIT

# 确认状态已恢复
STATE="$(dmsetup info "$DM_NAME" | awk '/State:/{print $2}')"
echo "FINAL_STATE=$STATE" | tee -a "$LOG"
[[ "$STATE" == "ACTIVE" ]] || { echo "ERROR: 设备未恢复到 ACTIVE" >&2; exit 1; }

echo "日志: $LOG"
