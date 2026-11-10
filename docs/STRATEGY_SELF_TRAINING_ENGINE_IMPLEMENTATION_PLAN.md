# 策略自训练引擎实施计划

**依据：** `STRATEGY_SELF_TRAINING_ENGINE_DEVELOPMENT.md` 0.1  
**实施原则：** 小步提交、先门禁后计算、先 TRAIN 后 VALIDATION/TEST、所有事实追加写入  
**当前边界：** 未确认的 Q 项数值不得成为代码默认值；以 READY 配置版本显式提供，缺失时安全失败

## 1. 交付策略

整个工程按可独立验收的纵向切片推进。每个切片必须同时包含领域契约、数据库约束、服务实现、审计和测试，不能先留下可绕过的空权限或仅靠前端限制。阶段间使用明确的 go/no-go 门，不以“接口已存在”代替数据、权限和复现证据。

所有实现遵守以下不变量：

- 只有 TRAIN 结果能驱动搜索、早停、参数阶段开放和下一轮候选；
- VALIDATION 只评估冻结终选集一次，结果不能回流优化器、大模型或继续搜索；
- TEST 使用独立 schema、服务账户和一次性原子消费，主 schema 只接收不透明证明；
- `CROSS_FIT_MODEL_A_CANDIDATE` 只服务 Q-036 go/no-go，不得晋级或进入正式模型 B、VALIDATION、TEST；
- READY 配置/数据集、LOCKED 模型和已完成事实不可原地修改；
- 未确认数值必须由版本化配置显式给出，缺失或未 READY 时拒绝启动；
- 任何阶段都不自动发布实盘策略。

## 2. 里程碑与依赖

### M0：工程契约与测试基线

交付：

- `auto_trade.training` 包、状态/分区/来源/拒绝码契约；
- UTC 左闭右开区间、purge/embargo、确定性 ID/哈希纯函数；
- 合法状态转换表和失败语义；
- 单元测试、集成测试目录约定和 `make test-integration` 入口设计。

验收：所有时间边界、非法状态转换、来源白名单和相同输入确定性测试通过。M0 不连接生产数据库，不启用训练任务。

### M1：A0 数据库治理基础

按迁移号顺序拆分，提交前重新扫描迁移目录：

1. `019`：三个 schema、NOLOGIN 角色、应用训练角色映射、追加式角色审计；
2. `020`：配置版本、数据集版本、成员、质量报告、暴露记录；
3. `021`：实验、迭代、状态日志、优化器和 VALIDATION 预算；
4. `022`：受控状态转换、READY 不可变、完成事实不可删改、基础授权；
5. `023`：历史时点合格池、资源预检和受控数据集事实写入；
6. `024`：完整复现清单和源修订触发的 STALE/SUPERSEDED 替代链。
7. `025`：数据库可信计算 Kline 最高可见修订、分片哈希和质量行数，撤销 worker 自报成员事实的旧权限。

临时 PostgreSQL/Timescale 集成测试由 `compose.integration.yaml` 和
`scripts/run_integration_tests.sh` 编排，不占用生产迁移号。

数据库迁移只创建 `NOLOGIN` 权限角色。另行交付部署引导，为 worker、orchestrator、evaluator、optimizer、weak-holdout、TEST executor/auditor/backup 创建或轮换彼此独立的 LOGIN、secret、连接池和 `application_name`，并验证它们不是 superuser、没有 `BYPASSRLS`，也不持有 `tb2_trader` 或实盘 NATS 发布权限。共享当前 `POSTGRES_USER` 不得作为 A0 完成状态。

部署引导脚本为 `database/bootstrap_training_roles.sh`。它必须在迁移成功后由部署系统执行，密码通过 `TRAINING_*_PASSWORD` secret 环境注入；脚本不打印或持久化 secret，缺少任一服务账户 secret 即失败。该脚本只创建 LOGIN 服务账户并授予对应 NOLOGIN 组角色，不替代迁移，也不直接启动训练任务。

验收：普通/通用角色无弱留出及 TEST `USAGE`；越界分区、非法转换、READY 修改均在数据库层失败；迁移可在空库完整应用并可重复跳过。

