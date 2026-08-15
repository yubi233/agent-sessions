// Package opencodeadapter 实现 OpenCode adapter（P3 -> v0.2/P1）。
// 使用本地 opencode server HTTP API（/session、/prompt_async、/abort、/event SSE）。
// Detect 只有探测到 healthy 服务并读出版本后才升级能力；否则全部 fail-closed 并给出中文原因。
package opencode

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// probeTimeout 是能力探测与服务发现的超时。探测失败不代表服务不可用，只代表本轮不可信。
const probeTimeout = 3 * time.Second

// Adapter 是 OpenCode 适配器。
type Adapter struct {
	mu       sync.Mutex
	url      string
	client   *Client
	stream   *streamReader
	handles  map[string]*handle
	detected bool
	version  string
}

// New 构造 OpenCode 适配器。
func New() *Adapter {
	return &Adapter{
		url:     strings.TrimSpace(os.Getenv(EnvURL)),
		handles: map[string]*handle{},
	}
}

// NewWithClient 构造指定客户端的适配器（测试注入 httptest）。
func NewWithClient(c *Client) *Adapter {
	return &Adapter{
		url:     c.base,
		client:  c,
		handles: map[string]*handle{},
	}
}

// health 探测本地服务；未配置 URL 或凭据缺失时返回确定性错误，供 Detect fail-closed。
func (a *Adapter) health(ctx context.Context) (HealthResult, error) {
	client := a.getClient()
	if client == nil {
		return HealthResult{}, os.ErrNotExist
	}
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	return client.Health(probeCtx)
}

// Detect 探测安装状态与版本，并按探测结果升级能力矩阵。
// 规则（ADPT-OPENCODE-01）：只有 GET /global/health 返回 healthy+version 才写 Version；
// Start/Resume/Send/Abort 已实现且契约测试通过才允许 native；其余保持 unsupported。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	health, err := a.health(ctx)
	if err != nil {
		return a.failClosed(""), nil
	}
	if !health.Healthy || health.Version == "" {
		return a.failClosed("OpenCode 本地服务健康检查未通过，控制能力已安全禁用。"), nil
	}
	a.mu.Lock()
	a.detected = true
	a.version = health.Version
	a.mu.Unlock()

	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		status := adapter.CapabilityUnsupported
		reason := "OpenCode 本地服务可探测，但该能力未实现或契约未通过。"
		switch name {
		case "start", "resume", "abort", "usage":
			// 已实现并通过 fixture contract：Start/Resume/Send/Abort 走真实 HTTP/SSE，usage 来自 step-finish 计数。
			status = adapter.CapabilityNative
			reason = ""
		case "permission":
			// opencode server 提供 /session/{id}/permissions/{id} 决策接口，但 Adapter 尚未实现。
			status = adapter.CapabilityUnsupported
		}
		caps = append(caps, adapter.Capability{Name: name, Status: status, Reason: reason})
	}
	return adapter.Capabilities{
		Provider:     "opencode",
		Version:      health.Version,
		Capabilities: caps,
	}, nil
}

// failClosed 构造全 unsupported 能力矩阵；reason 为空时根据探测失败原因生成中文说明。
func (a *Adapter) failClosed(reason string) adapter.Capabilities {
	if reason == "" {
		switch {
		case a.url == "":
			reason = "OpenCode 本地服务未配置（缺少 AGENT_SESSIONS_OPENCODE_URL），控制能力已安全禁用。"
		case os.Getenv(EnvPassword) == "":
			reason = "未配置 OPENCODE_SERVER_PASSWORD 凭据，无法通过 OpenCode 服务鉴权，控制能力已安全禁用。"
		default:
			reason = "OpenCode 本地服务探测失败，控制能力已安全禁用。"
		}
	}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		caps = append(caps, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
	}
	return adapter.Capabilities{Provider: "opencode", Capabilities: caps}
}

// Capabilities 返回能力矩阵。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// getClient 惰性构造客户端；未配置 URL 时返回 nil。
func (a *Adapter) getClient() *Client {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.client != nil {
		return a.client
	}
	c, err := NewClient()
	if err != nil {
		return nil
	}
	a.client = c
	return c
}

// getStream 惰性建立共享 SSE 订阅；已存在则复用。
func (a *Adapter) getStream(ctx context.Context) (*streamReader, error) {
	_ = ctx
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stream != nil {
		return a.stream, nil
	}
	client := a.client
	if client == nil {
		return nil, errors.New("opencode client 未配置")
	}
	stream, err := client.openStream()
	if err != nil {
		return nil, err
	}
	a.stream = stream
	return stream, nil
}

// Start 创建新会话（POST /session）并订阅其事件流。
// session ID 只在 handle 与本地 daemon 状态中流转，不进入公共协议。
func (a *Adapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	client := a.getClient()
	if client == nil {
		return nil, os.ErrNotExist
	}
	if req.WorkspaceRoot == "" {
		return nil, errors.New("Start 需要 workspace root")
	}
	session, err := client.CreateSession(ctx, sessionTitle(req))
	if err != nil {
		return nil, fmt.Errorf("opencode create session: %w", err)
	}
	h := a.newHandle(session.ID, req.Model)
	if err := h.attach(ctx); err != nil {
		_ = client.Abort(context.Background(), session.ID)
		a.detach(h)
		return nil, fmt.Errorf("opencode subscribe events: %w", err)
	}
	// 首个 turn：如果 StartRequest 带初始 prompt，异步发送；失败不回滚会话（可重试）。
	// 显式透传模型选择，避免 live gate 落到服务端默认模型而不可复现。
	if req.Prompt != "" {
		if err := client.PromptAsync(ctx, session.ID, []Part{TextPart(req.Prompt)}, req.Model); err != nil {
			_ = h.Dispose(context.Background())
			return nil, fmt.Errorf("opencode initial prompt: %w", err)
		}
	}
	return h, nil
}

