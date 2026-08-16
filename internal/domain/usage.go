package domain

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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
)

// UsageEventInput 是 Daemon 上传的 usage 事件输入。usageKey 由 Daemon 对来源事件
// 生成（如 session id + event seq + provider），保证断线重试幂等。
type UsageEventInput struct {
	UsageKey         string
	Provider         string
	UTCDay           string // "2006-01-02"（UTC）
	InputTokens      int64
	OutputTokens     int64
	CacheReadTokens  int64
	CacheWriteTokens int64
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
	keyHash := usageKeyHash(input.UsageKey)
	inserted, err = s.repo.UpsertUsageEvent(ctx, store.UsageEventRow{
		UsageKeyHash:     keyHash,
		AccountID:        accountID,
		TerminalID:       terminalID,
		Provider:         input.Provider,
		UTCDay:           input.UTCDay,
		InputTokens:      input.InputTokens,
		OutputTokens:     input.OutputTokens,
		CacheReadTokens:  input.CacheReadTokens,
		CacheWriteTokens: input.CacheWriteTokens,
		SchemaVersion:    UsageSchemaVersion,
		CreatedAtUnixMS:  time.Now().UnixMilli(),
	})
	if err != nil {
		return false, err
	}
	return inserted, nil
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
