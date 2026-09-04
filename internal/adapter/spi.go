// Package adapter 定义 Daemon 内统一 Provider Adapter SPI 与能力矩阵。
// 它是五个真实 Provider（Claude/Codex/OpenCode/OpenClaw/DeepSeek Harness）的共同底座；
// Provider 私有 payload 不得泄漏到客户端公共协议，未知能力默认 unsupported。
package adapter

import "context"

// 能力三态。未知能力必须按 unsupported 处理，不得推断为可用。
const (
	CapabilityNative      = "native"
	CapabilityEmulated    = "emulated"
	CapabilityUnsupported = "unsupported"
)

// 能力清单（与 packages/protocol 对齐）。客户端按此消费入口。
var CapabilityNames = []string{
	"start", "resume", "abort", "kill", "permission", "permission_mode", "question", "plan", "goal",
	"skill_catalog", "invoke_skill", "model_select", "effort_select",
	"attachments", "file_read", "git_read", "usage",
	"fork", "delegate_session", "delegate_cross_provider",
}

// ModelCapabilityDetail 是模型目录的安全元数据，用于上下文窗口和推理能力展示。
// 不包含 Provider 配置、凭据或请求正文。
type ModelCapabilityDetail struct {
	ContextWindowTokens int64    `json:"context_window_tokens,omitempty"`
	Reasoning           bool     `json:"reasoning"`
	Efforts             []string `json:"efforts,omitempty"`
}

// ModelCapabilityModel is one exact provider/model route advertised by DSH ACP.
// Value is the opaque ACP selector value and must be submitted unchanged.
type ModelCapabilityModel struct {
	Provider            string   `json:"provider"`
	Value               string   `json:"value"`
	ID                  string   `json:"id"`
	Name                string   `json:"name"`
	Description         string   `json:"description,omitempty"`
	ContextWindowTokens int64    `json:"context_window_tokens,omitempty"`
	Reasoning           bool     `json:"reasoning"`
	Efforts             []string `json:"efforts,omitempty"`
}

// ModelCapabilityGroup is a parent channel and its dynamically advertised models.
type ModelCapabilityGroup struct {
	ID     string                 `json:"id"`
	Name   string                 `json:"name"`
	Models []ModelCapabilityModel `json:"models"`
}

// Capability 描述单项能力状态与原因。
// Options 是 additive 选项目录（model/effort/permission_mode 等）：空表示不暴露目录，
// 客户端按 Status 决定入口是否可用，按 Options 渲染选择列表。
type Capability struct {
	Name    string   `json:"name"`
	Status  string   `json:"status"` // native | emulated | unsupported
	Reason  string   `json:"reason,omitempty"`
	Options []string `json:"options,omitempty"`
	// Default 是该能力目录的安全默认项（当前主要用于 model_select）。
	// 它必须同时存在于 Options 中；缺失时客户端不得自行猜测。
	Default string `json:"default,omitempty"`
	// ModelDetails 只对 model_select 生效，以模型引用为键提供上下文/推理白名单元数据。
	ModelDetails map[string]ModelCapabilityDetail `json:"model_details,omitempty"`
	// ModelGroups preserves ACP's provider-parent/model-child directory.
	ModelGroups []ModelCapabilityGroup `json:"model_groups,omitempty"`
}

// Capabilities 返回 Provider 的能力矩阵。
type Capabilities struct {
	Provider     string       `json:"provider"`
	Version      string       `json:"version"`
	Capabilities []Capability `json:"capabilities"`
}

// 六种唤醒结果。Resume 禁止把失败伪装成 resumed。
const (
	WakeResumed              = "resumed"
	WakeRestartedWithContext = "restarted_with_context"
	WakeUnsupported          = "unsupported"
	WakeLocalStateMissing    = "local_state_missing"
	WakeWorkspaceMoved       = "workspace_moved"
	WakeTerminalOffline      = "terminal_offline"
)

// EventType 是 canonical event 类型（客户端公共协议）。
type EventType string

