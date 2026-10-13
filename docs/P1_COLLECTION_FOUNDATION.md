# P1 数据采集基础链路实施记录

日期：2026-10-09

## 已完成

- PostgreSQL 16 + TimescaleDB 2.30.1 本地环境，55张业务表、9张超表。
- 12个月分钟数据容量与查询 PoC；10个标的共5,256,000行约1.06GB。
- Python 3.12 工程骨架，FastAPI健康接口、环境配置、CI、ruff、严格mypy和pytest。
- NATS 2.15.0 JetStream，文件持久化和本地独立数据卷。
- Binance USD-M 公共 REST 单一数据入口。
- 全量 USDT 永续合约及交易规则标准化。
- 1分钟 Ticker 快照：成交价、标记价、指数价、24小时涨跌幅、窗口时间、24小时量价和资金费率。
- 已关闭5分钟成交K线：OHLC、成交量、成交额、成交笔数。
- 原始响应和标准事件由同一请求结果产生，均使用稳定事件ID和 JetStream 去重头。
- 支持 Binance Unicode 合约代码，不用 ASCII 正则误删正常交易标的。

## JetStream 数据流

| Stream | Subject | 保留期 | 容量上限 | 用途 |
|---|---|---:|---:|---|
| RAW_MARKET | `raw.market.>` | 72小时 | 10GB | 原始交易所响应及短期重放 |
| NORMALIZED_MARKET | `market.normalized.>` | 7天 | 40GB | 规则、Ticker、K线标准事件 |
| DECISIONS | `decision.>` | 30天 | 6GB | 信号、风控和决策快照 |
| TRADE_EVENTS | `trade.>` | 30天 | 4GB | 订单和头寸事件 |
| DLQ | `dlq.>` | 30天 | 2GB | 有界重试后失败的事件 |

本地环境 JetStream 文件存储总上限为64GB，各流上限合计62GB，保留2GB安全余量。单副本运行；流定义保留副本参数，云端多节点部署时调整为3副本。

## 验证结果

- `ruff check`：通过。
- `mypy --strict`：通过，13个源文件无问题。
- `pytest`：10个测试通过。
- JetStream 发布、读取、删除冒烟：通过。
- Binance 真实采集：发现659个 USDT 永续合约规则；BTCUSDT、ETHUSDT 各生成1条分钟快照及1条已关闭5分钟K线。
- 真实采集后：RAW_MARKET 6条、NORMALIZED_MARKET 663条。
- PostgreSQL 与 NATS 容器均为 healthy，端口仅绑定 `127.0.0.1`。

## 下一阶段

实现 JetStream 数据库写入消费者、规则版本化和下架状态处理，然后加入守护调度、缺口检测、自动回补及 UTC 16:00 全量规则刷新。
