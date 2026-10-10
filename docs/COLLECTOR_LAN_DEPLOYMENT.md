# Auto Trade 2.0 采集系统局域网部署手册

本文用于将采集系统部署到一台长期运行的 Linux 局域网测试机。本机继续用于开发策略分析后台、回测/回放引擎和桌面数据分析终端。

## 1. 部署目标与边界

测试机运行完整采集链路：

```text
Binance Futures
      │ REST + WebSocket
      ▼
Collector ──► NATS JetStream ──► Market Writer ──► PostgreSQL/TimescaleDB
      │                                      ▲
      └──────── Data Repair ─────────────────┘
                                                   │
                                      局域网只读查询│
                                                   ▼
                                      本机策略分析后台
                                                   │
                                                   ▼
                                      回测/回放及桌面终端
```

部署约束：

- Binance 行情只由测试机采集服务请求，分析平台不重复请求 Binance。
- 所有业务时间、日界线、调度时间均使用 UTC。
- 主数据保存在 PostgreSQL/TimescaleDB；NATS 用于可靠事件传递，不代替数据库。
- 分析终端不保存数据库管理员凭据，通过分析后台使用只读账户查询。
- 当前部署是单机测试环境，保留以后增加数据库备份、只读副本和多机冗余的能力。

## 2. 服务和端口

| 服务 | Compose 服务名 | 默认端口 | 默认暴露范围 | 作用 |
|---|---|---:|---|---|
| PostgreSQL/TimescaleDB | `database` | 5432 | `127.0.0.1` | 行情和审计数据主存储 |
| NATS JetStream | `nats` | 4222 | `127.0.0.1` | 内部事件流 |
| NATS Monitor | `nats` | 8222 | `127.0.0.1` | 健康检查 |
| Market Writer | `market-writer` | 无外部端口 | Compose内部 | 消费事件并幂等落库 |
| Collector | `collector` | 无监听端口 | 主机网络 | 行情采集和实时事件发布 |
| Data Repair | `data-repair` | 无监听端口 | 主机网络 | 缺口检测和REST回补 |

不要在路由器上把5432、4222或8222映射到互联网。

## 3. 测试机准备

测试环境支持以下两类主机：

- Mac mini：适合短期验证和开发测试，使用Docker Desktop。
- Ubuntu：更接近未来云服务器生产环境，使用Docker Engine和Compose v2插件。

建议使用长期在线的主机、SSD以及有线网络。仅 `ticker_minutes` 按约500个标的一年估算已约49GB，完整数据还包括K线、OI、原始事件、索引、WAL、备份及10GB的NATS上限，因此应持续监控磁盘并预留明显余量。

需要安装：

- Docker Engine
- Docker Compose v2插件
- Git（使用Git交付时）
- GNU Make
- OpenSSL
- SSH Server（推荐用于数据库隧道）

### 3.1 Mac mini / macOS自动准备

macOS脚本使用Homebrew安装或检查Git、GNU Make、OpenSSL 3和Docker Desktop。macOS已经内置OpenSSH Server，只有显式传入 `--enable-ssh` 时脚本才会开启Remote Login。

首次运行前需要安装Apple Command Line Tools和Homebrew。脚本检测到缺失时会给出提示并安全退出，不会自动执行远程安装脚本。

```bash
chmod +x scripts/setup_test_host_macos.sh
./scripts/setup_test_host_macos.sh --enable-ssh
```

不希望脚本开启SSH时去掉参数：

```bash
./scripts/setup_test_host_macos.sh
```

脚本执行后仍需在Docker Desktop中手动完成：

1. `Settings > General`：开启登录时启动Docker Desktop。
2. `Settings > Resources > Network`：开启Host Networking。
3. `Settings > Resources > Advanced`：为Docker分配足够的内存和磁盘。

macOS还需要在系统能源设置中禁止显示器关闭后自动睡眠，并配置断电恢复自动启动。Docker Desktop的许可确认和系统安全提示必须由机器所有者亲自完成，脚本不会绕过。

如果出现 `docker: unknown command: docker compose`，说明当前Docker CLI没有发现Docker Desktop自带的Compose插件。重新执行Mac脚本即可为当前用户建立Compose和Buildx插件链接：

```bash
./scripts/setup_test_host_macos.sh
docker compose version
docker buildx version
```

### 3.2 Ubuntu自动准备

Ubuntu脚本使用Docker官方APT仓库安装Docker Engine、Compose v2、Buildx、Git、GNU Make、OpenSSL和OpenSSH Server，并启用Docker、SSH、NTP与UTC时区：

```bash
chmod +x scripts/setup_test_host_ubuntu.sh
./scripts/setup_test_host_ubuntu.sh
```

脚本不会自动删除已有Docker、Podman、containerd或runc包。检测到与Docker CE冲突的包时会列出包名并退出，避免破坏机器上已有容器。安装完成后，如果当前用户刚加入 `docker` 用户组，需要注销并重新登录。