// canonical 事件类型。
const (
	EventTurnStarted        EventType = "turn_started"
	EventUserMessage        EventType = "user_message"
	EventMessageDelta       EventType = "message_delta"
	EventMessageCompleted   EventType = "message_completed"
	EventTurnCompleted      EventType = "turn_completed"
	EventToolCall           EventType = "tool_call"
	EventToolResult         EventType = "tool_result"
	EventPermissionRequest  EventType = "permission_request"
	EventPermissionDecision EventType = "permission_decision"
	EventUserQuestion       EventType = "user_question"
	EventPlanChanged        EventType = "plan_changed"
	EventGoalChanged        EventType = "goal_changed"
	EventSkillCatalog       EventType = "skill_catalog_changed"
	EventUsage              EventType = "usage"
	EventFileChange         EventType = "file_change"
	EventDelegationChanged  EventType = "delegation_changed"
	EventSessionError       EventType = "session_error" // Provider 会话级错误（脱敏文案）
	// EventSessionAborted 是 Daemon 在 Abort 调用成功后生成的用户可见审计事件。
	EventSessionAborted EventType = "session_aborted"
	// v0.8.4（ADR-015）：细粒度回合状态与独立 thought 通道。
	// EventTurnPhase 投影回合阶段机（payload 白名单见 ADR-015 §6）；
	// EventSessionActivity 是 session 级聚合镜像（最新 active turn 的 phase）；
	// EventThoughtDelta 只承载 raw 模式的 reasoning 增量，与 assistant answer
	// 分开建模，绝不并入回答正文。
	EventTurnPhase       EventType = "turn_phase"
	EventSessionActivity EventType = "session_activity"
	// EventModesChanged 是 v0.8.6 B 的内部标记事件（不进 canonical 时间线）：
	// current_mode_update 改变句柄内 mode 快照后由 dsh handle 推出，事件泵据此
	// 调 syncModeInfo 把最新目录重上行 Relay（有变化才推，天然去重）。
	EventModesChanged EventType = "modes_changed"
	EventThoughtDelta EventType = "message_thought_delta"
)

// Event 是一条规范化事件。私有 Provider 字段不进入公共协议。
type Event struct {
	Type    EventType      `json:"type"`
	Seq     int64          `json:"seq"`
	Payload map[string]any `json:"payload"`
	// CreatedAtUnixMS is assigned once when the Daemon accepts the event into
	// the canonical stream. Zero is retained for legacy/history events.
	CreatedAtUnixMS int64 `json:"created_at_unix_ms,omitempty"`
	// ReplayOrdinal 是 Daemon 用于去重 ACP load 历史的内部字段，故意从公共 JSON 事件中省略。
	ReplayOrdinal int64 `json:"-"`
}

// Adapter 是 Daemon 与某类 Provider 的统一接口。
// 显式传入 context 以支持取消/超时；所有方法都是幂等或可安全重入的。
type Adapter interface {
	// Detect 探测安装状态与版本。
	Detect(ctx context.Context) (Capabilities, error)
	// Capabilities 返回能力矩阵。
	Capabilities() Capabilities
	// Start 启动一个新的会话实例，返回 handle。
	Start(ctx context.Context, req StartRequest) (Handle, error)
	// Resume 恢复已存在会话；必须返回六种唤醒结果之一。
	Resume(ctx context.Context, req ResumeRequest) (ResumeResult, error)
}

// StartRequest 是启动会话的输入。
type StartRequest struct {
	WorkspaceRoot string
	Provider      string
	Model         string
	Effort        string
	PlanMode      bool
	Prompt        string // 密文或本机状态；不写公共日志
}

// ResumeRequest 是恢复会话的输入。
type ResumeRequest struct {
	InstanceID    string
	WorkspaceRoot string
	// ReplayHistory 请求 ACP 使用 session/load 而不是 session/resume；这是 Daemon 内部提示，
	// 故意不进入命令 JSON 载荷。
	ReplayHistory bool `json:"-"`
}

// ResumeResult 明确区分唤醒结果，禁止伪装 resumed。
type ResumeResult struct {
	Result     string `json:"result"`
	InstanceID string `json:"instance_id,omitempty"`
}

// ResumeStreamingAdapter 是可选扩展，适用于在 Resume RPC 响应前发送回放事件的 Provider。
// 实现必须在传输初始化完成、load/resume 发出前调用 ready。回调让 Daemon 注册并消费事件流，
// 而无需把 runtime Handle 放进 ResumeResult 或 local_state。
type ResumeStreamingAdapter interface {
	ResumeStreaming(ctx context.Context, req ResumeRequest, ready func(Handle) error) (ResumeResult, error)
}

