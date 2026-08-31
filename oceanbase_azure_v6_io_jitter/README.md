# OceanBase on Azure v6 存储 I/O 抖动韧性分析与最佳实践

> **文档状态**：分析与方案部分已完成（源码级论证）；实测数据章节为待填模板。
> **适用版本**：OceanBase 4.3.5.5 / OBProxy 4.3.1.6 / Azure Standard D32s v6 + Premium SSD v2 / **Rocky Linux 9.8**
> **最后更新**：2026-08-31

---

## 摘要

OceanBase 在云上块存储环境中对**瞬时 I/O 高延迟事件**的敏感度显著高于其他常见中间件。本文通过**源码级**分析定位故障判定链路，并给出可证伪的测试方案与最佳实践配置。

**核心结论**

> 下列 8 条全部为 **[源码] / [官方] / [现场]** 级事实或由其直接推出的**代码层结论**。
> 本文**不包含任何未经实测的性能数字或运行时行为断言** —— 所有"某档位下会不会切主、
> 代价多大"一类的问题，均以可证伪的预测形式放在 `TEST-PLAN.md` §8，标注 [待验证]，等待实测填写。

1. **触发切主的门槛已被源码精确定位，不是估计值。** 判定链路有且只有两条，门槛分别是**日志盘 5s**、**数据盘 10s + 5s ≈ 15s**（§3.2 / §3.3）。客户现场 14 次慢 I/O 的 **p50 = 10.2s、max = 11.3s、14/14 全部超过 5s**，**必然击穿日志盘门槛**。

2. **两条链路的终点完全相同，都是切主。** 二者都产出 `FailureLevel::FATAL` 事件，进入选举优先级比较的**第一顺位故障项** `compare_fatal_failures_`，导致本节点让出 leader [源码]。

3. **根因是超时层级倒挂。** Azure 官方要求 OS 侧 NVMe I/O 超时设为 **240s**，以便"Azure host 级超时与恢复机制优先处理磁盘故障或中断" [官方]；Linux 内核上游默认 **30s** [源码]；而 OceanBase 默认 **5s** 即判故障。三层之间相差近两个数量级，**最内层反而最敏感**。

4. **切主是"优先级降级后的主动让位"，不是"租约超时后的被动选举"。** 这一点由源码判定：`ObFailureDetector` 每 100ms 刷新，FATAL 事件进入 election priority 比较。**因此 PALF 硬编码的 4s 租约不是本案的触发因素**，`*_tolerance_time` 才是（§5）。这直接回答了"能否通过调参吸收"——**参数空间足够**。

5. **⚠️ 修正：`log_storage_warning_trigger_percentage` 必须保持默认值 `0`，调大适得其反。** 源码显示"单次 I/O 超时"与"吞吐持续劣化"两条判定是 **`||`（或）关系而非替换关系**：调大该参数**不会豁免**前者，只会**额外新增**两条判定路径，使检测**更敏感**（§3.3.1）。**唯一能抬高日志盘门槛的参数是 `log_storage_warning_tolerance_time`。**

6. **调大 `tolerance_time` 不会削弱对真实坏盘的检出能力。** 源码中"返回 I/O 错误码"的判定路径（`fs_error_times >= 10 → WARNING`、`>= 100 → ERROR`）**完全独立于 `tolerance_time`** [源码]。即：放宽的只是"超时"判定，"报错"判定不受影响。这是本方案安全性的关键论据（§8）。

7. **这解释了"为何只有 OB 敏感"**。Redis / RocketMQ / ES / TiDB 不存在"秒级判定坏盘并主动发起选主"的探测器；它们在 I/O 停顿时仅表现为阻塞，停顿结束后自然恢复。

8. **条带化在 D32s v6 上换不来性能**。官方数据显示单块 PSSDv2 可 provision 到 80,000 IOPS / 2,000 MB/s，**已超过 D32s v6 整机的 uncached 上限 66,667 IOPS / 1,984 MBps** [官方]。微软文档亦直言可"避免为满足需求而条带化磁盘的维护开销"。因此当前的 6 盘 / 4 盘条带只换来了 **4~6 倍的抖动暴露面**（§4.1.1）。

> **证据边界**：客户提供的日志是按 `-4389` 过滤后的摘录，**其中不含切主事件的直接记录**。
> 本文的因果链由**源码路径**与**时间相关性**建立，属高可信推断；
> 要升级为现场直接证据，只需一条 SQL（见下方"结论速览 → 确证用 SQL"）。

---

## 结论速览

**客户四个问题的直接答复：**

| # | 问题 | 结论 | 依据 |
|---|---|---|---|
| Q1 | OB 在 Azure v6 上表现如何 | **无版本级不兼容**。OB 4.3.5 官方支持 Rocky Linux 9 [官方]；Rocky Linux 是 Azure 认可发行版 [官方]。3 节点集群部署、运行、压测（稳态 **790 TPS**）均正常。问题不在"能不能跑"，而在两点：**① 默认容错阈值（5s）与云盘延迟分布不匹配**；**② 存储 provisioned 能力不足时，排队延迟本身即可触发故障判定**（实测 clog 卷打满时 p99.9 达 **692ms**、峰值 **1.14s**，无任何注入故障）| A7 / A8 / **§7.6 [实测]** |
| Q2 | 默认参数下抖动会造成什么影响 | **已实测确认：会切主**。日志盘停顿超过 **5s**（`log_storage_warning_tolerance_time` 默认值）即判定 FATAL 故障，**约 7 秒后完成切主**；实测 `hung time` 5.03~5.07s，与默认值精确吻合。sys / meta / 用户租户**同时**切主。因 `PRIMARY_ZONE` 存在，恢复后 leader 自动回迁，**一次抖动 = 两次切主**。现场 14/14 次慢 I/O 均 > 5s（p50 10.2s）[现场] | **§7.2 [实测]** + F1 |
| Q3 | **能否通过调参完全吸收** | **⚠️ 实测结论与直觉相反：不能做到"业务无感"。** 实测规律为 **写中断时长 ≈ min(磁盘停顿时长, `tolerance_time` + 约 2s)**（16 个数据点，§7.4.1）。默认参数下切主反而把 60s 停顿压缩为 **7s** 业务中断；把阈值调到 60s 后，同样 30s 抖动会**实打实阻塞 29s**。**调参能消除的是"切主"这一状态变更事件，不能消除写阻塞。** 参数空间本身确实足够（单一旋钮，上限 300s，不经 PALF 4s 租约），且**调大后保护未被关闭**（90s 停顿仍切主，§7.4） | **§7.4.1 [实测]** |
| Q4 | 最佳实践配置 | 见 §8 与下方决策表。**没有一刀切的最优值**，取决于"业务更怕长阻塞还是更怕切主" | — |

> **⚠️ 本次实测最重要、也最反直觉的一条结论**
>
> **切主不是故障，切主是 OceanBase 的恢复手段。**
> 实测：磁盘停顿 60 秒时，默认参数下 OB 在 T+6s 把 leader 迁到健康节点，
> **业务在 T+7s 即恢复写入 —— 而磁盘还要再停 53 秒**（§7.3 逐秒数据）。
> 若把 `tolerance_time` 调到 60s 让它"不切主"，同一场景下**写入会被阻塞满 60 秒**。
>
> 因此，把"消除 failover"当作目标本身是需要重新审视的：
> **真正该优化的是"抖动命中概率"（存储布局）与"应用对秒级阻塞的容忍度"（重试），
> 而不是单纯把检测阈值调大。**

**调参决策表**（依据 §7.4.1 实测公式，按业务特征选择）：

| 业务特征 | 建议 `tolerance_time` | 代价 | 收益 |
|---|---|---|---|
| 有幂等重试、能容忍 N 秒写阻塞，**最怕 leader 漂移/告警风暴** | 略高于抖动包络上界（如抖动 ≤30s 则设 **35~45s**） | 单次抖动阻塞时长 = 抖动时长 | 无切主、无回迁二次扰动、无 failover 告警 |
| 无重试、**最怕长时间写不进去** | **保持默认 5s** | 每次抖动均切主 + 回迁（两次扰动）+ 在途事务报错 | 写中断被封顶在 **~7s** |
| 抖动包络不明 | **先测量再定**（见 §8 取证步骤） | — | — |

> **不建议**把 `tolerance_time` 设得远高于实际抖动包络（如抖动 10s 却设 300s）：
> 这会让一次真实的长停顿变成一次超长写阻塞，**失去 OB 自愈能力的保护**，
> 且实测显示应用可见错误数随阻塞时长显著上升（60.8s 阻塞 → 82 个错误，§7.5C）。

**最小改动集（按收益/风险排序）：**

| 顺序 | 层 | 动作 | 需重启 | 风险 | 依据 |
|---|---|---|---|---|---|
| 1 | **存储布局** | **降低条带数**：data 6 盘 → 1 盘、clog 4 盘 → 1 盘，并**设置 provisioned IOPS/吞吐** | 需迁移 | 中（需停机或在线搬迁） | **实测：6 盘条带仅 20.3k IOPS，而单块 PSSDv2 可 provision 到 80k**（§7.6.1） |
| 2 | OS | `nvme_core.io_timeout` **30 → 240**（对齐 Azure 官方值） | 是 | 极低 | **实测出厂值确为 30**（§7.0.1） |
| 3 | 应用 | 对 `-4012` / `-6002` / `-4038` 等**加幂等重试**（退避 ≥ 抖动包络上界） | 否 | 低 | **实测 2s 停顿即产生 `errno 4012`**（§7.5C） |
| 4 | OB | `log_storage_warning_tolerance_time` —— **按上方决策表取值，不是无脑调 60s** | 否 | 低 | **实测公式 §7.4.1** |
| 5 | OB | `data_storage_warning_tolerance_time` 同步对齐（若调整了第 4 项） | 否 | 低 | 源码门槛约 15s（§3.2） |
| 6 | 存储 | clog 卷水位 79% → **降至 60% 以下**（避开 `log_disk_utilization_threshold`=80 的激进回收） | 否 | 低 | **实测默认值确为 80**（§7.1） |

> **排序理由（依据实测）**：第 1 项直接降低"被抖动命中"的概率（条带 6 盘 → 单盘，
> 命中面缩小到约 1/6），是**唯一能减少事件发生次数**的措施；
> 第 2、3 项让系统在事件发生时表现更好；
> 第 4 项只改变"事件发生后是切主还是阻塞"，**不减少事件本身**——
> 这正是 §7.4.1 实测得出的结论，也是本次测试最重要的认知修正。

> **不要做**：
> - 调大 `data_storage_error_tolerance_time`（300s 是真实坏盘的兜底线，应保留）
> - 把 `tolerance_time` 设成远高于实际抖动包络的值（见上方决策表下的说明）
>
> **无需处理**：`log_storage_warning_trigger_percentage` —— **该参数在 4.3.5.5 中不存在**
> （已四重核实，见 §3.3.1）。若日后升级到引入该参数的版本，应保持默认值 `0`。

> **⚠️ 本表的证据边界**：
> 全部 6 项均有本次实测直接支撑。
> 但第 1 项支撑的是**性能维度**（条带没换来性能，反而限制了上限）；
> 其"**降低抖动命中概率**"的收益是几何推导，**未做 A/B 对照实验**（见 §7.7.5）。
> 落地前建议先在测试环境验证。

**确证用 SQL** —— 一条查询即可判定当时是否真的发生了磁盘故障判定。
`ObFailureDetector` 的每一次判定都会写入 `__all_server_event_history` [源码]，
下面的写法已在 4.3.5.5 真实集群上验证可执行 [实测]：

```sql
-- ⚠️ 字段名是 timestamp，不是 gmt_create（4.3.5.5 实测确认）
SELECT timestamp, svr_ip, module, event, name1, value1, name2, value2
FROM   oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE  timestamp BETWEEN '2026-07-20 15:00:00' AND '2026-07-20 15:10:00'
  AND  module IN ('FAILURE_DETECTOR','ELECTION','LOG')
ORDER  BY timestamp;
```

判读依据（事件取值均为 4.3.5.5 实测确认，见 §7.2.1）：

- `module='FAILURE_DETECTOR'` 且 `event='clog disk hang event'` → **日志盘链路，本案签名**
- `module='FAILURE_DETECTOR'` 且 `event='data disk hang event'` → 数据盘链路
- `module='ELECTION'` 且 `event='change leader to revoke'` → 该节点让出 leader
- 无任何记录 → 因果链需重新评估

同时可在 `observer.log` 中直接 grep：

```bash
grep -E "disk may be hung|disk has recoverd|errcode=-4392" observer.log
```

---

## 0. 证据等级规范

本文**每一条事实性陈述**均标注证据等级，不做无出处断言。

| 等级 | 含义 | 引用要求 |
|---|---|---|
| **[官方]** | 厂商官方文档 | 完整 URL + 原文摘录 |
| **[源码]** | OceanBase 开源代码 | 仓库 + 文件路径 + commit SHA |
| **[实测]** | 本次测试实际观测数据 | 场景编号 + 原始数据文件 |
| **[现场]** | 客户现网日志 / 配置 | 文件名 + 时间戳 |
| **[社区]** | 官方论坛 / 第三方 KB | URL + 明确标注为非官方 |
| **[待验证]** | 尚无可靠出处 | **禁止作为结论使用** |

> **关于"源码推论"**：由 [源码] 事实**推导出的预期运行时行为**（例如"停顿 6s 会触发切主"）
> **不等同于 [源码] 本身**，也**绝不是 [实测]**。本文一律将其归入 **[待验证]**，
> 并在文中显式标注"预期 / 推论"字样。**在实测数据产出前，任何推论都不得表述为既成事实。**
> 集中体现在 `TEST-PLAN.md` §8.1 —— 该表左侧两列是可证伪的预测，右侧两列才是数据。

> **本文的"确定"与"待定"分界**：
>
> | 已确定（不需要实测） | 待实测确认 |
> |---|---|
> | 判定链路的**代码路径**与**参数如何参与判定**（[源码] 逐行核实） | 具体档位下的**实际行为**（是否切主、切主耗时） |
> | 参数的默认值、取值范围、是否可动态生效（[源码]） | `60s` 是否为最优取值 |
> | 官方文档的事实性表述（[官方]） | 业务侧的实际错误率、TPS 恢复曲线 |
> | 客户现场日志中的慢 I/O 统计（[现场]，脚本实算） | 条带布局 A/B 的性能差异 |

> **本文档已剔除的不可靠断言**：分析初期曾出现"Azure 平台 120s 才判定 NVMe 故障"的说法。经核查 Microsoft Learn 的 `enable-nvme-interface` 与 `enable-nvme-faqs` **均无此表述**，该数字仅见于第三方 KB 转述。**已全部移除**，相关论证改用官方原文的定性表述。

