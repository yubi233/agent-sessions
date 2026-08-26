package dsh

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// fakeBridge 是 BridgeTransport 的内存实现（契约测试注入点）：
//   - 脚本回调在每次出站帧写入后同步执行，按请求 method/id 注入应答——应答在
//     请求注册之后才入队，消除"应答先于 pending 注册"的时序竞态；
//   - 测试也可直接 push 入站帧（session/update 通知、桥请求、坏帧）；
//   - Close/ForceKill 关闭入站队列，模拟桥进程退出（ReadFrame 返回 io.EOF）。
type fakeBridge struct {
	mu       sync.Mutex
	script   func(fb *fakeBridge, msg map[string]any)
	inbound  chan []byte
	outbound []map[string]any
	outCh    chan map[string]any
	closed   bool
}

func newFakeBridge() *fakeBridge {
	return &fakeBridge{
		inbound:  make(chan []byte, 64),
		outCh:    make(chan map[string]any, 64),
		outbound: []map[string]any{},
	}
}

// pushRaw 注入一帧原始字节（含坏帧场景）。
func (f *fakeBridge) pushRaw(raw []byte) { f.inbound <- raw }

// push 注入一帧（JSON 编码后入队）。
func (f *fakeBridge) push(t *testing.T, frame any) {
	t.Helper()
	raw, err := json.Marshal(frame)
	if err != nil {
		t.Fatalf("编码假桥帧: %v", err)
	}
	f.pushRaw(raw)
}

// WriteFrame 记录出站帧（经编码-解码归一，模拟真线上类型形状）并同步执行脚本。
func (f *fakeBridge) WriteFrame(msg map[string]any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return errors.New("fake bridge closed")
	}
	// 归一化：id 变为 float64、嵌套容器变为 []any / map[string]any，与真实 ndjson 一致。
	raw, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	var norm map[string]any
	if err := json.Unmarshal(raw, &norm); err != nil {
		return err
	}
	f.outbound = append(f.outbound, norm)
	select {
	case f.outCh <- norm:
	default:
	}
	if f.script != nil {
		f.script(f, msg)
	}
	return nil
}

// ReadFrame 从入站队列取一帧；队列关闭（桥退出）返回 io.EOF。
func (f *fakeBridge) ReadFrame() ([]byte, error) {
	raw, ok := <-f.inbound
	if !ok {
		return nil, io.EOF
	}
	return raw, nil
}

// Close 关闭入站队列（模拟进程退出）；幂等。
func (f *fakeBridge) Close() error { return f.shutdown() }

// ForceKill 同 Close（内存假桥无进程可杀）。
func (f *fakeBridge) ForceKill() error { return f.shutdown() }

func (f *fakeBridge) shutdown() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.closed {
		f.closed = true
		close(f.inbound)
	}
	return nil
}

// written 返回已写入帧的副本（断言用）。
func (f *fakeBridge) written() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]map[string]any, len(f.outbound))
	copy(out, f.outbound)
	return out
}

// lastWritten 返回最后一帧。
func (f *fakeBridge) lastWritten() map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.outbound) == 0 {
		return nil
	}
	return f.outbound[len(f.outbound)-1]
}

// drainOut 排空出站通知通道中已排队帧（在注入新桥请求前调用，隔离旧帧）。
func drainOut(fb *fakeBridge) {
	for {
		select {
		case <-fb.outCh:
		default:
			return
		}
	}
}

// frameID 提取出站帧的数值 id（归一化后为 float64，原始帧可能为 int64）。
func frameID(msg map[string]any) int64 {
	switch v := msg["id"].(type) {
	case int64:
		return v
	case float64:
		return int64(v)
	case json.Number:
		n, _ := v.Int64()
		return n
	}
	return 0
}

// methodOf 取帧 method（map 可能为 nil）。
func methodOf(msg map[string]any) string {
	if msg == nil {
		return ""
	}
	m, _ := msg["method"].(string)
	return m
}