两个脚本都支持查看说明：

```bash
./scripts/setup_test_host_macos.sh --help
./scripts/setup_test_host_ubuntu.sh --help
```

通用检查：

```bash
docker --version
docker compose version
git --version
make --version
docker ps
```

macOS时间同步检查：

```bash
date
date -u
sudo /usr/sbin/systemsetup -getusingnetworktime
sudo /usr/sbin/systemsetup -getnetworktimeserver
sudo /usr/sbin/systemsetup -gettimezone
```

macOS开启网络自动校时：

```bash
sudo /usr/sbin/systemsetup -setusingnetworktime on
```

Mac主机可以继续显示北京时间；采集容器已经显式使用UTC，不需要为了容器修改macOS显示时区。

Ubuntu时间同步检查和设置：

```bash
timedatectl status
sudo timedatectl set-ntp true
sudo timedatectl set-timezone UTC
```

`timedatectl` 是Linux systemd命令，macOS不存在该命令。

确认当前用户可以执行 `docker ps`。如果需要把项目放在 `/opt`，先在测试机创建可写目录：

```bash
sudo install -d -o "$(id -un)" -g "$(id -gn)" /opt/auto-trade
```

## 4. 交付项目代码

### 4.1 推荐：Git交付

先在开发机确认当前采集版本的所有文件均已提交并推送，再在测试机执行：

```bash
git clone <repository-url> auto-trade
cd auto-trade
git status --short
```

`git status --short` 在部署版本上应为空。

### 4.2 临时方式：完整目录复制

当前版本还未提交到远端仓库时，可以从开发机复制，但不要复制本机密码和运行数据：

```bash
rsync -av \
  --exclude '.git' \
  --exclude '.env' \
  --exclude 'artifacts' \
  --exclude 'backups' \
  /home/will/project/auto-trade/ <test-user>@<test-host>:/opt/auto-trade/
```

## 5. 创建部署配置

在测试机项目目录执行：

```bash
cd /opt/auto-trade
cp .env.example .env
chmod 600 .env
openssl rand -hex 32
```

将最后一条命令生成的随机值写入 `.env` 的 `POSTGRES_PASSWORD`，并至少修改以下字段：

```dotenv
ENVIRONMENT=TEST
SERVICE_NAME=auto-trade-collector
NODE_ID=collector-test-1
SHARD_ID=0

POSTGRES_PASSWORD=<独立随机强密码>
POSTGRES_BIND_IP=127.0.0.1

HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=127.0.0.1,localhost
```

说明：

- 测试机能够直接访问 Binance 时，代理保持为空。
- `NODE_ID` 必须能唯一标识这台机器。
- 推荐保持 `POSTGRES_BIND_IP=127.0.0.1`，从开发机通过SSH隧道访问。
- 不要把 `.env` 提交到Git或发送到聊天记录。
- 不要复用开发机现有数据库密码。

校验Compose配置：

```bash
docker compose config --quiet
```

命令无输出且返回码为0表示配置语法有效。

## 6. 首次启动基础设施

启动数据库和NATS：

```bash
make infra-up
docker compose ps database nats
```

两项都应显示 `healthy`。随后执行数据库迁移与校验：

```bash
make db-migrate
make db-verify
```

当前迁移脚本可重复执行；再次执行时出现 `already exists` 或 `skipping` 提示是正常的。校验应确认：

- TimescaleDB 扩展已安装。
- V2业务表已经建立。
- `core.schema_migrations` 中迁移状态为成功。

## 7. 部署前质量检查

首次部署或升级采集逻辑后，在测试机执行：

```bash
docker build --target test -t auto-trade-test:local .
make lint
make typecheck
make test
```

三项全部通过后再启动常驻服务。

## 8. 启动采集系统

测试镜像构建完成后，初始化并校验NATS JetStream：

```bash
make nats-init
make nats-verify
```

然后启动常驻采集服务：

```bash
make runtime-up
docker compose --profile runtime ps
```

持续观察启动日志：

```bash
make runtime-logs
```

预期看到：

- 合约目录同步完成，仅包含正常交易的USDT本位永续合约。
- WebSocket分片全部建立连接。
- 每分钟Ticker快照持续发布。
- Trade 1m、Trade 5m闭合K线持续发布。
- `!markPrice@arr@1s` 持续更新并按UTC分钟生成Mark 1m。
- 每5分钟OI完成全标的采集。
- `data-repair` 持续消费缺口队列。
- 没有持续出现 `429`、`418`、数据库连接失败或JetStream发布失败。

服务使用 `restart: unless-stopped`，测试机重启后会自动恢复。首次验收应主动重启一次主机并确认服务恢复：

```bash
sudo reboot
```

重新登录后：

