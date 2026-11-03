# 测试环境 READY 配置审批表

**状态：** 待审批，不可执行  
**适用范围：** 首个 5m 模型 A TRAIN smoke  
**禁止事项：** 本表中的建议值不是 READY 决策；不得复制集成测试夹具、以空值代替、由部署脚本自动批准，或在缺少审批时写入测试数据库。

## 1. 审批与落库规则

1. 每类配置使用独立 `semver`、规范化 JSON 和 SHA-256 `content_hash`；
2. 先创建 `DRAFT`，完成逐项复核后再转换为 `READY`；
3. `ready_by_user_id` 必须对应实际审批人，不能使用服务账户；
4. `READY` 后内容不可原地修改，调整数值必须创建新版本；
5. 首次 smoke 只批准 TRAIN 需要的 14 类配置，不创建 VALIDATION/TEST 配置；
6. 所有“待定”项确认前，不生成导入 SQL，不创建数据集或实验。

配置管理入口位于监控站点“训练工作区 → READY 配置”。部署迁移 `052_training_config_management` 并重建 monitor-api、monitor-ui 后：

- `TRAINING_RESEARCHER` 可以创建和编辑 `DRAFT`，每次写入均带原因并进入状态审计；
- `TRAINING_ADMIN` 可以把校验通过的 `DRAFT` 批准为 `READY`，或退役现有 `READY`；
- 普通站点 `ADMIN` 不会隐式获得上述训练权限；
- 页面显示 14 项齐备状态，但不会自动填入、复制或批准本表中的建议值。

## 2. A0 数据集配置

| 配置类型 | 必填字段/约束 | 设计已有口径 | 待审批数值 |
|---|---|---|---|
| `TICKER_POOL_RULES` | Ticker 池来源、历史时点计算、规则版本 | 使用历史时点池，不能读取未来榜单 | 池来源、排名口径、排除规则 |
| `DATA_QUALITY_RULES` | `required_dependencies[]`；每个依赖必须有 `minimum_coverage`、`minimum_effective_samples`、`minimum_effective_folds`、`warmup_required` | 必须覆盖 Trade/Mark K 线、EMA、OI、D-1 UTC 日榜/Ticker 池及全部启用因子依赖 | 依赖清单及每项覆盖率/样本/折数门槛 |
| `HOLDING_HORIZON_RULES` | `label_horizon_seconds > 0`、`max_holding_seconds > 0` | 标签设计使用 24h；最大持仓仍属于 Q-005 | `label_horizon_seconds`、`max_holding_seconds` |
| `ELIGIBLE_POOL_RULES` | `minimum_listing_age_seconds`、`minimum_notional_volume`、`required_contract_type`、`liquidity_lookback_seconds` | 上市时长初始建议 14 天；合约应限定永续 | 是否采用 1,209,600 秒；最低成交额；流动性窗口；合约类型字符串 |
| `REPRODUCIBILITY_TOLERANCE` | `absolute_tolerance >= 0`、`relative_tolerance >= 0` | 离散结果逐字节一致，浮点采用 Q-028 版本化容差 | 绝对/相对容差 |
| `RESOURCE_LIMITS` | 14 个显式正数，见下表 | Q-031 已给首版安全上限，部分容量值仍需压测 | 见下表 |
| `FEE_MODEL` | `maker_rate >= 0`、`taker_rate >= 0` | 必须版本化，不得隐含为 0 | maker/taker 费率 |
| `SLIPPAGE_MODEL` | `model_name`、`notional_coefficient`、`liquidity_coefficient`、`volatility_coefficient`，系数均非负 | 必须随名义头寸、成交额/深度代理和波动率变化 | 模型名和三个系数 |
| `VISIBILITY_CUTOFF_POLICY` | `policy_name`、`required_lead_seconds >= 0` | 候选月按准备就绪时点滚动；研究越权则登记暴露 | policy 名称及提前封存秒数；TRAIN smoke 使用的历史 cutoff |

### 2.1 `RESOURCE_LIMITS` 首版审批

| 字段 | 设计建议 | 审批值 |
|---|---:|---:|
| `max_heavy_experiments` | 1 | 待确认 |
| `db_workers_per_experiment` | 2 | 待确认 |
| `pool_connections` | 6 | 待确认 |
| `statement_timeout_seconds` | 900 | 待确认 |
| `lock_timeout_seconds` | 2 | 待确认 |
| `idle_in_transaction_session_timeout_seconds` | 60 | 待确认 |
| `work_mem_bytes` | 67,108,864 | 待确认 |
| `cpu_limit` | 4 | 待确认 |
| `memory_bytes` | 8,589,934,592 | 待确认 |
| `temp_disk_min_free_bytes` | 未给数值 | 待确认 |
| `max_candidate_count` | 未给数值 | 待确认 |
| `max_signal_count` | 未给数值 | 待确认 |
| `max_decision_row_count` | 未给数值 | 待确认 |
| `max_storage_bytes` | 未给数值 | 待确认 |

