package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"database/sql"
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

// validateBearer 校验 bearer token 并返回认证主体：token 存在未过期，且绑定的
// 设备仍为同账号同角色的 active 设备。RequireAuth 中间件与 session SSE 心跳
// 重验共用同一套规则，保证长连接不会在设备撤销后继续存活。
func (a *API) validateBearer(ctx context.Context, token string) (*domain.AuthSubject, error) {
	at, err := a.Repo.AccessTokenByValue(ctx, token)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, domain.ErrUnauthenticated
		}
		return nil, err
	}
	if time.Now().After(at.ExpiresAt) {
		_ = a.Repo.DeleteAccessToken(ctx, token)
		return nil, domain.ErrUnauthenticated
	}
	subj := domain.AuthSubject{
		AccountID: at.AccountID, DeviceID: at.DeviceID, Role: at.Role, DeviceOK: true,
	}
	if at.DeviceID != "" {
		dev, derr := a.Repo.DeviceByID(ctx, at.DeviceID)
		if derr != nil {
			if errors.Is(derr, sql.ErrNoRows) {
				return nil, domain.ErrUnauthenticated
			}
			return nil, derr
		}
		if dev.AccountID != at.AccountID || dev.Role != at.Role {
			return nil, domain.ErrUnauthenticated
		}
		if dev.Status != domain.DeviceActive {
			return nil, domain.ErrDeviceRevoked
		}
	}
	return &subj, nil
}

// handleSessionSSE 处理 /v1/sessions/{id}/events（v0.9.0 C5 会话级 SSE）。
// 与账号级 /v1/events 严格分离：
//   - cursor 是该 session 的排他 event_seq（Last-Event-ID 优先于 after_seq），
//     绝不能与 account_event_log 的账号级 cursor 混用；
//   - 事件帧仅作失效通知（event: invalidated, data: {}），canonical envelope
//     不经本流下发，客户端收到通知后按已合并 session cursor 拉 snapshot；
//   - 服务端先订阅 Hub，再立即从 SQLite 回放并 flush 初始连接注释；每次 Hub
//     唤醒与每个 15 秒心跳都从 SQLite 按最后发送 cursor 补缺口——Hub 丢唤醒
//     只损失延迟，不损失事件；心跳先复核 bearer token/绑定设备（fail-closed），
//     设备被撤销后最多一个心跳周期内关闭连接；
//   - 断开即释放 Hub 订阅与 ticker（defer）。
func (a *API) handleSessionSSE(presence *domain.PresenceHub, logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		// C7 kill switch：AGENT_SESSIONS_SESSION_SSE_ENABLED=0 时端点必须返回
		// 501/CAPABILITY_UNSUPPORTED，不得伪装资源 404。
		if os.Getenv("AGENT_SESSIONS_SESSION_SSE_ENABLED") == "0" {
			c.AbortWithStatusJSON(http.StatusNotImplemented, protocol.NewError(
				protocol.ErrCapabilityUnsupported, "session sse disabled by kill switch"))
			return
		}
		sessionID := c.Param("id")
		session, err := a.Sessions.GetSession(c.Request.Context(), sessionID)
		if err != nil {
			writeError(c, err)
			return
		}
		if session.AccountID != subject(c).AccountID {
			writeError(c, domain.ErrScopeDenied)
			return
		}
		cursor, err := sessionEventCursor(c)
		if err != nil {
			writeError(c, err)
			return
		}

		// 先订阅，再读取 SQLite 回放，避免两步之间新提交的事件形成不可恢复缺口。
		ch, cancel := presence.Subscribe(sessionID)
		defer cancel()
		if _, err := a.Repo.ListEventsAfter(c.Request.Context(), sessionID, cursor); err != nil {
			logger.Error("session sse initial replay", "error", err)
			writeError(c, err)
			return
		}

		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("X-Accel-Buffering", "no")
		c.Status(http.StatusOK)
		// 初始连接注释立即 flush：客户端以此为 handshake 完成信号。
		_, _ = c.Writer.Write([]byte(": connected\n\n"))
		c.Writer.Flush()

		lastCursor := cursor
		lastCursor, replayErr := a.replaySessionInvalidations(c, sessionID, lastCursor)
		if replayErr != nil {
			logger.Error("session sse initial replay", "error", replayErr)
			return
		}

		// 心跳重验用原始 bearer；RequireAuth 已确认过首帧有效。
		rawAuth := c.GetHeader("Authorization")
		bearer := strings.TrimPrefix(rawAuth, "Bearer ")
		ticker := time.NewTicker(sessionSSEHeartbeatInterval())
		defer ticker.Stop()
		ctx := c.Request.Context()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				// 每个心跳 tick：先复核 token/设备（fail-closed），再从 SQLite
				// 补缺口，最后发送注释心跳。查询失败按关闭处理。
				if bearer == "" {
					logger.Info("session sse heartbeat revalidation failed", "reason", "missing_bearer")
					return
				}
				if _, verr := a.validateBearer(ctx, bearer); verr != nil {
					logger.Info("session sse heartbeat revalidation failed", "error", verr)
					return
				}
				if lastCursor, replayErr = a.replaySessionInvalidations(c, sessionID, lastCursor); replayErr != nil {
					logger.Error("session sse heartbeat replay", "error", replayErr)
					return
				}
				_, _ = c.Writer.Write([]byte(": heartbeat\n\n"))
				c.Writer.Flush()
			case ev := <-ch:
				// Hub 仅是唤醒信号：丢帧/乱序都由 SQLite cursor 回放兜底。
				if ev.EventSeq <= lastCursor {
					continue
				}
				if lastCursor, replayErr = a.replaySessionInvalidations(c, sessionID, lastCursor); replayErr != nil {
					logger.Error("session sse live replay", "error", replayErr)
					return
				}
			}
		}
	}
}

