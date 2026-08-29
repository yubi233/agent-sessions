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
	// modelCatalog 只缓存上次健康探测得到的免费目录摘要，不缓存 provider 原始配置。
	modelCatalog    ModelCatalog
	modelCatalogErr error
	defaultModelErr error
}

// New 构造 OpenCode 适配器。
func New() *Adapter {
	_, defaultErr := configuredDefaultModel()
	return &Adapter{
		url:             strings.TrimSpace(os.Getenv(EnvURL)),
		handles:         map[string]*handle{},
		defaultModelErr: defaultErr,
	}
}

// NewWithClient 构造指定客户端的适配器（测试注入 httptest）。
func NewWithClient(c *Client) *Adapter {
	_, defaultErr := configuredDefaultModel()
	return &Adapter{
		url:             c.base,
		client:          c,
		handles:         map[string]*handle{},
		defaultModelErr: defaultErr,
	}
}

// configuredDefaultModel 返回显式环境默认值及其校验错误。默认值不能在这里
// 静默替换为付费模型；后续 Detect 会把错误反映为 model_select fail-closed。
func configuredDefaultModel() (string, error) {
	value := strings.TrimSpace(os.Getenv(EnvDefaultModel))
	if value == "" {
		return "", nil
	}
	if err := ValidateModelRef(value); err != nil {
		return "", fmt.Errorf("%s 无效: %w", EnvDefaultModel, err)
	}
	return value, nil
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

	// 能力矩阵中的模型目录来自本机 OpenCode 服务，而非静态 Provider 名称。
	// 目录获取失败只影响 model_select；基础会话能力仍按已验证 transport 声明。
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	catalog, catalogErr := a.getClient().DiscoverZenFreeModels(probeCtx)
	cancel()
	a.mu.Lock()
	a.modelCatalog = catalog
	a.modelCatalogErr = catalogErr
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
		case "model_select":
			if catalogErr == nil && len(catalog.Options) > 0 {
				status = adapter.CapabilityNative
				reason = ""
			} else if a.defaultModelErr != nil {
				reason = a.defaultModelErr.Error()
			} else if catalogErr != nil {
				reason = "未发现已配置的 OpenCode Zen 免费模型，模型选择已安全禁用。"
			} else {
				reason = "OpenCode Zen 免费模型目录为空，模型选择已安全禁用。"
			}
		case "effort_select":
			reason = effortSelectReason(catalog, catalogErr)
		}
		entry := adapter.Capability{Name: name, Status: status, Reason: reason}
		if name == "model_select" && status == adapter.CapabilityNative {
			entry.Options = append([]string(nil), catalog.Options...)
			entry.Default = catalog.Default
			entry.ModelDetails = make(map[string]adapter.ModelCapabilityDetail, len(catalog.Details))
			for model, detail := range catalog.Details {
				entry.ModelDetails[model] = adapter.ModelCapabilityDetail{
					ContextWindowTokens: detail.ContextWindowTokens,
					Reasoning:           detail.Reasoning,
					Efforts:             append([]string(nil), detail.Efforts...),
				}
			}
		}
		caps = append(caps, entry)
	}
	return adapter.Capabilities{
		Provider:     "opencode",
		Version:      health.Version,
		Capabilities: caps,
	}, nil
}

// effortSelectReason 区分“模型支持推理”与“可选择推理档位”。当前 OpenCode
// transport 尚未接入 effort 请求参数，因此有 variants 时也必须保持 fail-closed。
func effortSelectReason(catalog ModelCatalog, catalogErr error) string {
	if catalogErr != nil || catalog.Default == "" {
		return "OpenCode 推理档位目录未确认，已安全禁用。"
	}
	detail, ok := catalog.Details[catalog.Default]
	if !ok || !detail.Reasoning {
		return "OpenCode 当前默认模型未声明推理档位，已安全禁用。"
	}
	if len(detail.Efforts) == 0 {
		return "OpenCode 当前默认模型使用自动推理，未提供可选推理档位。"
	}
	return "OpenCode 当前模型提供推理档位，但 agent-sessions 尚未接入 session.effort_select，已安全禁用。"
}

