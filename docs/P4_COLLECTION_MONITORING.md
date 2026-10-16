# P4 采集系统监控MVP

日期：2026-10-10

## 目标

提供独立于采集进程的只读监控服务。监控结论以实际落库数据、NATS状态和回补队列为依据，不因Collector进程存在就假定数据健康。

## 当前能力

- FastAPI只读监控API：`GET /api/monitoring/overview`。
- 存活和就绪检查：`/health/live`、`/health/ready`。
- React + TypeScript监控页面，每15秒自动刷新。
- 当前TRADING状态USDT永续合约数量。
- Trade 1m、Mark 1m、Trade 5m覆盖率、延迟和WebSocket来源数量。
- 分钟Ticker的Mark Price与24hChange完整率。
- 最近一轮OI覆盖率和延迟。
- 回补任务当前状态、历史成功/失败、开放缺口、最老PENDING任务年龄、当前运行任务及等待队列对应的UTC数据时间范围。
- 最近一小时新增、完成、队列净变化、实际吞吐和预计清空时间。
- 最近10分钟Binance REST请求速率、使用权重峰值和2400权重上限占比。
- 最近60个完整自然分钟按“每分钟峰值等权”计算的REST权重均值，并显示有效分钟样本数。
- PostgreSQL数据库总空间、缓存命中率及占用最大的12个关系。
- 大表列表显示TimescaleDB Hypertable、分块数、Columnstore策略、已转换分块、实际节省比例、估算行数、数据、索引、TOAST和总占用；不执行高成本逐表精确计数。
- TimescaleDB内部chunk不重复展示，容量统一归入对应Hypertable。
- NATS JetStream连接、消息量和消费者数量。
- `HEALTHY`、`WARNING`、`CRITICAL`、`UNKNOWN`统一健康等级。

## 安全边界

- 第一版不提供重启、删除、队列修改或数据修复操作。
- 不挂载Docker Socket。
- 默认监控页面只绑定 `127.0.0.1:8080`。
- 局域网开放前需要增加认证和主机防火墙规则。
- 正式测试机应改用只读数据库账户；当前开发环境沿用项目数据库配置。

## Docker运行

```bash
make monitor-up
make monitor-logs
```

访问：

```text
http://127.0.0.1:8080
```

通过SSH隧道从开发机访问测试机：

```bash
ssh -N -L 18080:127.0.0.1:8080 <test-user>@<test-host>
```

然后访问 `http://127.0.0.1:18080`。

## 本地开发

后端：

```bash
uvicorn auto_trade.monitoring.app:app --reload --host 127.0.0.1 --port 8000
```

前端：

```bash
cd monitoring-ui
npm ci
npm run dev
```

Vite开发服务器将 `/api` 和 `/health` 代理到 `127.0.0.1:8000`。

## 当前限制

- 尚未增加身份认证，因此默认不允许对局域网或公网开放。
- 尚未接入主机磁盘、CPU、内存及容器重启次数。
- 尚未持久化健康状态历史和告警记录。
- 尚未接入Telegram等主动告警渠道。
- 健康阈值目前是系统基线，需要通过Mac mini测试运行数据继续校准。
