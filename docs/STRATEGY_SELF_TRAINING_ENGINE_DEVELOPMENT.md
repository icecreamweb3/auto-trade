# 策略自训练引擎开发文档

**版本：** 0.1  
**依据：** `STRATEGY_SELF_TRAINING_ENGINE.md`（Draft 0.2，最近修订 2026-10-31）  
**依据内容哈希：** `sha256=699bc01ff0d47f9c44c65e72ce24bdd0743d605c57da23264eed41259b4f2d0e`（文档更新后须重新计算）  
**文档状态：** 开发设计；结构已确认，具体数值以配置版本和待确认问题为准  
**范围：** 模型 A 机会发现、模型 B 退出训练、组合仿真、实验治理、隔离验证/测试和审计；不自动发布实盘

## 1. 文档目标与实施边界

本文将设计方案转换为可执行的工程任务、服务边界、数据库实体、接口契约和测试要求。它不是对原方案的重新决策；发生冲突时，以原方案中当前有效决策、Q 项和验收原则为准。

第一阶段必须支持：

- 固定 V2 基线、历史时点合格池、候选扫描、因子快照、信号和未来标签；
- 模型 A 的机会真值、MFE/MAE/Return 24h 及匹配随机入场基线；
- `FIXED_BASELINE_MODEL_A` 的可执行交易仿真和退出原型；
- TRAIN-only 搜索、暂定 Cross-fit、go/no-go 闸门、锁定和一次性 VALIDATION/TEST；
- 版本、权限、暴露、资源、访问和复现审计。

只有在 Q-030/Q-036 的语料和功效门槛通过后，才交付正式模型 B。若第一阶段仅有 8 月 TRAIN，预期可能停在模型 A 与基线退出原型，不能以原型结果宣称样本外能力。

不在本文范围内：自动实盘发布、将大模型作为参数搜索器、Oracle 进入主训练目标、完整研究 UI 阻塞核心训练，以及第 24 章尚未立项的新币事件研究。

## 2. 总体架构

### 2.1 逻辑分层

```text
数据接入/快照
    │
    ▼
数据集构建器 ──> 数据质量/覆盖/指纹审计
    │
    ▼
特征与候选扫描 ──> 因子快照 ──> 模型 A 信号/机会真值/随机基线
    │                                      │
    │                                      ▼
    └──────────────────────────────> 模型 B 退出回合/决策轨迹
                                           │
                                           ▼
                                      组合交易仿真
                                           │
                 ┌─────────────────────────┴────────────────────────┐
                 ▼                                                  ▼
          训练评估器/评分器                                      审计与版本库
                 │                                                  │
                 ├── TRAIN 目标 ──> 优化器适配器 ──> 下一轮候选       │
                 ├── TRAIN 摘要 ──> 大模型网关 ──> 候选校验器         │
                 └── VALIDATION/TEST 结论 ──> 锁定/消费状态机         │
```

### 2.2 可部署组件

| 组件 | 责任 | 数据权限 | 部署要求 |
|---|---|---|---|
| `training-orchestrator` | 实验、任务、状态机、版本引用、暂停/恢复 | 仅状态和不可变 ID | 独立进程/服务账户，不读指标事实 |
| `training-worker` | 数据集构建、特征、信号、标签、仿真任务 | `tb2_training_rw` 受控过程 | 独立连接池、资源配额；不得持有 `tb2_trader` 或实盘 NATS 发布权限 |
| `training-evaluator` | 评分、硬门槛、聚类/块 bootstrap、资格报告 | TRAIN/VALIDATION 事实和安全映射 | 不持有优化器凭据，不访问 TEST |
| `optimizer-adapter` | Optuna/TPE、随机搜索适配、`suggest/tell` | 仅 TRAIN 目标和硬门槛 | 独立进程、连接池、secret；优化器本身不连库 |
| `model-b-worker` | 安全 as-of 输入、退出决策重放 | `tb2_training_model_b` 安全视图/过程 | 不读来源、未来标签和结果表 |
| `test-executor` | 锁定版本的一次性 TEST 消费 | `strategy_training_test` | 应用层 readiness + 服务账户执行；首读原子消费 |
| `weak-holdout-executor` | 10 月弱留出诊断 | `strategy_training_weak_holdout` | 不得写候选选择/晋级 |
| `llm-gateway` | TRAIN 白名单摘要、结构化响应、审计 | 无 VALIDATION/TEST 权限 | 出站域名限制，密钥不入日志/数据库 |
| `training-api` | CLI/API、查询、导出、审批入口 | 依角色调用受控服务 | 不在前端计算权威指标 |

### 2.3 进程与凭据隔离

`training-orchestrator`、`optimizer-adapter`、`training-evaluator` 必须使用不同容器/进程、数据库登录、连接池和 secret。部署检查拒绝同一服务账户同时拥有 `tb2_training_optimizer` 与 `tb2_training_evaluator`。控制编排器只传递不可变任务 ID，不传递 VALIDATION 指标、排名、通过/失败、早停原因或其代理字段。

### 2.4 时间与分区

- 数据库和计算统一 UTC；页面显示 UTC+8 仅用于展示。
- 所有区间为左闭右开 `[start_at, end_at)`。
- 训练、验证、弱留出、TEST 和 Cross-fit 折均应用 `max(label_horizon, max_holding_horizon)` 的尾部 embargo；Cross-fit 训练窗口额外 purge。
- 正式 TEST 是 `visibility_cutoff` 实际生效后的第一个完整、封存前 `NONE` 暴露月份；候选月由准备就绪时点决定，不按日历强行消费。

## 3. 数据处理与训练流程

### 3.1 数据集构建顺序

1. 读取并冻结 `training_config_versions`、行情快照、Ticker 池、排名规则和数据质量规则。
2. 审计 K 线、EMA、OI、排名、流动性和因子预热覆盖；生成分区资格报告。
3. 按信号时点生成历史基础合格池：上市状态、上市时长、流动性、数据完整性和 USDT 永续约束均以当时可见状态判断。
4. 对基础池执行低成本候选扫描，再计算完整因子和信号；不得使用事后涨幅榜硬过滤。
5. 保存全部必要因子快照、信号来源、可用性状态和计算版本。
6. 计算时间安全的 MFE、MAE、Return 24h；标签窗口不得越过分区结束点。
7. 生成机会真值和同标的/同池/同时段/波动率/流动性/BTC 状态匹配的随机基线；保存抽样框和入选概率。
8. 运行固定退出或模型 B 仿真，生成交易、风险、执行和组合结果。
9. 评估硬门槛、评分、稳定性和统计置信区间；只有 TRAIN 结果可反馈搜索。

### 3.2 模型 A 与模型 B 顺序

