package dsh

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 本文件是 v0.8.3 P3 的 Go 适配器扩展面回归（ADR-014 §3-§8）：
// mode 目录/切换、session lifecycle、question 一次性回答、dsh/* 统一分发与
// SendContent 混合内容。全部基于内存假桥（P0 场景引擎），不依赖真实桥或模型。

// respondWithModes 是 P3 场景脚本：new/load/resume 响应携带 mode 目录，
// set_mode 校验目录并回 modes + current_mode_update 通知。
func respondWithModes(t *testing.T, sessionID string, catalog []map[string]any, rejectMode string) func(*fakeBridge, map[string]any) {
	t.Helper()
	base := respondByMethod(t, sessionID)
	return func(fb *fakeBridge, msg map[string]any) {
		switch methodOf(msg) {
		case "session/new", "session/load", "session/resume":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{
					"sessionId": sessionID,
					"modes": map[string]any{
						"currentModeId":  catalog[0]["id"],
						"availableModes": catalog,
					},
				},
			})
		case "session/set_mode":
			modeID, _ := msg["params"].(map[string]any)["modeId"].(string)
			known := false
			for _, m := range catalog {
				if m["id"] == modeID {
					known = true
				}
			}
			if !known || modeID == rejectMode {
				fb.push(t, map[string]any{
					"jsonrpc": "2.0", "id": frameID(msg),
					"error": map[string]any{"code": -32602, "message": "unknown session mode"},
				})
				return
			}
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{
					"modes": map[string]any{
						"currentModeId":  modeID,
						"availableModes": catalog,
					},
				},
			})
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "method": "session/update",
				"params": map[string]any{
					"sessionId": sessionID,
					"update":    map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": modeID},
				},
			})
		default:
			base(fb, msg)
		}
	}
}

func modeCatalog() []map[string]any {
	return []map[string]any{
		{"id": "workspace-write", "name": "Workspace write", "description": "工作区内写入"},
		{"id": "danger-full-access", "name": "Danger full access", "description": "完全访问"},
	}
}

// (V083-01) new 捕获 mode 目录；set_mode 原子切换并刷新快照；目录外 mode fail-closed。
func TestSetModeCatalogAndSwitch(t *testing.T) {
	const sessionID = "sess-p3-mode"
	fb := newFakeBridge()
	fb.script = respondWithModes(t, sessionID, modeCatalog(), "")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })

	modeHandle, ok := h.(adapter.SessionModeHandle)
	if !ok {
		t.Fatalf("handle 未实现 SessionModeHandle")
	}
	info := modeHandle.Modes()
	if info.CurrentModeID != "workspace-write" || len(info.AvailableModes) != 2 {
		t.Fatalf("new 应捕获 mode 目录，得到 %+v", info)
	}
	if err := modeHandle.SetMode(context.Background(), "danger-full-access"); err != nil {
		t.Fatalf("SetMode: %v", err)
	}
	// set_mode 响应先到；current_mode_update 通知随后刷新（同一值）。
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if modeHandle.Modes().CurrentModeID == "danger-full-access" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if got := modeHandle.Modes().CurrentModeID; got != "danger-full-access" {
		t.Fatalf("切换后快照 = %q, want danger-full-access", got)
	}
	// 目录外 mode：桥拒绝，错误原样返回（fail-closed），快照不变。
	if err := modeHandle.SetMode(context.Background(), "custom"); err == nil {
		t.Fatalf("目录外 mode 应被拒绝")
	}
	if got := modeHandle.Modes().CurrentModeID; got != "danger-full-access" {
		t.Fatalf("被拒切换不得改动快照，得到 %q", got)
	}
}

