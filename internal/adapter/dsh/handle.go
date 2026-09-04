package dsh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

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
	nextID         int64
	nextSeq        int64
	replayMode     bool
	replayOrdinal  int64
	replayDone     chan struct{}
	replayDoneOnce sync.Once
	// pending 是等待响应的请求表；readLoop 按 id 回填。
	pending map[int64]*pendingReq
	// dropped 记录被丢弃/无法映射的入站帧与 update 变体计数（诊断用，不进公共协议）。
	dropped map[string]int64
	// events 是有界缓冲的 canonical 事件通道（读循环在桥关闭后关闭它）。
	events   chan adapter.Event
	readDone chan struct{}
	closed   bool
	// eventMu/eventWG 协调事件入队和通道关闭，避免桥退出时并发写入已关闭通道。
	eventMu     sync.Mutex
	eventClosed bool
	eventStop   chan struct{}
	eventWG     sync.WaitGroup
	// sendMu 串行化会话的 prompt 槽位：桥同一时刻只允许一个 in-flight prompt。
	sendMu sync.Mutex
	// model 是用户通过 session.model_select / send 随行模型表达的期望模型；
	// appliedModel 是桥上已通过 session/set_config_option 生效的模型，
	// 两者共同保证每次变更只下发一次，绝不带着旧模型静默发送。
	model        string
	appliedModel string
	// effort 是用户通过 session.effort_select / send 随行 effort 表达的期望推理档位；
	// appliedEffort 是桥上已通过 set_config_option(configId=thought_level) 生效的档位。
	// 档位必须属于桥对当前模型公布的目录，否则桥以 invalidParams 拒绝（fail-closed）。
	effort        string
	appliedEffort string

	// permissionMu 保护 pendingPermissions（一次性权限决策 registry，v0.8.2 P1）。
	// 桥的 session/request_permission 请求先登记再广播，等待 daemon 经
	// ResolvePermission 注入决策；断线/Dispose 时统一 fail-closed 收口为 cancelled。
	permissionMu       sync.Mutex
	pendingPermissions map[string]*pendingPermission

	// modesMu 保护 modes（v0.8.3 P3）：来自 new/load/resume 响应的 mode 目录
	// 快照与 current_mode_update 通知的最新选中项。目录为空 = 桥未广告 mode。
	modesMu sync.Mutex
	modes   adapter.SessionModeInfo

	// agentPresetMu 保护 agentPreset（v0.8.5 §3.8）：来自 new/load/resume 响应
	// _meta 的 com.deepseek.dsh/agent-preset 键——会话实际 joined 的 DSH 预设。
	// 空字符串表示会话未 joined 预设（客户端不得猜测）。
	agentPresetMu sync.Mutex
	agentPreset   string

	// questionMu 保护 pendingQuestions（一次性 question 回答 registry，v0.8.3 P3）。
	// 桥的 dsh/question/request 请求先登记再广播 EventUserQuestion，等待 daemon
	// 经 ResolveQuestion 注入回答；断线/Dispose 统一 fail-closed 收口为错误应答。
	questionMu       sync.Mutex
	pendingQuestions map[string]*pendingQuestion

	// turnPhases 是 v0.8.4（ADR-015 §3）的回合相位注册表：对桥的 dsh/turn/status
	// 投影做结构校验（冻结转换表 + revision 单调 + 终态 fence），合法帧映射为
	// canonical turn.phase/session.activity 事件。读循环单 goroutine 访问。
	turnPhases *turnPhaseRegistry

	// 中断链路埋点（V084-08 补强）：abortRequested 记录客户端请求中断的次数；
	// turnsCancelled 记录回合确实以 stopReason=cancelled 结算的次数。两者结合
	// 回答"中断是否真正打断了 DSH 模型回合"——只发 cancel 而回合未取消说明
	// 中断链路失效。单 goroutine（读循环/Send）内递增。
	abortsRequested int64
	turnsCancelled  int64
}

// instrumentSnapshot 返回中断链路埋点计数（诊断与回归断言用）。
func (h *handle) instrumentSnapshot() map[string]int64 {
	return map[string]int64{
		"abort_requested": h.abortsRequested,
		"turn_cancelled":  h.turnsCancelled,
	}
}

// streamingEnvSwitch 是 v0.8.4 流式协商的回滚开关（ADR-015 §8）：
// AGENT_SESSIONS_DSH_STREAMING=off 时不声明流式扩展、不解析 _meta 身份帧，
// DSH 路径回到 v0.8.3 的 completed-only 语义。
const streamingEnvSwitch = "AGENT_SESSIONS_DSH_STREAMING"

var streamingOnce struct {
	sync.Once
	enabled bool
}

// streamingNegotiationEnabled 报告流式扩展是否协商（默认开启）。
func streamingNegotiationEnabled() bool {
	streamingOnce.Do(func() {
		streamingOnce.enabled = os.Getenv(streamingEnvSwitch) != "off"
	})
	return streamingOnce.enabled
}

