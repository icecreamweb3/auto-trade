# READY 配置参数参考

**适用范围：** 首个 5m 模型 A TRAIN smoke 及其后续配置版本维护  
**文档日期：** 2026-11-03  
**性质：** 字段与结构参考，不是数值审批记录

## 1. 使用规则

1. 本文示例用于说明 JSON 结构和字段语义，不代表数值已经批准为 `READY`；
2. 首次创建建议使用 `semver=0.1.0`、`schema_version=1`、父版本留空；
3. 配置先保存为 `DRAFT`，通过服务端和数据库校验后再由具有 `TRAINING_ADMIN` 权限的自然人批准；
4. `READY` 版本不可原地编辑。参数变化必须新建 `DRAFT`，并将原版本选为父版本；
5. 费用、滑点、流动性、数据质量、资源容量、机会阈值和评分权重必须根据测试环境实测结果批准，不能直接复制本文示例；
6. `VALIDATION` 和 `TEST` 结果不得用于反向调整 TRAIN 配置；
7. 所有百分比字段均以百分数值表达。例如 `3.0` 表示 3%，费率字段除外；
8. 所有时间窗口必须明确单位。本文中以 `_seconds` 结尾的字段单位为秒，以 `_bars` 结尾的字段单位为 K 线根数。

## 2. 推荐配置顺序

1. `HOLDING_HORIZON_RULES`
2. `RESOURCE_LIMITS`
3. `FEE_MODEL`、`SLIPPAGE_MODEL`
4. `TICKER_POOL_RULES`、`ELIGIBLE_POOL_RULES`
5. `DATA_QUALITY_RULES`
6. `REPRODUCIBILITY_TOLERANCE`
7. `VISIBILITY_CUTOFF_POLICY`
8. 模型 A 五项配置

---

## 3. 标签与持仓周期

### 3.1 `HOLDING_HORIZON_RULES`

控制标签观察窗口和策略允许的最大持仓时间。

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `label_horizon_seconds` | 正整数 | 从入场时点开始计算 MFE、MAE 和 Return 标签的未来窗口 |
| `max_holding_seconds` | 正整数 | 仿真退出规则允许持仓的最长时间 |

数据分区尾部、purge 和 embargo 必须至少覆盖两者的最大值。

24 小时标签和持仓示例：

```json
{
  "label_horizon_seconds": 86400,
  "max_holding_seconds": 86400
}
```

24 小时标签、48 小时最大持仓示例：

```json
{
  "label_horizon_seconds": 86400,
  "max_holding_seconds": 172800
}
```

第二个示例会使分区尾部、purge 和 embargo 至少按 48 小时计算。

---

## 4. 资源限制

### 4.1 `RESOURCE_LIMITS`

控制训练对数据库、CPU、内存、临时磁盘和持久化空间的最大占用。超过限制时应拒绝任务，不能自动扩大资源。

| 参数 | 含义 |
|---|---|
| `max_heavy_experiments` | 同时允许运行的重型实验数 |
| `db_workers_per_experiment` | 每个实验最多使用的数据库 worker 数 |
| `pool_connections` | 单实验允许使用的数据库连接上限 |
| `statement_timeout_seconds` | 单条 SQL 最大执行时间 |
| `lock_timeout_seconds` | 数据库锁等待上限 |
| `idle_in_transaction_session_timeout_seconds` | 事务空闲超时 |
| `work_mem_bytes` | PostgreSQL 单个排序或哈希操作的内存上限 |
| `cpu_limit` | 训练容器 CPU 上限 |
| `memory_bytes` | 训练容器内存上限 |
| `temp_disk_min_free_bytes` | 启动重型任务前要求的最小临时磁盘剩余空间 |
| `max_candidate_count` | 单实验最多候选参数数量 |
| `max_signal_count` | 单次候选扫描最多产生的信号数 |
| `max_decision_row_count` | 单次仿真最多允许的逐点决策行数 |
| `max_storage_bytes` | 单实验允许写入的总存储量 |

保守 smoke 结构示例：