// (V083-04/05) lifecycle 三方法：close 幂等（桥退出后视为已关闭）、delete 透传桥判定、
// fork 返回新 sessionId 并写对帧。
func TestLifecycleCloseDeleteFork(t *testing.T) {
	const sessionID = "sess-p3-lifecycle"
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		switch methodOf(msg) {
		case "session/close", "session/delete":
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": frameID(msg), "result": map[string]any{}})
		case "session/fork":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{"sessionId": "sess-forked"},
			})
		default:
			respondByMethod(t, sessionID)(fb, msg)
		}
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	lc, ok := h.(adapter.SessionLifecycleHandle)
	if !ok {
		t.Fatalf("handle 未实现 SessionLifecycleHandle")
	}
	if err := lc.CloseSession(context.Background()); err != nil {
		t.Fatalf("CloseSession: %v", err)
	}
	if _, err := lc.ForkSession(context.Background(), ""); err == nil {
		t.Fatalf("fork 缺 cwd 应拒绝")
	}
	forked, err := lc.ForkSession(context.Background(), "/tmp/dsh-ws")
	if err != nil || forked != "sess-forked" {
		t.Fatalf("ForkSession = %q, %v", forked, err)
	}
	if err := lc.DeleteSession(context.Background()); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	// 桥退出后 close 幂等成功（无需再请求）。读循环感知 EOF 存在时序，轮询收敛。
	_ = fb.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if err := lc.CloseSession(context.Background()); err == nil {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("桥退出后 CloseSession 应幂等成功: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// (V083-10/11) question one-shot：请求登记并广播 EventUserQuestion；
// ResolveQuestion 一次性回写桥原始 id（{answers:[...]} 形状）；重复/未知 fail-closed；
// 缺 requestId 的畸形请求错误应答并计数；Dispose 收口未决请求。
func TestQuestionOneShotLifecycle(t *testing.T) {
	const sessionID = "sess-p3-question"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	qh, ok := h.(adapter.QuestionAnswerHandle)
	if !ok {
		t.Fatalf("handle 未实现 QuestionAnswerHandle")
	}

	drainOut(fb)
	// 桥发起 question 请求（缺 requestId → 错误应答，不登记）。
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "id": int64(501), "method": "dsh/question/request",
		"params": map[string]any{"protocolVersion": 1, "sessionId": sessionID, "items": []any{}},
	})
	hh := h.(*handle)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if hh.droppedCounts()["question_bad_request"] >= 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if got := hh.droppedCounts()["question_bad_request"]; got < 1 {
		t.Fatalf("畸形 question 请求应计数，dropped=%v", hh.droppedCounts())
	}

	// 正常请求：登记 + 广播。
	drainOut(fb)
	items := []any{map[string]any{
		"id": "q1", "title": "选择方案", "type": "single-select",
		"options": []any{"方案 A", "方案 B"},
	}}
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "id": int64(502), "method": "dsh/question/request",
		"params": map[string]any{"protocolVersion": 1, "sessionId": sessionID, "requestId": "q-1", "items": items},
	})
	var question adapter.Event
	select {
	case question = <-h.Events():
	case <-time.After(2 * time.Second):
		t.Fatalf("等待 question 广播超时")
	}
	if question.Type != adapter.EventUserQuestion {
		t.Fatalf("事件类型 = %v", question.Type)
	}
	if question.Payload["request_id"] != "q-1" {
		t.Fatalf("载荷应携带关联键: %+v", question.Payload)
	}

	// 一次性回答：写回桥原始 id 502。
	if err := qh.ResolveQuestion("q-1", []adapter.QuestionAnswerItem{
		{ID: "q1", Selected: []string{"方案 A"}},
	}); err != nil {
		t.Fatalf("ResolveQuestion: %v", err)
	}
	var answerFrame map[string]any
	for _, frame := range fb.written() {
		if frameID(frame) == 502 && frame["result"] != nil {
			answerFrame = frame
		}
	}
	if answerFrame == nil {
		t.Fatalf("应答回写帧缺失: %v", fb.written())
	}
	result, _ := answerFrame["result"].(map[string]any)
	answers, _ := result["answers"].([]any)
	if len(answers) != 1 {
		t.Fatalf("应答形状不正确: %v", result)
	}
	first, _ := answers[0].(map[string]any)
	if first["id"] != "q1" {
		t.Fatalf("应答 id 不正确: %v", first)
	}
	// 重复回答 fail-closed。
	if err := qh.ResolveQuestion("q-1", nil); err == nil {
		t.Fatalf("重复回答应被拒绝")
	}
	// 未知 requestKey fail-closed。
	if err := qh.ResolveQuestion("q-unknown", nil); err == nil {
		t.Fatalf("未知 requestKey 应被拒绝")
	}
}

