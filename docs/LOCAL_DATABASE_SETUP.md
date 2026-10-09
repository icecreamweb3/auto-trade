# Auto Trade 本地数据库环境

本地开发数据库采用 PostgreSQL 16 + TimescaleDB，通过 Docker Compose 运行。数据库只绑定到 `127.0.0.1`，不会直接暴露到局域网或公网。

当前本地验证版本为 PostgreSQL 16.15 + TimescaleDB 2.30.1；Compose 使用固定版本标签，正式云部署还应固定经过验收的镜像摘要。

## 文件说明

- `compose.yaml`：本地数据库和一次性迁移任务。
- `.env`：本地实际连接参数，不提交 Git。
- `.env.example`：环境变量模板。
- `database/001_initial_schema.sql`：V2 初始数据库结构。
- Docker volume `auto-trade-postgres-data`：数据库持久化数据。

## 启动与验证

首次启动时，TimescaleDB 官方镜像会创建数据库，并自动执行 `database/001_initial_schema.sql`。

```bash
make db-up
make db-status
make db-verify
```

如果终端可以联网但 Docker 拉取镜像出现 `registry-1.docker.io` 超时，通常是 Docker 守护进程没有继承终端代理。确认当前没有不应中断的容器后，由本机管理员执行：

```bash
sudo --preserve-env=HTTP_PROXY,HTTPS_PROXY,NO_PROXY \
  ./scripts/configure-docker-proxy.sh
make db-up
```

脚本会先备份 `/etc/docker/daemon.json`、合并代理配置、验证 JSON，再重启 Docker。代理地址可能包含凭证，因此修改后的配置权限为 `0600`，不得提交到项目。

进入数据库：

```bash
make db-shell
```

查看日志：

```bash
make db-logs
```

停止服务但保留数据：

```bash
make db-down
```

## 数据库迁移

数据库结构变更由独立的一次性迁移任务执行，业务服务不得在启动时自行修改 Schema：

```bash
make db-migrate
```

当前 `001_initial_schema.sql` 具备基础幂等保护。后续变更应新增顺序迁移文件并交由 Alembic 管理，不应直接修改已经进入共享环境的历史迁移。

## 重要说明

- 修改初始化 SQL 不会自动作用于已经存在的 Docker volume，应通过新迁移应用变更。
- `docker compose down` 会保留数据；增加 `--volumes` 会永久删除本地数据库，请只在明确需要重建空库时使用。
- `.env` 中只保存本地开发密码。生产环境使用 Secret Store，不复制本地密码。
- API Key、Binance Secret 和其他交易凭证不得写入数据库初始化文件或 `.env.example`。

## 云服务器部署前调整

本地 Compose 是开发基线，不应原样作为公网部署配置。部署云服务器时至少完成：

1. 将数据库端口从宿主机发布配置中移除，只允许应用私网访问。
2. 将镜像从可变标签固定为经过测试的版本及镜像摘要。
3. 分别创建迁移、采集、交易、分析只读和备份登录用户，并继承数据库中的最小权限组。
4. 使用云 Secret Manager 或受保护的 Docker Secret 注入密码和证书。
5. 启用 TLS、加密磁盘、每日备份及连续 WAL 归档，并配置异机备份。
6. 接入数据库容量、连接数、慢查询、锁等待、复制/WAL 和备份恢复监控。
7. 在上线前执行空库迁移、升级迁移、备份恢复和 Binance 对账演练。
