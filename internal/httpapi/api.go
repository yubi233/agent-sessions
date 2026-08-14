package httpapi

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/adapterreg"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

const subjectKey = "auth_subject"

// API 聚合领域服务与仓储，供 handler 调用。
type API struct {
	Auth         *domain.AuthService
	Pairing      *domain.PairingService
	Sessions     *domain.SessionService
	Capabilities *adapterreg.Registry
	Repo         store.Repository
}

// New 构造 HTTP API 聚合。
func New(auth *domain.AuthService, pairing *domain.PairingService, sessions *domain.SessionService, repo store.Repository) *API {
	return &API{Auth: auth, Pairing: pairing, Sessions: sessions, Capabilities: adapterreg.New(), Repo: repo}
}

// RequireAuth 是鉴权中间件：解析 Bearer token，校验有效期与设备状态，
// 并把 AuthSubject 写入 gin context。scope 由认证上下文推导，不信任客户端前缀。
func (a *API) RequireAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		raw := c.GetHeader("Authorization")
		token, ok := strings.CutPrefix(raw, "Bearer ")
		if !ok || token == "" {
			writeError(c, domain.ErrUnauthenticated)
			return
		}
		at, err := a.Repo.AccessTokenByValue(c.Request.Context(), token)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(c, domain.ErrUnauthenticated)
				return
			}
			writeError(c, err)
			return
		}
		if time.Now().After(at.ExpiresAt) {
			_ = a.Repo.DeleteAccessToken(c.Request.Context(), token)
			writeError(c, domain.ErrUnauthenticated)
			return
		}
		subj := domain.AuthSubject{
			AccountID: at.AccountID, DeviceID: at.DeviceID, Role: at.Role, DeviceOK: true,
		}
		// 设备令牌必须绑定仍有效且同账号同角色的设备，不能只信任 access_tokens 历史字段。
		if at.DeviceID != "" {
			dev, derr := a.Repo.DeviceByID(c.Request.Context(), at.DeviceID)
			if derr != nil {
				if errors.Is(derr, sql.ErrNoRows) {
					writeError(c, domain.ErrUnauthenticated)
					return
				}
				writeError(c, derr)
				return
			}
			if dev.AccountID != at.AccountID || dev.Role != at.Role {
				writeError(c, domain.ErrUnauthenticated)
				return
			}
			if dev.Status != domain.DeviceActive {
				writeError(c, domain.ErrDeviceRevoked)
				return
			}
		}
		c.Set(subjectKey, subj)
		c.Next()
	}
}

// RequireOwner 要求当前主体为 owner（设备管理操作）。
func (a *API) RequireOwner() gin.HandlerFunc {
	return func(c *gin.Context) {
		subj := subject(c)
		if !subj.IsOwner() {
			writeError(c, domain.ErrOwnerRequired)
			return
		}
		c.Next()
	}
}

// RequireWrite 要求当前主体可提交会话写命令（Android 控制端）。
func (a *API) RequireWrite() gin.HandlerFunc {
	return func(c *gin.Context) {
		subj := subject(c)
		if !subj.CanWrite() {
			writeError(c, domain.ErrReadOnlyDevice)
			return
		}
		c.Next()
	}
}

// subject 从 gin context 读取认证主体。
func subject(c *gin.Context) domain.AuthSubject {
	v, ok := c.Get(subjectKey)
	if !ok {
		return domain.AuthSubject{}
	}
	s, _ := v.(domain.AuthSubject)
	return s
}