// (V083-11) Dispose 收口：未决 question 请求收到 dsh_extension_cancelled 错误应答。
func TestQuestionCancelledOnDispose(t *testing.T) {
	const sessionID = "sess-p3-question-dispose"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	drainOut(fb)
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "id": int64(601), "method": "dsh/question/request",
		"params": map[string]any{"protocolVersion": 1, "sessionId": sessionID, "requestId": "q-2", "items": []any{}},
	})
	time.Sleep(200 * time.Millisecond)
	_ = h.Dispose(context.Background())
	var errFrame map[string]any
	for _, frame := range fb.written() {
		if frameID(frame) == 601 && frame["error"] != nil {
			errFrame = frame
		}
	}
	if errFrame == nil {
		t.Fatalf("Dispose 应给未决 question 错误应答: %v", fb.written())
	}
	errObj, _ := errFrame["error"].(map[string]any)
	if !strings.Contains(errObj["message"].(string), "dsh_extension_cancelled") {
		t.Fatalf("收口应答应携带稳定错误码: %v", errObj)
	}
}

// (V083-15/18) CallExtension：envelope 注入（protocolVersion/sessionId）、
// 命名空间与冻结调用面校验、响应解码。
func TestCallExtensionDispatch(t *testing.T) {
	const sessionID = "sess-p3-ext"
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "dsh/goal/get" {
			params, _ := msg["params"].(map[string]any)
			// 脚本回调收到的是原始帧（int 未归一化）；协议版本兼容 int/float64 两种形态。
			version, _ := params["protocolVersion"].(int)
			if version != DshExtensionProtocolVersion || params["sessionId"] != sessionID {
				fb.push(t, map[string]any{
					"jsonrpc": "2.0", "id": frameID(msg),
					"error": map[string]any{"code": -32602, "message": "envelope 不完整"},
				})
				return
			}
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{"goal": map[string]any{"id": "g1", "revision": 3}},
			})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	ext, ok := h.(adapter.ExtensionDispatchHandle)
	if !ok {
		t.Fatalf("handle 未实现 ExtensionDispatchHandle")
	}
	result, err := ext.CallExtension(context.Background(), MethodDshGoalGet, nil)
	if err != nil {
		t.Fatalf("CallExtension: %v", err)
	}
	goal, _ := result["goal"].(map[string]any)
	if goal == nil || goal["id"] != "g1" {
		t.Fatalf("goal 响应解码不正确: %v", result)
	}
	// 非 dsh/ 命名空间拒绝。
	if _, err := ext.CallExtension(context.Background(), "other/verb", nil); err == nil {
		t.Fatalf("命名空间外方法应拒绝")
	}
	// 未冻结方法拒绝（通知不是调用面）。
	if _, err := ext.CallExtension(context.Background(), NotifyDshGoalChanged, nil); err == nil {
		t.Fatalf("通知不是合法调用面，应拒绝")
	}
}

