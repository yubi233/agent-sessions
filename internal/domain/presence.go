package domain

import (
	"context"
	"github.com/yubi233/agent-sessions/internal/store"
	"sync"
	"time"
)

// PresenceHub 管理进程内在线状态与广播订阅。
// SQLite 仍是业务真相，本结构只承载可重建的短状态：在线设备、SSE/WS 订阅。
type PresenceHub struct {
	mu                   sync.RWMutex
	devices              map[string]int64                                   // device_id -> last seen unix ms
	subscriptions        map[string]map[chan store.SessionEventRow]struct{} // session_id -> chans
	accountSubscriptions map[string]map[chan store.SessionEventRow]struct{} // account_id -> chans
	ttl                  time.Duration
}

// NewPresenceHub 构造进程内 presence hub。
func NewPresenceHub(ttl time.Duration) *PresenceHub {
	if ttl <= 0 {
		ttl = 60 * time.Second
	}
	return &PresenceHub{
		devices:              make(map[string]int64),
		subscriptions:        make(map[string]map[chan store.SessionEventRow]struct{}),
		accountSubscriptions: make(map[string]map[chan store.SessionEventRow]struct{}),
		ttl:                  ttl,
	}
}

// Touch 记录设备在线时间。
func (h *PresenceHub) Touch(deviceID string, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.devices[deviceID] = now.UnixMilli()
}

// Online 判断设备是否在 TTL 内在线。
func (h *PresenceHub) Online(deviceID string, now time.Time) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	last, ok := h.devices[deviceID]
	return ok && now.UnixMilli()-last <= h.ttl.Milliseconds()
}

// Subscribe 订阅会话事件；返回取消函数。
func (h *PresenceHub) Subscribe(sessionID string) (chan store.SessionEventRow, func()) {
	ch := make(chan store.SessionEventRow, 64)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subscriptions[sessionID] == nil {
		h.subscriptions[sessionID] = make(map[chan store.SessionEventRow]struct{})
	}
	h.subscriptions[sessionID][ch] = struct{}{}
	cancel := func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if set, ok := h.subscriptions[sessionID]; ok {
			delete(set, ch)
			if len(set) == 0 {
				delete(h.subscriptions, sessionID)
			}
		}
	}
	return ch, cancel
}

// Publish 把事件广播给会话订阅者（非阻塞）。
func (h *PresenceHub) Publish(sessionID string, ev store.SessionEventRow) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	h.publish(h.subscriptions[sessionID], ev)
}

// SubscribeAccount 订阅账号级事件。账号 SSE 必须使用此订阅，不能把 session-local
// event_seq 伪装成账号游标；断线后的真相始终由 SQLite cursor 回放提供。
func (h *PresenceHub) SubscribeAccount(accountID string) (chan store.SessionEventRow, func()) {
	ch := make(chan store.SessionEventRow, 64)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.accountSubscriptions[accountID] == nil {
		h.accountSubscriptions[accountID] = make(map[chan store.SessionEventRow]struct{})
	}
	h.accountSubscriptions[accountID][ch] = struct{}{}
	cancel := func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if set, ok := h.accountSubscriptions[accountID]; ok {
			delete(set, ch)
			if len(set) == 0 {
				delete(h.accountSubscriptions, accountID)
			}
		}
	}
	return ch, cancel
}

// PublishAccount 把已提交事件广播给同账号订阅者（非阻塞）。Hub 取消订阅时不关闭
// channel，避免并发 Publish 向已关闭 channel 写入；handler 由请求 context 自行退出。
func (h *PresenceHub) PublishAccount(accountID string, ev store.SessionEventRow) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	h.publish(h.accountSubscriptions[accountID], ev)
}

func (h *PresenceHub) publish(set map[chan store.SessionEventRow]struct{}, ev store.SessionEventRow) {
	for ch := range set {
		select {
		case ch <- ev:
		default:
			// 慢订阅者丢弃以保护其他订阅者；它会用 SQLite cursor 回放缺口。
		}
	}
}

// Snapshot 返回当前在线设备快照（脱敏元数据）。
func (h *PresenceHub) Snapshot(now time.Time) map[string]int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make(map[string]int64, len(h.devices))
	for k, v := range h.devices {
		if now.UnixMilli()-v <= h.ttl.Milliseconds() {
			out[k] = v
		}
	}
	return out
}

// Drain 阻塞式把事件送入订阅；供 handler 使用（Select 已具备）。
func (h *PresenceHub) Drain(ctx context.Context, ch chan store.SessionEventRow, ev store.SessionEventRow) bool {
	select {
	case <-ctx.Done():
		return false
	case ch <- ev:
		return true
	}
}
