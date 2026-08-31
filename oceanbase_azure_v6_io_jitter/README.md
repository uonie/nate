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
| Q1 | OB 在 Azure v6 上表现如何 | **无版本级不兼容**。OB 4.3.5 官方支持 Rocky Linux 9 [官方]；Rocky Linux 是 Azure 认可发行版 [官方]。问题不在"能不能跑"，而在**默认容错阈值与云盘延迟分布不匹配** | A7 / A8 |
| Q2 | 默认参数下抖动会造成什么影响 | **源码层面确定会触发磁盘故障判定**：日志盘门槛 5s，数据盘约 15s；现场 14/14 次慢 I/O 均 > 5s（p50 10.2s）[现场]。判定 → FATAL → 优先级降级的代码路径已逐行核实 [源码]。**"实际切主"这一步还取决于运行时条件（其他副本状态等），需实测确认** | S2 / S8 / F1 |
| Q3 | **能否通过调参完全吸收** | **源码层面确定参数空间足够**：门槛完全由两个 `*_tolerance_time` 决定（上限均 300s），**且不经过 PALF 4s 硬编码租约**，不存在"调不动的天花板" [源码]。**"60s 是否够用、代价多大"须由 `TEST-PLAN.md` §5.1 + §8 实测标定** | S7 / S3 / S9 |
| Q4 | 最佳实践配置 | 见 §8。**最小改动集**为下方 4 条 | — |

**最小改动集（按收益/风险排序）：**

| 顺序 | 层 | 动作 | 需重启 | 风险 |
|---|---|---|---|---|
| 1 | OS | `nvme_core.io_timeout=240`（对齐 Azure 官方值） | 是 | 极低 |
| 2 | OB | `log_storage_warning_tolerance_time` 5s → **60s** | 否 | 低 |
| 3 | OB | `data_storage_warning_tolerance_time` 5s → **60s** | 否 | 低 |
| 4 | OB | `log_storage_warning_trigger_percentage` **保持 0（不要动）** | — | — |

> **不要做**：调大 `log_storage_warning_trigger_percentage`（会让检测更敏感）；调大 `data_storage_error_tolerance_time`（300s 是真实坏盘的兜底线，应保留）。

> **⚠️ 上表的"确定"与"待定"分界**：
> **调哪个参数、往哪个方向调 = 源码已确定**（这是代码事实，不需要实测）。
> **调到 60s 是否恰好合适、业务侧代价多大 = 必须实测**（`TEST-PLAN.md` §5.1 标定实验 + §8 记录表）。
> 本文不提供任何未经实测的性能数字或行为断言。

**确证用 SQL** —— 一条查询即可判定当时是否真的发生了磁盘故障判定。源码中 `ObFailureDetector` 的每一次判定都会写入 `__all_server_event_history` [源码]：

```sql
SELECT gmt_create, svr_ip, module, event, name1, value1, name2, value2
FROM oceanbase.DBA_OB_SERVER_EVENT_HISTORY
WHERE module = 'FAILURE_DETECTOR'
  AND gmt_create BETWEEN '2026-07-20 15:00:00' AND '2026-07-20 15:10:00'
ORDER BY gmt_create;
```

若返回 `FAILURE_MODULE = LOG` / `FAILURE_TYPE = PROCESS_HANG` 的记录，即为切主原因的**直接证据**。

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
3. **但 Azure `enable-nvme-interface` 页面列出的 NVMe 支持镜像清单中，Rocky 分支只到 8.10 / 9.6，未包含 9.8。** 该页面同时说明"某些较旧的操作系统镜像默认超时为 30 秒"。因此 **`nvme_core.io_timeout` 的实际生效值必须现场确认，不能假定为 240**（§8 L1）。

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

源码 `src/share/parameter/ob_parameter_seed.ipp` [源码]：

```cpp
DEF_TIME(log_storage_warning_tolerance_time, OB_CLUSTER_PARAMETER, "5s", "[1s,300s]", ...);

DEF_INT(log_storage_warning_trigger_percentage, OB_CLUSTER_PARAMETER, "0", "[0,50]",
  "The performance decrease percentage threshold that may trigger a log disk failure. "
  "The default value is 0, which means the log disk will be considered to have failure "
  "only if any IO RT exceeds log_storage_warning_tolerance_time. "
  "If the value is greater than 0, which means the log disk will be considered to have failure "
  "only if current IO throughput < (normal throughput * log_storage_warning_trigger_percentage / 100) "
  "and performance degradation has been ongoing for log_storage_warning_tolerance_time seconds.");
```

