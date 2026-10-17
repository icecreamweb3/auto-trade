# Auto Trade 2.0 云服务器部署步骤

本文用于把完整采集链路部署到能够直连 Binance 的单台 Ubuntu 云服务器。机器规格与安全检查见 [`CLOUD_SERVER_CONFIGURATION_CHECKLIST.md`](CLOUD_SERVER_CONFIGURATION_CHECKLIST.md)。

部署目标：

```text
Binance REST/WebSocket（直连，无代理）
                  │
                  ▼
Collector ──► NATS JetStream ──► Market Writer ──► TimescaleDB
                  ▲                                      ▲
                  └──────────── Data Repair ─────────────┘
                                                         │
                                      Monitor API/UI（仅回环监听）
```

## 1. 部署变量

执行前确定以下值，文档中的占位符不要原样使用：

```text
<server-ip>       云服务器固定公网IP
<admin-cidr>      管理员出口CIDR，例如 203.0.113.10/32
<deploy-user>     普通部署用户
<repository-url>  Git仓库地址
<node-id>         唯一节点名，例如 cloud-collector-prod-1
```

默认项目目录为 `/opt/auto-trade`，数据盘挂载点为 `/data`。

## 2. 创建云主机和安全组

1. 按配置清单创建Ubuntu LTS x86_64服务器和独立SSD/NVMe数据盘。
2. 为服务器分配固定公网IPv4。
3. 安全组仅允许 `<admin-cidr>` 访问TCP 22。
4. 不开放5432、4222、8222和8080。
5. 允许出站TCP 443、DNS和NTP。

先通过SSH确认登录：

```bash
ssh <deploy-user>@<server-ip>
```

## 3. 初始化系统与数据盘

检查系统、磁盘和时间：

```bash
uname -a
lsblk -f
date
timedatectl status
```

以下格式化操作会清空目标磁盘。必须先用 `lsblk` 确认新数据盘的准确设备名，本文不提供可直接复制的格式化命令。

完成数据盘格式化后，将其挂载到 `/data`，并使用UUID写入 `/etc/fstab`。验收：

```bash
findmnt /data
df -h /data
sudo mount -a
```

创建Docker数据目录：

```bash
sudo install -d -m 0711 /data/docker
```

启用UTC和NTP：

```bash
sudo timedatectl set-timezone UTC
sudo timedatectl set-ntp true
timedatectl status
```

## 4. 安装Docker和主机工具

取得项目代码后可使用仓库脚本安装；如果此时尚未克隆仓库，也可以先把脚本单独安全传输到服务器并检查内容。

```bash
chmod +x scripts/setup_test_host_ubuntu.sh
./scripts/setup_test_host_ubuntu.sh
sudo apt-get install -y jq
```

脚本完成后注销并重新登录，使docker组生效：

```bash
exit
ssh <deploy-user>@<server-ip>
docker ps
docker compose version
```

在首次启动任何项目容器之前，把以下内容与现有 `/etc/docker/daemon.json` 合并：

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

校验并重启Docker：

```bash
sudo dockerd --validate --config-file=/etc/docker/daemon.json
sudo systemctl restart docker
docker info --format '{{.DockerRootDir}}'
```

输出必须是 `/data/docker`。

## 5. 加固SSH和主机防火墙

先验证SSH密钥登录，再禁用密码登录。错误修改SSH配置可能导致服务器失联，因此始终保留一个已连接会话完成验证。

Ubuntu UFW示例：

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <admin-cidr> to any port 22 proto tcp
sudo ufw enable
sudo ufw status verbose
```

云安全组与UFW必须同时满足限制；不要只配置其中一层。

## 6. 获取项目代码

```bash
sudo install -d -o "$(id -un)" -g "$(id -gn)" /opt/auto-trade
git clone <repository-url> /opt/auto-trade
cd /opt/auto-trade
git status --short
git rev-parse HEAD
```

部署提交必须明确记录，且 `git status --short` 应为空。

## 7. 创建无代理配置

```bash
cd /opt/auto-trade
cp .env.example .env
chmod 600 .env
openssl rand -hex 32
```

把随机值写入 `POSTGRES_PASSWORD`，并设置以下关键项：

```dotenv
ENVIRONMENT=PROD
SERVICE_NAME=auto-trade-collector
NODE_ID=<node-id>
SHARD_ID=0