// pendingPermission 是一条等待一次性决策的桥权限请求。
// requestKey 是本实现与移动端共用的关联键（=桥 toolCallId）；
// bridgeID 是桥发来请求的原始 JSON-RPC id，决策后必须原样回显应答。
type pendingPermission struct {
	requestKey string
	bridgeID   int64
	sessionID  string
	toolCallID string
	title      string
	resolved   bool
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
		transport:          tr,
		events:             make(chan adapter.Event, 256),
		pending:            map[int64]*pendingReq{},
		dropped:            map[string]int64{},
		pendingPermissions: map[string]*pendingPermission{},
		pendingQuestions:   map[string]*pendingQuestion{},
		turnPhases:         newTurnPhaseRegistry(0),
		readDone:           make(chan struct{}),
		replayDone:         make(chan struct{}),
		eventStop:          make(chan struct{}),
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

func (h *handle) setReplayMode(enabled bool) {
	h.mu.Lock()
	h.replayMode = enabled
	h.replayOrdinal = 0
	h.mu.Unlock()
}

// ReplayComplete 返回 DSH session/load 已收到响应的通知通道。
func (h *handle) ReplayComplete() <-chan struct{} { return h.replayDone }

func (h *handle) markReplayComplete() {
	h.mu.Lock()
	// ACP 保证回放通知先于 load 响应；响应返回后，后续实时事件不得再被标记为
	// 回放事件或占用回放背压通道，否则恢复后的 send 会被错误去重。
	h.replayMode = false
	h.mu.Unlock()
	h.replayDoneOnce.Do(func() { close(h.replayDone) })
}

// SetModel 应用运行期模型覆盖（session.model_select / session.send 的随行模型）。
// 值为客户端从 ACP 动态目录选择的 opaque route value（dsh:model:<provider>:<model>），
// 本端只透传不解析。空值忽略：与 opencode 口径一致，避免清空后桥回退到未受控的
// 配置默认。SetModel 无 ctx 与错误返回，真正的下发发生在下一次 Send 前（applyModel）；
// 桥对不在目录内的模型会以 invalidParams 拒绝，失败在 Send 路径 fail-closed。
func (h *handle) SetModel(model string) {
	model = strings.TrimSpace(model)
	if model == "" {
		return
	}
	h.mu.Lock()
	h.model = model
	h.mu.Unlock()
}

// applyModel 在 prompt 前把期望模型同步到桥（session/set_config_option，
// configId=model）。值为 ACP 动态目录（initialize 的 model-catalog _meta）公布的
// 无歧义 route value（dsh:model:<provider>:<model>），客户端原样提交、本端不按
// 渠道名解析。与上一次生效值相同则跳过；失败返回错误并交给 Send 的失败路径广播
// session_error/turn_completed，绝不带着旧模型继续发送。
func (h *handle) applyModel(ctx context.Context) error {
	h.mu.Lock()
	model := h.model
	applied := h.appliedModel
	h.mu.Unlock()
	if model == "" || model == applied {
		return nil
	}
	applyCtx, cancel := withTimeout(ctx, handshakeTimeout)
	defer cancel()
	if _, err := h.request(applyCtx, "session/set_config_option", map[string]any{
		"sessionId": h.sessionID,
		"configId":  "model",
		"value":     model,
	}); err != nil {
		return fmt.Errorf("dsh set_config_option(model=%s): %w", model, err)
	}
	h.mu.Lock()
	h.appliedModel = model
	h.mu.Unlock()
	return nil
}

// SetEffort 应用运行期推理档位覆盖（session.effort_select / session.send 的随行档位）。
// 空值忽略：与 model 口径一致，避免清空后桥回退到未受控的配置默认。
// 实际下发发生在下一次 Send 前（applyEffort），桥对不支持的档位以 invalidParams 拒绝，
// 失败在 Send 路径 fail-closed 并如实上报（客户端保留原档位，不产生假成功）。
func (h *handle) SetEffort(effort string) {
	effort = strings.TrimSpace(effort)
	if effort == "" {
		return
	}
	h.mu.Lock()
	h.effort = effort
	h.mu.Unlock()
}

// applyEffort 在 prompt 前把期望档位同步到桥（session/set_config_option，
// configId=thought_level——桥按当前模型已公布的档位校验并记忆该档位）。
// 与上一次生效值相同则跳过；失败返回错误并交给 Send 的失败路径广播
// session_error/turn_completed，绝不带着旧档位继续发送。
func (h *handle) applyEffort(ctx context.Context) error {
	h.mu.Lock()
	effort := h.effort
	applied := h.appliedEffort
	h.mu.Unlock()
	if effort == "" || effort == applied {
		return nil
	}
	applyCtx, cancel := withTimeout(ctx, handshakeTimeout)
	defer cancel()
	if _, err := h.request(applyCtx, "session/set_config_option", map[string]any{
		"sessionId": h.sessionID,
		"configId":  "thought_level",
		"value":     effort,
	}); err != nil {
		return fmt.Errorf("dsh set_config_option(thought_level=%s): %w", effort, err)
	}
	h.mu.Lock()
	h.appliedEffort = effort
	h.mu.Unlock()
	return nil
}

// sessionErrorPayload 构造 session_error 事件载荷：消息文案恒携带，若底层错误是
// 桥 JSON-RPC 错误（bridgeError）则把上游结构化事实（error_code/status/request_id）
// 一并投影到事件，供 daemon/客户端透传；非桥错误不附加这些字段。
func (h *handle) sessionErrorPayload(message string, err error) map[string]any {
	payload := map[string]any{
		"instance_id": h.sessionID,
		"message":     message,
	}
	var bridgeErr *bridgeError
	if errors.As(err, &bridgeErr) && bridgeErr != nil {
		if bridgeErr.errorCode != "" {
			payload["error_code"] = bridgeErr.errorCode
		}
		if bridgeErr.status != 0 {
			payload["http_status"] = bridgeErr.status
		}
		if bridgeErr.requestID != "" {
			payload["provider_request_id"] = bridgeErr.requestID
		}
	}
	return payload
}

// Send 把文本作为 session/prompt 单文本块发送，阻塞到该 turn 结束（桥返回 stopReason）。
// 取消当前 turn 请调用 Abort（cancel 通知会让桥以 stopReason=cancelled 结算本请求）。
func (h *handle) Send(ctx context.Context, text string) error {
	h.sendMu.Lock()
	defer h.sendMu.Unlock()
	// 下发顺序固定为 model → effort → prompt（与桥 configOptions 语义一致）：
	// sendMu 保证 set_config_option 不会与 in-flight prompt 并发；桥拒绝
	// （未知模型/不支持的档位/校验失败）时整轮 fail-closed，绝不带旧值静默发送。
	if err := h.applyModel(ctx); err != nil {
		h.pushEvent(adapter.Event{
			Type:    adapter.EventSessionError,
			Payload: h.sessionErrorPayload(fmt.Sprintf("模型切换失败：%v", err), err),
		})
		h.synthesizeTerminalPhase("error")
		h.pushEvent(adapter.Event{
			Type: adapter.EventTurnCompleted,
			Payload: map[string]any{
				"instance_id": h.sessionID,
				"stop_reason": "error",
			},
		})
		return err
	}
	if err := h.applyEffort(ctx); err != nil {
		h.pushEvent(adapter.Event{
			Type:    adapter.EventSessionError,
			Payload: h.sessionErrorPayload(fmt.Sprintf("推理档位切换失败：%v", err), err),
		})
		h.synthesizeTerminalPhase("error")
		h.pushEvent(adapter.Event{
			Type: adapter.EventTurnCompleted,
			Payload: map[string]any{
				"instance_id": h.sessionID,
				"stop_reason": "error",
			},
		})
		return err
	}
	return h.sendPromptBlocks(ctx, []map[string]any{{"type": "text", "text": text}})
}

// sendPromptBlocks 是 Send 的 prompt 发送核心（v0.8.3 P3 提取，供 SendContent
// 复用）：发起 session/prompt 并在失败/响应异常/正常结束三条路径上补齐
// session_error / turn_completed 终态事件，客户端绝不悬挂在“生成中”。
func (h *handle) sendPromptBlocks(ctx context.Context, prompt []map[string]any) error {
	params := map[string]any{
		"sessionId": h.sessionID,
		"prompt":    prompt,
	}
	result, err := h.request(ctx, "session/prompt", params)
	if err != nil {
		// 失败也必须收敛回合状态：没有终止标记客户端会永远停留在“生成中”。
		// 先发 session_error（UI 提示），再发 turn_completed（关掉 generating 态）。
		h.pushEvent(adapter.Event{
			Type:    adapter.EventSessionError,
			Payload: h.sessionErrorPayload(fmt.Sprintf("模型回合失败：%v", err), err),
		})
		h.synthesizeTerminalPhase("error")
		h.pushEvent(adapter.Event{
			Type: adapter.EventTurnCompleted,
			Payload: map[string]any{
				"instance_id": h.sessionID,
				"stop_reason": "error",
			},
		})
		return err
	}
	// ACP 会在 session/prompt 响应完成前以通知发送助手内容；响应到达后补发明确的
	// 终止标记，让 daemon 可以确定性地结束移动端生成状态。
	var response struct {
		StopReason string `json:"stopReason"`
	}
	if decodeErr := json.Unmarshal(result, &response); decodeErr != nil {
		// 响应 decode 失败同样必须收敛回合状态（v0.8.2 P1）：桥已返回结果但形状异常时，
		// 若直接返回错误，客户端会永远停留在“生成中”。先补发脱敏错误与失败终态，
		// 让 UI 回到可操作状态，原始错误只留在本机回执中。
		h.pushEvent(adapter.Event{
			Type: adapter.EventSessionError,
			Payload: map[string]any{
				"instance_id": h.sessionID,
				"message":     "模型回合响应异常，详情仅限本机诊断。",
			},
		})
		h.synthesizeTerminalPhase("error")
		h.pushEvent(adapter.Event{
			Type: adapter.EventTurnCompleted,
			Payload: map[string]any{
				"instance_id": h.sessionID,
				"stop_reason": "error",
			},
		})
		return fmt.Errorf("解析 session/prompt 响应: %w", decodeErr)
	}
	// 实测桥可能先返回 stopReason 响应、再补发最后一条 message_completed 通知
	// （同一连接按帧序，通知在响应帧之后到达）。若立刻发 turn_completed，daemon
	// 的 canonical 事件会出现 turn 先于正文的乱序，客户端按 turn 收敛后会错过
	// 回复正文。这里等待事件通道进入静默（或达到上限）再发终止标记，保证通知
	// 先入队；Send 本就阻塞到回合结束，额外宽限不影响并发语义。
	h.awaitInFlightNotifications(dshEventQuietWindow, dshEventDrainLimit)
	// 中断埋点：回合以 cancelled 结算 = 中断真正打断了模型回合。
	if response.StopReason == "cancelled" {
		h.turnsCancelled++
	}
	// v0.8.4：prompt 终态合成兜底 phase——桥已发终态时 terminal fence 去重。
	h.synthesizeTerminalPhase(response.StopReason)
	h.pushEvent(adapter.Event{
		Type: adapter.EventTurnCompleted,
		Payload: map[string]any{
			"instance_id": h.sessionID,
			"stop_reason": response.StopReason,
		},
	})
	return nil
}

// dshEventQuietWindow 是判定"在途通知已收完"的静默窗口；dshEventDrainLimit 是总上限，
// 即使桥持续补发通知也不会把 Send 卡死。
const (
	dshEventQuietWindow = 400 * time.Millisecond
	dshEventDrainLimit  = 3 * time.Second
)

// awaitInFlightNotifications 阻塞直到事件通道在静默窗口内没有新入队，或达到总上限。
// 消费者会实时排空通道，瞬时长度看不到波动；h.nextSeq 是 pushEvent 加锁递增的
// 累计入队计数，以"连续一个静默窗口内计数无增长"作为收敛判定。
func (h *handle) awaitInFlightNotifications(quiet, limit time.Duration) {
	deadline := time.Now().Add(limit)
	for {
		h.mu.Lock()
		before := h.nextSeq
		h.mu.Unlock()
		time.Sleep(quiet)
		h.mu.Lock()
		after := h.nextSeq
		h.mu.Unlock()
		if after == before || time.Now().After(deadline) {
			return
		}
	}
}

// Abort 发送 session/cancel 通知（通知型无应答帧；幂等，对空闲会话桥容错）。
// 埋点 abortRequested 记录中断请求次数；回合是否真的被取消由 turnsCancelled
// （prompt 以 stopReason=cancelled 结算）回答。
func (h *handle) Abort(ctx context.Context) error {
	_ = ctx
	h.abortsRequested++
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
	// 关闭前先把所有未决权限请求 fail-closed 收口为 cancelled（断线不泄漏）。
	h.cancelPendingPermissions()
	// v0.8.3 P3：未决 question 请求同样收口（错误应答让桥侧 ask() 快速失败）。
	h.cancelPendingQuestions()
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

// streamingNegotiationMeta 是 v0.8.4 客户端声明（ADR-015 §3/§5）：声明
// dsh/turn/status（增量 + phase 通知）与 dsh/thought（thought 通道），可见级别
// 默认 raw——终端所有者对自身终端拥有绝对所有权，raw 无需显式开启。
var streamingNegotiationMeta = map[string]any{
	NegotiationEntryTurnStatus: "1.0",
	NegotiationEntryThought:    "1.0",
	"dsh/thought/visibility":   "raw",
}

// initializeParams 是 ACP initialize 请求参数（spec §协议事实 冻结形状）。
// 流式回滚开关（AGENT_SESSIONS_DSH_STREAMING=off）关闭时不声明任何扩展，
// 桥自动回到 completed-only 旧路径。
var initializeParams = map[string]any{
	"protocolVersion": 1,
	"clientInfo": map[string]any{
		"name":    "agent-sessions-dsh",
		"version": "0.0.1",
	},
	"clientCapabilities": func() map[string]any {
		if !streamingNegotiationEnabled() {
			return map[string]any{}
		}
		return map[string]any{
			"_meta": map[string]any{
				DshExtensionMetaKey: streamingNegotiationMeta,
			},
		}
	}(),
}

// initializeResult 是 initialize 响应的最小投影。
type initializeResult struct {
	// ProtocolVersion 用 float64 承载：兼容 wire 上 1 与 1.0 两种数值形态。
	ProtocolVersion float64 `json:"protocolVersion"`
	AgentInfo       struct {
		Name    string `json:"name"`
		Version string `json:"version"`
	} `json:"agentInfo"`
	Meta struct {
		Catalog acpModelCatalogWire `json:"com.deepseek.dsh/model-catalog"`
	} `json:"_meta"`
	ModelCatalog ModelCatalog `json:"-"`
}

type acpModelCatalogWire struct {
	Version int `json:"version"`
	Current struct {
		Provider        string `json:"provider"`
		Model           string `json:"model"`
		Value           string `json:"value"`
		ReasoningEffort string `json:"reasoningEffort"`
	} `json:"current"`
	Providers []struct {
		ID     string `json:"id"`
		Name   string `json:"name"`
		Models []struct {
			Value               string `json:"value"`
			ID                  string `json:"id"`
			Name                string `json:"name"`
			Description         string `json:"description"`
			ContextWindowTokens int64  `json:"contextWindowTokens"`
			Reasoning           *struct {
				Efforts []struct {
					ID string `json:"id"`
				} `json:"efforts"`
			} `json:"reasoning"`
		} `json:"models"`
	} `json:"providers"`
}

func (catalog acpModelCatalogWire) project() ModelCatalog {
	if catalog.Version != 1 {
		return ModelCatalog{}
	}
	projected := ModelCatalog{}
	for _, provider := range catalog.Providers {
		group := adapter.ModelCapabilityGroup{ID: strings.TrimSpace(provider.ID), Name: strings.TrimSpace(provider.Name)}
		if group.ID == "" {
			continue
		}
		if group.Name == "" {
			group.Name = group.ID
		}
		for _, model := range provider.Models {
			item := adapter.ModelCapabilityModel{
				Provider: group.ID, Value: strings.TrimSpace(model.Value), ID: strings.TrimSpace(model.ID),
				Name: strings.TrimSpace(model.Name), Description: strings.TrimSpace(model.Description),
				ContextWindowTokens: model.ContextWindowTokens, Reasoning: model.Reasoning != nil,
			}
			if item.Value == "" || item.ID == "" {
				continue
			}
			if item.Name == "" {
				item.Name = item.ID
			}
			if model.Reasoning != nil {
				for _, effort := range model.Reasoning.Efforts {
					if value := strings.TrimSpace(effort.ID); value != "" {
						item.Efforts = append(item.Efforts, value)
					}
				}
			}
			group.Models = append(group.Models, item)
			if item.Provider == catalog.Current.Provider && item.ID == catalog.Current.Model {
				projected.Current = item
			}
		}
		if len(group.Models) > 0 {
			projected.Groups = append(projected.Groups, group)
		}
	}
	return projected
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
	res.ModelCatalog = res.Meta.Catalog.project()
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
		SessionID string          `json:"sessionId"`
		Modes     json.RawMessage `json:"modes"`
		Meta      json.RawMessage `json:"_meta"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return "", fmt.Errorf("解析 session/new 响应: %w", err)
	}
	if res.SessionID == "" {
		return "", errors.New("session/new 响应缺少 sessionId")
	}
	h.storeModes(res.Modes)
	h.storeAgentPreset(res.Meta)
	return res.SessionID, nil
}

// loadSession 请求 ACP 恢复已有会话并回放持久化的用户/助手消息。桥保证回放通知
// 先于响应，因此响应到达即可作为本轮回放完成边界。
func (h *handle) loadSession(ctx context.Context, cwd string) error {
	raw, err := h.request(ctx, "session/load", map[string]any{
		"sessionId":             h.sessionID,
		"cwd":                   cwd,
		"mcpServers":            []any{},
		"additionalDirectories": []string{},
	})
	if err == nil {
		var res struct {
			Modes json.RawMessage `json:"modes"`
			Meta  json.RawMessage `json:"_meta"`
		}
		if json.Unmarshal(raw, &res) == nil {
			h.storeModes(res.Modes)
			h.storeAgentPreset(res.Meta)
		}
		h.markReplayComplete()
	}
	return err
}

// resumeSession 恢复已有会话但不回放历史。
func (h *handle) resumeSession(ctx context.Context, cwd string) error {
	raw, err := h.request(ctx, "session/resume", map[string]any{
		"sessionId":             h.sessionID,
		"cwd":                   cwd,
		"mcpServers":            []any{},
		"additionalDirectories": []string{},
	})
	if err == nil {
		var res struct {
			Modes json.RawMessage `json:"modes"`
			Meta  json.RawMessage `json:"_meta"`
		}
		if json.Unmarshal(raw, &res) == nil {
			h.storeModes(res.Modes)
			h.storeAgentPreset(res.Meta)
		}
	}
	return err
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

// bridgeError 是桥 JSON-RPC 错误的结构化投影。桥在 error.data 中携带上游
// LlmFailure 事实（code/status/requestId，见 ACP internalError(data, detail)），
// 本端逐字段投影供上层事件透传，客户端因此拿到结构化 error_code 而非文本。
type bridgeError struct {
	rpcCode   int    // JSON-RPC 错误码（如 -32603）
	message   string // 桥提供的完整描述
	errorCode string // 上游稳定错误分类（如 RATE_LIMIT/QUOTA），来自 error.data.code
	status    int    // 上游 HTTP 状态（如 429），来自 error.data.status；0 表示缺失
	requestID string // 上游请求标识，来自 error.data.requestId
}

func (e *bridgeError) Error() string {
	return fmt.Sprintf("JSON-RPC 桥请求失败（code %d）: %s", e.rpcCode, e.message)
}

// wireError 从桥错误帧构造结构化错误：JSON-RPC 数值 code 与 message 恒保留，
// error.data 中的 LlmFailure 字段（code/status/requestId）若存在则投影到
// bridgeError 并以 %w 包装，调用方可用 errors.As 取出后透传 error_code/status。
func wireError(method string, rpcErr *rpcError) error {
	be := &bridgeError{rpcCode: rpcErr.Code, message: rpcErr.Message}
	if len(rpcErr.Data) > 0 {
		var data struct {
			Code      string `json:"code"`
			Status    int    `json:"status"`
			RequestID string `json:"requestId"`
		}
		if json.Unmarshal(rpcErr.Data, &data) == nil {
			be.errorCode = strings.TrimSpace(data.Code)
			be.status = data.Status
			be.requestID = strings.TrimSpace(data.RequestID)
		}
	}
	return fmt.Errorf("JSON-RPC %s 失败: %w", method, be)
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
// 循环退出时先把 closed 置位再关闭事件通道：Send 失败路径可能在桥退出后才补发
// session_error/turn_completed 终止事件，必须让 pushEvent 看到一致的关闭状态（Dispose 等待
// readDone 后返回，保证不向已关闭通道写事件）。
func (h *handle) readLoop() {
	defer close(h.readDone)
	defer func() {
		h.mu.Lock()
		h.closed = true
		h.mu.Unlock()
		// 桥退出（EOF/崩溃）时未决权限请求无法再获得决策：fail-closed 收口 cancelled。
		h.cancelPendingPermissions()
		// 未决 question 请求同样无法再获得回答：错误应答快速失败（不悬挂面板）。
		h.cancelPendingQuestions()
		h.eventMu.Lock()
		if !h.eventClosed {
			h.eventClosed = true
			close(h.eventStop)
		}
		h.eventMu.Unlock()
		// 让已经开始入队的协程先退出，再关闭公共事件通道。
		h.eventWG.Wait()
		close(h.events)
	}()
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

// handleNotification 处理桥的通知帧：session/update（含 v0.8.4 流式帧）与
// 协商后的 dsh/turn/status；其余方法名计数丢弃。
func (h *handle) handleNotification(msg rpcMessage) {
	if msg.Method == NotifyDshTurnStatus {
		// v0.8.4（ADR-015 §3）：桥是 phase 的唯一权威；未声明扩展时该通知
		// 不会到达（fail-closed），畸形/越权帧在这里丢弃计数。
		h.handleTurnStatus(msg.Params)
		return
	}
	if msg.Method != "session/update" {
		h.countDrop("notify:" + msg.Method)
		return
	}
	var params struct {
		SessionID string                     `json:"sessionId"`
		Update    json.RawMessage            `json:"update"`
		Meta      map[string]json.RawMessage `json:"_meta"`
	}
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		h.countDrop("bad_update")
		return
	}
	// v0.8.3 P3：current_mode_update 不进 canonical 事件流（mode 状态经
	// SessionModeHandle.Modes() 读取），只更新句柄内的目录快照。
	var probe struct {
		SessionUpdate string `json:"sessionUpdate"`
		CurrentModeID string `json:"currentModeId"`
	}
	if json.Unmarshal(params.Update, &probe) == nil && probe.SessionUpdate == "current_mode_update" {
		if probe.CurrentModeID != "" {
			h.modesMu.Lock()
			h.modes.CurrentModeID = probe.CurrentModeID
			h.modesMu.Unlock()
		}
		return
	}
	if !streamingNegotiationEnabled() {
		params.Meta = nil
	}
	ev, ok, variant := mapSessionUpdate(params.SessionID, params.Update, params.Meta)
	if !ok {
		// 白名单外或未知 update 变体：丢弃并计数，不报错。
		h.countDrop("update:" + variant)
		return
	}
	h.pushEvent(ev)
}

// handleTurnStatus 校验并转发桥的 dsh/turn/status 通知（v0.8.4，ADR-015 §3）。
// 严格 schema：未知字段、版本不匹配、跨 session、超限字段、白名单外 reason、
// 非法转换、revision 回退一律丢弃计数；合法帧映射为 canonical turn.phase 与
// session.activity 两个事件（后者是 session 级聚合镜像）。
func (h *handle) handleTurnStatus(params json.RawMessage) {
	if !streamingNegotiationEnabled() {
		h.countDrop("turn_status_undeclared")
		return
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(params, &raw); err != nil {
		h.countDrop("turn_status_malformed")
		return
	}
	for key := range raw {
		if !turnStatusAllowedField(key) {
			h.countDrop("turn_status_unknown_field")
			return
		}
	}
	var req struct {
		ProtocolVersion int             `json:"protocolVersion"`
		SessionID       string          `json:"sessionId"`
		TurnID          string          `json:"turnId"`
		Step            int64           `json:"step"`
		Phase           string          `json:"phase"`
		Revision        int64           `json:"revision"`
		Reason          string          `json:"reason"`
		SafeSummary     json.RawMessage `json:"safeSummary"`
	}
	if err := json.Unmarshal(params, &req); err != nil {
		h.countDrop("turn_status_malformed")
		return
	}
	if req.ProtocolVersion != dshTurnStatusProtocolVersion || req.SessionID != h.sessionID ||
		req.TurnID == "" || len(req.TurnID) > dshTurnStatusTurnIDLimit ||
		req.Step < 0 || req.Revision <= 0 || len(req.SafeSummary) > dshTurnStatusSummaryLimit ||
		!IsValidTurnPhaseReason(req.Reason) {
		h.countDrop("turn_status_invalid_payload")
		return
	}
	phase, ok := ParseTurnPhase(req.Phase)
	if !ok {
		h.countDrop("turn_status_unknown_phase")
		return
	}
	h.phaseApply(req.TurnID, req.Step, phase, TurnPhaseReason(req.Reason), req.Revision)
}

// turnStatusAllowedField 是 dsh/turn/status 严格 schema 的字段白名单。
func turnStatusAllowedField(key string) bool {
	switch key {
	case "protocolVersion", "sessionId", "turnId", "step", "phase", "revision", "reason", "safeSummary":
		return true
	default:
		return false
	}
}

// phaseApply 对一个回合执行冻结转换表校验并广播 phase 事件。bridgeRevision>0
// 时执行单调守卫（回退/重复丢弃）；合成兜底帧无桥 revision，由转换机自己的
// 终态 fence 去重。事件 revision 以转换机内部单调计数为准（下游排序依据）。
func (h *handle) phaseApply(turnID string, step int64, next TurnPhase, reason TurnPhaseReason, bridgeRevision int64) bool {
	entry := h.turnPhases.getOrCreate(turnID)
	if bridgeRevision > 0 {
		if bridgeRevision <= entry.lastRevision {
			h.countDrop("turn_phase_stale_revision")
			return false
		}
		entry.lastRevision = bridgeRevision
	}
	var phase, revision = next, int64(1)
	switch {
	case entry.joining:
		// 加入进行中的回合：首帧是桥的权威投影，任意相位都被信任并直接投影；
		// 之后的所有帧才受冻结转换表约束（ADR-015 §3 结构校验边界）。
		entry.joining = false
		entry.machine = joinedMachineAt(next)
	default:
		if current, _ := entry.machine.Current(); current == next {
			// 同相位自环：合法的 no-op 去重，不推进 revision、不产生事件。
			return true
		}
		var ok bool
		if phase, ok = entry.machine.Apply(next); !ok {
			// 非法转换 / terminal fence：丢弃并计数，绝不产生事件。
			h.countDrop("turn_phase_illegal_transition")
			return false
		}
		_, revision = entry.machine.Current()
	}
	activity := map[string]any{
		"instance_id": h.sessionID,
		"turn_id":     turnID,
		"phase":       string(phase),
		"revision":    revision,
	}
	h.pushEvent(adapter.Event{Type: adapter.EventTurnPhase, Payload: map[string]any{
		"instance_id": h.sessionID,
		"turn_id":     turnID,
		"step":        step,
		"phase":       string(phase),
		"revision":    revision,
		"reason":      string(reason),
	}})
	h.pushEvent(adapter.Event{Type: adapter.EventSessionActivity, Payload: activity})
	return true
}

// synthesizeTerminalPhase 在 prompt 终态处合成兜底 phase（ADR-015 §3）：桥已经
// 投影过终态时 terminal fence 静默去重；旧桥没有 phase 投影时保证客户端收到
// 权威终态，不会永远停留在"生成中"。
func (h *handle) synthesizeTerminalPhase(stopReason string) {
	if !streamingNegotiationEnabled() {
		return
	}
	phase := TurnPhaseCompleted
	reason := TurnReasonTurnEnd
	if stopReason == "cancelled" {
		phase = TurnPhaseCancelled
		reason = TurnReasonTurnCancelled
	} else if stopReason == "error" {
		phase = TurnPhaseFailed
		reason = TurnReasonTurnFailed
	}
	h.phaseApply(h.turnPhases.latestTurnID(), 0, phase, reason, 0)
}

// handleBridgeRequest 处理"桥→客户端"请求（带 id + method）。
func (h *handle) handleBridgeRequest(id int64, msg rpcMessage) {
	switch msg.Method {
	case "session/request_permission":
		h.handlePermissionRequest(id, msg.Params)
	case "dsh/question/request":
		h.handleQuestionRequest(id, msg.Params)
	default:
		// fs/*（writeTextFile/readTextFile 等）与任何未声明方法一律 -32601 fail-closed，
		// 与桥未实现方法（session/load 等）的错误形态保持一致。
		h.respondError(id, -32601, fmt.Sprintf("Method not found: %s", msg.Method))
	}
}

// handlePermissionRequest 处理桥的 session/request_permission 请求（v0.8.2 P1）：
//  1. 请求先登记到 pendingPermissions（requestKey=桥 toolCallId，绑定原始 JSON-RPC id），
//     随后向事件流广播 EventPermissionRequest（供移动端审批面板消费）；
//  2. 应答不立即 cancelled——真实链路是异步的：移动端批准/拒绝经 daemon 的
//     ResolvePermission 注入，由 registry 一次性回写桥的原始请求；
//  3. 只有 ResolvePermission 消费（allowed/rejected）或断线收口（cancelled）两种终态，
//     绝不静默批准；缺 toolCallId 的畸形请求无法关联，直接 fail-closed 取消。
func (h *handle) handlePermissionRequest(id int64, params json.RawMessage) {
	var req struct {
		SessionID string `json:"sessionId"`
		ToolCall  struct {
			ToolCallID string `json:"toolCallId"`
			Title      string `json:"title"`
		} `json:"toolCall"`
	}
	// 解析失败只影响事件载荷完整性，不影响关联键判定。
	_ = json.Unmarshal(params, &req)
	requestKey := req.ToolCall.ToolCallID
	if requestKey == "" {
		// 无 toolCallId 的权限请求无法与后续决策一一关联：fail-closed 立即取消。
		h.respondResult(id, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}})
		instanceID := req.SessionID
		if instanceID == "" {
			instanceID = h.sessionID
		}
		h.pushEvent(adapter.Event{Type: adapter.EventPermissionDecision, Payload: map[string]any{"instance_id": instanceID, "outcome": "cancelled"}})
		return
	}
	h.permissionMu.Lock()
	// 重复请求同一 toolCallId：后到者无法获得独立决策，按重复处理（fail-closed 取消）。
	if _, dup := h.pendingPermissions[requestKey]; dup {
		h.permissionMu.Unlock()
		h.respondResult(id, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}})
		h.countDrop("permission_dup_request")
		return
	}
	h.pendingPermissions[requestKey] = &pendingPermission{
		requestKey: requestKey,
		bridgeID:   id,
		sessionID:  req.SessionID,
		toolCallID: requestKey,
		title:      req.ToolCall.Title,
	}
	h.permissionMu.Unlock()
	// 广播权限请求事件（载荷携带 request_id/session_id/tool_call_id，移动端以
	// request_id 关联 approve/reject 命令；标题仅为展示，正文/凭据不进协议）。
	payload := map[string]any{
		"instance_id":  req.SessionID,
		"request_id":   requestKey,
		"tool_call_id": requestKey,
	}
	if req.ToolCall.Title != "" {
		payload["title"] = req.ToolCall.Title
	}
	h.pushEvent(adapter.Event{Type: adapter.EventPermissionRequest, Payload: payload})
}

// ResolvePermission 把一次性决策写回桥的原始 JSON-RPC 请求（PermissionDecisionHandle）。
// 每个请求只允许一次决策：未知 requestKey 或重复决策返回错误（fail-closed）。
func (h *handle) ResolvePermission(requestKey string, allow bool) error {
	requestKey = strings.TrimSpace(requestKey)
	if requestKey == "" {
		return errors.New("permission 决策缺少 requestKey")
	}
	h.permissionMu.Lock()
	pp := h.pendingPermissions[requestKey]
	if pp == nil {
		h.permissionMu.Unlock()
		return fmt.Errorf("未知或已处理的权限请求: %s", requestKey)
	}
	if pp.resolved {
		h.permissionMu.Unlock()
		return fmt.Errorf("权限请求已消费，禁止重复决策: %s", requestKey)
	}
	pp.resolved = true
	delete(h.pendingPermissions, requestKey)
	h.permissionMu.Unlock()
	outcome := "allowed-once"
	if !allow {
		outcome = "rejected"
	}
	// 应答 SDK 的决策形状 {outcome:{outcome:...}}（近端 protocol 冻结三态）。
	h.respondResult(pp.bridgeID, map[string]any{"outcome": map[string]any{"outcome": outcome}})
	// 广播决策事件（客户端据此刻画审批状态；决策只消费一次）。
	decisionPayload := map[string]any{
		"instance_id":  pp.sessionID,
		"request_id":   pp.requestKey,
		"tool_call_id": pp.toolCallID,
		"outcome":      "allowed",
	}
	if !allow {
		decisionPayload["outcome"] = "rejected"
	}
	h.pushEvent(adapter.Event{Type: adapter.EventPermissionDecision, Payload: decisionPayload})
	return nil
}

// cancelPendingPermissions 在句柄关闭/断线时把所有未决权限请求 fail-closed 收口为
// cancelled（v0.8.2 P1：挂起请求不随会话泄漏，客户端不永久显示处理中）。
func (h *handle) cancelPendingPermissions() {
	h.permissionMu.Lock()
	pending := h.pendingPermissions
	h.pendingPermissions = map[string]*pendingPermission{}
	h.permissionMu.Unlock()
	for _, pp := range pending {
		if pp.resolved {
			continue
		}
		h.respondResult(pp.bridgeID, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}})
		h.pushEvent(adapter.Event{
			Type: adapter.EventPermissionDecision,
			Payload: map[string]any{
				"instance_id":  pp.sessionID,
				"request_id":   pp.requestKey,
				"tool_call_id": pp.toolCallID,
				"outcome":      "cancelled",
			},
		})
	}
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
		req.ch <- rpcResult{err: wireError(req.method, msg.Error)}
		return
	}
	req.ch <- rpcResult{result: msg.Result}
}

// pushEvent 把 canonical 事件送入缓冲事件通道；消费者过慢时丢弃增量事件防背压
// （与 opencode SSE 订阅的丢增量口径一致；完整正文仍可从会话历史恢复）。
func (h *handle) pushEvent(ev adapter.Event) {
	h.mu.Lock()
	// 读循环在桥关闭后 close(events)；此后任何入队（如 Send 失败路径的终止事件）
	// 必须安静丢弃，不能 panic。closed 由 Dispose/Close 与 mu 一起维护。
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.nextSeq++
	ev.Seq = h.nextSeq
	replay := h.replayMode
	if replay {
		h.replayOrdinal++
		ev.ReplayOrdinal = h.replayOrdinal
	}
	// 读循环关闭事件通道前会先设置 eventClosed 并等待 eventWG；持有 h.mu
	// 直到完成登记，保证关闭路径不会漏等本次入队。
	h.eventMu.Lock()
	if h.eventClosed {
		h.eventMu.Unlock()
		h.mu.Unlock()
		return
	}
	h.eventWG.Add(1)
	h.eventMu.Unlock()
	h.mu.Unlock()
	defer h.eventWG.Done()
	if replay {
		// session/load 期间回放流必须无损：Runner 已在 load 发出前注册消费者，
		// 此处阻塞即可形成背压，不会静默丢弃超过通道容量的历史。
		select {
		case h.events <- ev:
		case <-h.eventStop:
		}
		return
	}
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
