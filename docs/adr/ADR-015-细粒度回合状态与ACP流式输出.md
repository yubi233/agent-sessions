# ADR-015：细粒度回合状态与 ACP 流式输出契约

- 状态：Accepted（v0.8.4 P0 冻结契约；P1 桥、P2 adapter/Relay、P3 客户端实现与本文不符时，以修订本文为准，不允许实现层私改语义）
- 关联：[迭代计划 v0.8.4](../zh/迭代计划/迭代计划v0.8.4.md)、[ADR-014](ADR-014-DSH-ACP扩展与能力收口.md)、[ADR-013](ADR-013-DeepSeek-Harness-Provider接入.md)
- 事实锚点：外部 deepseek-harness 仓库 `packages/acp/acp/src/index.ts`（桥）、`packages/core/agent-loop/src/agent.ts`（`assistant/chunk` 增量源）、`internal/adapter/dsh/`（Go 适配器与状态机）、`packages/protocol/schema/*`（公共协议）

## 1. 决策

v0.8.4 解决三个可观测性缺口：

1. **回合状态过粗**：session 级 `MobileSessionStatus` 无法表达排队/思考/工具执行/收尾等回合阶段。新增独立的 `TurnPhase` 投影，经版本化 `dsh/turn/status` 通知承载，映射为 canonical `turn.phase` / `session.activity` 事件；session 级状态语义保持不变。
2. **DSH 没有真正增量输出**：桥的实时输出从"完整 assistant message 一帧"改为"每个 `text-delta` 一帧标准 `agent_message_chunk`"；Go adapter 映射为 canonical `message.delta`；completed 只由完整 assistant message（committed 帧）产生。
3. **reasoning 不可见**：`agent_thought_chunk` 默认直接开启 `raw` 投影（`thoughtVisibility=raw`），reasoning-delta 逐块进入独立 thought 通道；`hidden`/`summary` 仅作旧客户端或显式降级的兼容模式。终端所有者对自身终端拥有绝对所有权，不做敏感度一刀切禁止；raw thought 与 assistant answer 分开建模，绝不因渲染方便拼进回答正文。

## 2. Session 与 turn 分层

```text
SessionStatus（session 级，保持既有语义）: idle | active | stopped | errored | offline
TurnPhase（回合级，本期新增）: queued | preparing | thinking | streaming | tool_running |
           waiting_permission | waiting_question | finishing |
           cancelling | completed | cancelled | failed
```

- `queued`：输入已接收但尚未进入 agent turn；`preparing`：turn 启动/上下文组装；
- `thinking`：已有 reasoning activity，或尚未出现第一个文本 chunk；
- `streaming`：至少一个 `text-delta` 已投影且未收到 completed；**首个文本 chunk 之后，后续 thought delta 不回退 phase**（解决 thinking/streaming 交错歧义）；
- `tool_running`：tool call 已打开未收到配对结果；工具执行中弹出权限/问题时 phase 切到 `waiting_permission`/`waiting_question`，决策收到后由后续事件自然驱动回 active phase；
- `finishing`：模型输出已结束、等待 completed/turn end/usage 收口；迟到的文本 chunk 允许 `finishing → streaming` 回退（防御性合法转换）；
- `cancelling`：收到取消、等待底层收敛；`completed`/`cancelled`/`failed` 为终态。
- 同一 session 最多一个 active turn；历史 turn phase 只用于回放。所有状态变更带 `sessionId`、`turnId`、`step`、单调 `revision` 与安全 `reason`。

### 2.1 转换表（冻结）

合法转换（源 → 目标集合；同相位自环为 no-op 去重，不计违规）：

