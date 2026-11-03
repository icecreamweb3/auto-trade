# 策略自训练引擎进度跟踪表

**更新时间：** 2026-11-03  
**代码基线：** `293cbca`  
**依据：** `STRATEGY_SELF_TRAINING_ENGINE_IMPLEMENTATION_PLAN.md`、当前仓库实现、测试环境部署证据  
**总体判定：** 主干工程能力已实现到 M5，并提前交付了 M7–M10 的部分治理与界面切片；测试环境四个 TRAIN runtime 已空载启动并通过身份隔离检查，但尚无任何 READY 配置、数据集、实验或任务，未跑通真实 TRAIN 闭环，不能标记为“整体完成”，也不能启动正式 VALIDATION、TEST 或影子运行。

## 1. 状态口径

| 状态 | 含义 |
|---|---|
| 完成 | 代码、数据库、自动化测试、目标环境部署和运行验收均已有证据 |
| 实现完成，待环境验收 | 代码和自动化测试已具备，但尚未在目标环境用真实配置/数据完成运行验收 |
| 进行中 | 核心实现已存在，仍缺少必需能力或端到端证据 |
| 契约/原型 | 只有领域契约、数据库骨架或局部算法，不具备正式运行条件 |
| 阻断 | 前置配置、数据、权限或独立人员条件未满足 |

任何“文件已存在”“迁移已执行”或“镜像已构建”均不单独等同于里程碑完成。

## 2. 里程碑总表

