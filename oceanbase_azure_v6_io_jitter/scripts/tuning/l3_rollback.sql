-- =====================================================================
-- l3_rollback.sql — 将 L3 层参数恢复为 OceanBase 出厂默认值
--
-- 默认值来源: src/share/parameter/ob_parameter_seed.ipp [源码]
--             commit fa399038f7edf3313575bd49d8c4a7cc64825c2e
--
-- 用于: 分层贡献度分析中的"单层剥离"对照, 或调优后需要回退时。
-- =====================================================================

-- =====================================================================
-- l3_rollback.sql — 将 L3 层参数恢复为 OceanBase 出厂默认值
--
-- 默认值来源: src/share/parameter/ob_parameter_seed.ipp [源码]
--             commit fa399038f7edf3313575bd49d8c4a7cc64825c2e
--
-- 用于: 分层贡献度分析中的"单层剥离"对照, 或调优后需要回退时。
-- =====================================================================

ALTER SYSTEM SET log_storage_warning_tolerance_time     = '5s';   -- 默认 5s
ALTER SYSTEM SET data_storage_warning_tolerance_time    = '5s';   -- 默认 5s
ALTER SYSTEM SET data_storage_error_tolerance_time      = '300s'; -- 默认 300s
ALTER SYSTEM SET _data_storage_io_timeout               = '10s';  -- 默认 10s

-- 保险起见复位; l3_tuning.sql 从未修改过该参数(源码分析表明调大会使检测更敏感),
-- 若环境中曾被他人调过, 此行可将其恢复默认。
ALTER SYSTEM SET log_storage_warning_trigger_percentage = 0;      -- 默认 0

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
