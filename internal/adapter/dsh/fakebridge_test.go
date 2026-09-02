package dsh

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
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
// session/cancel 为通知，无应答。set_config_option 按桥语义回成功空对象。
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
		case "session/load", "session/resume":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{},
			})
		case "session/set_config_option":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{},
			})
		case "session/prompt":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{"stopReason": "end_turn"},
			})
		}
	}
}

// framesByMethod 返回某 method 的全部出站帧。
func framesByMethod(frames []map[string]any, method string) []map[string]any {
	var out []map[string]any
	for _, frame := range frames {
		if methodOf(frame) == method {
			out = append(out, frame)
		}
	}
	return out
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

func TestCapabilitiesMatchResumeAndModelTruth(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondByMethod(t, "unused")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	byName := make(map[string]adapter.Capability, len(caps.Capabilities))
	for _, capability := range caps.Capabilities {
		byName[capability.Name] = capability
	}
	if byName["resume"].Status != adapter.CapabilityNative || byName["resume"].Reason != "" {
		t.Fatalf("resume 能力不真实: %+v", byName["resume"])
	}
	// model_select 已接入 session/set_config_option：native 且必须携带完整目录。
	modelSelect := byName["model_select"]
	if modelSelect.Status != adapter.CapabilityNative || modelSelect.Reason != "" {
		t.Fatalf("model_select 能力不真实: %+v", modelSelect)
	}
	if len(modelSelect.Options) != len(dshKnownModels) {
		t.Fatalf("model_select Options 数量 = %d, want %d", len(modelSelect.Options), len(dshKnownModels))
	}
	seen := map[string]bool{}
	for _, model := range modelSelect.Options {
		seen[model] = true
	}
	for _, model := range dshKnownModels {
		if !seen[model] {
			t.Fatalf("model_select Options 缺少 %q: %v", model, modelSelect.Options)
		}
	}
	// spi.go 不变量：Default 必须存在于 Options，客户端不得自行猜测默认模型。
	if modelSelect.Default == "" || !seen[modelSelect.Default] {
		t.Fatalf("model_select Default %q 必须存在于 Options %v", modelSelect.Default, modelSelect.Options)
	}
}

// 修改返回的 Options 切片不得污染后续矩阵（successMatrix 每次拷贝目录）。
func TestModelSelectOptionsAreCopiedPerMatrix(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondByMethod(t, "unused")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	first, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	for _, capability := range first.Capabilities {
		if capability.Name == "model_select" {
			if len(capability.Options) == 0 {
				t.Fatal("model_select 未暴露 Options")
			}
			capability.Options[0] = "mutated"
		}
	}
	for _, capability := range a.Capabilities().Capabilities {
		if capability.Name == "model_select" && capability.Options[0] != dshKnownModels[0] {
			t.Fatalf("Options 被外部修改污染: %v", capability.Options)
		}
	}
}

// 生产适配器必须把符号链接工作区规约为 realpath，再同时用于 transport、
// session/new 和后续 resume；否则 DSH 会按不同 project key 写入并拒绝恢复。
func TestProductionAdapterCanonicalizesWorkspaceCWD(t *testing.T) {
	realRoot := t.TempDir()
	aliasParent := t.TempDir()
	alias := filepath.Join(aliasParent, "workspace-link")
	if err := os.Symlink(realRoot, alias); err != nil {
		t.Skipf("当前文件系统不支持符号链接: %v", err)
	}
	fb := newFakeBridge()
	fb.script = respondByMethod(t, "canonical-session")
	var transportRoot string
	a := &Adapter{
		production: true,
		factory:    func() (BridgeTransport, error) { return fb, nil },
		workspaceFactory: func(root string) (BridgeTransport, error) {
			transportRoot = root
			return fb, nil
		},
	}
	// 禁止测试意外读取真实 checkout 的 legacy 根。
	t.Setenv(EnvBin, filepath.Join(t.TempDir(), "bin.js"))
	t.Setenv(EnvPersistCompression, PersistenceCompressionNone)
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: alias})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	want, err := canonicalWorkspacePath(alias)
	if err != nil {
		t.Fatal(err)
	}
	if transportRoot != want {
		t.Fatalf("transport workspace root = %q, want %q", transportRoot, want)
	}
	var newFrame map[string]any
	for _, frame := range fb.written() {
		if methodOf(frame) == "session/new" {
			newFrame = frame
			break
		}
	}
	if newFrame == nil {
		t.Fatal("未发送 session/new")
	}
	params, _ := newFrame["params"].(map[string]any)
	if params["cwd"] != want {
		t.Fatalf("session/new cwd = %v, want %q", params["cwd"], want)
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

	// session/prompt 应答（stopReason=end_turn）后必须补发回合终止标记，
	// 否则客户端无法区分“模型仍在生成”与“本轮已结束”。
	select {
	case ev := <-h.Events():
		if ev.Type != adapter.EventTurnCompleted {
			t.Fatalf("事件类型 = %q, want turn_completed", ev.Type)
		}
		if ev.Payload["stop_reason"] != "end_turn" {
			t.Fatalf("stop_reason = %v", ev.Payload["stop_reason"])
		}
	case <-time.After(5 * time.Second):
		t.Fatal("等待 turn_completed 事件超时")
	}
}