POSTGRES_PASSWORD=<独立随机强密码>
POSTGRES_BIND_IP=127.0.0.1
POSTGRES_PORT=5432
MONITOR_BIND_IP=127.0.0.1
MONITOR_PORT=8080

BINANCE_USDM_BASE_URL=https://fapi.binance.com
BINANCE_USDM_WEBSOCKET_URL=wss://fstream.binance.com

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

GAP_SCAN_LOOKBACK_HOURS=2160
GAP_SCAN_RECENT_LOOKBACK_HOURS=24
GAP_SCAN_HISTORICAL_WINDOW_HOURS=24
GAP_SCAN_STATEMENT_TIMEOUT_SECONDS=45
```

宿主机登录环境也可能携带代理变量。部署前检查并清除：

```bash
env | grep -i proxy || true
unset PROXY ALL_PROXY BINANCE_PROXY_URL HTTP_PROXY HTTPS_PROXY
docker compose config --quiet
```

确认Compose最终配置没有非空代理地址。以下命令只显示变量是否为空，不输出密码：

```bash
docker compose config | grep -E 'PROXY|proxy'
```

## 8. 部署前直连验证

验证REST：

```bash
curl --fail --silent --show-error --max-time 10 \
  'https://fapi.binance.com/fapi/v1/time'
```

构建应用测试镜像：

```bash
docker build --target test -t auto-trade-test:local .
```

使用和Collector相同的Python/WebSocket依赖持续接收5条消息，并强制禁用代理：

```bash
docker run --rm -i --network host auto-trade-test:local python - <<'PY'
import asyncio
from websockets.asyncio.client import connect

URL = "wss://fstream.binance.com/stream?streams=btcusdt@kline_1m"

async def main() -> None:
    async with connect(
        URL,
        proxy=None,
        open_timeout=10,
        ping_interval=20,
        ping_timeout=20,
    ) as websocket:
        for index in range(5):
            message = await asyncio.wait_for(websocket.recv(), timeout=10)
            print("received", index + 1, "bytes", len(message))
    print("DIRECT_WEBSOCKET_OK")

asyncio.run(main())
PY
```

必须看到5条消息和 `DIRECT_WEBSOCKET_OK`。只完成握手但收不到持续消息不能通过验收。

## 9. 质量检查

```bash
make lint
make typecheck
make test
```

三项全部通过后再启动基础设施。

## 10. 启动数据库和NATS

```bash
make infra-up
docker compose ps database nats
```

等待两项均为 `healthy`，然后执行：

```bash
make db-migrate
make db-verify
make nats-init
make nats-verify
```

NATS校验应确认总文件配额64GB以及各流上限；出现 `503 insufficient resources` 时不要继续启动回补服务。

## 11. 新环境部署或数据迁移

### 11.1 全新数据库

全新环境可直接进入下一节。系统会从空数据库开始采集，并按配置扫描最近90天缺口；初始回补队列较大属于预期行为。

### 11.2 从旧测试机迁移现有数据库

迁移期间只能有一个Collector对外采集。建议先完成云服务器的直连验证和基础设施启动，再安排短暂停机窗口。

旧测试机：

```bash
cd /opt/auto-trade
docker compose --profile runtime stop collector data-repair market-writer
mkdir -p backups
docker compose exec -T database \
  pg_dump -U auto_trade_admin -d auto_trade -Fc \
  > "backups/auto_trade_cutover_$(date -u +%Y%m%dT%H%M%SZ).dump"
sha256sum backups/auto_trade_cutover_*.dump
```

安全传输备份文件到云服务器 `/opt/auto-trade/backups/`，核对SHA-256。云服务器保持Collector未启动，恢复数据库：

```bash
cd /opt/auto-trade
docker compose exec -T database sh -ec \
  'dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
docker compose exec -T database sh -ec \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner' \
  < backups/<cutover-backup>.dump