// replaySessionInvalidations 从 SQLite 严格按 event_seq 升序补缺口；每个新事件
// 发送一帧失效通知（id=event_seq, event=invalidated, data={}），正文不经本流。
// 返回已发送的最大 event_seq；空回放保留原值。
func (a *API) replaySessionInvalidations(c *gin.Context, sessionID string, after int64) (int64, error) {
	events, err := a.Repo.ListEventsAfter(c.Request.Context(), sessionID, after)
	if err != nil {
		return after, err
	}
	last := after
	for _, event := range events {
		if event.EventSeq <= last {
			continue
		}
		_, _ = c.Writer.Write([]byte("id: " + strconv.FormatInt(event.EventSeq, 10) + "\n" +
			"event: invalidated\n" +
			"data: {}\n\n"))
		c.Writer.Flush()
		last = event.EventSeq
	}
	return last, nil
}

// sessionEventCursor 解析会话级 SSE 恢复游标。Last-Event-ID 优先；它与账号级
// account_event_log cursor 没有关联，必须是该 session 的非负 event_seq。
// 独立类型/命名（SessionEventCursor 契约）：绝不能把本游标传入 /v1/events。
func sessionEventCursor(c *gin.Context) (int64, error) {
	raw := c.GetHeader("Last-Event-ID")
	if raw == "" {
		raw = c.Query("after_seq")
	}
	if raw == "" {
		return 0, nil
	}
	if strings.TrimSpace(raw) != raw {
		return 0, protocol.NewError(protocol.ErrInvalidRequest, "session event cursor must be a non-negative integer")
	}
	cursor, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || cursor < 0 {
		return 0, protocol.NewError(protocol.ErrInvalidRequest, "session event cursor must be a non-negative integer")
	}
	return cursor, nil
}

// sessionSSEHeartbeatInterval 返回会话 SSE 心跳周期（默认 15 秒，T7 裁决）。
// AGENT_SESSIONS_SESSION_SSE_HEARTBEAT_SECONDS 可覆盖（诊断/契约测试用）；
// 非法或非正值回退默认，心跳只提前不延后于客户端 40 秒 watchdog。
func sessionSSEHeartbeatInterval() time.Duration {
	if raw := os.Getenv("AGENT_SESSIONS_SESSION_SSE_HEARTBEAT_SECONDS"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			return time.Duration(parsed) * time.Second
		}
	}
	return 15 * time.Second
}
