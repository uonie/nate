# OceanBase on Azure v6 存储 I/O 抖动韧性分析与最佳实践

> **文档状态**：分析与方案部分已完成（源码级论证）；实测数据章节为待填模板。
> **适用版本**：OceanBase 4.3.5.5 / OBProxy 4.3.1.6 / Azure Standard D32s v6 + Premium SSD v2
> **最后更新**：2026-08-30

---

## 摘要

OceanBase 在云上块存储环境中对**瞬时 I/O 高延迟事件**的敏感度显著高于其他常见中间件。本文通过**源码级**分析定位到三条独立的故障判定链路，并给出可证伪的测试方案与最佳实践配置。

**核心结论（分析阶段）**

1. **根因是超时层级倒挂**。Azure 官方要求 OS 侧 NVMe I/O 超时设为 **240s**，以便"Azure host 级超时与恢复机制优先处理磁盘故障或中断" [官方]；而 OceanBase 默认在 **5s** 即判定磁盘故障 [源码]。两者相差近两个数量级。

2. **最激进的一环是 `log_storage_warning_trigger_percentage = 0`**。该默认值的语义是：**只要任意单个 I/O 的响应时间超过 5s，日志盘即被判定为故障** —— 不是持续性能劣化，而是单次 I/O 事件 [源码]。

3. **这解释了"为何只有 OB 敏感"**。Redis / RocketMQ / ES / TiDB 不存在"秒级判定坏盘并主动发起选主"的探测器；它们在 I/O 停顿时仅表现为阻塞，停顿结束后自然恢复。

4. **存在一个尚未定论的关键分歧点**：切主可能由两条路径触发 —— 可调参的 failure detector（5s）或**硬编码不可调的 PALF 选举租约（4s）**[源码]。**二者的区分决定了"能否通过调参完全吸收"的最终答案**，必须由实测判定（见 §5.1）。

5. **客户现网存在四个影响放大因素**：LVM 多盘条带化、leader 高度集中于同一节点、自动均衡被关闭、clog 卷水位逼近回收阈值。

> **证据边界**：客户提供的日志是按 `-4389` 过滤后的摘录，**其中不含切主事件的直接记录**。
> 本文的因果链由**源码路径**与**时间相关性**建立，属高可信推断；
> 要升级为现场直接证据，需补充 `DBA_OB_SERVER_EVENT_HISTORY` 与完整 observer/election 日志（见 §3.5 证据边界声明）。

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
| OB 版本 | 4.3.5.5 |
| OBProxy | 4.3.1.6 |

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
| 2 | 旧镜像 `nvme_core.io_timeout` 默认 | 30s | 是 | [官方] |
| 3 | OB `_data_storage_io_timeout` | **10s** | 是 [1s,600s] | [源码] |
| 4 | OB `data_storage_warning_tolerance_time` | **5s** | 是 [1s,300s] | [源码] |
| 5 | OB `log_storage_warning_tolerance_time` | **5s** | 是 [1s,300s] | [源码] |
| 6 | OB `data_storage_error_tolerance_time` | 300s | 是 [10s,7200s] | [源码] |
| 7 | **PALF 选举租约** | **4s** | **否（硬编码）** | [源码] |

**Microsoft Learn 官方原文** [官方]：

> "For virtual machines using NVMe-attached storage, the default OS-level NVMe IO timeout for both Linux and Windows is now **240 seconds**. This change ensures that **Azure's host-level timeout and recovery mechanisms take precedence in handling disk failures or interruptions.** On Linux, this timeout corresponds to the kernel parameter `nvme_core.io_timeout` set to 240 seconds. ... Some older operating system images have the default timeout values set to 30 seconds. **This setting can cause the OS to timeout IOs before Azure can intervene.**"
>
> — <https://learn.microsoft.com/azure/virtual-machines/enable-nvme-interface>

**这是本文最重要的官方依据**：平台的设计前提是"OS 层应当等待足够长的时间，让平台侧的恢复机制先行处理"。而 OceanBase 默认在 5s 即做出终局判定。

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

判定链：

```
单个 I/O 超过 10s (_data_storage_io_timeout)
        │  记为 I/O 失败
        ▼
持续失败超过 5s (data_storage_warning_tolerance_time)
        │
        ▼
数据盘状态 = WARNING  ──►  触发切主等事件
        │
        │  持续失败超过 300s (data_storage_error_tolerance_time)
        ▼
数据盘状态 = ERROR    ──►  触发停机等事件
```

OceanBase 官方文档对两个状态的描述 [官方]：

