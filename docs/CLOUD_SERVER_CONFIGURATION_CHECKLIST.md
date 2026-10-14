# Auto Trade 2.0 云服务器配置清单

本文定义单机长期运行 Auto Trade 2.0 采集链路的云服务器配置基线。目标环境可直接访问 Binance USDⓈ-M REST 与 WebSocket，不使用任何代理。

完整安装、迁移和验收命令见 [`CLOUD_SERVER_DEPLOYMENT.md`](CLOUD_SERVER_DEPLOYMENT.md)。

## 1. 规格建议

| 项目 | 最低验证配置 | 推荐长期配置 | 说明 |
|---|---:|---:|---|
| 架构 | x86_64 | x86_64 | 使用官方 Docker、TimescaleDB 与 NATS 镜像 |
| vCPU | 4核 | 8核 | Collector、回补、写入器和数据库共用主机 |
| 内存 | 16GB | 32GB | PostgreSQL、Docker构建和历史回补需要余量 |
| 系统盘 | 60GB SSD | 80–100GB SSD | 仅放系统、软件和临时构建文件 |
| 数据盘 | 300GB SSD | 1TB NVMe/高性能云盘 | PostgreSQL、NATS、Docker日志和本地备份 |
| 数据盘性能 | 1,500 IOPS | 3,000+ IOPS | 优先保证稳定随机写入和fsync延迟 |
| 网络带宽 | 20Mbps | 100Mbps及以上 | 约525个合约的实时流、REST回补与镜像拉取 |
| 公网地址 | 固定IPv4 | 固定IPv4 | 便于SSH白名单和稳定出口 |
| 紧急Swap | 4GB | 8GB | 仅作故障缓冲，不替代物理内存 |

最低配置只适合功能验证。长期保存原始事件、90天回补、历史榜单和数据库备份时，优先采用推荐配置。

## 2. 云地域与网络

- [ ] 所选地域允许并能够稳定访问项目使用的 Binance API。
- [ ] 公网出口IP固定，且没有与其他高频 Binance 程序共享不可控出口。
- [ ] 从服务器直接访问 `https://fapi.binance.com`，不经过HTTP/SOCKS代理。
- [ ] 能持续接收 `wss://fstream.binance.com` WebSocket消息，而不只是完成握手。
- [ ] 出站允许 TCP 443、DNS和NTP。
- [ ] 入站仅开放管理员固定IP到 TCP 22。
- [ ] 不向公网开放 TCP 5432、4222、8222和8080。
- [ ] 监控页和数据库通过SSH隧道访问。

推荐安全组：

| 方向 | 协议/端口 | 来源或目标 | 规则 |
|---|---|---|---|
| 入站 | TCP 22 | 管理员固定CIDR | 允许 |
| 入站 | TCP 5432/4222/8222/8080 | 任意公网 | 拒绝 |
| 出站 | TCP 443 | 互联网 | 允许 |
| 出站 | UDP/TCP 53 | DNS服务器 | 允许 |
| 出站 | UDP 123 | NTP服务器 | 允许 |

## 3. 操作系统

- [ ] 使用仍受安全支持的 Ubuntu LTS x86_64。
- [ ] 主机名能够唯一标识环境，例如 `auto-trade-collector-prod-1`。
- [ ] 系统时区设为UTC。
- [ ] systemd-timesyncd或等效NTP服务已启用。
- [ ] 已安装安全更新并配置计划维护窗口。
- [ ] 创建独立普通部署用户，不直接使用root运行日常命令。
- [ ] 部署用户通过SSH密钥登录，关闭密码登录前已验证密钥可用。
- [ ] 部署用户加入 `docker` 组，并理解该组具有root等价权限。

## 4. 数据盘与文件系统

- [ ] 独立数据盘挂载到 `/data`。
- [ ] `/etc/fstab` 使用磁盘UUID并带 `nofail`，重启后自动挂载。
- [ ] Docker `data-root` 设置为 `/data/docker`，且在首次创建容器前完成。
- [ ] 文件系统建议使用 ext4 或 XFS。
- [ ] 数据盘可用空间长期保持20%以上。
- [ ] 云盘快照不能替代数据库逻辑备份；两者都要配置。

容量边界：

- NATS JetStream总文件配额为64GB。
- 应用流配额合计62GB，预留2GB服务器余量。
- PostgreSQL是长期权威存储，容量会持续增长。
- Docker镜像、构建缓存、容器日志和本地备份也占用数据盘。

建议告警阈值：

- 数据盘使用率达到70%：WARNING。
- 数据盘使用率达到85%：CRITICAL。
- inode使用率达到80%：WARNING。
- PostgreSQL或NATS写入延迟持续升高：WARNING。

