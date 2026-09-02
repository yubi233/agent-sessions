package dsh

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 本文件是 v0.8.3 P0 的假桥场景引擎（ADR-014 §7/§8 的测试化）。
// 目标：为 P1/P2 的桥/适配器实现提供可注入的场景骨架——mode、图像、生命周期、
// additionalDirectories、question/plan/goal/skill/delegation 的正常、重复、乱序、
// 超限、断线与越权场景都从同一个声明式脚本出发，固定复现 V08-12 而不依赖真实模型。
//
// P0 阶段先固定两类基线：
//  1. 桥未实现/适配器未映射的 update 变体（current_mode_update、plan_update、
//     available_commands_update）当前被丢弃并按变体计数——这是"桥不支持"的诚实基线，
//     P1/P2 实现后由对应场景测试翻转断言；
//  2. V083-07 的 Go 侧固定契约：Resume(ReplayHistory) 后 Send 必须重新下发
//     model（set_config_option 出现在 session/load 之后、session/prompt 之前），
//     恢复会话绝不带旧路由静默发送。

// scenarioConfig 是场景桥的声明式配置：桥侧能力开关与广告目录。
// 每个字段都对应一个可在 P1/P2 翻转的桥行为；P0 只声明形状，不接 handler。
type scenarioConfig struct {
	// modeCatalog 是桥广告的 permission mode 目录（nil = 桥不支持 mode）。
	modeCatalog []map[string]any
	// lifecycleMethods 声明桥已实现 session/close/list/delete/fork。
	lifecycleMethods bool
	// imageAdmission 声明桥 promptCapabilities.image=true（attachment 服务 + 模型支持）。
	imageAdmission bool
	// extensions 是桥在 agentCapabilities._meta 宣告的 dsh/* 目录（nil = 无扩展）。
	extensions map[string]string
	// rejectSetMode 让 set_mode 场景注入桥拒绝（未知 mode/custom）。
	rejectSetMode string
}

// scenarioLog 记录客户端发往桥的帧顺序（去噪：只保留 method + params），供断言排序。
type scenarioLog struct {
	methods []string
	params  []map[string]any
}

// methodIndex 返回第 n 次出现的 method 下标；不存在返回 -1。
func (l *scenarioLog) methodIndex(method string, nth int) int {
	seen := 0
	for i, m := range l.methods {
		if m == method {
			if seen == nth {
				return i
			}
			seen++
		}
	}
	return -1
}

// newScenarioBridge 构造场景桥：按配置应答 initialize/new/load/resume/set_mode/lifecycle
// 与 dsh/* 方法，并记录客户端帧顺序。配置外的 dsh/* 方法不回复（模拟桥未启用扩展）。
func newScenarioBridge(t *testing.T, cfg scenarioConfig) (*fakeBridge, *scenarioLog) {
	t.Helper()
	fb := newFakeBridge()
	log := &scenarioLog{}
	sessionID := "sess-scenario"
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		id := frameID(msg)
		method := methodOf(msg)
		// 记录客户端请求帧（通知帧同样记录，供排序断言）。
		log.methods = append(log.methods, method)
		if params, ok := msg["params"].(map[string]any); ok {
			log.params = append(log.params, params)
		} else {
			log.params = append(log.params, nil)
		}
		switch method {
		case "initialize":
			agentCaps := map[string]any{
				"loadSession":         true,
				"promptCapabilities":  map[string]any{"image": cfg.imageAdmission, "audio": false, "embeddedContext": false},
				"sessionCapabilities": map[string]any{"resume": map[string]any{}},
			}
			if cfg.extensions != nil {
				agentCaps["_meta"] = map[string]any{DshExtensionMetaKey: cfg.extensions}
			}
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{
					"protocolVersion":   1,
					"agentInfo":         map[string]any{"name": "deepseek-harness-acp", "version": "0.0.1"},
					"agentCapabilities": agentCaps,
				},
			})
		case "session/new":
			result := map[string]any{"sessionId": sessionID}
			if cfg.modeCatalog != nil {
				result["modes"] = map[string]any{"currentModeId": cfg.modeCatalog[0]["id"], "available": cfg.modeCatalog}
			}
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
		case "session/load", "session/resume":
			result := map[string]any{}
			if cfg.modeCatalog != nil {
				result["modes"] = map[string]any{"currentModeId": cfg.modeCatalog[0]["id"], "available": cfg.modeCatalog}
			}
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
		case "session/set_config_option":
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
		case "session/set_mode":
			if cfg.rejectSetMode != "" {
				fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id,
					"error": map[string]any{"code": -32602, "message": cfg.rejectSetMode}})
				return
			}
			result := map[string]any{}
			if cfg.modeCatalog != nil {
				result["modes"] = map[string]any{"currentModeId": cfg.modeCatalog[0]["id"], "available": cfg.modeCatalog}
			}
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
		case "session/close", "session/delete", "session/fork":
			if !cfg.lifecycleMethods {
				fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id,
					"error": map[string]any{"code": -32601, "message": "Method not found: " + method}})
				return
			}
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
		case "session/list":
			if !cfg.lifecycleMethods {
				fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id,
					"error": map[string]any{"code": -32601, "message": "Method not found: session/list"}})
				return
			}
			// 脱敏 list 形状：展示名/状态/revision/游标，无物理路径。
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{
				"sessions": []map[string]any{{
					"sessionId": sessionID, "displayName": "demo", "status": "closed", "revision": 1,
				}},
				"nextCursor": "",
			}})
		case "session/prompt":
			fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"stopReason": "end_turn"}})
		default:
			if strings.HasPrefix(method, DshExtensionNamespace) && cfg.extensions != nil {
				// P0 场景桥对已宣告扩展返回空成功；P2 起按各域 payload 场景覆盖。
				fb.push(t, map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
			}
			// 未宣告扩展：不回复，由调用方超时收口（fail-closed 语义在 P2 断言）。
		}
	}
	return fb, log
}