- `data_storage_warning_tolerance_time`：*"探测线程会将该数据盘状态设置为 `WARNING`，该状态会**触发切主**等事件以正常服务业务请求。"*
- `data_storage_error_tolerance_time`：*"探测线程会将该数据盘状态设置为 `ERROR`，该状态会**触发停机**等事件以避免向该节点发送的请求失败。"*

> **对于 10~30s 量级的瞬时停顿**：会跨过 WARNING（5s），但**不会**达到 ERROR（300s）。即数据盘链路可能导致切主，但不会导致节点停机。

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

**这是全文最关键的一段代码。** 参数语义分两种模式：

| `log_storage_warning_trigger_percentage` | 判定模型 |
|---|---|
| **`0`（默认）** | **任意单个 I/O 的 RT 超过 `log_storage_warning_tolerance_time`（5s）→ 立即判定日志盘故障** |
| `> 0` | 当前吞吐 < 正常吞吐 × N% **且持续劣化达 `log_storage_warning_tolerance_time` 秒** → 才判定故障 |

消费方为 `src/logservice/leader_coordinator/ob_failure_detector.cpp` [源码]：

```cpp
const int64_t tolerance_time = GCONF.log_storage_warning_tolerance_time;
sensitivity = GCONF.log_storage_warning_trigger_percentage;
```

该文件位于 **`leader_coordinator`（主选举协调器）** 目录下，即这一判定**直接进入切主决策路径**。

**结论**：默认配置下，日志盘只需经历**一次**超过 5s 的 I/O，即被判定为故障并进入切主流程。对于任何共享式 / 网络化块存储，这都是一个极易被触发的条件。

> OceanBase 官方仓库自带磁盘 hang 的集成测试用例 `mittest/logservice/test_ob_simple_log_disk_hang.cpp`，其中显式对该参数取 `0` 与 `5` 做对照验证 [源码]，可直接作为本次测试方法论的参考基准。

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

在补齐上述材料前，本文对现场事件的表述一律限定为"观测到 6~11s 的存储 I/O 停顿"，
不直接断言"该停顿导致了那一次 failover"。

**停顿位置的判定**：日志中 `submit_used` 与 `return_used` **两侧均出现 10s+ 的耗时**：

- `submit_used: 10145753`（提交阶段阻塞 10.1s）
- `return_used: 10144342` / `10221478` / `10442392`（等待完成阶段阻塞 10.2~10.4s）

而 `enqueue_used` / `dequeue_used` 均为个位数微秒。这说明**阻塞发生在设备层，而非 OceanBase 内部队列排队**。

**与超时层级的对照**：

| 阈值 | 值 | 现场停顿（6.1~11.3s）是否跨过 |
|---|---|---|
| PALF 有效容忍窗口（租约 4s − 水位线 1s） | ~3s | ✅ 已跨过 |
| PALF 选举租约 | 4s | ✅ 已跨过 |
| `log/data_storage_warning_tolerance_time` | 5s | ✅ 已跨过 |
| `_data_storage_io_timeout` | 10s | ✅ 部分跨过 |
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

### 4.2 leader 高度集中 [现场]

5 个日志流中 4 个的主副本集中在节点 46。一次单节点 I/O 停顿即引发**4 个日志流批量切主**，业务影响面被最大化。这与现场日志中 T1 / T1001 / T1002 三个租户同时报错的现象完全吻合。

**加剧因素**：客户配置中设置了 `enable_rebalance = FALSE` 与 `enable_transfer = FALSE` [现场]，即关闭了自动均衡，leader 集中的状态不会被 OceanBase 自动纠正，切主后也不会自动回迁均衡。

### 4.3 clog 卷水位偏高 [现场]

日志卷已用 **78%**（776G / 1000G），逼近 `log_disk_utilization_threshold` 默认值 **80** [源码]。越过该阈值后 PALF 开始回收复用日志段，会额外增加日志盘 I/O 压力，提高在抖动窗口内命中慢 I/O 的概率。

---

## 5. 关键结论：能否通过调参完全吸收

### 5.1 核心可证伪假设（必须由实测判定）

切主存在**两条独立触发路径**，二者的默认阈值极为接近（4s vs 5s），但**可调性截然相反**：

| 路径 | 阈值 | 可调性 |
|---|---|---|
| **B. failure detector**（`log_storage_warning_*`） | 5s | **可调至 300s，且可切换判定模型** |
| **C. PALF 选举租约** | 有效 ≈3s / 租约 4s | **硬编码，不可调** |

**关键问题**：PALF 的租约续约依赖副本间的 RPC 消息交换，而非磁盘 I/O。因此存在两种可能：