| 源 | 合法目标 |
| --- | --- |
| queued | preparing, cancelling, completed, failed |
| preparing | thinking, streaming, tool_running, waiting_permission, waiting_question, finishing, cancelling, completed, cancelled, failed |
| thinking | streaming, tool_running, waiting_permission, waiting_question, finishing, cancelling, completed, cancelled, failed |
| streaming | tool_running, waiting_permission, waiting_question, finishing, cancelling, completed, cancelled, failed |
| tool_running | thinking, streaming, tool_running, waiting_permission, waiting_question, finishing, cancelling, completed, cancelled, failed |
| waiting_permission | thinking, streaming, tool_running, finishing, cancelling, completed, cancelled, failed |
| waiting_question | thinking, streaming, tool_running, finishing, cancelling, completed, cancelled, failed |
| finishing | streaming, completed, failed, cancelling |
| cancelling | completed, cancelled, failed |
| completed / cancelled / failed | （无出边，terminal fence） |

非法转换（如 completed→streaming、failed→tool_running、queued→completed）一律丢弃并计数（`turn_phase_illegal_transition`），不产生事件、不推进 revision。未知 phase 字符串 fail-closed 丢弃计数，绝不映射为近似值。

### 2.2 旧客户端 fallback

- 未协商 `dsh/turn/status` 的 ACP client 收不到任何 phase 通知（fail-closed）；标准 `agent_message_chunk`/`agent_thought_chunk`/`tool_call` 语义不受影响。
- canonical 层旧客户端忽略未知 event type（`turn.phase`/`session.activity`/`message.thought_delta`），仍按 `message.completed`/`turn.completed` 正确关闭 streaming 状态；Relay `daemonObservationEventType` 之外的历史白名单不变。

## 3. `dsh/turn/status` 通知契约

- 方法名：`dsh/turn/status`（桥 → 客户端通知，只读投影；归入 ADR-014 §7 的 `dsh/*` 命名空间与协商体系，复用 `com.deepseek.dsh/extensions` `_meta` 键与 major/minor 版本规则）。
- 协商：客户端声明 `"dsh/turn/status": "1.0"`；桥未声明不发送；major 不匹配 fail-closed 不发送。
- params 严格 schema（未知字段拒绝，`dsh_extension_invalid_payload`）：

```json
{
  "protocolVersion": "1.0",
  "sessionId": "…",
  "turnId": "…",
  "step": 1,
  "phase": "streaming",
  "revision": 7,
  "reason": "first_text_delta",
  "safeSummary": "可选；≤200 字符的脱敏进展摘要"
}
```

- `reason` 白名单（冻结）：`turn_queued`、`turn_start`、`first_thought_delta`、`first_text_delta`、`tool_open`、`tool_close`、`permission_request`、`permission_resolved`、`question_request`、`question_resolved`、`model_output_end`、`cancel_requested`、`turn_end`、`turn_failed`、`turn_cancelled`。白名单外 reason 丢弃计数。
- 大小上限：`turnId` ≤128、`reason`/`phase` ≤64、`safeSummary` ≤200 字符；超限按畸形帧丢弃计数。
- **桥是实时 phase 的唯一权威**（它直接观测 chunk/thought/tool 流）；Go adapter 侧以本 ADR §2.1 转换表校验桥的投影：非法/回退/跨 session/重复 revision 帧丢弃计数。Go 侧仅在桥未投影时合成兜底终态（prompt 响应 → completed/cancelled/failed；session_error → failed），并保证终态 fence。
- `session.activity` 是 session 级聚合镜像（最新 active turn 的 phase），由 adapter 在转发 `turn.phase` 时同步产出，供会话列表等粗粒度消费方使用，不单独从桥接收。

## 4. 文本增量与 completed 契约

