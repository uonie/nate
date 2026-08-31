#!/usr/bin/env bash
#
# l1_os.sh — L1 层: OS / 内核调优  (Rocky Linux 9 / RHEL 9)
#
# 内容:
#   0. 记录 OS / 内核版本
#   1. nvme_core.io_timeout = 240   [官方] Microsoft Learn 明确要求
#      (Linux 内核上游默认仅 30s, 见 drivers/nvme/host/core.c)
#   2. 关闭 swap (或移出 OS 盘) + vm.swappiness=0  [官方] OB 官方要求
#   3. I/O 调度器与队列深度  (NVMe 默认即为 none, 通常无需调整)
#   4. vm.dirty_* 回写参数
#   5. 复核 THP / NUMA / tuned profile
#
# 用法:
#   ./l1_os.sh check    只检查当前状态, 不修改  (默认)
#   ./l1_os.sh apply    应用变更 (nvme 超时需重启生效)
#   ./l1_os.sh rollback 回滚变更
#
set -euo pipefail

ACTION="${1:-check}"
NVME_TIMEOUT=240
BACKUP="/etc/default/grub.ob_jitter.bak"
MODPROBE_CONF="/etc/modprobe.d/99-ob-nvme-timeout.conf"
SYSCTL_CONF="/etc/sysctl.d/99-ob-jitter.conf"

require_root() { [[ $EUID -ne 0 ]] && { echo "ERROR: 需要 root 权限" >&2; exit 1; }; return 0; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

check() {
  hr; echo "L1 OS 调优状态检查  @ $(hostname)"; hr

  echo "[0] 系统版本"
  printf '    OS        : %s\n' "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf '    内核      : %s\n' "$(uname -r)"

  echo
  echo "[1] nvme_core.io_timeout   期望: $NVME_TIMEOUT   [官方] MS Learn 要求"
  echo "    参考: 内核上游默认 30s; Azure 较新镜像出厂 240s, 较旧镜像 30s"
  if [[ -r /sys/module/nvme_core/parameters/io_timeout ]]; then
    cur="$(cat /sys/module/nvme_core/parameters/io_timeout)"
    printf '    运行时值 : %s  %s\n' "$cur" "$([[ "$cur" == "$NVME_TIMEOUT" ]] && echo '✔' || echo '✘ 需调整')"
  else
    echo "    运行时值 : (不可读, 可能非 NVMe 环境)"
  fi
  if grep -q 'nvme_core.io_timeout' /proc/cmdline 2>/dev/null; then
    printf '    内核命令行: %s ✔\n' "$(tr ' ' '\n' < /proc/cmdline | grep nvme_core.io_timeout)"
  else
    echo "    内核命令行: 未设置 ✘  (重启后会回到镜像默认值)"
  fi
  if [[ -f "$MODPROBE_CONF" ]]; then
    printf '    modprobe.d: %s ✔\n' "$(cat "$MODPROBE_CONF")"
  else
    echo "    modprobe.d: 未设置"
  fi

  echo
  echo "[2] swap / swappiness   期望: swap 关闭, vm.swappiness=0  [官方] OB 要求"
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    swapon --show | sed 's/^/    /'
    echo "    ✘ swap 已启用 —— OS 盘停顿时内存回收会被阻塞"
  else
    echo "    ✔ 未启用 swap"
  fi
  sw="$(sysctl -n vm.swappiness 2>/dev/null || echo '-')"
  printf '    vm.swappiness = %s  %s\n' "$sw" "$([[ "$sw" == "0" ]] && echo '✔' || echo '✘ OB 官方要求 0')"

  echo
  echo "[3] 块设备队列参数   期望: NVMe scheduler=none (RHEL9 默认即 none)"
  for q in /sys/block/nvme*/queue /sys/block/dm-*/queue; do
    [[ -d "$q" ]] || continue
    dev="$(basename "$(dirname "$q")")"
    sched="$(cat "$q/scheduler" 2>/dev/null || echo -)"
    nrq="$(cat "$q/nr_requests" 2>/dev/null || echo -)"
    printf '    %-10s scheduler=%-28s nr_requests=%s\n' "$dev" "$sched" "$nrq"
  done

  echo
  echo "[4] vm.dirty_* 回写参数   (内核上游默认: dirty_ratio=20, background=10)"
  sysctl vm.dirty_ratio vm.dirty_background_ratio \
         vm.dirty_expire_centisecs vm.dirty_writeback_centisecs 2>/dev/null | sed 's/^/    /'

  echo
  echo "[5] THP / NUMA / tuned   期望: THP=never, numa=off"
  printf '    THP       : %s\n' "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '(N/A)')"
  if grep -q 'numa=off' /proc/cmdline 2>/dev/null; then
    echo "    numa      : off ✔"
  else
    echo "    numa      : 未在内核命令行禁用"
  fi
  if command -v tuned-adm >/dev/null 2>&1; then
    prof="$(tuned-adm active 2>/dev/null | sed 's/^.*: //')"
    printf '    tuned     : %s\n' "${prof:-未运行}"
    case "$prof" in
      *virtual-guest*|*throughput-performance*)
        echo "    ⚠ 该 profile 会设置 vm.swappiness=30 / dirty_bytes=30~40%,"
        echo "      可能覆盖 /etc/sysctl.conf 中 OB 要求的 vm.swappiness=0。"
        echo "      处理方式: tuned 中追加自定义 profile, 或停用 tuned 后用 sysctl.d 固化。" ;;
    esac
  else
    echo "    tuned     : 未安装"
  fi
  hr
}

