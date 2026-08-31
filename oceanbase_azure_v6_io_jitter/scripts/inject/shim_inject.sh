#!/usr/bin/env bash
#
# shim_inject.sh — 在 dm_shim.sh 建立的垫层上热切换 table, 注入延迟或错误
#
# 支持三种模式:
#   delay   固定高延迟(设备仍可用, 只是慢) —— 验证"吞吐持续劣化"检测模型
#   flakey  周期性 I/O 错误返回           —— 界定 dm_suspend(只停顿不报错)的方法论边界
#   normal  恢复为 linear 直通             —— 注入结束后必须调用
#
# !! 测试环境专用, 严禁在生产环境执行 !!
#
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  shim_inject.sh -n <shim-name> -m delay  -l <read_ms> [-w <write_ms>] [-t <seconds>]
  shim_inject.sh -n <shim-name> -m flakey -u <up_secs> -o <down_secs> [-t <seconds>]
  shim_inject.sh -n <shim-name> -m normal

参数:
  -n  垫层设备名 (例如 shim_clog_0), 或用 -a <prefix> 对一组垫层同时操作
  -a  垫层前缀, 对匹配的全部垫层同时操作
  -m  模式: delay | flakey | normal
  -l  读延迟(毫秒), delay 模式必填
  -w  写延迟(毫秒), delay 模式可选, 默认与 -l 相同
  -u  正常期(秒), flakey 模式必填
  -o  故障期(秒), flakey 模式必填
  -t  持续时长(秒); 指定后到时自动恢复 normal
  -g  场景标签, 默认 manual

示例:
  # 单盘注入 2000ms 延迟, 持续 15s 后自动恢复 (场景 S8)
  shim_inject.sh -n shim_clog_0 -m delay -l 2000 -t 15 -g S8

  # 整组 4 块盘同时注入错误: 正常 1s / 故障 15s
  shim_inject.sh -a shim_clog -m flakey -u 1 -o 15 -t 16 -g flakey-ctrl

  # 手动恢复
  shim_inject.sh -a shim_clog -m normal
EOF
}

NAME=""; PREFIX=""; MODE=""; RDELAY=""; WDELAY=""; UP=""; DOWN=""; DURATION=""
TAG="${TAG:-manual}"
OUTDIR="${OUTDIR:-./data}"

while getopts "n:a:m:l:w:u:o:t:g:h" opt; do
  case "$opt" in
    n) NAME="$OPTARG" ;;
    a) PREFIX="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    l) RDELAY="$OPTARG" ;;
    w) WDELAY="$OPTARG" ;;
    u) UP="$OPTARG" ;;
    o) DOWN="$OPTARG" ;;
    t) DURATION="$OPTARG" ;;
    g) TAG="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "ERROR: 需要 root 权限" >&2; exit 1; }
[[ -z "$MODE" ]] && { echo "ERROR: 必须指定 -m" >&2; usage; exit 1; }

# 目标垫层列表
TARGETS=()
if [[ -n "$NAME" ]]; then
  TARGETS+=("$NAME")
elif [[ -n "$PREFIX" ]]; then
  mapfile -t TARGETS < <(dmsetup ls | awk '{print $1}' | grep "^${PREFIX}" | sort)
else
  echo "ERROR: 必须指定 -n 或 -a" >&2; exit 1
fi
[[ ${#TARGETS[@]} -eq 0 ]] && { echo "ERROR: 未匹配到任何垫层设备" >&2; exit 1; }

STATE_DIR="/run/ob_jitter_shim"
mkdir -p "$STATE_DIR" "$OUTDIR"
LOG="$OUTDIR/shim_${TAG}_${MODE}_$(date +%Y%m%d_%H%M%S).log"

# 保存原始 linear table (首次操作时), 供 normal 模式恢复
save_original() {
  local n="$1"
  [[ -f "$STATE_DIR/$n.orig" ]] && return 0
  local tbl; tbl="$(dmsetup table "$n")"
  # 仅当当前确实是 linear 时才保存, 避免把 delay/flakey table 存成"原始"
  if [[ "$tbl" == *" linear "* ]]; then
    echo "$tbl" > "$STATE_DIR/$n.orig"
  else
    echo "ERROR: $n 当前不是 linear, 且无原始 table 备份, 无法安全操作" >&2
    exit 1
  fi
}

# 从原始 linear table 解析出 <sectors> <backing-dev> <offset>
parse_orig() {
  local n="$1"
  awk '{print $2, $4, $5}' "$STATE_DIR/$n.orig"
}

reload_table() {
  local n="$1" tbl="$2"
  dmsetup suspend "$n"
  echo "$tbl" | dmsetup reload "$n"
  dmsetup resume "$n"
}

apply_mode() {
  local n="$1" mode="$2"
  save_original "$n"
  read -r sectors dev off < <(parse_orig "$n")

  case "$mode" in
    delay)
      [[ -z "$RDELAY" ]] && { echo "ERROR: delay 模式必须指定 -l" >&2; exit 1; }
      local wd="${WDELAY:-$RDELAY}"
      reload_table "$n" "0 $sectors delay $dev $off $RDELAY $dev $off $wd"
      ;;
    flakey)
      [[ -z "$UP" || -z "$DOWN" ]] && { echo "ERROR: flakey 模式必须指定 -u 与 -o" >&2; exit 1; }
      reload_table "$n" "0 $sectors flakey $dev $off $UP $DOWN"
      ;;
    normal)
      reload_table "$n" "$(cat "$STATE_DIR/$n.orig")"
      ;;
    *)
      echo "ERROR: 未知模式 $mode" >&2; exit 1 ;;
  esac
  printf '%-24s -> %s\n' "$n" "$(dmsetup table "$n")" | tee -a "$LOG"
}

restore_all() {
  for n in "${TARGETS[@]}"; do
    [[ -f "$STATE_DIR/$n.orig" ]] || continue
    reload_table "$n" "$(cat "$STATE_DIR/$n.orig")" || true
  done
  echo "RESTORE_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" | tee -a "$LOG"
}

{
  echo "=== shim_inject ==="
  echo "tag=$TAG mode=$MODE targets=${TARGETS[*]} duration=${DURATION:-persist}"
  echo "host=$(hostname)"
} | tee -a "$LOG"

if [[ "$MODE" == "normal" ]]; then
  restore_all
  exit 0
fi

trap restore_all EXIT

echo "INJECT_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" | tee -a "$LOG"
for n in "${TARGETS[@]}"; do apply_mode "$n" "$MODE"; done

if [[ -n "$DURATION" ]]; then
  sleep "$DURATION"
  restore_all
  trap - EXIT
  echo "已自动恢复。日志: $LOG"
else
  trap - EXIT
  echo "持续注入中(未指定 -t)。恢复请执行: $0 ${NAME:+-n $NAME}${PREFIX:+-a $PREFIX} -m normal"
fi