OceanBase 源码引用统一基于 `oceanbase/oceanbase` commit **`fa399038f7edf3313575bd49d8c4a7cc64825c2e`**。

---

## 1. 背景

客户在 Azure 上部署 OceanBase 生产集群，于 2026-07-20 观测到 OBServer failover，客户归因为 "disk error"。同一架构在其他云平台未复现同类现象；同环境下客户使用的 Redis / RocketMQ / ES / TiDB 等中间件均未报告异常。

本文需回答四个问题：

1. OceanBase 在 Azure v6 机型上的**基线表现**；
2. **默认参数**下，存储侧瞬时 I/O 高延迟会带来什么影响；
3. 这些影响**是否真的无法解决**，能否通过**调参完全吸收**且业务无感；
4. **最佳实践配置**是怎样的。

---

## 2. 客户环境现状

### 2.1 计算与存储 [现场]

| 项 | 配置 |
|---|---|
| VM 规格 | Standard **D32s v6**（32 vCPU / 128 GiB） |
| 磁盘类型 | Premium SSD v2 |
| 存储接口 | **NVMe**（`MSFT NVMe Accelerator v1.0`） |
| 操作系统 | **Rocky Linux 9.8**（RHEL 9.8 下游，2026-05-27 GA）[官方] |
| OB 版本 | 4.3.5.5 |
| OBProxy | 4.3.1.6 |

该规格的官方远程存储上限 [官方]（详见 §4.1.1）：uncached **66,667 IOPS / 1,984 MBps**，最大 64 块远程盘，**无本地临时盘**。

**操作系统侧的三条官方事实** [官方]：

1. **Rocky Linux 9 在 OceanBase 4.3.5 官方支持矩阵内**（x86_64 / ARM_64），不存在版本级不兼容。
2. **Rocky Linux 是 Azure 认可（endorsed）的发行版**，经 CIQ 发布，*"Microsoft CSS provides commercially reasonable support for these images."*
3. **但 Azure `enable-nvme-interface` 页面列出的 NVMe 支持镜像清单中，Rocky 分支只到 8.10 / 9.6，未包含 9.8。** 该页面同时说明"某些较旧的操作系统镜像默认超时为 30 秒"。

> **✅ 本次实测已解答这一未决问题** [实测]
>
> 在 Azure Marketplace 镜像 `resf:rockylinux-x86_64:9-base:9.8.20260525` + `Standard_D32s_v6` +
> `--disk-controller-type NVMe` 上开机后**未做任何修改**直接读取：
>
> ```
> # cat /sys/module/nvme_core/parameters/io_timeout
> 30
> # uname -r
> 5.14.0-687.10.1.el9_8.0.1.x86_64
> # cat /proc/cmdline
> ... rootdelay=300 console=ttyS0 earlyprintk=ttyS0 no_timer_check crashkernel=... net.ifnames=0
> （无任何 nvme_core 相关参数）
> ```
>
> 即 **该镜像的 `nvme_core.io_timeout` 出厂值为 30 秒，而非 Azure 官方要求的 240 秒**，
> 且内核命令行中没有任何 `nvme_core.*` 设置。这与 Azure 文档中"某些较旧镜像默认为 30 秒，
> 会导致 OS 先于 Azure 介入就超时"所描述的情形完全吻合。
>
> **因此 §8 L1 的 `nvme_core.io_timeout=240` 是本案必须执行的第一项改动，不是可选项。**
> 其他实测到的出厂默认值见 §7.0。

### 2.2 磁盘布局 [现场]

| 卷 | 挂载点 | 容量 | 组成 | 条带 |
|---|---|---|---|---|
| `nvme0n1` | `/`、`/boot`、swap | 256G | OS 盘（含 **4G swap**） | — |
| `obdatavg-obdatalv` | `/data/1` | 1.8T | **6 × 300G** PSSDv2 | `-i 6 -I 128k` |
| `oblogvg-obloglv` | `/data/log1` | 1000G（**已用 78%**） | **4 × 250G** PSSDv2 | `-i 4 -I 128k` |
| `obadminvg-obadminlv` | `/home/admin` | 400G | 1 × 400G | `-i 1` |

clog 挂载参数：`rw,noatime,nodiratime,attr2,inode64,logbufs=8,logbsize=32k,sunit=2048,swidth=8192,noquota`

### 2.3 集群拓扑 [现场]

**3F 三副本 1-1-1**，三台 OBServer（46 / 47 / 41）分属三个 zone，每个日志流 1 主 2 备，多数派 = 2/3（日志流成员中无仲裁成员）。

| 日志流 | 46 | 47 | 41 |
|---|---|---|---|
| T1/LS1、T1001/LS1、T1002/LS1、T1002/LS1001 | **主** | 备 | 备 |
| T1002/LS1004 | 备 | **主** | 备 |

**5 个日志流中 4 个的主副本集中在 46**，而 46 正是发生 I/O 停顿的节点。

### 2.4 已正确配置的项 [现场]

`numa=off`、`transparent_hugepage=never`、`noatime,nodiratime`、`freeze_trigger_percentage=30`、`nic_rate` 已按主机网络能力设置。

---

## 3. 核心分析：三条判定链路与超时层级

### 3.1 超时层级全景

| # | 层级 | 窗口 | 可调 | 等级 |
|---|---|---|---|---|
| 1 | Azure 官方要求 OS 侧 NVMe I/O 超时 | **240s** | 是 | [官方] |
| 2 | Linux 内核上游 `nvme_core.io_timeout` 默认 | **30s** | 是 | [源码] |
| 3 | OB `_data_storage_io_timeout` | **10s** | 是 [1s,600s] | [源码] |
| 4 | OB `data_storage_warning_tolerance_time` | **5s** | 是 [1s,300s] | [源码] |
| 5 | OB `log_storage_warning_tolerance_time` | **5s** ← **最敏感** | 是 [1s,300s] | [源码] |
| 6 | OB `data_storage_error_tolerance_time` | 300s | 是 [10s,7200s] | [源码] |
| 7 | PALF 选举租约（**本案不触发**，见 §5.1） | 4s | 否（硬编码） | [源码] |

内核上游默认值 [源码]，`drivers/nvme/host/core.c`：

```c
unsigned int nvme_io_timeout = 30;
module_param_named(io_timeout, nvme_io_timeout, uint, 0644);
MODULE_PARM_DESC(io_timeout, "timeout in seconds for I/O");
```

**Microsoft Learn 官方原文** [官方]：

> "For virtual machines using NVMe-attached storage, the default OS-level NVMe IO timeout for both Linux and Windows is now **240 seconds**. This change ensures that **Azure's host-level timeout and recovery mechanisms take precedence in handling disk failures or interruptions.** On Linux, this timeout corresponds to the kernel parameter `nvme_core.io_timeout` set to 240 seconds. ... Some older operating system images have the default timeout values set to 30 seconds. **This setting can cause the OS to timeout IOs before Azure can intervene.**"
>
> — <https://learn.microsoft.com/azure/virtual-machines/enable-nvme-interface>

**这是本文最重要的官方依据**：平台的设计前提是"OS 层应当等待足够长的时间，让平台侧的恢复机制先行处理"。而 OceanBase 默认在 **5s** 即做出终局判定 —— 比平台建议值小 **48 倍**，比内核上游默认值还小 6 倍。**整个超时层级是倒挂的：越靠近应用层，容忍度反而越低。**

### 3.2 链路 A：数据盘故障判定

源码 `src/share/parameter/ob_parameter_seed.ipp` [源码]：

```cpp
DEF_TIME(_data_storage_io_timeout, OB_CLUSTER_PARAMETER, "10s", "[1s,600s]",
        "io timeout for data storage, Range [1s,600s]. The default value is 10s",
        ObParameterAttr(Section::OBSERVER, Source::DEFAULT, EditLevel::DYNAMIC_EFFECTIVE));

DEF_TIME(data_storage_warning_tolerance_time, OB_CLUSTER_PARAMETER, "5s", "[1s,300s]",
        "time to tolerate disk read failure, after that, the disk status will be set warning. "
        "Range [1s,300s]. The default value is 5s",
        ObParameterAttr(Section::OBSERVER, Source::DEFAULT, EditLevel::DYNAMIC_EFFECTIVE));

DEF_TIME_WITH_CHECKER(data_storage_error_tolerance_time, OB_CLUSTER_PARAMETER, "300s",
        common::ObDataStorageErrorToleranceTimeChecker, "[10s,7200s]", ...);
```

判定链（**已由源码逐行核实**，`src/share/io/ob_io_struct.cpp` [源码]）：

```
单个 [读] I/O 超过 10s (_data_storage_io_timeout)
        │  ObIOFaultDetector::record_io_timeout() → 推入 RetryTask
        │  ⚠️ 仅 read 触发；write 分支直接返回 OB_NOT_SUPPORTED
        ▼
探测线程循环重试 detect_read()，指数退避
        │  handle_retry_task_():
        │    warn_ts  = diagnose_begin_ts + data_storage_warning_tolerance_time   (5s)
        │    error_ts = diagnose_begin_ts + data_storage_error_tolerance_time   (300s)
        ▼
重试窗口内始终未成功，current_ts >= warn_ts
        │  set_device_warning()  →  DEVICE_HEALTH_WARNING
        ▼
ObFailureDetector::detect_data_disk_io_failure_()
        │  发现 status != DEVICE_HEALTH_NORMAL
        │  → FailureEvent(PROCESS_HANG, STORAGE, FailureLevel::FATAL)
        ▼
       切主
```

**由此得到数据盘的精确门槛：**

| 阶段 | 参数 | 默认 | 累计 |
|---|---|---|---|
| 单次读 I/O 判超时 | `_data_storage_io_timeout` | 10s | 10s |
| 重试探测窗口 | `data_storage_warning_tolerance_time` | 5s | **≈ 15s → 切主** |
| 升级为 ERROR | `data_storage_error_tolerance_time` | 300s | ≈ 310s → 停机 |

**四条源码级要点：**

1. **只有「读」会触发数据盘故障判定。** `record_io_timeout()` / `record_io_error()` 中 `result.flag_.is_write()` 分支直接 `ret = OB_NOT_SUPPORTED` [源码]。写超时不进入这条链路。

2. **WARNING 与 ERROR 都会产生 FATAL 事件。** `detect_data_disk_io_failure_()` 的判断是 `!= DEVICE_HEALTH_NORMAL`，并不区分两级 [源码]。即 WARNING 就足以切主。

3. **WARNING 状态有最短保持期。** `get_device_health_status()` 中清除 WARNING 需要 `period > read_failure_black_list_interval_`，该值在 `ObIOConfig` 中默认 **60s** [源码]。**即一次 15s 的读停顿，会让该节点在优先级比较中"带伤"至少 60s。**

4. **返回错误码的真实坏盘走独立快速通道，不受 `tolerance_time` 影响。** 见下方源码片段：`MAX_DETECT_READ_WARN_TIMES = 10`、`MAX_DETECT_READ_ERROR_TIMES = 100`（`src/share/io/ob_io_define.h`）[源码]。**这是"调大 `tolerance_time` 不会导致真实坏盘漏检"的直接源码证据**：`sys_io_errno != 0` 这一支与时间阈值是 `||` 关系，互不影响。

```cpp
// src/share/io/ob_io_struct.cpp — handle_retry_task_()
if (current_ts >= error_ts || (sys_io_errno != 0 && fs_error_times >= MAX_DETECT_READ_ERROR_TIMES)) {
  set_device_error();
} else if (current_ts >= warn_ts || (sys_io_errno != 0 && fs_error_times >= MAX_DETECT_READ_WARN_TIMES)) {
  set_device_warning();
}
```

OceanBase 官方文档对两个状态的描述 [官方]：

- `data_storage_warning_tolerance_time`：*"探测线程会将该数据盘状态设置为 `WARNING`，该状态会**触发切主**等事件以正常服务业务请求。"*
- `data_storage_error_tolerance_time`：*"探测线程会将该数据盘状态设置为 `ERROR`，该状态会**触发停机**等事件以避免向该节点发送的请求失败。"*

> **对于 10~30s 量级的瞬时停顿**：会跨过 WARNING（≈15s），但**不会**达到 ERROR（≈310s）。即数据盘链路可能导致切主，但不会导致节点停机。

**三个参数均为 `DYNAMIC_EFFECTIVE`，无需重启 OBServer 即可在线生效** [源码]。

### 3.3 链路 B：日志盘故障判定（最激进）

> **版本基准**：本节所有源码引用一律以客户实际运行的 **OceanBase 4.3.5.5** 为准，对应上游 tag **`v4.3.5_CE_BP5_HF2`**（commit 时间 `2026-01-27T13:55:00Z`，与 RPM `oceanbase-ce-4.3.5.5-105020072026012721.el8` 的 release 号 `…2026012721` 精确对应）[源码]。**不同版本的判定实现差异很大**，见 §3.3.1。

参数定义 `src/share/parameter/ob_parameter_seed.ipp` @ `v4.3.5_CE_BP5_HF2` [源码]：

```cpp
DEF_TIME(log_storage_warning_tolerance_time, OB_CLUSTER_PARAMETER, "5s", "[1s,300s]",
         "time to tolerate log disk io delay, after that, log disk will be considered as failure. "
         "Range: [1s,300s]");
```

判定实现 `src/logservice/leader_coordinator/ob_failure_detector.cpp` → `detect_palf_hang_failure_()` @ `v4.3.5_CE_BP5_HF2` [源码]：

```cpp
FailureEvent clog_disk_hang_event(FailureType::PROCESS_HANG, FailureModule::LOG, FailureLevel::FATAL);
...
} else if (OB_FAIL(log_service->get_io_start_time(clog_disk_last_working_time))) {
  COORDINATOR_LOG(WARN, "get_io_start_time failed", K(ret));
} else if (FALSE_IT(is_clog_disk_hang = (OB_INVALID_TIMESTAMP != clog_disk_last_working_time
                    && now - clog_disk_last_working_time > GCONF.log_storage_warning_tolerance_time))) {
} else if (false == ATOMIC_LOAD(&has_add_clog_hang_event_)) {
  if (!is_clog_disk_hang) {
    // log disk does not hang, skip.
  } else if (OB_FAIL(add_failure_event(clog_disk_hang_event))) {
    ...
  } else {
    ATOMIC_SET(&has_add_clog_hang_event_, true);
    LOG_DBA_ERROR(OB_DISK_HUNG, "msg", "clog disk may be hung, add failure event",
                  K(clog_disk_hang_event), K(clog_disk_last_working_time),
                  "hung time", now - clog_disk_last_working_time);
  }
}
```