```text
FIXED_BASELINE_MODEL_A（B 阶段原型）
             │
             ▼
锁定 Cross-fit 协议/预算/种子
             │
             ▼
暂定 CROSS_FIT_MODEL_A_CANDIDATE
             │
      Q-036 外层折 go/no-go
       ┌─────┴─────┐
       │通过       │失败/功效不足
       ▼           ▼
正式 CROSS_FIT   停在模型 A + 基线退出原型
       │
       ▼
模型 B 正式训练 → 锁定 → 一次 VALIDATION → 后续 TEST
```

`CROSS_FIT_MODEL_A_CANDIDATE` 是入场事件来源枚举，但不是模型生命周期状态。它只能存在于 Q-036 闸门运行及其不可晋级的临时结果中；不得进入模型 B 正式 TRAIN、VALIDATION 或 TEST。END_TO_END_TEST 来源白名单只允许运行内实时产生的 `MODEL_A_SIGNAL`，必须明确拒绝该来源。go/no-go 内的模型 B 嵌套训练只能使用暂定 Cross-fit 语料，产物只用于闸门统计，必须标记不可晋级、不可写入模型注册表、不可复用；通过后必须全新运行正式模型 B。

来源契约固定为：模型 B 正式 TRAIN 只消费自然频率的 `CROSS_FIT_MODEL_A` 事件；VALIDATION 只消费锁定模型 A 重新生成的 `LOCKED_MODEL_A_VALIDATION_SIGNAL`；正式 TEST/端到端只消费运行内实时产生的 `MODEL_A_SIGNAL`。任何阶段都不得把暂定候选来源当作正式模型版本。

正式模型 A/B 锁定后，另有独立的 10 月弱留出分支：由 `weak-holdout-executor` 写入 `strategy_training_weak_holdout`，继承 `DECLARED` 谱系，只做诊断和工程演练，不回写候选选择、搜索早停、晋级或 TEST 状态。

### 3.3 暴露与实时运行

候选月内线上策略和纸面交易可以运行，但交易表、权益曲线、盈亏、持仓、告警和信号只进入运维隔离区，研究角色不可读。`OPERATIONAL_ONLY` 只允许显示采集延迟、任务健康、连接和错误；monitoring-ui 的 K 线、排名、回测、信号、交易结果页面必须隐藏或返回“仅运维模式”。研究者一旦看到策略派生结果，该月登记 `DECLARED`，不得作为正式 TEST。

## 4. 数据库设计

### 4.1 Schema 与权限

| Schema | 用途 | 允许分区 | 关键规则 |
|---|---|---|---|
| `strategy_training` | TRAIN/VALIDATION 训练事实和版本 | `TRAIN`、`VALIDATION` | 不得出现弱留出/TEST 行 |
| `strategy_training_weak_holdout` | 10 月弱留出及访问审计 | `WEAK_HOLDOUT` | `DECLARED` 谱系，不得晋级 |
| `strategy_training_test` | 正式 TEST 数据、状态和证据 | `TEST` | 物理隔离、首次读取即消费 |

原始行情仍在 `market`。时间隔离不能仅靠表级 `GRANT`；必须通过数据集边界、受控访问过程、worker 门禁和审计共同实现。

`strategy_training_weak_holdout` 使用与 `strategy_training` 同构的入场、标签、退出、组合和权益事实表，并额外使用独立的
`weak_holdout_access_log`。这些表只能写入 `WEAK_HOLDOUT/DECLARED` 数据，不能被主 schema 的 TRAIN/VALIDATION 查询复用，也不能写入 TEST 证据。

### 4.2 版本与规则表

| 表 | 关键字段 | 约束/用途 |
|---|---|---|
| `training_config_versions` | `config_version_id`、`config_type`、`semver`、`schema_version`、`config_json`、`content_hash`、`parent_version_id`、`status` | `DRAFT/READY/RETIRED`；READY 不可修改；覆盖因子、搜索空间、评分、Ticker 池、数据质量、退出、费用、滑点、组合规则 |
| `training_dataset_versions` | `dataset_version_id`、类型、分区边界、周期、warmup、eligible/label 窗口、purge/embargo、规则版本、根指纹、状态 | `BUILDING/READY/STALE/SUPERSEDED/INVALID/ARCHIVED`；READY 内容不可变 |
| `training_dataset_members` | 数据集 ID、源表/分片、时间范围、成员哈希、分片指纹 | 大数据集只保存可复现清单，不复制行情 |
| `training_data_quality_reports` | 数据集 ID、依赖、覆盖率、缺失率、warmup、有效折、阻断原因 | A0/D 阶段资格报告；缺失不得静默转为 0 或亏损 |
| `training_exposure_records` | 月份、`research_exposure_status`、cutoff、产物/查询、查看者、影响、评估结论 | 仅记录 TRAIN/VALIDATION/弱留出的 `NONE/DECLARED/UNKNOWN`；正式 TEST 的 `pre_seal_exposure_status` 位于 `strategy_training_test.test_sets`，`COMPROMISED` 是 TEST 状态，不是暴露枚举 |

必须保存源修订水位、规范化分片 SHA-256 和根指纹。源数据变化时旧数据集标记 `STALE/SUPERSEDED`，创建新版本，不覆盖旧结果。

### 4.3 实验与评估表

| 表 | 关键字段 | 说明 |
|---|---|---|
| `training_experiments` | 实验 ID、模式、父实验、配置/数据集版本、当前状态、停止原因、暴露身份 | `DISCOVERY/EXIT_POLICY/END_TO_END`；END_TO_END 不写迭代搜索事实 |
| `training_iterations` | 迭代 ID、实验 ID、候选版本、父迭代、来源、随机种子、状态、拒绝码、资源预算 | 保存所有 TRAIN L0；非法 Optuna 试验必须 `FAIL` 并调用 `tell()` |
| `training_iteration_metrics` | 迭代 ID、分区、指标值、样本数、有效独立日、计算版本 | 主 schema 仅含 TRAIN/VALIDATION；弱留出和 TEST 写入各自 schema |
| `training_score_components` | 迭代/评分版本、Discovery/Exit/End-to-end 分项、硬门槛、最终分 | 先硬门槛，后综合评分 |
| `training_validation_evaluations` | 逻辑身份、实验、候选、次数、alpha、置信区间、校正结果 | Q-029 全局共享预算，验证不能反馈搜索 |
| `training_validation_scopes` | 共享逻辑身份哈希、UTC 起止、Ticker 池规则版本、顺序检验协议、全局预算、alpha 总额、A/B 子族分配、已占用次数/alpha | 预算跨实验共享；身份哈希不得包含内容指纹、代码或候选；原子 reserve 失败时不得读取 VALIDATION |
| `training_optimizer_runs` | 优化器、搜索空间、预算、种子、worker、状态、开始/结束时间 | 记录 TPE/随机对照 |
| `training_optimizer_checkpoints` | run ID、trial 序号、study 状态哈希、恢复点 | 支持暂停/恢复；不可覆盖历史 |
| `training_cross_fit_folds` | fold ID、实验/暂定语料、原始/有效训练起止、预测起止、warmup/purge/embargo 区间、剔除数量、折内模型版本、折种子、状态 | 外层折与内层搜索一对多关联；每折从零重搜；折内验证次数必须为 0 |
| `training_go_no_go_evaluations` | Q-036 版本、暂定 Cross-fit、外层折、比较结果、功效、结论 | `PASS/FAIL/INSUFFICIENT_POWER`；功效不足不得解释为失败或通过 |
| `training_iteration_entry_events` | 迭代 ID、候选事件 ID、选择/拒绝状态、分项贡献 | 关联候选迭代与公共入场事实，不复制事件；候选来源和模型版本必须一致 |