// (V083-03) SendContent：图像块转 base64+mimeType 进 ACP image 块，复用既有
// prompt 槽位（model/effort 前置下发不变）；畸形块 fail-closed。
func TestSendContentImageBlocks(t *testing.T) {
	const sessionID = "sess-p3-image"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	ch, ok := h.(interface {
		SendContent(ctx context.Context, blocks []adapter.ContentBlock) error
	})
	if !ok {
		t.Fatalf("handle 未实现 SendContent")
	}
	png := []byte{0x89, 0x50, 0x4E, 0x47}
	if err := ch.SendContent(context.Background(), []adapter.ContentBlock{
		{Type: "text", Text: "看这张图"},
		{Type: "image", ImageData: png, ImageMIME: "image/png"},
	}); err != nil {
		t.Fatalf("SendContent: %v", err)
	}
	var promptParams map[string]any
	for _, frame := range fb.written() {
		if methodOf(frame) == "session/prompt" {
			promptParams, _ = frame["params"].(map[string]any)
		}
	}
	if promptParams == nil {
		t.Fatalf("session/prompt 帧缺失")
	}
	blocks, _ := promptParams["prompt"].([]any)
	if len(blocks) != 2 {
		t.Fatalf("prompt 应包含 2 个块: %v", promptParams)
	}
	img, _ := blocks[1].(map[string]any)
	if img["type"] != "image" || img["mimeType"] != "image/png" {
		t.Fatalf("图像块形状不正确: %v", img)
	}
	if img["data"] != base64.StdEncoding.EncodeToString(png) {
		t.Fatalf("图像数据应按标准 base64 编码")
	}
	// 畸形块：缺 MIME / 未知类型 / 空批次 fail-closed（无 prompt 发出）。
	before := len(framesByMethod(fb.written(), "session/prompt"))
	if err := ch.SendContent(context.Background(), []adapter.ContentBlock{
		{Type: "image", ImageData: png},
	}); err == nil {
		t.Fatalf("缺 MIME 的图像块应拒绝")
	}
	if err := ch.SendContent(context.Background(), []adapter.ContentBlock{
		{Type: "audio"},
	}); err == nil {
		t.Fatalf("未知块类型应拒绝")
	}
	if err := ch.SendContent(context.Background(), nil); err == nil {
		t.Fatalf("空批次应拒绝")
	}
	if after := len(framesByMethod(fb.written(), "session/prompt")); after != before {
		t.Fatalf("畸形块不得发出 prompt: before=%d after=%d", before, after)
	}
}

// (V083-04) Adapter.ListSessions：短生命周期探测桥 + 脱敏分页解码；
// 无 cwd 的行跳过而非伪造。
func TestAdapterListSessions(t *testing.T) {
	const sessionID = "sess-p3-list"
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "session/list" {
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{
					"sessions": []any{
						map[string]any{"sessionId": sessionID, "cwd": "/tmp/ws-a", "updatedAt": "2026-09-03T00:00:00Z"},
						map[string]any{"sessionId": "sess-orphan"},
					},
					"nextCursor": "MQ",
				},
			})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	// *Adapter 直接实现 SessionListProvider（P3 起 ListSessions 挂在 Adapter 层）。
	var _ adapter.SessionListProvider = a
	result, err := a.ListSessions(context.Background(), "", "")
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(result.Sessions) != 1 {
		t.Fatalf("无 cwd 行应被跳过: %+v", result)
	}
	if result.Sessions[0].SessionID != sessionID || result.Sessions[0].CWD != "/tmp/ws-a" {
		t.Fatalf("脱敏行不正确: %+v", result.Sessions)
	}
	if result.NextCursor != "MQ" {
		t.Fatalf("游标应原样回传: %q", result.NextCursor)
	}
	// cwd 过滤参数透传。每次 ListSessions 独立 spawn 探测桥并在完成后回收，
	// 因此第二次调用需要新桥：工厂按调用序返回未关闭的实例。
	second := newFakeBridge()
	second.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "session/list" {
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": frameID(msg), "result": map[string]any{"sessions": []any{}}})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	a2 := NewWithTransport(func() (BridgeTransport, error) { return second, nil })
	if _, err := a2.ListSessions(context.Background(), "/tmp/ws-b", "MQ"); err != nil {
		t.Fatalf("ListSessions(cwd,cursor): %v", err)
	}
	var listParams map[string]any
	for _, frame := range second.written() {
		if methodOf(frame) == "session/list" {
			listParams, _ = frame["params"].(map[string]any)
		}
	}
	if listParams["cwd"] != "/tmp/ws-b" || listParams["cursor"] != "MQ" {
		t.Fatalf("list 参数透传不正确: %v", listParams)
	}
}