**这是一个单一条件判定**——`now - 最近一次 I/O 起始时间 > tolerance_time`。没有"吞吐劣化"分支，没有百分比阈值，没有连续错误次数要求，也**没有任何可以放宽它的第二个参数**。日志盘 I/O 只要连续 5s 没有推进，立即产出 `FailureLevel::FATAL` 事件。

**判定与恢复的时间常量** [源码]（`ob_failure_detector.cpp` `mtl_start()`）：

| 定时器 | 周期 | 作用 |
|---|---|---|
| `failure_detect_timer_` | **100ms** | 检测 hang，命中即 `add_failure_event` |
| `recovery_detect_timer_` | **1s** | 检测恢复，`remove_failure_event` |

配套的 `has_add_clog_hang_event_` 原子标志保证同一次 hang 只登记一次事件；I/O 恢复推进后立即 `remove_failure_event` 并打印 `clog disk has recoverd, remove failure event`。

### 3.3.1 ⚠️ 版本修正：`log_storage_warning_trigger_percentage` 在 4.3.5.5 中并不存在

社区资料与本报告早期版本曾讨论过一个参数 `log_storage_warning_trigger_percentage`（吞吐劣化百分比阈值），并据此讨论"能否切换到更宽松的判定模型"。**经双重核实，该参数在客户运行的 4.3.5.5 上不存在**：

**核实一：源码** [源码]

在 tag `v4.3.5_CE_BP5_HF2` 的 `src/share/parameter/ob_parameter_seed.ipp` 中检索，`log_storage_warning_tolerance_time` 存在，而 **`log_storage_warning_trigger_percentage` 无任何定义**。该参数以及配套的 `PalfDiskHangDetector`（带宽劣化判定类）属于 4.3.5.5 **之后**的上游改动，仅存在于更高版本 / main 分支。

**核实二：在真实集群上直接验证** [实测]

在本次搭建的 4.3.5.5 三节点集群上执行：

```sql
-- 尝试设置该参数
ALTER SYSTEM SET log_storage_warning_trigger_percentage = 0;
--> ERROR 5099 (42000): System config unknown

-- 在参数视图中检索
SELECT count(*) FROM oceanbase.GV$OB_PARAMETERS
 WHERE name = 'log_storage_warning_trigger_percentage';
--> 0

-- 对照组：一个确实存在的隐藏参数
SELECT count(*) FROM oceanbase.GV$OB_PARAMETERS
 WHERE name = '_data_storage_io_timeout';
--> 3      （三个节点各一行）
```

**结论（本文的核心版本修正）：**

> 在 **OceanBase 4.3.5.5** 上，日志盘故障判定**只有一条路径、只受一个参数控制**：
> **`log_storage_warning_tolerance_time`（默认 5s，可调范围 [1s, 300s]）**。
>
> 这实际上使结论更简单也更确定：**不存在"换一种判定模型"的选项，调整该阈值是唯一手段**；
> 同时也**不存在**"调大 `trigger_percentage` 反而更敏感"这一风险——因为该旋钮在本版本中根本不可用。

> **升级提示**：若客户后续升级到引入 `PalfDiskHangDetector` 的更高版本，判定逻辑将变为"长时间无推进 **或** 带宽劣化持续超时"的**或**关系，届时 `log_storage_warning_trigger_percentage` 应保持默认值 `0`——调大它是**新增**判定路径（更敏感），而非替换为更宽松的模型。此项在升级前需重新评估。

**结论**：默认配置下，日志盘 I/O 只要**连续 5s 没有推进**，即被判定为 FATAL 故障并进入切主流程。对任何网络化块存储，这都是一个极易被触发的条件。该结论已由 §7 的实测数据逐档验证。

### 3.3.2 判定结果如何变成切主

`detect_palf_hang_failure_()` 在判定 hang 后构造的事件是 [源码]：

```cpp
FailureEvent clog_disk_hang_event(FailureType::PROCESS_HANG,
                                  FailureModule::LOG,
                                  FailureLevel::FATAL);   // ← FATAL
...
add_failure_event(clog_disk_hang_event);
LOG_DBA_ERROR(OB_DISK_HUNG, "msg", "clog disk may be hung, add failure event", ...);
```

该 FATAL 事件被选举优先级 `PriorityV1::refresh_()` 读取 [源码]：

```cpp
detector->get_specified_level_event(FailureLevel::FATAL, fatal_failures_);
```

而 `PriorityV1::compare()` 的比较顺序为 [源码]：

```cpp
compare_observer_stopped_   // kill -15 导致 observer stop
compare_server_stopped_flag_
compare_zone_stopped_flag_
compare_fatal_failures_     // ← 比较致命的异常（第 4 顺位，但是第 1 个"故障类"判据）
compare_scn_                // 避免切换至回放位点过小的副本
...
```

前三项都是**人为运维操作**（stop server / stop zone）。因此 **`fatal_failures_` 是优先级比较中排序最高的"故障类"判据** —— 一旦本节点持有 FATAL 事件而其他副本没有，本节点在优先级比较中必然落败，leader 被切走。

**这条链路是"主动让位"，与 PALF 选举租约到期的"被动选举"是两套独立机制**（见 §5）。

### 3.4 链路 C：PALF 选举租约（硬编码，不可调）

源码 `src/logservice/palf/election/utils/election_common_define.h` [源码]：

```cpp
constexpr int64_t MAX_LEASE_TIME = 10_s;
extern int64_t MAX_TST; // 最大单程消息延迟，暂设为1s，在单测中会将其调低，
                        // 日后可改为配置项，现阶段先用全局变量代替

inline int64_t CALCULATE_RENEW_LEASE_INTERVAL() { return std::min<int64_t>(0.5 * MAX_TST, 500_ms); }
inline int64_t CALCULATE_TIME_WINDOW_SPAN_TS()  { return 2 * MAX_TST; }   // 默认 2s
inline int64_t CALCULATE_MAX_ELECT_COST_TIME()  { return 10 * MAX_TST; }  // 默认 10s
inline int64_t CALCULATE_LEASE_INTERVAL()       { return 4 * MAX_TST; }   // 默认 4s
inline int64_t CALCULATE_TRIGGER_ELECT_WATER_MARK() { return std::min<int64_t>(MAX_TST, 1_s); }
```

推导：

| 量 | 计算 | 默认值 |
|---|---|---|
| 选举租约 | `4 × MAX_TST` | **4s** |
| 续约周期 | `min(0.5 × MAX_TST, 500ms)` | 500ms |
| 触发无主选举水位线 | `min(MAX_TST, 1s)` | 1s |
| **有效容忍窗口** | 租约 − 水位线 | **≈ 3s** |
| 单次选举最大耗时 | `10 × MAX_TST` | 10s |

`election_impl.cpp` 中存在 `RoleChangeReason::LeaseExpiredToRevoke` 与 `report_leader_lease_expired_event`，即租约到期后 leader 卸任并记录事件 [源码]。

> **关键限制**：`MAX_TST` 的源码注释明确写着 *"日后可改为配置项，现阶段先用全局变量代替"* —— 即**当前版本中 PALF 选举租约是硬编码的，无法通过任何配置项调整**。

### 3.5 现场日志逐条对照 [现场]

来源：`observer46.txt`（节点 46，即多数日志流的 leader 所在节点）

| 观测项 | 数值 |
|---|---|
| 停顿发生时刻 | `2026-07-20 15:03:25` 与 `15:03:52`（间隔约 27s，两波） |
| `result_delay` 范围 | **6,176,062 µs ~ 11,264,917 µs**（约 **6.1s ~ 11.3s**） |
| 受影响租户 | T1(sys) / T1001 / T1002 —— **全部租户** |
| 受影响线程 | `T1_IOWorker`、`T1001_IOWorker`、`T1002_IOWorker`、`T1002_OB_SLOG`、`T1002_L0_G0` |
| 错误码 | `-4389` |
| 代码位置 | `ob_io_define.cpp:2004` `estimate()` — *"io result wait too long"* |
| 观测到的 I/O 超时配置 | `timeout_us_:10000000`(10s) 与 `timeout_us_:300000000`(300s) 两类 |

**`result_delay` 量化分布**（由 `scripts/collect/scan_observer_log.sh` 对现场日志实际计算得出）：

| 统计量 | 值 |
|---|---|
| 样本数 | **14** |
| min | 6.176 s |
| p50 | 10.222 s |
| p90 | 10.442 s |
| p99 / max | 11.265 s |
| avg | 9.713 s |
| **超过 5s（`*_storage_warning_tolerance_time`）的次数** | **14 / 14（100%）** |
| **超过 10s（`_data_storage_io_timeout`）的次数** | **10 / 14（71%）** |
| 超过 300s（`data_storage_error_tolerance_time`）的次数 | **0 / 14** |

**这组数字是全文的核心实证**：现场每一次慢 I/O 都跨过了 OceanBase 的故障判定线（5s），
但**没有任何一次**接近平台侧的恢复窗口（OS 侧被官方要求等待 240s）或 OB 的 ERROR 线（300s）。

#### ⚠️ 证据边界声明（重要）

客户提供的 `observer46.txt` 是**按 `-4389` 过滤后的日志摘录**，不是完整的 observer.log。
用签名扫描工具核对，该摘录中：

| 签名分组 | 匹配数 |
|---|---|
| [A] I/O 超时与慢 I/O（`-4389`） | 有（14 条 `result_delay`） |
| [B] 磁盘状态变更（WARNING / ERROR） | **0** |
| [C] PALF 选举租约（`LeaseExpiredToRevoke` 等） | **0** |
| [D] failure detector | **0** |
| [E] 切主与角色变更 | **0** |

文件中唯一与 failover 相关的文字是客户自己写的批注行：
`#oblog failover error log // customer verbatim: ob server failover because of disk error`。

**因此必须明确**：

- **"发生了 failover"目前是客户的报告与归因，摘录本身不含切主事件的直接证据**；
- 本文建立的 `慢 I/O → 判定磁盘故障 → 切主` 因果链，依据是**源码路径**（§3.2/§3.3）
  与**时间相关性**，而非该摘录中的切主日志；
- 要把这条链路从"高度可信的推断"升级为"现场直接证据"，需要向客户补充索取：
  1. **`DBA_OB_SERVER_EVENT_HISTORY`** 在 `2026-07-20 15:00 ~ 15:10` 的完整记录 ← **切主的权威判据**；
  2. 该时间窗的**完整 `observer.log` 与 `election.log`**（不做过滤）；
  3. 三个节点（46 / 47 / 41）的日志，而非仅 46。

**第 1 项一条 SQL 即可确证**——源码中 failure detector 的每一次状态变更都会调用
`SERVER_EVENT_ADD("FAILURE_DETECTOR", ...)` 写入 `__all_server_event_history` [源码]：

```sql
SELECT gmt_create, svr_ip, module, event, name1, value1, name2, value2, name3, value3
FROM   oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE  module = 'FAILURE_DETECTOR'
  AND  gmt_create BETWEEN '2026-07-20 15:00:00' AND '2026-07-20 15:10:00'
ORDER  BY gmt_create;
```

判读方式：

| 返回结果 | 结论 |
|---|---|
| 有 `FAILURE_MODULE = LOG` 且 `FAILURE_TYPE = PROCESS_HANG` 的记录 | 日志盘链路（§3.3）被触发 —— 因果链得到现场直接证据 |
| 有 `FAILURE_MODULE = STORAGE` 的记录 | 数据盘链路（§3.2）被触发 |
| 无任何记录 | failure detector 未触发，切主另有原因，本文因果链需重新评估 |

在补齐上述材料前，本文对现场事件的表述一律限定为"观测到 6~11s 的存储 I/O 停顿"，
不直接断言"该停顿导致了那一次 failover"。

**停顿位置的判定**：日志中 `submit_used` 与 `return_used` **两侧均出现 10s+ 的耗时**：

- `submit_used: 10145753`（提交阶段阻塞 10.1s）
- `return_used: 10144342` / `10221478` / `10442392`（等待完成阶段阻塞 10.2~10.4s）

而 `enqueue_used` / `dequeue_used` 均为个位数微秒。这说明**阻塞发生在设备层，而非 OceanBase 内部队列排队**。

**与超时层级的对照**：

| 阈值 | 值 | 现场停顿（6.1~11.3s）是否跨过 |
|---|---|---|
| `log_storage_warning_tolerance_time`（**日志盘判故障→切主**） | 5s | ✅ **14 / 14 全部跨过** |
| `data_storage_warning_tolerance_time` | 5s | ✅ 已跨过 |
| `_data_storage_io_timeout`（数据盘计时起点） | 10s | ✅ 10 / 14 跨过 |
| 数据盘 WARNING 总门槛（10s + 5s） | ~15s | ⚠️ 单次未达，但两波间隔 27s 内叠加则可能达到 |
| PALF 选举租约（**本案不触发**，见 §5.1） | 4s | （形式上跨过，但该路径依赖 RPC 心跳而非磁盘，抖动期间网络正常） |
| `data_storage_error_tolerance_time` | 300s | ❌ 远未触及 |
| Azure 官方要求的 OS 侧 NVMe 超时 | 240s | ❌ 远未触及 |

**现场停顿幅度精确地落在"OceanBase 判定为坏盘"与"平台判定为正常"之间的区间内。**

---

## 4. 影响放大因素

### 4.1 LVM 多盘条带化 [现场]

数据卷跨 **6** 块 PSSDv2 条带化，日志卷跨 **4** 块条带化，条带单元 128k。

在条带布局下，**任意一块底层盘出现停顿，整个逻辑卷的 I/O 即被阻塞**。结合 §3.3 的结论（**单次** I/O 超 5s 即判故障），单盘抖动的命中概率被放大约 N 倍：

| 卷 | 底层盘数 | 相对单盘的暴露倍数 |
|---|---|---|
| `/data/1` | 6 | ~6× |
| `/data/log1` | 4 | ~4× |

且 128k 条带单元意味着单个较大 I/O 必然横跨多块盘，进一步提高命中面。

#### 4.1.1 关键：在 D32s v6 上，条带化换不来性能

Microsoft Learn 官方数据 [官方]：

**Standard_D32s_v6 的 VM 级远程存储上限**（`dsv6-series`，Uncached Ultra Disk and Premium SSD v2 列）：

| 项 | 值 |
|---|---|
| Uncached IOPS | **66,667** |
| Uncached 吞吐 | **1,984 MBps** |
| 突发 IOPS / 吞吐 | 104,167 / 1,984 MBps |
| 最大远程磁盘数 | 64 |
| Local Storage | **None**（该系列无本地临时盘） |