### 4.4 模型 A 表

| 表 | 关键字段 | 约束 |
|---|---|---|
| `training_feature_snapshots` | 事件时间、Ticker、因子注册表/参数版本、因子值、可用性、输入指纹 | 只追加；逐因子可追溯 |
| `training_entry_events` | 事件 ID、数据集/模型 A、signal_time、Ticker、来源、触发分、入场价格、池/排名版本 | 来源枚举包括 `FIXED_BASELINE_MODEL_A`、`CROSS_FIT_MODEL_A_CANDIDATE`、`CROSS_FIT_MODEL_A`、`LOCKED_MODEL_A_VALIDATION_SIGNAL`、`MODEL_A_SIGNAL` 等；`CROSS_FIT_MODEL_A_CANDIDATE` 仅 Q-036 闸门，禁止正式 B/VALIDATION/TEST |
| `training_entry_outcomes` | 事件 ID、label window、MFE、MAE、Return 24h、达到时间、完整性 | `label_window_end <= partition_end`；未来标签与入场事实物理隔离 |
| `training_opportunity_events` | 事件 ID、机会定义版本、真值、阈值、来源 | 不使用 Oracle Top 20 作为模型 A 真值 |
| `training_random_entry_baselines` | 基线 ID、匹配事件、抽样框、入选概率、种子、匹配层、重叠排除结果 | 支持重要性重加权和超额 MFE |

### 4.5 模型 B 与组合表

| 表 | 关键字段 | 约束 |
|---|---|---|
| `training_model_b_sample_map` | 样本 ID、自然来源、混合版本、抽样概率、实际权重、Oracle/对照标签 | Oracle 权重主目标固定为 0；逆风/震荡仅 TRAIN 重加权 |
| `training_exit_episode_inputs` | episode、入场事件、as-of 时间、不可反解样本 ID、模型 B 配置 | 不含最终结果、来源映射、未来标签 |
| `training_exit_outcomes` | episode、退出结果、MFE/MAE/回吐/成本 | 评估器写入，模型 B worker 不可读 |
| `training_decision_feature_snapshots` | episode、决策时间、当时可见特征、市场 as-of 引用 | 决策时间之后的数据被拒绝 |
| `training_exit_decisions` | episode、决策时间、动作、价格、原因、模型版本 | 只追加；可逐时点重放 |
| `training_portfolio_runs` | run、模式、资金/并发规则、版本、状态、开始/结束 | `TRAIN_PORTFOLIO`/`VALIDATION_PORTFOLIO`；TEST 物理隔离 |
| `training_portfolio_signal_dispositions` | 信号、接受/拒绝、原因、容量/重复约束 | 证明组合选择没有隐式漏信号 |
| `training_portfolio_equity_points` | run、时间、余额、权益、回撤、占用 | 可重放资金曲线 |
| `training_portfolio_trades` | run、事件/episode、成交、费用、滑点、净收益 | 执行成本按名义规模/成交额/波动率模型化 |
| `training_portfolio_trade_fills` | trade ID、成交序号、价格、数量、费用、滑点、成交时间 | 组合成交明细子表；只追加，汇总必须可由 fills 确定性重建 |

### 4.6 大模型、晋级和 TEST 表

| 表 | 关键字段 | 说明 |
|---|---|---|
| `training_model_advice_batches` | 批次、TRAIN 摘要哈希、模型/提供商请求 ID、脱敏载荷、校验结果 | 不保存密钥；泄漏字段出口拒绝 |
| `training_model_advice_batch_iterations` | 建议批次、迭代 ID、输入摘要哈希、输出校验状态 | 多对多关联；只能关联 TRAIN 摘要和候选校验结果 |
| `training_search_space_requests` | 请求、来源、变更、范围、审批、结果 | 大模型不能直接改搜索空间 |
| `training_promotion_approvals` | 候选、状态、审批人、前置证据、原因 | 模型锁定、影子晋级和 TEST 前置 |
| `training_strategy_links` | 模型 A/B/组合/策略 ID、血缘、暴露状态 | TEST 暴露递归继承，不能绕过 |
| `test_logical_scopes` | UTC 左闭右开范围、Ticker 池规则版本、受控用途、身份哈希 | 哈希不得包含内容指纹、代码或数据集版本；唯一身份不可重注册绕过 |
| `test_dataset_versions` | 逻辑身份、内容/分片指纹、supersedes、来源修订水位、状态 | 回补只产生新内容版本，不改变逻辑身份 |
| `test_sets` | 逻辑身份、分区、cutoff、`pre_seal_exposure_status`、状态、封存/消费时间 | `SEALED → CONSUMED`；另有 `COMPROMISED`，不可回退 |
| `test_set_access_log` | 请求者、用途、路径、时间、允许/拒绝、原因、运行 ID | 所有访问追加写入 |
| `test_model_exposures` | TEST 集、模型版本/谱系、暴露状态、证据哈希、查看者 | TEST 暴露继承到模型血缘 |
| `test_retry_approval_requests` | 消费链、发起人、审批人、同版本证明、无暴露证明、结果 | 发起/审批必须不同自然人；单人禁止 |
| `test_promotion_evidence` | TEST 运行、证明哈希、审计人、批准时间、主 schema 不透明引用 | 不复制 TEST 指标 |
| `test_state_transition_log` | TEST 集、旧/新状态、actor、原因、时间、request ID | 追加写入，覆盖 SEALED/CONSUMED/COMPROMISED |
| `training_model_versions` | 模型类型、配置/数据集、状态、内容哈希、锁定审批 | 生命周期 `DRAFT/LOCKED/SHADOW/RETIRED`；暂定候选不是模型版本 |
| `training_model_lineage_edges` | 子/父模型、关系、TEST 逻辑身份集合、创建版本 | 递归检查祖先是否消费同一 TEST 身份 |
| `training_state_transition_log` | 主 schema 对象、旧/新状态、actor、原因、时间 | 实验、迭代、数据集、模型和晋级状态审计 |
| `test_*` 派生表 | entry/outcome/exit/portfolio/equity 等 | 只在 `strategy_training_test`，主 schema 只接收证明引用 |

