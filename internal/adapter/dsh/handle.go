package dsh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"sync"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// handle 是运行中的 DSH ACP 会话实例句柄。
// 它同时实现 InstanceIDHandle（会话 ID 为桥 session/new 返回的真实 sessionId）与
// ForceKillHandle（per-session 子进程进程组所有权明确，session.kill 可安全强制终止）。
type handle struct {
	mu        sync.Mutex
	transport BridgeTransport
	sessionID string
	// nextID/nextSeq 分别是请求 id 与事件序号（单调递增）。
	nextID  int64
	nextSeq int64
	// pending 是等待响应的请求表；readLoop 按 id 回填。
	pending map[int64]*pendingReq
	// dropped 记录被丢弃/无法映射的入站帧与 update 变体计数（诊断用，不进公共协议）。
	dropped map[string]int64
	// events 是有界缓冲的 canonical 事件通道（读循环在桥关闭后关闭它）。
	events   chan adapter.Event
	readDone chan struct{}
	closed   bool
	// sendMu 串行化会话的 prompt 槽位：桥同一时刻只允许一个 in-flight prompt。
	sendMu sync.Mutex
}

// pendingReq 是等待中的请求记录。
type pendingReq struct {
	ch     chan rpcResult
	method string
}

// rpcResult 是一次请求的结果（成功为原始 result 字节，失败为错误）。
type rpcResult struct {
	result json.RawMessage
	err    error
}

// newHandle 构造会话句柄（事件通道有界缓冲，读循环随后启动）。
func newHandle(tr BridgeTransport) *handle {
	return &handle{
		transport: tr,
		events:    make(chan adapter.Event, 256),
		pending:   map[int64]*pendingReq{},
		dropped:   map[string]int64{},
		readDone:  make(chan struct{}),
	}
}

// InstanceID 返回桥 session/new 返回的真实会话 ID（供 daemon 持久化 instance 绑定）。
func (h *handle) InstanceID() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessionID
}

// setSessionID 记录会话 ID（Start 在 session/new 成功后调用）。
func (h *handle) setSessionID(id string) {
	h.mu.Lock()
	h.sessionID = id
	h.mu.Unlock()
}

// Send 把文本作为 session/prompt 单文本块发送，阻塞到该 turn 结束（桥返回 stopReason）。
// 取消当前 turn 请调用 Abort（cancel 通知会让桥以 stopReason=cancelled 结算本请求）。
func (h *handle) Send(ctx context.Context, text string) error {
	h.sendMu.Lock()
	defer h.sendMu.Unlock()
	params := map[string]any{
		"sessionId": h.sessionID,
		"prompt":    []map[string]any{{"type": "text", "text": text}},
	}
	_, err := h.request(ctx, "session/prompt", params)
	return err
}

// Abort 发送 session/cancel 通知（通知型无应答帧；幂等，对空闲会话桥容错）。
func (h *handle) Abort(ctx context.Context) error {
	_ = ctx
	return h.notify("session/cancel", map[string]any{"sessionId": h.sessionID})
}

// ForceKill 立即终止本会话的桥进程组（session.kill 语义；不等宽限）。
func (h *handle) ForceKill(ctx context.Context) error {
	_ = ctx
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil
	}
	h.mu.Unlock()
	return h.transport.ForceKill()
}

// Events 返回规范化事件流（读循环负责在桥关闭后关闭该通道）。
func (h *handle) Events() <-chan adapter.Event { return h.events }

// Dispose 关闭桥子进程（stdin EOF → 受控 dispose；宽限超时后 SIGKILL 进程组），
// 并等待读循环退出回收事件通道。幂等。
func (h *handle) Dispose(ctx context.Context) error {
	_ = ctx
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil
	}
	h.closed = true
	h.mu.Unlock()
	err := h.transport.Close()
	<-h.readDone
	return err
}

// request 发送带 id 的请求并等待响应；initialize/session/new 与 session/prompt
// （阻塞到 stopReason）都走这里。ctx 取消时清理 pending 并返回错误。
func (h *handle) request(ctx context.Context, method string, params any) (json.RawMessage, error) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil, errors.New("bridge 已关闭")
	}
	h.nextID++
	id := h.nextID
	req := &pendingReq{ch: make(chan rpcResult, 1), method: method}
	h.pending[id] = req
	h.mu.Unlock()

	frame := map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}
	if err := h.transport.WriteFrame(frame); err != nil {
		h.cancelPending(id)
		return nil, err
	}
	select {
	case res := <-req.ch:
		return res.result, res.err
	case <-ctx.Done():
		h.cancelPending(id)
		return nil, ctx.Err()
	}
}