```json
{
  "max_heavy_experiments": 1,
  "db_workers_per_experiment": 2,
  "pool_connections": 6,
  "statement_timeout_seconds": 900,
  "lock_timeout_seconds": 2,
  "idle_in_transaction_session_timeout_seconds": 60,
  "work_mem_bytes": 67108864,
  "cpu_limit": 4,
  "memory_bytes": 8589934592,
  "temp_disk_min_free_bytes": 5368709120,
  "max_candidate_count": 10,
  "max_signal_count": 100000,
  "max_decision_row_count": 1000000,
  "max_storage_bytes": 10737418240
}
```

换算：

- `67108864` = 64 MiB；
- `8589934592` = 8 GiB；
- `5368709120` = 5 GiB；
- `10737418240` = 10 GiB。

该示例仅适合单 trial smoke。扩大候选数之前必须重新做容量和数据库负载测试。

---

## 5. 费用与滑点

### 5.1 `FEE_MODEL`

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `maker_rate` | 非负数 | Maker 成交费率，小数形式 |
| `taker_rate` | 非负数 | Taker 成交费率，小数形式 |

结构示例：

```json
{
  "maker_rate": 0.0002,
  "taker_rate": 0.0005
}
```

`0.0005` 表示 0.05%。当前模型 B 重放使用 `taker_rate` 计算入场和退出费用；正式值应来自实际账户费率。

### 5.2 `SLIPPAGE_MODEL`

滑点必须同时反映固定成本、名义头寸、可成交额和波动率。

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `model_name` | 非空字符串 | 模型名称和版本标识 |
| `base_basis_points` | 非负数 | 固定基础滑点，单位 bp |
| `notional_coefficient` | 非负数 | 名义头寸规模影响系数 |
| `reference_notional` | 正数 | 名义头寸基准，通常为 USDT |
| `liquidity_coefficient` | 非负数 | 头寸相对可成交额的影响系数 |
| `volatility_coefficient` | 非负数 | 波动率影响系数 |
| `maximum_basis_points` | 非负数且不小于基础滑点 | 单边滑点硬上限，单位 bp |

运行时计算方式：

```text
滑点 bp =
  base_basis_points
  + notional_coefficient × 名义头寸 / reference_notional
  + liquidity_coefficient × 名义头寸 / 可成交额
  + volatility_coefficient × 波动率百分比
```

最终结果不超过 `maximum_basis_points`。

完整结构示例：

```json
{
  "model_name": "NOTIONAL_LIQUIDITY_VOLATILITY_V1",
  "base_basis_points": 1,
  "notional_coefficient": 1,
  "reference_notional": 1000,
  "liquidity_coefficient": 100,
  "volatility_coefficient": 0.5,
  "maximum_basis_points": 50
}
```

在名义头寸 1000 USDT、可成交额 1,000,000 USDT、波动率 2% 时，示例滑点约为 3.1 bp。

修改注意：运行时使用全部七个字段，不能只填写最早数据库约束中的四个字段。

---

## 6. Ticker 池与合格池

### 6.1 `TICKER_POOL_RULES`

定义每个历史时点允许研究的标的池。只能使用当时已经存在的信息，禁止用未来涨幅榜反推标的。

| 参数 | 含义 |
|---|---|
| `policy_name` | 规则名称和版本 |
| `source` | 历史排名或标的池来源 |
| `ranking_type` | 排名口径 |
| `as_of_lag_days` | 使用信号日前几天的排名 |
| `top_n` | 每日选取前多少名 |
| `excluded_symbols` | 明确排除的标的 |
| `required_contract_type` | 合约类型 |

结构示例：

```json
{
  "policy_name": "UTC_DAILY_2355_TOP_50_D_MINUS_1_V1",
  "source": "market.ranking_snapshots",
  "ranking_type": "UTC_DAILY_2355",
  "as_of_lag_days": 1,
  "top_n": 50,
  "excluded_symbols": [],
  "required_contract_type": "USDT_PERPETUAL"
}
```