`test_logical_scopes.scope_hash` 只由 UTC 左闭右开起止、Ticker 池规则版本和受控用途生成；不得混入内容指纹、代码版本、数据集版本或自由文本。回补只在
`test_dataset_versions` 建立新的内容版本和 `supersedes` 链，不改变逻辑身份。创建或晋级模型时，必须递归检查
`training_model_lineage_edges` 的全部祖先：任何祖先已经消费同一 `test_logical_scope_id`，当前谱系即拒绝。`pre_seal_exposure_status` 属于
`strategy_training_test.test_sets`，而 `training_exposure_records` 不得用 `COMPROMISED` 充当研究暴露状态。

### 4.7 通用数据库约束

- 所有版本 READY 后禁止 UPDATE；普通运行角色不能 DELETE 已完成事实。
- `label_window_end <= partition_end`、时间边界顺序、周期和状态转移使用 CHECK/触发器/受控过程共同校验。
- `entry_event_id` 按设计 15.4 的确定性指纹生成：`dataset_version + generating_model_version/iteration + ticker + signal_time + entry_time + direction`；同一候选重跑必须得到相同 ID，不同生成模型不得错误去重。重试产生新记录并关联原记录。
- TEST 首次成功读取使用原子状态更新；读取后失败只能同版本、同消费链、无暴露且双人审批重试。
- 通用只读/备份角色不得取得 TEST schema `USAGE`；TEST 执行器不能读取草稿、验证指标或大模型建议。

### 4.8 索引、分区与迁移顺序

首版迁移不得修改 `market`、`trade` 业务表的语义；只创建训练 schema、角色、受控过程和必要的只读引用。当前仓库最新迁移为 `018_telegram_channel_messages.sql`，本功能迁移从 `019_` 起按顺序分配；提交前必须扫描迁移目录确认没有并行占用，并在迁移说明中记录编号。按以下顺序执行：

1. schema、枚举/状态、角色和审计基础表；
2. 配置、数据集、成员清单和质量报告；
3. 实验、迭代、指标、优化器和验证预算；
4. 模型 A、模型 B、组合及隔离 TEST 表；
5. 受控过程、视图、触发器、索引、权限和回滚检查。

迁移文件只创建 `NOLOGIN` 数据库角色、schema、授权模板和审计结构，不写入登录密码或 secret。部署引导脚本另行创建/轮换登录角色、注入 secret，并验证应用服务账户到数据库角色的实际成员关系、互斥关系和撤销结果；secret 不进入迁移文件、版本库或日志。`apply_migrations.sh` 只负责按序执行迁移，不承担 secret 注入。

大表按 `dataset_version_id`、分区和 UTC 时间设计范围分区；事实表禁止无边界全表扫描。至少建立以下索引：

- 数据集：`(status, partition_start, partition_end)`、根指纹唯一索引；
- 特征/入场：`(dataset_version_id, signal_time, symbol)`、`(model_version_id, source)`；
- 标签/退出：`(entry_event_id)`、`(episode_id, decision_time)`；
- 迭代/指标：`(experiment_id, iteration_no)`、`(iteration_id, partition)`；
- 审计/TEST：`(test_set_id, accessed_at)`、`(actor_id, accessed_at)`、`(status)`。

所有索引、分区、压缩和保留策略必须通过容量测试后启用；不得用自动删除代替归档闭环。

## 5. API、模块与功能设计

### 5.1 内部模块

```text
training/
├── contracts.py             # 版本、分区、状态、指标、拒绝码
├── dataset_builder.py       # 数据集、成员清单、指纹、质量报告
├── search_space.py          # 搜索空间版本、阶段开放和预算
├── validation.py            # 优化器/大模型共用候选合法性校验
├── evaluator.py             # 回测调用、评分、硬门槛、统计
├── label_pipeline.py        # MFE/MAE/Return 与机会真值
├── baseline.py               # 随机时点、匹配变量、入选概率
├── simulator/                # 固定退出、模型 B、组合仿真
├── scoring.py                # 分项评分、硬门槛、bootstrap
├── cross_fit.py              # 折结构、purge、embargo、逐折重搜
├── optimizer.py              # TPE/随机搜索适配器
├── orchestrator.py           # 状态机、预算、早停、晋级
├── llm_advisor.py            # 白名单摘要、结构化输出、审计
├── test_executor.py          # 隔离 TEST 一次性消费
└── audit.py                  # 事件、版本、权限、访问和复现清单
```

`feature_scan.py` 和现有 `backtesting/service.py` 不修改；`dataset_builder.py`/`evaluator.py` 通过适配器包装现有 V2 基线，确保因子、周期、默认参数和交易语义一致。新包必须在 `auto_trade/training/` 下实现，Optuna 依赖写入 `pyproject.toml`，不能由运行时隐式安装。

### 5.2 API 契约

| API/命令 | 权限 | 行为 |
|---|---|---|
| `POST /training/datasets` | `TRAINING_ADMIN` | 创建 BUILDING 数据集，返回不可变 ID |
| `POST /training/datasets/{id}/audit` | worker/evaluator | 执行覆盖、warmup、指纹、purge/embargo 质量报告 |
| `POST /training/experiments` | `TRAINING_ADMIN` | 创建实验和锁定配置/数据集引用 |
| `POST /training/experiments/{id}/run` | orchestrator | 只启动合法状态和预算内任务；先原子占用验证/资源预算 |
| `POST /training/iterations/{id}/cancel` | `TRAINING_ADMIN` | 向数据库发送 cancel，宽限期后终止 worker，追加取消状态，不删除迭代 |
| `GET /training/experiments/{id}/metrics` | evaluator/审计 | 按权限查看分区指标；优化器只能取得 TRAIN 目标 |
| `POST /training/candidates/validate` | optimizer/LLM | 返回统一拒绝码；非法候选仍以 FAIL/约束状态完成 `tell()` |
| `POST /training/go-no-go` | evaluator | 运行 Q-036 暂定 Cross-fit 闸门并保存证据 |
| `POST /training/validation-scopes/{id}/reserve` | evaluator | 原子占用共享验证预算；占用失败不得读取 VALIDATION |
| `POST /training/search-space-requests/{id}/approve` | `TRAINING_ADMIN` | 审批搜索空间，不自动产生候选 |
| `POST /training/models/{id}/lock` | 人工审批 | 检查所有前置、血缘和暴露后锁定；不要求 TEST 重试式双人审批 |
| `POST /training/weak-holdouts` | `TRAINING_ADMIN` | A/B 锁定后运行 `DECLARED` 弱留出，结果不得回写选择/晋级 |
| `POST /training/test-sets/{id}/readiness` | `TRAINING_ADMIN`/审计服务 | cutoff、NONE、双人和值守检查 |
| `POST /training/test-sets/{id}/consume` | 应用层 TEST readiness + `tb2_training_test_executor` | 原子 SEALED→CONSUMED，一次性运行 |
| `POST /training/test-sets/{id}/retry-approvals` | 不同自然人的管理员/审计员 | 发起、审批 TEST 重试，不回退状态 |
| `GET /training/audit/export` | 审计角色 | 导出版本、访问、状态和复现证明，不导出密钥 |