// cancelPending 从待响应表中移除已取消的请求（迟到的响应将被记录为孤儿帧）。
func (h *handle) cancelPending(id int64) {
	h.mu.Lock()
	delete(h.pending, id)
	h.mu.Unlock()
}

// notify 发送通知帧（无 id，桥不回执）。
func (h *handle) notify(method string, params any) error {
	frame := map[string]any{"jsonrpc": "2.0", "method": method, "params": params}
	return h.transport.WriteFrame(frame)
}

// initializeParams 是 ACP initialize 请求参数（spec §协议事实 冻结形状）。
var initializeParams = map[string]any{
	"protocolVersion": 1,
	"clientInfo": map[string]any{
		"name":    "agent-sessions-dsh",
		"version": "0.0.1",
	},
	"clientCapabilities": map[string]any{},
}

// initializeResult 是 initialize 响应的最小投影。
type initializeResult struct {
	// ProtocolVersion 用 float64 承载：兼容 wire 上 1 与 1.0 两种数值形态。
	ProtocolVersion float64 `json:"protocolVersion"`
	AgentInfo       struct {
		Name    string `json:"name"`
		Version string `json:"version"`
	} `json:"agentInfo"`
}

// initialize 执行 ACP initialize 握手，返回协议版本与桥信息。
func (h *handle) initialize(ctx context.Context) (initializeResult, error) {
	raw, err := h.request(ctx, "initialize", initializeParams)
	if err != nil {
		return initializeResult{}, err
	}
	var res initializeResult
	if err := json.Unmarshal(raw, &res); err != nil {
		return initializeResult{}, fmt.Errorf("解析 initialize 响应: %w", err)
	}
	return res, nil
}

// newSession 创建桥会话（cwd 为用户工作区；mcpServers 固定空数组，桥拒绝非空）。
func (h *handle) newSession(ctx context.Context, cwd string) (string, error) {
	raw, err := h.request(ctx, "session/new", map[string]any{
		"cwd":        cwd,
		"mcpServers": []any{},
	})
	if err != nil {
		return "", err
	}
	var res struct {
		SessionID string `json:"sessionId"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return "", fmt.Errorf("解析 session/new 响应: %w", err)
	}
	if res.SessionID == "" {
		return "", errors.New("session/new 响应缺少 sessionId")
	}
	return res.SessionID, nil
}

// rpcMessage 是 JSON-RPC 帧的通用形状；ID 缺失表示通知，Method 非空表示"桥→客户端"请求。
type rpcMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error"`
}

// rpcError 是 JSON-RPC 错误对象。
type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

// hasID 判断帧是否携带 id（通知不带 id 字段）。
func (m *rpcMessage) hasID() bool { return len(m.ID) > 0 }

// idInt 解析帧 id 为 int64（桥使用数值 id；字符串 id 做防御支持）。
func (m *rpcMessage) idInt() (int64, error) {
	var n json.Number
	if err := json.Unmarshal(m.ID, &n); err == nil {
		return n.Int64()
	}
	var s string
	if err := json.Unmarshal(m.ID, &s); err == nil {
		if v, err := strconv.ParseInt(s, 10, 64); err == nil {
			return v, nil
		}
	}
	return 0, fmt.Errorf("无法解析 JSON-RPC id %s", string(m.ID))
}

// readLoop 消费桥 stdout 帧并分发：响应→pending、通知→mapper、桥请求→fail-closed 应答。
// 循环退出时关闭事件通道（Dispose 等待 readDone 后返回，保证不向已关闭通道写事件）。
func (h *handle) readLoop() {
	defer close(h.readDone)
	defer close(h.events)
	for {
		raw, err := h.transport.ReadFrame()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				// 传输级错误（如 scanner 超限）同样视为桥不可用，终止读循环。
				h.countDrop("transport_error")
			}
			return
		}
		var msg rpcMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			// 坏帧容错：丢弃并计数，继续处理后续帧。
			h.countDrop("bad_frame")
			continue
		}
		if !msg.hasID() {
			h.handleNotification(msg)
			continue
		}
		id, err := msg.idInt()
		if err != nil {
			h.countDrop("bad_frame")
			continue
		}
		if msg.Method != "" {
			h.handleBridgeRequest(id, msg)
			continue
		}
		h.resolvePending(id, msg)
	}
}

// handleNotification 处理桥的通知帧；目前只关注 session/update，其余方法名计数丢弃。
func (h *handle) handleNotification(msg rpcMessage) {
	if msg.Method != "session/update" {
		h.countDrop("notify:" + msg.Method)
		return
	}
	var params struct {
		SessionID string          `json:"sessionId"`
		Update    json.RawMessage `json:"update"`
	}
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		h.countDrop("bad_update")
		return
	}
	ev, ok, variant := mapSessionUpdate(params.SessionID, params.Update)
	if !ok {
		// 白名单外或未知 update 变体：丢弃并计数，不报错。
		h.countDrop("update:" + variant)
		return
	}
	h.pushEvent(ev)
}