// P1 Resume 时序：ready 回调返回前不得发出 load；回调接管事件流后可完整收到回放。
func TestResumeStreamingSubscribesBeforeLoad(t *testing.T) {
	const sessionID = "sess-resume"
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "session/load" {
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "method": "session/update",
				"params": map[string]any{
					"sessionId": sessionID,
					"update":    map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "旧问题"}},
				},
			})
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "method": "session/update",
				"params": map[string]any{
					"sessionId": sessionID,
					"update":    map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "旧回答"}},
				},
			})
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": frameID(msg), "result": map[string]any{}})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	readyCalled := false
	var resumed adapter.Handle
	result, err := a.ResumeStreaming(context.Background(), adapter.ResumeRequest{
		InstanceID: sessionID, WorkspaceRoot: "/tmp/dsh-ws", ReplayHistory: true,
	}, func(h adapter.Handle) error {
		readyCalled = true
		resumed = h
		for _, frame := range fb.written() {
			if methodOf(frame) == "session/load" {
				t.Fatalf("ready 回调返回前不得发送 session/load")
			}
		}
		return nil
	})
	if err != nil || result.Result != adapter.WakeResumed || !readyCalled {
		t.Fatalf("ResumeStreaming = %+v, %v, ready=%v", result, err, readyCalled)
	}
	t.Cleanup(func() { _ = resumed.Dispose(context.Background()) })
	var got []adapter.EventType
	for len(got) < 2 {
		select {
		case ev := <-resumed.Events():
			got = append(got, ev.Type)
		case <-time.After(2 * time.Second):
			t.Fatalf("等待回放事件超时，got=%v", got)
		}
	}
	if got[0] != adapter.EventUserMessage || got[1] != adapter.EventMessageCompleted {
		t.Fatalf("回放事件顺序 = %v", got)
	}
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "新回答"}},
		},
	})
	select {
	case event := <-resumed.Events():
		if event.ReplayOrdinal != 0 || event.Payload["text"] != "新回答" {
			t.Fatalf("回放完成后的实时事件被错误标记: %+v", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("等待回放完成后的实时事件超时")
	}
}

// 回放背压期间桥退出时，事件推送必须被停止信号唤醒，不能向已关闭通道写入或遗留协程。
func TestReplayEventPushStopsBeforeChannelClose(t *testing.T) {
	fb := newFakeBridge()
	h := newHandle(fb)
	go h.readLoop()
	h.setReplayMode(true)
	done := make(chan struct{})
	go func() {
		for i := 0; i < cap(h.events)+32; i++ {
			h.pushEvent(adapter.Event{Type: adapter.EventUserMessage, Payload: map[string]any{"text": "历史"}})
		}
		close(done)
	}()
	// 给推送协程一个机会填满回放缓冲，再触发桥退出。
	time.Sleep(10 * time.Millisecond)
	_ = h.Dispose(context.Background())
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("桥退出后回放推送协程未收敛")
	}
}

