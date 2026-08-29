// SessionRunner 把 outbox 中的 Relay 命令兑现到 Adapter handle（测试 ID ADPT-OPENCODE-06）。
// 链路：runner 消费命令 -> adapter handle -> canonical 事件回写本地 store。
// 对应项目文档 docs/zh/项目文档.md 的「PC Daemon」（启动/恢复/停止本地 Session Instance，
// 统一为 canonical event stream）与「统一能力模型」（未实现能力 fail-closed，不伪造成功）。
//
// 本阶段约束：
//   - permission/question/plan/goal/skill 等 kind 未实现，返回 ErrUnsupportedCommand；
//   - 真实密文 envelope 不可解（无 fixture_payload）时返回错误，保持 fail-closed；
//   - 无本地 instance 映射的 send/resume 返回 ErrSessionInstanceMissing（local_state_missing 语义）；
//   - 唤醒结果只写 adapter 返回的六态之一，runner 禁止伪造 resumed。
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 命令解析与 fail-closed 语义。
var (
	// ErrUnsupportedCommand 表示该 Relay 命令 kind 在本阶段未实现。
	ErrUnsupportedCommand = errors.New("unsupported daemon command: kind 未实现")
	// ErrSessionInstanceMissing 表示本地没有 <sessionID> 的 Provider instance（local_state_missing 语义）。
	ErrSessionInstanceMissing = errors.New("local_state_missing: session instance 不存在")
)

// instanceKey 是 <sessionID> -> providerThread JSON 的 local_state 键。
func instanceKey(sessionID string) string { return "instance:" + sessionID }

// eventKey 是最后一条 canonical 事件的 local_state 键。
func eventKey(sessionID string) string { return instanceKey(sessionID) + ":last_event" }

// resumeResultKey 是 resume 唤醒结果的 local_state 键。
func resumeResultKey(sessionID string) string { return instanceKey(sessionID) + ":resume_result" }

// providerThread 是本地持久化的会话实例映射。
// 只存 provider 与 OpenCode session id（及 workspace root），不存正文/密文。
type providerThread struct {
	Provider      string `json:"provider"`
	InstanceID    string `json:"instance_id"`
	WorkspaceRoot string `json:"workspace_root,omitempty"`
}

// lastEvent 是事件转发 goroutine 写入的最新 canonical 事件摘要。这里只保留类型、序号与累计
// 条数；完整 payload 只能经 EventEncoder 进入密文 outbox，不能以 last_event 旁路明文落盘。
type lastEvent struct {
	Count int               `json:"count"`
	Type  adapter.EventType `json:"type"`
	Seq   int64             `json:"seq"`
}

// runningSession 是运行中的实例句柄与事件转发 goroutine 的退出路径。
type runningSession struct {
	handle adapter.Handle
	cancel context.CancelFunc
}

// SessionRunner 是 Relay 命令 -> Adapter handle 的兑现器。
type SessionRunner struct {
	store    *Store
	adapters map[string]adapter.Adapter // key: provider 名（如 "opencode"）
	logger   *slog.Logger
	// DefaultModel 是启动时注入的默认模型。只有 OpenCode 且命令未携带模型时才
	// 使用它；空值会交给 Adapter/服务端按既有兼容语义处理，绝不猜测其它 Provider。
	DefaultModel string

	mu      sync.Mutex
	handles map[string]*runningSession // key: sessionID
	// executionMu 把同一 Daemon 的命令兑现串行化。Relay 已有 delivery/idempotency，但这里仍要
	// 防止 start 与 kill 并发改写同一 session 的本地 instance 映射。
	executionMu sync.Mutex

	// eventSink 仅接收 Daemon 本机已规范化事件；是否加密/上传由连接层决定。
	// 未配置 sink 时仍保留本地状态，但绝不伪造 Relay event 成功。
	eventSinkMu sync.RWMutex
	eventSink   func(sessionID string, event adapter.Event)

	// eventSeq 保存每个 session 最近分配的 canonical 序号。Provider handle 的
	// 序号只覆盖 Provider 事件，runner 自己生成的 user_message/断流终态也必须
	// 使用同一条单调序列，否则生产 E2EE encoder 会拒绝 Seq=0，或发生 AAD 序号冲突。
	eventSeqMu sync.Mutex
	eventSeq   map[string]int64
	eventCount map[string]int

	rootCtx    context.Context
	rootCancel context.CancelFunc
}