// sessionTitle 生成会话标题：只使用模型/类型摘要，不写入 prompt 正文。
func sessionTitle(req adapter.StartRequest) string {
	switch {
	case req.Provider != "":
		return "agent-sessions:" + req.Provider
	case req.Model != "":
		return "agent-sessions:" + req.Model
	default:
		return "agent-sessions"
	}
}

// Resume 恢复已存在会话（ADPT-OPENCODE-02）：
//   - 服务端 404 / 不可达 -> unsupported（禁止伪装 resumed）
//   - 会话存在且仍有消息 -> resumed
//   - 会话存在但上下文丢失（无消息） -> restarted_with_context
func (a *Adapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	client := a.getClient()
	if client == nil {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	session, err := client.GetSession(ctx, req.InstanceID)
	if err != nil {
		// 404 或网络失败都不得伪装成功；分类按结果口径返回。
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	messages, err := client.GetMessages(ctx, session.ID, 1)
	if err != nil {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	result := adapter.WakeResumed
	if len(messages) == 0 {
		// 服务端上下文已丢失：只能带上下文重启新会话，明确返回 restarted_with_context。
		result = adapter.WakeRestartedWithContext
	}
	// Resume 不改变会话模型选择：保持服务端已有模型。
	h := a.newHandle(session.ID, "")
	if err := h.attach(ctx); err != nil {
		a.detach(h)
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	return adapter.ResumeResult{Result: result, InstanceID: session.ID}, nil
}

// newHandle 创建会话句柄并登记。
func (a *Adapter) newHandle(sessionID, model string) *handle {
	a.mu.Lock()
	defer a.mu.Unlock()
	h := &handle{
		sessionID: sessionID,
		adapter:   a,
		events:    make(chan adapter.Event, 256),
		done:      make(chan struct{}),
		seq:       1,
		model:     model,
	}
	a.handles[sessionID] = h
	return h
}

// attach 为 handle 绑定 SSE 订阅。
func (h *handle) attach(ctx context.Context) error {
	stream, err := h.adapter.getStream(ctx)
	if err != nil {
		return err
	}
	h.stream = stream
	sub, _ := stream.subscribe(h.sessionID)
	h.sub = sub
	// 把订阅的规范化事件按 handle 序列号转发。
	go func() {
		for ev := range sub.ev {
			h.mu.Lock()
			ev.Seq = h.seq
			h.seq++
			h.mu.Unlock()
			select {
			case h.events <- ev:
			case <-h.done:
				return
			}
		}
	}()
	return nil
}

// detach 注销 handle 的订阅与登记；没有存活句柄时回收共享 SSE 流。
func (a *Adapter) detach(h *handle) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.handles, h.sessionID)
	if h.sub != nil && a.stream != nil {
		a.stream.unsubscribe(h.sessionID, h.sub)
	}
	if len(a.handles) == 0 && a.stream != nil {
		stream := a.stream
		a.stream = nil
		go stream.close()
	}
}

// handle 是运行中的 OpenCode 会话实例句柄。
type handle struct {
	mu        sync.Mutex
	sessionID string
	adapter   *Adapter
	stream    *streamReader
	sub       *subscription
	events    chan adapter.Event
	seq       int64
	done      chan struct{}
	// model 是创建/恢复时透传的模型选择；Send 时随 prompt_async 一起提交。
	model string
}

// ID 返回会话 ID（仅 daemon 本地使用；不进 Relay/Flutter 卡片）。
func (h *handle) ID() string { return h.sessionID }

// Send 向会话异步发送一条文本消息（POST /session/{id}/prompt_async）。
func (h *handle) Send(ctx context.Context, text string) error {
	client := h.adapter.getClient()
	if client == nil {
		return errors.New("opencode client 未配置")
	}
	h.mu.Lock()
	model := h.model
	h.mu.Unlock()
	return client.PromptAsync(ctx, h.sessionID, []Part{TextPart(text)}, model)
}

// Abort 中止当前 turn（POST /session/{id}/abort）。
func (h *handle) Abort(ctx context.Context) error {
	client := h.adapter.getClient()
	if client == nil {
		return errors.New("opencode client 未配置")
	}
	return client.Abort(ctx, h.sessionID)
}

// Events 返回规范化事件流。
func (h *handle) Events() <-chan adapter.Event { return h.events }

// Dispose 释放订阅并回收句柄。
func (h *handle) Dispose(ctx context.Context) error {
	_ = ctx
	h.mu.Lock()
	defer h.mu.Unlock()
	select {
	case <-h.done:
		return nil
	default:
		close(h.done)
	}
	h.adapter.detach(h)
	return nil
}