## 3. 模型 A 配置

| 配置类型 | 必填字段/约束 | 已固定结构 | 待审批数值 |
|---|---|---|---|
| `FACTOR_REGISTRY` | `adapter_version`、非空且唯一的 `factors[]` | 必须包装现有 V2 计算，不得读取未来数据 | adapter 版本、首批因子清单及各因子预热需求 |
| `SEARCH_SPACE` | `interval_seconds` 为 300 或 900；非空 `strategy_parameters`；Optimizer 同时需要非空 `parameters` 规则 | 第一阶段固定 300 秒；根数参数记录分钟等价值 | 固定扫描参数、Optuna 参数名/上下界/整数性/分类选择、trial 种子 |
| `RANDOM_BASELINE` | 正整数 `sample_count`、`minimum_frame_size`、`maximum_frame_candidates`；非负整数 `exclusion_window_seconds`；精确匹配字段和分层结构 | 匹配字段固定为 `btc_regime`、`instrument_id`、`liquidity_bucket`、`pool_identity`、`time_bucket`、`volatility_bucket` | 抽样数、最小抽样框、最大候选数、排除窗口、三个滚动窗口和分层边界 |
| `OPPORTUNITY_DEFINITION` | `minimum_mfe_percent > 0`、`maximum_mae_percent >= 0`、显式 `minimum_return_percent` | 时间安全机会总体，不使用 Oracle Top 20 | MFE、MAE、Return 三个阈值 |
| `SCORING_MODEL_A` | `calculation_version=DISCOVERY_V1`、7 个非负权重、两个正数 scale、四个正整数最小样本门槛 | 权重键和计算版本已固定 | 权重、scale、最低信号/机会/有效日/自然周数量 |

### 3.1 `RANDOM_BASELINE` 固定结构

`matching_fields` 必须精确包含以下六项，不能增删或重复：

```json
[
  "btc_regime",
  "instrument_id",
  "liquidity_bucket",
  "pool_identity",
  "time_bucket",
  "volatility_bucket"
]
```

`stratification` 的计算口径固定为：

| 字段 | 固定值/待定值 |
|---|---|
| `benchmark_symbol` | 建议 `BTCUSDT`，待确认 |
| `volatility_measure` | `CLOSE_RETURN_STDDEV_PERCENT` |
| `volatility_window_bars` | 待确认 |
| `volatility_boundaries_percent` | 严格递增数组，待确认 |
| `liquidity_measure` | `MEAN_QUOTE_VOLUME` |
| `liquidity_window_bars` | 待确认 |
| `liquidity_boundaries_quote_volume` | 严格递增数组，待确认 |
| `btc_regime_measure` | `CLOSE_RETURN_PERCENT` |
| `btc_regime_window_bars` | 待确认 |
| `btc_return_boundaries_percent` | 严格递增数组，待确认 |

### 3.2 `SCORING_MODEL_A` 固定权重键

以下七个键必须全部存在，权重均为非负数；具体数值尚未批准：

- `opportunity_recall`
- `entry_timing`
- `excess_mfe_quality`
- `cross_period_stability`
- `false_signal_penalty`
- `low_sample_penalty`
- `concentration_penalty`

另外必须批准：

- `entry_timing_scale_percent`
- `excess_mfe_scale_percent`
- `minimum_signal_count`
- `minimum_opportunity_count`
- `minimum_effective_day_count`
- `minimum_week_count`

## 4. 当前决策门

| 决策组 | 关联问题 | 未确认时的结果 |
|---|---|---|
| 标签/持仓/边界 | Q-005、Q-024 | 无法 READY 数据集，不能推导 embargo 和有效入场截止 |
| 合格池/质量 | Q-015、Q-032 | 无法生成可信 Ticker 池和因子覆盖报告 |
| 确定性 | Q-028 | 无法声明重复运行一致 |
| 资源 | Q-031 | 只能空载运行 runtime，不能准入真实任务 |
| 机会与随机基线 | Q-033 | 无法计算 OpportunityRecall 和超额 MFE |
| 费用与滑点 | Q-034 | 无法声明净收益或 1000 USDT 可成交 |
| 可见截止 | Q-035 | 无法创建符合治理要求的数据集版本 |
| 模型 A 评分 | Q-006 的模型 A 子项 | 无法生成权威 L0 或向 Optimizer TELL 成功目标 |

## 5. 批准后的执行顺序

1. 将批准值生成规范化 JSON，并在本地验证所有数据库契约；
2. 生成仅含 `DRAFT` 插入的审阅包和内容哈希清单；
3. 由实际审批人确认后转换为 `READY`；
4. 重新查询 14 类 READY 配置齐备性；
5. 创建单个 5m TRAIN 数据集构建任务；
6. 数据集 READY 后创建单实验、单 trial 的模型 A smoke；
7. 保存 `ASK → ITERATION → SCAN → EVALUATION → L0 → TELL` 全链证据。
