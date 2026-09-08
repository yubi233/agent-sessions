package domain

import (
	"context"
	"encoding/json"
	"github.com/yubi233/agent-sessions/internal/store"
	"sync"
	"time"
)

// PresenceInvalidation 是账号级轻量失效通知（v0.9.1 C3）。只携带 opaque terminal id、
// 新 availability 投影与 revision，不携带完整 DTO；App 收到后重新拉 /v1/terminals，
// 快照始终是 DTO 事实，通知只是加速（裁决 T4）。
type PresenceInvalidation struct {
	TerminalID       string `json:"terminal_id"`
	Availability     string `json:"availability"`
	PresenceRevision int64  `json:"presence_revision"`
}

// EnvelopeJSON 是 SSE data 载荷的稳定序列化（脱敏：只有 opaque id + 投影 + revision）。
func (inv PresenceInvalidation) EnvelopeJSON() string {
	raw, err := json.Marshal(inv)
	if err != nil {
		// 字段全为标量，序列化不会失败；防御性兜底保持帧可解析。
		return "{}"
	}
	return string(raw)
}

// PresenceHub 管理进程内在线状态与广播订阅。
// SQLite 仍是业务真相，本结构只承载可重建的短状态：在线设备、SSE/WS 订阅。
type PresenceHub struct {
	mu                   sync.RWMutex
	devices              map[string]int64                                   // device_id -> last seen unix ms
	subscriptions        map[string]map[chan store.SessionEventRow]struct{} // session_id -> chans
	accountSubscriptions map[string]map[chan store.SessionEventRow]struct{} // account_id -> chans
	// accountPresenceSubscriptions 是 presence invalidation 的账号级订阅
	// （v0.9.1 C3）。与账号事件订阅分开：失效通知不进入 account_event_log，
	// 不占用账号 cursor 空间，丢失由客户端安全对账兜底。
	accountPresenceSubscriptions map[string]map[chan PresenceInvalidation]struct{}
	ttl                          time.Duration
}

// NewPresenceHub 构造进程内 presence hub。
func NewPresenceHub(ttl time.Duration) *PresenceHub {
	if ttl <= 0 {
		ttl = 60 * time.Second
	}
	return &PresenceHub{
		devices:                      make(map[string]int64),
		subscriptions:                make(map[string]map[chan store.SessionEventRow]struct{}),
		accountSubscriptions:         make(map[string]map[chan store.SessionEventRow]struct{}),
		accountPresenceSubscriptions: make(map[string]map[chan PresenceInvalidation]struct{}),
		ttl:                          ttl,
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

// SessionSubscribers 返回指定会话的当前订阅数（脱敏诊断计数，测试用）。
// session SSE 契约用它断言「断开即释放订阅」。
func (h *PresenceHub) SessionSubscribers(sessionID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subscriptions[sessionID])
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

// SubscribeAccountPresence 订阅账号级 presence invalidation（v0.9.1 C3）。
// 返回取消函数；取消时不关闭 channel，避免并发发布写入已关闭 channel。
func (h *PresenceHub) SubscribeAccountPresence(accountID string) (chan PresenceInvalidation, func()) {
	ch := make(chan PresenceInvalidation, 16)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.accountPresenceSubscriptions[accountID] == nil {
		h.accountPresenceSubscriptions[accountID] = make(map[chan PresenceInvalidation]struct{})
	}
	h.accountPresenceSubscriptions[accountID][ch] = struct{}{}
	cancel := func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if set, ok := h.accountPresenceSubscriptions[accountID]; ok {
			delete(set, ch)
			if len(set) == 0 {
				delete(h.accountPresenceSubscriptions, accountID)
			}
		}
	}
	return ch, cancel
}

// AccountPresenceSubscribers 返回指定账号的 presence 订阅数（脱敏计数，测试用）。
func (h *PresenceHub) AccountPresenceSubscribers(accountID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.accountPresenceSubscriptions[accountID])
}

// PublishPresenceInvalidation 把一次 presence 变化广播给同账号订阅者（非阻塞）。
// 调用方必须只在「revision 真实前进」时调用（发布端按 revision 单调去重，
// 计划 §3.3）；慢订阅者丢弃后由客户端安全对账兜底。
func (h *PresenceHub) PublishPresenceInvalidation(accountID string, inv PresenceInvalidation) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for ch := range h.accountPresenceSubscriptions[accountID] {
		select {
		case ch <- inv:
		default:
			// 失效通知允许丢失：快照是 DTO 事实，客户端有前台 safety reconcile。
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
