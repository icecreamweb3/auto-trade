# Auto Trade 2.0

Binance USDⓈ-M USDT永续合约的数据采集、实时决策、交易执行和分析回测系统。

当前开发阶段：P3分钟K线采集。已具备全合约目录、分钟Ticker、资金费率、1分钟Trade/Mark K线、5分钟Trade K线、5分钟OI、滚动涨幅榜、UTC自然日榜自动生成、JetStream幂等落库和多序列缺口自动回补。需求、实施计划和数据库说明位于 `docs/`。

采集监控MVP提供只读FastAPI、React Web界面、数据覆盖率、回补队列、REST权重、数据库容量和JetStream状态。默认仅监听 `127.0.0.1:8080`。

## 本地启动

```bash
cp .env.example .env
make infra-up
make db-migrate
make db-verify
```

Python服务以3.12为最低版本。通过测试容器完成质量检查：

```bash
docker build --target test -t auto-trade-test:local .
make lint
make typecheck
make test
```

测试镜像建立后，初始化并验证NATS：

```bash
make nats-init
make nats-verify
```

执行 BTC/ETH 单周期真实采集验证：

```bash
make collector-smoke
```

启动或停止常驻采集器与数据库写入消费者：

```bash
make runtime-up
make runtime-logs
make runtime-down
```

可选的持久化文件日志、按日轮转和导出方式见
[`docs/RUNTIME_LOGGING.md`](docs/RUNTIME_LOGGING.md)。Docker控制台日志始终保留。

只启动或查看采集监控：

```bash
make monitor-up
make monitor-logs
```

浏览器访问 `http://127.0.0.1:8080`。局域网访问前应配置认证和防火墙；开发阶段推荐SSH隧道。

手动执行一轮缺口检测与回补：

```bash
make repair-once
```

## Telegram 频道订阅

Telegram 订阅器通过代理连接 MTProto，首次启动会从频道最早可见消息开始补录，
之后持续接收新增和编辑消息。原文、历史修订和结构化信号分别保存到
`market.telegram_messages`、`market.telegram_message_revisions` 和
`market.telegram_signals`，同时发布到 `decision.telegram.<channel>.history`
或 `decision.telegram.<channel>.realtime`。

先在 `.env` 配置 `TELEGRAM_API_ID`、`TELEGRAM_API_HASH`、
`TELEGRAM_PHONE`、`TELEGRAM_CHANNEL`。建议通过 `TELEGRAM_PROXY_URL`
显式配置 `http://`、`socks4://` 或 `socks5://` 代理；未配置时依次读取
`ALL_PROXY`、`HTTPS_PROXY`、`HTTP_PROXY`。订阅器不允许绕过代理直连。

应用迁移并构建镜像后，在本机终端执行一次授权：

```bash
docker compose --profile tools run --rm telegram-auth
```

默认选择二维码授权：在手机 Telegram 打开“设置 > 设备 > 连接桌面设备”扫码；
也可选择手机号验证码方式，此时终端会显示 Telegram 实际采用的投递渠道。
验证码和两步验证密码只在本机终端输入，不要写入 `.env`、日志或聊天记录。
授权会话保存在 Docker 命名卷 `auto-trade-telegram-session`。授权成功后启动订阅器：

```bash
docker compose --profile runtime up -d telegram-subscriber
docker compose logs -f telegram-subscriber
```

`TELEGRAM_STRATEGY_TRIGGER_ENABLED` 默认是 `false`。当前阶段只采集、解析和
发布信号；在频道规则完成样本回测和人工验收前，不会自动触发真实交易。

为 PaperTrader 独立补齐 BTCUSDT、ETHUSDT 自 `2020-04-01 00:00 UTC`
起的 5 分钟 Trade OHLCV：

```bash
make paper-history-backfill
make paper-history-status
```

该工具直接批量幂等写入规范化 `market.klines`，不经过 NATS。每个交易对的
游标保存在 `market.backfill_scan_checkpoints`，中断后重新执行同一命令即可续跑；
前向抓取结束后还会逐点检查缺口，只有目标区间全部为闭合、`VALID` K 线时才成功退出。
15 分钟和 1 小时行情由 5 分钟源数据查询时聚合，不重复长期存储。默认每个交易对
每次请求后等待 0.5 秒，可通过 `PAPER_HISTORY_REQUEST_INTERVAL_SECONDS` 调整。

采集器将每份 Binance 响应同时用于原始事件留存和标准事件生成；策略、风控和后续数据库写入消费者从 JetStream 获取这份一致的数据，不重复请求 Binance。Trade 1m/5m 使用 WebSocket 闭合K线；Mark 1m 使用全市场 `!markPrice@arr@1s` WebSocket 实时流在本地按UTC分钟聚合，缺口再由REST回补。

`daily-rankings` 服务每5分钟检查最近90天内缺失或非有效的 UTC 日榜，每轮最多处理7天。它只使用本地已闭合且质量有效的5分钟Trade K线；每天UTC日期结束后生成前一日榜单，启动时也会自动补齐遗漏日。数据尚不完整时快照保持非有效状态，缺口回补完成后由后续周期重算。

局域网测试机的完整部署、验收、升级、备份和分析终端接入步骤见 [`docs/COLLECTOR_LAN_DEPLOYMENT.md`](docs/COLLECTOR_LAN_DEPLOYMENT.md)。

无需代理的云服务器部署资料：

- [`docs/CLOUD_SERVER_CONFIGURATION_CHECKLIST.md`](docs/CLOUD_SERVER_CONFIGURATION_CHECKLIST.md)：机器规格、安全组、磁盘、备份和验收清单。
- [`docs/CLOUD_SERVER_DEPLOYMENT.md`](docs/CLOUD_SERVER_DEPLOYMENT.md)：从主机初始化到数据迁移、启动和24小时验收的完整步骤。