// NewSessionRunner 构造会话跑者。adapters 按 provider 名注册；
// 未注册 provider 的命令保持 fail-closed，不降级到任何默认 Provider。
func NewSessionRunner(store *Store, adapters map[string]adapter.Adapter, logger *slog.Logger) *SessionRunner {
	if logger == nil {
		logger = slog.Default()
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &SessionRunner{
		store:      store,
		adapters:   adapters,
		logger:     logger,
		handles:    map[string]*runningSession{},
		eventSeq:   map[string]int64{},
		eventCount: map[string]int{},
		rootCtx:    ctx,
		rootCancel: cancel,
	}
}

// SetEventSink 设置 canonical event 的本机出口。连接层必须先把正文编码为密文 envelope，
// 再进入 Relay outbox；runner 不持有账户密钥，也不直接发 HTTP。
// RegisterAdapter 运行期补注册 provider adapter（feature flag 灰度接入用）。
// 同名 provider 覆盖旧注册；调用须在 ConsumeCommand 之前。
func (r *SessionRunner) RegisterAdapter(provider string, ad adapter.Adapter) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.adapters[provider] = ad
}

func (r *SessionRunner) SetEventSink(sink func(sessionID string, event adapter.Event)) {
	r.eventSinkMu.Lock()
	defer r.eventSinkMu.Unlock()
	r.eventSink = sink
}

// ConsumeCommand 消费 outbox 中的一条 Relay 命令。
// kind 以 cmd.Kind 为准；payload_json 也可能携带 kind（Relay 命令体），作为兜底来源。
func (r *SessionRunner) ConsumeCommand(ctx context.Context, cmd Command) error {
	r.executionMu.Lock()
	defer r.executionMu.Unlock()
	kind := cmd.Kind
	if kind == "" {
		if env, err := parseEnvelope(cmd.PayloadJSON); err == nil && env.kind() != "" {
			kind = env.kind()
		}
	}
	switch kind {
	case "session.start":
		// 客户端 kind 清单不含 session.start；存在时兑现，否则本分支自然跳过。
		return r.startSession(ctx, cmd)
	case "session.send":
		return r.sendMessage(ctx, cmd)
	case "session.abort":
		return r.abortSession(ctx, cmd)
	case "session.kill":
		return r.killSession(ctx, cmd)
	case "session.resume":
		return r.resumeSession(ctx, cmd)
	case "session.model_select":
		return r.selectModel(ctx, cmd)
	case "session.effort_select":
		return r.selectEffort(ctx, cmd)
	default:
		// 未实现 kind 保持 fail-closed：不写任何成功状态（项目文档「统一能力模型」）。
		return fmt.Errorf("%w: kind=%s", ErrUnsupportedCommand, kind)
	}
}

// Close 停止全部事件转发 goroutine 并回收所有存活 handle（幂等）。
func (r *SessionRunner) Close(ctx context.Context) error {
	r.mu.Lock()
	handles := r.handles
	r.handles = map[string]*runningSession{}
	r.mu.Unlock()
	for _, rs := range handles {
		rs.cancel()
		_ = rs.handle.Dispose(ctx)
	}
	r.rootCancel()
	return nil
}

