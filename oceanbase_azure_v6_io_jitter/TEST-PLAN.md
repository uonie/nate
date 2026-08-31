# 测试执行方案：OceanBase on Azure v6 存储 I/O 抖动韧性验证

> 配套文档：[`README.md`](README.md)（分析报告） / [`scripts/`](scripts/)（脚本）

---

## 1. 测试目标

用可复现、可证伪的实验回答四个问题：

| # | 问题 | 判定方式 |
|---|---|---|
| Q1 | Azure v6 上 OB 的基线表现如何 | 无注入时的 TPS / P99 / I/O 延迟分布；与官方 VM 级上限（**66,667 IOPS / 1,984 MBps**）对比达成率 |
| Q2 | 默认参数下 I/O 停顿会造成什么影响 | 逐档位注入，记录切主 / 停机 / 业务错误 |
| Q3 | **能否通过调参完全吸收** | **`tolerance_time` 门槛标定实验（§5.1）** —— 验证源码结论"切主由 failure detector 触发、不经过 PALF 租约" |
| Q4 | 最佳实践配置是什么 | 分层调优的贡献度对比（§6）+ A/B 布局对比（S11） |

---

## 2. 测试环境

### 2.1 集群

| 项 | 配置 |
|---|---|
| 节点 | 3 × Standard **D32s v6**（对齐客户），分布 zone1 / zone2 / zone3 |
| 副本模式 | **3F 三副本 1-1-1**，多数派 2/3 |
| OB 版本 | **4.3.5.5**（必须与客户一致） |
| OBProxy | 4.3.1.6 |
| OS | **Rocky Linux 9.8**（与客户一致）。部署后立即核实 `uname -r` 与 `cat /sys/module/nvme_core/parameters/io_timeout` —— Azure NVMe 支持镜像清单中 Rocky 分支只到 9.6，9.8 的出厂超时值需实测确认 |
| tuned | 记录 `tuned-adm active`。若为 `virtual-guest` / `throughput-performance`，需先解决其 `vm.swappiness=30` 与 OB 要求 `vm.swappiness=0` 的冲突（见 README §8 L1） |

### 2.2 磁盘两组对照

| 组 | data (`/data/1`) | clog (`/data/log1`) | admin (`/home/admin`) |
|---|---|---|---|
| **A：客户现状** | 6 × 300G PSSDv2，`-i 6 -I 128k` | 4 × 250G PSSDv2，`-i 4 -I 128k` | 1 × 400G |
| **B：优化布局** | **1 × 1.8T PSSDv2**，provisioned **64,000 IOPS / 1,900 MB/s** | **1 × 1T PSSDv2**，provisioned **32,000 IOPS / 1,900 MB/s** | 1 × 400G |

A 组用于复现客户问题，B 组用于验证 §L2 布局建议的收益。

**B 组 provisioned 值的依据** [官方]：Standard_D32s_v6 的 VM 级 uncached 上限为 66,667 IOPS / 1,984 MBps；
单块 PSSDv2 只要 ≥160 GiB 即可 provision 到 80,000 IOPS，8,000 IOPS 以上即可达 2,000 MB/s。
因此单盘足以顶到 VM 上限，无需条带化。

**B 组必须验证的关键命题**：在 D32s v6 上，`1 块 provisioned 盘` 的吞吐/IOPS/延迟
与 `4~6 块盘条带` **无显著差异**（因 VM 级上限先封顶），但抖动暴露面从 4~6× 降到 1×。
若实测推翻该命题（例如条带化确实更快），则 L2 建议需要重写。

### 2.3 拓扑对照

| 组 | leader 分布 | 均衡开关 |
|---|---|---|
| **集中组**（复刻客户） | 5 个日志流中 4 个 leader 固定在同一节点 | `enable_rebalance=FALSE`、`enable_transfer=FALSE` |
| **均衡组**（对照） | leader 均匀分布于 3 节点 | 同上（保持变量单一） |

### 2.4 负载

| 负载 | 工具 | 档位 |
|---|---|---|
| OLTP 读写混合 | `sysbench oltp_read_write` | 中（50 并发）/ 高（200 并发） |
| TPC-C | `BenchmarkSQL` | 中 / 高 |

每个场景执行前先跑 **10 分钟预热 + 5 分钟基线采样**，确认 TPS 稳定后再注入。

---

## 3. 三个磁盘域独立测试

**核心原则：每个域单独注入、单独取数、单独出结论，最后才做组合注入。**

