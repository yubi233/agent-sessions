# Happy Mobile 功能对比与 OpenCode 验证

> 状态：`completed`（功能审计与 OpenCode CLI smoke；Adapter transport 仍为 `blocked`）
> 日期：2026-08-15
> 输入：[v0.1 迭代计划](../迭代计划/迭代计划v0.1.md)、[项目文档](../项目文档.md)、[OpenCode 测试 suite](../../test/08-Adapter-OpenCode.json)
> 相关实现：[OpenCode Adapter](../../../internal/adapter/opencode/opencode.go)、[真实模型 gate](../../../e2e-verify/real/opencode-live.mjs)

## P2 Todo

- [x] 固定 Happy 源码版本并只从该版本的移动端实现提取能力项。
- [x] 对照 Agent Sessions 的 Flutter、Relay、Daemon 和 Adapter 代码，区分已覆盖、局部覆盖、明确排除和未实现项。
- [x] 将每个缺口映射到稳定测试 ID、现有回归或下一阶段的测试要求。
- [x] 建立统一的 OpenCode Go 真实模型 smoke，限制可恢复重试为每个 case 最多 3 次。
- [x] 先定义真实调用的回归内容，再执行真实模型校验；报告只保留哈希、事件类型和 usage 摘要。
- [x] 修正 OpenCode Adapter 的能力误报：未实现 transport 时，即使配置本地 URL 也必须 fail-closed。
- [x] 回填项目文档、测试地图、结构化 suite、e2e 入口和 P3 Adapter 实施记录。
- [x] 执行聚焦回归、文档校验与静态 gate，作为本阶段提交前验证。

## 对比来源与方法