- 实时路径：`assistant/chunk(text-delta)` → 标准 `agent_message_chunk`（每个 delta 一帧）→ canonical `message.delta` → Relay `message.delta`。
- 已协商流式的桥在增量帧 `_meta` 携带 namespaced 身份：`com.deepseek.dsh/chunk = { kind: "text-delta", turn, step, seq }`；committed 帧携带 `{ kind: "committed", turn, step, messageId? }` 且 content 为权威全文。
- 消息身份：`messageId` 缺失时以 `t<turn>s<step>` 等价身份聚合；同一身份的 `message.completed` **替换**（而非追加）该身份的临时文本。一个 turn 内每条 assistant message 恰好一个权威 completed；中断时保留已发送前缀并标记 `interrupted=true`。
- 空文本 delta、重复 seq、乱序 seq、跨 session chunk 均拒绝或计数；`tool-call-delta` 只作为桥内组装输入，绝不广播半截 JSON。
- **回滚开关**：未协商流式能力的桥保持旧行为（完整 assistant message 一帧、无 `_meta`）→ Go 映射为 `message.completed`，行为与 v0.8.3 完全一致；任何一层失败降级为 completed-only 并给出准确 capability reason，不伪造 `native`。
- `session/load`、历史回放与断点恢复发送完整已提交消息（无 `_meta`、映射为 completed），不重放 token 动画；恢复后的新 turn 才启动增量。
- 输出队列有界：无法满足背压时暂停读取/发送，最终以明确错误或 cancelled 收口，禁止静默丢 chunk。

## 5. thought 通道契约（thoughtVisibility）

- 承载：标准 `agent_thought_chunk`；visibility 协商经 `com.deepseek.dsh/extensions` `_meta` 声明 `"dsh/thought": "1.0"` 并附 `thoughtVisibility` 偏好。
- **默认 `raw`**：reasoning-delta 逐块 → `agent_thought_chunk`（`_meta` 身份 `{ kind: "thought-delta", turn, step, seq, visibility: "raw" }`）→ canonical `message.thought_delta` → 独立 thought 事件与 UI。无需审批或显式开启。
- `summary`（显式降级）：不逐块发送；turn 结束时发送一帧计数级安全摘要（如"内部推理已折叠：N 段 / M 字符"），不含任何推理正文。
- `hidden`（兼容模式）：不发送 thought 内容，reasoning 活动只驱动 `dsh/turn/status` 的 `thinking` phase。
- 三种模式中 thought 都不写入 assistant answer 事件；未声明 thought capability 的客户端收不到任何 `agent_thought_chunk`。回放策略：raw 回放完整 thought 历史（独立通道），summary 回放摘要帧，hidden 不回放。
- 取消/中断收口：thought 通道与 text 通道各自维护 sequence，取消时各自以明确终态收口。

## 6. canonical 事件载荷白名单

| canonical 事件 | 载荷字段（全部脱敏白名单） |
| --- | --- |
| `message.delta` | `instance_id`、`message_id`、`text` |
| `message.thought_delta` | `instance_id`、`message_id`、`text`、`visibility` |
| `turn.phase` | `instance_id`、`turn_id`、`step`、`phase`、`revision`、`reason` |
| `session.activity` | `instance_id`、`turn_id`、`phase`、`revision` |

`message.completed`/`turn.completed` 载荷不变（新增可选 `interrupted` 布尔与 `message_id`）。任何 Provider 私有字段、路径、凭据、prompt 正文不进入上述载荷。

## 7. C 类边界与升格

- `delegate_session`、fs/terminal/MCP/NES 继续 unsupported，不因状态投影升格。
- DSH `streaming`/`turn_phase` 能力只在 P1（桥）、P2（adapter/Relay）、P3（客户端）gate 全部通过后，才从 `unsupported`/`partial` 升格；SDK 类型存在或 UI fixture 存在不构成升格依据。

## 8. 影响与回滚

- 影响面：DSH 桥（P1，独立仓库）、`internal/adapter/dsh`（状态机 + mapper）、`internal/daemon`（envelope/localdev）、`packages/protocol`（events/OpenAPI/生成物）、Flutter/Web（P3）。
- 回滚：流式关闭开关 = 客户端不协商 `dsh/turn/status` 与流式 `_meta`，桥自动回到 completed-only 旧路径；canonical 新事件类型对旧客户端不可见；无数据迁移，无破坏性变更。