| 域 | 挂载点 | 承载内容 | 关注的判定路径 |
|---|---|---|---|
| **A. OS 盘** | `/`、`/boot`、swap | 系统、二进制、swap | 是否波及 DB 线程；`enable_async_syslog` 保护是否生效 |
| **B. 数据盘** | `/data/1` | SSTable / 数据文件 | `_data_storage_io_timeout` → `data_storage_warning_tolerance_time` → ERROR |
| **C. 日志盘** | `/data/log1` | clog / PALF | `log_storage_warning_*` → leader coordinator → **切主** |
| **D. admin 盘** | `/home/admin` | observer.log | 日志写阻塞是否反压数据库线程 |

> 预期 C 域最敏感、A 域最不敏感 —— 但**必须实测证明，不得凭推断下结论**。

---

## 4. 注入方法

### 4.1 主手段：`dmsetup suspend/resume`

```bash
dmsetup suspend <dm-device>
sleep N
dmsetup resume <dm-device>
```

**原理**：`suspend` 后所有到达该 device-mapper 设备的 I/O 全量排队，N 秒后 `resume` 一次性放行。

**有效性论证**：与现场日志特征一致 —— `submit_used` 与 `return_used` 两侧均阻塞、`enqueue_used`/`dequeue_used` 为个位数微秒，即阻塞发生在块设备层而非应用队列 [现场]。

**局限（必须在报告中声明）**：`suspend` 只停顿、不返回错误。真实平台事件是否伴随 I/O 错误返回未知，因此需 `dm-flakey` 对照组界定方法论边界。

### 4.2 对照手段

| 手段 | 用途 |
|---|---|
| `dm-delay` | 注入固定高延迟（非全停），验证"持续劣化"模型 |
| `dm-flakey` | 注入"停顿 + I/O 错误返回"，界定 4.1 的方法论边界 |
| `cgroup v2 io.max` | 限流，模拟吞吐塌陷而非完全 hang |

### 4.3 注入粒度

| 粒度 | 目标 | 用途 |
|---|---|---|
| 整卷 | `/dev/mapper/oblogvg-obloglv` 等 | 常规场景 |
| **单块底层 PV** | 条带中的某一块 PSSDv2 | **验证条带化放大效应（S8）** |

### 4.4 时长档位

**2s / 4s / 5s / 6s / 8s / 10s / 15s / 20s / 30s / 60s / 120s**

密集覆盖四条阈值线两侧：

| 阈值 | 值 | 周边档位 |
|---|---|---|
| PALF 有效容忍窗口 | ~3s | 2s / 4s |
| PALF 选举租约 | 4s | 4s / 5s |
| `*_storage_warning_tolerance_time` | 5s | 4s / 5s / 6s |
| `_data_storage_io_timeout` | 10s | 8s / 10s / 15s |

每个档位**重复 5 次**取分布，避免单次偶然。

---

## 5. 场景矩阵

**默认参数组与调优参数组各跑一遍完整矩阵。**

| 编号 | 注入域 | 时长档 | 节点范围 | 验证点 |
|---|---|---|---|---|
| **S1** | C 日志盘 | 全档位 | leader | **切主的精确触发阈值** |
| **S2** | B 数据盘 | 全档位 | leader | warning / error 阈值行为 |
| **S3** | A OS 盘（+swap） | 全档位 | leader | 是否波及 DB 线程 |
| **S4** | D admin 盘 | 全档位 | leader | syslog 阻塞是否反压 |
| **S5** | A+B+C 同时 | 10/20/30s | leader | 叠加效应 |
| **S6** | C 日志盘 | 15s | **follower** | 多数派(2/3)是否吸收，业务是否无感 |
| **S7** | C 日志盘 | 15s | **全部 3 节点** | **多数派同时失效 —— 架构无法兜底的场景** |
| **S8** | 单块底层 PV | 15s | leader | **条带化放大效应** |
| **S9** | 周期抖动（每 5min 15s，持续 1h） | — | 随机节点 | 长期累积效应、切主抖动(flapping) |
| **S10** | C 日志盘 | 15s | leader 集中组 vs 均衡组 | **量化 leader 集中的放大倍数** |
| **S11** | 无注入（纯性能） | — | A 组布局 vs B 组布局 | **验证"条带化换不来性能"命题**：对比 TPS/IOPS/吞吐/P99 |

### 5.1 `tolerance_time` 门槛标定实验（最高优先级）

源码已确认：切主由 failure detector 的 FATAL 事件经优先级降级触发，**不经过 PALF 4s 硬编码租约**（见 README §5.1）。本实验的目的因此从"判定 H1/H2"变为**标定实际生效门槛并验证源码结论**。

