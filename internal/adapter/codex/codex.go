// Package codexadapter 实现 Codex adapter（P3）。
// W2（ADPT-CODEX-02）：Start/Send → thread/start + turn/start，Resume → thread/resume，
// Abort → turn/interrupt；通知经 mapper.go 映射为 canonical event。
// 协议证据：本机 codex app-server generate-json-schema（0.142.5）；golden trace 见 testdata/golden_trace.json。
package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// EnvBin 是 Codex 可执行环境变量。
const EnvBin = "AGENT_SESSIONS_CODEX_BIN"

// EnvEnabled 是 Codex adapter 接入 Daemon 执行侧 adapters map 的 feature flag。
// 缺省关闭；显式设为非空值才注册（W4 live smoke 前的灰度开关，回滚即 unset）。
const EnvEnabled = "AGENT_SESSIONS_CODEX_ENABLE"

// EnabledFromEnv 报告 feature flag 是否显式开启。
func EnabledFromEnv(getenv func(string) string) bool {
	if getenv == nil {
		return false
	}
	return strings.TrimSpace(getenv(EnvEnabled)) != ""
}

// Adapter 是 Codex 适配器。单个 app-server 进程被同 adapter 的多个 thread 共享；
// 通知按 params.threadId 路由到对应 handle。
type Adapter struct {
	bin      string
	detected bool
	version  string

	rpcFactory func(context.Context) (*RPCClient, error)

	mu      sync.Mutex
	rpc     *RPCClient
	handles map[string]*handle // key: threadId

	pendingApprovals map[string]*pendingApproval // key: itemId
}

// New 构造 Codex 适配器。
func New() *Adapter {
	a := &Adapter{
		bin:              os.Getenv(EnvBin),
		handles:          map[string]*handle{},
		pendingApprovals: map[string]*pendingApproval{},
	}
	if a.bin != "" {
		if out, err := exec.Command(a.bin, "--version").Output(); err == nil {
			version := strings.TrimSpace(string(out))
			if version != "" {
				a.detected = true
				a.version = version
			}
		}
	}
	return a
}

// NewWithRPC 以注入的 RPC 工厂构造适配器（契约测试注入确定性 fake app-server）。
func NewWithRPC(factory func(context.Context) (*RPCClient, error)) *Adapter {
	return &Adapter{rpcFactory: factory, handles: map[string]*handle{}, pendingApprovals: map[string]*pendingApproval{}}
}

// Available 报告是否探测到可执行二进制。
func (a *Adapter) Available() bool { return a.detected }

// Detect 返回能力矩阵。
// W2：start/resume/abort 由 thread/session golden trace 契约覆盖；
// W3（ADPT-CODEX-03）：permission（审批 round-trip）、skill_catalog（skills/list）、
// plan/goal（通知映射）、model_select/effort_select（turn/start 覆盖参数）已证明，升级 native。
// question、invoke_skill、attachments 等未证明项保持 unsupported（per-capability disable）。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	reason := "Codex CLI 未配置或探测失败，控制能力已安全禁用。"
	if a.detected {
		reason = "该能力尚未在 ADPT-CODEX 契约中证明，已安全禁用。"
	}
	native := map[string]bool{
		"start": true, "resume": true, "abort": true,
		"permission": true, "plan": true, "goal": true,
		"skill_catalog": true, "model_select": true, "effort_select": true,
	}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		status := adapter.CapabilityUnsupported
		capReason := reason
		if native[name] && a.detected {
			status = adapter.CapabilityNative
			capReason = ""
		}
		caps = append(caps, adapter.Capability{Name: name, Status: status, Reason: capReason})
	}
	return adapter.Capabilities{Provider: "codex", Version: a.version, Capabilities: caps}, nil
}

