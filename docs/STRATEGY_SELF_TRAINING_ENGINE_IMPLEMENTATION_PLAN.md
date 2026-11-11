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

当前进度：已补充部署侧 `database/bootstrap_training_roles.sh`，可在迁移后创建独立 LOGIN 服务账户并执行最小权限检查；已在测试环境验证角色、schema 权限和连接身份。`compose.training.yaml` 的 `training` profile 继续只做 fail-closed 身份/连接 smoke check；独立的 `training-runtime` profile 已接入数据库租约、心跳、取消和有限失败码，并启用 `DATASET_BUILD` v1、`MODEL_A_CANDIDATE_SCAN` v1、`MODEL_A_EVALUATION` v1、`MODEL_A_L0_AGGREGATION` v1、`MODEL_B_REPLAY` v1、`PORTFOLIO_EVALUATION` v1、`OPTIMIZER_TRIAL` v1、`ARCHIVE_VERIFY` v1、`CROSS_FIT_COORDINATE` v1 与 `CROSS_FIT_PREDICT` v1。迁移 `038`—`045` 分别落实任务载荷、隔离执行身份、模型 A/B/组合评估上下文、随机基线、TRAIN-only TELL 和归档恢复验证；迁移 `046_training_optimizer_ask.sql` 只通过当前 Optimizer ASK 租约提供冻结搜索空间和顺序 TRAIN 历史；迁移 `047_training_optimizer_orchestration.sql` 建立 proposal、候选 iteration 与 ASK/TELL 推进；迁移 `048_training_model_a_candidate_scan.sql` 新增活动租约约束的 5m 候选扫描、受控 as-of 行情读取、`IN_SAMPLE_MODEL_A` 事件和不可变 entry batch；迁移 `049_training_random_baseline_strata.sql` 以 READY 配置驱动信号前波动率、流动性和 BTC 状态分层，并保存同候选触发但低于信号门槛的可信抽样框；迁移 `050_training_random_baseline_outcomes.sql` 为每个实际抽中的随机候选保存独立、完整的未来 MFE/MAE/Return 路径，缺少任一路径时数据库拒绝随机基线；迁移 `051_training_model_a_discovery_l0.sql` 以完整 5m 基础池建立可复用机会总体，通过 READY `SCORING_MODEL_A` 计算 OpportunityRecall、入场时机、超额 MFE、跨周稳定性和三项惩罚，并写入权威 TRAIN L0。worker 仍无权直接读取行情表或自行调用旧批次冻结入口。编排器当前可自动推进 `ASK_ENQUEUED → ITERATION_CREATED → SCAN_ENQUEUED → EVALUATION_ENQUEUED → L0_ENQUEUED → TELL_ENQUEUED`，并在 Cross-fit 两组搜索完成后推进冻结折外预测。Optimizer 只消费冻结 SEARCH_SPACE 和既有 TRAIN TELL；编排器只得到标识与动作码，不读取目标值。评分方法和配置契约已经实现，但各环境仍必须先审批并绑定实际数值为 READY 的 `SCORING_MODEL_A`，不得沿用测试夹具数值。A0 仍不能标记为完成，直到 `046`—`051` 和 runtime 在目标环境完成部署验收，以及 secret、角色成员关系、`application_name`、NATS/实盘权限和连接池配置全部通过。

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

