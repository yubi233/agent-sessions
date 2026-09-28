// owner 配对加入（v0.10.0，ADR-017）：新 Android 设备以第二个 active owner
// 加入的未认证端面。创建/轮询两端点均经总开关与防滥用治理（TTL、单 pending、
// 审计），批准复用既有 owner 认证的 approve 端点（不撤销任何既有设备）。
package httpapi

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

type ownerPairingCreateRequest struct {
	DisplayName         string `json:"display_name"`
	Platform            string `json:"platform"`
	IdentityPublicKey   string `json:"identity_public_key"`
	EncryptionPublicKey string `json:"encryption_public_key"`
}

type ownerPairingCreateView struct {
	PairingID   string `json:"pairing_id"`
	CompareCode string `json:"compare_code"`
	Status      string `json:"status"`
	ExpiresAt   string `json:"expires_at"`
}

type ownerPairingStatusView struct {
	Status        string             `json:"status"`
	ExpiresAt     string             `json:"expires_at"`
	DisplayName   string             `json:"display_name,omitempty"`
	CompareCode   string             `json:"compare_code,omitempty"`
	DeviceID      string             `json:"device_id,omitempty"`
	AccessToken   string             `json:"access_token,omitempty"`
	RefreshToken  string             `json:"refresh_token,omitempty"`
	AccessExpires string             `json:"access_expires_at,omitempty"`
	Tokens        *ownerPairingToken `json:"-"`
}

type ownerPairingToken struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

// handleCreateOwnerPairing 未认证创建 owner 配对请求（ADR-017）：
// 总开关关闭 → 稳定 403；同账号已有 pending → 稳定 409；成功 201 并返回
// 比对码（新设备与 owner 双端展示核对）。
func (a *API) handleCreateOwnerPairing(c *gin.Context) {
	var req ownerPairingCreateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed owner pairing request"))
		return
	}
	// 总开关先于账号解析：关闭态不给公网任何账号存在性信息。
	// 传域错误让 mapError 给出 403/SCOPE_DENIED（而非 400）。
	if !a.Pairing.OwnerPairingEnabled {
		writeError(c, domain.ErrOwnerPairingDisabled)
		return
	}
	accountID, err := a.Repo.FirstAccountID(c.Request.Context())
	if err != nil {
		// 无账号的中继不存在「加入」语义（首部署走 device-bootstrap）。
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "relay has no account to join"))
		return
	}
	pairing, compareCode, err := a.Pairing.CreateOwnerPairingRequest(c.Request.Context(), domain.Device{
		AccountID:           accountID,
		Role:                domain.RoleAndroidOwner,
		Status:              domain.DeviceActive,
		DisplayName:         req.DisplayName,
		Platform:            req.Platform,
		IdentityPublicKey:   req.IdentityPublicKey,
		EncryptionPublicKey: req.EncryptionPublicKey,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, ownerPairingCreateView{
		PairingID:   pairing.ID,
		CompareCode: compareCode,
		Status:      pairing.Status,
		ExpiresAt:   pairing.ExpiresAt.UTC().Format("2006-01-02T15:04:05Z07:00"),
	})
}

// handleOwnerPairingStatus 新设备轮询配对状态；批准后一次性返回令牌对。
func (a *API) handleOwnerPairingStatus(c *gin.Context) {
	pairing, tokens, err := a.Pairing.OwnerPairingStatus(c.Request.Context(), c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	view := ownerPairingStatusView{Status: pairing.Status}
	if !pairing.ExpiresAt.IsZero() {
		view.ExpiresAt = pairing.ExpiresAt.UTC().Format("2006-01-02T15:04:05Z07:00")
	}
	if pairing.Role == domain.RoleAndroidOwner {
		view.DisplayName = pairing.DisplayName
		view.CompareCode = domain.OwnerPairingCompareCode(pairing.IdentityPublicKey, pairing.EncryptionPublicKey)
	}
	if pairing.Status == domain.PairingApproved && tokens != nil {
		view.DeviceID = tokens.DeviceID
		view.AccessToken = tokens.AccessToken
		view.RefreshToken = tokens.RefreshToken
		view.Tokens = &ownerPairingToken{AccessToken: tokens.AccessToken, RefreshToken: tokens.RefreshToken}
	}
	c.JSON(http.StatusOK, view)
}

// handleListPairings owner 配对页的 pending 清单（terminal 与 owner 请求均列出，
// 客户端按 role 区分渲染；owner 请求附比对码供人工核对）。
func (a *API) handleListPairings(c *gin.Context) {
	subj := subject(c)
	rows, err := a.Repo.ListPendingPairings(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]pairingView, 0, len(rows))
	for _, row := range rows {
		pairing := domain.PairingRequestFromRow(row)
		v := newPairingView(pairing)
		if pairing.Role == domain.RoleAndroidOwner {
			v.CompareCode = domain.OwnerPairingCompareCode(pairing.IdentityPublicKey, pairing.EncryptionPublicKey)
		}
		views = append(views, v)
	}
	c.JSON(http.StatusOK, gin.H{"pairings": views})
}