**单块 Premium SSD v2 的可 provision 上限**（`disks-types`）：

> "All Premium SSD v2 disks have a baseline IOPS of 3,000 that is free of charge. After 6 GiB, the maximum IOPS a disk can have increases at a rate of 500 per GiB, **up to 80,000 IOPS**. ... To set 80,000 IOPS on a disk, that disk must have at least **160 GiB**."
>
> "All Premium SSD v2 disks have a baseline throughput of 125 MB/s ... **2,000 MB/s is the maximum throughput supported for disks that have 8,000 IOPS or more.**"

**由此得出的算术结论**：

| 卷 | 客户配置 | 单块盘的可 provision 上限 | D32s v6 VM 级上限 | 结论 |
|---|---|---|---|---|
| `/data/1` | 6 × 300 GiB | 300 GiB ≥ 160 GiB → **80,000 IOPS / 2,000 MB/s** | 66,667 IOPS / 1,984 MBps | **单块盘即可封顶 VM 上限** |
| `/data/log1` | 4 × 250 GiB | 250 GiB ≥ 160 GiB → **80,000 IOPS / 2,000 MB/s** | 66,667 IOPS / 1,984 MBps | **单块盘即可封顶 VM 上限** |

即：**在 Standard_D32s_v6 上，只要单块 PSSDv2 provision 到位，条带化 4~6 块盘不会带来任何额外性能** ——
VM 级上限先封顶。条带化在此换到的只有 **4~6 倍的抖动暴露面**。

微软官方文档对这一点有直接表述 [官方]：

> "Premium SSD v2 doesn't support host caching but, benefits significantly from lower latency, which addresses some of the same core problems host caching addresses. **The ability to adjust IOPS, throughput, and size at any time also means you can avoid the maintenance overhead of having to stripe disks to meet your needs.**"

> **前提待确认 [待验证]**：客户材料中未记录各磁盘的 provisioned IOPS / 吞吐设置。
> 若客户使用的是 PSSDv2 默认档（3,000 IOPS / 125 MB/s），则条带化确实是当时提升总吞吐的手段
> （6 盘 ≈ 18,000 IOPS / 750 MB/s）。但这是"用暴露面换性能"的低效路径 ——
> 正确做法是**给单盘 provision**，同样达到 VM 上限且暴露面为 1×。
> **需向客户确认各盘的 provisioned IOPS 与吞吐值，再据此给出最终布局建议。**

### 4.2 leader 高度集中 [现场]

5 个日志流中 4 个的主副本集中在节点 46。一次单节点 I/O 停顿即引发**4 个日志流批量切主**，业务影响面被最大化。这与现场日志中 T1 / T1001 / T1002 三个租户同时报错的现象完全吻合。

**加剧因素**：客户配置中设置了 `enable_rebalance = FALSE` 与 `enable_transfer = FALSE` [现场]，即关闭了自动均衡，leader 集中的状态不会被 OceanBase 自动纠正，切主后也不会自动回迁均衡。

### 4.3 clog 卷水位偏高 [现场]

日志卷已用 **78%**（776G / 1000G）。相关阈值（均为 `OB_TENANT_PARAMETER`、`DYNAMIC_EFFECTIVE`）[源码]：

| 参数 | 默认 | 范围 | 语义 |
|---|---|---|---|
| `log_disk_utilization_threshold` | **80** | [10,100) | 超过后开始**回收复用**日志文件 |
| `log_disk_utilization_limit_threshold` | **95** | [80,100] | 超过后**停止提交或接收日志** |
| `log_disk_throttling_percentage` | **60** | [40,100] | 超过后触发**写入限流**（设为 100 表示关闭限流） |

源码约束：`log_disk_utilization_limit_threshold_ > log_disk_utilization_threshold_`（`palf_options.cpp`）。

客户当前 78% 的水位：

- **已越过 `log_disk_throttling_percentage`（60）** → 写入限流已在生效；
- **逼近 `log_disk_utilization_threshold`（80）** → 即将进入日志段回收复用，额外增加日志盘 I/O 压力；

两者叠加，提高了在抖动窗口内命中慢 I/O 的概率。

---

## 5. 关键结论：能否通过调参完全吸收

### 5.1 结论：参数空间足够，触发路径不经过 PALF 硬编码租约

切主存在**两条机制截然不同的路径**：

| 路径 | 机制 | 阈值 | 可调性 |
|---|---|---|---|
| **① Failure detector → 优先级降级 → 主动让位** | 存储故障判定 | 日志盘 **5s** / 数据盘 **≈15s** | **可调至 300s** |
| **② PALF 选举租约到期 → 被动重新选举** | 副本间 RPC 心跳 | 有效 ≈3s / 租约 4s | 硬编码，不可调 |

**判定依据（源码，非推测）：**

1. **路径 ① 的完整链条已逐行核实**，且**全程不经过选举租约**（链条见下方）。这是**优先级比较驱动的主动让位**，租约在此期间始终正常续约。

```
is_clog_disk_hang() / get_device_health_status()
     → add_failure_event(FailureLevel::FATAL)
     → PriorityV1::refresh_()  读取 fatal_failures_
     → PriorityV1::compare()   在 compare_fatal_failures_ 处判负
     → leader coordinator 主动切主
```

2. **路径 ② 的触发条件是"副本间 RPC 消息中断"，而非磁盘慢。** PALF 选举模块（`election_acceptor.cpp` / `election_proposer.cpp`）的续约处理是**纯内存 + RPC** 的状态机，不含磁盘 I/O 调用 [源码]。存储抖动期间网络正常，租约不会过期。

3. **本案的现场特征与路径 ① 完全吻合**：现场日志中命中的是 `*_IOWorker`、`T1002_OB_SLOG` 等 **I/O 线程**，`enqueue`/`dequeue` 仅个位数微秒而 `submit_used`/`return_used` 双侧 10s+，即阻塞发生在**设备层**而非调度层或网络层（§3.5）。

**因此：**

> **对 10~30s 量级的存储抖动，切主由路径 ① 触发，而路径 ① 的门槛完全由 `*_tolerance_time` 决定（可调至 300s）。**
> **"4s 硬编码租约"不是本案的天花板。参数空间是足够的。**

> **以上是[源码]级结论——关于"代码怎么写的"。**
> **它不等于"调到 60s 就一定没事"。** 后者属运行时行为，必须由 `TEST-PLAN.md` §5.1 标定实验
> 与 §8 记录表实测得出。在实测数据产出前，本文不给出任何具体档位下的行为断言。

### 5.2 "完全吸收"的准确含义与边界 [实测]

调参能做到的和不能做到的，**现已全部由实测确定**（§7.3 / §7.4 / §7.4.1）：

| 现象 | 调参前（默认 5s） | 调参后（tolerance=60s） | 证据 |
|---|---|---|---|
| 抖动期间事务延迟升高 | 是 | **仍是（无法消除）** | §7.3 / §7.4 逐秒 TPS |
| 抖动期间部分事务超时报错 | 是（2s 停顿即出现 `4012`） | **仍是，且更多**（60.8s 阻塞 → 82 个错误） | §7.5C |
| **写服务完全中断时长** | **封顶 ~7s**（切主即恢复） | **≈ 停顿全长**（30s 抖动 → 阻塞 29s） | **§7.4.1 公式** |
| **判定磁盘故障 → 切主** | **是**（≥5.8s 即触发） | **否**（停顿 < 60s 时）；**≥90s 仍会切主** | §7.3 / §7.4 |
| 切主导致的连接中断与 leader 漂移 | 是 | **否** | §7.4（0/4 日志流迁移） |
| 停顿结束后的二次扰动（leader 回迁） | **是**（约 1.0s 后回迁，降级尾巴可达 25s） | **否**（恢复干净，立即回到基线） | §7.3 / §7.4 逐秒原文 |
| 稳态性能 | — | **无可测量差异**（TPS +0.08%） | §7.5A |

> **🔴 准确表述（实测版，替代此前的源码推论）**
>
> **调参不能让业务无感。** 它做的是一次**形态交换**：
> 把「**短而硬**的中断（~7s）+ 切主 + 回迁二次扰动」
> 换成「**长而软**的阻塞（= 停顿全长）+ 无任何状态变更」。
>
> 两者**没有绝对优劣**，取决于业务更怕哪一种 —— 见"结论速览"中的**调参决策表**。
>
> 特别地：**当抖动 ≥ 60s 时，默认参数（7s 中断）明显优于调优参数（60s 阻塞）。**

这也解释了为什么 Redis / RocketMQ / ES / TiDB 在同一平台上"没问题"：
它们没有秒级的坏盘判定器，抖动只表现为**阻塞**（即上表右列的形态）。
把 OB 的 `tolerance_time` 调大，本质上就是**让 OB 的行为形态向这些中间件对齐** ——
但要清楚，这并不意味着"抖动消失了"，只是**抖动不再引发状态变更**。

**仍需现场确认的量：**

| 项 | 为什么需要现场确认 |
|---|---|
| 客户侧抖动的**时长包络** | 决策表的取值完全依赖它；现场日志仅见 6.1~11.3s，样本不足以定上界 |
| 业务侧对 N 秒写阻塞的容忍度 | 取决于 `ob_query_timeout` / 连接池 / 上游超时，需业务方确认 |
| OS 盘抖动的独立影响 | OS 盘不承载 clog/data，但承载 syslog 与 4G swap，路径不同（§7.7.1） |
| 三节点同时抖动时的行为 | 多数派同时受损，**任何参数都无法兜底**（架构事实，§7.7.7） |

### 5.3 结论的证据分层：代码事实 / 已实测 / 仍未验证

**A. 代码与文档事实**（不依赖实测，可直接断言）

1. **判定门槛的位置**：日志盘为 `now - clog_disk_last_working_time > log_storage_warning_tolerance_time`（默认 5s）[源码]。现场 14/14 次慢 I/O 全部 > 5s [现场]，即**门槛确实被跨过**。
2. **调大 `tolerance_time` 不改变"报错"判定路径**。返回错误码的路径（`fs_error_times >= 10/100`）与时间阈值在同一 `if` 中以 `||` 并列，互不影响 [源码]。
3. **`data_storage_error_tolerance_time` 默认 300s**，10~30s 量级的停顿在时间上远未触及该阈值 [源码]。
4. **数据盘 WARNING 状态的清除条件**是 `period > read_failure_black_list_interval_`（默认 60s）[源码]，即状态位不会随停顿结束立即复位。
5. **所有相关 OB 参数均为 `DYNAMIC_EFFECTIVE`**，可在线调整，无需重启 [源码]。
6. **3F 三副本的多数派是 2/3** —— 若三节点同时受损，多数派同时失效，**任何参数都无法兜底**（架构事实）。
7. **4.3.5.5 中日志盘判定是单一条件**，`log_storage_warning_trigger_percentage` 参数不存在 [源码]（§3.3.1）。

**B. 已由本次实测验证的结论**（原为源码推论，现已升级为 [实测]）

| 原推论 | 实测结果 | 出处 |
|---|---|---|
| 默认参数下 6s 停顿会实际发生切主 | ✅ **成立**。6.318s 停顿 → 3 个日志流全部切走 | §7.3 |
| 门槛精确等于 `log_storage_warning_tolerance_time`（5s） | ✅ **成立**。4.794s 不触发，5.844s 触发；`hung time` 实测 5.03~5.07s | §7.2 / §7.3 |
| 判定链路为「磁盘 hang 事件 → FATAL → 优先级降级 → 让位」 | ✅ **成立**。事件序列与时间戳完整捕获 | §7.2 |
| `log_storage_warning_trigger_percentage` 在 4.3.5.5 中不存在 | ✅ **成立**。四重核实（源码 + 三种运行时查询） | §3.3.1 / §7.1 |
| 7 个相关参数的默认值与源码一致 | ✅ **成立**。7/7 全部吻合 | §7.1 |
| Rocky 9.8 出厂 `nvme_core.io_timeout` 不是 Azure 要求的 240 | ✅ **成立**。出厂值为 **30** | §7.0.1 |

**C. 本次仍未验证的项** —— 见 §7.7 清单，**一律不做外推**。

---

## 6. 测试方案

完整可执行方案见 [`TEST-PLAN.md`](TEST-PLAN.md)，脚本见 [`scripts/`](scripts/)。要点：

- **三个磁盘域分别独立测试**：A（OS 盘）/ B（数据盘 `/data/1`）/ C（日志盘 `/data/log1`），各自独立注入、独立取数、独立结论，最后才做组合。
- **注入手段**：`dmsetup suspend/resume` 精确停顿（与现场 submit/return 双侧阻塞特征一致），`dm-delay` 固定延迟，`dm-flakey` 停顿+错误对照。
- **时长档位**：2 / 4 / 5 / 6 / 8 / 10 / 15 / 20 / 30 / 60 / 120s，密集覆盖 3s、4s、5s、10s 四条阈值线两侧。
- **判定"完全吸收"的三条硬标准**：`DBA_OB_SERVER_EVENT_HISTORY` 无切主/停机事件；应用侧零报错、无连接中断；停顿结束后 TPS 立即回到基线。

---

## 7. 实测结果

> 本章所有数据均来自 **2026-08-31 在 Azure 上真实搭建的 3 节点 OceanBase 4.3.5.5 集群**，
> 全部标注 [实测]。原始数据文件见 [`results/`](results/)。
> **本章不含任何推测值**；未完成的测试项一律标 `_未测_`。

### 7.0 测试环境

**与客户环境的对照**（几何一致，容量按比例缩小）：

| 项 | 客户现网 [现场] | 本次测试环境 [实测] | 一致性 |
|---|---|---|---|
| VM 规格 | Standard D32s v6 | **Standard_D32s_v6** ×3 | ✅ 一致 |
| 可用区 | 三个 zone | zone 1 / 2 / 3 | ✅ 一致 |
| 磁盘类型 | Premium SSD v2 | **PremiumV2_LRS** | ✅ 一致 |
| 存储接口 | NVMe（`MSFT NVMe Accelerator v1.0`） | **同左**（`--disk-controller-type NVMe`） | ✅ 一致 |
| 操作系统 | Rocky Linux 9.8 | **Rocky Linux 9.8**（`resf:rockylinux-x86_64:9-base:9.8.20260525`） | ✅ 一致 |
| 内核 | 未提供 | `5.14.0-687.10.1.el9_8.0.1.x86_64` | — |
| OB 版本 | 4.3.5.5 | **4.3.5.5**（`oceanbase-ce-4.3.5.5-105020072026012721.el8`） | ✅ 一致 |
| 集群形态 | 3F 三副本 1-1-1，多数派 2/3 | **3F 三副本 1-1-1**，多数派 2/3 | ✅ 一致 |
| data 卷几何 | 6 盘条带 `-i 6 -I 128k` | **6 盘条带 `-i 6 -I 128k`** | ✅ 几何一致 |
| log 卷几何 | 4 盘条带 `-i 4 -I 128k` | **4 盘条带 `-i 4 -I 128k`** | ✅ 几何一致 |
| data 卷容量 | 6 × 300 GiB = 1.8 TiB | 6 × 64 GiB = 384 GiB | ⚠️ **按比例缩小** |
| log 卷容量 | 4 × 250 GiB = 1000 GiB | 4 × 64 GiB = 256 GiB | ⚠️ **按比例缩小** |
| PSSDv2 性能档 | 未提供 | 默认基线（3,000 IOPS / 125 MB/s 每盘） | ⚠️ **可能不同** |
| leader 分布 | 5 个日志流中 4 个 leader 集中在同一节点 | **4 个日志流 leader 全部集中在 ob1**（`PRIMARY_ZONE='zone1;zone2,zone3'`） | ✅ 刻意复刻 |