含义：某日训练只能使用前一日 UTC 23:55 已冻结的 Top 50 排名。当前
`ranking_entries.rank_no`、排名消息契约及历史快照的硬上限均为 50；在完成这些组件的
版本化升级前，`top_n` 配成 100 会使数据集预检必然失败。

当前数据库主要把这份 JSON 用作版本化治理身份；实际池生成器必须实现完全一致的 as-of 语义。

### 6.2 `ELIGIBLE_POOL_RULES`

在 Ticker 池基础上进一步过滤上市时间、成交额和合约类型。

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `minimum_listing_age_seconds` | 非负数 | 上市后至少经过的时间 |
| `minimum_notional_volume` | 正数 | 流动性窗口内最低名义成交额 |
| `inferred_trading_minimum_notional_volume` | 正数 | 历史状态缺失时，以同一历史窗口内有效 TRADE Kline 的 quote volume 推定 `TRADING` 的严格下限；不覆盖已有的非交易状态 |
| `required_contract_type` | 非空字符串 | 必须匹配的合约类型 |
| `liquidity_lookback_seconds` | 正数 | 成交额统计回看窗口 |
| `notional_currency` | 说明字段 | 名义成交额计价货币 |
| `notional_measure` | 说明字段 | 成交额计算口径 |

结构示例：

```json
{
  "minimum_listing_age_seconds": 1209600,
  "minimum_notional_volume": 10000000,
  "inferred_trading_minimum_notional_volume": 100000,
  "required_contract_type": "USDT_PERPETUAL",
  "liquidity_lookback_seconds": 86400,
  "notional_currency": "USDT",
  "notional_measure": "ROLLING_QUOTE_VOLUME"
}
```

含义：上市至少 14 天、最近 24 小时名义成交额至少 1000 万 USDT、仅接受 USDT 永续合约。成交额门槛必须通过历史分布校准。

---

## 7. 数据质量

### 7.1 `DATA_QUALITY_RULES`

规定数据集能否进入 `READY`。依赖名称必须与质量报告生产器完全一致。

| 参数 | 含义 |
|---|---|
| `required_dependencies` | 必须存在的数据依赖名称 |
| `minimum_coverage` | 最低覆盖率，范围 0～1 |
| `minimum_effective_samples` | 最小有效样本数 |
| `minimum_effective_folds` | 最小有效折数 |
| `warmup_required` | 是否要求完成预热 |

结构示例：

```json
{
  "required_dependencies": [
    "TRADE_KLINE_5M",
    "MARK_KLINE_5M",
    "EMA20_5M",
    "EMA240_5M",
    "UTC_DAILY_RANKING_D_MINUS_1",
    "TICKER_POOL_D_MINUS_1"
  ],
  "dependency_rules": {
    "TRADE_KLINE_5M": {
      "minimum_coverage": 0.995,
      "minimum_effective_samples": 8000,
      "minimum_effective_folds": 1,
      "warmup_required": true
    },
    "MARK_KLINE_5M": {
      "minimum_coverage": 0.995,
      "minimum_effective_samples": 8000,
      "minimum_effective_folds": 1,
      "warmup_required": true
    },
    "EMA20_5M": {
      "minimum_coverage": 0.995,
      "minimum_effective_samples": 8000,
      "minimum_effective_folds": 1,
      "warmup_required": true
    },
    "EMA240_5M": {
      "minimum_coverage": 0.995,
      "minimum_effective_samples": 8000,
      "minimum_effective_folds": 1,
      "warmup_required": true
    },
    "UTC_DAILY_RANKING_D_MINUS_1": {
      "minimum_coverage": 0.95,
      "minimum_effective_samples": 20,
      "minimum_effective_folds": 1,
      "warmup_required": true
    },
    "TICKER_POOL_D_MINUS_1": {
      "minimum_coverage": 0.95,
      "minimum_effective_samples": 20,
      "minimum_effective_folds": 1,
      "warmup_required": true
    }
  }
}
```

正式批准前必须确认：