当前进度：已完成首个 M6 治理与执行契约切片。迁移 `054_training_cross_fit_execution.sql` 恢复并收紧 Cross-fit 来源/用途约束，增加回补覆盖、源修订水位、质量证据哈希、Q-019/Q-029/Q-030/Q-036/Q-039 READY、逐折从零 TPE/同预算随机对照、零次折内 VALIDATION、功效不足停止、候选语料和不可变正式语料映射门禁。迁移 `055_training_model_b_formal_search.sql` 增加第 0 轮基线证据、全新 TPE/随机成对正式搜索、正式安全输入、临时/随机产物禁止注册与锁定，以及正式 `MODEL_B_TRAIN` 回放路径。迁移 `077_training_cross_fit_runtime_guards.sql` 进一步要求每个 TPE/RANDOM optimizer run 在启动扫描前绑定外层折有效 TRAIN 区间，完成折必须满足冻结的试验、墙钟和重复次数，并由数据库依据锁定阈值计算 Q-036 intersection-union 结论；模型 A 点估计/BCa CI 与模型 B 2 倍成本压力门任一未通过都不能产生 `PASS`。迁移 `078_training_cross_fit_optimizer_orchestration.sql` 和 `CROSS_FIT_COORDINATE` evaluator task 接入首折及后续折的同预算 TPE/RANDOM 原子创建、扩展窗口、上一折完成门禁、失败传播和冻结墙钟超时。迁移 `079_training_cross_fit_predictions.sql` 与 `CROSS_FIT_PREDICT` worker task 按 TRAIN-only objective 和固定 tie-break 冻结每组最佳 trial，只开放对应外层预测窗，保留一日历史池有效期，允许零事件形成可审计批次，并在 TPE/RANDOM 两组任务均成功前禁止折完成；不同外层折可在各自 optimizer scope 内重新评估相同参数。迁移 `080_training_cross_fit_prediction_evaluation.sql` 将两组折外预测接入结果计算、固定参考集随机基线和覆盖率报告。迁移 `081_training_cross_fit_fold_finalization.sql` 与 `CROSS_FIT_FINALIZE_FOLD` evaluator task 在两组评估成功后，以租约绑定方式记录折样本数、最低拟合样本功效、TPE/RANDOM 预测与覆盖证据，并明确暂定候选不注册为模型版本。迁移 `082`、`086`—`088` 已继续接入固定候选语料、UTC 日 BCa/Q-036 组合闸门、模型 B 候选策略编译以及通用 ASK/回放/组合目标/TELL 链路；编排器仍只读取 ID 与动作码，READY 协议严格解析，旧协议缺少运行预算时 fail closed。`019`—`088` 已在一次性 TimescaleDB 环境完成顺序迁移、重复迁移和全部 SQL 集成测试。当前剩余阻断项为按外层折先前语料执行的临时模型 B 嵌套运行、折外成本压力证据自动汇总，以及 PASS 后全新正式模型 B 运行的自动创建，因此 M6 尚不能标记为完成。

补充进度（2026-11-10，2026-11-11 更新）：迁移 `082_training_cross_fit_candidate_corpus.sql` 已把最后一个完整预测折识别为正常边界，并接入 `CROSS_FIT_FINALIZE_CORPUS` evaluator task。候选语料只包含同时满足拟合样本、TPE/RANDOM 成对覆盖和每折最低事件数的有效折中 TPE 可评估事件；有效折不能按收益结果筛选。BCa/Q-036 runtime gate 已由 `086` 接入；当前剩余阻断项缩小为逐外层折临时模型 B 嵌套评估、成本压力证据自动汇总与通过后的正式模型 B 自动启动。

配置治理补充（2026-11-10）：迁移 `083_training_model_b_config_contracts.sql` 新增独立 `MODEL_B_SEARCH_SPACE`，并在数据库 READY 边界校验规则型退出参数、24h/5m 持仓边界、UTC 日 BCa 成本压力评分和模型 B 样本来源/权重。训练配置页面将模型 B 的共享依赖与五项专属 DRAFT/READY 配置单独展示；页面建议模板只创建草稿，不构成参数审批，也不会自动启动训练。

分阶段退出补充（2026-11-11）：迁移 `084_training_model_b_staged_exit_rules.sql` 将新建的模型 B 退出配置升级为 Schema 2 `RULE_BASED_EXIT_V2`。初始止损搜索范围固定为 2%–10%，建议值 5%；固定模板在盈利 10%/15%/25%/35% 时分别平掉当时剩余仓位的 20%，最终保留 40.96%；对应止损依次锁定 1%/5%/15%/25%，25% 后按相对入场收益的最高水位保留 10 个百分点回撤。所有收益率以含滑点的入场成交价为基准，新止损下一根 5m K 线生效，同柱冲突仍按 `WORST_CASE`。每笔部分退出独立记录手续费、滑点和成交审计；既有 V1 READY 记录不改写，并继续按原绑定重放，但不计入模型 B READY 完整度，也不得再新晋级为 READY。

