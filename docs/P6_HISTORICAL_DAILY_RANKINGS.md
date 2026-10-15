# 最近三个月 UTC 日涨幅榜构建

该任务从 Binance USD-M 永续合约 5 分钟成交 K 线，重建最近 90 个已经结束的
UTC 交易日涨幅榜。默认截止日为昨天，避免把当天尚未结束的数据误认为完整日榜。

## 口径

- 开盘价：UTC 00:00 开始的 5 分钟 K 线开盘价。
- 快照价：UTC 23:50 开始、23:55 结束的 5 分钟 K 线收盘价。
- 涨幅：`(快照价 / 开盘价 - 1) * 100`。
- 振幅：`(当日最高价 - 当日最低价) / 开盘价 * 100`。
- 完整性：00:00 至 23:50 必须具有 287 根时间对齐且不重复的已收盘 5 分钟
  K 线，才参与 Top 50；不读取 23:55 才开盘的下一根 K 线，避免前视数据。
- 最终快照写入 `market.ranking_snapshots` / `market.ranking_entries`，类型为
  `UTC_DAILY_2355`，生成方式为 `DERIVED`。
- Binance 历史 OI 接口只有较短历史窗口。本任务不会用当前 OI 冒充历史 OI；仅当
  本地库在快照前 10 分钟内已有 OI 观测时关联，否则写入空值并标记 `UNAVAILABLE`。

## 首次执行

本地实时采集服务若仍在使用同一公网 IP，先停止它，以免与历史任务争用 Binance
REST 限额；数据库保持运行：

```bash
make runtime-down
make db-up
make db-migrate
make history-rankings-3m
make history-rankings-status
```

默认并发为 4，每次分页请求后等待 0.25 秒。全量约需读取 500 多个标的、约 1.4
万个 REST 页面，耗时取决于网络和 Binance 限流状态；请求仍统一经过客户端的
`x-mbx-used-weight-1m` 保护。

任务按“标的 + UTC 日期”幂等保存到 `market.utc_daily_metrics`。中断后重复执行相同
命令会跳过已经落库的日期；只有全部标的抓取成功后才生成最终榜单。

## 开发验证与重算

先用两个标的、三天数据验证连接：

```bash
docker compose --profile tools run --rm --build historical-rankings \
  --days 3 --symbols BTCUSDT,ETHUSDT
```

仅根据已有日指标重新生成榜单：

```bash
docker compose --profile tools run --rm historical-rankings --days 90 --rank-only
```

强制重新抓取已存在的日指标：

```bash
docker compose --profile tools run --rm historical-rankings --days 90 --refresh
```

## 后续日榜自动更新

常驻运行环境包含独立的 `daily-rankings` 服务。服务启动后立即检查最近90天，之后
每5分钟检查一次；每轮最多处理7个缺失或非有效日期。日榜直接使用
`market.klines` 中已闭合、当前修订且质量为 `VALID` 的5分钟Trade K线，不额外请求
Binance。

每个标的仍必须具有UTC 00:00至23:50的287根完整K线才参与排名。数据不完整时会
保存中间日指标和非有效快照，查询接口不会将其作为可用日榜；缺口修复完成后，后续
扫描会自动重建并发布有效Top 50。配置项如下：

- `DAILY_RANKING_SCAN_INTERVAL_SECONDS`：扫描间隔，默认300秒。
- `DAILY_RANKING_LOOKBACK_DAYS`：启动补漏窗口，默认90天。
- `DAILY_RANKING_MAX_DAYS_PER_CYCLE`：单轮处理上限，默认7天。