// (V083-22) 能力矩阵真实性（P5 收口口径）：deterministic overlay（15/15）通过后，
// permission_mode/fork 升为 native；question/plan/goal/skill 以 dsh/* extension
// 承载最高 emulated；attachments 的 Relay opaque ref 未接通保持 unsupported。
// 防止「观察冒充能力」与「未过 gate 冒充 native」两个方向。
func TestP5MatrixUpgradedAfterDeterministicGate(t *testing.T) {
	caps := successMatrix("test")
	byName := map[string]adapter.Capability{}
	for _, c := range caps.Capabilities {
		byName[c.Name] = c
	}
	for _, name := range []string{"permission_mode", "fork"} {
		if c := byName[name]; c.Status != adapter.CapabilityNative {
			t.Fatalf("P5 gate 通过后 %s 应为 native，得到 %s", name, c.Status)
		}
	}
	for _, name := range []string{"question", "plan", "goal", "skill_catalog", "invoke_skill"} {
		c := byName[name]
		if c.Status != adapter.CapabilityEmulated {
			t.Fatalf("%s 以 dsh/* extension 承载应为 emulated，得到 %s", name, c.Status)
		}
		if c.Reason == "" {
			t.Fatalf("%s 的 emulated 必须带残余风险 reason", name)
		}
	}
	if c := byName["attachments"]; c.Status != adapter.CapabilityUnsupported {
		t.Fatalf("attachments 在 opaque ref 接入前保持 unsupported，得到 %s", c.Status)
	}
	// 观察不提升：delegation 两项在任何 gate 下保持 unsupported。
	for _, name := range []string{"delegate_session", "delegate_cross_provider"} {
		if c := byName[name]; c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s 不得因 subagent 投影升格", name)
		}
	}
}

// V085-12：new/load/resume 响应 _meta 回带 agent preset（v0.8.5 §3.8）。
// 桥只在会话 joined 预设时携带 com.deepseek.dsh/agent-preset 键；handle 解析并
// 暴露 AgentPreset()，供 runner 上行到 Relay 作只读投影。无键/空值清空快照。
func TestAgentPresetFromSessionStateMeta(t *testing.T) {
	const sessionID = "sess-v085-preset"
	fb := newFakeBridge()
	base := respondByMethod(t, sessionID)
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "session/new" {
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{
					"sessionId": sessionID,
					"modes": map[string]any{
						"currentModeId":  "default",
						"availableModes": []map[string]any{{"id": "default", "name": "默认"}},
					},
					"_meta": map[string]any{
						"com.deepseek.dsh/agent-preset": "standard",
					},
				},
			})
			return
		}
		base(fb, msg)
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })

	presetHandle, ok := h.(interface{ AgentPreset() string })
	if !ok {
		t.Fatalf("handle 未实现 AgentPreset()")
	}
	if got := presetHandle.AgentPreset(); got != "standard" {
		t.Fatalf("AgentPreset() = %q, want standard", got)
	}

	// 无键响应清空快照（最近一次会话状态为事实）：直接以同包私有方法验证。
	inner, ok := h.(*handle)
	if !ok {
		t.Fatalf("handle 类型断言失败")
	}
	inner.storeAgentPreset(json.RawMessage(`{"com.deepseek.dsh/model-catalog":{}}`))
	if got := presetHandle.AgentPreset(); got != "" {
		t.Fatalf("无键 meta 后 AgentPreset() = %q, want empty", got)
	}
	// 畸形 _meta JSON 同样清空（fail-closed，不保留旧值）。
	inner.storeAgentPreset(json.RawMessage(`{"com.deepseek.dsh/agent-preset":`))
	if got := presetHandle.AgentPreset(); got != "" {
		t.Fatalf("畸形 meta 后 AgentPreset() = %q, want empty", got)
	}
}