// (b2) prompt 失败也必须收敛回合：先 session_error 提示，再 turn_completed 终止，
// 否则客户端在 upstream 故障时永远停留在“生成中”。
func TestSendPromptFailureEmitsTerminalEvents(t *testing.T) {
	const sessionID = "sess-0001"
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "session/prompt" {
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"error": map[string]any{"code": -32603, "message": "Internal error: quota"},
			})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	h := startWithFake(t, fb)

	if err := h.Send(context.Background(), "会失败的消息"); err == nil {
		t.Fatal("prompt 失败必须返回错误")
	}

	first := <-h.Events()
	if first.Type != adapter.EventSessionError {
		t.Fatalf("第一个事件 = %q, want session_error", first.Type)
	}
	second := <-h.Events()
	if second.Type != adapter.EventTurnCompleted {
		t.Fatalf("第二个事件 = %q, want turn_completed", second.Type)
	}
	if second.Payload["stop_reason"] != "error" {
		t.Fatalf("stop_reason = %v, want error", second.Payload["stop_reason"])
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

	// v0.8.2 起 tool_call 是白名单内变体（映射为 EventToolCall，见 mapper 契约测试）。
	// 白名单外变体（plan）仍丢弃并计数，不报错。
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "plan", "title": "p-1"},
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
	waitForCount("update:plan")

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