**参数文档描述的两种模式：**

| `log_storage_warning_trigger_percentage` | 文档描述的判定模型 |
|---|---|
| **`0`（默认）** | 任意单个 I/O 的 RT 超过 `log_storage_warning_tolerance_time`（5s）→ 判定日志盘故障 |
| `> 0` | 当前吞吐 < 正常吞吐 × N% **且持续劣化达 `log_storage_warning_tolerance_time` 秒** → 判定故障 |

### 3.3.1 ⚠️ 源码修正：两种模式是「或」关系，不是「替换」关系

参数文档的措辞（"`If the value is greater than 0, which means ... only if ...`"）**极易被误读为"调大该参数就能改用更宽松的判定模型"**。核查消费方源码后可以确认，**事实并非如此**。

消费方 `src/logservice/leader_coordinator/ob_failure_detector.cpp` → `PalfDiskHangDetector::is_clog_disk_hang()` [源码]：

```cpp
const int64_t tolerance_time = GCONF.log_storage_warning_tolerance_time;
sensitivity = GCONF.log_storage_warning_trigger_percentage;
...
const double bw_error_ratio = MIN(0.5, 0.01 * sensitivity);
...
// 路径①：IO worker 长时间没有推进
const bool has_long_pending_io = (OB_INVALID_TIMESTAMP != last_working_time
    && now - last_working_time > tolerance_time);
...
if (false == has_failure) {
  if (((has_small_pending_io || is_perf_decrease_error) && has_continuous_error) ||
      has_long_pending_io) {          // ← 注意这里是 ||
    bool_ret = true;                   // 判定 clog 盘 hang
    last_detect_failure_time_ = now;
  }
}
```

**三点决定性推论：**

1. **`has_long_pending_io` 是一个独立的 `||` 分支**。它只依赖 `tolerance_time`，**完全不受 `sensitivity`（即 `trigger_percentage`）影响**。无论该参数取 0 还是 50，这条路径始终生效。

2. **`sensitivity = 0` 时，另外两条路径恒为 false**。因为 `bw_error_ratio = MIN(0.5, 0.01 × 0) = 0`，判定条件 `learn_avg_bw_[i] * 0 > this_avg_bw` 对任何非负吞吐都不成立。这与官方文档"默认值 0 意味着只由 IO RT 判定"的描述一致。

3. **因此把 `trigger_percentage` 调大 = 在保留原有路径的基础上再增加两条判定路径 = 检测变得更敏感，而非更宽松。**

**结论（本文的核心修正）：**

> **唯一能抬高日志盘判定门槛的参数是 `log_storage_warning_tolerance_time`（默认 5s，可调至 300s）。**
> **`log_storage_warning_trigger_percentage` 应保持默认值 `0`。**

**其余相关常量**（`ob_failure_detector.h`）[源码]：

| 常量 | 值 | 含义 |
|---|---|---|
| `PALF_DISK_DETECT_INTERVAL_US` | **1s** | 日志盘检测采样周期 |
| `MIN_RECOVERY_INTERVAL` | **30s** | 故障态最短恢复观察窗口 |
| `PALF_DISK_FAILURE_TIME_UPPER_BOUND` | **30min** | 故障态强制超时解除 |
| failure detect 定时器周期 | **100ms** | `mtl_start()` 中 `schedule_task_repeat(..., 100_ms, ...)` |
| recovery detect 定时器周期 | **1s** | 同上 |

**结论**：默认配置下，日志盘 I/O worker 只要**连续 5s 没有推进**，即被判定为故障并进入切主流程。对任何网络化块存储，这都是一个极易被触发的条件。

> OceanBase 官方仓库自带磁盘 hang 的集成测试用例 `mittest/logservice/test_ob_simple_log_disk_hang.cpp`，其中显式对该参数取 `0` 与 `5` 做对照验证 [源码]，可直接作为本次测试方法论的参考基准。

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

### 5.2 "完全吸收"的准确含义与边界

