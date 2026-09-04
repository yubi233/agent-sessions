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
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
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

func replayStateKey(sessionID string) string { return instanceKey(sessionID) + ":replay_state" }
func replayCheckpointKey(sessionID string) string {
	return instanceKey(sessionID) + ":replay_checkpoint"
}

const (
	replayPending  = "pending"
	replayLoading  = "loading"
	replayComplete = "complete"
)

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
	// resumeGeneration 用来使旧恢复协程的完成回调失效，避免旧句柄在新一轮恢复后
	// 把 replay 状态错误地写成 complete。
	resumeGeneration map[string]uint64
	// executionMu 把同一 Daemon 的命令兑现串行化。Relay 已有 delivery/idempotency，但这里仍要
	// 防止 start 与 kill 并发改写同一 session 的本地 instance 映射。
	executionMu sync.Mutex

	// eventSink 仅接收 Daemon 本机已规范化事件；是否加密/上传由连接层决定。
	// 未配置 sink 时仍保留本地状态，但绝不伪造 Relay event 成功。
	eventSinkMu sync.RWMutex
	eventSink   func(sessionID string, event adapter.Event)
	// eventSinkResult 供回放路径确认事件已进入本机 outbox；普通 sink 仍保留旧的
	// 无返回值形状，避免 fixture/嵌入方被迫改接口。
	eventSinkResult func(sessionID string, event adapter.Event) error

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
		store:            store,
		adapters:         adapters,
		logger:           logger,
		handles:          map[string]*runningSession{},
		resumeGeneration: map[string]uint64{},
		eventSeq:         map[string]int64{},
		eventCount:       map[string]int{},
		rootCtx:          ctx,
		rootCancel:       cancel,
	}
}

// SetEventSink 设置 canonical event 的本机出口。连接层必须先把正文编码为密文 envelope，
// 再进入 Relay outbox；runner 不持有账户密钥，也不直接发 HTTP。
// RegisterAdapter 运行期补注册 provider adapter（feature flag 灰度接入用）。
// 同名 provider 覆盖旧注册；调用须在 ConsumeCommand 之前。
func (r *SessionRunner) RegisterAdapter(provider string, ad adapter.Adapter) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.adapters == nil {
		r.adapters = make(map[string]adapter.Adapter)
	}
	r.adapters[provider] = ad
}

func (r *SessionRunner) SetEventSink(sink func(sessionID string, event adapter.Event)) {
	r.eventSinkMu.Lock()
	defer r.eventSinkMu.Unlock()
	r.eventSink = sink
	r.eventSinkResult = nil
}

// SetEventSinkResult 设置带提交结果的事件出口。回放事件只有在该出口返回成功后
// 才会推进 checkpoint；普通事件仍可通过 SetEventSink 使用旧的无返回值出口。
func (r *SessionRunner) SetEventSinkResult(sink func(sessionID string, event adapter.Event) error) {
	r.eventSinkMu.Lock()
	defer r.eventSinkMu.Unlock()
	r.eventSink = nil
	r.eventSinkResult = sink
}

// ConsumeCommand 消费 outbox 中的一条 Relay 命令。
// kind 以 cmd.Kind 为准；payload_json 也可能携带 kind（Relay 命令体），作为兜底来源。
func (r *SessionRunner) ConsumeCommand(ctx context.Context, cmd Command) error {
	// Abort 必须能在一个长时间 Send 回合期间抢占执行；其 handle 自身负责
	// serializing provider cancel，而 runner 的生命周期映射仍由 mu 保护。
	if commandKind(cmd) == "session.abort" {
		return r.abortSession(ctx, cmd)
	}
	r.executionMu.Lock()
	defer r.executionMu.Unlock()
	kind := commandKind(cmd)
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
	case "permission.respond", "permission.approve", "permission.reject":
		// v0.8.2 P1：移动端审批命令经 Relay 透传到 daemon（协议枚举 permission.respond
		// 与移动端 permission.approve/reject kind 同义）。runner 把一次性决策
		// 注入 handle 的 pending permission registry，回写桥原始 JSON-RPC 请求。
		return r.respondPermission(ctx, cmd)
	case "mode.set":
		// v0.8.3 P3：权限 mode 运行期切换（bridge session/set_mode 原子 bundle）。
		return r.setMode(ctx, cmd)
	case "question.answer":
		// v0.8.3 P3：桥 dsh/question/request 的一次性回答回流。
		return r.answerQuestion(ctx, cmd)
	case "plan.action", "goal.action", "skill.invoke":
		// v0.8.3 P3：plan/goal/skill 的受控扩展动作（统一 dsh/* 分发通道）。
		return r.extensionAction(ctx, cmd)
	case "session.stop":
		// v0.8.3 P3：graceful close（可恢复；与 kill/abort 状态机分离）。
		return r.stopSession(ctx, cmd)
	case "session.delete":
		// v0.8.3 P3：冷会话墓碑删除（桥侧审计先行）。
		return r.deleteSession(ctx, cmd)
	case "session.fork":
		// v0.8.3 P3：committed 前缀 fork（新会话身份）。
		return r.forkSession(ctx, cmd)
	default:
		// 未实现 kind 保持 fail-closed：不写任何成功状态（项目文档「统一能力模型」）。
		return fmt.Errorf("%w: kind=%s", ErrUnsupportedCommand, kind)
	}
}

