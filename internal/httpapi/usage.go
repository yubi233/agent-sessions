package httpapi

import (
	"errors"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// usageUploadRequest 是 Daemon 上传 usage 事件的请求体。字段全部为白名单
// 整数或归属标识；prompt、回复、费用与精确事件时间不允许出现在该 DTO。
// Signature 是 v0.6 additive 字段：携带时必须完整校验，required 模式下必须存在。
type usageUploadRequest struct {
	UsageKey         string                  `json:"usage_key"`
	SessionID        string                  `json:"session_id,omitempty"`
	Provider         string                  `json:"provider"`
	Model            string                  `json:"model,omitempty"`
	UTCDay           string                  `json:"utc_day"`
	InputTokens      int64                   `json:"input_tokens"`
	OutputTokens     int64                   `json:"output_tokens"`
	CacheReadTokens  int64                   `json:"cache_read_tokens,omitempty"`
	CacheWriteTokens int64                   `json:"cache_write_tokens,omitempty"`
	TTFTMS           *int64                  `json:"ttft_ms,omitempty"`
	DecodeThroughput *float64                `json:"decode_throughput,omitempty"`
	Signature        authz.TerminalSignature `json:"signature"`
}

// handleUsageUpload 只允许已配对 Terminal 上传 usage；按 usage_key_hash 去重，
// 重复上传返回同一 canonical receipt，不重复累加（ADR-010）。
func (a *API) handleUsageUpload(c *gin.Context) {
	subj := subject(c)
	// 使用原始 body 计算签名 body hash；绑定失败时不得进入业务处理。
	var req usageUploadRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
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
		SessionID:        req.SessionID,
		Provider:         req.Provider,
		Model:            req.Model,
		UTCDay:           req.UTCDay,
		InputTokens:      req.InputTokens,
		OutputTokens:     req.OutputTokens,
		CacheReadTokens:  req.CacheReadTokens,
		CacheWriteTokens: req.CacheWriteTokens,
		TTFTMS:           req.TTFTMS,
		DecodeThroughput: req.DecodeThroughput,
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

// parseIntQuery 解析非负整数字符串查询参数；offset 允许 0，limit 需要 >= 1。
func parseIntQuery(raw string) (int, error) {
	var value int
	for _, ch := range raw {
		if ch < '0' || ch > '9' {
			return 0, errors.New("not a number")
		}
		value = value*10 + int(ch-'0')
	}
	return value, nil
}