// respondByMethod 是常用脚本：按请求 method 注入固定应答（id 回显请求 id）；
// session/cancel 为通知，无应答。
func respondByMethod(t *testing.T, sessionID string) func(fb *fakeBridge, msg map[string]any) {
	t.Helper()
	return func(fb *fakeBridge, msg map[string]any) {
		id := frameID(msg)
		switch methodOf(msg) {
		case "initialize":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{
					"protocolVersion": 1,
					"agentInfo":       map[string]any{"name": "deepseek-harness-acp", "version": "0.0.1"},
				},
			})
		case "session/new":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{"sessionId": sessionID},
			})
		case "session/prompt":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{"stopReason": "end_turn"},
			})
		}
	}
}

// startWithFake 用假桥启动一个 DSH 会话句柄（契约测试公共脚手架）。
func startWithFake(t *testing.T, fb *fakeBridge) adapter.Handle {
	t.Helper()
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	return h
}

// (a) 版本不符 → Detect 全 unsupported、Version 留空、各带中文原因。
func TestDetectVersionMismatchFailClosed(t *testing.T) {
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "initialize" {
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{
					"protocolVersion": 2,
					"agentInfo":       map[string]any{"name": "deepseek-harness-acp", "version": "9.9.9"},
				},
			})
		}
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if caps.Provider != "dsh" || caps.Version != "" {
		t.Fatalf("版本不符时 Version 必须留空: %#v", caps)
	}
	for _, c := range caps.Capabilities {
		if c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status=%q：版本不符必须全 unsupported", c.Name, c.Status)
		}
		if c.Reason == "" {
			t.Fatalf("%s 必须带中文原因", c.Name)
		}
	}
}

// (b) Start/Send 往返（initialize → session/new(cwd) → session/prompt 单文本块）
// 与 agent_message_chunk → message_completed 映射。
func TestStartSendRoundTripAndMessageCompleted(t *testing.T) {
	const sessionID = "sess-0001"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)

	idh, ok := h.(adapter.InstanceIDHandle)
	if !ok {
		t.Fatal("Start 必须返回 InstanceIDHandle")
	}
	if idh.InstanceID() != sessionID {
		t.Fatalf("InstanceID = %q, want %q", idh.InstanceID(), sessionID)
	}

	// 出站握手帧断言：initialize → session/new(cwd=WorkspaceRoot, mcpServers=[])。
	written := fb.written()
	if len(written) < 2 {
		t.Fatalf("预期至少 2 帧，实际 %d", len(written))
	}
	if methodOf(written[0]) != "initialize" {
		t.Fatalf("首帧必须是 initialize，实际 %q", methodOf(written[0]))
	}
	if methodOf(written[1]) != "session/new" {
		t.Fatalf("次帧必须是 session/new，实际 %q", methodOf(written[1]))
	}
	newParams, _ := written[1]["params"].(map[string]any)
	if newParams["cwd"] != "/tmp/dsh-ws" {
		t.Fatalf("session/new cwd = %v, want /tmp/dsh-ws", newParams["cwd"])
	}
	if servers, _ := newParams["mcpServers"].([]any); len(servers) != 0 {
		t.Fatalf("mcpServers 必须为空数组，实际 %v", newParams["mcpServers"])
	}

	// 注入助手文本块通知，然后 Send（读循环按队列顺序先消费通知再结算 prompt）。
	fb.push(t, map[string]any{
		"jsonrpc": "2.0",
		"method":  "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update": map[string]any{
				"sessionUpdate": "agent_message_chunk",
				"content":       map[string]any{"type": "text", "text": "你好，DSH"},
				"messageId":     "msg-1",
			},
		},
	})
	if err := h.Send(context.Background(), "继续"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// prompt 帧形状：{sessionId, prompt:[{type:text,text}]}。
	last := fb.lastWritten()
	if methodOf(last) != "session/prompt" {
		t.Fatalf("Send 后末帧必须是 session/prompt，实际 %q", methodOf(last))
	}
	p, _ := last["params"].(map[string]any)
	if p["sessionId"] != sessionID {
		t.Fatalf("prompt sessionId = %v, want %q", p["sessionId"], sessionID)
	}
	prompt, _ := p["prompt"].([]any)
	block, _ := prompt[0].(map[string]any)
	if block["type"] != "text" || block["text"] != "继续" {
		t.Fatalf("prompt 文本块形状不符: %#v", block)
	}

	// 事件流映射：agent_message_chunk → message_completed（携带文本与 message_id）。
	select {
	case ev := <-h.Events():
		if ev.Type != adapter.EventMessageCompleted {
			t.Fatalf("事件类型 = %q, want message_completed", ev.Type)
		}
		if ev.Payload["text"] != "你好，DSH" {
			t.Fatalf("completed 文本 = %v", ev.Payload["text"])
		}
		if ev.Payload["message_id"] != "msg-1" {
			t.Fatalf("completed message_id = %v", ev.Payload["message_id"])
		}
	case <-time.After(5 * time.Second):
		t.Fatal("等待 message_completed 事件超时")
	}
}