- **假设 H1**：续约线程独立于磁盘 I/O。磁盘 hang 时网络仍正常，follower 正常回复续约消息 → 租约不会过期 → 切主**仅**由 failure detector 触发 → **调参可完全吸收**。
- **假设 H2**：续约路径在某处依赖磁盘 I/O（如元数据读写或日志落盘确认）→ 磁盘 hang 会导致租约过期 → **4s 是无法通过调参突破的硬上限**。

**实验设计（可证伪）**：将 `log_storage_warning_tolerance_time` 调至 60s、`log_storage_warning_trigger_percentage` 调至 >0，然后以 **2s / 4s / 5s / 6s / 8s / 10s** 密集档位注入日志盘停顿：

| 观测到的现象 | 结论 |
|---|---|
| 切主消失，直到停顿远超 60s 才出现 | **H1 成立** → 调参可完全吸收 |
| 切主仍稳定发生在 ~3-4s，与参数设置无关 | **H2 成立** → 4s 为硬上限，需架构兜底 |

> **在实测完成前，本文不对"能否完全吸收"给出结论。** 这正是本次测试的核心价值。

### 5.2 已可确定的结论

无论 H1 / H2 哪个成立，以下结论已由源码与官方文档确定：

1. **默认参数一定会在 5s 处误判**。`log_storage_warning_trigger_percentage = 0` 的"单次 I/O 超时即判故障"模型，对云上块存储而言过于激进 [源码]。
2. **调整判定模型优于单纯调大超时**。将 `log_storage_warning_trigger_percentage` 设为 >0，把判定从"单次 I/O 事件"改为"吞吐持续劣化"，**在提高抖动容忍度的同时不牺牲对真实坏盘的检出能力** —— 真实坏盘表现为持续吞吐塌陷，而非单次毛刺。
3. **数据盘链路不会导致停机**。10~30s 量级停顿远未触及 `data_storage_error_tolerance_time`（300s）[源码]。
4. **3F 架构本身具备兜底能力**，但兜底不等于无损：切主有 RTO，在途事务会失败。**若三节点同时抖动，多数派同时失效，架构无法兜底** —— 这是必须靠参数与布局优化来预防的场景。
5. **所有相关 OB 参数均为 `DYNAMIC_EFFECTIVE`**，可在线调整，无需重启 [源码]。

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

- 7.1 Azure v6 基线性能表现
- 7.2 A 域（OS 盘）抖动影响
- 7.3 B 域（数据盘）抖动影响
- 7.4 C 域（日志盘）抖动影响
- 7.5 H1 / H2 假设判定结果
- 7.6 分层调优贡献度对比
- 7.7 leader 集中 vs 均衡的影响面对比

---

## 8. 最佳实践配置清单

> 标注 [待实测确认] 的项需经 §7 验证后方可作为最终建议。

### L1 — OS / 内核

| 项 | 建议值 | 依据 |
|---|---|---|
| `nvme_core.io_timeout` | **240** | [官方] MS Learn 明确要求 |
| swap | 关闭（或移出 OS 盘） | 避免 OS 盘停顿时阻塞内存回收 |
| `transparent_hugepage` | `never` | 客户已配置 ✔ |
| `numa` | `off` | 客户已配置 ✔ |
| 挂载参数 | `noatime,nodiratime` | 客户已配置 ✔ |

设置方式（RHEL / CentOS 系）：

```bash
# /etc/default/grub 的 GRUB_CMDLINE_LINUX 追加：nvme_core.io_timeout=240
grub2-mkconfig -o /etc/grub2-efi.cfg   # EFI 启动
# 或 grub2-mkconfig -o /etc/grub2.cfg  # BIOS 启动
reboot

# 验证
cat /proc/cmdline
cat /sys/module/nvme_core/parameters/io_timeout   # 期望 240
```

### L2 — 存储布局

| 项 | 建议 | 依据 |
|---|---|---|
| 条带盘数 | **显著降低**，优先用单块大容量 PSSDv2 并配置 provisioned IOPS / 吞吐 | §4.1，条带化放大暴露面 4~6 倍 |
| 三域隔离 | OS / data / clog 使用独立卷 | 客户已隔离 ✔ |
| clog 水位 | 降至 **60% 以下** | §4.3，避免逼近 80% 回收阈值 |

### L3 — OceanBase 判定模型（关键层）

```sql
-- 核心：把日志盘判定模型从"单次 IO 超时"改为"吞吐持续劣化"
ALTER SYSTEM SET log_storage_warning_trigger_percentage = 20;   -- [待实测确认] 取值 [0,50]
ALTER SYSTEM SET log_storage_warning_tolerance_time    = '60s'; -- [待实测确认] 取值 [1s,300s]

-- 数据盘侧同步放宽
ALTER SYSTEM SET data_storage_warning_tolerance_time   = '60s'; -- [待实测确认] 取值 [1s,300s]
ALTER SYSTEM SET _data_storage_io_timeout              = '60s'; -- [待实测确认] 取值 [1s,600s]

-- ERROR 级保持默认，确保真实坏盘仍能被及时发现
-- data_storage_error_tolerance_time = 300s  (默认，不建议调整)
```