当前进度：已补充部署侧 `database/bootstrap_training_roles.sh`，可在迁移后创建独立 LOGIN 服务账户并执行最小权限检查；已在测试环境验证角色、schema 权限和连接身份。`compose.training.yaml` 的 `training` profile 继续只做 fail-closed 身份/连接 smoke check；独立的 `training-runtime` profile 已接入数据库租约、心跳、取消和有限失败码，并启用 `DATASET_BUILD` v1、`MODEL_A_CANDIDATE_SCAN` v1、`MODEL_A_EVALUATION` v1、`MODEL_A_L0_AGGREGATION` v1、`MODEL_B_REPLAY` v1、`PORTFOLIO_EVALUATION` v1、`OPTIMIZER_TRIAL` v1 与 `ARCHIVE_VERIFY` v1。迁移 `038`—`045` 分别落实任务载荷、隔离执行身份、模型 A/B/组合评估上下文、随机基线、TRAIN-only TELL 和归档恢复验证；迁移 `046_training_optimizer_ask.sql` 只通过当前 Optimizer ASK 租约提供冻结搜索空间和顺序 TRAIN 历史；迁移 `047_training_optimizer_orchestration.sql` 建立 proposal、候选 iteration 与 ASK/TELL 推进；迁移 `048_training_model_a_candidate_scan.sql` 新增活动租约约束的 5m 候选扫描、受控 as-of 行情读取、`IN_SAMPLE_MODEL_A` 事件和不可变 entry batch；迁移 `049_training_random_baseline_strata.sql` 以 READY 配置驱动信号前波动率、流动性和 BTC 状态分层，并保存同候选触发但低于信号门槛的可信抽样框；迁移 `050_training_random_baseline_outcomes.sql` 为每个实际抽中的随机候选保存独立、完整的未来 MFE/MAE/Return 路径，缺少任一路径时数据库拒绝随机基线；迁移 `051_training_model_a_discovery_l0.sql` 以完整 5m 基础池建立可复用机会总体，通过 READY `SCORING_MODEL_A` 计算 OpportunityRecall、入场时机、超额 MFE、跨周稳定性和三项惩罚，并写入权威 TRAIN L0。worker 仍无权直接读取行情表或自行调用旧批次冻结入口。编排器当前可自动推进 `ASK_ENQUEUED → ITERATION_CREATED → SCAN_ENQUEUED → EVALUATION_ENQUEUED → L0_ENQUEUED → TELL_ENQUEUED`。Optimizer 只消费冻结 SEARCH_SPACE 和既有 TRAIN TELL；编排器只得到标识与动作码，不读取目标值。评分方法和配置契约已经实现，但各环境仍必须先审批并绑定实际数值为 READY 的 `SCORING_MODEL_A`，不得沿用测试夹具数值。A0 仍不能标记为完成，直到 `046`—`051` 和 runtime 在目标环境完成部署验收，以及 secret、角色成员关系、`application_name`、NATS/实盘权限和连接池配置全部通过。

### M2：A0 数据集构建与审计

交付：历史时点合格池、源修订水位、分片/根指纹、依赖覆盖、warmup、purge/embargo、质量报告、STALE/SUPERSEDED 替代链和资源预检。

前置配置：Q-005、Q-015、Q-028、Q-031、Q-034、Q-035 对应版本必须 READY；没有 READY 版本只能生成诊断，不能把数据集标为 READY。

验收：源数据任一修订改变根指纹；缺失依赖不填 0；标签窗口不越界；重复构建得到相同成员清单和哈希。

当前进度：已完成。历史 as-of 合格池、显式依赖/容量门禁、数据库可信 Kline 修订水位与分片哈希、根指纹、完整复现清单、READY 门禁以及源修订替代状态链均已实现，并通过一次性数据库集成测试。部署 LOGIN/secret 与生产数据验证仍属于独立部署边界，未在本地自动执行。

### M3：A1 模型 A 基线数据链