// handleBridgeRequest 处理"桥→客户端"请求（带 id + method）。
func (h *handle) handleBridgeRequest(id int64, msg rpcMessage) {
	switch msg.Method {
	case "session/request_permission":
		h.handlePermissionRequest(id, msg.Params)
	default:
		// fs/*（writeTextFile/readTextFile 等）与任何未声明方法一律 -32601 fail-closed，
		// 与桥未实现方法（session/load 等）的错误形态保持一致。
		h.respondError(id, -32601, fmt.Sprintf("Method not found: %s", msg.Method))
	}
}

// handlePermissionRequest 处理桥的 session/request_permission 请求：
//  1. 先向事件流广播 EventPermissionRequest（供客户端策略层消费）；
//  2. 再按 fail-closed 返回 cancelled 决策——决策通道已接通，但当前策略是取消
//     而非静默批准（绝不替用户批准任何工具调用）；
//  3. 补充广播 EventPermissionDecision 记录已做出的取消决策。
func (h *handle) handlePermissionRequest(id int64, params json.RawMessage) {
	var req struct {
		SessionID string `json:"sessionId"`
		ToolCall  struct {
			ToolCallID string `json:"toolCallId"`
			Title      string `json:"title"`
		} `json:"toolCall"`
	}
	// 解析失败只影响事件载荷完整性，不影响取消决策本身。
	_ = json.Unmarshal(params, &req)
	payload := map[string]any{"instance_id": req.SessionID}
	if req.ToolCall.ToolCallID != "" {
		payload["tool_call_id"] = req.ToolCall.ToolCallID
	}
	if req.ToolCall.Title != "" {
		payload["title"] = req.ToolCall.Title
	}
	h.pushEvent(adapter.Event{Type: adapter.EventPermissionRequest, Payload: payload})
	// fail-closed：应答 SDK 的决策形状 {outcome:{outcome:"cancelled"}}（近端 protocol 冻结）。
	h.respondResult(id, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}})
	h.pushEvent(adapter.Event{
		Type: adapter.EventPermissionDecision,
		Payload: map[string]any{
			"instance_id": req.SessionID,
			"outcome":     "cancelled",
		},
	})
}

// respondResult 向桥写"客户端"侧请求的成功应答。
func (h *handle) respondResult(id int64, result any) {
	frame := map[string]any{"jsonrpc": "2.0", "id": id, "result": result}
	if err := h.transport.WriteFrame(frame); err != nil {
		h.countDrop("write_failed")
	}
}

// respondError 向桥写错误应答（fs/* 等未接入客户端能力的统一形状）。
func (h *handle) respondError(id int64, code int, message string) {
	frame := map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}}
	if err := h.transport.WriteFrame(frame); err != nil {
		h.countDrop("write_failed")
	}
}

// resolvePending 用响应帧回填对应请求；无匹配请求时记录为孤儿帧（防御）。
func (h *handle) resolvePending(id int64, msg rpcMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	req, ok := h.pending[id]
	if !ok {
		h.dropped["orphan_response"]++
		return
	}
	delete(h.pending, id)
	if msg.Error != nil {
		req.ch <- rpcResult{err: fmt.Errorf("JSON-RPC %s 失败（code %d）: %s", req.method, msg.Error.Code, msg.Error.Message)}
		return
	}
	req.ch <- rpcResult{result: msg.Result}
}

// pushEvent 把 canonical 事件送入缓冲事件通道；消费者过慢时丢弃增量事件防背压
// （与 opencode SSE 订阅的丢增量口径一致；完整正文仍可从会话历史恢复）。
func (h *handle) pushEvent(ev adapter.Event) {
	h.mu.Lock()
	h.nextSeq++
	ev.Seq = h.nextSeq
	h.mu.Unlock()
	select {
	case h.events <- ev:
	default:
		h.countDrop("event_overflow")
	}
}

// countDrop 递增某类丢弃/容错计数（并发安全）。
func (h *handle) countDrop(key string) {
	h.mu.Lock()
	h.dropped[key]++
	h.mu.Unlock()
}

// droppedCounts 返回丢弃计数的快照（契约测试断言用）。
func (h *handle) droppedCounts() map[string]int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make(map[string]int64, len(h.dropped))
	for k, v := range h.dropped {
		out[k] = v
	}
	return out
}