// ReplayCompletionHandle 在提供方完成 load 回放时关闭通知通道。
// Daemon 只有在收到该通知并排空已登记事件后，才能把本机回放状态标记为 complete。
type ReplayCompletionHandle interface {
	Handle
	ReplayComplete() <-chan struct{}
}

// Handle 是运行中的会话实例句柄，承载发送/中止。
type Handle interface {
	// Send 发送输入（流式）。
	Send(ctx context.Context, text string) error
	// Abort 中止当前 turn。
	Abort(ctx context.Context) error
	// Events 返回规范化事件流（供 mapper 消费）。
	Events() <-chan Event
	// Dispose 释放资源并清理进程树。
	Dispose(ctx context.Context) error
}

// InstanceIDHandle 由已经拿到 Provider canonical session ID 的 adapter 提供。
// 创建空会话时没有 turn_started 事件，Daemon 仍可安全持久化真实 Provider 会话绑定；
// 这不是事件伪造，也不会触发模型请求。
type InstanceIDHandle interface {
	Handle
	InstanceID() string
}

// ModelOverrideHandle 支持运行期更新会话模型（session.model_select / session.send
// 的随行模型）。由具备模型路由能力的 adapter 实现；daemon 按可选接口断言，不强制。
type ModelOverrideHandle interface {
	Handle
	SetModel(model string)
}

// EffortOverrideHandle 支持运行期更新会话推理档位（session.effort_select /
// session.send 的随行 effort）。由具备推理档位路由能力的 adapter 实现；
// daemon 按可选接口断言，不强制。
type EffortOverrideHandle interface {
	Handle
	SetEffort(effort string)
}

// PermissionOutcome 是一次权限决策的结果（与桥 request_permission 的 optionId 对齐）。
type PermissionOutcome string

const (
	// PermissionAllowed 允许一次（allow-once）。
	PermissionAllowed PermissionOutcome = "allowed"
	// PermissionRejected 拒绝（reject-once）。
	PermissionRejected PermissionOutcome = "rejected"
)

// PermissionDecisionHandle 由能把 ACP session/request_permission 请求挂起等待
// 一次性决策的 Handle 实现（v0.8.2 P1 pending permission registry）。
// daemon 收到 permission.respond 命令后按 requestKey 调用 ResolvePermission；
// 未知/重复/已取消请求返回错误（fail-closed），每个请求只允许一次决策。
type PermissionDecisionHandle interface {
	Handle
	// ResolvePermission 把一次性决策写回桥的原始 JSON-RPC 请求。
	// requestKey 是 permission_request 事件载荷中的 request_id（本实现=tool_call_id）。
	// allow=true 应答 allowed-once，false 应答 rejected；成功后广播 permission_decision。
	ResolvePermission(requestKey string, allow bool) error
}

// ForceKillHandle 只由明确拥有本机 Provider 进程树的 Handle 实现。它和 Abort 的语义不同：
// Abort 只取消当前 turn；ForceKill 必须在返回前启动受控进程树的终止流程。共享 HTTP 服务、
// 远端 Provider 或无法证明所有权的 Adapter 不得实现此接口。
type ForceKillHandle interface {
	Handle
	ForceKill(ctx context.Context) error
}

// dsh/* 扩展方法名（v0.8.3 冻结调用面；ADR-014 §7/§8）。daemon 的 runner 经
// ExtensionDispatchHandle 分发这些方法；adapter/dsh 包负责 envelope 注入与
// P0 wire 契约校验。通知（dsh/*/changed）是桥→客户端只读投影，不在此列。
const (
	ExtensionMethodQuestionAnswer = "dsh/question/answer"
	ExtensionMethodPlanSetMode    = "dsh/plan/set_mode"
	ExtensionMethodGoalGet        = "dsh/goal/get"
	ExtensionMethodGoalMutate     = "dsh/goal/mutate"
	ExtensionMethodSkillCatalog   = "dsh/skill/catalog"
	ExtensionMethodSkillInvoke    = "dsh/skill/invoke"
)