API 不允许客户端提交分区结束点后的数据、自由 SQL、未来标签、TEST 结果或任意模型版本。所有写操作关联 request ID、actor、代码版本、配置哈希和审计事件。

### 5.3 状态机

```text
DATASET: BUILDING → READY → STALE → SUPERSEDED/ARCHIVED
EXPERIMENT: DRAFT → RUNNING → PAUSED/STOPPED（实验不承担模型 LOCKED 状态）
ITERATION: CREATED → VALIDATING → RUNNING → SUCCEEDED/FAILED/REJECTED/CANCELLED
MODEL: DRAFT → LOCKED → SHADOW/RETIRED
TEST: DRAFT → SEALED → CONSUMED（不可回退）；任何阶段发现提前暴露、越权读取或隔离绕过，均可从 DRAFT 或 SEALED 直接转为 COMPROMISED（不可回退）
```

状态转换只能由编排器或受控过程执行；失败不覆盖父版本，重试创建关联新运行。

## 6. 安全、审计与资源控制

### 6.1 RBAC

数据库角色和应用角色必须显式映射，不能由 `ADMIN` 隐式继承训练权限：

- `tb2_training_rw`：worker 受控读写事实；
- `tb2_training_orchestrator`：实验/任务状态和不可变引用；
- `tb2_training_optimizer`：仅 `optimizer_train_objective` 和 TRAIN 目标；
- `tb2_training_evaluator`：TRAIN/VALIDATION 评估、评分和验证引用；
- `tb2_training_model_b`：`model_b_entry_inputs`、`model_b_market_asof` 和受控决策写入；
- `tb2_training_test_executor`：锁定 TEST 一次性消费；
- `tb2_training_weak_holdout_executor`：弱留出执行；
- `tb2_training_test_auditor`、`tb2_training_test_backup`：审计和隔离备份；
- `TRAINING_RESEARCHER`、`TRAINING_ADMIN`、`TRAINING_TEST_AUDITOR`：应用层角色，写入 `core.app_user_training_roles`，授予/续期/撤销必须追加审计。

`TRAINING_ADMIN` 负责版本、实验和发布；`TRAINING_TEST_AUDITOR` 只审计 TEST 证据；两者必须是不同自然人。服务账户不能作为人工审批人。人员不足时禁止封存和启动 TEST。数据库角色不能直接授予浏览器用户；应用 RBAC、数据库授权、服务账户和自然人互斥检查必须同时通过。

### 6.2 防泄漏门禁

- 代码层：所有查询必须带数据集版本和 as-of 时间；禁止使用当前 Ticker 列表回看历史。
- 数据库层：训练 worker 只能调用受控过程；模型 B 只能读取安全视图；TEST schema 独立。
- 过程/视图层：`optimizer_train_objective` 只返回 TRAIN 目标和硬门槛；`model_b_entry_inputs` 不含来源/结果；`model_b_market_asof` 强制决策时间边界；`locked_versions_for_test` 只返回 LOCKED 且血缘合格版本。
- 指标层：优化器对 `training_iteration_metrics`、`training_score_components` 和 VALIDATION 评估表无 SELECT；VALIDATION 指标必须带 `training_validation_evaluation` 引用，否则由约束拒绝。
- 进程层：优化器/评估器/编排器分离；LLM 只接收 TRAIN 白名单摘要。
- 载荷层：拒绝 validation/test、未来结果、排名、早停原因、结果性自由文本字段。
- UI 层：候选月 `OPERATIONAL_ONLY` 只显示运维指标；策略输出对研究角色隐藏。
- API 层：`/api/market/klines`、`/api/rankings/daily`、`/api/backtests/*`、导出 API 和直连查询必须在 cutoff middleware/受控过程层拒绝候选月研究数据（403 或统一“仅运维模式”响应），不能只依赖前端隐藏。
- 脚本层：`make feature-scan-3m` 必须经过带研究截止日和审计的包装器；研究角色访问 `market` 只能经视图/RLS/受控 as-of 过程，不能取得底层表无界 SELECT。

### 6.3 资源配额

首个 READY 资源配置版本固定以下初始安全上限：全系统 1 个重型实验、每实验 2 个数据库 worker、训练连接池 6 个连接、`statement_timeout=15min`、`lock_timeout=2s`、`idle_in_transaction_session_timeout=60s`、`work_mem<=64MB`、4 vCPU、8 GiB 内存和独立临时盘水位。最终值仍须压测后创建新版本。准入控制器检查连接/CPU/IO/锁等待、只读副本延迟、采集 checkpoint 新鲜度、`application_name` 隔离和实盘健康；重型任务使用经负载证明的错峰窗口，采集/实盘优先。取消任务必须向数据库发送 cancel，宽限期后终止 worker。

## 7. 测试策略

### 7.1 测试分层

| 层级 | 目标 | 环境 |
|---|---|---|
| 单元测试 | 纯函数、边界、状态机、SQL 构造、序列化 | Python/pytest，无外部服务 |
| 数据库集成测试 | 表约束、角色、受控过程、指纹、事务和状态机 | 临时 PostgreSQL/Timescale |
| 服务集成测试 | API、worker、evaluator、optimizer、权限和审计联动 | Compose 测试环境 |
| 端到端测试 | A0→A1→B→D→F 主路径和失败路径 | 固定小型数据集、隔离 TEST |
| UI 回归测试 | 页面状态、权限、错误、运维降级 | 测试 API + 浏览器 |
| 性能/容量测试 | 预算、并发、超时、恢复、写入和查询负载 | 接近生产资源 |