// startSession 兑现 session.start：按 payload 的 provider 查找 adapter 并 Start，
// 从首个 turn_started 事件取得 OpenCode session id，持久化 instance 映射后启动事件转发。
func (r *SessionRunner) startSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.start 缺少 session_id")
	}
	provider := env.provider()
	if provider == "" {
		return errors.New("session.start 缺少 provider")
	}
	ad, ok := r.adapters[provider]
	if !ok {
		return fmt.Errorf("provider %q 未注册 adapter，保持 fail-closed", provider)
	}
	workspaceRoot := strings.TrimSpace(env.WorkspaceRoot)
	if workspaceRoot == "" {
		workspace, err := r.store.ConfirmedWorkspaceByID(cmd.WorkspaceID)
		if err != nil {
			return fmt.Errorf("resolve workspace %q: %w", cmd.WorkspaceID, err)
		}
		workspaceRoot = workspace.Root
	}

	// 重复 start 先回收旧句柄，避免泄漏与事件串流。
	r.mu.Lock()
	if old := r.handles[sessionID]; old != nil {
		old.cancel()
		_ = old.handle.Dispose(context.Background())
	}
	r.mu.Unlock()

	model := strings.TrimSpace(env.model())
	if model == "" && provider == "opencode" {
		model = strings.TrimSpace(r.DefaultModel)
	}
	handle, err := ad.Start(ctx, adapter.StartRequest{
		WorkspaceRoot: workspaceRoot,
		Provider:      provider,
		Model:         model,
		Effort:        env.effort(),
		PlanMode:      env.PlanMode,
		Prompt:        env.prompt(), // 密文或本机状态；不写公共日志
	})
	if err != nil {
		return fmt.Errorf("adapter start: %w", err)
	}
	// 先登记 handle（session.send/abort 立即可用），再等待首个事件。
	fwdCtx, cancel := context.WithCancel(r.rootCtx)
	r.mu.Lock()
	r.handles[sessionID] = &runningSession{handle: handle, cancel: cancel}
	r.mu.Unlock()

	var first adapter.Event
	var instanceID string
	if identified, ok := handle.(adapter.InstanceIDHandle); ok && strings.TrimSpace(identified.InstanceID()) != "" {
		// OpenCode 已在 POST /session 响应中返回 canonical ID；空会话不会产生
		// turn_started，因此不等待模型事件，也不消耗真实 Provider token。
		instanceID = strings.TrimSpace(identified.InstanceID())
	} else {
		first, err = r.awaitFirstEvent(ctx, handle)
		if err != nil {
			cancel()
			_ = handle.Dispose(context.Background())
			r.removeHandle(sessionID)
			return err
		}
		instanceID, err = instanceIDFromEvent(first)
		if err != nil {
			cancel()
			_ = handle.Dispose(context.Background())
			r.removeHandle(sessionID)
			return err
		}
	}

	// 持久化 instance 映射：只存 provider 与 OpenCode session id，不存正文/密文。
	mapping, err := json.Marshal(providerThread{
		Provider:      provider,
		InstanceID:    instanceID,
		WorkspaceRoot: workspaceRoot,
	})
	if err != nil {
		cancel()
		_ = handle.Dispose(context.Background())
		r.removeHandle(sessionID)
		return err
	}
	if err := r.store.Set(instanceKey(sessionID), string(mapping)); err != nil {
		cancel()
		_ = handle.Dispose(context.Background())
		r.removeHandle(sessionID)
		return fmt.Errorf("持久化 instance 映射: %w", err)
	}

	// 事件转发 goroutine：canonical 事件写回本地 store；fwdCtx 取消时退出。
	if first.Type != "" {
		go r.forwardEvents(sessionID, handle, fwdCtx, first)
	} else {
		go r.forwardEvents(sessionID, handle, fwdCtx)
	}
	return nil
}

