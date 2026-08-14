package domain

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"

	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// 附件策略同时约束客户端和 Relay，避免任意 MIME、大文件或无限分块进入持久化层。
const (
	MaxImageAttachmentBytes              int64 = 10 * 1024 * 1024
	MaxTextAttachmentBytes               int64 = 1 * 1024 * 1024
	MaxAttachmentChunks                        = 64
	MaxAttachmentChunkCiphertextBytes          = 512 * 1024
	MaxAttachmentMetadataCiphertextBytes       = 16 * 1024
)

const (
	AttachmentPending   = "pending"
	AttachmentCompleted = "completed"
)

var (
	ErrAttachmentNotFound      = errors.New("attachment not found")
	ErrAttachmentInvalid       = errors.New("attachment invalid")
	ErrAttachmentConflict      = errors.New("attachment conflict")
	ErrAttachmentChunkOrder    = errors.New("attachment chunk order")
	ErrAttachmentIncomplete    = errors.New("attachment incomplete")
	ErrAttachmentAlreadyClosed = errors.New("attachment already completed")
)

// AttachmentChunkInput 是已经在客户端加密后的上传块。Relay 永远不接收文件名或明文正文。
type AttachmentChunkInput struct {
	AccountID          string
	DeviceID           string
	Role               string
	AttachmentID       string
	SessionID          string
	MimeType           string
	ByteSize           int64
	Compression        string
	MetadataCiphertext []byte
	ChunkIndex         int
	TotalChunks        int
	Ciphertext         []byte
	IdempotencyKey     string
	LeaseEpoch         int64
}

// AttachmentCompleteInput 仅完成已经上传的密文块，重复相同幂等键返回既有完成结果。
type AttachmentCompleteInput struct {
	AccountID      string
	DeviceID       string
	Role           string
	AttachmentID   string
	SessionID      string
	TotalChunks    int
	IdempotencyKey string
	LeaseEpoch     int64
}

// AttachmentReceipt 是上传或完成后的最小回执，不回显密文或文件名。
type AttachmentReceipt struct {
	AttachmentID string
	ChunkIndex   int
	Status       string
	Idempotent   bool
}

// AttachmentService 管理附件密文块的会话归属、fencing 和完成幂等。
type AttachmentService struct {
	repo store.Repository
}

// NewAttachmentService 构造附件领域服务。
func NewAttachmentService(repo store.Repository) *AttachmentService {
	return &AttachmentService{repo: repo}
}

// UploadChunk 接受一个严格顺序的密文块。每次写入都在事务内复核 Android 写身份与当前 lease。
func (s *AttachmentService) UploadChunk(ctx context.Context, in AttachmentChunkInput) (AttachmentReceipt, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return AttachmentReceipt{}, ErrReadOnlyDevice
	}
	if err := validateAttachmentChunkInput(in); err != nil {
		return AttachmentReceipt{}, err
	}
	hash := ciphertextHash(in.Ciphertext)
	receipt := AttachmentReceipt{AttachmentID: in.AttachmentID, ChunkIndex: in.ChunkIndex, Status: AttachmentPending}
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		session, err := tx.SessionByID(ctx, in.SessionID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrSessionNotFound
			}
			return err
		}
		if session.AccountID != in.AccountID {
			return ErrScopeDenied
		}
		if err := checkLeaseWithRepo(ctx, tx, in.SessionID, in.DeviceID, in.LeaseEpoch); err != nil {
			return err
		}

		attachment, err := tx.AttachmentByID(ctx, in.AttachmentID)
		if errors.Is(err, sql.ErrNoRows) {
			attachment = store.AttachmentRow{
				ID: in.AttachmentID, SessionID: in.SessionID, AccountID: in.AccountID,
				MimeType: in.MimeType, ByteSize: in.ByteSize, Compression: in.Compression,
				TotalChunks: in.TotalChunks, MetadataCiphertext: in.MetadataCiphertext,
				CreatedByDeviceID: in.DeviceID, LeaseEpoch: in.LeaseEpoch, Status: AttachmentPending,
			}
			if err := tx.CreateAttachment(ctx, attachment); err != nil {
				return err
			}
		} else if err != nil {
			return err
		} else {
			// 不把其他账号附件 ID 的存在性通过 409 暴露给当前账号。
			if attachment.AccountID != in.AccountID {
				return ErrScopeDenied
			}
			if !attachmentMatches(attachment, in) || attachment.Status != AttachmentPending {
				return ErrAttachmentConflict
			}
		}

		if existing, lookupErr := tx.AttachmentChunkByIndex(ctx, in.AttachmentID, in.ChunkIndex); lookupErr == nil {
			if sameChunk(existing, in, hash) {
				receipt.Idempotent = true
				return nil
			}
			return ErrAttachmentConflict
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if existing, lookupErr := tx.AttachmentChunkByIdempotency(ctx, in.AttachmentID, in.IdempotencyKey); lookupErr == nil {
			if sameChunk(existing, in, hash) {
				receipt.Idempotent = true
				return nil
			}
			return ErrAttachmentConflict
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		count, err := tx.CountAttachmentChunks(ctx, in.AttachmentID)
		if err != nil {
			return err
		}
		// 按序持久化保证 complete 只需比较总数，不会接受缺块或跳块的组合。
		if count != in.ChunkIndex {
			return ErrAttachmentChunkOrder
		}
		return tx.CreateAttachmentChunk(ctx, store.AttachmentChunkRow{
			AttachmentID: in.AttachmentID, ChunkIndex: in.ChunkIndex,
			IdempotencyKey: in.IdempotencyKey, Ciphertext: in.Ciphertext,
			CiphertextSHA256: hash,
		})
	})
	if err != nil {
		return AttachmentReceipt{}, err
	}
	return receipt, nil
}