// Capabilities 返回能力矩阵。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// getRPC 惰性建立与 app-server 的 JSON-RPC 连接并启动通知泵；失败 fail-closed。
func (a *Adapter) getRPC(ctx context.Context) (*RPCClient, error) {
	a.mu.Lock()
	if a.rpc != nil {
		c := a.rpc
		a.mu.Unlock()
		return c, nil
	}
	factory := a.rpcFactory
	bin := a.bin
	a.mu.Unlock()

	if factory == nil {
		if bin == "" {
			return nil, os.ErrNotExist
		}
		client, err := NewRPCClient(ctx, bin)
		if err != nil {
			return nil, err
		}
		// 真实 app-server 要求 initialize 握手（fake 注入路径不做握手，契约脚本按序驱动）。
		if err := initializeAppServer(ctx, client); err != nil {
			_ = client.Close()
			return nil, fmt.Errorf("app-server initialize: %w", err)
		}
		if !a.setRPC(client) {
			_ = client.Close()
			return a.getRPC(ctx)
		}
		return client, nil
	}
	client, err := factory(ctx)
	if err != nil {
		return nil, err
	}
	if !a.setRPC(client) {
		// 并发惰性初始化：保留先到者，关闭后到者。
		_ = client.Close()
		return a.getRPC(ctx)
	}
	return client, nil
}

// setRPC 登记新客户端；已有客户端时返回 false。
func (a *Adapter) setRPC(client *RPCClient) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.rpc != nil {
		return false
	}
	a.rpc = client
	// 订阅必须在启动泵 goroutine 之前同步登记：Notifications()/Requests()
	// 是"调用即注册等待通道"的懒订阅模型，若在 goroutine 内才注册，
	// 首个请求的响应通知可能在 notifyWait 仍为空时到达并被
	// dispatchNotification 静默丢弃（v0.6 发布门实测的 golden trace 偶发丢事件）。
	notifications := client.Notifications()
	requests := client.Requests()
	go a.pumpNotifications(client, notifications)
	go a.pumpApprovals(client, requests)
	return true
}

// pumpNotifications 消费共享通知流，按 threadId 路由到对应 handle。
func (a *Adapter) pumpNotifications(client *RPCClient, notifications <-chan RPCNotification) {
	for n := range notifications {
		var probe struct {
			ThreadID string `json:"threadId"`
		}
		_ = json.Unmarshal(n.Params, &probe)
		events := mapNotification(n)
		if len(events) == 0 && probe.ThreadID == "" {
			continue
		}
		a.mu.Lock()
		h := a.handles[probe.ThreadID]
		a.mu.Unlock()
		if h == nil {
			continue
		}
		for _, ev := range events {
			h.deliver(ev)
		}
	}
}

// Start 创建新线程（thread/start），带初始 prompt 时立即发起首个 turn（turn/start）。
func (a *Adapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	if req.WorkspaceRoot == "" {
		return nil, errors.New("codex Start 需要 workspace root")
	}
	client, err := a.getRPC(ctx)
	if err != nil {
		return nil, errors.New("codex app-server 不可用，Start 已安全禁用")
	}
	var resp threadStartResponse
	if err := client.Call(ctx, methodThreadStart, buildThreadStartParams(req), &resp); err != nil {
		return nil, err
	}
	if resp.Thread.ID == "" {
		return nil, errors.New("codex thread/start 未返回 thread id")
	}
	h := a.newHandle(resp.Thread.ID)
	h.setModel(req.Model)
	h.setEffort(req.Effort)
	if req.Prompt != "" {
		turnID, err := h.startTurnFor(ctx, client, req.Prompt)
		if err != nil {
			_ = h.Dispose(context.Background())
			return nil, err
		}
		h.setTurnID(turnID)
	}
	return h, nil
}