// sendMessage 兑现 session.send：从 fixture 密文 envelope 解析文本并转发到 handle.Send。
// 真实密文不可解时返回错误，保持 fail-closed。
func (r *SessionRunner) sendMessage(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.send 缺少 session_id")
	}
	text, err := env.fixtureMessage()
	if err != nil {
		return err
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	// The prompt is the canonical source for the user's timeline entry. Emit it
	// before the provider call so slow model turns do not hide the sent message.
	r.emitEvent(sessionID, adapter.Event{
		Type: adapter.EventUserMessage,
		Payload: map[string]any{
			"instance_id": sessionID,
			"text":        text,
		},
	})
	// 模型解析顺序：send 密文随行 > 会话已持久化选择（model_select）> handle 现值
	// （Start 时的目录默认）。空模型会让 opencode 服务端回退到它的配置默认，
	// 可能命中付费订阅条目，因此绝不能带着空模型发出。
	if override := strings.TrimSpace(env.model()); override != "" {
		if setter, ok := rs.handle.(adapter.ModelOverrideHandle); ok {
			setter.SetModel(override)
		}
	} else if stored, err := r.store.Get("model:" + sessionID); err == nil {
		if setter, ok := rs.handle.(adapter.ModelOverrideHandle); ok {
			setter.SetModel(strings.TrimSpace(stored))
		}
	}
	// 推理档位解析顺序：send 密文随行 > 会话已持久化选择（effort_select）> handle 现值。
	// 空值表示自动推理/不覆盖，由 Adapter 决定是否透传 variant。
	if override := strings.TrimSpace(env.effort()); override != "" {
		if setter, ok := rs.handle.(adapter.EffortOverrideHandle); ok {
			setter.SetEffort(override)
		}
	} else if stored, err := r.store.Get("effort:" + sessionID); err == nil {
		if setter, ok := rs.handle.(adapter.EffortOverrideHandle); ok {
			setter.SetEffort(strings.TrimSpace(stored))
		}
	}
	if err := rs.handle.Send(ctx, text); err != nil {
		// 传输层同步失败不会产生 Provider SSE 事件；若只回写命令回执，时间线里的
		// user_message 之后没有任何失败痕迹，客户端会停留在生成中。这里补发脱敏
		// 错误与失败终态，传输细节只保留在本机回执错误码，不进入公共协议。
		r.emitEvent(sessionID, adapter.Event{
			Type: adapter.EventSessionError,
			Payload: map[string]any{
				"instance_id": sessionID,
				"message":     "Provider 发送失败，详情仅限本机诊断。",
			},
		})
		r.emitEvent(sessionID, adapter.Event{
			Type: adapter.EventTurnCompleted,
			Payload: map[string]any{
				"instance_id": sessionID,
				"stop_reason": "send_failed",
			},
		})
		return err
	}
	return nil
}

// abortSession 兑现 session.abort。
func (r *SessionRunner) abortSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.abort 缺少 session_id")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	if err := rs.handle.Abort(ctx); err != nil {
		// Abort 同步失败同样没有 Provider SSE 事件；补发脱敏错误让用户知道中止未生效。
		// 不合成终态：Provider 回合可能仍在进行，伪造 turn_completed 会掩盖真实状态。
		r.emitEvent(sessionID, adapter.Event{
			Type: adapter.EventSessionError,
			Payload: map[string]any{
				"instance_id": sessionID,
				"message":     "Provider 中止失败，详情仅限本机诊断。",
			},
		})
		return err
	}
	return nil
}

// killSession 兑现 session.kill。它只调用拥有本机进程树的 Handle.ForceKill，绝不把远端
// HTTP abort 当作进程清理成功。未声明本机所有权的 Provider 保持 CAPABILITY_UNSUPPORTED。
func (r *SessionRunner) killSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.kill 缺少 session_id")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	killer, ok := rs.handle.(adapter.ForceKillHandle)
	if !ok {
		return fmt.Errorf("%w: session.kill requires owned provider process", ErrUnsupportedCommand)
	}
	if err := killer.ForceKill(ctx); err != nil {
		// 强制终止失败意味着 Provider 进程树可能仍在运行；失败必须进入用户时间线，
		// 而不是只留在命令回执里。Dispose/本地清理失败发生在进程已终止之后，
		// 由回执错误码承载，不再向时间线追加噪音。
		r.emitEvent(sessionID, adapter.Event{
			Type: adapter.EventSessionError,
			Payload: map[string]any{
				"instance_id": sessionID,
				"message":     "Provider 进程终止失败，详情仅限本机诊断。",
			},
		})
		return fmt.Errorf("force kill provider process: %w", err)
	}
	// ForceKill 成功后立即切断事件转发并释放 handle；重复 delivery 在 Relay/local store 收敛，
	// 本地映射同步删除，避免后续 send/resume 错把已终止实例当作仍可用。
	rs.cancel()
	if err := rs.handle.Dispose(ctx); err != nil {
		return fmt.Errorf("dispose killed session handle: %w", err)
	}
	r.removeHandle(sessionID)
	if err := r.store.Delete(instanceKey(sessionID)); err != nil {
		return fmt.Errorf("删除已终止 instance 映射: %w", err)
	}
	if err := r.store.Delete(resumeResultKey(sessionID)); err != nil {
		return fmt.Errorf("删除已终止 resume 结果: %w", err)
	}
	return nil
}

