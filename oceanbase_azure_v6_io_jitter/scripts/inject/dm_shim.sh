#!/usr/bin/env bash
#
# dm_shim.sh — 在裸盘(PV)之上建立 device-mapper 垫层, 供后续注入延迟/错误
#
# 背景:
#   dm-delay / dm-flakey 需要在目标设备之上叠加一层 dm target。
#   对已经存在的条带化 LV 无法直接替换 table(striped table 含多个底层设备),
#   因此正确做法是在【搭建测试环境时】先给每块 PV 套一层 linear 垫层,
#   再用垫层设备去做 pvcreate/vgcreate。
#   之后即可在运行时通过 shim_inject.sh 把某块盘的 table 在
#   linear <-> delay <-> flakey 之间热切换, 实现单盘精确注入(场景 S8)。
#
# !! 测试环境专用, 必须在创建 LVM 之前执行 !!
#
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  dm_shim.sh create <prefix> <dev1> [dev2 ...]    # 为每块裸盘创建 linear 垫层
  dm_shim.sh list   [prefix]                      # 列出已创建的垫层
  dm_shim.sh remove <prefix>                      # 删除全部垫层(需先 vgremove)

示例:
  # 为 clog 的 4 块盘创建垫层, 得到 /dev/mapper/shim_clog_0 .. _3
  dm_shim.sh create shim_clog /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1

  # 随后用垫层设备建 LVM
  pvcreate /dev/mapper/shim_clog_{0,1,2,3}
  vgcreate oblogvg /dev/mapper/shim_clog_{0,1,2,3}
  lvcreate -i 4 -I 128k -l 100%FREE -n obloglv oblogvg
EOF
}

[[ $# -lt 1 ]] && { usage; exit 1; }
[[ $EUID -ne 0 ]] && { echo "ERROR: 需要 root 权限" >&2; exit 1; }

ACTION="$1"; shift

case "$ACTION" in
  create)
    PREFIX="$1"; shift
    [[ $# -lt 1 ]] && { echo "ERROR: 至少指定一块设备" >&2; exit 1; }
    i=0
    for dev in "$@"; do
      [[ -b "$dev" ]] || { echo "ERROR: 不是块设备: $dev" >&2; exit 1; }
      sectors="$(blockdev --getsz "$dev")"
      name="${PREFIX}_${i}"
      echo "0 $sectors linear $dev 0" | dmsetup create "$name"
      echo "created /dev/mapper/$name  <- $dev  ($sectors sectors)"
      i=$((i + 1))
    done
    ;;

  list)
    PREFIX="${1:-shim_}"
    dmsetup ls | grep "^${PREFIX}" || echo "(无匹配垫层)"
    echo
    for name in $(dmsetup ls | awk '{print $1}' | grep "^${PREFIX}" || true); do
      printf '%-24s %s\n' "$name" "$(dmsetup table "$name")"
    done
    ;;

  remove)
    PREFIX="$1"
    for name in $(dmsetup ls | awk '{print $1}' | grep "^${PREFIX}" || true); do
      dmsetup remove "$name" && echo "removed $name"
    done
    ;;

  *)
    usage; exit 1 ;;
esac
