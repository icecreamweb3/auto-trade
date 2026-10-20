# 5m/15m 特征因子扫描

`auto_trade.strategies.feature_scan` 从 PostgreSQL 直接读取持久化的 `market.klines_15m`
和预计算的 15m EMA 指标，筛选过去 90 天满足条件的 K 线。OHLC、Volume 和桶内最后一条
可用 OI 已由指标服务提前从 5m 数据聚合；扫描时不再执行 5m→15m 聚合。扫描只读数据库，
不写交易信号，也不会把历史缺失的 OI 当作 0。

默认使用“提前突破”组合：

1. `bullish_candle_sequence`：连续 2 根阳线；前一根收盘位置至少 50%，最后一根至少
   85%，且最后一根上影线占整根振幅不超过 15%。
2. `single_bar_price_rise`：当前 K 线从开盘到收盘上涨至少 3%。
3. `volume_acceleration`：当前 quote volume 至少为此前 20 根均值的 2 倍，且至少为
   上一根的 1.3 倍；均值不包含当前 K 线。
4. `ema_bullish_setup`：EMA20 已不低于 EMA240，或者两者差距不超过 1%、EMA20
   上升且差距较上一根至少缩小 30%。
5. `low_average_amplitude`：当前 K 线之前连续 7 日的平均振幅小于 2%。

原确认因子继续保留，可在页面或 CLI 中单独选择：

1. `ema_bullish_cross`：EMA20 在最近 4 根 15m K 线内由下向上穿过 EMA240。
2. `rapid_price_rise`：当前收盘价相对 4 根前（1 小时）上涨至少 3%。
3. `open_interest_rise`：当前 OI 价值相对 4 根前上涨至少 5%。
4. `volume_surge`：当前 15m quote volume 至少是此前连续 7 日均值的 5 倍。
5. `amplitude_spike_streak`：连续 2 根 K 线的振幅，均至少是各自此前连续 7 日平均振幅的 5 倍。
6. `low_average_amplitude`：与提前突破组合共用的低波动背景因子。

振幅口径为 `(high - low) / open * 100`。7 日均值不包含当前 K 线；若 15m K 线不连续，
或指定对比时点没有 OI，相关因子不通过。

运行默认提前突破组合：

```bash
make db-migrate
docker compose --profile runtime run --rm ema-indicators \
  python -m auto_trade.collectors.ema_indicators once
make feature-scan-3m
```

迁移会建立持久化 15m 表及增量 checkpoint。第二条命令用于在扫描前把新增或修复过的
5m K 线和 OI 同步为 15m 派生数据；常驻的
`ema-indicators` 服务已运行且数据最新时可以省略。

只检查 BRUSDT，并调整提前突破阈值：

```bash
docker compose --profile tools run --rm feature-scan \
  --symbols BRUSDT \
  --single-bar-price-rise-percent 3 \
  --volume-acceleration-average-multiple 2 \
  --ema-near-cross-gap-percent 1
```

只用部分因子筛选时可重复传入 `--require-factor`，但输出仍会包含全部因子的通过状态、
实测值、阈值和失败原因，便于检查或调参：

```bash
docker compose --profile tools run --rm feature-scan \
  --require-factor ema_bullish_cross \
  --require-factor rapid_price_rise \
  --format csv
```

可配置参数可通过 `python -m auto_trade.strategies.feature_scan --help` 查看。新增因子时，增加一个
返回 `FactorResult` 的计算函数，将其注册到 `FACTOR_EVALUATORS`，并加入 `ALL_FACTORS`。
