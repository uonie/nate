# 原始数据归档目录

测试执行产生的原始数据按场景归档到此目录，**不提交到仓库**（见 `.gitignore`）。

## 目录约定

```
data/
├── baseline_params.tsv              GV$OB_PARAMETERS 全量基线
├── <场景>_<域>_<时间戳>/            run_matrix.sh 自动创建
│   ├── manifest.tsv                 每次注入的精确起止时间戳(UTC)
│   ├── inject_*.log                 单次注入日志
│   └── run_*.out                    单次注入 stdout
├── <场景>_collect/                  start_collect.sh 采集
│   ├── env_snapshot.txt             环境快照
│   ├── iostat.txt / vmstat.txt
│   ├── dmesg.txt / nvme_error.txt
│   └── meta.txt
├── <场景>_leader_watch.tsv          leader 分布逐秒记录
├── <场景>_events.tsv                DBA_OB_SERVER_EVENT_HISTORY  ← 切主权威判据
└── <场景>_logscan.txt               observer.log 签名扫描结果
```

## 分析顺序

1. 用 `manifest.tsv` 的注入时间窗去切 `events.tsv`，确认该窗口内是否有切主/停机事件；
2. 对齐 `leader_watch.tsv`，确认切主发生的精确秒；
3. 用 `logscan.txt` 的 `[C]` / `[D]` 分组判断触发路径（PALF 租约 vs failure detector）；
4. 用 `iostat.txt` 的 await / aqu-sz 确认注入确实生效；
5. 用业务侧 TPS 曲线计算恢复时长。