## 5. Docker配置

- [ ] Docker Engine来自Docker官方仓库。
- [ ] Docker Compose v2和Buildx可用。
- [ ] Docker服务设置为开机启动。
- [ ] Docker日志启用大小和文件数限制。
- [ ] `live-restore` 已启用，Docker守护进程升级时尽量保持容器运行。

建议把以下配置合并进 `/etc/docker/daemon.json`，不要覆盖服务器已有的有效配置：

```json
{
  "data-root": "/data/docker",
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "10"
  }
}
```

## 6. 应用配置基线

- [ ] `ENVIRONMENT=PROD`，或明确使用 `TEST` 表示非生产数据环境。
- [ ] `NODE_ID` 在全部部署中唯一。
- [ ] PostgreSQL密码由 `openssl rand -hex 32` 独立生成。
- [ ] `.env` 权限为 `600`，不进入Git、不上传工单。
- [ ] PostgreSQL、NATS和监控UI继续绑定 `127.0.0.1`。
- [ ] `PROXY`、`ALL_PROXY`、`BINANCE_PROXY_URL`、`HTTP_PROXY`、`HTTPS_PROXY` 全部为空。
- [ ] `NO_PROXY=127.0.0.1,localhost,database,nats`。
- [ ] `WEBSOCKET_STREAMS_PER_CONNECTION=100`。
- [ ] `FILE_LOG_ENABLED=true`，保留14天应用日志。
- [ ] 90天扫描继续采用24小时历史窗口，避免单次请求突增。

推荐 `.env` 关键项：

```dotenv
ENVIRONMENT=PROD
SERVICE_NAME=auto-trade-collector
NODE_ID=cloud-collector-prod-1
SHARD_ID=0

POSTGRES_BIND_IP=127.0.0.1
NATS_URL=nats://127.0.0.1:4222
MONITOR_BIND_IP=127.0.0.1

PROXY=
ALL_PROXY=
BINANCE_PROXY_URL=
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=127.0.0.1,localhost,database,nats

WEBSOCKET_STREAMS_PER_CONNECTION=100
WEBSOCKET_RECONNECT_MAX_SECONDS=30
WEBSOCKET_RECEIVE_TIMEOUT_SECONDS=60
WEBSOCKET_MESSAGE_QUEUE_SIZE=4096
WEBSOCKET_KLINE_WORKERS_PER_CONNECTION=4

FILE_LOG_ENABLED=true
FILE_LOG_RETENTION_DAYS=14
```

## 7. 备份和恢复

- [ ] PostgreSQL每天至少一次逻辑备份。
- [ ] 备份加密复制到不同故障域的对象存储或另一台服务器。
- [ ] 至少保留7份日备份和4份周备份；按业务要求延长。
- [ ] 每季度至少执行一次恢复演练。
- [ ] 记录备份文件大小、校验和、开始时间、完成时间和恢复结果。
- [ ] NATS不是长期权威存储，不以NATS卷备份代替PostgreSQL备份。
- [ ] 云盘快照在数据库一致性边界内执行，或在快照前暂停写入。

## 8. 监控和验收指标

- [ ] 所有Compose常驻服务为 `Up`，有健康检查的服务为 `healthy`。
- [ ] Collector日志显示 `proxy_enabled=False`。
- [ ] 所有WebSocket分片连接成功，无持续idle/reconnect。
- [ ] Trade 1m、Mark 1m、Trade 5m近1小时WebSocket成功率均不低于99%。
- [ ] `missing=0`，REST兜底只偶发出现。
- [ ] 回补队列的小时净变化长期小于等于0。
- [ ] NATS没有 `503 insufficient resources`。
- [ ] PostgreSQL、NATS和数据盘容量均已接入告警。
- [ ] 连续运行24小时后再完成最终验收。
- [ ] 主机重启后服务自动恢复并重新连接。

## 9. 上线前签字项

| 项目 | 结果 | 证据/备注 |
|---|---|---|
| 云主机规格符合基线 | ☐ | |
| 安全组仅开放受限SSH | ☐ | |
| 数据盘和Docker data-root正确 | ☐ | |
| 系统UTC和NTP正常 | ☐ | |
| 五类代理变量均为空 | ☐ | |
| REST直连验证通过 | ☐ | |
| WebSocket持续收流验证通过 | ☐ | |
| 数据库迁移与校验通过 | ☐ | |
| NATS容量和流配置校验通过 | ☐ | |
| WebSocket成功率达到99% | ☐ | |
| 24小时稳定性验收通过 | ☐ | |
| 备份和恢复演练通过 | ☐ | |