// resumeSession 兑现 session.resume：用本地 instance 映射中的 OpenCode session id
// 调 adapter.Resume，并把结果（六态之一）写入 store；禁止伪造 resumed。
func (r *SessionRunner) resumeSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.resume 缺少 session_id")
	}
	// 实例映射必须已存在；无映射时不得伪造唤醒结果。
	raw, err := r.store.Get(instanceKey(sessionID))
	if err != nil {
		return fmt.Errorf("%w: session=%s", ErrSessionInstanceMissing, sessionID)
	}
	var th providerThread
	if err := json.Unmarshal([]byte(raw), &th); err != nil {
		return fmt.Errorf("instance 映射损坏: %w", err)
	}
	ad, ok := r.adapters[th.Provider]
	if !ok {
		return fmt.Errorf("provider %q 未注册 adapter，保持 fail-closed", th.Provider)
	}
	root := env.WorkspaceRoot
	if root == "" {
		root = th.WorkspaceRoot
	}
	res, err := ad.Resume(ctx, adapter.ResumeRequest{
		InstanceID:    th.InstanceID,
		WorkspaceRoot: root,
	})
	if err != nil {
		return fmt.Errorf("adapter resume: %w", err)
	}
	// 结果必须来自 adapter 且是六态之一；runner 不推断、不伪造（项目文档「统一能力模型」）。
	if !validWakeResult(res.Result) {
		return fmt.Errorf("adapter 返回非法唤醒结果 %q，保持 fail-closed", res.Result)
	}
	resultJSON, err := json.Marshal(res)
	if err != nil {
		return err
	}
	return r.store.Set(resumeResultKey(sessionID), string(resultJSON))
}

// lookupSession 按 sessionID 取运行中的句柄；无实例返回 ErrSessionInstanceMissing。
// 注意：只认本进程存活句柄；daemon 重启后持久化映射仍存在但没有句柄，
// 此时 send/abort 同样 fail-closed（local_state_missing 语义），恢复路径是 session.resume。
func (r *SessionRunner) lookupSession(sessionID string) (*runningSession, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rs, ok := r.handles[sessionID]
	if !ok {
		return nil, fmt.Errorf("%w: session=%s", ErrSessionInstanceMissing, sessionID)
	}
	return rs, nil
}

// removeHandle 删除句柄登记（启动失败回滚用）。
func (r *SessionRunner) removeHandle(sessionID string) {
	r.mu.Lock()
	delete(r.handles, sessionID)
	r.mu.Unlock()
}

// forwardEvents 把 handle 的 canonical 事件写回本地 store（简单记最后一条）。
// 退出路径：fwdCtx 取消（Close/会话回收）或 handle 事件流关闭。
// handle.Dispose 由调用方（startSession 失败路径或 Close）负责，这里只负责停止转发。
func (r *SessionRunner) forwardEvents(sessionID string, h adapter.Handle, fwdCtx context.Context, initial ...adapter.Event) {
	terminalSeen := false
	if len(initial) > 0 && initial[0].Type != "" {
		terminalSeen = initial[0].Type == adapter.EventTurnCompleted
		r.writeEvent(sessionID, 0, initial[0])
	}
	for {
		select {
		case ev, ok := <-h.Events():
			if !ok {
				// A provider-owned event stream closing while the forwarding context is
				// still live is an abnormal interruption (for example, a bridge crash).
				// Emit one canonical terminal marker so Relay/Flutter cannot retain a
				// stale generating state. Intentional Close/kill paths cancel fwdCtx
				// first and must not manufacture a stopped event.
				if fwdCtx.Err() == nil && !terminalSeen {
					r.writeEvent(sessionID, 0, adapter.Event{
						Type: adapter.EventSessionError,
						Payload: map[string]any{
							"instance_id": sessionID,
							"message":     "Provider 事件流已中断，详情仅限本机诊断。",
						},
					})
					r.writeEvent(sessionID, 0, adapter.Event{
						Type: adapter.EventTurnCompleted,
						Payload: map[string]any{
							"instance_id": sessionID,
							"stop_reason": "stopped",
						},
					})
				}
				return
			}
			if ev.Type == adapter.EventTurnStarted {
				// A new busy marker opens a fresh turn; a terminal from a prior
				// turn must not suppress recovery if this one is interrupted.
				terminalSeen = false
			}
			if ev.Type == adapter.EventTurnCompleted {
				terminalSeen = true
			}
			// select 在取消与事件同时就绪时随机选择分支；写入前再校验一次，
			// 保证重复 start 回收旧句柄后仍滞留在旧通道里的事件绝不串入时间线。
			if fwdCtx.Err() != nil {
				return
			}
			r.writeEvent(sessionID, 0, ev)
		case <-fwdCtx.Done():
			return
		}
	}
}