// (c) Abort 幂等：重复 cancel 通知不报错，且帧形状为 {sessionId}。
func TestAbortIdempotent(t *testing.T) {
	const sessionID = "sess-0001"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)

	if err := h.Abort(context.Background()); err != nil {
		t.Fatalf("第一次 Abort: %v", err)
	}
	if err := h.Abort(context.Background()); err != nil {
		t.Fatalf("第二次 Abort 必须幂等: %v", err)
	}

	cancels := 0
	for _, m := range fb.written() {
		if methodOf(m) != "session/cancel" {
			continue
		}
		cancels++
		p, _ := m["params"].(map[string]any)
		if p["sessionId"] != sessionID {
			t.Fatalf("cancel params = %#v, want sessionId=%q", p, sessionID)
		}
	}
	if cancels < 2 {
		t.Fatalf("预期至少两帧 session/cancel，实际 %d", cancels)
	}
}

// (d) request_permission：先产出 EventPermissionRequest，fail-closed 应答 cancelled
// （{outcome:{outcome:"cancelled"}}），再产出 EventPermissionDecision(cancelled)，
// 绝不静默批准。
func TestPermissionRequestFailClosed(t *testing.T) {
	const sessionID = "sess-0001"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	drainOut(fb)

	// 注入桥的权限请求（带 id 100）。
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "id": 100,
		"method": "session/request_permission",
		"params": map[string]any{
			"sessionId": sessionID,
			"toolCall":  map[string]any{"toolCallId": "tool-7", "title": "bash echo"},
			"options": []any{
				map[string]any{"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
			},
		},
	})

	// 事件流先出现 permission_request。
	select {
	case ev := <-h.Events():
		if ev.Type != adapter.EventPermissionRequest {
			t.Fatalf("首个权限事件 = %q, want permission_request", ev.Type)
		}
		if ev.Payload["instance_id"] != sessionID {
			t.Fatalf("permission_request instance_id = %v", ev.Payload["instance_id"])
		}
		if ev.Payload["tool_call_id"] != "tool-7" {
			t.Fatalf("permission_request tool_call_id = %v", ev.Payload["tool_call_id"])
		}
	case <-time.After(5 * time.Second):
		t.Fatal("等待 permission_request 事件超时")
	}

	// 应答帧：id 回显 + outcome.cancelled（SDK 决策形状 {outcome:{outcome:"cancelled"}}）。
	deadline := time.After(5 * time.Second)
	for {
		select {
		case out := <-fb.outCh:
			if frameID(out) != 100 {
				continue
			}
			res, _ := out["result"].(map[string]any)
			outcome, _ := res["outcome"].(map[string]any)
			if outcome["outcome"] != "cancelled" {
				t.Fatalf("fail-closed 决策必须是 cancelled: %#v", res)
			}
		case <-time.After(10 * time.Millisecond):
			// 等读循环写入应答。
			continue
		case <-deadline:
			t.Fatal("未收到权限请求的 cancelled 应答")
		}
		// 应答帧已确认，跳出。
		break
	}

	// 决策事件：permission_decision(cancelled)。
	select {
	case ev := <-h.Events():
		if ev.Type != adapter.EventPermissionDecision {
			t.Fatalf("后续事件 = %q, want permission_decision", ev.Type)
		}
		if ev.Payload["outcome"] != "cancelled" {
			t.Fatalf("permission_decision outcome = %v", ev.Payload["outcome"])
		}
	case <-time.After(5 * time.Second):
		t.Fatal("等待 permission_decision 事件超时")
	}
}