func commandKind(cmd Command) string {
	if cmd.Kind != "" {
		return cmd.Kind
	}
	if env, err := parseEnvelope(cmd.PayloadJSON); err == nil {
		return env.kind()
	}
	return ""
}

// Close 停止全部事件转发 goroutine 并回收所有存活 handle（幂等）。
func (r *SessionRunner) Close(ctx context.Context) error {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	handles := r.handles
	r.handles = map[string]*runningSession{}
	// 清空代数表会使尚未退出的旧回放回调无法再提交 complete。
	r.resumeGeneration = map[string]uint64{}
	r.mu.Unlock()
	for _, rs := range handles {
		rs.cancel()
		_ = rs.handle.Dispose(ctx)
	}
	if r.rootCancel != nil {
		r.rootCancel()
	}
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
	if r.handles == nil {
		r.handles = make(map[string]*runningSession)
	}
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
	parent := r.rootCtx
	if parent == nil {
		parent = context.Background()
	}
	fwdCtx, cancel := context.WithCancel(parent)
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
		// 查无实例（如 Daemon 重启后本地映射丢失、客户端未先 session.start）同样
		// 不会产生任何 Provider 事件。与下方 handle.Send 同步失败保持同一条用户
		// 可见语义：先落 user_message，再补发脱敏错误与失败终态；否则时间线里的
		// 消息之后没有任何失败痕迹，客户端会无限停留在生成中。传输细节只保留在
		// 命令回执错误码（local_state_missing），不进入公共协议。
		r.emitEvent(sessionID, adapter.Event{
			Type: adapter.EventUserMessage,
			Payload: map[string]any{
				"instance_id": sessionID,
				"text":        text,
			},
		})
		r.emitEvent(sessionID, adapter.Event{
			Type: adapter.EventSessionError,
			Payload: map[string]any{
				"instance_id": sessionID,
				"message":     "本机会话尚未启动，消息未送达 Provider；请先启动会话。",
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
	// prompt 是用户时间线消息的规范来源；在调用 Provider 前先写入，避免模型回合
	// 较慢时用户看不到刚发送的消息。
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
	// v0.8.3 P3 混合内容：send 密文携带 images 时走 ContentHandle.SendContent
	//（文本 + 图像块同批进入 ACP prompt；图像字节只经内存，明文不写日志/事件）。
	// 无图像保持既有纯文本 Send 路径不变。图像解码失败与桥 admission 拒绝
	// （text-only overlay / 缺 attachment 服务 / 模型不支持）都走同一条
	// session_error + turn_completed 失败收口，客户端不悬挂在生成中。
	if env.Ciphertext != nil && env.Ciphertext.FixturePayload != nil && len(env.Ciphertext.FixturePayload.Images) > 0 {
		blocks := make([]adapter.ContentBlock, 0, len(env.Ciphertext.FixturePayload.Images)+1)
		if text != "" {
			blocks = append(blocks, adapter.ContentBlock{Type: "text", Text: text})
		}
		for i, img := range env.Ciphertext.FixturePayload.Images {
			data, decodeErr := base64.StdEncoding.DecodeString(img.DataB64)
			if decodeErr != nil {
				return fmt.Errorf("session.send 图像块 %d base64 解码失败: %w", i, decodeErr)
			}
			blocks = append(blocks, adapter.ContentBlock{Type: "image", ImageData: data, ImageMIME: img.MIME})
		}
		contentHandle, ok := rs.handle.(adapter.ContentHandle)
		if !ok {
			return fmt.Errorf("%w: 会话 %s 的 handle 不支持混合内容发送", ErrUnsupportedCommand, sessionID)
		}
		if err := contentHandle.SendContent(ctx, blocks); err != nil {
			r.emitEvent(sessionID, adapter.Event{
				Type: adapter.EventSessionError,
				Payload: map[string]any{
					"instance_id": sessionID,
					"message":     "图像消息发送失败，详情仅限本机诊断。",
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
	// Abort 成功只表示 Provider 已接受取消请求；Provider 后续的 cancelled
	// turn_completed 仍负责最终状态收口，不能在这里伪造第二条终态。
	r.emitEvent(sessionID, adapter.Event{
		Type: adapter.EventSessionAborted,
		Payload: map[string]any{
			"instance_id": sessionID,
		},
	})
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

// resumeSession 兑现 session.resume：用本地 instance 映射中的 Provider session id
// 调 adapter.Resume，并把结果（六态之一）写入 store；支持流式 Adapter 时先登记
// 新句柄并转发事件，再由 Adapter 发出 session/load 或 session/resume。
func (r *SessionRunner) resumeSession(ctx context.Context, cmd Command) error {
	if r == nil || r.store == nil {
		return errors.New("daemon 本地状态存储不可用")
	}
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
	root = strings.TrimSpace(root)
	if root == "" {
		return fmt.Errorf("session.resume 缺少 workspace root")
	}
	// persisted cwd 与调用方工作区不一致时，不能把路径移动当作同一会话继续。
	if th.WorkspaceRoot != "" && workspaceRootsDiffer(th.WorkspaceRoot, root) {
		// 同一进程内若仍有旧工作区句柄，也必须先撤销并回收，避免旧 cwd
		// 的事件继续写入新工作区时间线；重启后的无句柄情况自然跳过。
		r.mu.Lock()
		movedHandle := r.handles[sessionID]
		delete(r.handles, sessionID)
		r.mu.Unlock()
		if movedHandle != nil {
			movedHandle.cancel()
			_ = movedHandle.handle.Dispose(context.Background())
		}
		res := adapter.ResumeResult{Result: adapter.WakeWorkspaceMoved, InstanceID: th.InstanceID}
		resultJSON, _ := json.Marshal(res)
		_ = r.store.Set(resumeResultKey(sessionID), string(resultJSON))
		return nil
	}
	replay := true
	if state, stateErr := r.store.Get(replayStateKey(sessionID)); stateErr == nil && strings.TrimSpace(state) == replayComplete {
		replay = false
	}
	// 每次恢复都分配新的代数；旧句柄即使在取消后晚到完成信号，也不能改写本轮状态。
	resumeGeneration := r.beginResumeGeneration(sessionID)
	req := adapter.ResumeRequest{
		InstanceID:    th.InstanceID,
		WorkspaceRoot: root,
		ReplayHistory: replay,
	}
	var registered *runningSession
	var replayDone <-chan struct{}
	ready := func(handle adapter.Handle) error {
		if handle == nil {
			return errors.New("resume ready callback 收到空句柄")
		}
		parent := r.rootCtx
		if parent == nil {
			parent = context.Background()
		}
		fwdCtx, cancel := context.WithCancel(parent)
		registered = &runningSession{handle: handle, cancel: cancel}
		// 先登记，再启动 forwardEvents；Adapter 只有在 callback 返回后才发送
		// load/resume，因此回放通知不会落在无人消费的窗口内。
		r.mu.Lock()
		if r.handles == nil {
			r.handles = make(map[string]*runningSession)
		}
		var old *runningSession
		if old = r.handles[sessionID]; old != nil {
			old.cancel()
		}
		r.handles[sessionID] = registered
		r.mu.Unlock()
		if old != nil {
			_ = old.handle.Dispose(context.Background())
		}
		if replay {
			if completion, ok := handle.(adapter.ReplayCompletionHandle); ok {
				replayDone = completion.ReplayComplete()
			}
		}
		go r.forwardEventsWithReplay(sessionID, handle, fwdCtx, replayDone, func() {
			r.markReplayCompleteForGeneration(sessionID, resumeGeneration)
		})
		return nil
	}
	if replay {
		if err := r.setReplayState(sessionID, replayLoading); err != nil {
			return fmt.Errorf("记录 replay loading 状态: %w", err)
		}
	}
	var res adapter.ResumeResult
	streaming, isStreaming := ad.(adapter.ResumeStreamingAdapter)
	if isStreaming {
		res, err = streaming.ResumeStreaming(ctx, req, ready)
	} else {
		// 旧 Adapter 无法交出 runtime handle，只保留原有结果语义；若本进程
		// 没有存活句柄，resumed 仍不会让后续 send 虚构可用实例。
		res, err = ad.Resume(ctx, req)
	}
	if err != nil {
		if registered != nil {
			registered.cancel()
			_ = registered.handle.Dispose(context.Background())
			r.removeHandle(sessionID)
		}
		r.resetReplayStateAfterFailure(sessionID, replay)
		return fmt.Errorf("adapter resume: %w", err)
	}
	// 结果必须来自 adapter 且是六态之一；runner 不推断、不伪造（项目文档「统一能力模型」）。
	if !validWakeResult(res.Result) {
		if registered != nil {
			registered.cancel()
			_ = registered.handle.Dispose(context.Background())
			r.removeHandle(sessionID)
		}
		r.resetReplayStateAfterFailure(sessionID, replay)
		return fmt.Errorf("adapter 返回非法唤醒结果 %q，保持 fail-closed", res.Result)
	}
	if res.Result == adapter.WakeResumed {
		// 流式恢复必须在 RPC 返回前交出新句柄；否则结果看似成功，后续 send
		// 却只能落到不存在的本机实例。旧式 Adapter 则至少必须保留可用旧句柄。
		if isStreaming && registered == nil {
			r.resetReplayStateAfterFailure(sessionID, replay)
			return fmt.Errorf("adapter resume 成功但未交接句柄，保持 fail-closed")
		}
		if !isStreaming {
			if _, lookupErr := r.lookupSession(sessionID); lookupErr != nil {
				r.resetReplayStateAfterFailure(sessionID, replay)
				return fmt.Errorf("adapter resume 成功但本机没有可用句柄，保持 fail-closed: %w", lookupErr)
			}
		}
	}
	if res.Result != adapter.WakeResumed && registered != nil {
		registered.cancel()
		_ = registered.handle.Dispose(context.Background())
		r.removeHandle(sessionID)
	}
	if res.Result != adapter.WakeResumed {
		r.resetReplayStateAfterFailure(sessionID, replay)
	}
	resultJSON, err := json.Marshal(res)
	if err != nil {
		r.resetReplayStateAfterFailure(sessionID, replay)
		return err
	}
	if err := r.store.Set(resumeResultKey(sessionID), string(resultJSON)); err != nil {
		r.resetReplayStateAfterFailure(sessionID, replay)
		return err
	}
	if res.Result == adapter.WakeResumed && replay && replayDone == nil {
		// 旧版流式适配器没有提供回放完成信号，只能把 RPC 响应作为完成边界；
		// DSH 适配器实现了 ReplayCompletionHandle，会等待事件转发后再标记。
		if err := r.store.Set(replayStateKey(sessionID), replayComplete); err != nil {
			r.resetReplayStateAfterFailure(sessionID, replay)
			return fmt.Errorf("记录 replay complete 状态: %w", err)
		}
	}
	return nil
}

// workspaceRootsDiffer 比较两个工作区的 canonical 路径；任一目录已被移动/删除时，
// 退回绝对规范字符串，仍能把“旧路径 vs 新路径”分类为 workspace_moved，而不是把
// 文件不存在误报成普通 Provider 错误。两边都可 realpath 时优先采用 realpath，兼容
// macOS 的符号链接别名。
func workspaceRootsDiffer(stored, current string) bool {
	stored = comparableWorkspacePath(stored)
	current = comparableWorkspacePath(current)
	return stored != "" && current != "" && stored != current
}

func comparableWorkspacePath(root string) string {
	root = strings.TrimSpace(root)
	if root == "" {
		return ""
	}
	if canonical, err := filepath.EvalSymlinks(root); err == nil {
		root = canonical
	}
	if absolute, err := filepath.Abs(root); err == nil {
		root = absolute
	}
	return filepath.Clean(root)
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
	r.forwardEventsWithReplay(sessionID, h, fwdCtx, nil, nil, initial...)
}

// forwardEventsWithReplay 转发事件，并在提供方宣布 load 响应完成后排空历史队列。
// 回放状态只有在排空并写入本机摘要后才会变成 complete；后续实时事件仍继续转发。
func (r *SessionRunner) forwardEventsWithReplay(sessionID string, h adapter.Handle, fwdCtx context.Context, replayDone <-chan struct{}, onReplayComplete func(), initial ...adapter.Event) {
	terminalSeen := false
	replaySignal := replayDone
	replayMarked := replaySignal == nil
	completeReplay := func() {
		if replayMarked {
			return
		}
		replayMarked = true
		if onReplayComplete != nil {
			onReplayComplete()
		}
	}
	processEvent := func(ev adapter.Event) bool {
		if ev.Type == adapter.EventTurnStarted {
			// 新的忙碌标记开启新回合；上一回合的终态不能抑制本回合中断告警。
			terminalSeen = false
		}
		if ev.Type == adapter.EventTurnCompleted {
			terminalSeen = true
		}
		// 取消和事件同时就绪时，写入前再次检查上下文，避免旧句柄事件串入时间线。
		if fwdCtx.Err() != nil {
			return false
		}
		if ev.ReplayOrdinal > 0 {
			// 回放帧没有稳定消息 ID；本机确定性序号用于重试去重，不暴露 DSH ID。
			if r.replayCommitted(sessionID, ev.ReplayOrdinal) {
				return true
			}
		}
		if ev.ReplayOrdinal > 0 {
			if err := r.writeEventResult(sessionID, ev); err != nil {
				if r.logger != nil {
					r.logger.Warn("回放事件未提交到本机出口", "session_id", sessionID, "error", err)
				}
				return false
			}
		} else {
			r.writeEvent(sessionID, 0, ev)
		}
		if ev.ReplayOrdinal > 0 {
			if err := r.markReplayCommitted(sessionID, ev.ReplayOrdinal); err != nil {
				if r.logger != nil {
					r.logger.Warn("回放 checkpoint 未提交", "session_id", sessionID, "error", err)
				}
				return false
			}
		}
		return true
	}
	if len(initial) > 0 && initial[0].Type != "" {
		terminalSeen = initial[0].Type == adapter.EventTurnCompleted
		// startSession 已经在等待事件时确认了这条首帧；即使随后马上被
		// 重复 start 回收，也要保留这条已确认的会话开始事件。
		r.writeEvent(sessionID, 0, initial[0])
	}
	for {
		if replaySignal != nil {
			select {
			case <-replaySignal:
				replaySignal = nil
				// load 响应到达前的历史帧已全部进入 events；在 complete 前
				// 非阻塞排空，保证慢消费者也不会被过早标记为 complete。
				for {
					select {
					case ev, ok := <-h.Events():
						if !ok {
							// 已收到 load 完成信号但事件流随即关闭时，队列中的历史
							// 已排空，可以安全完成本轮回放；未收到信号的关闭会在
							// 外层分支直接返回并保留 loading/pending。
							completeReplay()
							return
						}
						if !processEvent(ev) {
							return
						}
					default:
						completeReplay()
						goto replayDrained
					}
				}
			default:
			}
		}
	replayDrained:
		select {
		case ev, ok := <-h.Events():
			if !ok {
				// 提供方事件流仍在运行时却提前关闭，视为异常中断；补一条终态，
				// 防止客户端永久停留在生成中。主动关闭/强杀会先取消上下文，不补造终态。
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
			if !processEvent(ev) {
				return
			}
		case <-fwdCtx.Done():
			return
		case <-replaySignal:
			// 下一轮会先消费回放完成信号并排空事件队列。
		}
	}
}

func (r *SessionRunner) markReplayComplete(sessionID string) {
	if r == nil || r.store == nil {
		return
	}
	if err := r.setReplayState(sessionID, replayComplete); err != nil && r.logger != nil {
		r.logger.Warn("记录 replay complete 状态失败", "error", err)
	}
}

// beginResumeGeneration 为一次恢复分配单调代数。代数只保存在本机内存，不进入 Relay 或
// 事件载荷；它仅用于屏蔽被替换句柄的迟到回调。
func (r *SessionRunner) beginResumeGeneration(sessionID string) uint64 {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.resumeGeneration == nil {
		r.resumeGeneration = make(map[string]uint64)
	}
	r.resumeGeneration[sessionID]++
	return r.resumeGeneration[sessionID]
}

// markReplayCompleteForGeneration 仅允许当前恢复代数推进 complete，避免旧回放协程覆盖
// 新一轮恢复的 pending/loading 状态。
func (r *SessionRunner) markReplayCompleteForGeneration(sessionID string, generation uint64) {
	if r == nil || r.store == nil {
		return
	}
	r.mu.Lock()
	current, ok := r.resumeGeneration[sessionID]
	if !ok || current != generation {
		r.mu.Unlock()
		return
	}
	// 在同一把锁内完成校验和写入，避免新一轮恢复在校验后抢先
	// 设置 loading，随后又被旧协程的 complete 覆盖。
	err := r.setReplayState(sessionID, replayComplete)
	r.mu.Unlock()
	if err != nil && r.logger != nil {
		r.logger.Warn("记录 replay complete 状态失败", "error", err)
	}
}

// setReplayState 写入并校验本机回放状态，避免出现无法被下一次恢复解释的任意字符串。
func (r *SessionRunner) setReplayState(sessionID, state string) error {
	if r == nil || r.store == nil {
		return errors.New("daemon 本地状态存储不可用")
	}
	switch state {
	case replayPending, replayLoading, replayComplete:
	default:
		return fmt.Errorf("非法 replay 状态 %q", state)
	}
	return r.store.Set(replayStateKey(sessionID), state)
}

// resetReplayStateAfterFailure 只有本轮确实尝试了回放时才回写 pending；已经 complete 的
// session/resume 失败不应被误降级为 load，否则下一次恢复会重复投递整段历史。
func (r *SessionRunner) resetReplayStateAfterFailure(sessionID string, replay bool) {
	if !replay || r == nil || r.store == nil {
		return
	}
	if err := r.setReplayState(sessionID, replayPending); err != nil && r.logger != nil {
		r.logger.Warn("恢复失败后回写 replay pending 状态失败", "error", err)
	}
}

func replaySourceKey(sessionID string, ordinal int64) string {
	hash := sha256.Sum256([]byte("dsh-replay-v1\x00" + sessionID + "\x00" + fmt.Sprint(ordinal)))
	return hex.EncodeToString(hash[:])
}

func replayCommittedKey(sessionID string, ordinal int64) string {
	return instanceKey(sessionID) + ":replay:" + replaySourceKey(sessionID, ordinal)
}

func (r *SessionRunner) replayCommitted(sessionID string, ordinal int64) bool {
	if r == nil || r.store == nil {
		return false
	}
	_, err := r.store.Get(replayCommittedKey(sessionID, ordinal))
	return err == nil
}

func (r *SessionRunner) markReplayCommitted(sessionID string, ordinal int64) error {
	if r == nil || r.store == nil {
		return errors.New("daemon 本地状态存储不可用")
	}
	if err := r.store.Set(replayCommittedKey(sessionID, ordinal), "1"); err != nil {
		return err
	}
	checkpoint := ordinal
	if raw, err := r.store.Get(replayCheckpointKey(sessionID)); err == nil {
		if parsed, parseErr := strconv.ParseInt(raw, 10, 64); parseErr == nil && parsed > checkpoint {
			checkpoint = parsed
		}
	}
	return r.store.Set(replayCheckpointKey(sessionID), fmt.Sprint(checkpoint))
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
		// 保证零值 SessionRunner fixture 也可用；生产构造函数会主动初始化该映射，
		// 但测试和嵌入方可能直接使用结构体字面量。
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
			// 序号耗尽后无法恢复；保留最高合法值，不能回绕成会被 E2EE 拒绝的负数。
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
	_ = r.recordEventResult(sessionID, ev)
}

// recordEventResult 与 recordEvent 相同，但把事件出口的提交错误返回给回放调用方。
func (r *SessionRunner) recordEventResult(sessionID string, ev adapter.Event) error {
	if ev.CreatedAtUnixMS <= 0 {
		ev.CreatedAtUnixMS = time.Now().UnixMilli()
	}
	if strings.TrimSpace(sessionID) == "" {
		if ev.Seq <= 0 {
			ev.Seq = 1
		}
		return r.notifyEventSinkResult(sessionID, ev)
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
	return r.notifyEventSinkResult(sessionID, ev)
}

// nextEventSequence 将 Provider 提供的序号折叠进 Runner 持有的规范序列。
// Provider 的间隔会保留，重复、过晚或零值则递增一位；饱和处理避免回绕成负数。
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
	_ = r.notifyEventSinkResult(sessionID, ev)
}

func (r *SessionRunner) notifyEventSinkResult(sessionID string, ev adapter.Event) error {
	r.eventSinkMu.RLock()
	sink := r.eventSink
	resultSink := r.eventSinkResult
	r.eventSinkMu.RUnlock()
	if resultSink != nil {
		return resultSink(sessionID, ev)
	}
	if sink != nil {
		sink(sessionID, ev)
	}
	return nil
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

func (r *SessionRunner) writeEventResult(sessionID string, ev adapter.Event) error {
	return r.recordEventResult(sessionID, ev)
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
// fixtureImage 是 session.send 混合内容中的一张图像（v0.8.3 P3）。
// DataB64 是标准 base64 编码的图像字节；MIME 必须在桥 admission 白名单内
// （image/png|jpeg|webp|gif），由 adapter SendContent 与桥共同校验。
type fixtureImage struct {
	DataB64 string `json:"data_b64"`
	MIME    string `json:"mime"`
}

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
	// RequestID 是 permission 审批命令携带的权限请求关联键（=桥 toolCallId），
	// 移动端 permission.approve/reject 的 ciphertext 只带 request_id。
	// v0.8.3 P3 起也被 question.answer 用作 question 请求关联键。
	RequestID string `json:"request_id"`
	// ModeID 是 mode.set 命令的目标权限 mode（桥广告目录内的一项）。
	ModeID string `json:"mode_id"`
	// Answers 是 question.answer 的回答批次原文（wire 契约白名单形状）。
	Answers json.RawMessage `json:"answers"`
	// Operation 是 goal.action 的显式操作（create/edit/pause/resume/complete/clear/get）。
	Operation string `json:"operation"`
	// Text 是 goal.action create/edit 携带的目标文本。
	Text string `json:"text"`
	// ExpectedRevision 是 goal.action 的 CAS 期望版本（缺省不校验）。
	ExpectedRevision *int64 `json:"expected_revision"`
	// Active 是 plan.action set_mode 的目标状态。
	Active *bool `json:"active"`
	// Name 是 skill.invoke 的 skill 名称（须在已广播目录且 userInvocable）。
	Name string `json:"name"`
	// CatalogRevision 是 skill.invoke 引用的目录摘要版本。
	CatalogRevision string `json:"catalog_revision"`
	// CWD 是 session.fork 的新工作区根。
	ForkCWD string `json:"fork_cwd"`
	// ChildSessionID 是 Relay fork API（POST /v1/sessions/:id/forks）生成的
	// 子 Relay 会话 ID；daemon fork 成功后把新 provider sessionId 绑定为子会话实例。
	ChildSessionID string `json:"child_session_id"`
	// Images 是 session.send 携带的图像块（fixture 形状：base64 数据 + MIME）。
	// Daemon 在本机把图像字节转成 ACP image 块；明文只经内存，不写日志/事件。
	Images []fixtureImage `json:"images"`
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

// setMode 兑现 mode.set（v0.8.3 P3 B-1）：把运行期权限 mode 切换注入会话
// handle 的 SessionModeHandle（桥 session/set_mode 原子 bundle 切换）。
// 目录外 mode 由桥拒绝；无运行 handle 或 handle 不支持时 fail-closed。
func (r *SessionRunner) setMode(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("mode.set 缺少 session_id")
	}
	modeID := ""
	if env.Ciphertext != nil && env.Ciphertext.FixturePayload != nil {
		modeID = strings.TrimSpace(env.Ciphertext.FixturePayload.ModeID)
	}
	if modeID == "" {
		return errors.New("mode.set 缺少 mode_id")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	modeHandle, ok := rs.handle.(adapter.SessionModeHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持权限 mode 切换", ErrUnsupportedCommand, sessionID)
	}
	if err := modeHandle.SetMode(ctx, modeID); err != nil {
		return fmt.Errorf("权限 mode 切换失败: %w", err)
	}
	// mode 状态的客户端可见性走 set_mode 命令回执与能力矩阵目录；mode 不是
	// 错误也不是 canonical 事件，不伪造事件流流量。
	return nil
}

// answerQuestion 兑现 question.answer（v0.8.3 P3 B-5）：把一次性回答注入
// handle 的 QuestionAnswerHandle，由其回写桥的原始 dsh/question/request。
// 未知/重复 requestKey 由 handle 侧 fail-closed（与 permission one-shot 同口径）。
func (r *SessionRunner) answerQuestion(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("question.answer 缺少 session_id")
	}
	requestID := ""
	var answers []adapter.QuestionAnswerItem
	if env.Ciphertext != nil && env.Ciphertext.FixturePayload != nil {
		requestID = strings.TrimSpace(env.Ciphertext.FixturePayload.RequestID)
		if len(env.Ciphertext.FixturePayload.Answers) > 0 {
			if err := json.Unmarshal(env.Ciphertext.FixturePayload.Answers, &answers); err != nil {
				return fmt.Errorf("question.answer 回答批次解析失败: %w", err)
			}
		}
	}
	if requestID == "" {
		return errors.New("question.answer 缺少 request_id")
	}
	if len(answers) == 0 {
		return errors.New("question.answer 回答批次为空")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	qh, ok := rs.handle.(adapter.QuestionAnswerHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持 question 回答回流", ErrUnsupportedCommand, sessionID)
	}
	return qh.ResolveQuestion(requestID, answers)
}

// extensionAction 兑现 plan.action / goal.action / skill.invoke（v0.8.3 P3）：
// 统一经 handle 的 ExtensionDispatchHandle 分发到冻结的 dsh/* 扩展方法；
// method/参数形状由 adapter 侧 P0 wire 契约校验，runner 只做 kind → method 映射。
func (r *SessionRunner) extensionAction(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return fmt.Errorf("%s 缺少 session_id", cmd.Kind)
	}
	fp := env.Ciphertext.FixturePayload
	if env.Ciphertext == nil || fp == nil {
		return fmt.Errorf("%s 缺少 ciphertext/fixture 载荷", cmd.Kind)
	}
	var method string
	params := map[string]any{}
	switch cmd.Kind {
	case "plan.action":
		if fp.Active == nil {
			return errors.New("plan.action 缺少 active")
		}
		method = adapter.ExtensionMethodPlanSetMode
		params["active"] = *fp.Active
	case "goal.action":
		operation := strings.TrimSpace(fp.Operation)
		if operation == "" {
			return errors.New("goal.action 缺少 operation")
		}
		if operation == "get" {
			method = adapter.ExtensionMethodGoalGet
		} else {
			method = adapter.ExtensionMethodGoalMutate
			params["operation"] = operation
			if strings.TrimSpace(fp.Text) != "" {
				params["text"] = fp.Text
			}
			if fp.ExpectedRevision != nil {
				params["expectedRevision"] = *fp.ExpectedRevision
			}
		}
	case "skill.invoke":
		name := strings.TrimSpace(fp.Name)
		if name == "" {
			return errors.New("skill.invoke 缺少 name")
		}
		method = adapter.ExtensionMethodSkillInvoke
		params["requestId"] = cmd.RequestID
		params["name"] = name
		params["catalogRevision"] = strings.TrimSpace(fp.CatalogRevision)
	default:
		return fmt.Errorf("%w: kind=%s", ErrUnsupportedCommand, cmd.Kind)
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	ext, ok := rs.handle.(adapter.ExtensionDispatchHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持 dsh/* 扩展分发", ErrUnsupportedCommand, sessionID)
	}
	if _, err := ext.CallExtension(ctx, method, params); err != nil {
		// 桥的稳定错误码（stale_revision/invalid_payload 等）保留在错误链里，
		// 让命令回执能区分业务拒绝与基础设施失败。
		return fmt.Errorf("dsh 扩展动作 %s 失败: %w", method, err)
	}
	return nil
}

// stopSession 兑现 session.stop（v0.8.3 P3 B-3）：graceful close——取消当前
// turn、桥侧 close（可恢复），随后回收本机桥进程与 handle 登记。
// 与 session.kill 的强杀状态机分离：这里不清 instance 映射（会话可恢复），
// 只移除运行句柄；后续 resume 走既有 Resume 流程重建。
func (r *SessionRunner) stopSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.stop 缺少 session_id")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	lifecycle, ok := rs.handle.(adapter.SessionLifecycleHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持 graceful close", ErrUnsupportedCommand, sessionID)
	}
	if err := lifecycle.CloseSession(ctx); err != nil {
		return fmt.Errorf("graceful close 失败: %w", err)
	}
	rs.cancel()
	if err := rs.handle.Dispose(ctx); err != nil {
		return fmt.Errorf("dispose closed session handle: %w", err)
	}
	r.removeHandle(sessionID)
	return nil
}

// deleteSession 兑现 session.delete（v0.8.3 P3 B-3）：冷会话墓碑删除。
// 冷状态判定在桥（运行中/未知会话拒绝），daemon 只透传并保持幂等回执。
func (r *SessionRunner) deleteSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.delete 缺少 session_id")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	lifecycle, ok := rs.handle.(adapter.SessionLifecycleHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持会话删除", ErrUnsupportedCommand, sessionID)
	}
	if err := lifecycle.DeleteSession(ctx); err != nil {
		return fmt.Errorf("session 删除失败: %w", err)
	}
	// 删除成功后回收运行句柄（若仍在）：被删会话不再接受任何命令。
	rs.cancel()
	_ = rs.handle.Dispose(ctx)
	r.removeHandle(sessionID)
	return nil
}

// forkSession 兑现 session.fork（v0.8.3 P3 B-3）：committed 前缀复制到新会话。
// 两种入口形状：
//  1. Relay fork API（POST /v1/sessions/:id/forks）：ciphertext 携带
//     child_session_id（Relay 已创建的子 Relay 会话）。fork 成功后把新 provider
//     sessionId 绑定为子会话实例映射（instance:<childSessionID>），子会话随即
//     可按既有 resume 链路恢复——不产生孤儿 Relay 会话。
//  2. 直连/fixture：fork_cwd 显式提供工作区根。
//
// fork 结果同时写入本机 store（fork:<parentSessionID>）供诊断；回执只含状态。
func (r *SessionRunner) forkSession(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("session.fork 缺少 session_id")
	}
	childSessionID := ""
	forkCWD := ""
	if env.Ciphertext != nil && env.Ciphertext.FixturePayload != nil {
		childSessionID = strings.TrimSpace(env.Ciphertext.FixturePayload.ChildSessionID)
		forkCWD = strings.TrimSpace(env.Ciphertext.FixturePayload.ForkCWD)
	}
	// 父会话实例映射：fork 的工作区根与 provider 必须与父会话一致（同一 workspace
	// 语义），不能由命令载荷自由指定第二套授权真相。
	raw, err := r.store.Get(instanceKey(sessionID))
	if err != nil {
		return fmt.Errorf("%w: session=%s", ErrSessionInstanceMissing, sessionID)
	}
	var th providerThread
	if err := json.Unmarshal([]byte(raw), &th); err != nil {
		return fmt.Errorf("instance 映射损坏: %w", err)
	}
	if forkCWD == "" {
		forkCWD = th.WorkspaceRoot
	}
	if forkCWD == "" {
		return errors.New("session.fork 缺少 fork_cwd 且父会话无工作区根")
	}
	rs, err := r.lookupSession(sessionID)
	if err != nil {
		return err
	}
	lifecycle, ok := rs.handle.(adapter.SessionLifecycleHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持会话 fork", ErrUnsupportedCommand, sessionID)
	}
	newSessionID, err := lifecycle.ForkSession(ctx, forkCWD)
	if err != nil {
		return fmt.Errorf("session fork 失败: %w", err)
	}
	if err := r.store.Set("fork:"+sessionID, newSessionID); err != nil {
		return fmt.Errorf("记录 fork 结果: %w", err)
	}
	// Relay 子会话绑定：新 provider sessionId 成为子 Relay 会话的实例，
	// 子会话从 committed 前缀继续（resume 走既有链路）。无 child_session_id
	// 的直连/fixture 调用跳过绑定，不留悬空映射。
	if childSessionID != "" {
		binding, err := json.Marshal(providerThread{
			Provider: th.Provider, InstanceID: newSessionID, WorkspaceRoot: forkCWD,
		})
		if err != nil {
			return fmt.Errorf("序列化子会话实例绑定: %w", err)
		}
		if err := r.store.Set(instanceKey(childSessionID), string(binding)); err != nil {
			return fmt.Errorf("绑定子会话实例: %w", err)
		}
	}
	return nil
}

// respondPermission 兑现 permission.respond / permission.approve / permission.reject：
// 把移动端的一次性审批决策注入会话 handle 的 pending permission registry，
// 由 handle 回写桥的原始 JSON-RPC 请求（allowed-once/rejected）。
// 命令 kind 为 reject（permission.reject）时决策为拒绝，其余一律视为批准；
// 会话无运行 handle、未知 request_id 或重复决策均失败（fail-closed）。
func (r *SessionRunner) respondPermission(ctx context.Context, cmd Command) error {
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		return err
	}
	sessionID := env.sessionID()
	if sessionID == "" {
		return errors.New("permission 命令缺少 session_id")
	}
	requestID := ""
	if env.Ciphertext != nil && env.Ciphertext.FixturePayload != nil {
		requestID = strings.TrimSpace(env.Ciphertext.FixturePayload.RequestID)
	}
	if requestID == "" {
		return errors.New("permission 命令缺少 request_id")
	}
	// 以分发 case 的 cmd.Kind 为准（PayloadJSON 可能不含 kind）；
	// permission.reject → 拒绝，其余（approve/respond）→ 批准。
	allow := cmd.Kind != "permission.reject"
	r.mu.Lock()
	rs := r.handles[sessionID]
	r.mu.Unlock()
	if rs == nil {
		return fmt.Errorf("会话 %s 没有运行中 handle，无法回写权限决策", sessionID)
	}
	decider, ok := rs.handle.(adapter.PermissionDecisionHandle)
	if !ok {
		return fmt.Errorf("%w: 会话 %s 的 handle 不支持权限决策回流", ErrUnsupportedCommand, sessionID)
	}
	// 决策注入：handle 侧 one-shot 校验未知/重复并回写桥原始请求。
	return decider.ResolvePermission(requestID, allow)
}
