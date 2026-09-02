package protocol

// 设备角色。android_owner / android 是移动写端；web 在本地 LLM 会话场景也被允许
// 提交会话写命令（主动发起对话），但仅限同账号单租户本地 Web 使用。
const (
	RoleAndroidOwner = "android_owner"
	RoleAndroid      = "android"
	RoleTerminal     = "terminal"
	RoleWeb          = "web"
	RoleAdmin        = "admin"
)

// 命令状态机。accepted 之后才允许进入 running。
const (
	CommandAccepted  = "accepted"
	CommandRunning   = "running"
	CommandSucceeded = "succeeded"
	CommandFailed    = "failed"
	CommandCancelled = "cancelled"
	CommandRejected  = "rejected"
	CommandExpired   = "expired"
)

// 六种唤醒结果，禁止把失败伪装成 resumed。
const (
	WakeResumed              = "resumed"
	WakeRestartedWithContext = "restarted_with_context"
	WakeUnsupported          = "unsupported"
	WakeLocalStateMissing    = "local_state_missing"
	WakeWorkspaceMoved       = "workspace_moved"
	WakeTerminalOffline      = "terminal_offline"
)

// 能力三态。未知能力必须按 unsupported 处理。
const (
	CapabilityNative      = "native"
	CapabilityEmulated    = "emulated"
	CapabilityUnsupported = "unsupported"
)

// CapabilityNames 是客户端必须消费的能力清单。
// v0.8.2 校对：补齐与 internal/adapter/spi.go 全量 20 项一致的 kill / permission_mode，
// 避免 SPI 与公共协议能力清单漂移（一致性守护测试固化的唯一真值清单）。
var CapabilityNames = []string{
	"start", "resume", "abort", "kill", "permission", "permission_mode", "question", "plan", "goal",
	"skill_catalog", "invoke_skill", "model_select", "effort_select",
	"attachments", "file_read", "git_read", "usage",
	"fork", "delegate_session", "delegate_cross_provider",
}

// DeviceRoleCanWrite 判断该角色是否允许提交会话写命令。
func DeviceRoleCanWrite(role string) bool {
	return role == RoleAndroidOwner || role == RoleAndroid || role == RoleWeb
}

// KnownWakeOutcomes 返回全部合法唤醒结果，供测试与 mock 注入。
func KnownWakeOutcomes() []string {
	return []string{
		WakeResumed, WakeRestartedWithContext, WakeUnsupported,
		WakeLocalStateMissing, WakeWorkspaceMoved, WakeTerminalOffline,
	}
}