> **⚠️ 偏差声明**：测试盘容量小于客户现网（64 GiB vs 300/250 GiB），
> 且客户各盘的 provisioned IOPS / 吞吐设置未知。
> **条带几何（6 盘 / 4 盘 × 128k）与集群形态完全一致**，
> 而本章结论关注的是**时间阈值判定行为**，该行为由 `log_storage_warning_tolerance_time`
> 与"I/O 是否推进"决定，**与盘容量无关**，因此该偏差不影响 §7.2 / §7.3 的结论。
> 涉及绝对吞吐的数据（如基线 IOPS）则**不可直接外推到客户环境**。

**节点清单**：

| 节点 | 规格 | Zone | 内网 IP | 角色 |
|---|---|---|---|---|
| ob1 | Standard_D32s_v6 | 1 | 10.20.1.11 | OBServer（zone1，**全部 leader**） |
| ob2 | Standard_D32s_v6 | 2 | 10.20.1.12 | OBServer（zone2） |
| ob3 | Standard_D32s_v6 | 3 | 10.20.1.13 | OBServer（zone3） |
| obctl | Standard_D2s_v6 | 1 | 10.20.1.10 | OBD 部署机 / 压测发起端 / 观测端 |

**存储布局**（3 个 OB 节点完全一致）：

| 挂载点 | LVM | dm 设备 | 条带 | 容量 |
|---|---|---|---|---|
| `/data/1` | `vg_data/lv_data` | `vg_data-lv_data` (253:0) | **6 × 128k** | 384 GiB |
| `/data/log1` | `vg_log/lv_log` | `vg_log-lv_log` (253:1) | **4 × 128k** | 256 GiB |

**负载**：`sysbench oltp_read_write`，10 表 × 50 万行，16 线程，
`--db-ps-mode=disable --mysql-ignore-errors=all`，全程持续运行。

### 7.0.1 Rocky 9.8 出厂默认值实测 [实测]

镜像开机后**未做任何修改**直接读取。

> **采样严谨性说明**：为避免"已被我方前置脚本修改过的值"混入出厂基准，
> 下表的 `vm.*` / `fs.*` 取自 **obctl 控制节点** —— 该节点自始至终**未执行过任何 OS 前置**，
> `/etc/sysctl.d/99-oceanbase.conf` 与 `/etc/security/limits.d/99-oceanbase.conf` 均不存在
> （证明输出见原始数据文件）。OB 节点（ob1/2/3）的 `vm.*` 已被前置脚本修改，**不可用作出厂基准**。

| 项 | 出厂实测值 | OB / Azure 官方要求 | 判断 |
|---|---|---|---|
| `nvme_core.io_timeout` | **30** | Azure 要求 **240** [官方] | 🔴 **必须改**（§8 L1） |
| `nvme_core.admin_timeout` | 60 | — | — |
| `nvme_core.shutdown_timeout` | 5 | — | — |
| `nvme_core.max_retries` | 5 | — | — |
| `/proc/cmdline` 中的 nvme 参数 | **无任何一项** | — | 佐证 io_timeout 未被镜像预设 |
| NVMe I/O 调度器 | **`[none]`** mq-deadline kyber bfq | "NVMe 默认为 `none`，无需调整" [官方] | ✅ 已符合 |
| `nr_requests` | 255 | — | — |
| `max_sectors_kb` | 256 | — | — |
| `vm.swappiness` | **60** | **0** [官方] | 🔴 **必须改** |
| `vm.dirty_ratio` | **20** | — | 上游内核默认 |
| `vm.dirty_background_ratio` | **10** | — | 上游内核默认 |
| `vm.max_map_count` | **65530** | **655360** [官方] | 🔴 **必须改** |
| `vm.min_free_kbytes` | 67584 | 2097152 [官方] | 🟡 建议改 |
| `fs.aio-max-nr` | **65536** | **1048576** [官方] | 🔴 **必须改** |
| `fs.file-max` | 9223372036854775807 | 6573688 [官方] | ✅ 出厂已远高于要求，**不要照抄官方值下调** |
| `tuned` | **未安装**（`tuned-adm: command not found`，`tuned.service` 不存在） | — | ✅ 无冲突（见 §8 L1） |
| SELinux | **Enforcing** | 建议 Permissive/Disabled | 🟡 需处理 |
| firewalld | 未安装 / inactive | — | — |
| swap | **无** | 建议关闭 | ✅（客户为自建 4G swap，需单独关闭） |
| 磁盘 model | `MSFT NVMe Accelerator v1.0` | — | 与客户现场一致 |
| 内核 | `5.14.0-687.10.1.el9_8.0.1.x86_64` | — | Rocky 9.8 (Blue Onyx) |

> **三条最关键的出厂默认值**：`nvme_core.io_timeout=30`（**不是** Azure 要求的 240）、
> `vm.swappiness=60`（**不是** OB 要求的 0）、`fs.aio-max-nr=65536`（**不是** OB 要求的 1048576）。
> 三者都需要显式修改，**镜像不会替你设好**。

> **⚠️ 一个反向陷阱**：OB 官方文档给出 `fs.file-max = 6573688`，而 Rocky 9.8 出厂值是
> `9223372036854775807`（内核上限）。若按官方文档"照抄设置"，反而会把该值**调低 12 个数量级**。
> 正确做法是取二者较大值，即**保持不动**。这一点在客户部署文档中同样需要复核。

原始数据：[`results/env-baseline.txt`](results/env-baseline.txt)

### 7.1 OB 4.3.5.5 参数默认值核验 [实测]

在真实集群上执行 `SELECT name, value, scope FROM oceanbase.GV$OB_PARAMETERS WHERE name IN (...)`，
**逐项核验本报告 §3 中所有由源码推导的默认值**：

| 参数 | 本报告源码推断 | **4.3.5.5 实测值** | scope | 一致 |
|---|---|---|---|---|
| `log_storage_warning_tolerance_time` | 5s | **5s** | CLUSTER | ✅ |
| `data_storage_warning_tolerance_time` | 5s | **5s** | CLUSTER | ✅ |
| `data_storage_error_tolerance_time` | 300s | **300s** | CLUSTER | ✅ |
| `_data_storage_io_timeout` | 10s | **10s** | CLUSTER | ✅ |
| `log_disk_utilization_threshold` | 80 | **80** | TENANT | ✅ |
| `log_disk_utilization_limit_threshold` | 95 | **95** | TENANT | ✅ |
| `log_disk_throttling_percentage` | 60 | **60** | TENANT | ✅ |
| `log_storage_warning_trigger_percentage` | 0（基于 main 分支源码） | **参数不存在** | — | ❌ **见 §3.3.1** |

**结论**：§3 中所有参数默认值的源码推断**全部被实测印证**，唯一的例外是
`log_storage_warning_trigger_percentage` —— 该参数在 4.3.5.5 中根本不存在（详见 §3.3.1 的双重核实）。

原始数据：[`results/params-verify.txt`](results/params-verify.txt)

### 7.2 因果链实测：从磁盘停顿到切主的完整时间线 [实测]

**方法**：在 leader 节点 ob1 上对日志盘 `/dev/mapper/vg_log-lv_log` 执行
`dmsetup suspend` → `sleep 15` → `dmsetup resume`（实际停顿 15.843s），
全程从 ob2 观测（避免观测通道自身被阻塞）。业务负载持续运行。

**实测时间线**（事件表时间为本地时区 UTC+8，注入起点 = 12:21:55.0）：

| 时刻 | 相对停顿起点 | 事件 | 来源 |
|---|---|---|---|
| 12:21:55.0 | **T+0** | `dmsetup suspend` 日志盘 | 注入器 |
| 12:22:00.99 | **T+5.03s** | `FAILURE_DETECTOR｜clog disk hang event｜LOG`，`hung time=5030662`μs | 事件表 + observer.log |
| 12:22:01.02 | T+5.06s | 同上（T1002 租户），`hung time=5055996`μs | 同上 |
| 12:22:01.16~01.94 | T+6.2~7.0s | `LOG｜ROLE TRANSITION` —— **T1 / T1001 / T1002 三个租户全部** | 事件表 |
| 12:22:02.04 | **T+7.04s** | `ELECTION｜change leader to takeover` @ **10.20.1.12** —— **新主接管** | 事件表 |
| 12:22:03.46 | T+8.46s | `ELECTION｜change leader to revoke` @ **10.20.1.11** —— **旧主让位** | 事件表 |
| 12:22:11.02 | T+16.0s（resume 瞬间） | `FAILURE_DETECTOR｜REMOVE FAILURE｜LOG` ×3 | 事件表 |
| 12:22:12~16 | T+17~21s | leader **自动回迁** ob1（`PRIMARY_ZONE=zone1` 驱动） | 事件表 |

**observer.log 原始记录**（ob1）：

```
[2026-08-31 04:22:00.994359] ERROR detect_palf_hang_failure_ (ob_failure_detector.cpp:357)
  [T1_Occam][T1][lt=5][errcode=-4392] disk is hung(msg="clog disk may be hung, add failure event",
  clog_disk_hang_event={type:PROCESS HANG, module:LOG, info:clog disk hang event, level:FATAL},
  clog_disk_last_working_time=1788150115963640, hung time=5030662)

[2026-08-31 04:22:11.099933] INFO  [COORDINATOR] detect_palf_hang_failure_ (ob_failure_detector.cpp:367)
  [T1_Occam][T1][lt=5] clog disk has recoverd, remove failure event(ret=0,
  clog_disk_hang_event={type:PROCESS HANG, module:LOG, info:clog disk hang event, level:FATAL})
```

**六条决定性结论**（全部 [实测]）：

1. **判定门槛精确等于 5s**。`hung time` 实测 5.031s / 5.056s / 5.068s，
   即在停顿开始后 **5.03~5.07 秒**触发，与 `log_storage_warning_tolerance_time` 默认值 **5s** 精确吻合，
   误差来自 100ms 的检测定时器周期。**§3.3 的源码分析得到完全验证**。
2. **事件等级确为 FATAL**，`{type:PROCESS HANG, module:LOG, level:FATAL}`，
   errcode **`-4392`**（`OB_DISK_HUNG`）—— 与 §3.3.2 源码分析一致。
3. **切主真实发生，且在停顿开始后约 7 秒完成**（T+7.04s 新主接管）。
   这回答了本报告此前列为 [待验证] 的核心问题：**"判定成立"确实会导致"实际切主"**。
4. **三个租户（sys / meta / 用户租户）同时切主** —— 与客户现场
   "T1 / T1001 / T1002 同时报错"的现象完全一致，交叉印证了现场日志的因果解释。
5. **恢复是立即的**：`dmsetup resume` 后 **同一秒内**（T+16.0s）即 `REMOVE FAILURE`，
   不存在 30 秒级的恢复观察窗口。
6. **一次抖动 = 两次切主**。因客户设置了 `PRIMARY_ZONE`，
   故障解除后 leader 会自动回迁，回迁本身又是一次切主（T+17~21s）。
   **业务侧因此会观察到两次连接中断，而非一次。**

原始数据：[`results/timeline-15s.txt`](results/timeline-15s.txt)

### 7.2.1 修正：确证 SQL 的正确写法 [实测]

本报告早期版本给出的确证 SQL 使用了 `gmt_create` 字段，**实际执行会报错**：

```
ERROR 1054 (42S22): Unknown column 'gmt_create' in 'where clause'
```

**4.3.5.5 上经过实测验证的正确写法**：

```sql
-- 注意：字段名是 timestamp（不是 gmt_create）；时间为 OB 会话时区
SELECT timestamp, svr_ip, module, event, name1, value1, name2, value2
FROM   oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE  timestamp BETWEEN '2026-07-20 15:00:00' AND '2026-07-20 15:10:00'
  AND  module IN ('FAILURE_DETECTOR','ELECTION','LOG')
ORDER  BY timestamp;
```

**实测确认的事件取值**（这是判读的关键，早期版本并不知道这些具体值）：

| module | event | name1 / value1 | 含义 |
|---|---|---|---|
| `FAILURE_DETECTOR` | **`clog disk hang event`** | `LOG` | **日志盘判定为 hang** —— 本案的核心签名 |
| `FAILURE_DETECTOR` | **`REMOVE FAILURE`** | `LOG` | 故障解除 |
| `ELECTION` | `change leader to takeover` | `TENANT_ID` | 该节点**接管**为新 leader |
| `ELECTION` | `change leader to revoke` | `TENANT_ID` | 该节点**让出** leader |
| `ELECTION` | `directly change leader` / `witness change leader` / `prepare change leader` | `TENANT_ID` | 选举过程记录 |
| `LOG` | `ROLE TRANSITION` | `TENANT_ID` | 日志流角色切换 |

**observer.log / alert.log 的可 grep 签名**（源自 `LOG_DBA_ERROR`，4.3.5.5 实测确认）：

| 签名 | 含义 |
|---|---|
| `clog disk may be hung, add failure event` | 日志盘判定 hang（`OB_FAILURE_LOG_DISK_HUNG`） |
| `data disk may be hung, add failure event` | 数据盘判定 hang（`OB_FAILURE_DATA_DISK_HUNG`） |
| `clog disk has recoverd, remove failure event` | 日志盘恢复 |
| `data disk has recoverd, remove failure event` | 数据盘恢复 |
| `clog disk is almost full, add failure event` | 日志盘水位告警 |
| `errcode=-4392` | `OB_DISK_HUNG` |

> **给客户的最小取证动作**：在 46 节点上执行
> `grep -E "disk may be hung|disk has recoverd|errcode=-4392" observer.log`，
> 并按上表查询 `DBA_OB_SERVER_EVENT_HISTORY`。
> 命中 `clog disk may be hung` 即可把 §3.5 的因果链从推断升级为现场直接证据。

