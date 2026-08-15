// Package adapter 定义 Daemon 内统一 Provider Adapter SPI 与能力矩阵。
// 它是四个真实 Provider（Claude/Codex/OpenCode/OpenClaw）的共同底座；
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
	"start", "resume", "abort", "permission", "permission_mode", "question", "plan", "goal",
	"skill_catalog", "invoke_skill", "model_select", "effort_select",
	"attachments", "file_read", "git_read", "usage",
	"delegate_session", "delegate_cross_provider",
}

// Capability 描述单项能力状态与原因。
type Capability struct {
	Name   string `json:"name"`
	Status string `json:"status"` // native | emulated | unsupported
	Reason string `json:"reason,omitempty"`
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
	EventMessageDelta       EventType = "message_delta"
	EventMessageCompleted   EventType = "message_completed"
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