集成测试代码统一放在 `tests/integration/`，入口为 `make test-integration`。该目标使用独立的测试 Compose 启动临时 PostgreSQL/TimescaleDB（随机项目名、临时 schema/卷和固定迁移版本），测试结束后销毁临时资源；不得连接开发或生产数据库。若环境没有 TimescaleDB 镜像，必须显式失败，不得静默降级为仅单元测试。

### 7.2 单元测试清单

#### 时间、分区和标签

- UTC 左闭右开边界：正好等于 `partition_end` 的事件被拒绝。
- `label_window_end > partition_end` 被拒绝；purge/embargo 使用最大标签/持仓窗口。
- warmup 从因子注册表计算，不使用正文硬编码日期。
- Q-032 根数参数在 5m 原型中按分钟等价值换算；当 `feature_scan.py` 的 `interval_seconds=900` 语义未迁移时，测试必须断言该配置不得标记为“当前 V2 默认”。
- UTC+8 展示转换不改变查询边界。

#### 候选池、因子和信号

- 下架前可生成、下架后不可生成；当前合约列表不能回看历史。
- D-1 日榜可用/缺失时行为正确；缺失不自动填未来榜单。
- 全量低成本候选不会因未进入榜单被过滤。
- 因子缺失返回不可用状态，不返回 0 伪造结果。

#### 标签与基线

- MFE/MAE/Return 的路径端点、达到时间和 24h 窗口正确。
- 随机基线按标的、候选触发、波动率、流动性、BTC 状态匹配；重叠窗口被排除。
- 抽样框、入选概率和种子确定性重现。
- Oracle 不进入模型 B 主目标，逆风/震荡仅允许 TRAIN 重加权。

#### 评分、统计和门禁

- 硬门槛先于综合评分和排名。
- 日或日×标的聚类/块 bootstrap 不把重叠信号当独立样本。
- TPE/随机搜索比较使用暂定 Cross-fit 折外结果，不使用原始 TRAIN 目标。
- 功效不足返回 `INSUFFICIENT_POWER`，不得自动映射为 PASS/FAIL。
- 模型 B 闸门产物不可晋级或写入模型注册表。

#### 优化器和状态机

- 非法候选不调用回测，但以 `TrialState.FAIL` 或版本化约束结果完成 `tell()`。
- 重复、取消、超时、恢复、失败不覆盖父迭代。
- READY、LOCKED、CONSUMED 状态不可被普通角色修改或回退。

### 7.2.1 单元测试夹具与属性测试

固定夹具至少包含：

- 两个标的、两个分区、一个跨边界标签和一个缺失排名日；
- 相同 signal_time 的重叠信号、不同成交额/波动率/BTC 状态的随机基线候选；
- Oracle、`ADVERSE_OR_RANGE_CONTROL`、`CROSS_FIT_MODEL_A_CANDIDATE`、`CROSS_FIT_MODEL_A`、`LOCKED_MODEL_A_VALIDATION_SIGNAL`、`MODEL_A_SIGNAL` 和 `FIXED_BASELINE_MODEL_A` 来源；
- 正常、硬门槛失败、范围非法、依赖非法、超预算、功效不足和 TEST 已消费状态。

属性测试应验证：任何未来时间输入都不能进入 as-of 查询；任意源修订都会改变对应数据集指纹；相同输入/种子/版本产生相同排序键和事件 ID；所有非法状态转换均不可提交。

### 7.3 数据库集成测试

1. 使用最小 schema 创建全部专用角色，验证每个角色正向权限和越权失败。
2. 验证训练角色不能访问弱留出/TEST，通用只读/备份不能取得 TEST `USAGE`。
3. 插入越界标签、跨分区标签、非法状态转换和重复逻辑 TEST 身份，均必须失败。
4. 修改源修订水位/分片内容后，回放必须标记旧数据集 `STALE` 并要求新版本。
5. 通过受控过程写入事实；直接 UPDATE/DELETE 已完成事实必须被拒绝。
6. `SEALED → CONSUMED` 与并发重复消费测试只能成功一次；失败重试必须满足双人审批条件。
7. 模型 B 安全视图不得反解来源、Oracle/对照标记、标签或结果表。
8. `training_validation_scopes` 的身份哈希只含 UTC 范围和 Ticker 池规则版本；并发 reserve 超出全局次数或 alpha 预算时原子失败，失败事务不得读取任何 VALIDATION 数据；`training_validation_evaluations` 的累计预算不能通过新实验/数据版本重置。
9. `training_cross_fit_folds` 每折必须保存原始/有效训练起止、预测起止、warmup/purge/embargo、剔除数量、折内模型版本和种子；每折从零重搜，折内验证次数必须为 0。
10. `CROSS_FIT_MODEL_A_CANDIDATE` 只能用于 go/no-go；尝试写入模型 B 正式 TRAIN、VALIDATION 或 TEST 必须被约束拒绝。
11. 回补只改变 `test_dataset_versions` 内容指纹并建立 supersedes 关系，不改变 `test_logical_scopes` 身份；任一祖先消费同一逻辑身份时，新的模型谱系必须被拒绝。
12. 角色互斥、服务账户不能审批、人员不足禁止 readiness/封存、训练容器不能发布实盘 NATS 均必须有正向和越权用例。

### 7.4 服务集成测试

- **A0 流程：** 建表、角色迁移、指纹、覆盖审计、purge/embargo、`visibility_cutoff`、monitoring-ui 降级和审计全部通过后才能进入 A1。
- **A1 流程：** 固定配置生成确定性特征、信号、标签、机会真值和随机基线；重复运行哈希一致。
- **B 流程：** 固定入场事件、as-of 决策、退出边界、费用/滑点和组合资金约束正确；不能读取未来路径。
- **D 流程：** 暂定 Cross-fit、外层折、模型 A 对照、嵌套模型 B 闸门、功效不足停止和正式语料升级路径正确。
- **弱留出流程：** A/B 均锁定后，`weak-holdout-executor` 才能使用 10 月 `DECLARED` 数据；运行、结果、访问和谱系写入 `strategy_training_weak_holdout`，结果不得回写候选选择/晋级，不得标记 TEST。
- **VALIDATION 流程：** TRAIN 搜索完成后只运行冻结候选；验证结果不能触发新候选、优化器或 LLM。
- **TEST 流程：** 双人 readiness、cutoff、NONE 暴露、锁定血缘、一次消费、失败重试和主 schema 不透明证明完整。
- **失败流程：** worker 崩溃、数据库超时、LLM 不可用、Optuna 失败、权限拒绝、数据指纹变化均安全失败且不影响实盘。

### 7.4.1 集成测试编排

