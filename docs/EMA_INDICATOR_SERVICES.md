# EMA 指标服务

EMA20、EMA240 分为两个用途不同的服务，避免 BTCUSDT、ETHUSDT 的超长历史阻塞全部
交易对的实时指标。

## 实时增量服务

`ema-indicators` 是 `runtime` profile 下的常驻服务。它处理所有已有有效 5m K 线的
交易对，并根据 checkpoint 持续计算新增或修订数据的 5m、15m、1h EMA。

新交易对或 checkpoint 版本变化时，只读取最近 `EMA_INDICATOR_BOOTSTRAP_BARS` 根 5m
K 线进行预热，默认 2880 根。数据库暂时不可用时，当前轮次会立即停止，等待正常扫描
间隔后再重试，不会继续为数百个交易对反复创建失败连接。

## BTC/ETH 历史回补服务

`ema-indicators-history` 是 `tools` profile 下的一次性服务，只在人工执行时启动，完成后退出。
默认从 2020-04-01 开始为 BTCUSDT、ETHUSDT 计算到执行时数据库内最新一根已关闭、
有效且已完成回补的 5m K 线。数据按 `EMA_HISTORY_CHUNK_DAYS` 分片读取和提交，默认每片
7 天，避免把数年 K 线一次性载入内存。
指定起点的第一根收盘价作为 EMA 初始值，因此重复执行相同区间会得到一致结果。

```bash
make ema-history-backfill
```

也可以指定其他起始日期或明确的交易对：

```bash
docker compose --profile tools run --rm --build ema-indicators-history \
  --symbols BTCUSDT ETHUSDT --start 2020-04-01
```

历史服务与实时服务对同一交易对、同一周期使用数据库 advisory lock，历史回补期间实时
服务会等待该周期完成，避免互相删除或覆盖数据。历史服务最终保存 checkpoint，后续由
实时服务从该时间点继续增量计算。