// modelDetails 返回健康探测确认过的模型目录元数据。模型不在动态目录时不猜测。
func (a *Adapter) modelDetails(model string) (ModelDetails, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	detail, ok := a.modelCatalog.Details[strings.TrimSpace(model)]
	return detail, ok
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
	// 未指定模型时优先使用最近一次健康探测确认过的 Zen 免费默认值；目录尚未
	// 探测时仅允许显式、结构合法的环境值，除此之外保留空值以兼容旧服务端。
	// Relay 能力矩阵会把“目录未确认”展示为不可选，真实 gate 则始终显式传入已发现模型。
	if strings.TrimSpace(req.Model) == "" {
		a.mu.Lock()
		model := a.modelCatalog.Default
		defaultErr := a.defaultModelErr
		a.mu.Unlock()
		if model == "" {
			if defaultErr != nil {
				return nil, defaultErr
			}
			model, _ = configuredDefaultModel()
		}
		if model == "" {
			// 目录兜底只能取健康探测确认过的条目；空模型会让 opencode 服务端
			// 回退到它自己的配置默认，可能命中付费订阅条目。
			model = a.catalogFallbackModel()
		}
		if model != "" {
			req.Model = model
		}
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
	sub, ok := stream.subscribe(h.sessionID)
	if !ok {
		return errors.New("opencode 事件流已关闭")
	}
	h.sub = sub
	// 把订阅的规范化事件按 handle 序列号转发。
	go func() {
		// This goroutine is the sole owner of h.events closure. Dispose only
		// signals h.done, so an in-flight send can never race a close.
		defer close(h.events)
		for {
			select {
			case ev, ok := <-sub.ev:
				if !ok {
					return
				}
				ev = h.enrichUsageEvent(ev)
				h.mu.Lock()
				ev.Seq = h.seq
				h.seq++
				h.mu.Unlock()
				select {
				case h.events <- ev:
				case <-h.done:
					return
				}
			case <-h.done:
				return
			}
		}
	}()
	return nil
}

// enrichUsageEvent 将健康探测确认过的模型目录元数据补入 usage 事件。
// 这里只写模型标识、Provider 与上下文窗口计数，不写原始目录或 Provider 配置。
func (h *handle) enrichUsageEvent(event adapter.Event) adapter.Event {
	if event.Type != adapter.EventUsage {
		return event
	}
	h.mu.Lock()
	model := strings.TrimSpace(h.model)
	h.mu.Unlock()
	if model == "" {
		model = h.adapter.catalogFallbackModel()
	}
	if model == "" {
		return event
	}
	payload := make(map[string]any, len(event.Payload)+3)
	for key, value := range event.Payload {
		payload[key] = value
	}
	payload["provider"] = "opencode"
	payload["model"] = model
	if detail, ok := h.adapter.modelDetails(model); ok && detail.ContextWindowTokens > 0 {
		payload["context_window_tokens"] = detail.ContextWindowTokens
	}
	event.Payload = payload
	return event
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
	doneOnce  sync.Once
	// model 是创建/恢复时透传的模型选择；Send 时随 prompt_async 一起提交。
	model string
}

// InstanceID 返回 OpenCode /session 创建响应中的真实 session ID。
func (h *handle) InstanceID() string { return h.sessionID }

// ID 返回会话 ID（仅 daemon 本地使用；不进 Relay/Flutter 卡片）。
func (h *handle) ID() string { return h.sessionID }

// Send 向会话异步发送一条文本消息（POST /session/{id}/prompt_async）。
// catalogFallbackModel 返回目录排序后的兜底模型；目录为空时返回空串，由调用方
// 保持空值（不发明模型名）。
func (a *Adapter) catalogFallbackModel() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.modelCatalog.Default != "" {
		return a.modelCatalog.Default
	}
	if len(a.modelCatalog.Options) > 0 {
		return a.modelCatalog.Options[0]
	}
	return ""
}

// SetModel 应用运行期模型覆盖（session.model_select / session.send 的随行模型）。
// 空值忽略：空模型会让 opencode 服务端回退到它的配置默认，可能命中付费条目。
func (h *handle) SetModel(model string) {
	model = strings.TrimSpace(model)
	if model == "" {
		return
	}
	h.mu.Lock()
	h.model = model
	h.mu.Unlock()
}

func (h *handle) Send(ctx context.Context, text string) error {
	client := h.adapter.getClient()
	if client == nil {
		return errors.New("opencode client 未配置")
	}
	h.mu.Lock()
	model := h.model
	h.mu.Unlock()
	if strings.TrimSpace(model) == "" {
		model = h.adapter.catalogFallbackModel()
	}
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
	h.doneOnce.Do(func() { close(h.done) })
	h.adapter.detach(h)
	return nil
}