// pushModeUpdate 注入一条 current_mode_update 会话通知（P1 后应映射为 mode 事件）。
func pushModeUpdate(t *testing.T, fb *fakeBridge, sessionID, modeID string) {
	t.Helper()
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": modeID},
		},
	})
}

// pushPlanUpdate 注入一条 ACP plan_update 通知（markdown 审核内容）。
func pushPlanUpdate(t *testing.T, fb *fakeBridge, sessionID, planID, markdown string) {
	t.Helper()
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "plan_update", "planId": planID, "type": "markdown", "content": markdown},
		},
	})
}

// pushAvailableCommands 注入一条 available_commands_update 通知（命令/skill 目录）。
func pushAvailableCommands(t *testing.T, fb *fakeBridge, sessionID string, commands []map[string]any) {
	t.Helper()
	fb.push(t, map[string]any{
		"jsonrpc": "2.0", "method": "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "available_commands_update", "commands": commands},
		},
	})
}

// (V083-01 基线) 当前 handle 未映射 current_mode_update：丢弃并按变体计数，不产生事件。
// P1 实现 mode 投影后，本测试由 mode 目录/set_mode 场景测试替代或翻转。
func TestBaselineCurrentModeUpdateDropped(t *testing.T) {
	const sessionID = "sess-mode-baseline"
	fb, _ := newScenarioBridge(t, scenarioConfig{})
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) == "initialize" {
			// 用 respondByMethod 语义手写：只回 initialize 最小形状。
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": frameID(msg),
				"result": map[string]any{
					"protocolVersion": 1,
					"agentInfo":       map[string]any{"name": "deepseek-harness-acp", "version": "0.0.1"},
				},
			})
			return
		}
		respondByMethod(t, sessionID)(fb, msg)
	}
	h := startWithFake(t, fb)
	pushModeUpdate(t, fb, sessionID, "workspace-write")
	// 事件通道必须保持安静（无伪造 mode 事件）。
	select {
	case ev := <-h.Events():
		t.Fatalf("未映射的 current_mode_update 不应产生事件: %+v", ev)
	case <-time.After(300 * time.Millisecond):
	}
	hh := h.(*handle)
	if got := hh.droppedCounts()["update:current_mode_update"]; got != 1 {
		t.Fatalf("current_mode_update 应按变体计数丢弃，dropped=%v", hh.droppedCounts())
	}
}

