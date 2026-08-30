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
-- 1) 【核心】日志盘判定模型: 单次 IO 超时  ->  吞吐持续劣化
--
--    源码 src/share/parameter/ob_parameter_seed.ipp 语义: [源码]
--      = 0 (默认): 只要任意单个 IO 的 RT 超过 log_storage_warning_tolerance_time,
--                  日志盘立即被判定为故障 -> 进入 leader_coordinator 切主路径。
--      > 0       : 仅当 当前吞吐 < 正常吞吐 * N/100
--                  且劣化持续 log_storage_warning_tolerance_time 秒, 才判定故障。
--
--    这一改动在提高抖动容忍度的同时【不牺牲对真实坏盘的检出能力】——
--    真实坏盘表现为持续吞吐塌陷, 而非单次毛刺。
--    取值范围 [0,50]。
-- ---------------------------------------------------------------------
ALTER SYSTEM SET log_storage_warning_trigger_percentage = 20;   -- [待实测确认]

-- 配合放宽判定窗口。取值范围 [1s,300s], 默认 5s。
ALTER SYSTEM SET log_storage_warning_tolerance_time = '60s';    -- [待实测确认]


-- ---------------------------------------------------------------------
-- 2) 数据盘侧同步放宽
--
--    判定链: 单个 IO 超过 _data_storage_io_timeout 记为失败
--            -> 持续失败超过 data_storage_warning_tolerance_time -> WARNING -> 触发切主
--            -> 持续失败超过 data_storage_error_tolerance_time   -> ERROR   -> 触发停机
-- ---------------------------------------------------------------------
ALTER SYSTEM SET data_storage_warning_tolerance_time = '60s';   -- [待实测确认] 范围 [1s,300s], 默认 5s
ALTER SYSTEM SET _data_storage_io_timeout            = '60s';   -- [待实测确认] 范围 [1s,600s], 默认 10s

-- ERROR 级【保持默认 300s 不动】, 作为真实坏盘的兜底检出。
-- 10~30s 量级的瞬时停顿远未触及该阈值, 无需调整。
-- ALTER SYSTEM SET data_storage_error_tolerance_time = '300s';  -- 不建议改动


-- ---------------------------------------------------------------------
-- 3) L4 缓冲与节流(可选, 与 L3 分开单独验证贡献度)
-- ---------------------------------------------------------------------
-- 更大的 memstore 缓冲有助于吸收停顿期的写入
-- ALTER SYSTEM SET freeze_trigger_percentage = 30;   -- 客户已配置

-- 异步 syslog, 避免日志写入阻塞数据库线程(默认即为 true, 确认不要关闭)
-- ALTER SYSTEM SET enable_async_syslog = true;

-- 限制 syslog I/O 突发
-- ALTER SYSTEM SET syslog_io_bandwidth_limit = '30MB';


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
--   log_storage_warning_trigger_percentage  20
--   log_storage_warning_tolerance_time      60s
--   data_storage_warning_tolerance_time     60s
--   _data_storage_io_timeout                60s
--   data_storage_error_tolerance_time       300s   (未改动)


-- =====================================================================
-- 权衡说明(必须向使用方明确说明)
--
--   放宽 *_tolerance_time 会延缓对【真实坏盘】的发现。因此:
--     a) 优先调整 log_storage_warning_trigger_percentage(改判定模型),
--        而非单纯调大超时 —— 前者不牺牲真实故障检出能力;
--     b) 保持 data_storage_error_tolerance_time 默认值作为兜底;
--     c) 配合平台侧磁盘健康监控, 形成双重保障。
--
-- 重要前提
--
--   若 TEST-PLAN.md §5.1 判定 H2 成立(切主由 PALF 选举租约触发),
--   则本文件的参数调整【无法完全消除】4s 以上停顿导致的切主 ——
--   PALF 租约 = 4 * MAX_TST = 4s 在当前版本中为硬编码, 不可配置。 [源码]
--   此时必须依靠 L1(降低 OS 侧过早超时) + L2(降低条带暴露面)
--   + L5(leader 打散、应用幂等重试) 组合缓解。
-- =====================================================================