apply() {
  require_root
  hr; echo "应用 L1 调优"; hr

  # --- 1. nvme_core.io_timeout ---
  echo "[1] nvme_core.io_timeout -> $NVME_TIMEOUT"
  if [[ -w /sys/module/nvme_core/parameters/io_timeout ]]; then
    echo "$NVME_TIMEOUT" > /sys/module/nvme_core/parameters/io_timeout
    echo "    运行时已生效(仅对新提交的 I/O 有效): $(cat /sys/module/nvme_core/parameters/io_timeout)"
  fi

  # 1a. 内核命令行 —— RHEL9/Rocky9 优先用 grubby
  if command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --remove-args="nvme_core.io_timeout" >/dev/null 2>&1 || true
    grubby --update-kernel=ALL --args="nvme_core.io_timeout=$NVME_TIMEOUT"
    echo "    grubby 已更新所有内核条目"
    grubby --info=DEFAULT 2>/dev/null | grep -m1 '^args=' | sed 's/^/      /' || true
  elif [[ -f /etc/default/grub ]]; then
    [[ -f "$BACKUP" ]] || cp -a /etc/default/grub "$BACKUP"
    if grep -q 'nvme_core.io_timeout=' /etc/default/grub; then
      sed -i "s/nvme_core\.io_timeout=[0-9]\+/nvme_core.io_timeout=$NVME_TIMEOUT/" /etc/default/grub
    else
      sed -i "s/^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"/\1 nvme_core.io_timeout=$NVME_TIMEOUT\"/" /etc/default/grub
    fi
    echo "    /etc/default/grub 已更新 (备份: $BACKUP)"
    if [[ -d /sys/firmware/efi ]]; then
      GRUB_CFG="$(ls /etc/grub2-efi.cfg /boot/efi/EFI/*/grub.cfg 2>/dev/null | head -1)"
    else
      GRUB_CFG="$(ls /etc/grub2.cfg /boot/grub2/grub.cfg 2>/dev/null | head -1)"
    fi
    [[ -n "${GRUB_CFG:-}" ]] && grub2-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1 \
      && echo "    grub 已重新生成: $GRUB_CFG"
  else
    echo "    WARN: 既无 grubby 也无 /etc/default/grub, 请手动持久化"
  fi

  # 1b. 模块参数 + 重建 initramfs (nvme 驱动在 initramfs 中加载)
  echo "options nvme_core io_timeout=$NVME_TIMEOUT" > "$MODPROBE_CONF"
  echo "    已写入 $MODPROBE_CONF"
  if command -v dracut >/dev/null 2>&1; then
    dracut -f --regenerate-all >/dev/null 2>&1 && echo "    initramfs 已重建 (dracut -f --regenerate-all)"
  fi
  echo "    !! 需重启后才完全生效 !!"

  # --- 2. swap + swappiness ---
  echo
  echo "[2] 关闭 swap"
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    swapoff -a && echo "    已 swapoff -a"
    if [[ -f /etc/fstab ]]; then
      cp -a /etc/fstab /etc/fstab.ob_jitter.bak
      sed -i '/\sswap\s/ s/^\([^#]\)/#\1/' /etc/fstab
      echo "    /etc/fstab 中 swap 条目已注释 (备份: /etc/fstab.ob_jitter.bak)"
    fi
  else
    echo "    已是关闭状态"
  fi

  # --- 3. 队列参数 ---
  echo
  echo "[3] 块设备队列参数"
  for q in /sys/block/nvme*/queue; do
    [[ -d "$q" ]] || continue
    dev="$(basename "$(dirname "$q")")"
    if grep -qw 'none' "$q/scheduler" 2>/dev/null; then
      echo none > "$q/scheduler" 2>/dev/null && echo "    $dev scheduler -> none"
    fi
    [[ -w "$q/nr_requests" ]] && { echo 1024 > "$q/nr_requests" 2>/dev/null && echo "    $dev nr_requests -> 1024"; } || true
  done
  echo "    注: sysfs 变更重启后失效, 生产环境请写入 udev 规则或 tuned profile"

  # --- 4. sysctl ---
  echo
  echo "[4] sysctl (降低脏页积压 + OB 要求的 swappiness=0)"
  cat > "$SYSCTL_CONF" <<'EOF'
# OceanBase I/O 抖动韧性调优 (L1)
# swappiness: OB 官方服务器配置文档要求为 0
vm.swappiness = 0
# 降低脏页水位, 减小停顿期回写风暴 (内核上游默认 20/10)
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
EOF
  sysctl -p "$SYSCTL_CONF" | sed 's/^/    /'
  if command -v tuned-adm >/dev/null 2>&1 && tuned-adm active >/dev/null 2>&1; then
    echo "    ⚠ tuned 正在运行, 其 profile 可能在重启后覆盖上述 sysctl。"
    echo "      请执行 '$0 check' 复核, 必要时停用 tuned 或自定义 profile。"
  fi

  hr
  echo "完成。请重启使 nvme_core.io_timeout 生效, 然后运行: $0 check"
}

