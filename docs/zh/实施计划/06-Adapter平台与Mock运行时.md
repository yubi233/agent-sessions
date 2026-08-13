# Adapter 平台与 Mock 运行时实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ADAPTER-PLATFORM` |
| owner | Provider Adapter Platform |
| status | `planned` |
| next_work_package | W1 SPI 与状态机 |
| blocked_by | 协议事件 schema 与 Daemon 进程监督未交付 |
| target | M4 / P3 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` + `DAEMON-SPI@v1-draft` |
| adr | ADR-003、ADR-004、ADR-006 |

## 1. 目标与明确排除项

建立 Daemon 内统一 Adapter SPI、canonical event mapper、能力矩阵、mock runtime 和 fixture harness。它是四个 Provider 的共同底座，不能把 Provider 私有 payload 泄漏到客户端公共协议。

不在这里实现 Claude/Codex/OpenCode/OpenClaw 的具体客户端或 live smoke；每个真实 Adapter 有独立计划和 feature flag。

## 2. 进入条件、输入和依赖

- 输入：协议事件/命令 schema、Daemon 进程监督、Relay session/command contract。
- 依赖：mock transport、确定性时钟/fixture、能力枚举和 Android/Web 消费 fixtures。
- 所有未知能力默认 `unsupported`，不得推断为可用。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 SPI 与状态机 | protocol event schema | 定义 `Detect/Capabilities/Start/Resume/Send/Abort/RespondPermission/SetMode/PlanAction/GoalAction/SkillCatalog/InvokeSkill/Dispose`；显式上下文和取消 | Go interface、typed requests/results | `ADPT-01` | contract | SPI compile/fixture report | 接口只兼容新增；未知 adapter disabled |
| W2 canonical mapper | W1 | 映射 Turn、Message、Tool、Permission、Question、Plan、Goal、Skill、Usage、FileChange；保留 source metadata 的加密侧带 | canonical event mapper | `ADPT-01` | unit + contract | golden trace | 丢弃未映射私有字段并生成 protocol error |
| W3 capability/模式 | W1 | 每项能力 `native/emulated/unsupported`；Plan/Goal/Skill 状态和风险确认语义 | capability contract、UI fixtures | `MODE-01..04` | contract + integration | state transition report | capability flag 关闭入口，不伪造 native |
| W4 mock vertical slice | W2/W3 | mock start/resume/send/stream/abort/permission/skill、可注入断线/超时/旧 instance | mock runtime、deterministic fixture harness | `ADPT-01`、`MODE-01..04` | integration | mock Relay/Daemon trace | 默认 mock 仅测试环境启用 |

## 4. 数据、权限、错误和事件边界

- ProviderThread handle 和上游原始参数作为密文或仅本机状态；公共 event 只含已定义 canonical 字段。
- `Resume` 必须返回 `resumed`、`restarted_with_context`、`unsupported`、`local_state_missing`、`workspace_moved` 或 `terminal_offline`，不能把失败伪装成恢复。
- Plan/Goal/Skill 的产品层状态由 canonical event 驱动；Provider 声称 capability 前必须通过专属 contract。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

先跑纯 SPI/mapper 单元，再运行 mock Relay-Daemon-Android fixture 垂直切片。真实上游、模型调用和 Provider 安装均为 false；相关计划独立申请授权。

## 6. 退出条件、阻塞和残余风险

退出：mock 能完整生成会话控制事件，所有能力三态可消费，状态机拒绝非法转换，未实现 Provider 不影响已有 adapter。

阻塞：公共 schema 无法表达某个必须产品语义、Provider 要求服务器解密，或需要 PTY 作为唯一基础实现。残余风险：真实上游协议和版本差异归四个专属计划。

## 7. 文档回填清单

回填 SPI、能力枚举、canonical event、mock fixture revision、错误语义和测试索引。