// SessionMode 是权限 mode 目录中的一项（ADR-014 §3；来自 DSH permission preset 表）。
type SessionMode struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// SessionModeInfo 是会话当前广告的权限 mode 目录与当前选中项。
// 目录为空表示桥/部署未广告 mode（能力保持 unsupported 的真相源）。
type SessionModeInfo struct {
	CurrentModeID  string
	AvailableModes []SessionMode
}

// SessionModeHandle 由支持运行期权限 mode 切换的 Handle 实现（v0.8.3 B-1）。
// SetMode 必须走桥的 session/set_mode（preset 原子 bundle 切换）；
// 未知/custom mode 由桥拒绝，错误原样返回（fail-closed）。
// Modes 返回最近一次 new/load/resume/current_mode_update 同步的目录快照。
type SessionModeHandle interface {
	Handle
	Modes() SessionModeInfo
	SetMode(ctx context.Context, modeID string) error
}

// QuestionAnswerItem 是一次结构化回答批次中的单题回答（ADR-014 §8）。
// Selected 与 CustomText 互斥表达；Skipped 表示本题跳过。
type QuestionAnswerItem struct {
	ID         string   `json:"id"`
	Selected   []string `json:"selected,omitempty"`
	CustomText string   `json:"custom_text,omitempty"`
	Skipped    bool     `json:"skipped,omitempty"`
}

// QuestionAnswerHandle 由能把桥 dsh/question/request 交互请求挂起等待一次性
// 回答的 Handle 实现（v0.8.3 B-5）。ResolveQuestion 按 requestKey 一次性回写
// 桥的原始 JSON-RPC 请求；未知/重复/已收口请求返回错误（fail-closed），
// 与 PermissionDecisionHandle 的 one-shot 语义一致。
type QuestionAnswerHandle interface {
	Handle
	ResolveQuestion(requestKey string, answers []QuestionAnswerItem) error
}

// ExtensionDispatchHandle 是 dsh/* 扩展方法的统一分发通道（v0.8.3 B-7/8/10）。
// method 必须位于 dsh/ 命名空间（如 dsh/goal/mutate、dsh/plan/set_mode、
// dsh/skill/invoke）；params 由 handle 注入 protocolVersion/sessionId envelope
// 并做 P0 wire 契约校验。结果原样返回给 runner 写命令回执。
type ExtensionDispatchHandle interface {
	Handle
	CallExtension(ctx context.Context, method string, params map[string]any) (map[string]any, error)
}

// ContentBlock 是混合内容块（v0.8.3 B-2 图像链路）。Type 为 text 或 image；
// ImageData 是 Daemon 授权解密后的图像字节（只经内存传给桥，绝不写日志/事件）。
type ContentBlock struct {
	Type      string
	Text      string
	ImageData []byte
	ImageMIME string
}

// ContentHandle 由支持混合内容发送的 Handle 实现（B-2）。实现必须复用与 Send
// 相同的 prompt 槽位、model/effort 前置下发和失败收口路径。
type ContentHandle interface {
	Handle
	SendContent(ctx context.Context, blocks []ContentBlock) error
}

// SessionLifecycleHandle 由桥提供生命周期方法的 Handle 实现（v0.8.3 B-3）。
// CloseSession 是可恢复的 graceful close；DeleteSession 只接受已 close 的冷
// 会话（桥侧墓碑+审计后回收）；ForkSession 复制 committed 前缀并返回新会话 ID。
type SessionLifecycleHandle interface {
	Handle
	CloseSession(ctx context.Context) error
	DeleteSession(ctx context.Context) error
	ForkSession(ctx context.Context, cwd string) (string, error)
}

// SessionSummary 是 session/list 的脱敏行（无物理路径/正文/凭据）。
type SessionSummary struct {
	SessionID string
	CWD       string
	UpdatedAt string
}

// SessionListResult 是一次脱敏分页列表。
type SessionListResult struct {
	Sessions   []SessionSummary
	NextCursor string
}

// SessionListProvider 由支持 session/list 的 Adapter 实现（v0.8.3 B-3）。
// list 不绑定单一运行会话，因此挂在 Adapter 层：实现自行为探测桥建立
// 短生命周期连接并在完成后回收。
type SessionListProvider interface {
	ListSessions(ctx context.Context, cwd string, cursor string) (SessionListResult, error)
}