模型 B 候选运行时补充（2026-11-11）：迁移 `087_training_model_b_candidate_runtime.sql` 将每个 TPE/随机候选编译为与迭代一一绑定、追加写且不可变的有效退出策略。基础 `EXIT_RULES` READY 版本只作为审计锚点，不为候选复制或伪造新的 READY 配置；模型 B 回放与组合评估必须通过同一迭代覆盖层读取同一份有效策略。临时 Q-036 候选仅能读取冻结的 `CROSS_FIT_MODEL_A_CANDIDATE/GO_NO_GO` 语料，正式候选仅能读取晋级后的自然信号和明确控制样本。候选准备任务会按有效 `max_holding_seconds` 固化 episode，并为每个 episode 创建独立回放任务；搜索完成、组合目标回写和 TELL 的自动推进仍是下一运行时切片，不得把本切片解释为已可启动正式训练。

模型 B 优化器补充（2026-11-11）：迁移 `088_training_model_b_optimizer_runtime.sql` 已将 `MODEL_B_SEARCH_SPACE` 接入既有隔离 ASK/TELL 适配器，并新增 `PREPARE → REPLAY → PORTFOLIO_EVALUATION → TRAIN 净期望目标 → TELL` 的状态推进。自然事件未成交按零收益留在目标分母，对照样本不进入候选选择目标；任何退出风险违规都会使目标写入安全失败。优化器仍只读取聚合后的 TRAIN 目标，不能读取事件、回放或组合事实。迁移 `089_training_cross_fit_model_b_nested_evidence.sql` 进一步建立逐外层折的 `TRAIN_PRIOR/FOLD_OUT` 不可混用边界：临时候选准备只能读取本折 `training_end_at` 之前的事件；折外 episode 必须绑定本折独立评价迭代；成本压力值由原始 gross/funding/fee/slippage 按锁定倍数重新计算，并要求完整覆盖固定 Q-036 语料后才能汇入总闸门。该链路仍需接入临时实验及逐折 optimizer/evaluation iteration 的自动创建，以及 PASS 后全新正式运行的自动创建，尚不能宣称 M6 完成。

Model B 嵌套功效补充（2026-11-11）：迁移 `090_training_cross_fit_model_b_fold_eligibility.sql` 在任何临时 Model B 搜索前冻结 outcome-blind 的逐折资格快照。没有更早 Cross-fit 事件的首个预测折只记为 `WARMUP`，不得读取自身或未来折来凑训练样本；其余折只有同时具备历史训练事件、折外事件和 UTC 日覆盖才可记为 `ELIGIBLE`。系统按 Q-036 READY 的每折 100 事件、总计 15 个有效折、30 个独立日和 1,500 个完整事件重新检查功效，任一不足即以 `MODEL_B_NESTED_INSUFFICIENT_POWER` 进入 `INSUFFICIENT_POWER`，不解释为模型失败。逐折 optimizer/evaluation iteration 自动创建仍是下一切片。

Model B 嵌套搜索补充（2026-11-11）：迁移 `091_training_cross_fit_model_b_nested_search.sql` 在 090 资格通过后自动创建不可晋级的临时 `EXIT_POLICY` 子实验，复制父实验已经冻结的 READY 配置，并为首个及后续 `ELIGIBLE` 折创建同预算、同种子的 TPE/随机 optimizer 对。首对同时作为 Q-036 gate 的审计锚点；后续对只有在前一个有效 Model B 折成功后才能创建。每个 optimizer 候选仍只能通过 089 的 `TRAIN_PRIOR` 上下文读取本折之前的事件。独立折外评价 experiment/iteration、FOLD_OUT replay 和 evaluator 汇总任务仍需下一迁移接入。

