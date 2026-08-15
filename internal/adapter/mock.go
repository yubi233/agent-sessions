package adapter

import (
	"context"
	"fmt"
	"sync"
)

// MockAdapter 是可注入断线/超时/旧 instance 的 mock runtime。
// 仅测试环境启用；它演示完整会话控制事件，供 Relay->Daemon->客户端垂直切片使用。
type MockAdapter struct {
	provider string
	version  string
	mu       sync.Mutex
	nextID   int
	// wakeOverrides 允许注入六种唤醒结果。
	wakeOverrides map[string]string
}

// NewMockAdapter 构造 mock adapter。
func NewMockAdapter() *MockAdapter {
	return &MockAdapter{provider: "mock", version: "0.1.0", wakeOverrides: map[string]string{}}
}

// SetWakeOverride 为指定 instance 注入唤醒结果（MODE-04）。
func (m *MockAdapter) SetWakeOverride(instanceID, result string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.wakeOverrides[instanceID] = result
}

// Detect 报告 mock 能力：核心能力 native，跨 Provider 派发由 deterministic dispatcher 模拟。
func (m *MockAdapter) Detect(ctx context.Context) (Capabilities, error) {
	_ = ctx
	byName := map[string]string{
		"start": CapabilityNative, "resume": CapabilityNative, "abort": CapabilityNative,
		"permission": CapabilityNative, "permission_mode": CapabilityNative,
		"question": CapabilityNative, "plan": CapabilityNative,
		"goal": CapabilityNative, "skill_catalog": CapabilityNative, "invoke_skill": CapabilityNative,
		"model_select": CapabilityNative, "effort_select": CapabilityNative,
		"attachments": CapabilityNative, "file_read": CapabilityNative, "git_read": CapabilityNative,
		"usage": CapabilityNative, "delegate_session": CapabilityNative,
		"delegate_cross_provider": CapabilityEmulated,
	}
	caps := make([]Capability, 0, len(CapabilityNames))
	for _, name := range CapabilityNames {
		status := byName[name]
		if status == "" {
			status = CapabilityUnsupported
		}
		caps = append(caps, Capability{Name: name, Status: status})
	}
	return Capabilities{Provider: m.provider, Version: m.version, Capabilities: caps}, nil
}

// Capabilities 返回能力矩阵。
func (m *MockAdapter) Capabilities() Capabilities {
	caps, _ := m.Detect(context.Background())
	return caps
}

// Start 启动 mock 会话实例，流式产生事件。
func (m *MockAdapter) Start(ctx context.Context, req StartRequest) (Handle, error) {
	m.mu.Lock()
	m.nextID++
	id := fmt.Sprintf("mock-%d", m.nextID)
	m.mu.Unlock()

	ev := make(chan Event, 16)
	handle := &mockHandle{id: id, events: ev, done: make(chan struct{})}

	// 模拟流式 delta、消息完成与 usage。
	go func() {
		defer close(ev)
		emit := func(t EventType, p map[string]any) {
			select {
			case ev <- Event{Type: t, Seq: 1, Payload: p}:
			case <-ctx.Done():
			}
		}
		emit(EventTurnStarted, map[string]any{"instance_id": id})
		emit(EventMessageDelta, map[string]any{"text": "hello from mock"})
		emit(EventMessageCompleted, map[string]any{"text": "hello from mock"})
		emit(EventUsage, map[string]any{"input_tokens": 10, "output_tokens": 20})
		<-handle.done
	}()
	return handle, nil
}

// Resume 恢复 mock 会话；未注册 instance 返回 unsupported，可注入指定结果。
func (m *MockAdapter) Resume(ctx context.Context, req ResumeRequest) (ResumeResult, error) {
	m.mu.Lock()
	result := m.wakeOverrides[req.InstanceID]
	m.mu.Unlock()
	if result == "" {
		result = WakeResumed
	}
	if result == WakeUnsupported || result == WakeLocalStateMissing {
		return ResumeResult{Result: result}, nil
	}
	return ResumeResult{Result: result, InstanceID: req.InstanceID}, nil
}

// mockHandle 是 mock 会话实例句柄。
type mockHandle struct {
	id     string
	events chan Event
	done   chan struct{}
	mu     sync.Mutex
}

func (h *mockHandle) Send(ctx context.Context, text string) error {
	_ = ctx
	select {
	case h.events <- Event{Type: EventMessageDelta, Payload: map[string]any{"text": text}}:
	default:
	}
	return nil
}

func (h *mockHandle) Abort(ctx context.Context) error {
	_ = ctx
	return nil
}

func (h *mockHandle) Events() <-chan Event { return h.events }

func (h *mockHandle) Dispose(ctx context.Context) error {
	_ = ctx
	h.mu.Lock()
	defer h.mu.Unlock()
	select {
	case <-h.done:
	default:
		close(h.done)
	}
	return nil
}
