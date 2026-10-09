# 交易机器人 2.0 实施计划与技术选型

> 基线：`TRADING_BOT_2_0_REQUIREMENTS.md` Draft 0.276
>
> 文档性质：实施计划，不新增或修改业务需求
>
> 估算口径：2 名后端/交易工程师、1 名数据/回测工程师、1 名前端桌面工程师（可兼职）、1 名测试/运维工程师（可兼职）

## 1. 技术选型

| 范围 | 选型 | 用途与选择理由 |
|---|---|---|
| 主要语言 | Python 3.12 | 延续现有策略资产；异步网络、数据分析与回测生态完整；交易逻辑可在实盘和回测中复用 |
| API/管理后台 | FastAPI + Pydantic v2 + Uvicorn | 提供分析、回放、配置发布和只读生产数据 API；强类型事件与接口契约 |
| 异步任务 | asyncio + AnyIO | Binance WebSocket/REST、JetStream 消费和订单状态机均使用非阻塞执行 |
| Binance 接入 | 官方 REST/WebSocket 协议适配器；HTTPX + websockets | 在内部建立独立 exchange adapter，避免业务层绑定第三方 SDK 数据模型；公共行情只由采集网关访问一次 |
| 持久事件流 | NATS JetStream + nats.py | 满足已确认的发布确认、持久消费者、位点、重放、DLQ 和未来多节点扩展要求 |
| ORM/迁移 | SQLAlchemy 2.x + Alembic | 事务表使用 ORM，批量时序写入使用 PostgreSQL 原生批量接口；Schema 迁移走独立 one-shot job |
| 中心数据库 | PostgreSQL 16 + TimescaleDB 2.x | PostgreSQL 处理订单、版本、审计事务；TimescaleDB 处理全市场 1m/5m 时序、压缩和时间范围读取；不引入第二套数据库一致性问题 |
| 数据计算 | Polars + NumPy；Pandas 仅作兼容 | Polars 用于大规模列式回测和因子计算；策略核心保持纯 Python/NumPy 可确定性执行 |
| 回测并行 | 独立 worker 进程 + PostgreSQL 任务表 | 首期严格限制一个大型任务；不额外引入 Celery/Redis，减少运行组件；后续可替换为分布式调度器 |
| 桌面端 | PySide6 + QtWebEngine/Plotly | Python 单栈桌面端，通过 FastAPI 访问，不直连数据库；适合参数表、回放控制和交互图表 |
| 可观测性 | structlog + OpenTelemetry + Prometheus + Grafana + Loki | 统一事件 ID、snapshot ID、order intent ID；覆盖延迟、积压、数据缺口、交易与安全门禁 |
| 测试 | pytest + pytest-asyncio + Hypothesis + Testcontainers | 单元、性质、契约、数据库迁移、NATS、故障注入及确定性回放测试 |
| 部署 | Docker Compose + systemd + Alembic one-shot migration | 符合首期双服务器、各环境单节点及容器持久化要求；为未来多节点保留 node/shard/epoch 字段 |
| 安全 | mTLS、NATS Subject ACL、数据库最小权限、外部 Secret Store | API Secret 不入业务库；实盘、采集、分析、迁移、备份身份分离 |

### 1.1 为什么 2.0 不继续使用普通 MySQL 表

1.0 代码和表结构以 MySQL 为主，但 2.0 不迁移历史数据、也不与 1.0 共用可写业务表。全量 USDT 永续标的每分钟数据在 12 个月尺度会形成高行数时序数据；TimescaleDB 能在不拆分事务数据库的情况下提供 hypertable、时间分块、压缩和按 ticker/time 的高效扫描。订单、风控预留、P0 安全状态和 outbox 仍由 PostgreSQL 原子事务保证。

这项选型不改变已确认的数据流：实时数据先得到 JetStream 持久化确认，实时决策与数据库写入并行；只有下单前的决策意图、风险预留和幂等键必须同步提交数据库。

## 2. 服务边界