测试 Compose 至少启动 PostgreSQL/Timescale、API、worker、evaluator 和 optimizer-adapter；任务队列优先使用数据库任务表/锁。如果使用 NATS，必须是独立账户和独立 subject/stream，训练容器不得持有采集、交易、保护性订单或实盘 subject 的 publish 权限，也不得拥有 `tb2_trader`。测试数据使用固定 UTC 时间、固定随机种子和独立 schema；测试结束清理临时 schema/卷，不触碰开发或生产卷。

每次集成运行保存：镜像摘要、迁移版本、配置版本、数据集根指纹、随机种子、测试报告和服务日志。测试必须同时覆盖成功路径和中途重启路径，确认 checkpoint 恢复不会重复写入事实或绕过状态机。

### 7.5 API 测试矩阵

| 用例 | 预期 |
|---|---|
| 未登录访问训练 API | 401 |
| 普通用户访问管理员/TEST API | 403 |
| 任务引用 STALE/INVALID 数据集 | 422，创建失败审计 |
| 请求跨越分区结束点 | 422，不执行查询 |
| 优化器请求 VALIDATION/TEST 字段 | 403/422，载荷审计 |
| 非法候选 | 422；对应 trial 为 FAIL，不留 RUNNING |
| validation scope reserve 超出次数或 alpha 预算 | 409/422；原子占用失败，不读取 VALIDATION，并写审计 |
| TEST readiness 在 cutoff 未生效、非 NONE 暴露或模型未锁定时调用 | 422；拒绝 SEALED，不读取候选月结果 |
| TEST 重试审批缺少不同自然人或同版本证明 | 403/422；不改变 CONSUMED/COMPROMISED 状态 |
| 弱留出在模型 A/B 未锁定时调用 | 409；拒绝执行且不产生弱留出事实 |
| 重复 TEST 消费 | 409，状态仍 CONSUMED |
| TEST 无第二审计人 | readiness FAIL，禁止 SEALED/CONSUME |
| 越权访问候选月研究结果 | 403 并写访问日志，月状态降级 |

### 7.6 UI 与浏览器测试

- 研究员、管理员、审计员页面和操作菜单按 RBAC 显示；前端隐藏不替代后端授权。
- `OPERATIONAL_ONLY` 下 K 线、排名、回测、信号、交易、盈亏页面隐藏或显示统一占位，只显示延迟/健康/连接/错误。
- 实验详情能查看版本、状态、失败原因、硬门槛、预算和复现命令，但无权读取隔离 TEST 指标。
- TEST 证据页面只显示不透明引用和证明状态；审计导出带访问者、时间、用途和哈希。
- 网络失败、权限 403、空数据、加载中、轮询恢复和错误重试均有明确 UI 状态，不把错误渲染为空结果。
- 候选月请求 `/api/market/klines`、`/api/rankings/daily`、`/api/backtests/*` 和导出接口时，后端必须返回 403/运维模式；对 `make feature-scan-3m` 的包装器必须记录 cutoff、调用者、查询范围和拒绝原因。测试不能只验证页面元素隐藏。

### 7.7 性能与容量测试

- 以版本化规模预算验证候选数、信号数、决策行、存储估算误差和拒绝阈值。
- 并发训练时验证数据库连接上限、statement/lock timeout、CPU/内存/临时盘和采集 checkpoint SLO。
- 取消/暂停任务后验证连接释放、锁释放、状态落库和可恢复 checkpoint。
- 大事实导出使用 Parquet；验证压缩、恢复、分区扫描和索引计划。
- 证明研究任务异常不会影响采集、实盘服务和保护性订单路径。

### 7.8 L0/L1/L2 分级持久化

- **L0 证据层：** 每个候选都保存不可变配置、数据集/代码版本、种子、状态、失败/淘汰原因、硬门槛和已产生聚合指标；失败、超时和未晋级候选不能删除。
- **L1 汇总层：** 由原始输入确定性重跑生成因子/事件/分区汇总，必须与 L0 的聚合指标一致；不一致则复现失败并禁止晋级。
- **L2 明细层：** 只按实验开始前固定的价值/抽样规则保存逐信号、逐决策和逐资金曲线明细；不能看到结果后再选择性升级或删除。
- VALIDATION L0 必须带 `training_validation_evaluation_id`，没有评估引用的 VALIDATION 指标由数据库约束拒绝；非终选候选不得补算 VALIDATION。
- 实验启动前按候选数、信号数、平均持仓决策点、字段大小、压缩率和保留期计算容量预算；超预算必须减少 L2 规模或拒绝启动。
- 冷明细归档为 Parquet + ZSTD，保存行数、时间范围、对象大小、SHA-256 清单和恢复验证记录。归档恢复后必须与 L1/L0 聚合一致。

### 7.9 可复现清单

每次数据集、迭代、模型、仿真、go/no-go 和测试运行都生成 `reproducibility_manifest`，至少包含：代码提交、镜像摘要、Python/系统版本、依赖锁文件哈希、数据库迁移版本、配置/数据集/规则/评分版本、源分片根指纹、随机种子、BLAS/OpenMP 线程数、CPU/并发、Q-028 绝对/相对容差、查询规范化文本哈希、输入输出文件哈希和运行命令。验收 1/11 要求逐字节离散结果一致，浮点结果按该容差比较；任一清单项缺失不得标记运行可复现。

## 8. 实施顺序与交付物

| 阶段 | 交付物 | 阻断条件 |
|---|---|---|
| A0 | schema/角色、受控过程、资源配额、数据审计、指纹、purge/embargo、cutoff、UI 运维降级 | Q-001/005/015/028/031/034/035 未确定或测试未通过 |
| A1 | 特征/标签/信号/机会真值/随机基线、确定性清单和导出；Q-032 根数→分钟等价值换算测试、Q-033 基线测试 | Q-032/Q-033 未确定；5m 原型不得称为当前 15m V2 默认；覆盖、1m 审计或指纹不合格时只能 5m 原型 |
| B | 固定基线入场、退出仿真、as-of 安全视图、组合资金 | Q-005/Q-006/Q-007/Q-017/Q-037 未确定 |
| C | 编排、优化器检查点、审批、审计、TEST 状态机、RBAC 回归、L0/L1/L2 归档恢复、资源准入控制器 | Q-031、归档/恢复或双人 TEST 人员不通过不得进入 F |
| D | Cross-fit、暂定闸门、TPE/随机比较、模型 B 搜索 | Q-019/Q-029/Q-030/Q-036/Q-039 未确定或功效不足则停在原型 |
| E | 可选 LLM 网关、载荷校验、调用审计 | 不得成为 TEST 必需前置 |
| F | 锁定模型、正式 TEST、证据和影子晋级 | Q-038、cutoff/NONE/双人/1m/血缘任一失败即禁止 |
| G | 完整训练工作区和运维页面 | 不阻塞 A–F 核心流程 |

