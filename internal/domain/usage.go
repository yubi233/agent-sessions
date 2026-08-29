package domain

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// Usage 的公开契约边界（ADR-010）：
//   - Relay 只接收白名单整数计数与 UTC 日桶，不保存 prompt、回复、费用或精确时间；
//   - usage key 由 Daemon 生成，Relay 以 usage_key_hash 唯一约束去重；
//   - 读取端只获得 account-scoped 的 today/7d/30d 聚合。
//
// 所有数值必须是非负安全整数；无效时间桶、未知 Provider、重复 ID 或超限值
// 返回稳定错误，不能污染报表。

const (
	// UsageMaxTokenValue 单条 usage 计数的硬上限，防止脏数据或错误适配器把
	// 超大整数写进聚合（ADR-010 第 6 条）。
	UsageMaxTokenValue = 1_000_000_000_000
	// UsageSchemaVersion 当前 usage 事件 schema 版本；未来加字段必须递增并向后兼容。
	UsageSchemaVersion = 1
	usageMaxTTFTMS     = 24 * 60 * 60 * 1000
	usageMaxThroughput = 1_000_000.0
)

// UsageEventInput 是 Daemon 上传的 usage 事件输入。usageKey 由 Daemon 对来源事件
// 生成（如 session id + event seq + provider），保证断线重试幂等。
type UsageEventInput struct {
	UsageKey            string
	SessionID           string
	Provider            string
	Model               string
	UTCDay              string // "2006-01-02"（UTC）
	InputTokens         int64
	OutputTokens        int64
	CacheReadTokens     int64
	CacheWriteTokens    int64
	ContextWindowTokens int64
	TTFTMS              *int64
	DecodeThroughput    *float64
}

// SessionUsageProjection 是单会话 StatsLine/Model seat 能安全展示的 usage 投影。
type SessionUsageProjection struct {
	Model               string   `json:"model,omitempty"`
	InputTokens         int64    `json:"input_tokens"`
	OutputTokens        int64    `json:"output_tokens"`
	CacheReadTokens     int64    `json:"cache_read_tokens"`
	CacheWriteTokens    int64    `json:"cache_write_tokens"`
	ContextWindowTokens int64    `json:"context_window_tokens,omitempty"`
	TTFTMS              *int64   `json:"ttft_ms,omitempty"`
	DecodeThroughput    *float64 `json:"decode_throughput,omitempty"`
	HasUsage            bool     `json:"-"`
}

// UsageDayAggregate 是单账号单 Provider 单 UTC 日桶的聚合投影。
type UsageDayAggregate struct {
	Provider         string
	UTCDay           string
	InputTokens      int64
	OutputTokens     int64
	CacheReadTokens  int64
	CacheWriteTokens int64
}

// UsageSummary 是客户端读取的 account-scoped 用量摘要。
type UsageSummary struct {
	Days        int                 `json:"days"`
	UTCToday    string              `json:"utc_today"`
	Providers   []UsageDayAggregate `json:"providers"`
	TotalInput  int64               `json:"total_input_tokens"`
	TotalOutput int64               `json:"total_output_tokens"`
}

// UsageService 处理 usage 事件去重与聚合查询。
type UsageService struct {
	repo store.Repository
}

// NewUsageService 构造用量服务。
func NewUsageService(repo store.Repository) *UsageService {
	return &UsageService{repo: repo}
}

// UploadUsageEvent 以 usage_key_hash 去重写入一条 usage 事件。
// 返回 inserted=false 表示重复 key（Daemon outbox 重放），调用方仍应返回成功 receipt。
func (s *UsageService) UploadUsageEvent(ctx context.Context, accountID, terminalID string, input UsageEventInput) (inserted bool, err error) {
	if input.UsageKey == "" {
		return false, protocol.NewError(protocol.ErrInvalidRequest, "usage key is required")
	}
	if input.Provider == "" {
		return false, protocol.NewError(protocol.ErrInvalidRequest, "provider is required")
	}
	if err := validateUTCDay(input.UTCDay); err != nil {
		return false, err
	}
	if err := validateTokens(input.InputTokens, input.OutputTokens, input.CacheReadTokens, input.CacheWriteTokens); err != nil {
		return false, err
	}
	if input.ContextWindowTokens < 0 || input.ContextWindowTokens > UsageMaxTokenValue {
		return false, protocol.NewError(protocol.ErrInvalidRequest, "context_window_tokens is invalid")
	}
	if err := validateUsageTiming(input.TTFTMS, input.DecodeThroughput); err != nil {
		return false, err
	}
	sessionID := strings.TrimSpace(input.SessionID)
	model := strings.TrimSpace(input.Model)
	if sessionID != "" {
		session, err := s.repo.SessionByID(ctx, sessionID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return false, ErrSessionNotFound
			}
			return false, err
		}
		if session.AccountID != accountID {
			return false, ErrScopeDenied
		}
		workspace, err := s.repo.WorkspaceByID(ctx, session.WorkspaceID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return false, ErrWorkspaceNotFound
			}
			return false, err
		}
		if workspace.TerminalID != "" && workspace.TerminalID != terminalID {
			return false, ErrScopeDenied
		}
	}
	keyHash := usageKeyHash(input.UsageKey)
	inserted, err = s.repo.UpsertUsageEvent(ctx, store.UsageEventRow{
		UsageKeyHash:        keyHash,
		AccountID:           accountID,
		TerminalID:          terminalID,
		SessionID:           sessionID,
		Provider:            input.Provider,
		Model:               model,
		UTCDay:              input.UTCDay,
		InputTokens:         input.InputTokens,
		OutputTokens:        input.OutputTokens,
		CacheReadTokens:     input.CacheReadTokens,
		CacheWriteTokens:    input.CacheWriteTokens,
		ContextWindowTokens: input.ContextWindowTokens,
		TTFTMS:              input.TTFTMS,
		DecodeThroughput:    input.DecodeThroughput,
		SchemaVersion:       UsageSchemaVersion,
		CreatedAtUnixMS:     time.Now().UnixMilli(),
	})
	if err != nil {
		return false, err
	}
	if inserted && sessionID != "" && model != "" {
		if err := s.repo.SetSessionModel(ctx, sessionID, model); err != nil {
			return false, err
		}
	}
	return inserted, nil
}