Happy 的权威对比基线固定为[`slopus/happy@eb980a5c9eea25b1c145c06cd6241a0a365c2b6d`](https://github.com/slopus/happy/tree/eb980a5c9eea25b1c145c06cd6241a0a365c2b6d)。审计直接阅读该提交的移动端会话视图、会话快捷操作、文件侧栏、实时语音和 Inbox/Friends 实现：

- [`SessionView.tsx`](https://github.com/slopus/happy/blob/eb980a5c9eea25b1c145c06cd6241a0a365c2b6d/packages/happy-app/sources/-session/SessionView.tsx)
- [`useSessionQuickActions.ts`](https://github.com/slopus/happy/blob/eb980a5c9eea25b1c145c06cd6241a0a365c2b6d/packages/happy-app/sources/hooks/useSessionQuickActions.ts)
- [`FilesSidebar.tsx`](https://github.com/slopus/happy/blob/eb980a5c9eea25b1c145c06cd6241a0a365c2b6d/packages/happy-app/sources/components/FilesSidebar.tsx)
- [`RealtimeVoiceSession.tsx`](https://github.com/slopus/happy/blob/eb980a5c9eea25b1c145c06cd6241a0a365c2b6d/packages/happy-app/sources/realtime/RealtimeVoiceSession.tsx)
- [`InboxView.tsx`](https://github.com/slopus/happy/blob/eb980a5c9eea25b1c145c06cd6241a0a365c2b6d/packages/happy-app/sources/components/InboxView.tsx)

结论先由上述固定源码与本仓库实际代码得出。真实模型只接受封闭的优先级选项，用于检查该结论是否自洽，不能替代代码审计，也不能把模型回复当作功能事实来源。

## 功能矩阵

| 功能域 | Happy Mobile 基线 | Agent Sessions 当前实现 | 结论 | 后续动作 |
| --- | --- | --- | --- | --- |
| 会话列表、消息/工具时间线、停止 | 会话视图呈现消息、工具与运行状态 | Flutter 有列表、详情、流式时间线、工具事件、lease 保护 send/abort；P2/P6 fixture 及可见 macOS gate 已覆盖 | 本地体验已覆盖；真实 Provider 尚未贯通 | P0：接入 OpenCode transport 后跑真实 session start/send/abort gate |
| 权限与问题 | 会话内交互卡 | Flutter 有 permission/question 卡、所有权和 fencing 校验 | 本地链路已覆盖 | P0：在 canonical event 映射中验证真实请求和回答 |
| 模型、effort、Plan/Goal/Skill | 会话侧支持模型/操作控制 | Flutter 有 capability 三态、Plan/Goal/Skill 确认与 provider/model/effort 创建参数 | 局部覆盖；真实 Provider 不可兑现 | P0 transport 后按 capability 分项补 ADPT-OPENCODE-03 |
| 图片/文本附件 | 会话附件与文件操作 | 本地内存 draft、MIME/大小限制、加密 chunk、失败续传已实现 | 业务边界已覆盖 | P1：真实 Adapter 链路验证，不让 UI 代替 Provider 证据 |
| Git diff 与文件检查 | 文件侧栏、文件查看和 diff | 已实现受限 Workspace 的 Git status、文件树、搜索、unified/split、hunk、特殊文件降级 | Git diff 更受控；通用文件浏览仍缺失 | P1：增设只读通用文件浏览与内容搜索，复用 Workspace 安全校验 |
| resume、fork、duplicate、archive | 快捷操作覆盖恢复、分叉、复制和归档 | 有新建、停止、删除和本地 cursor 恢复；没有 fork/duplicate/archive，真实 Provider resume 仍 unsupported | 局部覆盖 | P1：先完成真实 resume 语义，再决定 fork/duplicate/archive 的数据模型与迁移 |
| 父子会话/跨 Provider | 会话侧支持并行操作，但不以 Agent Sessions 的加密 Delegation 作为同一契约 | 已有 parent-child Delegation 图、确认卡、独立 lease 和摘要隔离 | Agent Sessions 有专属安全能力 | 保持现状；真实 cross-provider 另做授权 gate |
| 生命周期、通知与 Push | 移动端实时状态与通知能力 | cursor 恢复、去重、失效 lease、应用内通知降级已完成；UnifiedPush 原生 distributor 未验收 | 局部覆盖 | P1：Android 原生和系统 Push 验收，不影响本轮 MacBook gate |
| usage/context、自动补全 | 会话使用量与辅助交互可见 | SPI 预留`usage`，Flutter 未形成完整 usage/context 与自动补全体验 | 未完成 | P2：定义数据来源、脱敏规则和移动 UI 回归 |
| 实时语音 | 实时语音会话 | 明确排除 | 非本轮范围 | P2/产品决策后单独立项 |
| Inbox、Friends、社交 feed | Inbox、好友、请求与 feed | 明确排除 | 非本轮范围 | 不纳入远程编码会话的 P0/P1 gate |

## 最高优先级：真实 Provider transport

代码审计发现，`internal/adapter/opencode.Adapter`过去会在配置`AGENT_SESSIONS_OPENCODE_URL`后把`start`、`resume`等能力标记为`native`，但其`Start()`仍返回不可用错误、`Resume()`仍返回`unsupported`。这会让客户端依据错误能力矩阵显示无法兑现的控制入口。

本轮在`internal/adapter/opencode/opencode_test.go`新增`ADPT-OPENCODE-01`回归，并把`Detect()`改为：未接入 HTTP/SSE/WS transport 时，无论 URL 是否配置，所有能力都返回`unsupported`并带出中文原因；同时不再凭一个未经验证的 URL 伪造 Provider 版本或可用状态。该修复保证移动端在真实链路完成前保持 fail-closed。

下一阶段的 P0 实施顺序：

1. 建立 OpenCode endpoint/version/auth 发现与本地 client，区分未配置、未启动、认证失败和未知协议版本。
2. 映射 create/send/abort、delta/tool/final/error 为`adapter.Event`，加 cancellation、断线和 cleanup 回归。
3. 加密持久化 provider session handle，落实`resumed`、`restarted_with_context`或`unsupported`三种真实恢复语义。
4. 只有上述 contract 与 Adapter 集成通过后，才将对应 capability 从`unsupported`升为`native`，并新增真实移动端 session gate。

## OpenCode Go 真实模型 smoke

### 录制前定义的回归内容

本阶段不录制视频，因为它没有用户可见页面，且真实 CLI 输出不能替代 Flutter 可见验收。执行前登记的测试内容如下：

| 测试 ID | 受控动作 | Oracle | 清理与证据 |
| --- | --- | --- | --- |
| `ADPT-OPENCODE-04` | 在临时空目录运行`opencode run --pure --format json`，不调用工具、不写文件 | 返回最小 JSON 算术结果，识别 assistant text event 与 token usage | 删除临时目录；报告保留事件类型、哈希和 usage |
| `HAPPY-OPENCODE-01` | 使用同一隔离调用对固定功能事实做封闭优先级审阅 | 返回`provider_transport`、`voice`、`social`之一；本轮必须为`provider_transport` | 删除临时目录；不保存原始 prompt/回复 |

运行入口固定为：

```bash
task test:real -- --provider opencode --model opencode-go/deepseek-v4-flash --retries 3
```

每个 case 最多一次首次请求和三次可恢复重试，仅允许`provider_timeout`或`provider_http_error`重试；模型输出契约失败不会通过重试标绿。两个 case 因而最多消耗八次真实请求。本轮用户允许真实调用且不限制 token。

### 实际结果

2026-08-15 的最新报告为[`04-live-smoke.json`](../../../e2e-verify/reports/2026-08-15T02-10-08-760Z/ADAPTER-OPENCODE/04-live-smoke.json)：

- `status=passed`，本机可发现`opencode-go/deepseek-v4-flash`。
- `ADPT-OPENCODE-04`和`HAPPY-OPENCODE-01`均在第 1 次真实请求成功，无重试。
- 共执行 2 次真实请求，观测到`9865` input tokens、`24` output tokens。
- `real_model=true`、`real_upstream=true`、`fixture_data=false`、`real_browser=false`、`headless=false`。
- `HAPPY-OPENCODE-01`返回的结构化结论是`highest_priority_gap=provider_transport`。

报告中的 request/session 标识只保存 SHA-256 短哈希；没有保存凭据、模型原文、用户提示、会话正文或浏览器/屏幕产物。该通过结论只覆盖本机 OpenCode CLI 真实调用，不能替代 Adapter transport、Flutter 可见窗口或 Android 实机验收。

## 覆盖与残余风险

| 需求 | 测试 ID | 层级/位置 | 本轮状态 | 残余风险 |
| --- | --- | --- | --- | --- |
| 已配置 URL 不伪造 native | `ADPT-OPENCODE-01` | Go unit，`internal/adapter/opencode/opencode_test.go` | passed | 其他 Provider 的 transport 也需各自审计 |
| OpenCode CLI 最小模型请求 | `ADPT-OPENCODE-04` | Node contract + authorized real model，`e2e-verify/real/` | passed | CLI 成功不证明 Daemon/Relay/Flutter 链路 |
| Happy 差距优先级一致性 | `HAPPY-OPENCODE-01` | Node contract + authorized real model，`e2e-verify/real/` | passed | 封闭模型审阅不是功能事实来源 |
| Flutter 用户可见流程 | `MOBILE-01..06`、`DELEG-01..07` | Flutter/Go + MacBook visible 5fps | 已有 P1-P6 证据 | Android AVD/实机与系统 Push 后续验收 |

本阶段不改变 Android gate：Android AVD、Android Keystore/Drift、UnifiedPush 和真机仍不阻塞本轮 MacBook 本地 Flutter 验收。Happy 的语音和社交能力保持明确排除；通用文件浏览、会话快捷操作、usage/context 与真实系统 Push 进入后续 P1/P2 排期，而不是以视觉 fixture 或模型 smoke 冒充已经交付。