**权衡说明（必须向使用方说明）**：放宽 `*_tolerance_time` 会延缓对真实坏盘的发现。因此：

- **优先调整 `log_storage_warning_trigger_percentage`**（改判定模型），而非单纯调大超时 —— 前者不牺牲真实故障检出能力；
- 保持 `data_storage_error_tolerance_time` 默认值作为兜底；
- 配合平台侧磁盘健康监控，形成双重保障。

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
| 应用侧 | 幂等重试 + 合理的连接池超时 | 切主 RTO 期间的在途事务必然失败 |

---

## 9. 下一步行动

| # | 事项 | 目的 | 阻塞了什么 |
|---|---|---|---|
| 1 | 向客户索取 `DBA_OB_SERVER_EVENT_HISTORY`（2026-07-20 15:00~15:10）| 确认切主事件与其 reason | §3.5 因果链从推断升级为直接证据 |
| 2 | 向客户索取三节点完整 `observer.log` + `election.log` | 判断触发路径是 PALF 租约还是 failure detector | H1/H2 的现场侧佐证 |
| 3 | 搭建 3 × D32s v6 测试环境 | 执行 `TEST-PLAN.md` | §7 全部实测章节 |
| 4 | 执行 §5.1 H1/H2 判定实验 | **回答"能否完全吸收"** | §5、§8 最终建议定稿 |
| 5 | 在 4.3.5.5 上用 `GV$OB_PARAMETERS` 复核全部参数默认值 | 确认本文源码引用与实际版本一致 | §3 各表格的版本适用性 |
| 6 | 核实 Azure v6 远程盘的 host caching 支持情况（需 MS Learn 原文） | 补充 L2 布局建议 | 该建议暂未写入本文 |

> 在第 4 项完成前，§8 中标注 [待实测确认] 的参数取值**不可作为对客户的正式建议**。

---

## 10. 附录：完整引用清单

### 官方文档

| # | 内容 | URL |
|---|---|---|
| A1 | Azure NVMe 支持的 OS 镜像与 `nvme_core.io_timeout=240` 要求 | <https://learn.microsoft.com/azure/virtual-machines/enable-nvme-interface> |
| A2 | Azure NVMe 通用 FAQ | <https://learn.microsoft.com/azure/virtual-machines/enable-nvme-faqs> |
| A3 | OceanBase `data_storage_error_tolerance_time` | <https://www.oceanbase.com/docs/common-oceanbase-database-cn-10000000001702092> |
| A4 | OceanBase `data_storage_warning_tolerance_time` | <https://www.oceanbase.com/docs/common-oceanbase-database-cn-10000000001702093> |

### 源码

仓库 `oceanbase/oceanbase`，commit `fa399038f7edf3313575bd49d8c4a7cc64825c2e`

| # | 文件 | 内容 |
|---|---|---|
| S1 | `src/share/parameter/ob_parameter_seed.ipp` | `_data_storage_io_timeout`、`data_storage_warning_tolerance_time`、`data_storage_error_tolerance_time`、`log_storage_warning_tolerance_time`、`log_storage_warning_trigger_percentage` 的定义、默认值与取值范围 |
| S2 | `src/logservice/leader_coordinator/ob_failure_detector.cpp` | 日志盘故障判定的消费方，位于主选举协调器路径 |
| S3 | `src/logservice/palf/election/utils/election_common_define.h` | PALF 选举租约、续约周期、触发选举水位线的计算式 |
| S4 | `src/logservice/palf/election/algorithm/election_impl.cpp` | `RoleChangeReason::LeaseExpiredToRevoke` 租约到期卸任 |
| S5 | `mittest/logservice/test_ob_simple_log_disk_hang.cpp` | 官方磁盘 hang 集成测试用例，可作方法论参考 |

### 社区（非官方，仅作旁证）

| # | 内容 | URL |
|---|---|---|
| C1 | 日志盘 hang 5 秒导致 OB 切主的用户反馈 | <https://ask.oceanbase.com/t/topic/35604965/3> |

### 现场材料

| # | 文件 | 内容 |
|---|---|---|
| F1 | `observer46.txt` | 2026-07-20 failover 时段 observer 日志摘录、磁盘布局、挂载信息 |
| F2 | `OceanBase安装文档-泰国.docx` | 客户 OB 部署流程与参数配置 |