// (e) EOF/坏帧容错：坏帧被丢弃计数且不崩读循环；白名单外变体丢弃计数；
// EOF 后事件通道关闭，桥死后 Send 报错，Dispose 幂等。
func TestEOFAndBadFrameTolerance(t *testing.T) {
	const sessionID = "sess-0001"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	hd := h.(*handle)

	// 坏帧先行注入：读循环必须继续存活并处理后续有效帧。
	fb.pushRaw([]byte("this is { not json\n(_*#"))
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update": map[string]any{
				"sessionUpdate": "agent_message_chunk",
				"content":       map[string]any{"type": "text", "text": "容错"},
			},
		},
	})
	select {
	case ev := <-h.Events():
		if ev.Type != adapter.EventMessageCompleted {
			t.Fatalf("坏帧后有效通知映射 = %q, want message_completed", ev.Type)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("坏帧后读循环未继续处理有效帧")
	}

	// 白名单外变体（tool_call）：丢弃并计数，不报错。
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t-1"},
		},
	})

	// 等待坏帧与未知变体计数落定。
	waitForCount := func(key string) {
		t.Helper()
		deadline := time.After(5 * time.Second)
		for {
			if hd.droppedCounts()[key] > 0 {
				return
			}
			select {
			case <-time.After(5 * time.Millisecond):
			case <-deadline:
				t.Fatalf("未观测到计数 key=%q", key)
			}
		}
	}
	waitForCount("bad_frame")
	waitForCount("update:tool_call")

	// EOF（模拟桥退出）：读循环结束，事件通道关闭。
	if err := fb.Close(); err != nil {
		t.Fatalf("fake Close: %v", err)
	}
	select {
	case _, ok := <-h.Events():
		if ok {
			t.Fatal("EOF 后事件通道应关闭")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("事件通道未在 EOF 后关闭")
	}
	// 桥死后 Send 必须报错而不是挂死。
	if err := h.Send(context.Background(), "x"); err == nil {
		t.Fatal("桥关闭后 Send 必须报错")
	}
	// Dispose 幂等：先 Close 后 Dispose、重复 Dispose 都不 panic。
	_ = h.Dispose(context.Background())
	_ = h.Dispose(context.Background())
}

// 补充：桥的 fs/* 请求按 -32601 fail-closed 应答（handle 的未声明客户端请求防御）。
func TestFsRequestRejectedWithMethodNotFound(t *testing.T) {
	const sessionID = "sess-0001"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	// 启动即注册了 Cleanup Dispose；fs 请求不产生事件，无需持有 handle 引用。
	startWithFake(t, fb)
	drainOut(fb)

	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "id": 200,
		"method": "fs/readTextFile",
		"params": map[string]any{"sessionId": sessionID, "path": "/etc/hosts"},
	})

	deadline := time.After(5 * time.Second)
	for {
		select {
		case out := <-fb.outCh:
			if frameID(out) != 200 {
				continue
			}
			rpcErr, _ := out["error"].(map[string]any)
			if code, _ := rpcErr["code"].(float64); int(code) != -32601 {
				t.Fatalf("fs/* 必须回 -32601，实际 %#v", out)
			}
			return
		case <-time.After(10 * time.Millisecond):
			continue
		case <-deadline:
			t.Fatal("未收到 fs/* 的 -32601 应答")
		}
	}
}