// Complete 只允许完成当前 lease 下完整上传的附件，防止旧控制端补写或重放完成动作。
func (s *AttachmentService) Complete(ctx context.Context, in AttachmentCompleteInput) (AttachmentReceipt, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return AttachmentReceipt{}, ErrReadOnlyDevice
	}
	if !validAttachmentID(in.AttachmentID) || strings.TrimSpace(in.SessionID) == "" ||
		strings.TrimSpace(in.IdempotencyKey) == "" || in.LeaseEpoch <= 0 || in.TotalChunks < 1 || in.TotalChunks > MaxAttachmentChunks {
		return AttachmentReceipt{}, ErrAttachmentInvalid
	}
	receipt := AttachmentReceipt{AttachmentID: in.AttachmentID, ChunkIndex: -1, Status: AttachmentCompleted}
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		attachment, err := tx.AttachmentByID(ctx, in.AttachmentID)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrAttachmentNotFound
		}
		if err != nil {
			return err
		}
		if attachment.AccountID != in.AccountID || attachment.SessionID != in.SessionID {
			return ErrScopeDenied
		}
		if err := checkLeaseWithRepo(ctx, tx, in.SessionID, in.DeviceID, in.LeaseEpoch); err != nil {
			return err
		}
		if attachment.Status == AttachmentCompleted {
			if attachment.CompleteIdempotencyKey == in.IdempotencyKey {
				receipt.Idempotent = true
				return nil
			}
			return ErrAttachmentAlreadyClosed
		}
		if attachment.TotalChunks != in.TotalChunks {
			return ErrAttachmentInvalid
		}
		count, err := tx.CountAttachmentChunks(ctx, in.AttachmentID)
		if err != nil {
			return err
		}
		if count != attachment.TotalChunks {
			return ErrAttachmentIncomplete
		}
		updated, err := tx.CompleteAttachment(ctx, in.AttachmentID, in.IdempotencyKey)
		if err != nil {
			return err
		}
		if !updated {
			return ErrAttachmentAlreadyClosed
		}
		// attachment id 来自客户端；通过 JSON 编码构造 outbox，避免把特殊字符拼入持久化 payload。
		payload, marshalErr := json.Marshal(struct {
			AttachmentID string `json:"attachment_id"`
		}{AttachmentID: in.AttachmentID})
		if marshalErr != nil {
			return marshalErr
		}
		return tx.EnqueueOutbox(ctx, store.OutboxRow{
			Kind: "attachment.completed", PayloadJSON: string(payload), Status: "pending",
		})
	})
	if err != nil {
		return AttachmentReceipt{}, err
	}
	return receipt, nil
}

func validateAttachmentChunkInput(in AttachmentChunkInput) error {
	if !validAttachmentID(in.AttachmentID) ||
		strings.TrimSpace(in.SessionID) == "" || strings.TrimSpace(in.IdempotencyKey) == "" ||
		in.LeaseEpoch <= 0 || in.TotalChunks < 1 || in.TotalChunks > MaxAttachmentChunks ||
		in.ChunkIndex < 0 || in.ChunkIndex >= in.TotalChunks ||
		len(in.MetadataCiphertext) == 0 || len(in.MetadataCiphertext) > MaxAttachmentMetadataCiphertextBytes ||
		len(in.Ciphertext) == 0 || len(in.Ciphertext) > MaxAttachmentChunkCiphertextBytes {
		return ErrAttachmentInvalid
	}
	if !validAttachmentMetadata(in.MimeType, in.ByteSize, in.Compression) {
		return ErrAttachmentInvalid
	}
	return nil
}

// validAttachmentID 统一 chunk 与 complete 的资源标识长度边界，避免 path 参数绕开上传校验。
func validAttachmentID(value string) bool {
	return strings.TrimSpace(value) != "" && len(value) <= 128
}

func validAttachmentMetadata(mime string, byteSize int64, compression string) bool {
	if byteSize <= 0 {
		return false
	}
	switch mime {
	case "image/png", "image/jpeg", "image/webp":
		return byteSize <= MaxImageAttachmentBytes && compression == "none"
	case "text/plain", "text/markdown":
		return byteSize <= MaxTextAttachmentBytes && (compression == "none" || compression == "gzip")
	default:
		return false
	}
}

func attachmentMatches(existing store.AttachmentRow, in AttachmentChunkInput) bool {
	return existing.SessionID == in.SessionID && existing.AccountID == in.AccountID &&
		existing.MimeType == in.MimeType && existing.ByteSize == in.ByteSize &&
		existing.Compression == in.Compression && existing.TotalChunks == in.TotalChunks &&
		existing.CreatedByDeviceID == in.DeviceID && existing.LeaseEpoch == in.LeaseEpoch &&
		string(existing.MetadataCiphertext) == string(in.MetadataCiphertext)
}

func sameChunk(existing store.AttachmentChunkRow, in AttachmentChunkInput, hash string) bool {
	return existing.ChunkIndex == in.ChunkIndex && existing.IdempotencyKey == in.IdempotencyKey &&
		existing.CiphertextSHA256 == hash
}

func ciphertextHash(ciphertext []byte) string {
	sum := sha256.Sum256(ciphertext)
	return hex.EncodeToString(sum[:])
}
