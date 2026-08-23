package dsh

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// handshakeTimeout 是 initialize / session/new 的默认超时。P0 实测冷启动约 359ms，
// 30s 宽裕量足以覆盖慢速磁盘；无调用方截止时间时才套用。
const handshakeTimeout = 30 * time.Second

// Adapter 是 DeepSeek Harness ACP 桥适配器（spi.Adapter 实现）。
// Detect 做一次性真实握手（spawn 桥 + initialize）并缓存结果，之后不再触碰子进程；
// 每次 Start 独立 spawn 一个 per-session 子进程（ADR-013 §3 方案 A）。
type Adapter struct {
	mu      sync.Mutex
	factory func() (BridgeTransport, error)

	// 一次性握手缓存：首次 Detect 后确定能力口径。
	handshakeDone bool
	handshakeOK   bool
	version       string
	failReason    string
}

// New 构造生产适配器（真实 dsh-acp-demo 子进程）。
func New() *Adapter {
	return &Adapter{factory: func() (BridgeTransport, error) { return newBinTransport() }}
}

// NewWithTransport 构造指定桥工厂的适配器（契约测试注入内存假桥）。
func NewWithTransport(factory func() (BridgeTransport, error)) *Adapter {
	return &Adapter{factory: factory}
}

// Detect 做一次性 ACP 握手并缓存：协议版本须为 1 才升级能力矩阵；
// 版本不符或握手失败 → 全部能力 unsupported、各带中文原因、Version 留空（fail-closed）。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.handshakeDone {
		return a.matrixLocked(), nil
	}
	// 一次性握手（持锁执行：Registry 对每类 Provider 顺序调用，结果需要原子提交）。
	tr, err := a.factory()
	if err == nil {
		h := newHandle(tr)
		go h.readLoop()
		initCtx, cancel := withTimeout(ctx, handshakeTimeout)
		info, initErr := h.initialize(initCtx)
		cancel()
		// 握手完成后立即关闭本次探测子进程，避免进程泄漏。
		_ = h.Dispose(context.Background())
		if initErr != nil {
			err = initErr
		} else if info.ProtocolVersion != 1 {
			err = fmt.Errorf("桥协议版本不符（protocolVersion=%v，要求 1）", info.ProtocolVersion)
		} else {
			// 版本门通过：采集桥 agentInfo 写入能力快照（ADR-013 §2）。
			a.handshakeOK = true
			a.version = info.AgentInfo.Version
		}
	}
	a.handshakeDone = true
	if err != nil {
		a.failReason = err.Error()
	}
	return a.matrixLocked(), nil
}

// Capabilities 返回能力矩阵（复用 Detect 的一次性握手缓存）。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start 启动一个 DSH ACP 会话：spawn 桥 → initialize → session/new(cwd=WorkspaceRoot)，
// 返回实现 InstanceIDHandle 的 handle（InstanceID()=桥返回的真实 sessionId）。
// req.Model 不上 wire：模型由桥配置（cordis.yml 的 provider/model）承载，运行期不可选，
// 对应能力矩阵 model_select=unsupported。
func (a *Adapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	if strings.TrimSpace(req.WorkspaceRoot) == "" {
		return nil, errors.New("Start 需要 workspace root")
	}
	tr, err := a.factory()
	if err != nil {
		return nil, err
	}
	h := newHandle(tr)
	go h.readLoop()
	// 任一握手步骤失败都回收子进程后返回错误（fail-closed，不留下半开 handle）。
	fail := func(cause error) (adapter.Handle, error) {
		_ = h.Dispose(context.Background())
		return nil, cause
	}
	initCtx, cancel := withTimeout(ctx, handshakeTimeout)
	info, err := h.initialize(initCtx)
	cancel()
	if err != nil {
		return fail(fmt.Errorf("dsh initialize: %w", err))
	}
	if info.ProtocolVersion != 1 {
		return fail(fmt.Errorf("dsh 协议版本不符: protocolVersion=%v", info.ProtocolVersion))
	}
	// 会话 cwd 取调用方工作区（与 ACP session/new 的 cwd 语义一致）；mcpServers 固定空数组
	// （桥对非空 mcpServers 直接抛 invalidParams，见 acp-demo validateSessionParams）。
	newCtx, cancelNew := withTimeout(ctx, handshakeTimeout)
	sessionID, err := h.newSession(newCtx, req.WorkspaceRoot)
	cancelNew()
	if err != nil {
		return fail(fmt.Errorf("dsh session/new: %w", err))
	}
	h.setSessionID(sessionID)
	return h, nil
}