| 里程碑 | 目标 | 当前实现与证据 | 测试环境状态 | 当前判定 | 完成前仍需 |
|---|---|---|---|---|---|
| M0 工程契约与测试基线 | 契约、UTC 边界、状态机、确定性 ID、测试入口 | `contracts.py`、状态/来源白名单、确定性逻辑和训练单元测试已存在；本次 Python 3.12 环境收集 159 项，156 通过、3 跳过 | 不依赖运行环境 | 完成 | 保持回归测试持续通过 |
| M1 A0 数据库治理基础 | schema、RBAC、LOGIN、审计、独立运行身份 | `019–052` 已实现；`052` 增加受控 DRAFT 创建/编辑和审计；10 个独立 LOGIN 角色、成员关系及非 superuser/非 BYPASSRLS 已验证 | 测试环境当前部署至 `051`；四个 runtime 已常驻启动并通过身份隔离检查 | 实现完成，`052` 待部署 | 执行 `052` 并重建 monitor-api/UI；后续新增 Model B/LLM runtime 时按相同边界验收 |
| M2 A0 数据集构建与审计 | as-of 数据集、指纹、质量、STALE/SUPERSEDED | `dataset_builder`、`dataset_repository`、`dataset_lifecycle`、可信 Kline 分片和迁移 `023–025` 已实现；数据库集成夹具已有 | 尚未对测试环境真实月份执行完整数据集构建和质量验收 | 实现完成，待真实数据验收 | 审批并绑定 READY 前置配置；运行真实覆盖/容量/依赖审计；保存复现清单 |
| M3 A1 模型 A 基线链 | 候选、信号、标签、机会总体、随机基线、DiscoveryScore | 迁移 `026–028`、`039`、`043`、`048–051`；候选扫描、评价和 L0 handler 已实现；随机基线含波动率、流动性、BTC 状态、低分触发对照及独立未来路径 | `049–051` 已部署；配置、数据集、实验和任务当前均为 0，未用真实 TRAIN 数据跑通 | 实现完成，待配置与 TRAIN smoke | 审批评分权重/硬门槛及其余 READY 配置；创建真实数据集和单个 trial；验证 L0、机会召回、超额 MFE、幂等重放 |
| M4 B 固定退出与组合仿真 | 模型 B 安全输入、费用滑点、成交和组合重放 | `simulator.py`、`simulation_service.py`、MODEL_B_REPLAY、PORTFOLIO_EVALUATION handler 与迁移 `029–030`、`041–042` 已存在 | 未执行真实固定退出/组合仿真闭环 | 进行中 | READY 费用、滑点、退出和容量配置；真实事件重放；逐字节/容差复现证据 |
| M5 C 编排与优化器闭环 | 租约、状态机、Optuna、ASK/TELL、归档与资源门禁 | 迁移 `031`、`038`、`040`、`044–047`；真实 Optuna ASK、proposal、candidate iteration、TRAIN-only TELL 和自动任务推进已实现 | 四个 runtime 已空载运行且身份验证通过；因无 READY 配置/数据集，尚无真实 `ASK → L0 → TELL` 环境闭环 | 实现完成，待环境闭环 | 建立审批后的 READY 配置；跑一个受限实验；验证心跳、取消、崩溃恢复、重复执行和资源准入 |
| M6 D Cross-fit 与模型 B 正式搜索 | 逐折重搜、功效闸门、正式语料和模型 B 搜索 | `cross_fit.py`、`evaluator.py`、迁移 `033` 和来源隔离契约已有 | 无 runtime handler/真实外层折运行证据；第一阶段数据大概率不足 | 契约/原型 | Q-019/029/030/036/039 READY；实现逐折任务编排和嵌套训练；累计数月数据并通过功效检查 |
| M7 VALIDATION、弱留出与 TEST 隔离 | 原子预算、弱留出、双人审批、一次性 TEST | 迁移 `032`、`034`；`validation_scope.py`、`weak_holdout.py`、`test_executor.py` 和隔离测试已有 | 未封存正式 TEST；独立自然人审批条件未验证 | 治理基础完成，运行阻断 | 配置 cutoff/候选月；验证 UI/API/直连隔离；落实第二位自然人；完成 readiness 和原子消费演练 |
| M8 可选 LLM 分析器 | TRAIN 白名单摘要、结构响应、人工审批和出站限制 | 迁移 `035`、`llm_advisor.py` 及单元测试已有 | 未接真实 LLM 网关；未做出站域名/密钥运行验收 | 契约/原型 | 实现真实网关和 secret 注入；非法载荷、超时、审计及网络限制验收；非 TEST 阻断项 |
| M9 锁定、证据与影子导出 | LOCKED、正式 TEST 证据、审计导出、SHADOW_EXPORT | 迁移 `036`、`promotion.py` 和 M9 集成约束已有 | 无正式 TEST、晋级或影子导出运行证据 | 契约/原型 | 必须先完成 M3–M7 门禁；运行锁定、TEST、证据包和人工影子导出全过程 |
| M10 完整工作区 | 实验、版本、预算、失败、审计及运维页面 | 已实现 READY 配置清单、14 项齐备矩阵、DRAFT 新建/乐观锁编辑、服务端校验、TRAINING_ADMIN 审批/退役和审计；既有 workspace/operational-only 保持隔离 | 代码和本地自动化验证通过，尚未在测试环境部署 `052` 和新 monitor-api/UI，也未完成浏览器权限矩阵 | 实现完成，待环境验收 | 部署 `052` 和监控服务；用研究员/管理员/无授权用户分别验证编辑、审批和 403；继续补实验及审计浏览页面 |

## 3. 测试环境部署跟踪