### 7.3 日志盘停顿时长分档标定（默认参数） [实测]

**实验条件**：`log_storage_warning_tolerance_time = 5s`（出厂默认）。
在 ob1（持有全部 4 个日志流 leader）的日志卷 `vg_log-lv_log` 上 `dmsetup suspend N 秒`，
全程 `sysbench oltp_read_write`（16 线程）持续加压。
每档均等待 leader 复位到 ob1 后才开始，档间隔 50s。

**A. 切主判定与时间指标**（全部由 `DBA_OB_SERVER_EVENT_HISTORY` 机器化回溯，非人工读取）

| 请求 | 实际停顿 | 检测到 hang | 新主接管 | 旧主让位 | 故障解除 | leader 回迁 | hang 事件数 | 切走日志流 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| 2s | 2.312s | — | — | — | — | — | 0 | 0 / 4 | **无切主** |
| 3s | 3.839s | — | — | — | — | — | 0 | 0 / 4 | **无切主** |
| 4s | **4.794s** | — | — | — | — | — | 0 | 0 / 4 | **无切主** |
| 5s | **5.844s** | T+5.86s | T+6.51s | T+7.05s | T+6.66s | T+8.01s | 2 | **1 / 4** | **切主** |
| 6s | 6.318s | T+6.02s | T+6.60s | T+7.62s | T+7.22s | T+8.50s | 3 | **3 / 4** | **切主** |
| 8s | 8.082s | T+5.18s | T+5.80s | T+6.69s | T+8.18s | T+9.01s | 3 | **4 / 4** | **切主** |
| 10s | 10.084s | T+5.49s | T+6.10s | T+10.57s | T+10.54s | T+11.51s | 3 | **4 / 4** | **切主** |
| 15s | 15.079s | T+5.90s | T+6.51s | T+7.14s | T+15.90s | T+17.01s | 3 | **4 / 4** | **切主** |
| 30s | 30.635s | T+5.26s | T+6.01s | T+6.66s | T+30.82s | T+31.51s | 3 | **4 / 4** | **切主** |
| 60s | 60.071s | T+5.33s | T+6.01s | T+6.58s | T+60.26s | T+61.10s | 3 | **4 / 4** | **切主** |

> T = `dmsetup suspend` 发起时刻（秒级精度，因此各档 T+ 值有 ±1s 的采样误差）。
> 更精确的检测延迟以 `observer.log` 中的 `hung time` 字段为准，实测 **5.03~5.07s**（§7.2）。

**四条由上表直接读出的事实：**

1. **切主门槛精确落在 5s。** 4.794s 停顿 **0 个** hang 事件、**0 次**切主；
   5.844s 停顿即产生 hang 事件并切主。该边界与 `log_storage_warning_tolerance_time` 默认值 **5s** 完全吻合。
2. **检测延迟恒定，与停顿总长无关。** 各档检测时刻均在 **T+5.2 ~ T+6.0s**，
   30s 档与 60s 档的检测时刻（T+5.26 / T+5.33）与 8s 档（T+5.18）无差异。
   即 OB **不等停顿结束**，跨过 5s 线立即判定。
3. **影响面随停顿时长扩大。** 5.8s 只切走 1 个日志流；6.3s 切走 3 个；**≥8s 则 4 个全切**。
   即"停顿越长，被波及的租户越多"。
4. **故障解除严格发生在 I/O 恢复瞬间**（`故障解除` 列 ≈ `实际停顿` 列），
   随后约 **1.0 秒**完成 leader 回迁。因客户/本测试均配置了 `PRIMARY_ZONE`，
   **一次抖动 = 两次切主**（切走 + 回迁），业务被扰动两次。

**B. 业务面影响**（sysbench 每秒输出，机器化统计）

| 请求 | 实际停顿 | **TPS 归零最长连续秒** | TPS 归零总秒 | 停顿中是否恢复服务 | 第二次扰动（回迁） |
|---|---|---|---|---|---|
| 2s | 2.312s | **1s** | 3s | —（未切主） | 有 |
| 3s | 3.839s | **2s** | 5s | —（未切主） | 有 |
| 4s | 4.794s | **3s** | 4s | —（未切主） | 有 |
| 5s | 5.844s | **6s** | 9s | 是 | 有 |
| 6s | 6.318s | **5s** | 5s | 是 | 有 |
| 8s | 8.082s | **6s** | 9s | 是 | 有 |
| 10s | 10.084s | **5s** | 5s | 是 | 有 |
| 15s | 15.079s | **6s** | 6s | 是 | 有 |
| 30s | 30.635s | **6s** | 6s | 是 | 有 |
| 60s | 60.071s | **7s** | 7s | 是 | 有 |

> **⚠️ 这是本次测试最反直觉、也最重要的一条实测结论：**
> **默认参数下，写服务的完全中断时长被"封顶"在约 5~7 秒，与磁盘实际停顿多长无关。**
> 因为切主本身就是恢复手段 —— 停顿 60 秒时，OB 在 T+6s 把 leader 迁到 ob2，
> **业务在 T+7s 即恢复写入，而磁盘还要再停 53 秒**。

60s 档的 sysbench 逐秒原文（截取），可直接看出这一行为：

```
981s     tps=163.02    p95=7.43      <- 停顿前基线
985s     tps=131.00    p95=7.30      <- dmsetup suspend 发起
986s     tps=0.00      p95=0.00      <- 写入完全阻塞
987s ~ 992s   tps=0.00               <- 归零共 7 秒
993s     tps=14.00     p95=58.92     <- leader 已在 ob2, 服务恢复
994s ~ 1045s  tps=22~29  p95=38~52   <- 磁盘仍在停顿, 但业务持续可写(降级运行)
```

15s 档可清楚看到**两次**扰动：

```
755s     tps=276.03    p95=7.98      <- 停顿前
756s ~ 761s   tps=0.00               <- 第一次中断(6s), 切主
762s     tps=30.00     p95=6960.17   <- 恢复瞬间的延迟尖峰 6.96s
763s ~ 772s   tps=52~57  p95=38~44   <- 降级运行(磁盘仍停顿)
773s     tps=2.00      p95=363.18    <- 第二次扰动: leader 回迁
774s     tps=272.94    p95=9.22      <- 回到基线
```

**C. 这条结论对"是否该调参"的直接影响**

默认参数的行为并非"只有坏处"：它用**一次 5~7 秒的硬中断 + 一次回迁抖动**，
换来了"无论磁盘停多久，业务最多停 7 秒"的上限保证。
因此**调大 `tolerance_time` 是有代价的**——代价的量化见 §7.4。

原始数据：[`results/ladder-default.log`](results/ladder-default.log)、
[`results/timeline-default.txt`](results/timeline-default.txt)、
[`results/sb-default/`](results/sb-default/)

### 7.4 日志盘停顿时长分档标定（调优后） [实测]

**实验条件**：仅改一个参数 —— `log_storage_warning_tolerance_time` **5s → 60s**
（`ALTER SYSTEM SET`，在线生效，无需重启）。其余一切不变。

| 请求 | 实际停顿 | 检测到 hang | 新主接管 | hang 事件数 | 切走日志流 | **TPS 归零** | 判定 |
|---|---|---|---|---|---|---|---|
| 10s | 10.070s | — | — | 0 | 0 / 4 | **9s** | **无切主** |
| 15s | 15.080s | — | — | 0 | 0 / 4 | **15s** | **无切主** |
| 30s | 30.084s | — | — | 0 | 0 / 4 | **29s** | **无切主** |
| 45s | 45.078s | — | — | 0 | 0 / 4 | **44s** | **无切主** |
| 60s | 60.844s | T+61.61s | — | 1 | 0 / 4 | **60s** | **无切主**（边界） |
| **90s** | 90.836s | **T+61.18s** | T+62.51s | 2 | **4 / 4** | **61s** | **切主** |

> **数据有效性声明**：60s 与 90s 两行取自带负载的补测（`ladder_tuned2.txt`）。
> 首轮 tuned 标定中这两档因 sysbench 的 `--time` 预算到期而**在无客户端负载下执行**，
> 其业务指标无效，已作废并重测。10/15/30/45s 四档负载正常，数据有效。
> 此处如实记录，不做掩饰。

**三条关键结论：**

1. **门槛精确平移到新值。** 90s 档的检测时刻为 **T+61.18s**，
   与新设的 `tolerance_time = 60s` 完全吻合（默认参数时为 T+5.2~6.0s）。
   **参数确实是唯一且精确的旋钮。**
2. **🔴 保护并未被关闭。** 这是本次调参最重要的安全性验证：
   把阈值调到 60s **不等于**关闭磁盘故障检测 ——
   **90 秒的停顿依然被检出并依然切主**，4 个日志流全部迁走，行为与默认参数下完全一致，
   只是判定点从 5s 移到了 60s。**"调大阈值 = 埋掉真实坏盘"的担心，实测不成立。**
3. **60.844s 停顿是一个边界样本**：检测在 T+61.61s 触发（1 次 hang 事件），
   但 I/O 已在 T+60.8s 恢复，故障标记在 T+61.81s 即被清除，**未来得及引发 leader 变更**。
   说明"检测触发"与"实际切主"之间还有约 1.3 秒的窗口。

调优后 30s 档的 sysbench 逐秒原文 —— 注意**恢复是干净的，没有降级尾巴、没有第二次扰动**：

```
1600s   tps=126.03    p95=6.09      <- dmsetup suspend 发起
1601s ~ 1629s  tps=0.00             <- 阻塞 29 秒(= 停顿时长), 无切主
1630s   tps=25.00     p95=8.90      <- I/O 恢复
1631s   tps=176.03    p95=6.67      <- 立即回到基线, 无延迟尖峰
1632s ~ 1636s  tps=163~174 p95≈6.7  <- 稳定, 无二次扰动
```

原始数据：[`results/ladder-tuned.txt`](results/ladder_tuned.txt)、
[`results/ladder-tuned2.txt`](results/ladder_tuned2.txt)

### 7.4.1 🔴 核心规律：写中断时长的实测公式

把 §7.3 与 §7.4 的 16 个数据点放在一起，浮现出一条极其简单的规律：

> **写服务完全中断时长 ≈ min( 磁盘停顿时长, `tolerance_time` + 约 2 秒 )**

| 磁盘停顿 | tolerance=5s（默认）中断 | tolerance=60s（调优）中断 |
|---|---|---|
| 2.3s | 1s | —（未测） |
| 3.8s | 2s | —（未测） |
| 4.8s | 3s | —（未测） |
| 5.8s | **6s** | —（未测） |
| 6.3s | **5s** | —（未测） |
| 8.1s | **6s** | —（未测） |
| 10.1s | **5s** | **9s** |
| 15.1s | **6s** | **15s** |
| 30.6s | **6s** | **29s** |
| 45.1s | —（未测） | **44s** |
| 60.1 / 60.8s | **7s** | **60s** |
| 90.8s | —（未测） | **61s** |

**这条公式的含义，必须讲清楚：**

- **切主不是故障，切主是恢复手段。** 默认参数下，无论磁盘停 15s、30s 还是 60s，
  写服务都在约 **6~7 秒**后于新 leader 上恢复。OB 用一次切主，把"磁盘停多久就停多久"
  变成了"最多停 7 秒"。
- **调大 `tolerance_time` 会让写中断变长，而不是变短。** 把阈值调到 60s 后，
  一次 30s 的抖动会让写入**实打实阻塞 29 秒**（默认参数下只阻塞 6 秒）。
- 因此**"调参完全吸收、业务无感"这个说法，实测不成立**。
  调参能消除的是**切主这一状态变更事件**（及其伴随的 leader 漂移、回迁二次扰动、
  运维告警），**不能消除写阻塞** —— 磁盘停多久，写就阻塞多久。

**那么调参的价值到底是什么？** 见 §7.5 的副作用实测与 §8 的决策表。

### 7.5 调参副作用实测 [实测]

**A. 稳态性能影响 —— 无可测量差异**

同一集群、同一负载（sysbench 16 线程），分别在两种配置下各采样 **150 秒**：

| 配置 | 采样数 | TPS 均值 | TPS 中位数 | p95 延迟均值 | p95 延迟中位数 | p95 延迟最大 |
|---|---|---|---|---|---|---|
| `tolerance_time` = **5s**（默认） | 150 | **789.9** | 737.1 | 253.43 ms | **11.65 ms** | 3040 ms |
| `tolerance_time` = **60s**（调优） | 150 | **790.5** | 715.0 | 278.23 ms | **11.24 ms** | 3209 ms |
| **差异** | — | **+0.08%** | −3.0% | +9.8% | **−3.5%** | +5.6% |

**结论**：TPS 差异 0.08%，p95 延迟中位数差异 3.5%，**均在本环境的测量噪声范围内**。
该参数只在故障判定路径上被读取，不在 I/O 热路径上，实测与源码预期一致 ——
**调整该参数不引入稳态性能代价**。

> 说明：本测试环境使用 PSSDv2 默认基线（每盘 3000 IOPS / 125 MB/s），
> 单秒 TPS 抖动较大（`tps_min` 两组均为 0），因此上表以**中位数**为主要判据。
> 原始逐秒数据：[`results/steady_default5.txt`](results/steady_default5.txt)、
> [`results/steady_tuned60.txt`](results/steady_tuned60.txt)

**B. 对真实故障检出能力的影响 —— 未削弱，只是门槛平移**

| 验证项 | 结果 |
|---|---|
| 90s 停顿在 `tolerance=60s` 下是否仍被检出 | ✅ **是**，T+61.18s 检出 |
| 是否仍然切主 | ✅ **是**，4/4 日志流全部迁走 |
| 检出延迟是否等于新阈值 | ✅ **是**，61.18s ≈ 60s + 检测周期 |

即：**阈值调整是"平移"而非"关闭"**。这与 §3.4 的源码结论（时间阈值与
错误次数阈值 `MAX_DETECT_READ_WARN_TIMES=10` / `MAX_DETECT_READ_ERROR_TIMES=100`
是并列的"或"关系）相互印证。

**C. 应用可见错误数 —— 随阻塞时长上升**

sysbench 侧累计错误数（`err/s` 求和，已开 `--mysql-ignore-errors=all` 因此不中断压测）：

| 配置 | 停顿时长 | 应用错误数 |
|---|---|---|
| 默认 5s | 8.1s | 8 |
| 默认 5s | 10.1s | 4 |
| 默认 5s | 15.1s | 2 |
| 默认 5s | 30.6s | 1 |
| 调优 60s | 60.8s | **82** |
| 调优 60s | 90.8s | **106** |