调参能做到的和不能做到的，必须说清楚。**下表是源码推论 [待验证]，用于指导实测，不是实测结果：**

| 现象 | 调参前（默认） | 调参后（tolerance=60s）· 源码推论 |
|---|---|---|
| 抖动期间事务延迟升高 | 是 | **预期仍是（无法消除）** |
| 抖动期间部分事务超时报错 | 是 | **取决于业务超时设置，需实测** |
| **判定磁盘故障 → 切主** | **是** | **预期否（抖动 < 60s 时）** ← **本方案要验证的核心命题** |
| 切主导致的连接中断与事务回滚 | 是 | **预期否** |
| 切主后 RTO 与主从切换抖动 | 是 | **预期否** |

**准确表述：调参不能消除抖动本身；源码分析表明它能把"抖动 → 判定坏盘 → 切主 → 集群级故障"降级为"抖动 → 短暂卡顿 → 自行恢复"，此命题待 §8.1 第 6s 行实测确认。**

这正是 Redis / RocketMQ / ES / TiDB 在同一平台上的表现形态 —— 它们没有秒级坏盘判定器，所以只表现为阻塞。

**仍需实测确认的量（不影响上述定性结论）：**

| 项 | 为什么需要实测 |
|---|---|
| 60s 是否为最优取值 | 需权衡业务侧超时与真实坏盘检出延迟 |
| 抖动期间业务侧的实际错误率 | 取决于 `ob_query_timeout` / 连接池配置，需压测确认 |
| OS 盘抖动的独立影响 | OS 盘不承载 clog/data，但承载 syslog 与 4G swap，路径不同（§7.2） |
| 三节点同时抖动时的行为 | 多数派同时受损，任何参数都无法兜底 |

### 5.3 已由源码与官方文档确定的结论

以下均为**代码/文档事实**，不依赖实测：

1. **判定门槛的位置**：日志盘为 `now - last_working_time > log_storage_warning_tolerance_time`（默认 5s）[源码]。现场 14/14 次慢 I/O 全部 > 5s [现场]，即**门槛确实被跨过**。
2. **⚠️ `log_storage_warning_trigger_percentage` 必须保持 0。** 调大只会新增判定路径使检测更敏感（§3.3.1）[源码]。
3. **调大 `tolerance_time` 不改变"报错"判定路径**。返回错误码的路径（`fs_error_times >= 10/100`）与时间阈值在同一 `if` 中以 `||` 并列，互不影响 [源码]。
4. **`data_storage_error_tolerance_time` 默认 300s**，10~30s 量级的停顿在时间上远未触及该阈值 [源码]。
5. **数据盘 WARNING 状态的清除条件**是 `period > read_failure_black_list_interval_`（默认 60s）[源码]，即状态位不会随停顿结束立即复位。
6. **所有相关 OB 参数均为 `DYNAMIC_EFFECTIVE`**，可在线调整，无需重启 [源码]。
7. **3F 三副本的多数派是 2/3** —— 若三节点同时受损，多数派同时失效，**任何参数都无法兜底**（架构事实）。

**以下属源码推论 [待验证]，需由 `TEST-PLAN.md` §8 实测确认：**

| 推论 | 验证场景 |
|---|---|
| 默认参数下 6s 停顿会实际发生切主 | §8.1 第 6s 行（默认参数列） |
| `tolerance_time=60s` 后同样的 6s 停顿不再切主 | §8.1 第 6s 行（调优后列） |
| 调参不引入稳态性能代价 | §8.2 稳态 TPS 行 |
| 调参不延后真实坏盘（报错型）的检出 | §8.2 `dm-flakey` 行 |

---

## 6. 测试方案

完整可执行方案见 [`TEST-PLAN.md`](TEST-PLAN.md)，脚本见 [`scripts/`](scripts/)。要点：

- **三个磁盘域分别独立测试**：A（OS 盘）/ B（数据盘 `/data/1`）/ C（日志盘 `/data/log1`），各自独立注入、独立取数、独立结论，最后才做组合。
- **注入手段**：`dmsetup suspend/resume` 精确停顿（与现场 submit/return 双侧阻塞特征一致），`dm-delay` 固定延迟，`dm-flakey` 停顿+错误对照。
- **时长档位**：2 / 4 / 5 / 6 / 8 / 10 / 15 / 20 / 30 / 60 / 120s，密集覆盖 3s、4s、5s、10s 四条阈值线两侧。
- **判定"完全吸收"的三条硬标准**：`DBA_OB_SERVER_EVENT_HISTORY` 无切主/停机事件；应用侧零报错、无连接中断；停顿结束后 TPS 立即回到基线。