- 依赖名称与质量报告实际输出一致；
- 样本数按全数据集、单标的还是自然日统计；
- 依赖是否与本次冻结的 `FACTOR_REGISTRY` 一致；首轮模型 A 不启用 OI 因子，
  因 Binance 历史 OI 仅能取得最近约一个月，`OPEN_INTEREST_5M` 不属于本轮必需依赖；
- 2026 年 10 月以后具备 OI 数据的实验若启用 OI 因子，必须创建新的
  `FACTOR_REGISTRY`、`DATA_QUALITY_RULES` 和 `SEARCH_SPACE` 版本，将
  `OPEN_INTEREST_5M` 恢复为必需依赖并重新执行预检；
- 启用因子的全部依赖都已包含，不能以缺失值填 0 或静默禁用因子。

首轮模型 A 所需的历史 `MARK_KLINE_5M` 应在数据集预检前完成回补。部署包含
`queue-mark-5m` 命令的新 `data-repair` 镜像后，以左闭右开 UTC 区间排队：

```bash
./scripts/queue-mark-5m-backfill.sh \
  2026-07-21T00:00:00Z \
  2026-09-01T00:00:00Z
```

脚本只负责识别缺口并创建幂等回补任务；常驻 `data-repair` 服务继续按既有速率限制处理。
执行期间通过 `docker compose --profile runtime logs -f --tail=100 data-repair` 观察进度，
任务完成后必须重新运行数据集构建预检，不能仅以任务状态代替实际覆盖率检查。

---

## 8. 可复现容差

### 8.1 `REPRODUCIBILITY_TOLERANCE`

规定重复运行时允许的浮点误差。

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `absolute_tolerance` | 非负数 | 接近零时允许的最大绝对误差 |
| `relative_tolerance` | 非负数 | 相对于数值规模允许的最大相对误差 |

结构示例：

```json
{
  "absolute_tolerance": 0.0000000001,
  "relative_tolerance": 0.00000001
}
```

即绝对容差 `1e-10`、相对容差 `1e-8`。离散结果、ID、状态、样本数和哈希仍应逐字节一致，容差只适用于明确登记的浮点指标。

---

## 9. 可见截止策略

### 9.1 `VISIBILITY_CUTOFF_POLICY`

规定候选分区开始前，研究访问必须提前多久被封存。

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `policy_name` | 非空字符串 | 封存策略名称 |
| `required_lead_seconds` | 非负数 | cutoff 必须领先分区开始时间的秒数 |

结构示例：

```json
{
  "policy_name": "PRE_PARTITION_CUTOFF_24H_V1",
  "required_lead_seconds": 86400
}
```

若数据分区从 `2026-12-01 00:00:00 UTC` 开始，则数据集的 `visibility_cutoff_at` 最晚应为 `2026-11-30 00:00:00 UTC`。

配置本身不保存具体 cutoff 日期；具体时间保存在数据集版本中。

---

## 10. 模型 A 五项配置

### 10.1 `FACTOR_REGISTRY`

冻结当前模型 A 启用的因子集合。

| 参数 | 含义 |
|---|---|
| `adapter_version` | 因子计算适配器版本 |
| `factors` | 启用因子名称，必须唯一且与代码注册表一致 |

结构示例：

```json
{
  "adapter_version": "FEATURE_SCAN_V2_5M_V1",
  "factors": [
    "bullish_candle_sequence",
    "single_bar_price_rise",
    "volume_acceleration",
    "ema_bullish_setup",
    "low_average_amplitude"
  ]
}
```

因子名称必须与 `src/auto_trade/strategies/feature_scan.py` 中的注册名称完全一致。

### 10.2 `SEARCH_SPACE`

包含两部分：

- `strategy_parameters`：全部候选共享的固定参数；
- `parameters`：Optuna 允许搜索的参数及边界。

数值规则结构：

```json
{
  "kind": "numeric",
  "minimum": 1,
  "maximum": 10,
  "integer": true
}
```

分类规则结构：

```json
{
  "kind": "categorical",
  "choices": ["A", "B"]
}
```