| 服务 | 部署位置 | 核心职责 | 禁止事项 |
|---|---|---|---|
| collector-gateway | 实盘服务器 | Binance 公共数据唯一入口、标准化、事件 ID、发布确认、REST 回补 | 不做策略判断，不直接下单 |
| market-writer | 实盘服务器 | 幂等落库、缺口检测、质量状态、5m 及高周期构建 | 不触发追溯实盘交易 |
| decision-engine | 实盘服务器 | 构造不可变 snapshot，运行信号层、市场风控层、JEV、评分 | 不临时重复请求 Binance 决策数据 |
| account-coordinator | 实盘服务器 | 每子账户串行队列、账户硬风控、风险预留、轮换和退出协调 | 不允许一个子账户并行执行两个策略 |
| order-executor | 实盘服务器 | 幂等订单意图、规则取整、下单、确认、保护单、对账 | 不接受非生产或过期/未知安全 epoch 的开仓意图 |
| safety/outbox | 实盘服务器 | P0 锁存、safety_epoch、事务 outbox、告警 | 消息故障不得自动解除 P0 |
| analysis-api | 回测服务器 | 数据集锁定、实验管理、只读生产事实、桌面 API | 不持有 Binance 实盘交易密钥 |
| backtest-worker | 回测服务器 | 回放、因子/风险/退出独立组合、样本外评估、指标计算 | 不修改生产事实或实盘发布版本 |
| desktop | 用户桌面 | 实验、回放、对比、审批界面 | 不直连中心数据库 |

## 3. 分阶段实施表

| 阶段 | 周期 | 主要工作 | 交付物 | 完成标准/关口 |
|---|---:|---|---|---|
| P0 基线冻结与原型验证 | 第 1–2 周 | 冻结需求映射；验证 PostgreSQL/TimescaleDB 写入量、压缩率、12 个月区间扫描；核对 Binance 历史归档覆盖 | ADR、容量报告、数据字典 v1、PoC | 峰值写入和回测读取不突破需求延迟/资源水位；关键字段均有来源和单位 |
| P1 工程骨架与契约 | 第 2–4 周 | monorepo/service 结构；Pydantic 事件模型；事件版本、幂等键、错误码；Compose/CI/迁移任务 | 可启动开发环境、事件契约测试、首版迁移 | 当前和前一事件版本兼容；迁移可重复验证且业务容器不自行改表 |
| P2 数据采集与落库 | 第 4–8 周 | ticker/rules 16:00 刷新；1m ticker+24hChange；5m K线/OI/费率；23:55 排行；JetStream 双消费者；缺口检测与回补 | collector、market-writer、覆盖审计 | 同一实时数据不重复请求；重放不重复落库；决策快照 15 秒内就绪率达到需求 |
| P3 账户事实与交易执行 | 第 7–11 周 | 子账户、账户快照、订单意图、风险预留、订单/成交/持仓生命周期、保护单、对账、外部变更识别 | account-coordinator、executor、reconciler | 重启/重复事件/未知订单不重复下单；成交与 Binance 对账；无保护仓位触发 P0 |
| P4 分层决策与 baseline_v1 | 第 10–14 周 | 连续阳线统一策略模型；信号、市场风控、账户风控、执行、退出分别版本化；三根 K 线保护期；JEV shadow 日志 | strategy runtime、版本包、逐层决策日志 | 相同 snapshot+版本得到相同结果；1.0 基线逐信号/退出回放差异均被解释和批准 |
| P5 安全、恢复与可观测性 | 第 12–16 周 | P0 状态+safety_epoch+outbox 原子事务；限流、断流、DB/NATS 故障；指标、日志、告警、备份恢复 | 安全状态机、仪表盘、Runbook、恢复演练报告 | 满足已确认 RPO/RTO；故障演练无重复开仓、无静默裸仓；恢复先对账后开仓 |
| P6 回测/回放内核 | 第 14–19 周 | 数据集快照、初始化区、时间顺序仿真、成交/手续费/资金费、账户组合回放、因子/风控/退出插件 | 确定性回测引擎、基线结果 | 同一输入重复运行哈希与结果一致；无未来数据；实盘与回放共享同一策略规则代码 |
| P7 分析 API 与桌面端 | 第 18–22 周 | 参数实验、Walk-forward/样本外、Precision@K、MFE/MAE、兑现率、超级标的、图表与对比审批 | analysis-api、桌面安装包、报告模板 | 桌面不直连 DB；指标逐笔可追溯；候选只生成不可变发布包，不直接改实盘 |
| P8 联调与影子运行 | 第 22–24 周 | 端到端回放、Testnet、JEV shadow、限流/压力/安全测试、操作培训 | 验收报告、发布清单 | P0/P1 缺陷清零；数据完整率、延迟、事件积压及数据库水位达标 |
| P9 单账户灰度 | 不少于 14 天且 50 笔平仓 | 15 USDT 固定名义灰度；增强监控；与批准基线比较 | 灰度复盘和晋级决定 | 同时满足时间和样本门槛；触发既定停止条件则回退并人工复核 |
| P10 正式运行与优化 | 灰度通过后 | 切换批准的 30 USDT 正式版本；持续数据质量和策略研究 | 正式发布、月度 SLO/策略报告 | 只发布经过样本外验证和人工批准的不可变版本；退出参数仍由回测确定 |

