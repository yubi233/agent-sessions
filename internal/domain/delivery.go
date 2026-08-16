package domain

import (
	"sync"

	"github.com/yubi233/agent-sessions/internal/store"
)

// DaemonDeliveryHub 只加速已持久化的 Terminal 命令投递。断线或进程重启后，Daemon 必须从
// SQLite delivery_seq 回放，因此此 Hub 不承担可靠性或账号级事件语义。
type DaemonDeliveryHub struct {
	mu            sync.RWMutex
	subscriptions map[string]map[chan store.DaemonDeliveryRow]struct{}
}

func NewDaemonDeliveryHub() *DaemonDeliveryHub {
	return &DaemonDeliveryHub{subscriptions: make(map[string]map[chan store.DaemonDeliveryRow]struct{})}
}

func (h *DaemonDeliveryHub) Subscribe(terminalID string) (chan store.DaemonDeliveryRow, func()) {
	ch := make(chan store.DaemonDeliveryRow, 32)
	h.mu.Lock()
	if h.subscriptions[terminalID] == nil {
		h.subscriptions[terminalID] = make(map[chan store.DaemonDeliveryRow]struct{})
	}
	h.subscriptions[terminalID][ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		set := h.subscriptions[terminalID]
		if _, ok := set[ch]; ok {
			delete(set, ch)
			close(ch)
		}
		if len(set) == 0 {
			delete(h.subscriptions, terminalID)
		}
	}
}

// Publish 是非阻塞优化路径。慢订阅者丢弃推送后仍能依赖 SSE reconnect 回放，不能影响命令提交。
func (h *DaemonDeliveryHub) Publish(terminalID string, delivery store.DaemonDeliveryRow) {
	h.mu.RLock()
	set := h.subscriptions[terminalID]
	channels := make([]chan store.DaemonDeliveryRow, 0, len(set))
	for ch := range set {
		channels = append(channels, ch)
	}
	h.mu.RUnlock()
	for _, ch := range channels {
		select {
		case ch <- delivery:
		default:
		}
	}
}