## 9. 发布、回滚与运维

### 9.1 发布前检查

- 配置、代码提交、数据库迁移、镜像、依赖和数据集根指纹均有版本号。
- `git diff --check`、单元、数据库集成、服务集成和最小端到端测试通过。
- 连接数、超时、角色权限、出站域名和 secret 检查通过。
- TEST readiness、cutoff、暴露审计和双人值守证据齐全。

### 9.2 回滚

代码回滚只切换到已验证镜像；数据和事实不删除。数据集/配置回滚通过引用旧的 READY 版本，不复用已被标记 STALE/COMPROMISED 的 TEST。若 TEST 已读取，任何不确定性均保持 CONSUMED 或 COMPROMISED，不能回退封存状态。

### 9.3 可观测性

所有服务输出结构化日志，至少包含 request ID、experiment ID、dataset/model version、partition、actor、状态转换、拒绝码和耗时。监控指标包括任务状态、队列、数据库连接/锁/超时、数据覆盖、候选/信号/决策数量、预算消耗、失败率和 TEST 访问拒绝数。日志不得包含 API key、密码、完整 TEST 指标或未脱敏模型载荷。

## 10. 开发完成标准

开发版本只有同时满足以下条件才可标记为“可进入正式 VALIDATION”：

1. A0/A1/B/C 的功能、权限和集成测试通过；
2. 数据集、模型、配置和评分均可按哈希确定性复现；
3. Cross-fit 资格报告、暂定 go/no-go 和 Q-036 功效检查通过；
4. 模型 B 正式训练只使用正式 Cross-fit，且 TRAIN/VALIDATION 来源符合分区契约；
5. 验证预算、alpha、聚类/块 bootstrap 和多重比较协议已经版本化；
6. TEST 双人 readiness、cutoff、NONE 暴露、schema 和消费状态机完成演练；
7. 任一失败只会停止/降级当前实验，不会自动修改实盘策略。

正式 TEST 通过并不等于自动发布实盘；影子晋级和实盘接入仍需独立审批。

## 11. 验收原则到测试用例追溯

| 验收项 | 自动化用例/证据 | 层级 |
|---:|---|---|
| 1 | `reproducibility_manifest`、离散结果逐字节比较、浮点 Q-028 容差 | E2E/复现 |
| 2 | as-of 查询和未来字段静态/动态扫描 | 单元/集成 |
| 3 | L0/L1/L2 重跑一致性、事件到因子快照追溯 | 数据库/E2E |
| 4 | 缺失行情、因子、排名不得转为 0/亏损 | 单元 |
| 5 | MFE/可执行净收益分离断言 | 单元 |
| 6 | 锁定基线、提升、置信区间和多重比较 | evaluator 集成 |
| 7 | 优化器/LLM/编排器无法读取 TEST；消费后谱系降级 | 安全集成 |
| 8 | LLM 超时、非法 JSON、不可用回退 | 服务集成 |
| 9 | 候选永不自动发布实盘 | API/E2E |
| 10 | TEST 消费链只运行一次完整基础池，并报告榜单漏选机会 | TEST E2E |
| 11 | 固定入场/模型 B/组合重放逐字节及浮点容差 | E2E/复现 |
| 12 | 模型 B 决策载荷未来字段拒绝 | 安全集成 |
| 13 | Oracle/逆风对照不进入可交易端到端结果 | 数据库/评分 |
| 14 | TEST 只接受锁定模型 A/B 和 `MODEL_A_SIGNAL` | TEST 集成 |
| 15 | 组合运行、处置、权益曲线和锁定版本完整血缘 | E2E |
| 16 | SEALED 原子消费、双人重试、状态不可回退 | 数据库/权限 |
| 17 | 模型 B 安全视图无法读取来源/标签/结果 | 权限集成 |
| 18 | 全候选 L0、终选 VALIDATION 引用、L1/L2 规则固定 | 数据库/容量 |
| 19 | 完成事实拒绝 UPDATE/DELETE，修订追加新版本 | 数据库 |
| 20 | 三 schema 隔离和通用角色无 TEST `USAGE` | 权限集成 |
| 21 | purge/embargo 使用最大窗口且训练标签不越界 | 单元/数据集 |
| 22 | END_TO_END_TEST 来源白名单拒绝 `CROSS_FIT_MODEL_A_CANDIDATE`、CROSS_FIT、FIXED、Oracle 等 | 数据库/E2E |
| 23 | 优化器无指标 SELECT、VALIDATION 需评估引用、角色/进程/secret 分离 | 安全集成 |
| 24 | as-of 过程和不可反解 ID；底层行情/映射直接读取拒绝 | 权限集成 |
| 25 | TEST 状态/证据留在 TEST schema，主 schema 仅证明引用 | 数据库 |
| 26 | 样本混合比例、入选概率、Oracle PSI/KS/Wasserstein 和来源 AUC | 统计集成 |
| 27 | 回补只改内容指纹；祖先消费同一逻辑身份时递归拒绝 | TEST/谱系 |
| 28 | 密钥不入库/日志、出站域名白名单 | 安全集成 |
| 29 | TRAIN-only 搜索、验证预算原子占用、失败后不可继续搜索 | 服务集成 |
| 30 | READY 指纹重算和 STALE/SUPERSEDED 替代链 | 数据库 |
| 31 | 1 重型实验/2 worker/6 连接/15m/2s/60s/64MB/4vCPU/8GiB 配额及采集 SLO | 容量 |
| 32 | 候选/信号/决策/存储/CPU/连接预算预检和超限拒绝 | 容量 |
| 33 | 所有硬门槛先于排名、验证和晋级 | evaluator |
| 34 | 优化器/LLM 共用候选校验器和拒绝码 | 单元/服务 |
| 35 | 全因子依赖覆盖预检、回补约 2026-06-21 证据、整折无效规则 | A0/D 集成 |
| 36 | 训练角色授予/撤销、角色互斥、服务账户不能审批、人员不足禁止 TEST | RBAC |
| 37 | 机会真值、随机基线匹配和按日/标的聚类 bootstrap | 统计集成 |
| 38 | 每折从零重搜、折内验证次数为 0、折预算/种子/区间保存 | Cross-fit |
| 39 | TRAIN/VALIDATION/TEST 来源与自然频率契约 | 数据库/E2E |
| 40 | 暂定 Cross-fit 外层折 go/no-go、模型 B 暂定产物不可晋级、功效不足停止 | D 阶段 E2E |

任何追溯项缺少自动化证据、SQL 权限证据或不可变审计引用时，不得将对应验收项标记为通过。
