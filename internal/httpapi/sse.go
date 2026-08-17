package httpapi

import (
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// handleSSE 处理 /v1/events（账号级 SSE，支持 Last-Event-ID / after_seq 恢复）。
func (a *API) handleSSE(presence *domain.PresenceHub, logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		subj := subject(c)
		afterCursor, err := accountEventCursor(c)
		if err != nil {
			writeError(c, err)
			return
		}

		// 先订阅，再读取 SQLite 回放，避免两步之间新提交的事件形成不可恢复缺口。
		ch, cancel := presence.SubscribeAccount(subj.AccountID)
		defer cancel()
		events, err := a.Repo.ListAccountEventsAfter(c.Request.Context(), subj.AccountID, afterCursor)
		if err != nil {
			logger.Error("sse account event replay", "error", err)
			writeError(c, err)
			return
		}

		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Status(http.StatusOK)
		c.Writer.Flush()

		lastCursor := afterCursor
		for _, event := range events {
			writeSSE(c, event.AccountEventCursor, event.EventType, event.EnvelopeJSON)
			lastCursor = event.AccountEventCursor
		}

		// 订阅进程内广播并保持长连接，发送心跳。
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		ctx := c.Request.Context()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				// Hub 丢弃慢订阅者或不同写请求乱序发布时，定期从 SQLite cursor 补齐。
				// 因此 Hub 只负责低延迟唤醒，永远不承担事件顺序或可靠性语义。
				var replayErr error
				lastCursor, replayErr = a.replayAccountEvents(c, subj.AccountID, lastCursor)
				if replayErr != nil {
					logger.Error("sse account event heartbeat replay", "error", replayErr)
					return
				}
				// 心跳帧，防止代理/客户端判定连接断开。
				c.Writer.Write([]byte(": heartbeat\n\n"))
				c.Writer.Flush()
			case event := <-ch:
				// 初始回放和 Hub 可能交叉，也可能有并发写请求反序抵达。只把 Hub
				// 当作唤醒信号，从 SQLite 严格按 cursor 回放，不能直接转发 event。
				if event.AccountEventCursor <= lastCursor {
					continue
				}
				var replayErr error
				lastCursor, replayErr = a.replayAccountEvents(c, subj.AccountID, lastCursor)
				if replayErr != nil {
					logger.Error("sse account event live replay", "error", replayErr)
					return
				}
			}
		}
	}
}

// replayAccountEvents 始终按 SQLite cursor 发送缺口，避免把进程内 Hub 的调度顺序当作
// 账号事件总序。返回已发送的最大 cursor；空回放保留原值。
func (a *API) replayAccountEvents(c *gin.Context, accountID string, afterCursor int64) (int64, error) {
	events, err := a.Repo.ListAccountEventsAfter(c.Request.Context(), accountID, afterCursor)
	if err != nil {
		return afterCursor, err
	}
	lastCursor := afterCursor
	for _, event := range events {
		writeSSE(c, event.AccountEventCursor, event.EventType, event.EnvelopeJSON)
		lastCursor = event.AccountEventCursor
	}
	return lastCursor, nil
}

func writeSSE(c *gin.Context, seq int64, eventType, data string) {
	_, _ = c.Writer.Write([]byte("id: " + strconv.FormatInt(seq, 10) + "\n"))
	if eventType != "" {
		_, _ = c.Writer.Write([]byte("event: " + eventType + "\n"))
	}
	_, _ = c.Writer.Write([]byte("data: " + data + "\n\n"))
	c.Writer.Flush()
}

// accountEventCursor 解析账号级 SSE 恢复游标。Last-Event-ID 优先；它与 session-local
// event_seq 没有关联，必须是 account_event_log 的非负 cursor。
func accountEventCursor(c *gin.Context) (int64, error) {
	raw := c.GetHeader("Last-Event-ID")
	if raw == "" {
		raw = c.Query("after_seq")
	}
	if raw == "" {
		return 0, nil
	}
	if strings.TrimSpace(raw) != raw {
		return 0, protocol.NewError(protocol.ErrInvalidRequest, "event cursor must be a non-negative integer")
	}
	cursor, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || cursor < 0 {
		return 0, protocol.NewError(protocol.ErrInvalidRequest, "event cursor must be a non-negative integer")
	}
	return cursor, nil
}