// emitEvent 将 runner 生成的规范化事件交给连接层；连接层负责编码和上传。
func (r *SessionRunner) emitEvent(sessionID string, ev adapter.Event) {
	// sendMessage 生成的 user_message 不经过 Provider handle，因此必须走与
	// forwardEvents 完全相同的记录路径。这样它既不会被摘要遗漏，也不会在
	// Daemon 重启后让序号分配器从落后的 last_event 重新开始。
	r.recordEvent(sessionID, ev)
}

// normalizeEventSeq 将 Provider 提供的序号纳入 runner 的 canonical 序列。
// Provider 序号通常从 1 开始，但不同事件源可能重复、缺失或在 runner 自己的
// user_message 之后回退；此时统一递增，保证正数且不发生 AAD 序号冲突。首次使用
// 某 session 时尽量从本地 last_event 摘要恢复，避免 Daemon 重启后重新从 1 开始。
func (r *SessionRunner) normalizeEventSeq(sessionID string, ev adapter.Event) adapter.Event {
	if strings.TrimSpace(sessionID) == "" {
		// 调用方已在命令入口校验 sessionID；保留一个确定性正数兜底，避免
		// 内部测试/未来调用把 Seq=0 送进生产 encoder。
		if ev.Seq <= 0 {
			ev.Seq = 1
		}
		return ev
	}
	r.eventSeqMu.Lock()
	defer r.eventSeqMu.Unlock()
	if r.eventSeq == nil {
		// Keep zero-value SessionRunner fixtures safe; production constructors
		// initialize this map eagerly, but tests and embedders may use a literal.
		r.eventSeq = make(map[string]int64)
	}
	if r.eventCount == nil {
		r.eventCount = make(map[string]int)
	}
	current, ok := r.eventSeq[sessionID]
	if !ok {
		summary := r.persistedLastEvent(sessionID)
		current = summary.Seq
		r.eventCount[sessionID] = summary.Count
	}
	if ev.Seq > current {
		current = ev.Seq
	} else {
		if current == int64(^uint64(0)>>1) {
			// Sequence exhaustion is unrecoverable; retain the highest valid value
			// rather than wrapping into a negative number rejected by E2EE.
			ev.Seq = current
			return ev
		}
		current++
	}
	r.eventSeq[sessionID] = current
	ev.Seq = current
	return ev
}

// recordEvent 是 Runner 唯一的 canonical event 记录路径：在同一把锁下分配
// 单调序号、递增脱敏计数、写入 last_event 摘要并通知连接层 sink。Provider
// 事件和 Runner 生成的 user_message/EOF 终态都必须经过这里；否则并发路径
// 可能先发出事件、后写旧摘要，导致重启后序号重用。sink 在摘要提交后
// 顺序调用，保证同一 Runner 内观察到的事件顺序与摘要一致。
func (r *SessionRunner) recordEvent(sessionID string, ev adapter.Event) {
	if strings.TrimSpace(sessionID) == "" {
		if ev.Seq <= 0 {
			ev.Seq = 1
		}
		r.notifyEventSink(sessionID, ev)
		return
	}

	r.eventSeqMu.Lock()
	defer r.eventSeqMu.Unlock()
	if r.eventSeq == nil {
		r.eventSeq = make(map[string]int64)
	}
	if r.eventCount == nil {
		r.eventCount = make(map[string]int)
	}
	current, ok := r.eventSeq[sessionID]
	if !ok {
		summary := r.persistedLastEvent(sessionID)
		current = summary.Seq
		r.eventCount[sessionID] = summary.Count
	}
	ev.Seq = nextEventSequence(current, ev.Seq)
	r.eventSeq[sessionID] = ev.Seq
	r.eventCount[sessionID]++
	count := r.eventCount[sessionID]
	r.persistEventSummary(sessionID, lastEvent{Count: count, Type: ev.Type, Seq: ev.Seq})
	r.notifyEventSink(sessionID, ev)
}

