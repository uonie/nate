# 脚本说明

> **⚠️ 全部脚本仅供测试环境使用，严禁在生产环境执行任何注入操作。**

## 目录

```
scripts/
├── inject/           抖动注入
│   ├── dm_suspend.sh     主手段: dmsetup suspend/resume 精确停顿
│   ├── dm_shim.sh        环境搭建: 在裸盘上建 dm 垫层(供 delay/flakey 使用)
│   ├── shim_inject.sh    对照手段: dm-delay 固定延迟 / dm-flakey 停顿+错误
│   └── run_matrix.sh     按时长档位批量执行并归档
├── collect/          观测采集
│   ├── start_collect.sh      启动 OS 层采集(iostat/vmstat/dmesg/nvme)
│   ├── stop_collect.sh       停止采集
│   ├── ob_events.sh          OB 层: 事件历史/leader 分布/参数基线  ← 切主权威判据
│   └── scan_observer_log.sh  observer.log 签名扫描  ← H1/H2 判定辅助
└── tuning/           调优
    ├── l1_os.sh          L1: OS/内核 (nvme_core.io_timeout=240、swap、队列、dirty)
    ├── l3_tuning.sql     L3: OB 磁盘故障判定模型  ← 关键层
    └── l3_rollback.sql   L3: 恢复出厂默认值
```

---

## 快速上手

### 1. 环境准备

```bash
chmod +x scripts/inject/*.sh scripts/collect/*.sh scripts/tuning/*.sh

# 检查 L1 现状(只读, 不修改)
sudo ./scripts/tuning/l1_os.sh check

# 导出参数基线
OB_PASS=xxx ./scripts/collect/ob_events.sh -m params -o data/baseline_params.tsv
```

### 2. 若要做单盘注入(场景 S8) —— 必须在建 LVM 之前

```bash
# 为 clog 的 4 块盘建立 dm 垫层
sudo ./scripts/inject/dm_shim.sh create shim_clog /dev/nvme{1,2,3,4}n1

# 用垫层设备建 LVM
sudo pvcreate /dev/mapper/shim_clog_{0,1,2,3}
sudo vgcreate oblogvg /dev/mapper/shim_clog_{0,1,2,3}
sudo lvcreate -i 4 -I 128k -l 100%FREE -n obloglv oblogvg
```

### 3. 执行一轮场景

```bash
# 启动采集(每个节点都要跑)
sudo ./scripts/collect/start_collect.sh ./data/S1_collect

# 另开终端: 持续记录 leader 分布
OB_PASS=xxx ./scripts/collect/ob_events.sh -m watch -o data/S1_leader_watch.tsv

# 预热 10min + 基线 5min 后开始注入
sudo ./scripts/inject/run_matrix.sh -d clog -s S1

# 停止采集
sudo ./scripts/collect/stop_collect.sh ./data/S1_collect

# 按 manifest 时间窗提取事件(切主的权威判据)
OB_PASS=xxx ./scripts/collect/ob_events.sh -m events \
  -f '2026-08-30 10:00:00' -t '2026-08-30 12:00:00' -o data/S1_events.tsv

# 扫描 observer.log 签名
sudo ./scripts/collect/scan_observer_log.sh \
  -f '2026-08-30 10:00:00' -t '2026-08-30 12:00:00' -o data/S1_logscan.txt
```

### 4. H1 / H2 判定实验（最高优先级）

```bash
# 只调 failure detector, 不动其他任何参数
obclient -h127.0.0.1 -P2881 -uroot@sys -p -Doceanbase <<'SQL'
ALTER SYSTEM SET log_storage_warning_tolerance_time     = '60s';
ALTER SYSTEM SET log_storage_warning_trigger_percentage = 20;
SQL

# 阈值密集区注入
sudo ./scripts/inject/run_matrix.sh -d clog -s H1H2 -L "2 4 5 6 8 10"
```

判定：

| 观测现象 | 结论 |
|---|---|
| 切主消失，直到停顿远超 60s 才出现 | **H1 成立** → 调参可完全吸收 |
| 切主仍稳定发生在 ~3-4s，与参数无关 | **H2 成立** → PALF 租约 4s 为硬上限 |

辅助佐证：`scan_observer_log.sh` 输出中，
`[C] PALF 选举租约` 分组有匹配 → 指向 H2；
`[D] failure detector` 分组有匹配 → 指向 H1。

---

## 安全机制

| 脚本 | 机制 |
|---|---|
| `dm_suspend.sh` | 派生看门狗进程，在 `停顿时长 + 30s` 后强制 `resume`；`trap EXIT` 兜底 |
| `shim_inject.sh` | 原始 linear table 保存在 `/run/ob_jitter_shim/`，`trap EXIT` 自动恢复；指定 `-t` 时到时自动恢复 |
| `l1_os.sh` | 默认 `check` 只读；`apply` 前备份 `/etc/default/grub` 与 `/etc/fstab`；提供 `rollback` |
| `run_matrix.sh` | 支持 `-N` dry-run；场景间隔默认 60s 确保状态复位 |

**若脚本异常中断导致设备卡在 SUSPENDED**：

```bash
dmsetup info <name> | grep State      # 确认状态
dmsetup resume <name>                 # 手动恢复
```

---

## 方法论局限（报告中必须声明）

`dmsetup suspend` 只停顿、不返回 I/O 错误。真实平台事件是否伴随错误返回未知，
因此必须用 `shim_inject.sh -m flakey` 做"停顿 + 错误"对照组，界定该方法论的有效边界。