预计首个可灰度版本为 24 周左右；灰度观察期不计入开发周期。若人员少于上述假设，应保持阶段关口不变并顺延周期，不应通过合并安全与回测验收来压缩。

## 4. 数据库设计原则

- 使用 `core`、`config`、`market`、`trade`、`analysis`、`audit` 六个 Schema 做权限边界。
- 所有业务时间用 `TIMESTAMPTZ` 存储，连接会话强制 UTC；交易所时间与采集时间分别保存。
- 价格、数量、金额、费率使用 `NUMERIC`，禁止 `FLOAT` 进入交易事实。
- 市场事实使用确定性业务键和 payload hash 幂等；原始载荷、标准化记录和决策 snapshot 均可相互追溯。
- 策略、市场风控、账户风控、执行和退出配置均为不可变版本；发布包只引用已批准版本。
- API 密钥仅保存 `credential_ref`，不保存 key/secret 明文或密文内容。
- `trade.safety_states`、`trade.outbox_events` 与业务变更放在同一事务；发布动作发生在提交之后。
- `analysis` 只引用锁定的数据集版本和实盘事实，不修改 `market/trade/config/audit`。
- 具体退出参数不提供默认值；数据库仅提供版本模型，`exit_baseline_v1` 须由 1.0 实际生效配置事实冻结后导入。

## 5. 数据库脚本执行方式

初始化脚本：[database/v2/001_initial_schema.sql](../../database/v2/001_initial_schema.sql)

前置条件：PostgreSQL 16、TimescaleDB、具有建库对象权限的 migration 用户。脚本只创建 Schema、表、索引、hypertable、触发器、权限组和固定系统参数，不创建带密码的登录账号。

```bash
psql --set=ON_ERROR_STOP=1 --dbname=trading_bot_v2 \
  --file=database/v2/001_initial_schema.sql
```

生产环境必须由一次性 migration 容器执行，并使用 PostgreSQL advisory lock；不得由多个业务服务并发运行此文件。实际登录用户由 Secret Store/部署系统创建，再加入脚本创建的 NOLOGIN 权限组。

## 6. 首轮验收清单

- 数据库脚本在空库执行成功，再次执行不会破坏已有数据。
- 1m、5m、OI、资金费率和排行的唯一键能拦截重放重复数据。
- 一个决策可追溯到 snapshot、原始事件、策略版本、账户快照、风险判定、订单意图、成交和完整持仓生命周期。
- P0 状态、递增 epoch 和 outbox 可在单事务测试中验证原子性。
- 回测账号无法更新或删除生产事实，只能写 `analysis`。
- 利润兑现率只对完整关闭且数据完整的生命周期生成；`NO_POSITIVE_MFE`、`PROFIT_TO_LOSS` 和异常值均可明确表达。
- 数据集版本包含截止时间、覆盖状态和内容哈希；运行中的新增行情不改变已开始实验。
- 未写入任何未经回测确认的退出参数。
