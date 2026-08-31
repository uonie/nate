-- =====================================================================
-- l3_tuning.sql — L3 层: OceanBase 磁盘故障判定模型调优
--
-- 这是直接消除误判切主的关键层。
-- 所有参数的 EditLevel 均为 DYNAMIC_EFFECTIVE，无需重启 OBServer。 [源码]
--
-- 执行前请先用 collect/ob_events.sh -m params 导出基线。
-- 标注 [待实测确认] 的取值必须经 TEST-PLAN.md §5.1/§6 验证后方可作为最终建议。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) 执行前基线快照
-- ---------------------------------------------------------------------
SELECT svr_ip, name, value, edit_level
FROM   oceanbase.GV$OB_PARAMETERS
WHERE  name IN (
         '_data_storage_io_timeout',
         'data_storage_warning_tolerance_time',
         'data_storage_error_tolerance_time',
         'log_storage_warning_tolerance_time',
         'log_storage_warning_trigger_percentage'
       )
ORDER BY name, svr_ip;


-- ---------------------------------------------------------------------
-- 1) 【核心】日志盘: 抬高 has_long_pending_io 的判定门槛
--
--    源码 ob_failure_detector.cpp -> PalfDiskHangDetector::is_clog_disk_hang():
--
--      const bool has_long_pending_io = (OB_INVALID_TIMESTAMP != last_working_time
--          && now - last_working_time > tolerance_time);
--      ...
--      if (((has_small_pending_io || is_perf_decrease_error) && has_continuous_error)
--          || has_long_pending_io) {        // <-- 注意是 ||
--        bool_ret = true;                   // 判定 clog 盘 hang -> FATAL -> 切主
--      }
--
--    结论: has_long_pending_io 是独立的 || 分支, 只依赖 tolerance_time,
--          完全不受 log_storage_warning_trigger_percentage 影响。
--
--    因此【唯一能抬高日志盘门槛的参数就是 tolerance_time】。
--    取值范围 [1s,300s], 默认 5s。
-- ---------------------------------------------------------------------
ALTER SYSTEM SET log_storage_warning_tolerance_time = '60s';

-- ---------------------------------------------------------------------
--    !! 警告: log_storage_warning_trigger_percentage 必须保持默认值 0 !!
--
--    参数文档的措辞 ("If the value is greater than 0, ... only if ...")
--    极易被误读为"调大它就能换成更宽松的判定模型"。源码显示并非如此:
--
--      sensitivity     = GCONF.log_storage_warning_trigger_percentage;
--      bw_error_ratio  = MIN(0.5, 0.01 * sensitivity);
--
--      sensitivity = 0 -> bw_error_ratio = 0
--                      -> learn_avg_bw_[i] * 0 > this_avg_bw 恒为 false
--                      -> is_perf_decrease_error / has_small_pending_io 恒为 false
--                      -> 只剩 has_long_pending_io 一条判定路径
--
--      sensitivity > 0 -> has_long_pending_io 仍然生效 (|| 关系),
--                         另外【新增】两条判定路径
--                      -> 检测变得更敏感, 而不是更宽松!
--
--    所以: 不要动这个参数。
-- ---------------------------------------------------------------------
-- ALTER SYSTEM SET log_storage_warning_trigger_percentage = 0;   -- 保持默认


-- ---------------------------------------------------------------------
-- 2) 数据盘侧同步放宽
--
--    判定链 (源码 src/share/io/ob_io_struct.cpp 逐行核实):
--      单个【读】IO 超过 _data_storage_io_timeout (10s)
--        -> record_io_timeout() 推入 RetryTask  [仅 read; write 直接 NOT_SUPPORTED]
--        -> 探测线程循环重试 detect_read()
--        -> current_ts >= diagnose_begin_ts + data_storage_warning_tolerance_time (5s)
--        -> set_device_warning() -> DEVICE_HEALTH_WARNING
--        -> detect_data_disk_io_failure_() 见到 != NORMAL -> FATAL -> 切主
--      总门槛约 10s + 5s = 15s。
--
--    注: WARNING 状态的清除需要 period > read_failure_black_list_interval_ (默认 60s),
--        即一次停顿会让该节点在优先级比较中"带伤"至少 60s。
-- ---------------------------------------------------------------------
ALTER SYSTEM SET data_storage_warning_tolerance_time = '60s';   -- 范围 [1s,300s], 默认 5s

-- _data_storage_io_timeout 保持默认 10s 即可:
--   它只决定"何时开始探测", 探测本身还有 warning_tolerance 的窗口。
--   若要更保守可一并调大, 但收益低于上面一条。
-- ALTER SYSTEM SET _data_storage_io_timeout          = '10s';   -- 默认, 范围 [1s,600s]

