#!/usr/bin/env bash
#
# run_matrix.sh — 按时长档位批量执行注入, 每档重复 N 次并归档
#
# 时长档位密集覆盖四条阈值线两侧:
#   ~3s   PALF 有效容忍窗口(租约 4s - 触发选举水位线 1s)
#    4s   PALF 选举租约 (硬编码, 不可配置)
#    5s   *_storage_warning_tolerance_time
#   10s   _data_storage_io_timeout
#
set -euo pipefail

DOMAIN="clog"
SCENARIO="S1"
REPEAT=5
GAP=60
LADDER="2 4 5 6 8 10 15 20 30 60 120"
OUTDIR="${OUTDIR:-./data}"
DRYRUN=0

usage() {
  cat <<'EOF'
用法:
  run_matrix.sh [-d <domain>] [-s <scenario>] [-r <repeat>] [-g <gap_sec>] [-L "<ladder>"] [-N]

参数:
  -d  磁盘域: data | clog | admin      (默认 clog)
  -s  场景编号, 用于归档命名           (默认 S1)
  -r  每档重复次数                     (默认 5)
  -g  两次注入之间的间隔秒数           (默认 60, 确保集群状态复位)
  -L  自定义时长档位, 空格分隔
  -N  dry-run, 只打印不执行
  -h  帮助

示例:
  # 场景 S1: 日志盘全档位
  ./run_matrix.sh -d clog -s S1

  # H1/H2 判定专用: 只跑阈值密集区
  ./run_matrix.sh -d clog -s H1H2 -L "2 4 5 6 8 10"

  # 场景 S2: 数据盘全档位
  ./run_matrix.sh -d data -s S2
EOF
}

while getopts "d:s:r:g:L:Nh" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    s) SCENARIO="$OPTARG" ;;
    r) REPEAT="$OPTARG" ;;
    g) GAP="$OPTARG" ;;
    L) LADDER="$OPTARG" ;;
    N) DRYRUN=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECT="$HERE/dm_suspend.sh"
[[ -x "$INJECT" ]] || chmod +x "$INJECT" 2>/dev/null || true

RUN_ID="${SCENARIO}_${DOMAIN}_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$OUTDIR/$RUN_ID"
mkdir -p "$RUN_DIR"
MANIFEST="$RUN_DIR/manifest.tsv"

printf 'scenario\tdomain\tduration_s\titeration\tstart_utc\tend_utc\tlogfile\n' > "$MANIFEST"

echo "=== 场景矩阵 $SCENARIO / 域 $DOMAIN ==="
echo "档位: $LADDER"
echo "每档重复: $REPEAT 次, 间隔: ${GAP}s"
echo "归档目录: $RUN_DIR"
TOTAL=0
for d in $LADDER; do TOTAL=$((TOTAL + REPEAT)); done
echo "总注入次数: $TOTAL, 预计耗时约 $(( (TOTAL * GAP) / 60 )) 分钟(不含注入时长)"
echo

for dur in $LADDER; do
  for i in $(seq 1 "$REPEAT"); do
    START="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    echo "--- [$SCENARIO] ${dur}s  第 $i/$REPEAT 次  @ $START ---"

    if [[ "$DRYRUN" -eq 1 ]]; then
      echo "  (dry-run) $INJECT -d $DOMAIN -t $dur -g ${SCENARIO}_${dur}s_$i"
      LOGF="(dry-run)"
    else
      OUTDIR="$RUN_DIR" "$INJECT" -d "$DOMAIN" -t "$dur" -g "${SCENARIO}_${dur}s_$i" \
        | tee "$RUN_DIR/run_${dur}s_${i}.out"
      LOGF="$RUN_DIR/run_${dur}s_${i}.out"
    fi

    END="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SCENARIO" "$DOMAIN" "$dur" "$i" "$START" "$END" "$LOGF" >> "$MANIFEST"

    echo "  恢复观察 ${GAP}s ..."
    [[ "$DRYRUN" -eq 1 ]] || sleep "$GAP"
  done
done

echo
echo "=== 完成 ==="
echo "清单: $MANIFEST"
echo "下一步: 用 collect/ob_events.sh 按 manifest 的时间窗提取 DBA_OB_SERVER_EVENT_HISTORY"