| 编号 | 检查项 | 当前证据 | 状态 | 下一动作 |
|---|---|---|---|---|
| DEP-01 | 数据库迁移 | `019–051` 在测试环境记录为成功 | 完成 | 后续迁移继续按序执行 |
| DEP-02 | LOGIN 与组角色 | 10 个训练 LOGIN 均非 superuser、非 BYPASSRLS，成员关系匹配 | 完成 | 定期轮换 secret 并复验 |
| DEP-03 | env secret | `training-roles.env` 权限检查通过；四个 runtime 必需变量存在且非空 | 完成 | 不入库、不打印；纳入部署系统托管 |
| DEP-04 | Worker/Orchestrator 镜像 | `auto-trade:local` 已于 2026-11-03 重建 | 完成 | 启动并核验数据库身份 |
| DEP-05 | Optimizer 镜像 | `auto-trade-training-optimizer:local` 已重建；Optuna 4.9.0 可导入 | 完成 | 启动并核验 ASK 租约与目标隔离 |
| DEP-06 | Evaluator 镜像 | `auto-trade-training-evaluator:local` 已重建；PyArrow 26.0.0 可导入 | 完成 | 启动并核验评价租约与归档能力 |
| DEP-07 | 四个 runtime 常驻服务 | Worker、Orchestrator、Optimizer、Evaluator 已使用提交 `3066e4e` 的新镜像滚动重建，身份验证通过，重启计数均为 0 | 完成 | 运行真实任务时继续监控心跳和重启计数 |
| DEP-08 | `application_name` 与连接池 | 四个独立 LOGIN 各有 1 条 idle 连接，`application_name` 均正确；每服务 `pool_size=1`、`max_overflow=0` 已在容器内生效 | 完成 | 启用第五个 Model B runtime 前复核全局连接数不超过 READY 配置 |
| DEP-09 | NATS/实盘权限隔离 | 四个 runtime 的 `NATS_URL` 均为空；训练 LOGIN 没有任何 `tb2_trader` 成员关系 | 完成 | 后续新增 Model B/LLM 服务时重复验收 |
| DEP-10 | 真实训练任务 | 当前没有已验收的真实训练任务 | 未开始 | 从单数据集、单 trial、限制资源的 smoke 开始 |

## 4. 当前关键路径

| 顺序 | 工作项 | 进入条件 | 退出证据 | 当前状态 |
|---:|---|---|---|---|
| 1 | 启动四个 `training-runtime` 服务 | 镜像和 secret 已就绪 | 四服务健康；角色、`application_name`、连接池和权限隔离通过 | 完成 |
| 2 | 建立测试环境 READY 配置清单 | 所有待定数值完成人工审批 | 数据集、搜索空间、随机基线、评分、资源和费用配置均为版本化 READY | 阻断：当前配置版本为 0 |
| 3 | 构建一个真实 TRAIN 数据集 | M1/M2 环境门禁通过 | READY 数据集、质量报告、成员/分片/root hash、复现清单 | 待执行 |
| 4 | 跑通单个模型 A trial | READY 数据集与 `SCORING_MODEL_A` 已绑定 | `ASK → ITERATION → SCAN → EVALUATION → L0 → TELL` 全链成功 | 待执行 |
| 5 | 做恢复与安全验收 | 单 trial 成功 | 幂等重放、取消、超时、崩溃恢复、非法来源和越权均按预期拒绝 | 待执行 |
| 6 | 扩展模型 A TRAIN 搜索 | 资源预算和 go/no-go 口径 READY | 多 trial 稳定运行，基线与随机搜索比较证据完整 | 待执行 |
| 7 | 进入 M4 固定退出与组合仿真 | 模型 A 基线通过 | 固定退出净期望、费用滑点和组合容量证据 | 待执行 |
| 8 | 进入 M6 Cross-fit | 至少数月可用数据且功效前检通过 | 暂定 Cross-fit 闸门通过，正式语料重新生成 | 数据阻断 |
| 9 | VALIDATION/TEST/SHADOW | M6 通过、双人治理和正式未见月成立 | 一次性 VALIDATION、原子 TEST、证据包及人工影子批准 | 治理与数据阻断 |

## 5. 自动化验证快照

