package httpapi

import (
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
)

// handleSSE 处理 /v1/events（账号级 SSE，支持 Last-Event-ID / after_seq 恢复）。
func (a *API) handleSSE(presence *domain.PresenceHub, logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		subj := subject(c)
		afterSeq := lastEventID(c)

		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Status(http.StatusOK)
		c.Writer.Flush()

		// 先按游标回放该账号所有会话的事件，补齐缺口（SSE-01）。
		sessions, err := a.Sessions.ListSessions(c.Request.Context(), subj.AccountID)
		if err != nil {
			logger.Error("sse list sessions", "error", err)
			return
		}
		var lastSeq int64 = afterSeq
		for _, sess := range sessions {
			events, err := a.Sessions.ListEventsAfter(c.Request.Context(), sess.ID, afterSeq)
			if err != nil {
				continue
			}
			for _, ev := range events {
				writeSSE(c, ev.EventSeq, ev.EventType, ev.EnvelopeJSON)
				if ev.EventSeq > lastSeq {
					lastSeq = ev.EventSeq
				}
			}
		}

		// 订阅进程内广播并保持长连接，发送心跳。
		ch, cancel := presence.Subscribe("__account__")
		defer cancel()
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		ctx := c.Request.Context()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				// 心跳帧，防止代理/客户端判定连接断开。
				c.Writer.Write([]byte(": heartbeat\n\n"))
				c.Writer.Flush()
			case ev := <-ch:
				// 账号级广播由 handler 调用方发布，这里直接转发。
				writeSSE(c, ev.EventSeq, ev.EventType, ev.EnvelopeJSON)
			}
		}
	}
}

func writeSSE(c *gin.Context, seq int64, eventType, data string) {
	_, _ = c.Writer.Write([]byte("id: " + strconv.FormatInt(seq, 10) + "\n"))
	if eventType != "" {
		_, _ = c.Writer.Write([]byte("event: " + eventType + "\n"))
	}
	_, _ = c.Writer.Write([]byte("data: " + data + "\n\n"))
	c.Writer.Flush()
}

// lastEventID 解析 SSE 恢复游标（Last-Event-ID 头优先，其次 after_seq query）。
func lastEventID(c *gin.Context) int64 {
	raw := c.GetHeader("Last-Event-ID")
	if raw == "" {
		raw = c.Query("after_seq")
	}
	seq, _ := strconv.ParseInt(raw, 10, 64)
	return seq
}
