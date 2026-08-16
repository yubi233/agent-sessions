package httpapi

import (
	"errors"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// usageUploadRequest 是 Daemon 上传 usage 事件的请求体。字段全部为白名单
// 整数或归属标识；prompt、回复、费用与精确事件时间不允许出现在该 DTO。
type usageUploadRequest struct {
	UsageKey         string `json:"usage_key"`
	Provider         string `json:"provider"`
	UTCDay           string `json:"utc_day"`
	InputTokens      int64  `json:"input_tokens"`
	OutputTokens     int64  `json:"output_tokens"`
	CacheReadTokens  int64  `json:"cache_read_tokens,omitempty"`
	CacheWriteTokens int64  `json:"cache_write_tokens,omitempty"`
}

// handleUsageUpload 只允许已配对 Terminal 上传 usage；按 usage_key_hash 去重，
// 重复上传返回同一 canonical receipt，不重复累加（ADR-010）。
func (a *API) handleUsageUpload(c *gin.Context) {
	subj := subject(c)
	var req usageUploadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	// terminal_id 外键关联 terminals 表；subject 只带 device_id，需要先解析
	// 已配对 Terminal，避免把设备 id 当成 terminal id 写入 usage 归属。
	terminal, err := a.Repo.TerminalByDeviceID(c.Request.Context(), subj.DeviceID)
	if err != nil {
		writeError(c, domain.ErrTerminalRequired)
		return
	}
	inserted, err := a.Usage.UploadUsageEvent(c.Request.Context(), subj.AccountID, terminal.ID, domain.UsageEventInput{
		UsageKey:         req.UsageKey,
		Provider:         req.Provider,
		UTCDay:           req.UTCDay,
		InputTokens:      req.InputTokens,
		OutputTokens:     req.OutputTokens,
		CacheReadTokens:  req.CacheReadTokens,
		CacheWriteTokens: req.CacheWriteTokens,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{
		"usage_key_hash": domain.UsageKeyHashOf(req.UsageKey),
		"inserted":       inserted,
	})
}

// handleUsageSummary 返回账号在最近 1/7/30 天（UTC 日桶）的白名单聚合。
// 任何账号都只读自己的聚合；不返回单条事件或其它账号数据。
func (a *API) handleUsageSummary(c *gin.Context) {
	days := 30
	if raw := c.Query("days"); raw != "" {
		parsed, err := parseIntQuery(raw)
		if err != nil || (parsed != 1 && parsed != 7 && parsed != 30) {
			writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "days must be 1, 7 or 30"))
			return
		}
		days = parsed
	}
	summary, err := a.Usage.Summary(c.Request.Context(), subject(c).AccountID, days, time.Now())
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, summary)
}

// parseIntQuery 解析正整数字符串查询参数。
func parseIntQuery(raw string) (int, error) {
	var value int
	for _, ch := range raw {
		if ch < '0' || ch > '9' {
			return 0, errors.New("not a number")
		}
		value = value*10 + int(ch-'0')
	}
	if value <= 0 {
		return 0, errors.New("not positive")
	}
	return value, nil
}