**步骤**：

```sql
-- 1) 只放宽 log 侧 tolerance_time，其余一律不动
ALTER SYSTEM SET log_storage_warning_tolerance_time = '60s';
-- ⚠️ 不要调 log_storage_warning_trigger_percentage，保持默认 0
--    源码中它与 has_long_pending_io 是 || 关系，调大会使检测更敏感
```

```bash
# 2) 对 leader 节点的日志盘做密集档位注入，每档 5 次
#    重点覆盖 4s(PALF 租约) 与 5s(默认 tolerance) 两条线的两侧
for d in 2 4 5 6 8 10 15 30 45 60 90; do
  for i in $(seq 1 5); do
    ./scripts/inject/dm_suspend.sh -d clog -t $d
    sleep 90     # > read_failure_black_list_interval(60s)，确保状态完全恢复
  done
done
```

**3) 判定**：

| 观测现象 | 结论 |
|---|---|
| 切主全部消失，直到停顿 > 60s 才重新出现 | **源码结论得到验证** → 门槛确由 `tolerance_time` 决定，调参可吸收 |
| 切主仍稳定发生在 ~3-4s，与参数无关 | 源码结论不成立，存在未识别的租约依赖路径 → 需重新分析 |
| 出现在两者之间的某个固定值 | 记录实际分界点，反查对应源码路径 |

**4) 对照组**：同样档位下把 `log_storage_warning_trigger_percentage` 从 0 调到 20 再跑一遍。

> **预期（源码推论）**：调到 20 后切主**不会减少，反而可能增多** —— 因为新增了
> `is_perf_decrease_error` / `has_small_pending_io` 两条判定路径。
> 若实测证实这一点，即为 §3.3.1 源码分析的直接验证。

**辅助佐证**：切主事件的权威判据是事件表，而非日志：

```sql
SELECT gmt_create, svr_ip, module, event, name1, value1, name2, value2
FROM oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE module = 'FAILURE_DETECTOR'
ORDER BY gmt_create DESC LIMIT 50;
```

| 观测到的记录 | 指向 |
|---|---|
| `FAILURE_MODULE = LOG`，`FAILURE_TYPE = PROCESS_HANG` | 日志盘链路（§3.3） |
| `FAILURE_MODULE = STORAGE`，`FAILURE_TYPE = PROCESS_HANG` | 数据盘链路（§3.2） |
| `observer.log` 中 `LeaseExpiredToRevoke` / `leader_lease_expired` | PALF 租约路径（源码推论认为不应出现） |

---

## 6. 分层调优与贡献度分析

**必须逐层单独加、单独测，量化每层贡献度。不允许一次性全加然后归因。**

| 层 | 内容 | 单独验证的场景 |
|---|---|---|
| **L1 OS/内核** | `nvme_core.io_timeout=240`（grubby + modprobe.d + dracut）、关闭 swap、`vm.swappiness=0`、核实 tuned profile、`vm.dirty_*` | S1/S2/S3 全档位 |
| **L2 存储布局** | A 组 → B 组（降条带数、provisioned IOPS）、clog 水位降至 60% | S1/S2/S8/S11 |
| **L3 OB 判定模型** | `log_storage_warning_tolerance_time` 5s→60s、`data_storage_warning_tolerance_time` 5s→60s（**`trigger_percentage` 保持 0**） | **S1（关键）** |
| **L4 缓冲/节流** | `freeze_trigger_percentage`、`memstore_limit_percentage`、`writing_throttling_*`、`syslog_io_bandwidth_limit` | S1/S2 |
| **L5 接入层/应用** | obproxy 拉黑与重试策略、连接池超时、幂等重试 | S1/S7 |

### 6.1 执行顺序

```
基线（全默认）
  → +L1        → 测 → 记录 Δ
  → +L1+L2     → 测 → 记录 Δ
  → +L1+L2+L3  → 测 → 记录 Δ   ← 预期这一层贡献最大
  → +L1..L4    → 测 → 记录 Δ
  → +L1..L5    → 测 → 记录 Δ
```

同时做**单层剥离**验证：`全量 − L3` 与 `全量`对比，确认 L3 的必要性。

---

## 7. 观测指标与采集

### 7.1 业务面

