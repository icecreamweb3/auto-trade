# 15m 特征因子扫描

`auto_trade.strategies.feature_scan` 从 PostgreSQL 直接读取持久化的 `market.klines_15m`
和预计算的 15m EMA 指标，筛选过去 90 天满足条件的 K 线。OHLC、Volume 和桶内最后一条
可用 OI 已由指标服务提前从 5m 数据聚合；扫描时不再执行 5m→15m 聚合。扫描只读数据库，
不写交易信号，也不会把历史缺失的 OI 当作 0。

默认因子定义：

1. `ema_bullish_cross`：EMA20 在最近 4 根 15m K 线内由下向上穿过 EMA240。
2. `rapid_price_rise`：当前收盘价相对 4 根前（1 小时）上涨至少 3%。
3. `open_interest_rise`：当前 OI 价值相对 4 根前上涨至少 5%。
4. `volume_surge`：当前 15m quote volume 至少是此前连续 7 日均值的 5 倍。
5. `amplitude_spike_streak`：连续 2 根 K 线的振幅，均至少是各自此前连续 7 日平均振幅的 5 倍。
6. `low_average_amplitude`：当前 K 线之前连续 7 日的平均振幅小于 2%。

振幅口径为 `(high - low) / open * 100`。7 日均值不包含当前 K 线；若 15m K 线不连续，
或指定对比时点没有 OI，相关因子不通过。

运行全部因子：

```bash
make db-migrate
docker compose --profile runtime run --rm ema-indicators \
  python -m auto_trade.collectors.ema_indicators once
make feature-scan-3m
```

迁移会建立持久化 15m 表及增量 checkpoint。第二条命令用于在扫描前把新增或修复过的
5m K 线和 OI 同步为 15m 派生数据；常驻的
`ema-indicators` 服务已运行且数据最新时可以省略。

只检查 BRUSDT，并调整“快速拉升”和 OI 阈值：

```bash
docker compose --profile tools run --rm feature-scan \
  --symbols BRUSDT \
  --price-rise-percent 4 \
  --oi-rise-percent 8
```

只用部分因子筛选时可重复传入 `--require-factor`，但输出仍会包含六项因子的通过状态、
实测值、阈值和失败原因，便于检查或调参：

```bash
docker compose --profile tools run --rm feature-scan \
  --require-factor ema_bullish_cross \
  --require-factor rapid_price_rise \
  --format csv
```

可配置参数可通过 `python -m auto_trade.strategies.feature_scan --help` 查看。新增因子时，增加一个
返回 `FactorResult` 的计算函数，将其注册到 `FACTOR_EVALUATORS`，并加入 `ALL_FACTORS`。