阶梯搜索补充（2026-11-11）：第一阶段不开放八个相互独立的阶梯参数，而是在固定四阶形状上新增 `trigger_scale=0.8–1.2` 与 `shared_close_fraction=0.10–0.30`。`trigger_scale` 同步缩放止盈触发、锁盈值、最高水位启动值和允许回撤，避免破坏模板内部的风险递进关系；每档均按当时剩余仓位使用同一个 `shared_close_fraction`。候选必须最终保留至少 30% 仓位，因此高平仓比例可能形成无效组合；无效性只由冻结参数决定，记为失败并消耗优化预算，不读取结果指标。候选编译器固化原始参数、有效退出配置及各自内容哈希后再交给 TRAIN 回放，TPE 与随机对照使用相同编译和拒绝规则。迁移 `085_training_model_b_search_ladder_parameters.sql` 以追加方式移除旧版配置类型白名单约束，不回改已部署的 `083` 迁移。当前 Q-030 每折 20 次 TPE 预算下保持这两个新增自由度；若未来开放各档独立间距和仓位，须先新建并审批更高预算的 `CROSS_FIT_PROTOCOL`。

Q-036 运行补充（2026-11-11）：迁移 `086_training_cross_fit_q036_runtime.sql` 新增临时模型 B 闸门运行及逐事件成本压力证据，只有证据完整覆盖冻结候选语料且临时 TPE/随机运行均成功时，才允许投递 `CROSS_FIT_EVALUATE_GATE`。Evaluator 使用同一 UTC 日参考集计算模型 A BCa 区间和模型 B 2 倍成本压力 BCa 区间，数据库再次按锁定协议计算 intersection-union 判定；缺少模型 B 证据、参考日集合变化或数据库判定不一致均安全失败。PASS 后只晋级不可变正式语料，不复用临时优化器运行。候选策略持久化和通用回放编排已由 `087`—`088` 接入；逐外层折嵌套运行、折外成本压力证据汇总和 PASS 后正式运行自动创建仍是 M6 阻断项。

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

补充运行状态（2026-11-10）：`CROSS_FIT_FINALIZE_CORPUS` 已接入真实 evaluator 租约循环，末折之后不再尝试创建越出 TRAIN 区间的下一折。M6 仍未完成，也不得据此启动正式 Cross-fit。

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

当前切片已推进至 `M10`：训练工作区 API/UI、实验/失败/预算汇总、审计隔离和 `OPERATIONAL_ONLY` 运维入口已实现；工作区现要求显式、有效且未撤销的 `TRAINING_RESEARCHER`，产品 `ADMIN` 不再隐式取得训练访问权。`019`—`088` 迁移已通过一次性数据库顺序迁移、重复迁移和集成测试。`DATASET_BUILD`、`MODEL_A_CANDIDATE_SCAN`、`MODEL_A_EVALUATION`、`MODEL_A_L0_AGGREGATION`、`MODEL_B_PREPARE_CANDIDATE`、`MODEL_B_REPLAY`、`PORTFOLIO_EVALUATION`、`OPTIMIZER_TRIAL`、`ARCHIVE_VERIFY`、`CROSS_FIT_COORDINATE`、`CROSS_FIT_PREDICT`、`CROSS_FIT_FINALIZE_FOLD`、`CROSS_FIT_FINALIZE_CORPUS` 与 `CROSS_FIT_EVALUATE_GATE` 已接入真实租约循环；Optimizer 已实现可重放的真实 Optuna ASK、proposal 落库、候选迭代创建、5m 受控扫描、Q-033 配置驱动分层低分对照、被抽中候选的独立未来路径、完整基础池机会总体、配置驱动 DiscoveryScore、模型 B 迭代级有效退出策略、TRAIN-only TELL 及逐 trial 自动推进。M6 已接入同预算折内搜索、最佳 trial 冻结、折外预测/评估、候选语料、BCa 组合闸门和通用模型 B 候选执行；逐外层折临时模型 B 嵌套评估、成本压力证据自动汇总与正式模型 B 自动启动仍未接入。单次真实 SQL 集成夹具已验证 L0 成功终态、Optimizer 目标可见性和幂等重放；真实月度数据覆盖、独立自然人部署和生产环境 secret/RBAC 仍未完成，不能据此启动正式模型 B、VALIDATION、TEST、影子运行或完整训练流水线。
