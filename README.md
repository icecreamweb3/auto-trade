# Auto Trade 2.0

Binance USDⓈ-M USDT永续合约的数据采集、实时决策、交易执行和分析回测系统。

当前开发阶段：P3分钟K线采集。已具备全合约目录、分钟Ticker、资金费率、1分钟Trade/Mark K线、5分钟Trade K线、5分钟OI、滚动涨幅榜、JetStream幂等落库和多序列缺口自动回补。需求、实施计划和数据库说明位于 `docs/`。

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

采集器将每份 Binance 响应同时用于原始事件留存和标准事件生成；策略、风控和后续数据库写入消费者从 JetStream 获取这份一致的数据，不重复请求 Binance。Trade 1m/5m 使用 WebSocket 闭合K线；Mark 1m 使用全市场 `!markPrice@arr@1s` WebSocket 实时流在本地按UTC分钟聚合，缺口再由REST回补。

局域网测试机的完整部署、验收、升级、备份和分析终端接入步骤见 [`docs/COLLECTOR_LAN_DEPLOYMENT.md`](docs/COLLECTOR_LAN_DEPLOYMENT.md)。

无需代理的云服务器部署资料：

- [`docs/CLOUD_SERVER_CONFIGURATION_CHECKLIST.md`](docs/CLOUD_SERVER_CONFIGURATION_CHECKLIST.md)：机器规格、安全组、磁盘、备份和验收清单。
- [`docs/CLOUD_SERVER_DEPLOYMENT.md`](docs/CLOUD_SERVER_DEPLOYMENT.md)：从主机初始化到数据迁移、启动和24小时验收的完整步骤。