5m 搜索空间示例：

```json
{
  "interval_seconds": 300,
  "strategy_parameters": {
    "lookback_days": 90,
    "average_days": 7,
    "required_factors": [
      "bullish_candle_sequence",
      "single_bar_price_rise",
      "volume_acceleration",
      "ema_bullish_setup",
      "low_average_amplitude"
    ],
    "factor_weights": {
      "bullish_candle_sequence": 12,
      "single_bar_price_rise": 8,
      "volume_acceleration": 15,
      "ema_bullish_setup": 12,
      "low_average_amplitude": 8
    }
  },
  "parameters": {
    "cooldown_bars": {
      "kind": "numeric",
      "minimum": 1,
      "maximum": 12,
      "integer": true
    },
    "signal_score_threshold": {
      "kind": "numeric",
      "minimum": 60,
      "maximum": 85,
      "integer": true
    },
    "trigger_single_bar_rise_percent": {
      "kind": "numeric",
      "minimum": 0.4,
      "maximum": 1.2,
      "integer": false
    },
    "trigger_volume_average_multiple": {
      "kind": "numeric",
      "minimum": 1.2,
      "maximum": 2.5,
      "integer": false
    }
  }
}
```

约束：

- 第一阶段 `interval_seconds` 固定为 `300`；
- `required_factors` 必须与 `FACTOR_REGISTRY.factors` 完全一致；
- 候选只能包含 `parameters` 中声明的字段；
- 参数名包含 validation、test、future、label、outcome、rank 等结果信息时会被拒绝。

### 10.3 `RANDOM_BASELINE`

用于比较真实信号入场和同标的、同流动性、同波动率、同 BTC 市况的随机时点。

| 参数 | 含义 |
|---|---|
| `sample_count` | 每次需要抽取的随机对照数量 |
| `minimum_frame_size` | 抽样框最低候选数 |
| `maximum_frame_candidates` | 抽样框最多保留的候选时点数 |
| `exclusion_window_seconds` | 排除真实信号附近重叠时点的窗口 |
| `matching_fields` | 固定六项匹配条件 |
| `stratification` | 波动率、流动性和 BTC 市况的窗口与分桶边界 |

结构示例：

```json
{
  "sample_count": 5,
  "minimum_frame_size": 20,
  "maximum_frame_candidates": 500,
  "exclusion_window_seconds": 86400,
  "matching_fields": [
    "btc_regime",
    "instrument_id",
    "liquidity_bucket",
    "pool_identity",
    "time_bucket",
    "volatility_bucket"
  ],
  "stratification": {
    "benchmark_symbol": "BTCUSDT",
    "volatility_measure": "CLOSE_RETURN_STDDEV_PERCENT",
    "volatility_window_bars": 12,
    "volatility_boundaries_percent": [0.2, 0.5, 1.0],
    "liquidity_measure": "MEAN_QUOTE_VOLUME",
    "liquidity_window_bars": 12,
    "liquidity_boundaries_quote_volume": [100000, 1000000, 10000000],
    "btc_regime_measure": "CLOSE_RETURN_PERCENT",
    "btc_regime_window_bars": 12,
    "btc_return_boundaries_percent": [-1, 0, 1]
  }
}
```

在 5m 周期下，12 根等于 60 分钟。所有分桶边界必须是非空、有限且严格递增的数值数组。

### 10.4 `OPPORTUNITY_DEFINITION`

定义什么是真正需要模型召回的机会，三项条件必须同时满足。

| 参数 | 类型/范围 | 含义 |
|---|---|---|
| `minimum_mfe_percent` | 大于 0 | 未来窗口最大有利波动最低值 |
| `maximum_mae_percent` | 不小于 0 | 未来窗口最大不利波动上限 |
| `minimum_return_percent` | 显式数值 | 标签窗口结束收益最低值 |

结构示例：

```json
{
  "minimum_mfe_percent": 3.0,
  "maximum_mae_percent": 2.0,
  "minimum_return_percent": 1.0
}
```