| 指标 | 采集方式 |
|---|---|
| TPS / QPS | sysbench / BenchmarkSQL 逐秒输出 |
| P99 / P999 延迟 | 同上 |
| 错误码分布 | 应用侧捕获 `-4012`(超时) / `-6002`(事务回滚) / `-4038`(not master) / `-4023`(重试) / `-4389`(IO 等待过久) / `-4392` |
| 连接中断时长 | 客户端连接状态采样 |
| 恢复时长 | TPS 从跌落到回归基线 95% 的时间 |

### 7.2 OceanBase 面

| 指标 | 采集方式 |
|---|---|
| **切主 / 停机事件** | `DBA_OB_SERVER_EVENT_HISTORY` ← **切主的权威判据** |
| leader 变更 | `GV$OB_LOG_STAT` 轮询 |
| I/O 状态 | `GV$OB_IO_*` |
| 参数基线 | `GV$OB_PARAMETERS` 全量导出（每组测试前后各一次） |
| 日志签名 | `observer.log` 中 `-4389`、`LeaseExpiredToRevoke`、disk status 变更 |

### 7.3 OS 面

| 指标 | 采集方式 |
|---|---|
| await / aqu-sz / util | `iostat -x 1` |
| 块层轨迹 | `blktrace` / `blkparse`（仅在需要深挖时开启） |
| NVMe 错误 | `nvme error-log`、`dmesg` |
| 内存/swap | `vmstat 1` |

### 7.4 时间同步

所有节点与采集端必须启用 NTP/chrony，注入脚本记录**精确到毫秒的注入起止时间戳**，便于与 OB 日志对齐。

---

## 8. "完全吸收"的判定标准

**三条必须全部满足**，缺一即不算完全吸收：

1. **`DBA_OB_SERVER_EVENT_HISTORY` 中无切主、无停机事件**；
2. **应用侧零报错、无连接中断**；
3. **仅出现与停顿时长同量级的延迟毛刺，停顿结束后 TPS 立即回到基线（≥95%）**。

### 8.1 分档预期与实测记录表

> **⚠️ 本表左侧两列是「待验证的假设」，不是数据**
>
> "源码推论"列由 README §3.2 / §3.3 / §5.1 的源码分析推导而来，属 **[待验证]** 等级，
> **禁止作为结论对外引用**。它的唯一用途是**给出可证伪的预测**——
> 实测跑出来若与预测不符，说明源码分析有误，必须回溯修正。
>
> "实测"列在执行 §5 场景后据实填写，并附原始数据文件路径。**空着就是还没测，不要填猜测值。**

| 停顿时长 | 默认参数（5s）<br>源码推论 [待验证] | 默认参数<br>**实测** | 调优后（60s）<br>源码推论 [待验证] | 调优后<br>**实测** |
|---|---|---|---|---|
| 2s | 预期无切主 | _未测_ | 预期无切主 | _未测_ |
| 4s | 预期无切主（PALF 租约走 RPC，不受磁盘影响） | _未测_ | 预期无切主 | _未测_ |
| 5s | 预期临界（判定条件为 `>` 严格大于） | _未测_ | 预期无切主 | _未测_ |
| 6s | 预期切主（日志盘 `has_long_pending_io`） | _未测_ | 预期无切主 | _未测_ |
| 8s | 预期切主（日志盘） | _未测_ | 预期无切主 | _未测_ |
| 10s | 预期切主（日志盘；数据盘开始计时） | _未测_ | 预期无切主 | _未测_ |
| 15s | 预期切主（日志盘 + 数据盘 WARNING 临界 10+5） | _未测_ | 预期无切主 | _未测_ |
| 20s | 预期切主（日志盘 + 数据盘 WARNING） | _未测_ | 预期无切主 | _未测_ |
| 30s | 预期切主（同上） | _未测_ | 预期无切主 | _未测_ |
| 60s | 预期切主（同上） | _未测_ | 预期临界（`>` 严格大于） | _未测_ |
| 120s | 预期切主（同上） | _未测_ | 预期切主 | _未测_ |
| 300s+ | 预期切主，且可能进入 ERROR（`data_storage_error_tolerance_time`） | _未测_ | 预期切主，且可能进入 ERROR | _未测_ |

**实测列的填写口径**：只填三种值 —— `无切主` / `切主` / `停机`，并在备注中附
`DBA_OB_SERVER_EVENT_HISTORY` 的对应记录与原始数据目录。**不得填写推测或"应该"。**

**结论分类**（每档在实测完成后判定）：

| 分类 | 含义 |
|---|---|
| **完全吸收** | §8 开头三条判定标准全部满足 |
| **部分收敛** | 无切主，但业务侧有报错或 TPS 恢复滞后 |
| **无法吸收** | 仍发生切主或停机 |

