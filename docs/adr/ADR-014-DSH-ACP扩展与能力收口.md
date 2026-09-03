# ADR-014：DSH ACP 扩展契约与 v0.8.2 遗留能力收口

- 状态：Accepted（v0.8.3 P0 冻结契约；P5 收口后对应 handler/adapter/Relay/客户端 gate 全链路成立并按证据升格：permission_mode/fork → native、question/plan/goal/skill_catalog/invoke_skill → emulated（dsh/* extension 承载）、attachments → 条件式 unsupported（Relay opaque ref 未接通）；证据见[实施记录 21](../zh/实施记录/21-v0.8.3-DSH-ACP能力收口与交互扩展.md) P5 节）
- 关联：[迭代计划 v0.8.3](../zh/迭代计划/迭代计划v0.8.3.md)、[ADR-013](ADR-013-DeepSeek-Harness-Provider接入.md)、[实施记录 20](../zh/实施记录/20-v0.8.2-DSH能力补全与工具活动.md)、[实施记录 21](../zh/实施记录/21-v0.8.3-DSH-ACP能力收口与交互扩展.md)
- 事实锚点：外部 deepseek-harness 仓库 `packages/acp/acp/src/index.ts`（桥）、`internal/adapter/dsh/`（Go 适配器）、`internal/daemon/runner.go`（命令分发）、`packages/protocol/schema/*`（公共协议）

## 1. 决策

v0.8.3 把 v0.8.2 判定"可通过 DSH ACP bridge 较小范围改动接入"的能力全部实现收口，采用两层协议承载：

1. 有 ACP 对应语义的能力优先使用 ACP 标准/unstable 方法（`session/set_mode`、`session/request_permission`、`plan_update`、`available_commands_update`、unstable elicitation、image content block、`additionalDirectories`、session lifecycle capability）。
2. ACP 没有标准方法的能力使用版本化 `dsh/*` extension，并在 `initialize` 的 namespaced `_meta` 协商；未协商、版本不兼容或客户端断线时保持 `unsupported`/`cancelled`，不降级为无结构文本。

本 ADR 是 P0 冻结的跨边界契约唯一事实源；后续阶段（P1 桥、P3 adapter/Relay、P4 客户端）实现与本文不符时，以修订本文为准，不允许实现层私改语义。

## 2. 能力五态口径

每个 B 类能力必须记录以下五态之一，不允许混称：

| 态 | 含义 | 本期能力 |
| --- | --- | --- |
| ACP 标准 | ACP 稳定协议方法/字段直接承载 | B-1 mode（`session/set_mode`）、B-3 lifecycle（`session/close`/`session/list`/`session/delete`/`session/fork`）、B-4 additionalDirectories、B-11 `available_commands_update`、B-2 图像 content block |
| ACP unstable | SDK unstable 通道，须客户端显式声明 | B-6 elicitation（`unstable_createElicitation`）、B-5 question 的优先通道 |
| dsh extension | 版本化 `dsh/*` 私有 extension（`_meta` 协商） | B-5 question fallback、B-7 plan 状态、B-8 goal、B-9 skill 目录补充、B-10 skill invoke、B-12 delegation 投影 |
| 事件投影 | canonical 事件只读投影，无写回流 | B-12 delegation（`tool_call`/`tool_call_update` + `dsh/delegation/changed`）、plan/goal/skill 的 changed 通知 |
| unsupported | 无安全语义归属或缺少 DSH 等价语义，fail-closed | C 类全部（见 §9） |

升格规则不变：只有 bridge 标准能力/extension 与对应 handler、adapter、Relay、客户端 gate 全部存在时才可 `emulated`/`native`；`dsh/*` extension 承载的能力最高 `emulated`；任何一层缺失返回准确 `unsupported` reason。`dsh/*` 不对其他 ACP agent 宣称通用互操作。

## 3. permission mode 契约（B-1）

- mode 目录来自 DSH `permissionPresets` 的可用且可校验 preset；P0 冻结至少 `workspace-write`、`danger-full-access` 两个 modeId；若提供 `read-only`，必须先在 DSH 核心注册显式 preset，桥不得临时拼组合。
- `session/new`/`session/load`/`session/resume` 响应携带 `modes: { currentModeId, available: [{ id, name, description }] }`；缺 preset 服务或目录为空时不携带 `modes`，能力保持 unsupported。
- `session/set_mode` 只接受当前会话已广告的 modeId；未知/custom/已失效 mode 一律 `invalidParams` 拒绝。成功后发送 `session/update` 的 `current_mode_update`。
- 切换经 DSH 公开 preset setter 原子持久化 `permission/preset`、`sandbox/mode`、`approval/policy` 三件套；现有 setter 不满足原子性时先在 DSH 核心补原子 bundle API，任何失败不得留下半套事件。
- 边界：mode 修改绑定 session、live agent 与 expected revision；in-flight prompt 在 step 边界排队或明确拒绝，不得让当前工具获得意外升权；持久 Terminal 存在时必须通过其 mode fence。
- `DSH_PERMISSION_MODE` 环境变量只决定进程启动默认值，不是运行期切换通道，也不构成 capability 证据；恢复后的当前 mode 从持久 session projection 重建。

## 4. 图像与 opaque attachment ref 契约（B-2）

- Relay/移动端只持有 opaque attachment 引用（id、MIME、宽高、字节大小、哈希），不接触明文；Daemon 授权读取/解密后把图像转为 ACP `image` content block 发给桥。
- 桥侧 admission 复用 `content.ts`：服务挂载（`@deepseek-ai/dsh-attachment-local`）与模型 `inputModalities` 同时支持时开启，否则准确拒绝；`initialize` 的 `promptCapabilities.image` 如实反映。
- 助手侧图像输出沿用 `assistantBlockToAcp` 双向转换；失败按既有 outputError 收口，不伪造文本。
- 拒绝矩阵（fail-closed，均带脱敏中文原因）：text-only overlay、缺 attachment 服务、模型不支持图像、MIME 不在白名单、超大小/尺寸上限、哈希不符、无引用授权。失败不落明文日志，不产生半提交 attachment。

## 5. 会话生命周期契约（B-3）

- `session/close`：可恢复的 graceful close。与 `session/cancel`（仅终止当前 turn）和 `session/delete`（不可逆回收）分离。重复 close 幂等；关闭期间停止新 prompt，in-flight turn、pending question/permission、subagent drain 全部收敛后应答。
- `session/list`：只从 DSH persistence 返回授权范围内的脱敏元数据（sessionId、cwd basename 级展示名、状态、revision、时间戳），分页游标 + revision；不返回物理路径、正文、凭据。
- `session/delete`：只接受冷（已关闭/非运行中）会话；先写墓碑与审计并确认持久化，再回收物理数据；对运行中/未知会话拒绝。重试幂等（墓碑去重）。
- `session/fork`：只复制指定 revision 前的已提交事件前缀，生成新 sessionId 与父子元数据；不复制凭据、未提交尾部、pending 交互或运行中升权状态。fork 是普通 session fork，不等于 DSH subagent delegation，不改变 `delegate_session=unsupported`。
- close/delete/fork 三套状态机与幂等键分离，不得混用成功终态。

## 6. additionalDirectories 契约（B-4）

- `session/new`/`load`/`resume`/`fork` 请求中的 `additionalDirectories` 经规范化（绝对路径、`EvalSymlinks`）后绑定 workspace/session allowlist；拒绝：非绝对、不存在、重复、与 cwd 重叠、符号链接逃逸、越权根。
- 工具 sandbox 与 Agent Sessions readonly transport 使用同一授权真相（workspace registry 单一来源），不形成第二套授权结果。
- 规范化身份持久化进 session meta；恢复时重新校验（路径漂移、symlink 变更即拒绝），不直接信任客户端上次路径。

## 7. dsh/* extension 命名、协商与 envelope

- 命名：方法 `dsh/<domain>/<verb>`，通知 `dsh/<domain>/changed`；命名空间固定 `dsh/`，禁止复用未注册的 ACP 标准方法名。
- 协商：客户端在 `InitializeRequest.clientCapabilities._meta["com.deepseek.dsh/extensions"]` 声明 `{ <method>: <major.minor> }`；桥在 `InitializeResponse.agentCapabilities._meta` 同名键报告自己的目录。仅当客户端已声明对应 method 且 major 相同、minor ≤ 桥版本时启用；elicitation 与 plan 分别以 `clientCapabilities.elicitation.form`、`clientCapabilities.plan` 为准。
- envelope：每个 extension 请求/通知至少携带 `protocolVersion`（整数 major）与 `sessionId`；长交互另带 `requestId`（业务幂等键，JSON-RPC id 仍用于单次 method response）；状态修改另带 `expectedRevision`（CAS）。
- 版本规则：只允许向后兼容 minor 升级；未知字段严格拒绝；major 不匹配、重复 requestId、revision 倒退、跨 session 请求全部 fail-closed。
- 生命周期：transport failure、client error、EOF、dispose 必须收敛为明确错误或 `cancelled`；pending registry 绑定 session/agent/requestId 并挂 AbortSignal，超时（默认 120s，可配置）与断线统一收口，不允许无限 pending；通知发出不视为业务成功。

### 7.1 错误码（P0 冻结）

| 错误码字符串 | JSON-RPC code | 语义 |
| --- | --- | --- |
| `dsh_extension_unsupported` | -32601 | 客户端未声明或桥未启用该 extension |
| `dsh_extension_major_mismatch` | -32000 | 协议 major 不兼容 |
| `dsh_extension_invalid_payload` | -32602 | 严格 schema 校验失败（含未知字段） |
| `dsh_extension_duplicate_request` | -32000 | requestId 重复 |
| `dsh_extension_stale_revision` | -32000 | expectedRevision 与当前不一致（CAS 拒绝） |
| `dsh_extension_cross_session` | -32000 | 请求绑定与 payload session 不一致 |
| `dsh_extension_cancelled` | -32000 | 超时/断线/dispose 收口终态 |

## 8. 版本化 wire types（禁止复用插件私有 JSON）

以下类型在 Go 侧落在 `internal/adapter/dsh/wire.go`（P0 提交），桥侧（TS）按同一形状在 P1/P2 实现；两侧只依赖本节形状，不依赖 DSH 插件内部对象。

- **question**（B-5/B-6）：`DshQuestionItem { id, title, options[], multiSelect, allowCustomText, intent }`；answer 为逐题 `{ id, selected[], customText }` 一次性 batch；`intent=plan-review` 必须携带被审核 markdown detail 与 approve/keep-planning 自有选项，approve label 必须属于原问题选项（服务端复验）。string / single-select / multi-select 之外的字段类型拒绝，不静默丢 `intent`/`detail`。
- **plan**（B-7）：committed projection 只有 `{ active, pending }`，经 `dsh/plan/changed` 发送；`exit_plan_mode` 的完整 markdown 在提问前转 ACP `plan_update(type=markdown)`，审核结束发同 id `plan_removed`；不从 projection 或 assistant 文本合成 entries。`dsh/plan/set_mode` 只切 session-scoped plan mode，不改 sandbox/approval。
- **goal**（B-8）：`dsh/goal/get` 返回 `{ projection, revision, phase, roundCounters, timestamps }`；`dsh/goal/mutate` 只接受显式 operation（create/edit/pause/resume/complete/clear）+ `expectedRevision`，冲突返回 `dsh_extension_stale_revision`；round driver 自动状态只发 changed 通知。
- **skill**（B-9/B-10）：descriptor 白名单 `{ name, description, whenToUse, invocation }`；`path`、`resourceBase`、`locator`、provider metadata、skill body 不进目录。`catalogRevision` 只在 `complete=true` 时对排序后 descriptor 集合计算内容摘要；incomplete 保留 last-good 或保持 unavailable。`dsh/skill/invoke` 必须引用当前 `catalogRevision` 与已广播的 `userInvocable` skill name；未知/未广播/过期 revision 一律拒绝，不降级为普通 prompt。
- **delegation**（B-12）：`dsh/delegation/changed` 字段仅 `{ runId, parentSessionId, state(running|completed|failed|cancelled), provider, local, stopReason?, summary? }`；不发送 task envelope、child 正文、凭据或本地路径；start 只在 child 已发布后出现，不合成 proposed 状态；parent dispose/断线触发 child-first drain，终态只能收敛 completed/failed/cancelled。

## 9. C 类边界（继续 unsupported，不伪造）

`file_read`/`git_read`（Agent Sessions 已有独立 readonly transport，桥 fs 工具重复接入会产生两套授权真相）、ACP `fs/*`（方向为 Agent→Client，需改变 DSH 本地 fs 执行域）、terminal（PTY owner/生命周期跨域）、editor/NES、MCP 管理、`delegate_session`/`delegate_cross_provider`、ACP-controlled child session delegation。理由与 v0.8.3 计划 §3.2 一致；观察类投影（B-12）不得提升 delegation 能力。

## 10. V08-12 迁移与 resume→send 修复口径

- 历史 `p4-dsh-v08-resume-*` failed 报告不改写；`docs/test/18` 的 V08-12 用例保持 failed。
- 根因域在桥侧：`session/set_config_option(model)` 发生于 `session/load` 之前时，load 重建的 record 从持久事件/配置恢复路由，先前客户端选择的模型丢失，恢复后 prompt 以错误路由发出（`model_route_or_protocol_failure`）。
- 修复验收（V083-07）：deterministic bridge 回归固定复现 `initialize → session/new → set_config_option(model) → session/load → session/prompt` 序列，断言 load 后 selection/preset/事件 cursor/turn owner/output settlement 全部保持；P5 经用户显式授权后另立真实模型报告，不覆盖历史。
- Go 侧同口径回归：Resume（ReplayHistory）→ Send 前必须重新下发 model/effort（`appliedModel/appliedEffort` 在新 handle 上从空开始），断言恢复会话不带旧路由静默发送。

## 11. 影响与回滚

- 影响面：`internal/adapter/dsh/wire.go`（新增）、fake bridge 场景（测试内）、`packages/protocol/schema/commands.json`（追加 `question.answer`、`session.fork`，纯 additive）、`docs/test/21-DSH ACP扩展能力.json`、能力矩阵后续阶段按 gate 升格。无 SQLite 迁移、无破坏性公开 API 变更。
- 回滚：extension 契约为 additive；回滚即桥/adapter 停止广告 `dsh/*`，客户端按未协商 fail-closed 保持 unsupported；能力矩阵自动回落，不需要数据动作。