make db-migrate
make db-verify
```

恢复命令会替换目标数据库内容，只能在确认目标是新云服务器且备份校验通过后执行。NATS传输卷不迁移，长期数据以PostgreSQL为准。

## 12. 启动运行时服务

```bash
make runtime-up
docker compose --profile runtime ps
```

确认以下服务运行：

- `database`
- `nats`
- `market-writer`
- `collector`
- `data-repair`
- `monitor-api`
- `monitor-ui`

查看启动日志：

```bash
docker compose --profile runtime logs --since=10m --no-color \
  collector market-writer data-repair monitor-api
```

Collector日志必须显示：

- `proxy_enabled=False`
- 所有WebSocket分片建立连接
- 没有持续的 `idle`、`disconnected`、`queue saturated`
- 每分钟同步汇总成功率接近100%

## 13. WebSocket与数据完整性验收

先观察逐分钟日志：

```bash
docker compose logs --since=15m collector \
  | grep -E \
'starting Binance|WebSocket connected|WebSocket idle|WebSocket disconnected|reconnect scheduled|kline sync summary'
```

即时验收标准：

- Trade 1m每分钟成功率不低于99%。
- Mark 1m每分钟成功率不低于99%。
- Trade 5m每5分钟成功率不低于99%。
- 不持续依赖REST兜底。

通过SSH隧道访问监控页：

```bash
ssh -N -L 18080:127.0.0.1:8080 <deploy-user>@<server-ip>
```

本地浏览器打开 `http://127.0.0.1:18080`。也可在服务器查询：

```bash
curl -s http://127.0.0.1:8080/api/monitoring/overview \
  | jq '{websocket_sync, backfill, rest_usage, nats}'
```

近1小时最终验收：

- 三类 `websocket_sync.success_percent >= 99`。
- 三类 `missing = 0`。
- `rest_fallback` 仅偶发增长。
- 回补队列小时净变化持续小于等于0。

## 14. 切换完成与旧机处理

确认云服务器持续采集后：

1. 保持旧测试机Collector和Data Repair停止，避免双重请求Binance。
2. 不立即删除旧数据库和卷。
3. 保留旧机只读至少7天，直到云服务器完成24小时稳定性和备份验收。
4. 记录旧机停止时间、新机启动时间、Git提交和数据库备份校验和。

## 15. 重启恢复验收

```bash
sudo reboot
```

重新登录后：

```bash
cd /opt/auto-trade
docker compose --profile runtime ps
docker compose --profile runtime logs --since=10m --no-color
```

所有常驻服务应自动恢复，WebSocket应重新连接且 `proxy_enabled=False`。

## 16. 备份任务

创建本地备份：

```bash
cd /opt/auto-trade
mkdir -p backups
backup_file="backups/auto_trade_$(date -u +%Y%m%dT%H%M%SZ).dump"
docker compose exec -T database \
  pg_dump -U auto_trade_admin -d auto_trade -Fc > "$backup_file"
sha256sum "$backup_file" > "$backup_file.sha256"
docker compose exec -T database pg_restore --list < "$backup_file" | head
```

把备份及校验文件加密复制到不同故障域，并按配置清单执行保留和恢复演练。

## 17. 日常运维

状态与容量：

```bash
docker compose --profile runtime ps
df -h /data
docker system df
curl -s http://127.0.0.1:8222/healthz
```

异常日志：

```bash
docker compose --profile runtime logs --since=1h --no-color \
  collector market-writer data-repair \
  | grep -E 'ERROR|failed|429|418|rate limit|idle|disconnected|insufficient resources'
```

不要执行：

```text
docker compose down -v
docker volume rm auto-trade-postgres-data
docker volume rm auto-trade-nats-data
```

这些命令会删除持久数据。

## 18. 标准升级

升级前先备份并记录当前提交：

```bash
cd /opt/auto-trade
git status --short
git rev-parse HEAD
git pull --ff-only
docker build --target test -t auto-trade-test:local .
make lint
make typecheck
make test
make db-migrate
docker compose --profile runtime up -d --build --force-recreate \
  market-writer collector data-repair monitor-api monitor-ui
```

升级后重新执行WebSocket、覆盖率、回补队列和24小时稳定性验收。
