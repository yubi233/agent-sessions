package domain

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// 会话内容密钥（DEK）分发（v0.8.5 §3.2 / ADR-016）：
// 生成方 = Daemon（明文仅本机），wrapped blob 经 Terminal 上行落 device_key_wraps，
// owner 设备读取后用设备私钥 unwrap 密封附件；任何路径不落明文或可解密元数据。
var (
	// ErrContentDEKConflict 表示会话已有不同内容 DEK id（防降级覆盖）。
	ErrContentDEKConflict = errors.New("content dek conflict")
	// ErrContentDEKNotFound 表示会话尚无内容密钥（fail-closed：附件禁选并显示等待文案）。
	ErrContentDEKNotFound = errors.New("content dek not found")
)

// ContentDEKProjection 是 owner 读取的最小投影：只含本设备的 wrapped blob 与 id。
type ContentDEKProjection struct {
	DEKID       string
	RecipientID string
	WrappedDEK  []byte
}

// PutSessionContentDEK 让 home Terminal 为会话登记内容 DEK 的 wrapped blob（ADR-016 §3.1）。
// 校验链：home Terminal 归属 → recipient 是同账号 active owner → 会话 content_dek_id 空则
// 写入（Set + PutKeyWrap）；同 dekID 幂等放行；异 dekID 拒绝（ErrContentDEKConflict）。
func (s *DaemonService) PutSessionContentDEK(ctx context.Context, accountID, deviceID, role, sessionID, dekID string, wrapped []byte, recipientDeviceID string) error {
	if strings.TrimSpace(dekID) == "" || len(wrapped) == 0 || strings.TrimSpace(recipientDeviceID) == "" {
		return protocol.NewError(protocol.ErrInvalidRequest, "dek_id/wrapped_dek/recipient_device_id required")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return err
	}
	session, err := s.repo.SessionByID(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrSessionNotFound
		}
		return err
	}
	if session.AccountID != accountID {
		return ErrScopeDenied
	}
	workspace, err := s.repo.WorkspaceByID(ctx, session.WorkspaceID)
	if err != nil {
		return err
	}
	if workspace.TerminalID != terminal.ID {
		return ErrScopeDenied
	}
	recipient, err := s.repo.DeviceByID(ctx, recipientDeviceID)
	if err != nil {
		return ErrScopeDenied
	}
	if recipient.AccountID != accountID || recipient.Status != DeviceActive || recipient.Role != RoleAndroidOwner {
		return ErrScopeDenied
	}
	// 会话已有 content_dek_id：同 id 幂等（已有 wrap 直接放行），异 id 拒绝。
	if session.ContentDEKID != "" && session.ContentDEKID != dekID {
		return ErrContentDEKConflict
	}
	if session.ContentDEKID == "" {
		if err := s.repo.SetSessionContentDEK(ctx, sessionID, dekID); err != nil {
			return err
		}
	}
	// 幂等：recipient 已有同 dekID 的 wrap 时直接返回，不重复插入。
	wraps, err := s.repo.ListKeyWraps(ctx, dekID)
	if err != nil {
		return err
	}
	for _, wrap := range wraps {
		if wrap.RecipientDeviceID == recipientDeviceID {
			return nil
		}
	}
	return s.repo.PutKeyWrap(ctx, store.KeyWrapRow{
		DEKID: dekID, RecipientDeviceID: recipientDeviceID, SenderDeviceID: deviceID,
		WrappedDEK: wrapped, CreatedAt: time.Now().UTC(),
	})
}

// ContentDEKForSession 让 owner/write 设备读取自己在本会话的 wrapped DEK（ADR-016 §3.2）。
// 只回当前设备的 wrap；无 DEK/无本设备 wrap → ErrContentDEKNotFound（404 fail-closed）。
func (s *AttachmentService) ContentDEKForSession(ctx context.Context, accountID, deviceID, role, sessionID string) (ContentDEKProjection, error) {
	if !protocol.DeviceRoleCanWrite(role) {
		return ContentDEKProjection{}, ErrReadOnlyDevice
	}
	session, err := s.repo.SessionByID(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ContentDEKProjection{}, ErrSessionNotFound
		}
		return ContentDEKProjection{}, err
	}
	if session.AccountID != accountID {
		return ContentDEKProjection{}, ErrScopeDenied
	}
	if session.ContentDEKID == "" {
		return ContentDEKProjection{}, ErrContentDEKNotFound
	}
	wraps, err := s.repo.ListKeyWraps(ctx, session.ContentDEKID)
	if err != nil {
		return ContentDEKProjection{}, err
	}
	for _, wrap := range wraps {
		if wrap.RecipientDeviceID == deviceID {
			return ContentDEKProjection{DEKID: wrap.DEKID, RecipientID: wrap.RecipientDeviceID, WrappedDEK: wrap.WrappedDEK}, nil
		}
	}
	return ContentDEKProjection{}, ErrContentDEKNotFound
}