| 日期 | 范围 | 命令/环境 | 结果 | 说明 |
|---|---|---|---|---|
| 2026-11-03 | 训练单元测试 | `.venv/bin/python -m pytest -q tests/unit/test_training_*.py`，Python 3.12 | 159 项：156 通过、3 跳过 | 系统 Python 3.10 不满足项目 `>=3.12`，不得用于判定回归 |
| 2026-11-03 | 数据库迁移 | 测试环境 TimescaleDB | `019–051` 成功 | 迁移成功不代表真实训练闭环成功 |
| 2026-11-03 | 镜像依赖 | 测试环境 Docker | 三个物理镜像构建成功；Optuna/PyArrow 导入通过 | Worker 和 Orchestrator 共用 `auto-trade:local` |
| 2026-11-03 | runtime 空载部署 | 测试环境 Docker/PostgreSQL | 四服务运行；独立 LOGIN/`application_name` 正确；NATS 禁用；无 `tb2_trader` 继承 | 初启时 PostgreSQL recovery 导致各重启 3 次，随后稳定 |
| 2026-11-03 | 训练对象盘点 | 测试环境 PostgreSQL | READY/DRAFT 配置、数据集、实验和任务全部为 0 | 符合安全失败预期，不能创建真实 trial |
| 2026-11-03 | runtime 连接池重部署 | 测试环境提交 `3066e4e` | 四容器新镜像运行、重启 0、每服务连接池 `1/0`、实际连接总数 4 | 未重启数据库及其他业务服务 |
| 2026-11-03 | READY 配置管理 | 本地 Python/TypeScript/临时 TimescaleDB | 新增单元测试通过；全部 unit 测试通过（3 跳过）；UI `npm run build` 通过；`make test-integration` 全量通过，包含 `052` 重复迁移、DRAFT 创建/编辑/审计和 READY 不可变 | 尚未部署测试环境，不代表 14 类数值已经获批或存在 READY 记录 |

## 6. 测试环境 READY 配置清单

以下是首个模型 A TRAIN smoke 的最小配置集合。当前全部缺失；数值必须由人工审批后创建版本，不能复制集成测试夹具或由部署脚本静默生成。

字段级审批口径见 `STRATEGY_SELF_TRAINING_ENGINE_CONFIG_APPROVAL.md`。`052` 与训练工作区提供受控配置管理入口，但当前数值仍待人工审批；界面不会自动生成或批准默认值。

| 用途 | 配置类型 | 当前状态 | 说明 |
|---|---|---|---|
| 数据集 | `TICKER_POOL_RULES` | 缺失 | Ticker 池规则与逻辑身份 |
| 数据集 | `DATA_QUALITY_RULES` | 缺失 | 覆盖率、缺口和质量门槛 |
| 数据集 | `HOLDING_HORIZON_RULES` | 缺失 | 标签与最大持仓边界 |
| 数据集 | `ELIGIBLE_POOL_RULES` | 缺失 | 历史时点合格池规则 |
| 数据集 | `REPRODUCIBILITY_TOLERANCE` | 缺失 | 确定性与浮点容差 |
| 数据集/实验 | `RESOURCE_LIMITS` | 缺失 | 重型实验、worker、连接、CPU/内存限制 |
| 数据集 | `FEE_MODEL` | 缺失 | 费用版本 |
| 数据集 | `SLIPPAGE_MODEL` | 缺失 | 流动性/波动率相关滑点 |
| 数据集 | `VISIBILITY_CUTOFF_POLICY` | 缺失 | 研究可见截止策略 |
| 模型 A | `FACTOR_REGISTRY` | 缺失 | 5m 因子和预热契约 |
| 模型 A | `SEARCH_SPACE` | 缺失 | Optuna 冻结搜索空间 |
| 模型 A | `RANDOM_BASELINE` | 缺失 | 分层、抽样概率与重叠排除 |
| 模型 A | `OPPORTUNITY_DEFINITION` | 缺失 | 机会总体真值定义 |
| 模型 A | `SCORING_MODEL_A` | 缺失 | DiscoveryScore 权重和硬门槛 |

## 7. 更新规则

每次推进后只更新以下事实，不以主观百分比代替证据：

1. 修改里程碑“当前实现与证据”“测试环境状态”“当前判定”；
2. 在部署跟踪中记录实际运行结果，失败项不得改为完成；
3. 在关键路径中只把有不可变证据的工作项标为完成；
4. 在自动化验证快照中追加日期、精确范围、命令/环境和结果；
5. 若 READY 配置、数据覆盖、独立审批人或功效不足，明确标为阻断，不用默认值绕过；
6. 正式 VALIDATION、TEST 和 SHADOW 前必须重新进行一次全表审核。
