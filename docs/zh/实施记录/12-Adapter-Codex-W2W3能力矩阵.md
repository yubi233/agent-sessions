# Codex Adapter W2/W3：thread 映射与能力矩阵（ADPT-CODEX-02/03）

日期：2026-08-23 ｜ 状态：`delivered`（W1-W4 全部交付；执行侧由 AGENT_SESSIONS_CODEX_ENABLE feature flag 灰度）

## W4 授权 live smoke（ADPT-CODEX-04，已授权执行）

- 门禁：`AGENT_SESSIONS_CODEX_LIVE_SMOKE=1`（缺省 skip）；入口 `task test:real:codex`
- 预算：最小隔离 workspace（t.TempDir）+ 1 个对话 turn + 1 个 abort turn；显式 Dispose+Close 终止进程树
- 结果（2026-08-23T04:41Z）：chat turn 全链路事件到位（turn_started / message_delta / message_completed），instance id 持久化，dispose_close ok
- 已知边界：模型秒回时对已完成 turn 发 `turn/interrupt` 服务端返回 rpc -32600（turn 已 completed），属可接受结局，报告按错误类别脱敏记录
- 握手补充：真实 app-server 必须先 `initialize{clientInfo}` + `initialized` 通知（fake 注入路径不受影响）
- 波动性：首轮冷启动（MCP server 启动、上游延迟）可能显著偏慢，live gate 建议预留 240s timeout

## 协议证据锚点

- 本机 `codex app-server generate-json-schema`（codex-cli **0.142.5**，protocol v2）。
- 关键方法：
  - `thread/start{cwd?,model?}` / `thread/resume{threadId}` → `thread{id,turns[]}`
  - `turn/start{threadId,input:[{type:"text",text}],model?,effort?}` → `turn{id}`
  - `turn/interrupt{threadId,turnId}`
  - `skills/list{cwds?,forceReload?}` → `data[].skills[]:{name,description,enabled,path,scope}`
- 服务端通知：`thread/started`、`turn/started`、`item/started|completed`、
  `item/agentMessage/delta`、`turn/completed`、`turn/plan/updated{plan:[{step,status}]}`、
  `thread/goal/updated{goal:{objective,status}}`。
- 服务端请求（带 id 回调）：`item/commandExecution/requestApproval{itemId,command,...}`，
  响应 `{"decision":"accept|acceptForSession|decline|cancel"}`。

## Golden trace

`internal/adapter/codex/testdata/golden_trace.json`（fixture_version 1），9 场景契约全绿：

1. start+prompt 流式回复（turn_started/message_delta/message_completed）
2. 二次 send + commandExecution tool_call/tool_result
3. abort → turn/interrupt（无活跃 turn 时报错，不伪装）
4. resume 已有线程 → resumed；上下文为空 → restarted_with_context
5. resume 不存在线程 → unsupported（禁止伪装成功）
6. W3 审批 round-trip（permission_request → Respond accept → permission_decision）
7. W3 skills/list 目录拉取
8. W3 plan/goal 通知映射（plan_changed/goal_changed）
9. W3 model/effort turn 级覆盖参数

## 能力矩阵（Detect，bin 已探测时）

| 能力 | 状态 | 证据 |
| --- | --- | --- |
| start / resume / abort | native | golden trace 场景 1-5 |
| permission | native | 审批 round-trip（场景 6）；fileChange/mcp 审批尚未映射 |
| plan / goal | native | 通知映射（场景 8） |
| skill_catalog | native | skills/list（场景 7） |
| model_select / effort_select | native | turn/start 覆盖参数（场景 9） |
| question | unsupported | `item/tool/requestUserInput` 未实现 |
| invoke_skill | unsupported | turn input 的 skill UserInput 未实现 |
| kill | unsupported | 进程树所有权归 Adapter.Close 统一管理 |
| 其余（attachments/file_read/git_read/usage/fork/delegate_*） | unsupported | 未证明 |

bin 未配置时全部 fail-closed 并给出中文原因。

## 边界与回滚

- adapter 已按 feature flag `AGENT_SESSIONS_CODEX_ENABLE`（缺省关闭）接入 Daemon 执行侧 adapters map（`apps/daemon/main.go`），并新增 `SessionRunner.RegisterAdapter` 支持运行期补注册；开启即灰度，unset 即回滚。
- 无 CLI 文本 scraping；全部走 JSON-RPC typed 客户端。
- TurnError 明文按隐私边界只上报脱敏固定文案。
- 回滚：codex 能力矩阵随 bin 探测自动降级为全 unsupported。