// nextEventSequence folds a provider-supplied sequence into the Runner-owned
// canonical sequence. Provider gaps are preserved, while duplicate/late/zero
// values advance by one. Saturation avoids wrapping into a negative sequence.
func nextEventSequence(current, supplied int64) int64 {
	if supplied > current {
		return supplied
	}
	if current == int64(^uint64(0)>>1) {
		return current
	}
	return current + 1
}

func (r *SessionRunner) notifyEventSink(sessionID string, ev adapter.Event) {
	r.eventSinkMu.RLock()
	sink := r.eventSink
	r.eventSinkMu.RUnlock()
	if sink != nil {
		sink(sessionID, ev)
	}
}

func (r *SessionRunner) persistEventSummary(sessionID string, summary lastEvent) {
	if r == nil || r.store == nil || strings.TrimSpace(sessionID) == "" {
		return
	}
	raw, err := json.Marshal(summary)
	if err != nil {
		return
	}
	if err := r.store.Set(eventKey(sessionID), string(raw)); err != nil && r.logger != nil {
		r.logger.Warn("daemon runner persist event", "error", err)
	}
}

func (r *SessionRunner) persistedLastEvent(sessionID string) lastEvent {
	if r == nil || r.store == nil {
		return lastEvent{}
	}
	raw, err := r.store.Get(eventKey(sessionID))
	if err != nil {
		return lastEvent{}
	}
	var summary lastEvent
	if err := json.Unmarshal([]byte(raw), &summary); err != nil {
		return lastEvent{}
	}
	if summary.Seq < 0 {
		summary.Seq = 0
	}
	if summary.Count < 0 {
		summary.Count = 0
	}
	return summary
}

func (r *SessionRunner) persistedEventSeq(sessionID string) int64 {
	return r.persistedLastEvent(sessionID).Seq
}

// writeEvent 写最后一条 canonical 事件；失败只告警，不阻塞命令消费。
func (r *SessionRunner) writeEvent(sessionID string, _ int, ev adapter.Event) {
	r.recordEvent(sessionID, ev)
}

// awaitFirstEvent 等待 handle 事件流的第一条事件；超时或提前关闭视为启动失败。
func (r *SessionRunner) awaitFirstEvent(ctx context.Context, h adapter.Handle) (adapter.Event, error) {
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	select {
	case ev, ok := <-h.Events():
		if !ok {
			return adapter.Event{}, errors.New("handle 事件流提前关闭")
		}
		return ev, nil
	case <-waitCtx.Done():
		return adapter.Event{}, waitCtx.Err()
	}
}

// instanceIDFromEvent 从 turn_started 事件取 OpenCode session id；
// 类型不符或缺失都视为启动失败，禁止猜测 instance id。
func instanceIDFromEvent(ev adapter.Event) (string, error) {
	if ev.Type != adapter.EventTurnStarted {
		return "", fmt.Errorf("首个事件类型 %q，期望 turn_started", ev.Type)
	}
	id, _ := ev.Payload["instance_id"].(string)
	if id == "" {
		return "", errors.New("turn_started 缺少 instance_id")
	}
	return id, nil
}

// validWakeResult 校验唤醒结果必须是六态之一。
func validWakeResult(result string) bool {
	switch result {
	case adapter.WakeResumed, adapter.WakeRestartedWithContext, adapter.WakeUnsupported,
		adapter.WakeLocalStateMissing, adapter.WakeWorkspaceMoved, adapter.WakeTerminalOffline:
		return true
	}
	return false
}

// ---- 命令 payload envelope ----

// commandEnvelope 是 Relay 命令 payload_json 的 fixture envelope。
// 真实密文（无 ciphertext.fixture_payload）不可解时保持 fail-closed。
type commandEnvelope struct {
	Kind          string             `json:"kind"`
	SessionID     string             `json:"session_id"`
	WorkspaceRoot string             `json:"workspace_root"`
	PlanMode      bool               `json:"plan_mode"`
	Provider      string             `json:"provider"`
	Model         string             `json:"model"`
	Effort        string             `json:"effort"`
	Prompt        string             `json:"prompt"`
	Ciphertext    *fixtureCiphertext `json:"ciphertext"`
}

// fixtureCiphertext 是密文 envelope；fixture 场景用 fixture_payload 明文模拟。
type fixtureCiphertext struct {
	FixturePayload *fixturePayload `json:"fixture_payload"`
}