// (f) 模型覆盖：SetModel 后 Send 必须先下发 session/set_config_option(configId=model)
// 再发 prompt；同一模型不重复下发，变更后恰好再下发一次。
func TestSendAppliesModelViaSetConfigOptionBeforePrompt(t *testing.T) {
	const sessionID = "sess-model"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	setter, ok := h.(adapter.ModelOverrideHandle)
	if !ok {
		t.Fatal("DSH handle 必须实现 ModelOverrideHandle")
	}

	setter.SetModel("mimo-v2.5-free")
	if err := h.Send(context.Background(), "第一轮"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	written := fb.written()
	switches := framesByMethod(written, "session/set_config_option")
	if len(switches) != 1 {
		t.Fatalf("预期恰好 1 帧 set_config_option，实际 %d", len(switches))
	}
	p, _ := switches[0]["params"].(map[string]any)
	if p["sessionId"] != sessionID || p["configId"] != "model" || p["value"] != "mimo-v2.5-free" {
		t.Fatalf("set_config_option 形状不符: %#v", p)
	}
	// 时序：set_config_option 必须先于本轮 prompt。
	switchIndex, promptIndex := -1, -1
	for i, frame := range written {
		switch methodOf(frame) {
		case "session/set_config_option":
			switchIndex = i
		case "session/prompt":
			if promptIndex < 0 {
				promptIndex = i
			}
		}
	}
	if switchIndex == -1 || promptIndex == -1 || switchIndex > promptIndex {
		t.Fatalf("set_config_option(idx=%d) 必须先于首个 prompt(idx=%d)", switchIndex, promptIndex)
	}

	// 同一模型再次 Send：不重复下发。
	if err := h.Send(context.Background(), "第二轮"); err != nil {
		t.Fatalf("第二次 Send: %v", err)
	}
	if got := len(framesByMethod(fb.written(), "session/set_config_option")); got != 1 {
		t.Fatalf("同一模型不得重复下发 set_config_option，实际 %d 帧", got)
	}

	// 变更模型：恰好再下发一次新值。
	setter.SetModel("gpt-5.5")
	if err := h.Send(context.Background(), "第三轮"); err != nil {
		t.Fatalf("第三次 Send: %v", err)
	}
	switches = framesByMethod(fb.written(), "session/set_config_option")
	if len(switches) != 2 {
		t.Fatalf("变更后预期共 2 帧 set_config_option，实际 %d", len(switches))
	}
	if p, _ := switches[1]["params"].(map[string]any); p["value"] != "gpt-5.5" {
		t.Fatalf("第二次下发 value = %v, want gpt-5.5", p["value"])
	}
}

// (f2) Start 时声明的模型（StartRequest.Model）同样在首个 Send 前下发。
func TestStartRegistersRequestedModel(t *testing.T) {
	const sessionID = "sess-start-model"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: "/tmp/dsh-ws",
		Model:         "nemotron-3-ultra-free",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	if _, ok := h.(adapter.ModelOverrideHandle); !ok {
		t.Fatal("DSH handle 必须实现 ModelOverrideHandle")
	}
	if err := h.Send(context.Background(), "首轮"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	switches := framesByMethod(fb.written(), "session/set_config_option")
	if len(switches) != 1 {
		t.Fatalf("预期恰好 1 帧 set_config_option，实际 %d", len(switches))
	}
	if p, _ := switches[0]["params"].(map[string]any); p["value"] != "nemotron-3-ultra-free" {
		t.Fatalf("Start 模型未生效: %#v", p)
	}
}

// (f3) SetModel 空值/纯空白忽略：不产生 set_config_option，prompt 直接发送。
func TestSetModelEmptyIgnored(t *testing.T) {
	const sessionID = "sess-empty-model"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	setter := h.(adapter.ModelOverrideHandle)
	setter.SetModel("")
	setter.SetModel("   ")
	if err := h.Send(context.Background(), "无模型覆盖"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if got := framesByMethod(fb.written(), "session/set_config_option"); len(got) != 0 {
		t.Fatalf("空模型覆盖不得下发 set_config_option: %d 帧", len(got))
	}
}

// (f4) 桥拒绝模型（未知模型/目录外）时整轮 fail-closed：不发送 prompt，
// 补发 session_error + turn_completed 终止事件；恢复合法模型后可重试成功。
func TestSetModelFailureFailsClosed(t *testing.T) {
	const sessionID = "sess-model-fail"
	fb := newFakeBridge()
	reject := true
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "session/set_config_option" {
			if reject {
				fb.push(t, map[string]any{
					"jsonrpc": "2.0", "id": frameID(msg),
					"error": map[string]any{"code": -32602, "message": "no provider route for model: unknown-model"},
				})
				return
			}
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": frameID(msg), "result": map[string]any{}})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	h := startWithFake(t, fb)
	setter := h.(adapter.ModelOverrideHandle)
	setter.SetModel("unknown-model")

	if err := h.Send(context.Background(), "应当被拒绝"); err == nil {
		t.Fatal("set_config_option 失败时 Send 必须返回错误")
	}
	if got := framesByMethod(fb.written(), "session/prompt"); len(got) != 0 {
		t.Fatal("模型切换失败后绝不能发送 prompt（fail-closed）")
	}
	first := <-h.Events()
	if first.Type != adapter.EventSessionError {
		t.Fatalf("第一个事件 = %q, want session_error", first.Type)
	}
	second := <-h.Events()
	if second.Type != adapter.EventTurnCompleted {
		t.Fatalf("第二个事件 = %q, want turn_completed", second.Type)
	}
	if second.Payload["stop_reason"] != "error" {
		t.Fatalf("stop_reason = %v, want error", second.Payload["stop_reason"])
	}

	// 期望模型保留：桥恢复后下一次 Send 重试下发并成功放行 prompt。
	reject = false
	if err := h.Send(context.Background(), "重试"); err != nil {
		t.Fatalf("恢复后 Send: %v", err)
	}
	switches := framesByMethod(fb.written(), "session/set_config_option")
	if len(switches) != 2 {
		t.Fatalf("失败一次 + 重试一次应共 2 帧，实际 %d", len(switches))
	}
	if p, _ := switches[1]["params"].(map[string]any); p["value"] != "unknown-model" {
		t.Fatalf("重试必须沿用期望模型: %#v", p)
	}
	prompts := framesByMethod(fb.written(), "session/prompt")
	if len(prompts) != 1 {
		t.Fatalf("恢复后 prompt 应发送一次，实际 %d", len(prompts))
	}
}

// v0.8.2 P1：SetEffort 经 session/set_config_option(configId=thought_level) 下发，
// 顺序为 model → effort → prompt；同一档位去重、变更再下发、空值忽略。
func TestSendAppliesEffortViaThoughtLevelBeforePrompt(t *testing.T) {
	const sessionID = "sess-effort"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	setter, ok := h.(adapter.EffortOverrideHandle)
	if !ok {
		t.Fatal("DSH handle 必须实现 EffortOverrideHandle")
	}
	setter.SetEffort("max")
	if err := h.Send(context.Background(), "第一轮"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	written := fb.written()
	switches := framesByMethod(written, "session/set_config_option")
	if len(switches) != 1 {
		t.Fatalf("预期恰好 1 帧 set_config_option，实际 %d", len(switches))
	}
	p, _ := switches[0]["params"].(map[string]any)
	if p["sessionId"] != sessionID || p["configId"] != "thought_level" || p["value"] != "max" {
		t.Fatalf("set_config_option 形状不符: %#v", p)
	}
	// 时序：thought_level 必须先于 prompt。
	switchIndex, promptIndex := -1, -1
	for i, frame := range written {
		switch methodOf(frame) {
		case "session/set_config_option":
			if switchIndex < 0 {
				switchIndex = i
			}
		case "session/prompt":
			if promptIndex < 0 {
				promptIndex = i
			}
		}
	}
	if switchIndex == -1 || promptIndex == -1 || switchIndex > promptIndex {
		t.Fatalf("set_config_option(idx=%d) 必须先于 prompt(idx=%d)", switchIndex, promptIndex)
	}
	// 同一档位再次 Send：不重复下发。
	if err := h.Send(context.Background(), "第二轮"); err != nil {
		t.Fatalf("第二次 Send: %v", err)
	}
	if got := len(framesByMethod(fb.written(), "session/set_config_option")); got != 1 {
		t.Fatalf("同一档位不得重复下发，实际 %d 帧", got)
	}
	// 变更档位：恰好再下发一次新值。
	setter.SetEffort("medium")
	if err := h.Send(context.Background(), "第三轮"); err != nil {
		t.Fatalf("第三次 Send: %v", err)
	}
	switches = framesByMethod(fb.written(), "session/set_config_option")
	if len(switches) != 2 {
		t.Fatalf("变更后预期共 2 帧 set_config_option，实际 %d", len(switches))
	}
	if p, _ := switches[1]["params"].(map[string]any); p["value"] != "medium" {
		t.Fatalf("第二次下发 value = %v, want medium", p["value"])
	}
}

// SetEffort 空值/纯空白忽略：不产生 set_config_option，prompt 直接发送。
func TestSetEffortEmptyIgnored(t *testing.T) {
	const sessionID = "sess-empty-effort"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	setter := h.(adapter.EffortOverrideHandle)
	setter.SetEffort("   ")
	if err := h.Send(context.Background(), "首轮"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if got := len(framesByMethod(fb.written(), "session/set_config_option")); got != 0 {
		t.Fatalf("空 effort 不得下发 set_config_option，实际 %d 帧", got)
	}
	if got := len(framesByMethod(fb.written(), "session/prompt")); got != 1 {
		t.Fatalf("空 effort 时 prompt 应照常发送，实际 %d 帧", got)
	}
}

// 桥拒绝不支持的档位（invalidParams）时整轮 fail-closed：不发 prompt，
// 先广播 session_error 再补 turn_completed(error)；客户端保留原档位可重试。
func TestSetEffortFailureFailsClosed(t *testing.T) {
	const sessionID = "sess-bad-effort"
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
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
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"sessionId": sessionID}})
		case "session/set_config_option":
			// 桥拒绝不支持的档位：invalidParams（-32602）。
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"error": map[string]any{"code": -32602, "message": "unsupported reasoning effort"},
			})
		}
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	setter := h.(adapter.EffortOverrideHandle)
	setter.SetEffort("ultra")
	if err := h.Send(context.Background(), "首轮"); err == nil {
		t.Fatal("桥拒绝档位时 Send 必须失败（fail-closed）")
	}
	if got := len(framesByMethod(fb.written(), "session/prompt")); got != 0 {
		t.Fatalf("档位被拒后不得发送 prompt，实际 %d 帧", got)
	}
	// 事件流补终态：session_error → turn_completed(error)，客户端不悬挂。
	var types []adapter.EventType
	deadline := time.After(5 * time.Second)
	for len(types) < 2 {
		select {
		case ev := <-h.Events():
			types = append(types, ev.Type)
		case <-deadline:
			t.Fatalf("等待终态事件超时，got=%v", types)
		}
	}
	if types[0] != adapter.EventSessionError || types[1] != adapter.EventTurnCompleted {
		t.Fatalf("终态事件顺序 = %v, want [session_error turn_completed]", types)
	}
}