// Resume 恢复已存在线程（thread/resume）。禁止把失败伪装成 resumed：
//   - 进程/RPC 失败或服务端错误 -> unsupported
//   - 线程存在且已有 turns -> resumed
//   - 线程存在但上下文为空 -> restarted_with_context
func (a *Adapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	client, err := a.getRPC(ctx)
	if err != nil {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	var resp threadStartResponse
	if err := client.Call(ctx, methodThreadResume, buildThreadResumeParams(req.InstanceID), &resp); err != nil {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	if resp.Thread.ID == "" {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	result := adapter.WakeResumed
	if len(resp.Thread.Turns) == 0 {
		result = adapter.WakeRestartedWithContext
	}
	_ = a.newHandle(resp.Thread.ID)
	return adapter.ResumeResult{Result: result, InstanceID: resp.Thread.ID}, nil
}

// Skill 是 skills/list 返回的技能条目（SkillMetadata 子集）。
type Skill struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
	Path        string `json:"path,omitempty"`
	Scope       string `json:"scope,omitempty"`
}

// Skills 拉取技能目录（skills/list）。失败返回错误，不伪造空目录。
func (a *Adapter) Skills(ctx context.Context, cwds []string) ([]Skill, error) {
	client, err := a.getRPC(ctx)
	if err != nil {
		return nil, errors.New("codex app-server 不可用，skills 已安全禁用")
	}
	var resp struct {
		Data []struct {
			Cwd    string  `json:"cwd"`
			Skills []Skill `json:"skills"`
			Errors []any   `json:"errors"`
		} `json:"data"`
	}
	params := map[string]any{}
	if len(cwds) > 0 {
		params["cwds"] = cwds
	}
	if err := client.Call(ctx, methodSkillsList, params, &resp); err != nil {
		return nil, err
	}
	out := make([]Skill, 0, 16)
	for _, entry := range resp.Data {
		out = append(out, entry.Skills...)
	}
	return out, nil
}

// Decide 回答一条待审批请求（item/commandExecution/requestApproval），
// 并向对应 handle 投递 permission_decision 事件。decision 取 Decision* 常量。
func (a *Adapter) Decide(ctx context.Context, itemID, decision string) error {
	if decision != DecisionAccept && decision != DecisionDecline && decision != DecisionCancel {
		return fmt.Errorf("未知审批决策 %q", decision)
	}
	a.mu.Lock()
	pending := a.pendingApprovals[itemID]
	delete(a.pendingApprovals, itemID)
	a.mu.Unlock()
	if pending == nil {
		return fmt.Errorf("没有待审批请求 item_id=%s", itemID)
	}
	if err := pending.client.Respond(pending.reqID, map[string]any{"decision": decision}); err != nil {
		return err
	}
	a.mu.Lock()
	h := a.handles[pending.threadID]
	a.mu.Unlock()
	if h != nil {
		h.deliver(adapter.Event{
			Type: adapter.EventPermissionDecision,
			Payload: map[string]any{
				"item_id":  itemID,
				"decision": decision,
			},
		})
	}
	return nil
}

// pumpApprovals 消费服务端审批请求：登记 pending 并投递 permission_request 事件。
func (a *Adapter) pumpApprovals(client *RPCClient, requests <-chan RPCServerRequest) {
	for req := range requests {
		itemID, command, ev := mapApprovalRequest(req.Method, req.Params)
		if itemID == "" {
			continue // 未知服务端请求安全降级（W3 只证明 commandExecution 审批）
		}
		var probe struct {
			ThreadID string `json:"threadId"`
		}
		_ = json.Unmarshal(req.Params, &probe)
		a.mu.Lock()
		a.pendingApprovals[itemID] = &pendingApproval{
			client:   client,
			reqID:    req.ID,
			threadID: probe.ThreadID,
			command:  command,
		}
		h := a.handles[probe.ThreadID]
		a.mu.Unlock()
		if h != nil {
			h.deliver(ev)
		}
	}
}

type pendingApproval struct {
	client   *RPCClient
	reqID    json.RawMessage
	threadID string
	command  string
}

// newHandle 创建线程句柄并登记到通知路由表。
func (a *Adapter) newHandle(threadID string) *handle {
	h := &handle{
		threadID: threadID,
		adapter:  a,
		events:   make(chan adapter.Event, 256),
		done:     make(chan struct{}),
	}
	h.seq = 1
	a.mu.Lock()
	a.handles[threadID] = h
	a.mu.Unlock()
	return h
}

// Close 终止共享 app-server 进程；daemon 回收 adapter 时调用，幂等。
func (a *Adapter) Close() error {
	a.mu.Lock()
	client := a.rpc
	a.rpc = nil
	a.mu.Unlock()
	if client == nil {
		return nil
	}
	return client.Close()
}

// handle 是运行中的 codex 线程句柄。
type handle struct {
	threadID string
	adapter  *Adapter

	mu       sync.Mutex
	turnID   string // 最近一次 turn/start 成功的 turn；Abort 依赖它
	model    string // 当前模型选择；turn/start 覆盖参数
	effort   string // 当前 reasoning effort；turn/start 覆盖参数
	done     chan struct{}
	doneOnce sync.Once

	events chan adapter.Event
	seqMu  sync.Mutex
	seq    int64
}

// InstanceID 返回 app-server 的真实 thread id（InstanceIDHandle）。
func (h *handle) InstanceID() string { return h.threadID }

// startTurnFor 以当前 model/effort 覆盖发起一个 turn 并返回其 id。
func (h *handle) startTurnFor(ctx context.Context, client *RPCClient, text string) (string, error) {
	h.mu.Lock()
	model, effort := h.model, h.effort
	h.mu.Unlock()
	var resp turnStartResponse
	params := buildTurnStartParams(h.threadID, text, model, effort)
	if err := client.Call(ctx, methodTurnStart, params, &resp); err != nil {
		return "", err
	}
	if resp.Turn.ID == "" {
		return "", errors.New("codex turn/start 未返回 turn id")
	}
	return resp.Turn.ID, nil
}

// SetModel 设置后续 turn 的模型覆盖（model_select）。
func (h *handle) SetModel(model string) { h.setModel(model) }

// SetEffort 设置后续 turn 的 reasoning effort 覆盖（effort_select）。
func (h *handle) SetEffort(effort string) { h.setEffort(effort) }

// Send 发送用户输入（turn/start）。
func (h *handle) Send(ctx context.Context, text string) error {
	client, err := h.adapter.getRPC(ctx)
	if err != nil {
		return errors.New("codex app-server 不可用，Send 已安全禁用")
	}
	turnID, err := h.startTurnFor(ctx, client, text)
	if err != nil {
		return err
	}
	h.setTurnID(turnID)
	return nil
}

// Abort 中止当前 turn（turn/interrupt）；无活跃 turn 时报错而非伪装成功。
func (h *handle) Abort(ctx context.Context) error {
	client, err := h.adapter.getRPC(ctx)
	if err != nil {
		return errors.New("codex app-server 不可用，Abort 已安全禁用")
	}
	h.mu.Lock()
	turnID := h.turnID
	h.mu.Unlock()
	if turnID == "" {
		return errors.New("codex 无活跃 turn 可中止")
	}
	return client.Call(ctx, methodTurnInterrupt, buildTurnInterruptParams(h.threadID, turnID), nil)
}

// Events 返回规范化事件流。
func (h *handle) Events() <-chan adapter.Event { return h.events }

// Dispose 注销句柄；共享 app-server 进程由 Adapter.Close 统一回收。
func (h *handle) Dispose(ctx context.Context) error {
	_ = ctx
	h.doneOnce.Do(func() { close(h.done) })
	a := h.adapter
	a.mu.Lock()
	delete(a.handles, h.threadID)
	a.mu.Unlock()
	return nil
}

func (h *handle) setTurnID(turnID string) {
	if turnID == "" {
		return
	}
	h.mu.Lock()
	h.turnID = turnID
	h.mu.Unlock()
}

func (h *handle) setModel(model string) {
	h.mu.Lock()
	h.model = model
	h.mu.Unlock()
}

func (h *handle) setEffort(effort string) {
	h.mu.Lock()
	h.effort = effort
	h.mu.Unlock()
}

// deliver 把 canonical 事件按 handle 序列号投递到事件通道；Dispose 后静默丢弃。
func (h *handle) deliver(ev adapter.Event) {
	h.seqMu.Lock()
	ev.Seq = h.seq
	h.seq++
	h.seqMu.Unlock()
	select {
	case h.events <- ev:
	case <-h.done:
	}
}