---

## 7. 实测结果

> **待填**。执行 [`TEST-PLAN.md`](TEST-PLAN.md) 后回填，所有数据标注 [实测] 并附原始数据文件路径。

- 7.1 Azure v6 基线性能表现（与官方 66,667 IOPS / 1,984 MBps 上限的达成率）
- 7.2 A 域（OS 盘）抖动影响
- 7.3 B 域（数据盘）抖动影响
- 7.4 C 域（日志盘）抖动影响
- 7.5 调参前后切主发生率对比（验证 §5.1 的源码结论）
- 7.6 分层调优贡献度对比
- 7.7 leader 集中 vs 均衡的影响面对比
- 7.8 A 组（多盘条带）vs B 组（单盘 provisioned）性能与暴露面对比

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

> **⚠️ `tuned` 与 OB 官方要求存在冲突，需现场核实。** RHEL 9 在虚拟机上的默认 tuned profile 是 `virtual-guest` [官方]。

其上游定义为 [官方，`redhat-performance/tuned` 仓库]：

```ini
[main]
include=throughput-performance
[vm]
dirty_bytes = 30%          # 内核默认 dirty_ratio 为 20%
[sysctl]
vm.swappiness = 30         # OB 官方要求 0
```

两点风险：

1. **`vm.swappiness = 30` 会覆盖 `/etc/sysctl.conf` 中的 `0`**，与 OB 官方要求冲突。客户 OS 盘上有 4G swap，一旦触发换页，OS 盘抖动将直接放大为进程停顿。
2. **`dirty_bytes = 30%`**：在 128 GiB 内存的 D32s v6 上约合 **38 GB** 脏页阈值，远高于内核默认的 20%。回写风暴的峰值 I/O 量更大，会加长停顿窗口。

现场核实命令：

```bash
tuned-adm active
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

```sql
-- ===== 日志盘：唯一有效的门槛参数 =====
-- 抬高 has_long_pending_io 的判定门槛。5s -> 60s
ALTER SYSTEM SET log_storage_warning_tolerance_time    = '60s'; -- 取值 [1s,300s]

-- ⚠️ 保持默认 0，不要调大！
-- 源码中它与 tolerance_time 判定是 || 关系(§3.3.1)，
-- 调大只会新增两条判定路径,使检测更敏感而非更宽松。
-- ALTER SYSTEM SET log_storage_warning_trigger_percentage = 0;   -- 保持默认

-- ===== 数据盘：两个参数串联,总门槛 = io_timeout + warning_tolerance =====
ALTER SYSTEM SET data_storage_warning_tolerance_time   = '60s'; -- 取值 [1s,300s]
-- _data_storage_io_timeout 保持 10s 即可:
--   它只决定"何时开始探测",探测本身还有 warning_tolerance 的窗口。
--   若要更保守可一并调大,但收益低于上面一条。
-- ALTER SYSTEM SET _data_storage_io_timeout           = '10s';  -- 默认,取值 [1s,600s]

-- ===== ERROR 级保持默认,确保真实坏盘仍能被及时发现 =====
-- data_storage_error_tolerance_time = 300s  (默认,不建议调整)
```

**为什么这样调是安全的（源码级论证）：**

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
| 磁盘返回 I/O 错误（真实坏盘） | **是**，10 次错误即 WARNING，100 次即 ERROR，不受 tolerance_time 影响 |
| 磁盘完全无响应（挂死） | **是**，`data_storage_error_tolerance_time`（300s）兜底 |
| 短时高延迟（平台抖动） | **否 —— 这正是我们想要的效果** |

**仍需说明的权衡：**

- 纯超时型的慢盘（不报错、只是持续变慢）检出会从 5s 延后到 60s；
- 抖动窗口内业务侧仍会出现延迟升高，需配合 L5 的应用侧超时设置；
- 建议配合平台侧磁盘健康监控形成双重保障。

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
