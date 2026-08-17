package protocol

// 稳定错误码。客户端只能按码分支，不能依赖 message 文案。
const (
	ErrUnauthenticated         = "UNAUTHENTICATED"
	ErrDeviceRevoked           = "DEVICE_REVOKED"
	ErrOwnerRequired           = "OWNER_REQUIRED"
	ErrTokenReused             = "TOKEN_REUSED"
	ErrPairingExpired          = "PAIRING_EXPIRED"
	ErrReadOnlyDevice          = "READ_ONLY_DEVICE"
	ErrScopeDenied             = "SCOPE_DENIED"
	ErrLeaseConflict           = "LEASE_CONFLICT"
	ErrTargetInstanceStale     = "TARGET_INSTANCE_STALE"
	ErrIdempotencyConflict     = "IDEMPOTENCY_CONFLICT"
	ErrProtocolVersionMismatch = "PROTOCOL_VERSION_MISMATCH"
	ErrUpgradeRequired         = "UPGRADE_REQUIRED"
	ErrProtocolUnsupported     = "PROTOCOL_UNSUPPORTED"
	ErrUnknownPayloadVersion   = "UNKNOWN_PAYLOAD_VERSION"
	ErrUnknownEvent            = "UNKNOWN_EVENT"
	ErrCapabilityUnsupported   = "CAPABILITY_UNSUPPORTED"
	ErrWorkspaceMoved          = "WORKSPACE_MOVED"
	ErrWorkspacePathDenied     = "WORKSPACE_PATH_DENIED"
	ErrSnapshotStale           = "SNAPSHOT_STALE"
	ErrContentUnavailable      = "CONTENT_UNAVAILABLE"
	ErrTerminalOffline         = "TERMINAL_OFFLINE"
	ErrLocalStateMissing       = "LOCAL_STATE_MISSING"
	ErrDaemonRestartRecovery   = "DAEMON_RESTART_RECOVERY"
	ErrDaemonExecutionFailed   = "DAEMON_EXECUTION_FAILED"
	ErrPayloadTooLarge         = "PAYLOAD_TOO_LARGE"
	ErrDeadlineExceeded        = "DEADLINE_EXCEEDED"
	ErrInvalidRequest          = "INVALID_REQUEST"
)

// APIError 是 REST/WS/SSE 共用的错误体。
type APIError struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

func (e APIError) Error() string {
	if e.Message == "" {
		return e.Code
	}
	return e.Code + ": " + e.Message
}

// NewError 构造不泄露密钥或正文的稳定错误。
func NewError(code, message string) APIError {
	return APIError{Code: code, Message: message}
}