// fixturePayload 是 fixture 场景的明文负载；真实密文不携带此结构。
type fixturePayload struct {
	Message       string `json:"message"`
	Provider      string `json:"provider"`
	Model         string `json:"model"`
	Effort        string `json:"effort"`
	Prompt        string `json:"prompt"`
	Path          string `json:"path"`
	SnapshotToken string `json:"snapshot_token"`
	Offset        int    `json:"offset"`
	Limit         int    `json:"limit"`
}

// parseEnvelope 解析 payload_json；JSON 不合法或 payload 为空时返回错误。
func parseEnvelope(raw string) (*commandEnvelope, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, errors.New("command payload 为空")
	}
	var env commandEnvelope
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		return nil, fmt.Errorf("command payload 解析失败: %w", err)
	}
	return &env, nil
}

func (e *commandEnvelope) kind() string      { return strings.TrimSpace(e.Kind) }
func (e *commandEnvelope) sessionID() string { return strings.TrimSpace(e.SessionID) }

// fixtureMessage 从密文 envelope 取 fixture 消息文本；真实密文不可解时返回错误。
func (e *commandEnvelope) fixtureMessage() (string, error) {
	if e.Ciphertext == nil || e.Ciphertext.FixturePayload == nil {
		return "", errors.New("密文 envelope 无法解密（fixture payload 缺失），保持 fail-closed")
	}
	text := strings.TrimSpace(e.Ciphertext.FixturePayload.Message)
	if text == "" {
		return "", errors.New("fixture payload 缺少 message")
	}
	return text, nil
}

// 以下取值优先取 ciphertext.fixture_payload，缺省回退到顶层字段。
func (e *commandEnvelope) provider() string {
	if e.Ciphertext != nil && e.Ciphertext.FixturePayload != nil && e.Ciphertext.FixturePayload.Provider != "" {
		return e.Ciphertext.FixturePayload.Provider
	}
	return e.Provider
}

func (e *commandEnvelope) model() string {
	if e.Ciphertext != nil && e.Ciphertext.FixturePayload != nil && e.Ciphertext.FixturePayload.Model != "" {
		return e.Ciphertext.FixturePayload.Model
	}
	return e.Model
}

func (e *commandEnvelope) effort() string {
	if e.Ciphertext != nil && e.Ciphertext.FixturePayload != nil && e.Ciphertext.FixturePayload.Effort != "" {
		return e.Ciphertext.FixturePayload.Effort
	}
	return e.Effort
}

func (e *commandEnvelope) prompt() string {
	if e.Ciphertext != nil && e.Ciphertext.FixturePayload != nil && e.Ciphertext.FixturePayload.Prompt != "" {
		return e.Ciphertext.FixturePayload.Prompt
	}
	return e.Prompt
}

// selectModel 兑现 session.model_select：解析模型名并持久化到会话元数据。
// 当前只更新本地 KV store；运行期模型覆盖需要桥侧 session/new 或 sessionUpdate 支持。
func (r *SessionRunner) selectModel(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.model_select 缺少 session_id")
	}
	// 模型名必须与 send 路径的 TrimSpace 语义一致：纯空白选择存储后会在 SetModel
	// 被静默忽略，用户以为已切换实则沿用旧模型，因此入口处直接拒绝。
	model := strings.TrimSpace(env.model())
	if model == "" {
		return errors.New("session.model_select 缺少 model")
	}
	if err := r.store.Set("model:"+sessionID, model); err != nil {
		return fmt.Errorf("持久化模型选择: %w", err)
	}
	return nil
}

// selectEffort 兑现 session.effort_select：解析推理档位并持久化到会话元数据。
// 运行期生效由 send 路径在 EffortOverrideHandle 上应用，和 model_select 保持一致。
func (r *SessionRunner) selectEffort(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.effort_select 缺少 session_id")
	}
	// 空 effort 会被 SetEffort 静默忽略，用户以为已切换实则沿用旧档位，因此入口直接拒绝。
	effort := strings.TrimSpace(env.effort())
	if effort == "" {
		return errors.New("session.effort_select 缺少 effort")
	}
	if err := r.store.Set("effort:"+sessionID, effort); err != nil {
		return fmt.Errorf("持久化推理档位: %w", err)
	}
	return nil
}
