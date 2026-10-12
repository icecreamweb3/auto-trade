# P5 时序数据容量优化

日期：2026-10-10

## 目标

在不降低采集粒度、不删除规范化历史行情的前提下，降低PostgreSQL长期容量增速，并保留最近3个月历史回补和最近24小时实时缺口修复所需的可写窗口。

## 已实施的第一阶段

- `raw_events`、`klines`、`ticker_minutes`、`funding_observations`、`open_interest_observations`未来新分块改为1天。
- 五张高频表启用TimescaleDB Hypercore/Columnstore。
- Columnstore排序包含主键和唯一索引字段，确保冷分块转换后仍可执行唯一性检查。
- 完整分块超过72小时后由后台策略自动转入Columnstore。
- 72小时冷却窗口长于最近24小时实时缺口检测窗口；3个月历史回补按24小时分段扫描与回补，不会反复全量扫描历史区间。
- 监控页面显示策略状态、已转换分块数和实际空间节省比例。
- 当前阶段没有配置任何retention policy，不会自动删除数据。

现有7天分块不会被重切；`set_chunk_time_interval`仅影响后续新分块。因此首次自动转换需要等待现有分块关闭并满足72小时条件。

## 部署

```bash
make db-migrate
make db-storage-verify
make monitor-up
```

可在可删除的容量压测表上转换一个分块，取得本机真实压缩率：

```bash
make db-columnstore-poc
```

验证结果中五张表应满足：

- `chunk_interval` 为 `1 day`；
- `columnstore_enabled` 为 `true`；
- 每张表存在一个已调度的 `policy_compression`；
- `columnstore_after` 为72小时对应值。

## 暂未启用的第二阶段

原始事件归档和删除必须按以下顺序实施：

1. 按UTC日期导出 `market.raw_events` 到Parquet + ZSTD；
2. 为归档生成行数、时间范围、对象大小和SHA-256清单；
3. 在隔离数据库完成抽样恢复和回放验证；
4. 归档连续稳定运行后，才允许为数据库配置7天或30天retention。

在归档闭环完成以前，不得为 `market.raw_events` 添加自动删除策略。