**这是调大阈值的真实代价**：阻塞越久，越多在途事务超时报错。
在 2 秒停顿（远未达任何门槛、无切主）时就已观测到 `errno 4012 / Transaction result is unknown` —— 即**即便不切主，抖动本身也会让在途事务失败**，
应用侧的幂等重试是必需的（见 §8 L5）。

原始数据：[`results/final.log`](results/final.log)

### 7.6 Azure v6 存储基线性能实测 [实测]

> 这一节回答客户的 **Q1：OB 在 Azure v6 机型上的基线表现如何**。
> 测试在 ob3（follower 节点）上执行，`fio 3.35`，`--direct=1 --ioengine=libaio --time_based --runtime=30`。
> **磁盘均为 PSSDv2 出厂默认配置（未 provision 额外 IOPS/吞吐）**，与本测试环境一致。

| 场景 | 卷 | 组成 | IOPS | 带宽 | p99 延迟 | **p99.9 延迟** | **最大延迟** |
|---|---|---|---|---|---|---|---|
| 4k 随机读 | `/data/1` | 6 盘条带 | **20.3k** | 79.3 MiB/s | 60.0 ms | 202 ms | **577 ms** |
| 4k 随机写 | `/data/1` | 6 盘条带 | **18.4k** | 72.0 MiB/s | 71.8 ms | 184 ms | **594 ms** |
| 128k 顺序写 | `/data/1` | 6 盘条带 | 6,481 | **810 MiB/s** | 16.6 ms | 296 ms | **541 ms** |
| 128k 顺序写 | `/data/log1` | 4 盘条带 | 4,275 | **534 MiB/s** | 41.2 ms | 447 ms | **725 ms** |
| 4k 随机写 | `/data/log1` | 4 盘条带 | **12.6k** | 49.3 MiB/s | 325 ms | 692 ms | **🔴 1,141 ms** |

原始数据：[`results/fio-baseline.txt`](results/fio-baseline.txt)

#### 7.6.1 🔴 两个重要发现

**发现 A：实测吞吐精确等于"盘数 × PSSDv2 出厂基线"，条带化并没有突破 VM 上限，只是在拼凑基线。**

| 卷 | 盘数 | 理论基线（盘数 × 3,000 IOPS / 125 MB/s） | 实测 | 吻合度 |
|---|---|---|---|---|
| `/data/1` | 6 | 18,000 IOPS / 750 MB/s | 20.3k IOPS / 850 MB/s | ✅ 吻合 |
| `/data/log1` | 4 | 12,000 IOPS / 500 MB/s | 12.6k IOPS / 560 MB/s | ✅ 吻合 |

对比 **Standard_D32s_v6 的 VM 级上限：66,667 IOPS / 1,984 MBps** [官方]：

- 6 盘条带只用掉了 VM 能力的 **约 30%**；
- **单块 PSSDv2 即可 provision 到 80,000 IOPS / 1,200 MB/s** [官方]，
  **一块盘就能超过这 6 块盘条带的总和（20.3k）约 4 倍**。

> **即：当前的多盘条带布局，既没有换来性能，又把抖动暴露面放大了 4~6 倍。**
> 这是本次实测对"最小改动集第 1 项（降低条带数）"的**直接数据支撑**
> —— 该建议不牺牲任何性能，反而提升性能上限。

**发现 B：在未 provision 额外 IOPS 的情况下，卷被打满时的尾延迟本身就已进入"OB 判定门槛"的量级。**

上表最后一行：clog 卷 4k 随机写在跑满 12.6k IOPS（= 4 盘基线之和）时，
**p99.9 延迟 692 ms，最大延迟 1.14 秒 —— 而这期间没有注入任何故障，磁盘完全健康。**

这意味着：

1. 卷一旦接近其 provisioned 上限，**排队延迟会迅速进入百毫秒到秒级**；
2. 从 OceanBase 的视角看，**"限流排队导致的慢 I/O"与"平台瞬时抖动导致的慢 I/O"是同一种现象** ——
   都只是"这个 I/O 很久没返回"，`ObFailureDetector` 无法区分二者（§3.3 源码）；
3. 因此 **provisioned IOPS/吞吐不足，本身就是一个可以独立触发磁盘故障判定的因素**，
   与平台抖动无关，且**完全在客户可控范围内**。

> **给客户的可执行动作**：确认 `/data/log1` 与 `/data/1` 各盘的
> **provisioned IOPS 与吞吐**设置，以及业务高峰期的实际使用率。
> 若长期运行在 provisioned 上限附近，应先**上调 provisioned 值**——
> 这比调 OB 参数更根本，且没有任何副作用。
>
> 客户各盘的 provisioned 值目前**仍未知**，是本报告最重要的待取证项之一。

#### 7.6.2 与客户环境的差异说明

| 项 | 本测试环境 | 客户环境 | 影响 |
|---|---|---|---|
| 单盘容量 | data 6×64G / clog 4×64G | data 6×300G / clog 4×250G | **PSSDv2 基线 IOPS 与容量无关**（均为 3,000），故结构性结论可迁移 |
| provisioned IOPS/吞吐 | 未设置（用默认基线） | **未知** | 若客户已上调，绝对数值会更高，但"条带 vs 单盘 provisioned"的结论不变 |
| 条带宽度 | 与客户一致（6 / 4，128k） | 6 / 4，128k | 一致 |

### 7.7 尚未执行的测试项

以下项目在本轮测试中**未执行**，不得据此下任何结论：

- 7.7.1 A 域（OS 盘）抖动影响 —— `_未测_`
- 7.7.2 B 域（数据盘 `/data/1`）抖动影响 —— `_未测_`（本轮只标定了 C 域日志盘）
- 7.7.3 分层调优（L1 / L2 / L4）各自的贡献度 —— `_未测_`
- 7.7.4 leader 集中 vs 均衡的影响面对比 —— `_未测_`
- 7.7.5 **A 组（多盘条带）vs B 组（单盘 provisioned）的抖动 A/B 对照** —— `_未测_`
  （§7.6 已实测两者的**性能**差异，但**抖动命中概率**的差异未做对照实验）
- 7.7.6 `dm-flakey`（停顿 + 错误返回）对照组 —— `_未测_`
- 7.7.7 三节点同时抖动（多数派同时失效）—— `_未测_`
- 7.7.8 单块底层 PV 停顿（条带化放大效应的直接验证）—— `_未测_`

---

## 8. 最佳实践配置清单

> 标注 [待实测确认] 的项需经 §7 验证后方可作为最终建议。

### L1 — OS / 内核（Rocky Linux 9.8）

**环境事实** [官方]：

| 项 | 值 | 出处 |
|---|---|---|
| Rocky Linux 9.8 | 2026-05-27 GA，RHEL 9.8 下游 | rockylinux.org/news |
| Rocky Linux 9 生命周期 | Active Support 至 2027-05-31，EOL 2032-05-31 | wiki.rockylinux.org/rocky/version |
| Azure 是否认可 Rocky Linux | **是**，经 CIQ 发布，"Microsoft CSS provides commercially reasonable support" | endorsed-distros |
| OB 4.3.5 是否支持 Rocky Linux 9 | **是**，官方支持矩阵明确列出 | OB 官方服务器配置文档 |
| 内核上游 `nvme_core.io_timeout` 默认 | **30** 秒（`unsigned int nvme_io_timeout = 30;`） | kernel `drivers/nvme/host/core.c` |
| RHEL 9 上 NVMe 默认 I/O 调度器 | `none`；OB 官方："NVMe SSD 默认的 I/O 调度器为 `none`，**无需调整**" | OB 官方 / RH KCS 5427 |

> ⚠️ **值得关注**：Azure `enable-nvme-interface` 文档中列出的 NVMe 支持镜像清单，Rocky 分支只到 **Rocky Linux 8.10 / 9.6**，**未包含 9.8** [官方]。这不代表 9.8 不可用，但意味着**该镜像不在 Azure 已验证的"出厂即 240s"范围内，`nvme_core.io_timeout` 必须自行确认和设置**。

**建议项：**

| 项 | 建议值 | 依据 |
|---|---|---|
| `nvme_core.io_timeout` | **240** | [官方] MS Learn 明确要求；上游默认仅 30s，必须确认实际值 |
| swap | 关闭（或移出 OS 盘） | 客户 OS 盘上有 4G swap；OS 盘停顿时换页会阻塞内存回收 |
| `vm.swappiness` | **0** | [官方] OB 官方服务器配置文档要求 `vm.swappiness = 0` |
| `tuned` profile | **确认是否为 `virtual-guest`** | 见下方说明 |
| `transparent_hugepage` | `never` | 客户已配置 ✔ |
| `numa` | `off` | 客户已配置 ✔ |
| 挂载参数 | `noatime,nodiratime` | 客户已配置 ✔ |
| I/O 调度器 | `none` | [官方] NVMe 默认即为 `none`，无需调整 |

> **⚠️ `tuned` 可能覆盖 OB 官方要求，但在 Azure Rocky 9.8 镜像上实测「未安装」。**
>
> RHEL 9 在虚拟机上的默认 tuned profile 是 `virtual-guest` [官方]，
> 其上游定义（[官方，`redhat-performance/tuned` 仓库]）见下方代码块。
> 若该 profile 生效，会带来两点风险：`vm.swappiness=30` 覆盖 OB 要求的 `0`；
> `dirty_bytes=30%` 在 128 GiB 内存上约合 38 GB 脏页阈值，回写风暴峰值 I/O 更大。

```ini
# tuned profile: virtual-guest  (RHEL 9 虚拟机默认)
[main]
include=throughput-performance
[vm]
dirty_bytes = 30%          # 内核默认 dirty_ratio 为 20%
[sysctl]
vm.swappiness = 30         # OB 官方要求 0
```

**✅ 实测结论：Azure Marketplace 的 Rocky 9.8 镜像并未安装 tuned，因此该冲突在本环境中不存在** [实测]

在 `resf:rockylinux-x86_64:9-base:9.8.20260525` 镜像上开机后直接检查：

```
# tuned-adm active
-bash: tuned-adm: command not found
# systemctl status tuned
Unit tuned.service could not be found.
# sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
vm.swappiness = 60            ← 上游内核默认值，非 tuned 的 30
vm.dirty_ratio = 20           ← 上游内核默认值，非 tuned 的 30%
vm.dirty_background_ratio = 10
```

三个值都等于**上游内核默认值**，而不是 `virtual-guest` profile 的值，交叉印证了 tuned 确实未生效。

**这修正了本报告早期版本的一处判断**：此前基于"RHEL 9 虚拟机默认启用 `virtual-guest`"的官方文档推断出该冲突存在，实测表明 Azure 的 Rocky 9.8 镜像**未预装 tuned**，因此不存在被覆盖的问题。

**但 `vm.swappiness = 60` 仍需修改** —— 它虽然不是 tuned 造成的，却同样违反 OB 官方要求的 `0`，且客户 OS 盘上启用了 4G swap。

**现场核实命令（客户环境仍需执行一次，因为客户可能自行安装过 tuned）：**

```bash
command -v tuned-adm && tuned-adm active || echo "tuned not installed"
sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
```

**设置方式（Rocky Linux 9 / RHEL 9）：**

NVMe 驱动通常在 initramfs 阶段加载（根文件系统位于 NVMe 盘上），因此**仅写 `/etc/modprobe.d/` 不足以生效，必须重建 initramfs**；更稳妥的做法是**两者都做**。

```bash
# 方式一：内核命令行（推荐，最可靠）
grubby --update-kernel=ALL --args="nvme_core.io_timeout=240"

# 方式二：模块参数 + 重建 initramfs（RHEL 9 官方持久化流程）
echo 'options nvme_core io_timeout=240' > /etc/modprobe.d/99-nvme-timeout.conf
dracut -f --regenerate-all

reboot

# 验证（四处都要看）
cat /proc/cmdline | tr ' ' '\n' | grep nvme_core   # 期望 nvme_core.io_timeout=240
cat /sys/module/nvme_core/parameters/io_timeout    # 期望 240
lsblk -d -o NAME,MODEL,SIZE | grep -i nvme         # 确认走的是 NVMe 接口
uname -r                                           # 记录实际内核版本
```

> Red Hat 官方文档对该流程的表述 [官方]：*"Generate a new initial RAM disk image to apply the changes: `dracut -f -v ...`"*，*"The changes described in this procedure will take effect and persist after rebooting the system."*

### L2 — 存储布局

| 项 | 建议 | 依据 |
|---|---|---|
| 条带盘数 | **降为单块大容量 PSSDv2 + provisioned IOPS/吞吐** | §4.1.1：在 D32s v6 上单盘即可封顶 VM 级上限（66,667 IOPS / 1,984 MBps），条带化只换来 4~6 倍暴露面 [官方] |
| provisioned 值 | data / clog 各按需求设置，**单盘 ≥160 GiB 即可 provision 到 80,000 IOPS**，8,000 IOPS 以上可达 2,000 MB/s | [官方] `disks-types` |
| 三域隔离 | OS / data / clog 使用独立卷 | 客户已隔离 ✔ |
| clog 水位 | 降至 **60% 以下** | §4.3：78% 已越过 `log_disk_throttling_percentage`(60) 写入限流线，且逼近 `log_disk_utilization_threshold`(80) 回收线 |
| host caching | 无需考虑 | [官方] "Premium SSD v2 doesn't support host caching"；且 Dsv6 系列无本地临时盘，VM 规格表仅列 Uncached 指标 |

微软官方对"是否需要条带化"的直接表述 [官方]：

> "The ability to adjust IOPS, throughput, and size at any time also means you can **avoid the maintenance overhead of having to stripe disks** to meet your needs."

### L3 — OceanBase 判定模型（关键层）

> **🔴 先读这一段：L3 不是"越大越好"**
>
> 本次实测（§7.4.1）得到的规律是
> **写中断时长 ≈ min(磁盘停顿时长, `tolerance_time` + 约 2s)**。
> 因此调大该参数**不会**让业务无感，只会把"短而硬的中断 + 切主"
> 换成"长而软的阻塞 + 无状态变更"。
>
> **取值必须按实际抖动包络标定，不能照抄 60s。** 先做下面的取证，再定值。

**第 0 步：先测出你自己的抖动包络**（没有这一步，后面的取值就是拍脑袋）

```sql
-- 过去 30 天所有磁盘 hang 判定事件；看 hung time 的分布与上界
SELECT timestamp, svr_ip, event, value1, value2
FROM   oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE  module = 'FAILURE_DETECTOR'
ORDER  BY timestamp DESC;
```