> **本表最关键的一行是 6s**：源码推论认为默认参数下会切主、调优后不会。
> **这一行的实测结果直接决定 Q3（"能否通过调参完全吸收"）的答案** ——
> 在跑出这一行之前，Q3 的答案只能表述为"源码分析表明可以，待实测确认"。

### 8.2 副作用记录表（必填，全部待实测）

调优不能只看"切主没了"，还要看代价。**下表全部为待测项，无任何预填值：**

| 观测项 | 默认参数（实测） | 调优后（实测） | 为什么要测 |
|---|---|---|---|
| 抖动期间 P99 延迟峰值 | _未测_ | _未测_ | 验证"调参不改变抖动本身"这一表述是否成立 |
| 抖动期间业务错误数 | _未测_ | _未测_ | 取决于 `ob_query_timeout` 与连接池设置，决定 L5 建议 |
| 抖动结束到 TPS 回基线的时间 | _未测_ | _未测_ | 量化"省掉切主 RTO"的实际收益 |
| 稳态 TPS（无注入） | _未测_ | _未测_ | 确认参数变更没有引入稳态性能代价 |
| 模拟真实坏盘（`dm-flakey` 报错）的检出时间 | _未测_ | _未测_ | **验证安全性论据**：源码认为错误次数路径不受 `tolerance_time` 影响，需实证 |

---

## 9. 执行检查清单

### 9.1 环境搭建

- [ ] 3 × D32s v6 开通，分布三 zone
- [ ] A 组磁盘按客户布局创建（LVM 条带命令见客户部署文档）
- [ ] OB 4.3.5.5 安装，3F 三副本 1-1-1
- [ ] `GV$OB_PARAMETERS` 全量导出为基线（`scripts/tuning/dump_params.sh`）
- [ ] 确认所有参数默认值与 §README 表格一致，不一致则以实测为准并更新文档
- [ ] 复刻 leader 集中状态 + `enable_rebalance=FALSE`/`enable_transfer=FALSE`
- [ ] NTP 同步确认
- [ ] 注入工具可用性验证（`dmsetup`、`dm-delay`、`dm-flakey` 模块）

### 9.2 每个场景执行

- [ ] 预热 10min + 基线采样 5min，TPS 稳定
- [ ] 启动全部采集管线（`scripts/collect/start_collect.sh`）
- [ ] 记录注入起始时间戳（毫秒）
- [ ] 执行注入
- [ ] 记录注入结束时间戳
- [ ] 观察 5min 恢复期
- [ ] 停止采集，归档原始数据到 `data/<场景编号>_<档位>_<次数>/`
- [ ] 查询 `DBA_OB_SERVER_EVENT_HISTORY` 该时间窗事件
- [ ] 场景间隔 ≥60s，确保状态复位

### 9.3 安全注意

- [ ] **测试环境专用，严禁在生产执行任何注入操作**
- [ ] 注入脚本必须带超时自动 `resume` 兜底（防止脚本崩溃导致设备永久 suspend）
- [ ] `dmsetup suspend` 期间禁止对该设备执行其他 dm 操作

---

## 10. 已知风险与局限

| 风险 | 应对 |
|---|---|
| **等效注入 ≠ 平台真实事件**：`dmsetup suspend` 只停顿不报错 | 用 `dm-flakey` 对照组界定边界；报告中显式声明该局限 |
| **调高容错阈值会延缓真实坏盘发现** | 报告给出双向权衡；源码显示时间阈值与错误次数阈值（`MAX_DETECT_READ_WARN_TIMES=10` / `MAX_DETECT_READ_ERROR_TIMES=100`）是**并列的"或"关系**，真实坏盘仍走次数路径；保持 `data_storage_error_tolerance_time` 默认 300s |
| **日志盘无 error 级二级参数**，容错模型比数据盘更激进 | 单独验证超长停顿（60s/120s）下日志盘的上限行为；注意 `PALF_DISK_FAILURE_TIME_UPPER_BOUND=30min` |
| **参数默认值需在 4.3.5.5 上复核** | 现有值来自 main 分支源码；实测前用 `GV$OB_PARAMETERS` 全量比对 |
| **开启 `enable_rebalance`/`enable_transfer` 可能反增抖动命中面** | 单独设场景验证后台搬迁 I/O 的影响，不可简单建议"打开" |
| **源码分析结论未经实测验证** | §5.1 标定实验即为验证手段；若实测与源码推论不符，以实测为准并回溯源码路径 |