交付：现有 V2 `feature_scan.py` 适配器、因子快照、低成本候选、信号、MFE/MAE/Return 24h、机会真值、匹配随机入场基线和 JSON/CSV/Parquet 导出。

前置配置：Q-032、Q-033 READY；训练/验证月 1m 覆盖审计完成前，只能标记 5m 原型。

验收：相同版本/数据/种子产生相同事件 ID、排序和标签；不可用因子保持不可用；随机基线保存抽样框、概率和重叠排除证据。

### M4：B 固定退出与组合仿真

交付：`FIXED_BASELINE_MODEL_A` 入场、模型 B 安全输入视图、固定退出原型、费用/滑点、成交、组合容量、权益曲线和逐时点重放。

前置配置：Q-005、Q-006、Q-007、Q-017、Q-037 READY。

验收：模型 B worker 无法读取来源、未来标签和最终结果；固定输入重放动作/成交逐字节一致，浮点结果满足 Q-028 容差。

### M5：C 编排、优化器与治理闭环

交付：任务表/锁、编排状态机、取消/恢复、Optuna 适配器与 checkpoint、统一候选校验器、L0/L1/L2、归档恢复、审批、训练 API/CLI 和资源准入控制器。

验收：优化器只得到 TRAIN 目标；非法候选不运行回测但完成 `tell(FAIL)`；崩溃恢复不重复写事实；VALIDATION 字段和 TEST 数据不可达。

### M6：D Cross-fit 与模型 B 正式搜索

交付：逐折从零搜索、折内 purge/embargo、暂定候选、TPE/同预算随机对照、Q-036 功效闸门、正式 `CROSS_FIT_MODEL_A` 语料和模型 B 搜索。

前置配置：Q-019、Q-029、Q-030、Q-036、Q-039 READY。

验收：折内 VALIDATION 次数为 0；功效不足返回 `INSUFFICIENT_POWER` 并停止；临时模型 B 产物不可进入注册表；通过后正式模型 B 必须全新运行。

当前进度：已完成首个 M6 治理与执行契约切片。迁移 `054_training_cross_fit_execution.sql` 恢复并收紧 Cross-fit 来源/用途约束，增加回补覆盖、源修订水位、质量证据哈希、Q-019/Q-029/Q-030/Q-036/Q-039 READY、逐折从零 TPE/同预算随机对照、零次折内 VALIDATION、功效不足停止、候选语料和不可变正式语料映射门禁。迁移 `055_training_model_b_formal_search.sql` 增加第 0 轮基线证据、全新 TPE/随机成对正式搜索、正式安全输入、临时/随机产物禁止注册与锁定，以及正式 `MODEL_B_TRAIN` 回放路径。迁移 `077_training_cross_fit_runtime_guards.sql` 进一步要求每个 TPE/RANDOM optimizer run 在启动扫描前绑定外层折有效 TRAIN 区间，完成折必须满足冻结的样本、试验、墙钟和重复次数，并由数据库依据锁定阈值计算 Q-036 intersection-union 结论；模型 A 点估计/BCa CI 与模型 B 2 倍成本压力门任一未通过都不能产生 `PASS`。Python 增加 READY 协议严格解析和租约绑定 repository，旧协议缺少运行预算时 fail closed。`019`—`077` 已在一次性 TimescaleDB 环境完成顺序迁移、重复迁移和全部 SQL 集成测试。Cross-fit optimizer 的自动创建/逐折推进、折外预测事件生成、BCa 统计 evaluator、临时模型 B 嵌套训练及正式模型 B 自动启动仍未接入任务 runtime，因此 M6 尚不能标记为完成，也不得创建正式 RUNNING Cross-fit。

### M7：C/F VALIDATION、弱留出与 TEST 隔离

交付：共享 validation scope 原子预算、冻结终选一次验证、10 月 `DECLARED` 弱留出、TEST 逻辑身份/内容版本、双人 readiness、SEALED 原子消费、失败重试和递归谱系检查。

前置条件：独立自然人的 `TRAINING_ADMIN` 与 `TRAINING_TEST_AUDITOR` 均有效；Q-038 流程和正式 TEST 月 1m 覆盖通过。

