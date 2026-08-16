// Package httpapi 是 Relay 的传输层：Gin handler、鉴权中间件与错误映射。
// 本层只做绑定、鉴权、调用 use-case 与响应映射，不写 SQL、不编排业务规则。
package httpapi

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// mapError 把领域错误映射为稳定协议错误码与 HTTP 状态。
// 客户端只能按 code 分支，不能依赖 message 文案；正文/密钥不得进入错误体。
func mapError(err error) (int, protocol.APIError) {
	var protocolErr protocol.APIError
	if errors.As(err, &protocolErr) {
		return http.StatusBadRequest, protocolErr
	}
	switch {
	case errors.Is(err, domain.ErrInvalidCredentials), errors.Is(err, domain.ErrUnauthenticated):
		return http.StatusUnauthorized, protocol.NewError(protocol.ErrUnauthenticated, "authentication required")
	case errors.Is(err, domain.ErrDeviceRevoked):
		return http.StatusForbidden, protocol.NewError(protocol.ErrDeviceRevoked, "device revoked")
	case errors.Is(err, domain.ErrOwnerRequired):
		return http.StatusForbidden, protocol.NewError(protocol.ErrOwnerRequired, "owner device required")
	case errors.Is(err, domain.ErrLastOwner):
		return http.StatusConflict, protocol.NewError(protocol.ErrOwnerRequired, "last owner cannot be revoked")
	case errors.Is(err, domain.ErrTokenReused):
		return http.StatusUnauthorized, protocol.NewError(protocol.ErrTokenReused, "refresh token reused")
	case errors.Is(err, domain.ErrPairingExpired):
		return http.StatusGone, protocol.NewError(protocol.ErrPairingExpired, "pairing request expired")
	case errors.Is(err, domain.ErrPairingNotFound):
		return http.StatusNotFound, protocol.NewError(protocol.ErrInvalidRequest, "pairing request not found")
	case errors.Is(err, domain.ErrPairingAlreadyHandled):
		return http.StatusConflict, protocol.NewError(protocol.ErrInvalidRequest, "pairing request already handled")
	case errors.Is(err, domain.ErrRecoveryLocked):
		return http.StatusTooManyRequests, protocol.NewError(protocol.ErrInvalidRequest, "recovery code locked")
	case errors.Is(err, domain.ErrRecoveryInvalid):
		return http.StatusUnauthorized, protocol.NewError(protocol.ErrInvalidRequest, "invalid recovery code")
	case errors.Is(err, domain.ErrReadOnlyDevice):
		return http.StatusForbidden, protocol.NewError(protocol.ErrReadOnlyDevice, "read-only device")
	case errors.Is(err, domain.ErrTerminalRequired):
		return http.StatusForbidden, protocol.NewError(protocol.ErrScopeDenied, "terminal device required")
	case errors.Is(err, domain.ErrProtocolUpgradeRequired):
		return http.StatusUpgradeRequired, protocol.NewError(protocol.ErrUpgradeRequired, "daemon protocol upgrade required")
	case errors.Is(err, domain.ErrProtocolUnsupported):
		return http.StatusConflict, protocol.NewError(protocol.ErrProtocolUnsupported, "daemon protocol unsupported")
	case errors.Is(err, domain.ErrScopeDenied):
		return http.StatusForbidden, protocol.NewError(protocol.ErrScopeDenied, "resource scope denied")
	case errors.Is(err, domain.ErrBootstrapCompleted):
		return http.StatusConflict, protocol.NewError(protocol.ErrInvalidRequest, "owner bootstrap already completed")
	case errors.Is(err, domain.ErrAccountExists):
		return http.StatusConflict, protocol.NewError(protocol.ErrInvalidRequest, "account exists")
	case errors.Is(err, domain.ErrRegistrationClosed):
		return http.StatusConflict, protocol.NewError(protocol.ErrInvalidRequest, "initial owner already exists")
	case errors.Is(err, domain.ErrLeaseConflict):
		return http.StatusConflict, protocol.NewError(protocol.ErrLeaseConflict, "lease conflict")
	case errors.Is(err, domain.ErrTargetStale):
		return http.StatusConflict, protocol.NewError(protocol.ErrTargetInstanceStale, "target instance stale")
	case errors.Is(err, domain.ErrDaemonCommandState):
		return http.StatusConflict, protocol.NewError(protocol.ErrIdempotencyConflict, "daemon command state conflict")
	case errors.Is(err, domain.ErrIdempotencyUsed), errors.Is(err, domain.ErrDelegationInvalidState):
		return http.StatusConflict, protocol.NewError(protocol.ErrIdempotencyConflict, "delegation decision conflict")
	case errors.Is(err, domain.ErrDelegationUnsupported):
		return http.StatusConflict, protocol.NewError(protocol.ErrCapabilityUnsupported, "delegation capability unsupported")
	case errors.Is(err, domain.ErrDelegationBoundary):
		return http.StatusForbidden, protocol.NewError(protocol.ErrScopeDenied, "delegation workspace or terminal denied")
	case errors.Is(err, domain.ErrDelegationNotFound):
		return http.StatusNotFound, protocol.NewError(protocol.ErrInvalidRequest, "delegation not found")
	case errors.Is(err, domain.ErrSessionNotFound), errors.Is(err, domain.ErrWorkspaceNotFound):
		return http.StatusNotFound, protocol.NewError(protocol.ErrInvalidRequest, "session not found")
	case errors.Is(err, domain.ErrAttachmentNotFound):
		return http.StatusNotFound, protocol.NewError(protocol.ErrInvalidRequest, "attachment not found")
	case errors.Is(err, domain.ErrAttachmentConflict), errors.Is(err, domain.ErrAttachmentAlreadyClosed):
		return http.StatusConflict, protocol.NewError(protocol.ErrIdempotencyConflict, "attachment upload conflict")
	case errors.Is(err, domain.ErrAttachmentIncomplete):
		return http.StatusConflict, protocol.NewError(protocol.ErrInvalidRequest, "attachment upload incomplete")
	case errors.Is(err, domain.ErrAttachmentInvalid), errors.Is(err, domain.ErrAttachmentChunkOrder):
		return http.StatusBadRequest, protocol.NewError(protocol.ErrInvalidRequest, "invalid attachment upload")
	default:
		return http.StatusInternalServerError, protocol.NewError(protocol.ErrInvalidRequest, "internal error")
	}
}

// writeError 统一写出脱敏错误响应。
func writeError(c *gin.Context, err error) {
	status, apiErr := mapError(err)
	c.AbortWithStatusJSON(status, apiErr)
}

// writeOK 写出成功响应。
func writeOK(c *gin.Context, v any) {
	c.JSON(http.StatusOK, v)
}