-- ERROR 级【保持默认 300s 不动】, 作为真实坏盘的兜底检出。
-- 10~30s 量级的瞬时停顿远未触及该阈值, 无需调整。
-- ALTER SYSTEM SET data_storage_error_tolerance_time = '300s';  -- 不建议改动

-- ---------------------------------------------------------------------
--    为什么放宽 tolerance_time 是安全的 (源码论证):
--
--      if (current_ts >= error_ts || (sys_io_errno != 0 && fs_error_times >= 100)) {
--        set_device_error();
--      } else if (current_ts >= warn_ts || (sys_io_errno != 0 && fs_error_times >= 10)) {
--        set_device_warning();
--      }
--
--    "超时"与"报错"是 || 关系。真实坏盘几乎总是伴随 sys_io_errno != 0 (EIO 等),
--    走右半支, 与 tolerance_time 无关 ->【放宽超时不会导致真实坏盘漏检】。
--    (MAX_DETECT_READ_WARN_TIMES=10, MAX_DETECT_READ_ERROR_TIMES=100, ob_io_define.h)
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 3) L4 缓冲与节流(可选, 与 L3 分开单独验证贡献度)
-- ---------------------------------------------------------------------
-- 更大的 memstore 缓冲有助于吸收停顿期的写入
-- ALTER SYSTEM SET freeze_trigger_percentage = 30;   -- 客户已配置

-- 异步 syslog, 避免日志写入阻塞数据库线程(默认即为 true, 确认不要关闭)
-- ALTER SYSTEM SET enable_async_syslog = true;

-- 限制 syslog I/O 突发
-- ALTER SYSTEM SET syslog_io_bandwidth_limit = '30MB';

-- 日志盘水位三阈值(OB_TENANT_PARAMETER, DYNAMIC_EFFECTIVE) [源码]
--   log_disk_throttling_percentage        默认 60  [40,100]  超过后触发写入限流
--   log_disk_utilization_threshold        默认 80  [10,100)  超过后回收复用日志文件
--   log_disk_utilization_limit_threshold  默认 95  [80,100]  超过后停止提交/接收日志
--   约束: limit_threshold > utilization_threshold  (palf_options.cpp)
--
-- 客户 clog 卷已用 78%, 已越过限流线(60)、逼近回收线(80)。
-- 【首选方案是扩容/降水位, 而非调高阈值】——
-- 调高阈值只是推迟限流, 并不减少日志盘 I/O 压力。
-- ALTER SYSTEM SET log_disk_throttling_percentage = 60;   -- 保持默认


-- ---------------------------------------------------------------------
-- 4) 生效确认
-- ---------------------------------------------------------------------
SELECT svr_ip, name, value, edit_level
FROM   oceanbase.GV$OB_PARAMETERS
WHERE  name IN (
         '_data_storage_io_timeout',
         'data_storage_warning_tolerance_time',
         'data_storage_error_tolerance_time',
         'log_storage_warning_tolerance_time',
         'log_storage_warning_trigger_percentage'
       )
ORDER BY name, svr_ip;

-- 预期结果:
--   log_storage_warning_tolerance_time      60s
--   data_storage_warning_tolerance_time     60s
--   log_storage_warning_trigger_percentage  0      (保持默认, 不要改)
--   _data_storage_io_timeout                10s    (保持默认)
--   data_storage_error_tolerance_time       300s   (未改动)


-- =====================================================================
-- 权衡说明(必须向使用方明确说明)
--
--   放宽 *_tolerance_time 只放宽了"超时"判定, 不影响"报错"判定:
--     a) 磁盘返回 IO 错误(真实坏盘): 仍然 10 次 -> WARNING, 100 次 -> ERROR,
--        与 tolerance_time 无关, 【不会漏检】;
--     b) 磁盘完全无响应: data_storage_error_tolerance_time (300s) 兜底;
--     c) 纯超时型慢盘(不报错只变慢): 检出会从 5s 延后到 60s —— 这是唯一的代价;
--     d) 建议配合平台侧磁盘健康监控, 形成双重保障。
--
--   !! 不要调大 log_storage_warning_trigger_percentage 来"换判定模型" !!
--   源码中它与 has_long_pending_io 是 || 关系(见本文件第 1 节),
--   调大只会新增判定路径, 使检测更敏感。
--
-- 关于 PALF 4s 硬编码租约
--
--   本方案的有效性【不依赖】PALF 租约可调:
--   源码已确认切主走的是
--     failure detector -> FailureLevel::FATAL
--       -> PriorityV1::compare_fatal_failures_ -> 优先级降级 -> 主动让位
--   这一路径, 而非"租约到期 -> 被动重新选举"。
--   选举续约是纯内存 + RPC 的状态机, 存储抖动期间网络正常, 租约不会过期。
--   详见 README.md §5.1。
-- =====================================================================