rollback() {
  require_root
  hr; echo "回滚 L1 调优"; hr
  if command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --remove-args="nvme_core.io_timeout" >/dev/null 2>&1 \
      && echo "  已从内核命令行移除 nvme_core.io_timeout"
  fi
  if [[ -f "$BACKUP" ]]; then
    cp -a "$BACKUP" /etc/default/grub && echo "  已恢复 /etc/default/grub"
  fi
  [[ -f "$MODPROBE_CONF" ]] && { rm -f "$MODPROBE_CONF"; echo "  已移除 $MODPROBE_CONF"; }
  command -v dracut >/dev/null 2>&1 && dracut -f --regenerate-all >/dev/null 2>&1 \
    && echo "  initramfs 已重建"
  [[ -f /etc/fstab.ob_jitter.bak ]] && { cp -a /etc/fstab.ob_jitter.bak /etc/fstab; echo "  已恢复 /etc/fstab"; }
  [[ -f "$SYSCTL_CONF" ]] && { rm -f "$SYSCTL_CONF"; echo "  已移除 $SYSCTL_CONF"; }
  echo "  请重启使内核命令行变更生效"
  hr
}

case "$ACTION" in
  check)    check ;;
  apply)    apply; echo; check ;;
  rollback) rollback ;;
  *) echo "用法: $0 {check|apply|rollback}" >&2; exit 1 ;;
esac