```bash
# observer.log 侧：抖动的真实时长分布（result_delay 单位 us）
grep -oP 'result_delay[=:]\s*\K[0-9]+' observer.log \
  | awk '{printf "%.1f\n", $1/1000000}' | sort -n | uniq -c
```

**第 1 步：按包络取值**

```sql
-- ===== 日志盘：唯一有效的门槛参数 =====
-- 取值原则: 略高于抖动包络上界(P99.9), 而不是"尽可能大"
--   抖动包络 <= 10s  -> 设 15s
--   抖动包络 <= 30s  -> 设 35~45s
--   包络不明          -> 保持默认 5s, 先取证
-- 客户现场已观测到 6.1~11.3s(样本 14), 若确认上界在 15s 内, 建议:
ALTER SYSTEM SET log_storage_warning_tolerance_time    = '20s'; -- 取值 [1s,300s]

-- ⚠️ log_storage_warning_trigger_percentage 在 4.3.5.5 中不存在(§3.3.1), 无需处理。
--    若日后升级到含该参数的版本, 必须保持默认 0 ——
--    源码中它与 tolerance_time 是 || 关系, 调大只会新增判定路径, 使检测更敏感。

-- ===== 数据盘：两个参数串联, 总门槛 = io_timeout + warning_tolerance =====
ALTER SYSTEM SET data_storage_warning_tolerance_time   = '20s'; -- 与上面对齐
-- _data_storage_io_timeout 保持 10s 即可:
--   它只决定"何时开始探测", 探测本身还有 warning_tolerance 的窗口。
-- ALTER SYSTEM SET _data_storage_io_timeout           = '10s';  -- 默认, 取值 [1s,600s]

-- ===== ERROR 级保持默认, 确保真实坏盘仍能被及时发现 =====
-- data_storage_error_tolerance_time = 300s  (默认, 不建议调整)
```

**第 2 步：验证（实测已确认这两点，客户侧应复现一次）**

| 验证项 | 本次实测结果 | 出处 |
|---|---|---|
| 稳态性能是否受影响 | **否**，TPS 差异 +0.08%，p95 中位差异 −3.5% | §7.5A |
| 超过新阈值的停顿是否仍被检出并切主 | **是**，90s 停顿在 tolerance=60s 下仍于 T+61.18s 检出并切主 4/4 日志流 | §7.4 |

**为什么这样调是安全的（源码级论证 + 实测印证）：**

放宽 `*_tolerance_time` 只放宽了**"超时"**判定，**不影响"报错"判定**。数据盘探测路径中两者是 `||` 关系 [源码]：

```cpp
if (current_ts >= error_ts || (sys_io_errno != 0 && fs_error_times >= 100)) {
  set_device_error();
} else if (current_ts >= warn_ts || (sys_io_errno != 0 && fs_error_times >= 10)) {
  set_device_warning();
}
```

真实坏盘几乎总是伴随 `sys_io_errno != 0`（EIO 等），走的是右半支，**与 `tolerance_time` 无关**。因此：

| 故障形态 | 调参后是否仍能及时检出 |
|---|---|
| 磁盘返回 I/O 错误（真实坏盘） | **是**，10 次错误即 WARNING，100 次即 ERROR，不受 tolerance_time 影响 [源码] |
| 磁盘完全无响应（挂死） | **是** —— **已实测**：90s 停顿在 tolerance=60s 下仍被检出并切主（§7.4） |
| 短时高延迟（平台抖动） | **否** —— 这正是调参想要的效果，代价是改为写阻塞（§7.4.1） |

**必须一并说明的权衡（实测支撑）：**

| 权衡项 | 实测数据 |
|---|---|
| 写阻塞时长变长 | 30s 抖动：默认阻塞 6s → 调优后阻塞 **29s**（§7.4.1） |
| 应用可见错误增多 | 60.8s 阻塞产生 **82 个**错误，90.8s 产生 **106 个**（§7.5C） |
| 纯超时型慢盘检出延后 | 从 5s 延后到新阈值（不影响报错型故障） |
| 稳态性能 | **无可测量影响**（§7.5A） |

- 抖动窗口内业务侧仍会出现延迟升高与在途事务失败，**必须配合 L5 的应用侧幂等重试**；
- 建议配合平台侧磁盘健康监控形成双重保障；
- **若抖动包络长期 ≥60s，应保持默认参数** —— 此时切主（7s 中断）优于阻塞（60s）。

### L4 — 缓冲与节流

| 参数 | 建议 | 说明 |
|---|---|---|
| `freeze_trigger_percentage` | 30 | 客户已配置 ✔，更大的 memstore 缓冲有助于吸收停顿 |
| `syslog_io_bandwidth_limit` | 保持默认 30MB | 限制日志 I/O 突发 |
| `enable_async_syslog` | `true`（默认） | 异步日志，避免 syslog 阻塞数据库线程 |

### L5 — 架构与接入层

| 项 | 建议 | 依据 |
|---|---|---|
| leader 分布 | **打散**，避免多数日志流 leader 集中于单节点 | §4.2 |
| `enable_rebalance` / `enable_transfer` | **谨慎评估**后再开启 | 开启会引入后台搬迁 I/O，可能反增抖动命中面 [待实测确认] |
| 应用侧 | 幂等重试 + 合理的连接池超时 | 切主 RTO 期间在途事务会失败，需应用侧承接 |

---

## 9. 下一步行动

### 9.1 可立即执行（不需要测试环境）

| # | 事项 | 目的 |
|---|---|---|
| 1 | 在三节点执行**结论速览**中的 **`FAILURE_DETECTOR` 事件查询 SQL** | **一条 SQL 即可确证** 2026-07-20 的切主是否由磁盘故障判定引发，以及是 LOG 还是 STORAGE 模块 |
| 2 | 现场核实 `cat /sys/module/nvme_core/parameters/io_timeout` | 确认 Rocky 9.8 镜像实际生效值是 240 还是 30（Azure 清单未含 9.6 之后版本） |
| 3 | 现场核实 `tuned-adm active` + `sysctl vm.swappiness vm.dirty_ratio` | 排查 tuned `virtual-guest` 覆盖 OB 官方要求的 `vm.swappiness=0`（§8 L1） |
| 4 | 向客户索取各磁盘的 provisioned IOPS / 吞吐设置 | 判定条带化是否真的换到了性能（§4.1.1、L2） |
| 5 | 索取三节点完整 `observer.log` + `election.log`（不过滤） | 补齐 §3.5 的证据边界 |

### 9.2 需要测试环境

| # | 事项 | 目的 | 阻塞了什么 |
|---|---|---|---|
| 6 | 搭建 3 × D32s v6 测试环境 | 执行 `TEST-PLAN.md` | §7 全部实测章节 |
| 7 | 执行 `TEST-PLAN.md` §5.1 **`tolerance_time` 门槛标定实验**（场景 S1，日志盘全档位注入） | 验证 §5.1 的源码结论，标定最优 `tolerance_time` | §8 参数取值定稿 |
| 8 | 执行 S11（A/B 布局性能对比） | 验证"条带化换不来性能"命题 | §4.1.1、L2 建议定稿 |
| 9 | 执行 S7（三节点同时抖动） | 界定"架构无法兜底"的边界 | §5.2 边界说明定稿 |
| 10 | 在 4.3.5.5 上用 `GV$OB_PARAMETERS` 复核全部参数默认值 | 确认本文源码引用与实际版本一致 | §3 各表格的版本适用性 |

> 上表 S1 / S7 / S11 为 `TEST-PLAN.md` 的**测试场景编号**；
> 正文中形如 `[源码] S3` 的引用为**附录源码清单编号**，两套编号互不相干。

> §8 中的参数**方向性结论已由源码确定**（调 `tolerance_time`、不调 `trigger_percentage`），
> 但**具体取值（60s）仍建议经第 7 项标定后再定稿**。

---

## 10. 附录：完整引用清单

### 官方文档

| # | 内容 | URL |
|---|---|---|
| A1 | Azure NVMe 支持的 OS 镜像与 `nvme_core.io_timeout=240` 要求 | <https://learn.microsoft.com/azure/virtual-machines/enable-nvme-interface> |
| A2 | Azure NVMe 通用 FAQ | <https://learn.microsoft.com/azure/virtual-machines/enable-nvme-faqs> |
| A3 | OceanBase `data_storage_error_tolerance_time` | <https://www.oceanbase.com/docs/common-oceanbase-database-cn-10000000001702092> |
| A4 | OceanBase `data_storage_warning_tolerance_time` | <https://www.oceanbase.com/docs/common-oceanbase-database-cn-10000000001702093> |
| A5 | **Dsv6 系列规格**：无本地临时盘；Standard_D32s_v6 uncached PSSDv2 上限 66,667 IOPS / 1,984 MBps | <https://learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dsv6-series> |
| A6 | **Azure 托管磁盘类型**：PSSDv2 不支持 host caching；IOPS/吞吐 provision 规则；"可避免条带化的维护开销" | <https://learn.microsoft.com/azure/virtual-machines/disks-types> |
| A7 | **Azure 认可的 Linux 发行版**：Rocky Linux（CIQ）— "Microsoft CSS provides commercially reasonable support for these images." | <https://learn.microsoft.com/azure/virtual-machines/linux/endorsed-distros> |
| A8 | **OceanBase V4.3.5 服务器配置**：支持的 OS 矩阵（含 Rocky Linux 9、RHEL 7/8/9）；`vm.swappiness=0`；"NVMe SSD 默认的 I/O 调度器为 `none`，无需调整" | <https://www.oceanbase.com/docs/common-oceanbase-database-cn-1000000002013491> |
| A9 | **Rocky Linux 9.8 GA 公告**（2026-05-27，RHEL 9.8 下游） | <https://rockylinux.org/news/rocky-linux-9-8-ga-release> |
| A10 | **Rocky Linux 版本与生命周期**：Rocky 9 Active Support 至 2027-05-31，EOL 2032-05-31 | <https://wiki.rockylinux.org/rocky/version/> |
| A11 | **RHEL 9 内核模块管理**：`/etc/modprobe.d/*.conf` + `dracut -f` 持久化流程 | <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/managing-kernel-modules_managing-monitoring-and-updating-the-kernel> |
| A12 | **RHEL 9 默认 tuned profile**：虚拟机为 `virtual-guest` | <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/monitoring_and_managing_system_status_and_performance/index> |
| A13 | **tuned `virtual-guest` profile 定义**：`dirty_bytes=30%`、`vm.swappiness=30`（继承 `throughput-performance`） | <https://github.com/redhat-performance/tuned/blob/master/profiles/virtual-guest/tuned.conf> |
| A14 | **RHEL 9 磁盘调度器**；KCS 5427 I/O 调度器推荐 | <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/setting-the-disk-scheduler_monitoring-and-managing-system-status-and-performance> |

### 上游内核源码

| # | 文件 | 内容 |
|---|---|---|
| K1 | `drivers/nvme/host/core.c` | `unsigned int nvme_io_timeout = 30;` — NVMe I/O 超时上游默认值 |
| K2 | `drivers/nvme/host/nvme.h` | `#define NVME_IO_TIMEOUT (nvme_io_timeout * HZ)` |
| K3 | `mm/page-writeback.c` | `dirty_background_ratio = 10`、`vm_dirty_ratio = 20` 上游默认值 |
| K4 | `mm/vmscan.c` | `int vm_swappiness = 60;` 上游默认值 |

### 源码

仓库 `oceanbase/oceanbase`，commit `fa399038f7edf3313575bd49d8c4a7cc64825c2e`

| # | 文件 | 内容 |
|---|---|---|
| S1 | `src/share/parameter/ob_parameter_seed.ipp` | `_data_storage_io_timeout`、`data_storage_warning_tolerance_time`、`data_storage_error_tolerance_time`、`log_storage_warning_tolerance_time`、`log_storage_warning_trigger_percentage`、`log_disk_utilization_threshold`、`log_disk_utilization_limit_threshold`(95, [80,100])、`log_disk_throttling_percentage`(60, [40,100]) 的定义、默认值与取值范围 |
| S2 | `src/logservice/leader_coordinator/ob_failure_detector.cpp` | **本文核心**。`is_clog_disk_hang()` 的"或"式判定结构（§3.3.1）；`detect_palf_hang_failure_()` / `detect_data_disk_io_failure_()` 产出 `FailureLevel::FATAL`；`insert_event_to_table_()` 写入 `__all_server_event_history`；detect 定时器周期 100ms |
| S3 | `src/logservice/palf/election/utils/election_common_define.h` | PALF 选举租约、续约周期、触发选举水位线的计算式 |
| S4 | `src/logservice/palf/election/algorithm/election_impl.cpp` | `RoleChangeReason::LeaseExpiredToRevoke` 租约到期卸任 |
| S5 | `mittest/logservice/test_ob_simple_log_disk_hang.cpp` | 官方磁盘 hang 集成测试用例，可作方法论参考 |
| S6 | `src/logservice/palf/palf_options.{h,cpp}` | 日志盘水位三阈值的语义注释与约束校验（`limit_threshold > utilization_threshold`） |
| S7 | `src/logservice/leader_coordinator/election_priority_impl/election_priority_v1.cpp` | `PriorityV1::compare()` 比较顺序；`compare_fatal_failures_` 为第 1 顺位故障判据；`refresh_()` 读取 FATAL 事件 |
| S8 | `src/share/io/ob_io_struct.cpp` | 数据盘链路：`ObIOFaultDetector::record_io_timeout()`（**仅 read**）；`handle_retry_task_()` 的 `warn_ts`/`error_ts` 计算；`get_device_health_status()` 的 WARNING 清除条件；`read_failure_black_list_interval_ = 60s` |
| S9 | `src/share/io/ob_io_define.h` | `MAX_DETECT_READ_WARN_TIMES = 10`、`MAX_DETECT_READ_ERROR_TIMES = 100` — 真实坏盘的独立快速通道 |
| S10 | `src/logservice/leader_coordinator/ob_failure_detector.h` | `PALF_DISK_DETECT_INTERVAL_US = 1s`、`MIN_RECOVERY_INTERVAL = 30s`、`PALF_DISK_FAILURE_TIME_UPPER_BOUND = 30min` |

### 社区（非官方，仅作旁证）

| # | 内容 | URL |
|---|---|---|
| C1 | 日志盘 hang 5 秒导致 OB 切主的用户反馈 | <https://ask.oceanbase.com/t/topic/35604965/3> |

### 现场材料

| # | 文件 | 内容 |
|---|---|---|
| F1 | `observer46.txt` | 2026-07-20 failover 时段 observer 日志摘录、磁盘布局、挂载信息 |
| F2 | `OceanBase安装文档-泰国.docx` | 客户 OB 部署流程与参数配置 |