// Resume 恢复已存在会话：桥未实现 session/load、session/list（实测 -32601），
// 一律返回六态枚举中的 unsupported，绝不伪装成 resumed（spi 硬性要求）。
func (a *Adapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	_ = ctx
	_ = req
	return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
}

// matrixLocked 根据握手缓存构造能力矩阵（调用方须持锁）。
func (a *Adapter) matrixLocked() adapter.Capabilities {
	if a.handshakeDone && a.handshakeOK {
		return successMatrix(a.version)
	}
	return failClosedMatrix(a.failReason)
}

// failClosedMatrix 构造全 unsupported 能力矩阵：每条能力带同一中文原因，Version 留空。
func failClosedMatrix(reason string) adapter.Capabilities {
	if reason == "" {
		reason = "DeepSeek Harness ACP 桥不可用，控制能力已安全禁用。"
	}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		caps = append(caps, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
	}
	return adapter.Capabilities{Provider: "dsh", Capabilities: caps}
}

// successMatrix 是握手成功后的能力矩阵（spec §2 冻结口径）。
func successMatrix(version string) adapter.Capabilities {
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		status := adapter.CapabilityNative
		reason := ""
		switch name {
		case "start", "abort", "kill":
			// native：start/abort 走真实 JSON-RPC；kill 因 per-session 子进程进程组所有权，
			// handle 实现 ForceKillHandle（session.kill 可安全触发进程树终止）。
			if name == "kill" {
				reason = "per-session 子进程进程组所有权"
			}
		case "resume":
			// 桥未实现 session/load（实测 -32601），Resume 恒返回 unsupported 六态之一。
			status = adapter.CapabilityUnsupported
			reason = "桥未实现 session/load（实测 -32601）"
		case "permission":
			// 决策通道（session/request_permission）已接通，但当前策略为取消而非静默批准。
			status = adapter.CapabilityEmulated
			reason = "决策通道已接通但当前策略为取消而非静默批准"
		case "permission_mode":
			status = adapter.CapabilityUnsupported
			reason = "权限策略由桥配置固定，不支持运行期切换"
		case "question":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现提问通道（无 question 相关 wire 方法）"
		case "plan":
			status = adapter.CapabilityUnsupported
			reason = "桥不广播 plan 变体，未接入计划能力"
		case "goal":
			status = adapter.CapabilityUnsupported
			reason = "桥不广播 goal 事件"
		case "skill_catalog":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现技能目录通道"
		case "invoke_skill":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现技能调用方法"
		case "model_select":
			status = adapter.CapabilityUnsupported
			reason = "模型由桥配置承载，不支持运行期选择"
		case "effort_select":
			status = adapter.CapabilityUnsupported
			reason = "桥不支持运行期 effort 选择"
		case "attachments":
			status = adapter.CapabilityUnsupported
			reason = "桥 prompt 仅接受 text 块，不支持附件"
		case "file_read":
			status = adapter.CapabilityUnsupported
			reason = "桥 fs/* 请求按 -32601 拒绝，未接入文件读取"
		case "git_read":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现 git 读取能力"
		case "usage":
			status = adapter.CapabilityUnsupported
			reason = "桥不广播 usage_update（仅提交 agent_message_chunk）"
		case "fork":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现 session/fork"
		case "delegate_session":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现会话委托"
		case "delegate_cross_provider":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现跨 Provider 委托"
		}
		caps = append(caps, adapter.Capability{Name: name, Status: status, Reason: reason})
	}
	return adapter.Capabilities{Provider: "dsh", Version: version, Capabilities: caps}
}

// withTimeout 在 ctx 无截止时间时套上默认超时，避免桥异常时请求挂死；
// ctx 已有截止时间则原样返回（不剥夺调用方控制权）。
func withTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if _, ok := ctx.Deadline(); ok {
		return ctx, func() {}
	}
	return context.WithTimeout(ctx, d)
}