```bash
cd /opt/auto-trade
docker compose --profile runtime ps
docker compose --profile runtime logs --since=10m --no-color
```

## 9. 数据完整性验收

进入数据库：

```bash
make db-shell
```

### 9.1 最新K线覆盖率

```sql
WITH latest AS (
    SELECT price_type, interval_seconds, max(open_time) AS open_time
    FROM market.klines
    WHERE is_current
    GROUP BY 1, 2
)
SELECT
    k.price_type,
    k.interval_seconds,
    l.open_time AT TIME ZONE 'UTC' AS open_time_utc,
    count(DISTINCT k.instrument_id) AS symbols,
    count(DISTINCT k.instrument_id) FILTER (
        WHERE k.source = 'WEBSOCKET'
    ) AS websocket_symbols,
    max(k.collected_at) - min(k.collected_at) AS write_span
FROM market.klines k
JOIN latest l USING (price_type, interval_seconds, open_time)
WHERE k.is_current
GROUP BY 1, 2, 3
ORDER BY 2, 1;
```

当前应至少出现：

- `TRADE / 60`
- `MARK / 60`
- `TRADE / 300`

每组标的数量应与当天 `TRADING` 合约数量一致。

### 9.2 最新Ticker完整率

```sql
WITH latest AS (
    SELECT max(minute_time) AS minute_time
    FROM market.ticker_minutes
)
SELECT
    l.minute_time AT TIME ZONE 'UTC' AS minute_time_utc,
    count(*) AS symbols,
    count(*) FILTER (WHERE t.source = 'WEBSOCKET') AS websocket_symbols,
    count(*) FILTER (WHERE t.mark_price IS NOT NULL) AS with_mark,
    count(*) FILTER (WHERE t.price_change_24h IS NOT NULL) AS with_24h_change
FROM market.ticker_minutes t
JOIN latest l USING (minute_time)
GROUP BY l.minute_time;
```

四个数量应与当前正常交易标的总数一致。

### 9.3 回补队列

```sql
SELECT data_type, status, count(*)
FROM market.backfill_jobs
GROUP BY 1, 2
ORDER BY 1, 2;
```

首次启动会发现历史或停机缺口，`PENDING` 短期增加是正常的。连续观察时应满足：

- `SUCCEEDED` 持续增加。
- 首轮缺口发现完成后，`PENDING` 总体下降。
- 没有长期停留的 `RUNNING`。
- `FAILED` 不持续增加。

### 9.4 24小时观察期

测试机至少连续运行24小时，再确认：

- 每分钟数据没有持续断层。
- UTC 16:00合约目录和交易规则完成全量更新。
- WebSocket断线能够自动重连。
- Binance返回的IP权重保持在安全范围。
- 没有持续的 `429/418`。
- 数据库、NATS和Docker日志的磁盘增长符合预期。

## 10. 分析终端访问数据库

### 10.1 推荐方式：SSH隧道

数据库继续只绑定测试机回环地址。在开发机建立隧道：

```bash
ssh -N -L 15432:127.0.0.1:5432 <test-user>@<test-host>
```

DBeaver或分析后台连接参数：

```text
Host: 127.0.0.1
Port: 15432
Database: auto_trade
User: auto_trade_analysis_reader
```

SSH隧道断开只影响分析查询，不影响测试机采集。

### 10.2 创建只读分析账户

在测试机执行 `make db-shell`，然后执行：

```sql
CREATE ROLE auto_trade_analysis_reader LOGIN;
\password auto_trade_analysis_reader

GRANT CONNECT ON DATABASE auto_trade TO auto_trade_analysis_reader;
GRANT USAGE ON SCHEMA core, config, market, trade, analysis, audit
TO auto_trade_analysis_reader;

GRANT SELECT ON ALL TABLES IN SCHEMA core, config, market, trade, analysis, audit
TO auto_trade_analysis_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, config, market, trade, analysis, audit
GRANT SELECT ON TABLES TO auto_trade_analysis_reader;

ALTER ROLE auto_trade_analysis_reader SET default_transaction_read_only = on;
ALTER ROLE auto_trade_analysis_reader SET statement_timeout = '10min';
```

分析桌面程序不要直接使用该账户；由本机分析后台持有凭据，桌面程序只调用后台API。

### 10.3 可选方式：局域网直接连接

只有明确需要长期直连时才采用。将测试机 `.env` 设置为测试机的固定局域网IP：

```dotenv
POSTGRES_BIND_IP=192.168.x.x
```

如果采集服务已经运行，先停止运行时服务，再重建数据库端口映射并恢复：

```bash
make runtime-down
docker compose up -d --force-recreate database
make runtime-up
```

同时必须做到：

