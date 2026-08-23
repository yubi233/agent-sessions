package domain

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const (
	MessageFeedbackPositive = "positive"
	MessageFeedbackNegative = "negative"
	maxFeedbackNoteRunes    = 4096
	maxFeedbackMessageIDLen = 256
)

var ErrMessageFeedbackConflict = errors.New("message feedback version conflict")

type MessageFeedbackConflictError struct {
	Current *store.MessageFeedbackRow
}

func (e MessageFeedbackConflictError) Error() string {
	return ErrMessageFeedbackConflict.Error()
}

func (e MessageFeedbackConflictError) Unwrap() error {
	return ErrMessageFeedbackConflict
}

type MessageFeedbackInput struct {
	AccountID       string
	DeviceID        string
	Role            string
	SessionID       string
	MessageID       string
	Rating          string
	Note            string
	ExpectedVersion *int64
}

type MessageFeedbackService struct {
	repo store.Repository
	now  func() time.Time
}

func NewMessageFeedbackService(repo store.Repository) *MessageFeedbackService {
	return &MessageFeedbackService{repo: repo, now: time.Now}
}

func (s *MessageFeedbackService) List(ctx context.Context, accountID, sessionID string) ([]store.MessageFeedbackRow, error) {
	if err := s.ensureSessionScope(ctx, accountID, sessionID); err != nil {
		return nil, err
	}
	return s.repo.ListMessageFeedback(ctx, sessionID)
}

func (s *MessageFeedbackService) Get(ctx context.Context, accountID, sessionID, messageID string) (*store.MessageFeedbackRow, error) {
	if err := validateFeedbackMessageID(messageID); err != nil {
		return nil, err
	}
	if err := s.ensureSessionScope(ctx, accountID, sessionID); err != nil {
		return nil, err
	}
	item, err := s.repo.MessageFeedbackByMessage(ctx, sessionID, messageID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &item, nil
}

func (s *MessageFeedbackService) Put(ctx context.Context, in MessageFeedbackInput) (store.MessageFeedbackRow, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return store.MessageFeedbackRow{}, ErrReadOnlyDevice
	}
	if err := validateFeedbackMessageID(in.MessageID); err != nil {
		return store.MessageFeedbackRow{}, err
	}
	rating := strings.TrimSpace(in.Rating)
	if rating != MessageFeedbackPositive && rating != MessageFeedbackNegative {
		return store.MessageFeedbackRow{}, protocol.NewError(protocol.ErrInvalidRequest, "feedback rating is invalid")
	}
	note, err := normalizeFeedbackNote(in.Note)
	if err != nil {
		return store.MessageFeedbackRow{}, err
	}
	nowUnixMS := s.now().UTC().UnixMilli()
	var out store.MessageFeedbackRow
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if err := ensureFeedbackSessionScope(ctx, tx, in.AccountID, in.SessionID); err != nil {
			return err
		}
		current, lookupErr := tx.MessageFeedbackByMessage(ctx, in.SessionID, in.MessageID)
		if lookupErr != nil && !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if errors.Is(lookupErr, sql.ErrNoRows) {
			if in.ExpectedVersion != nil {
				return MessageFeedbackConflictError{}
			}
			out = store.MessageFeedbackRow{
				AccountID: in.AccountID, SessionID: in.SessionID, MessageID: in.MessageID,
				Rating: rating, Note: note, Version: 1,
				UpdatedByDeviceID: in.DeviceID, UpdatedAtUnixMS: nowUnixMS,
			}
			return tx.CreateMessageFeedback(ctx, out)
		}
		if in.ExpectedVersion == nil || current.Version != *in.ExpectedVersion {
			return MessageFeedbackConflictError{Current: &current}
		}
		out = current
		out.Rating = rating
		out.Note = note
		out.Version = current.Version + 1
		out.UpdatedByDeviceID = in.DeviceID
		out.UpdatedAtUnixMS = nowUnixMS
		updated, err := tx.UpdateMessageFeedback(ctx, out, current.Version)
		if err != nil {
			return err
		}
		if !updated {
			latest, latestErr := tx.MessageFeedbackByMessage(ctx, in.SessionID, in.MessageID)
			if latestErr == nil {
				return MessageFeedbackConflictError{Current: &latest}
			}
			return MessageFeedbackConflictError{}
		}
		return nil
	})
	if err != nil {
		return store.MessageFeedbackRow{}, err
	}
	return out, nil
}

func (s *MessageFeedbackService) Delete(ctx context.Context, in MessageFeedbackInput) (*store.MessageFeedbackRow, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return nil, ErrReadOnlyDevice
	}
	if err := validateFeedbackMessageID(in.MessageID); err != nil {
		return nil, err
	}
	if in.ExpectedVersion == nil {
		return nil, protocol.NewError(protocol.ErrInvalidRequest, "feedback version is required")
	}
	var currentAfterConflict *store.MessageFeedbackRow
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if err := ensureFeedbackSessionScope(ctx, tx, in.AccountID, in.SessionID); err != nil {
			return err
		}
		current, lookupErr := tx.MessageFeedbackByMessage(ctx, in.SessionID, in.MessageID)
		if lookupErr != nil {
			if errors.Is(lookupErr, sql.ErrNoRows) {
				return MessageFeedbackConflictError{}
			}
			return lookupErr
		}
		if current.Version != *in.ExpectedVersion {
			return MessageFeedbackConflictError{Current: &current}
		}
		deleted, err := tx.DeleteMessageFeedback(ctx, in.SessionID, in.MessageID, current.Version)
		if err != nil {
			return err
		}
		if !deleted {
			latest, latestErr := tx.MessageFeedbackByMessage(ctx, in.SessionID, in.MessageID)
			if latestErr == nil {
				currentAfterConflict = &latest
			}
			return MessageFeedbackConflictError{Current: currentAfterConflict}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return nil, nil
}

func (s *MessageFeedbackService) ensureSessionScope(ctx context.Context, accountID, sessionID string) error {
	return ensureFeedbackSessionScope(ctx, s.repo, accountID, sessionID)
}

func ensureFeedbackSessionScope(ctx context.Context, repo store.Repository, accountID, sessionID string) error {
	session, err := repo.SessionByID(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrSessionNotFound
		}
		return err
	}
	if session.AccountID != accountID {
		return ErrScopeDenied
	}
	return nil
}

func validateFeedbackMessageID(messageID string) error {
	value := strings.TrimSpace(messageID)
	if value == "" || len(value) > maxFeedbackMessageIDLen {
		return protocol.NewError(protocol.ErrInvalidRequest, "message_id is invalid")
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			continue
		}
		switch r {
		case '_', '-', '.', ':':
			continue
		default:
			return protocol.NewError(protocol.ErrInvalidRequest, "message_id is invalid")
		}
	}
	return nil
}

func normalizeFeedbackNote(note string) (string, error) {
	value := strings.TrimSpace(note)
	if value == "" {
		return "", nil
	}
	if utf8.RuneCountInString(value) > maxFeedbackNoteRunes {
		return "", protocol.NewError(protocol.ErrInvalidRequest, "feedback note is too large")
	}
	return value, nil
}