// (V083-13/V083-17 基线) plan_update 与 available_commands_update 当前同样按变体丢弃。
func TestBaselinePlanAndCommandsUpdateDropped(t *testing.T) {
	const sessionID = "sess-plan-baseline"
	fb := newFakeBridge()
	fb.script = respondByMethod(t, sessionID)
	h := startWithFake(t, fb)
	pushPlanUpdate(t, fb, sessionID, "plan-1", "# 计划")
	pushAvailableCommands(t, fb, sessionID, []map[string]any{{"name": "/review", "kind": "skill"}})
	select {
	case ev := <-h.Events():
		t.Fatalf("未映射的审核/目录变体不应产生事件: %+v", ev)
	case <-time.After(300 * time.Millisecond):
	}
	hh := h.(*handle)
	if got := hh.droppedCounts()["update:plan_update"]; got != 1 {
		t.Fatalf("plan_update 应按变体计数丢弃，dropped=%v", hh.droppedCounts())
	}
	if got := hh.droppedCounts()["update:available_commands_update"]; got != 1 {
		t.Fatalf("available_commands_update 应按变体计数丢弃，dropped=%v", hh.droppedCounts())
	}
}

// (V083-07 Go 侧固定契约) Resume(ReplayHistory) → Send 的下发顺序：
// session/load 之后必须重新出现 set_config_option(model)，且先于 session/prompt。
// 该契约与 P1 的桥侧修复（load 后保留 selection）互为镜像：无论桥是否丢路由，
// Go 适配器都不得带旧模型静默发送。
func TestV08307ResumeSendReappliesModelAfterLoad(t *testing.T) {
	const sessionID = "sess-v08307"
	fb, log := newScenarioBridge(t, scenarioConfig{})
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	var resumed adapter.Handle
	result, err := a.ResumeStreaming(context.Background(), adapter.ResumeRequest{
		InstanceID: sessionID, WorkspaceRoot: "/tmp/dsh-ws", ReplayHistory: true,
	}, func(h adapter.Handle) error { resumed = h; return nil })
	if err != nil || result.Result != adapter.WakeResumed {
		t.Fatalf("ResumeStreaming = %+v, %v", result, err)
	}
	t.Cleanup(func() { _ = resumed.Dispose(context.Background()) })
	resumed.(adapter.ModelOverrideHandle).SetModel("nemotron-3-ultra-free")
	if err := resumed.Send(context.Background(), "恢复后的第一句话"); err != nil {
		t.Fatalf("恢复后 Send: %v", err)
	}
	loadIdx := log.methodIndex("session/load", 0)
	modelIdx := log.methodIndex("session/set_config_option", 0)
	promptIdx := log.methodIndex("session/prompt", 0)
	if loadIdx < 0 || modelIdx < 0 || promptIdx < 0 {
		t.Fatalf("缺少关键帧: load=%d model=%d prompt=%d", loadIdx, modelIdx, promptIdx)
	}
	if !(loadIdx < modelIdx && modelIdx < promptIdx) {
		t.Fatalf("帧顺序必须为 load → set_config_option(model) → prompt，实际: %v", log.methods)
	}
	// model 下发参数必须携带目标模型，不得静默沿用旧路由。
	params := log.params[modelIdx]
	if params["configId"] != "model" || params["value"] != "nemotron-3-ultra-free" {
		t.Fatalf("恢复后模型下发参数不正确: %v", params)
	}
}

// (V083-25 场景骨架) 声明式场景桥可按配置应答 mode/生命周期/扩展方法——
// P1/P2 的场景测试将基于本骨架注入正常/重复/乱序/超限/断线/越权序列。
// 本测试只验证骨架自身的应答形状，不充当功能验收。
func TestScenarioBridgeShapeContract(t *testing.T) {
	cfg := scenarioConfig{
		modeCatalog: []map[string]any{
			{"id": "workspace-write", "name": "Workspace write", "description": "允许工作区内写入"},
			{"id": "danger-full-access", "name": "Danger full access", "description": "完全访问，需要风险确认"},
		},
		lifecycleMethods: true,
		imageAdmission:   true,
		extensions:       map[string]string{"dsh/goal/mutate": "1.0", "dsh/skill/invoke": "1.0"},
	}
	fb, _ := newScenarioBridge(t, cfg)
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	// 骨架烟测：Abort（cancel 通知）不报错；lifecycle/扩展应答形状由后续阶段断言。
	if err := h.Abort(context.Background()); err != nil {
		t.Fatalf("Abort: %v", err)
	}
}
