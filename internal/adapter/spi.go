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
)

// Event 是一条规范化事件。私有 Provider 字段不进入公共协议。
type Event struct {
	Type    EventType      `json:"type"`
	Seq     int64          `json:"seq"`
	Payload map[string]any `json:"payload"`
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
}

// ResumeResult 明确区分唤醒结果，禁止伪装 resumed。
type ResumeResult struct {
	Result     string `json:"result"`
	InstanceID string `json:"instance_id,omitempty"`
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

// ForceKillHandle 只由明确拥有本机 Provider 进程树的 Handle 实现。它和 Abort 的语义不同：
// Abort 只取消当前 turn；ForceKill 必须在返回前启动受控进程树的终止流程。共享 HTTP 服务、
// 远端 Provider 或无法证明所有权的 Adapter 不得实现此接口。
type ForceKillHandle interface {
	Handle
	ForceKill(ctx context.Context) error
}