- 测试机使用固定局域网IP或DHCP保留地址。
- 主机防火墙仅允许开发机IP访问TCP 5432。
- 使用只读分析账户，不使用 `auto_trade_admin`。
- 路由器不得把5432映射到公网。
- 不需要从局域网访问NATS时，4222和8222继续保持回环绑定。

局域网直接连接默认不提供链路加密；需要更高安全性时继续使用SSH隧道或VPN。

## 11. 日常运维

查看状态：

```bash
docker compose --profile runtime ps
```

查看最近日志：

```bash
docker compose --profile runtime logs --since=30m --no-color \
  collector market-writer data-repair
```

检查限流和失败：

```bash
docker compose --profile runtime logs --since=1h --no-color \
  collector data-repair | grep -E '429|418|rate limit|failed|ERROR'
```

查看磁盘：

```bash
df -h
docker system df
docker volume ls
```

停止采集服务但保留数据库和NATS：

```bash
make runtime-down
```

恢复：

```bash
make runtime-up
```

不要执行 `docker compose down -v`，该命令会删除数据库和NATS持久化卷。

## 12. 升级流程

升级前确认当前版本和工作区状态：

```bash
git status --short
git rev-parse HEAD
```

标准升级流程：

```bash
git pull --ff-only
docker build --target test -t auto-trade-test:local .
make lint
make typecheck
make test
docker compose --profile runtime build market-writer collector
make runtime-down
make db-migrate
make runtime-up
```

完成后重新执行服务状态、日志和最新数据覆盖率检查。数据库迁移执行前应先完成备份。

## 13. 数据库备份

在测试机项目目录创建备份：

```bash
mkdir -p backups
docker compose exec -T database \
  pg_dump -U auto_trade_admin -d auto_trade -Fc \
  > "backups/auto_trade_$(date -u +%Y%m%dT%H%M%SZ).dump"
```

使用数据库容器中的工具检查备份目录可读取：

```bash
docker compose exec -T database pg_restore --list \
  < backups/auto_trade_<UTC时间>.dump | head
```

注意：

- 本地单份备份不等于可靠备份，应定期复制到另一块磁盘或另一台机器。
- 恢复演练完成前，不能认为备份方案已经验证。
- NATS中的事件是传输状态，长期历史数据以PostgreSQL为准。

## 14. 故障排查

### Mac提示unknown command: docker compose

Docker Desktop本身包含Compose；该错误通常表示终端选择了旧Docker CLI，或用户级插件链接没有正确建立。先运行：

```bash
type -a docker
ls -l /Applications/Docker.app/Contents/Resources/cli-plugins/docker-compose
./scripts/setup_test_host_macos.sh
docker compose version
```

修复脚本会把Docker Desktop内置的Compose和Buildx注册到 `${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins`，不会下载来源不明的独立Compose文件。如果Docker Desktop内置插件本身缺失，脚本会停止并提示使用Docker Desktop的Repair功能或重新安装。

### 服务没有启动

```bash
docker compose --profile runtime ps
docker compose --profile runtime logs --tail=200 --no-color
```

### Binance连接失败

检查测试机能否访问REST与WebSocket；确认代理变量为空或配置正确；确认系统时间同步。不要在连接失败时提高REST并发。

### 出现429或418

- 确认同一公网出口下没有旧版交易机器人或其他高频Binance程序。
- 保留当前自动冷却，不要反复重启服务。
- 查看日志中的 `x-mbx-used-weight-1m`。
- 等待 Binance 限制解除后再观察回补队列恢复。

### 回补队列增加

首次运行、停机后恢复或重新扫描时会先发现缺口，因此队列可能先增加。判断是否异常应观察多个周期的趋势，而不是单次总数。

### 数据库无法从开发机连接

- SSH方式：确认隧道进程仍在运行以及本地15432端口未被占用。
- 直连方式：确认 `POSTGRES_BIND_IP` 是测试机实际局域网IP、端口映射已经重建、防火墙允许开发机IP。
- 确认使用只读账户及正确数据库名。

### 磁盘空间不足

先停止采集服务，保留数据库：

```bash
make runtime-down
```

不要直接删除Docker Volume或数据库目录。先确认是数据库、NATS还是Docker日志占用，再制定可恢复的清理或扩容方案。

## 15. 测试部署验收标准

满足以下条件后，可认为局域网测试机部署完成：

- 数据库与NATS健康检查通过。
- Collector、Market Writer、Data Repair持续运行。
- 当前全部正常交易USDT永续合约均有Trade 1m、Mark 1m和Trade 5m数据。
- 分钟Ticker包含Mark Price和24hChange。
- OI按5分钟持续更新。
- 回补队列总体收敛且没有持续失败。
- 连续24小时没有持续限流、写入异常或静默断流。
- 主机重启后服务自动恢复。
- 分析后台可通过只读账户访问数据。
- 未向公网开放数据库或NATS端口。
- 已完成至少一次数据库备份和可读性检查。