验收：预算不能通过新实验或内容版本重置；重复 TEST 消费只有一次成功；单人/同人审批失败；祖先消费相同逻辑 TEST 身份时后代拒绝。

### M8：E 可选 LLM 分析器

交付：TRAIN 白名单摘要、结构化响应、候选校验、search-space request 人工审批、出站域名和密钥审计。

验收：LLM 不可用、超时或非法 JSON 时不产生候选；载荷出现 VALIDATION/TEST/未来结果字段时拒绝。此里程碑不阻塞 TEST。

### M9：F 锁定、证据与影子导出

交付：模型锁定、正式 TEST 执行、证明哈希、审计导出和人工批准的 `SHADOW_EXPORT`；不自动接入实盘。

验收：开发文档第 11 章 40 项追溯全部有自动化或不可变证据，且 A0/A1/B/C/D 的必需门通过。

### M10：G 完整工作区

交付：训练工作区、实验/版本/预算/失败/审计页面和 `OPERATIONAL_ONLY` 运维页面；权威指标仍由后端计算。

验收：浏览器权限矩阵、403/空数据/网络失败/恢复状态和候选月后端 cutoff 门禁通过。

## 3. 每个里程碑的完成定义

每个里程碑只有同时满足以下条件才完成：

1. 代码、迁移、配置 schema、权限和审计一起交付；
2. 聚焦单元测试、数据库/服务集成测试按风险通过；
3. `ruff`、`mypy`、`git diff --check` 通过，仓库既有失败需单独记录；
4. 生成或更新复现清单，明确未做的浏览器、部署、生产数据验证；
5. 不覆盖用户现有改动，不自动迁移开发/生产数据库，不重建无关容器；
6. 阶段阻断项未满足时，状态保持原型/不可晋级，不能用人工备注绕过。

## 4. 当前实施状态

截至 2026-11-03，已完成并在一次性 TimescaleDB 集成环境验收：

- M0：领域契约、UTC 时间边界、确定性标识、状态机与单元测试；
- `019`：三个隔离 schema、NOLOGIN 最小权限角色、应用训练身份和追加式角色审计；
- `020`：READY 配置、TRAIN/VALIDATION 数据集、成员/质量/暴露事实及复现清单；
- `021`：TRAIN-only 实验/迭代、优化器检查点、冻结终选、共享 VALIDATION 逻辑身份和不可回收预算。

当前切片已推进至 `M10`：训练工作区 API/UI、实验/失败/预算汇总、审计隔离和 `OPERATIONAL_ONLY` 运维入口已实现；工作区现要求显式、有效且未撤销的 `TRAINING_RESEARCHER`，产品 `ADMIN` 不再隐式取得训练访问权。`019`—`055` 迁移已通过一次性数据库顺序迁移、重复迁移和集成测试。`DATASET_BUILD`、`MODEL_A_CANDIDATE_SCAN`、`MODEL_A_EVALUATION`、`MODEL_A_L0_AGGREGATION`、`MODEL_B_REPLAY`、`PORTFOLIO_EVALUATION`、`OPTIMIZER_TRIAL` 与 `ARCHIVE_VERIFY` 已接入真实租约循环；Optimizer 已实现可重放的真实 Optuna ASK、proposal 落库、候选迭代创建、5m 受控扫描、Q-033 配置驱动分层低分对照、被抽中候选的独立未来路径、完整基础池机会总体、配置驱动 DiscoveryScore、TRAIN-only TELL 及逐 trial 自动推进。M6 已增加 Cross-fit 与正式模型 B 的数据库/Python fail-closed 契约，但尚未把 Cross-fit 和正式搜索接入任务 runtime、真实 Optuna 与编排推进。单次真实 SQL 集成夹具已验证 L0 成功终态、Optimizer 目标可见性和幂等重放；实际评分权重与硬门槛仍须按环境审批为 READY。真实月度数据覆盖、独立自然人部署和生产环境 secret/RBAC 仍未完成，不能据此启动正式 Cross-fit、正式模型 B、TEST、影子运行或完整训练流水线。