// SessionProjection 返回一个会话的白名单 usage/model/timing 投影。没有 session-scoped
// usage 时返回 nil；调用方必须展示 unavailable，不能填 0。
func (s *UsageService) SessionProjection(ctx context.Context, accountID, sessionID string) (*SessionUsageProjection, error) {
	session, err := s.repo.SessionByID(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrSessionNotFound
		}
		return nil, err
	}
	if session.AccountID != accountID {
		return nil, ErrScopeDenied
	}
	row, err := s.repo.SessionUsageSummary(ctx, accountID, sessionID)
	if err != nil {
		return nil, err
	}
	if !row.HasData && row.Model == "" && row.ContextWindowTokens == 0 && row.TTFTMS == nil && row.DecodeThroughput == nil {
		if session.Model == "" {
			return nil, nil
		}
		row.Model = session.Model
	}
	return &SessionUsageProjection{
		Model:               firstNonEmpty(row.Model, session.Model),
		InputTokens:         row.InputTokens,
		OutputTokens:        row.OutputTokens,
		CacheReadTokens:     row.CacheReadTokens,
		CacheWriteTokens:    row.CacheWriteTokens,
		ContextWindowTokens: row.ContextWindowTokens,
		TTFTMS:              row.TTFTMS,
		DecodeThroughput:    row.DecodeThroughput,
		HasUsage:            row.HasData || row.ContextWindowTokens > 0 || row.TTFTMS != nil || row.DecodeThroughput != nil,
	}, nil
}

// Summary 返回账号在最近 days 天（含今天）UTC 日桶内的聚合。
// days 只允许 1、7、30，其它取值返回稳定错误。
func (s *UsageService) Summary(ctx context.Context, accountID string, days int, now time.Time) (UsageSummary, error) {
	if days != 1 && days != 7 && days != 30 {
		return UsageSummary{}, protocol.NewError(protocol.ErrInvalidRequest, "days must be 1, 7 or 30")
	}
	today := now.UTC()
	start := today.AddDate(0, 0, -(days - 1))
	startDay := start.Format("2006-01-02")
	endDay := today.Format("2006-01-02")
	rows, err := s.repo.AggregateUsage(ctx, accountID, startDay, endDay)
	if err != nil {
		return UsageSummary{}, err
	}
	var summary UsageSummary
	summary.Days = days
	summary.UTCToday = endDay
	for _, row := range rows {
		summary.Providers = append(summary.Providers, UsageDayAggregate{
			Provider:         row.Provider,
			UTCDay:           row.UTCDay,
			InputTokens:      row.InputTokens,
			OutputTokens:     row.OutputTokens,
			CacheReadTokens:  row.CacheReadTokens,
			CacheWriteTokens: row.CacheWriteTokens,
		})
		summary.TotalInput += row.InputTokens
		summary.TotalOutput += row.OutputTokens
	}
	return summary, nil
}

// UsageKeyHashOf 把 Daemon 生成的 usage key 映射为不可逆哈希（导出给 handler
// 用于回显 canonical receipt），Relay 不保存原始 key。
func UsageKeyHashOf(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

// usageKeyHash 是 UsageKeyHashOf 的等价内部调用，语义同上。
func usageKeyHash(key string) string {
	return UsageKeyHashOf(key)
}

func validateUTCDay(day string) error {
	if _, err := time.Parse("2006-01-02", day); err != nil {
		return protocol.NewError(protocol.ErrInvalidRequest, "utc_day must be YYYY-MM-DD")
	}
	return nil
}

func validateTokens(values ...int64) error {
	for _, value := range values {
		if value < 0 || value > UsageMaxTokenValue {
			return protocol.NewError(protocol.ErrInvalidRequest, "token count out of range")
		}
	}
	return nil
}

func validateUsageTiming(ttft *int64, throughput *float64) error {
	if ttft != nil && (*ttft < 0 || *ttft > usageMaxTTFTMS) {
		return protocol.NewError(protocol.ErrInvalidRequest, "ttft_ms out of range")
	}
	if throughput != nil && (*throughput <= 0 || *throughput > usageMaxThroughput) {
		return protocol.NewError(protocol.ErrInvalidRequest, "decode_throughput out of range")
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