含义：24 小时内 MFE 至少 3%、MAE 不超过 2%、窗口结束收益至少 1%。阈值只能由 TRAIN 分布确定。

### 10.5 `SCORING_MODEL_A`

定义模型 A 的 `DiscoveryScore`。

正向分数：

- `opportunity_recall`：机会召回；
- `entry_timing`：入场路径质量；
- `excess_mfe_quality`：相对随机基线的超额 MFE；
- `cross_period_stability`：跨周稳定性。

惩罚项：

- `false_signal_penalty`：假信号比例；
- `low_sample_penalty`：样本不足；
- `concentration_penalty`：信号过度集中在少数标的。

| 参数 | 含义 |
|---|---|
| `entry_timing_scale_percent` | 将入场质量映射至 0～100 的尺度 |
| `excess_mfe_scale_percent` | 将超额 MFE 映射至 0～100 的尺度 |
| `minimum_signal_count` | 最低信号数量硬门槛 |
| `minimum_opportunity_count` | 最低机会总体数量 |
| `minimum_effective_day_count` | 最低独立有效自然日数 |
| `minimum_week_count` | 最低自然周数量 |

结构示例：

```json
{
  "calculation_version": "DISCOVERY_V1",
  "weights": {
    "opportunity_recall": 0.3,
    "entry_timing": 0.15,
    "excess_mfe_quality": 0.25,
    "cross_period_stability": 0.1,
    "false_signal_penalty": 0.1,
    "low_sample_penalty": 0.05,
    "concentration_penalty": 0.05
  },
  "entry_timing_scale_percent": 3.0,
  "excess_mfe_scale_percent": 2.0,
  "minimum_signal_count": 100,
  "minimum_opportunity_count": 50,
  "minimum_effective_day_count": 20,
  "minimum_week_count": 4
}
```

任一最低数量门槛不满足时，候选会被硬拒绝，不产生可供 Optuna 晋级的目标值。

---

## 11. 修改前检查清单

创建替代版本前逐项确认：

- [ ] 修改原因和依据已经记录；
- [ ] 新 SemVer 未与同类型现有版本重复；
- [ ] 父版本指向被替代的同类型版本；
- [ ] JSON 中没有 `null` 占位；
- [ ] 时间、百分比、费率、bp、字节和 K 线根数的单位无混用；
- [ ] `FACTOR_REGISTRY` 与 `SEARCH_SPACE.required_factors` 完全一致；
- [ ] `DATA_QUALITY_RULES` 覆盖所有启用因子的依赖；
- [ ] `SLIPPAGE_MODEL` 包含运行时需要的完整七字段；
- [ ] 随机基线分桶边界严格递增；
- [ ] 资源值已经通过目标环境容量预检；
- [ ] 配置只使用 TRAIN 证据，没有读取 VALIDATION 或 TEST 结果；
- [ ] 审批人具有有效 `TRAINING_ADMIN` 授权；
- [ ] READY 后不再原地修改，后续变化创建新 DRAFT。

## 12. 相关文档与代码

- 数值审批状态：[STRATEGY_SELF_TRAINING_ENGINE_CONFIG_APPROVAL.md](./STRATEGY_SELF_TRAINING_ENGINE_CONFIG_APPROVAL.md)
- 总体设计：[STRATEGY_SELF_TRAINING_ENGINE.md](./STRATEGY_SELF_TRAINING_ENGINE.md)
- 开发设计：[STRATEGY_SELF_TRAINING_ENGINE_DEVELOPMENT.md](./STRATEGY_SELF_TRAINING_ENGINE_DEVELOPMENT.md)
- 进度跟踪：[STRATEGY_SELF_TRAINING_ENGINE_PROGRESS.md](./STRATEGY_SELF_TRAINING_ENGINE_PROGRESS.md)
- 配置管理 API：`src/auto_trade/training/config_management.py`
- 搜索空间解析：`src/auto_trade/training/search_space.py`
- 因子定义：`src/auto_trade/strategies/feature_scan.py`
- 滑点计算：`src/auto_trade/training/simulator.py`
