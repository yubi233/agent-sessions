package dsh

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// handshakeTimeout 是 initialize / session/new 的默认超时。P0 实测冷启动约 359ms，
// 30s 宽裕量足以覆盖慢速磁盘；无调用方截止时间时才套用。
// 握手超时改为可配置（v0.9.2 R4：真机实测遇到 30s 内桥未完成 initialize）。
// 读取入口见 handshake.go 的 handshakeTimeoutFromEnv；缺省值不变。
// handshakeTimeoutFor 在 handshake.go 中按需解析环境变量。

// handshakeTimeoutFor 每次调用都重新解析环境变量：既便于测试覆盖，也避免包级
// 变量把进程启动时的环境固化（回滚时 unset 即恢复缺省）。
func handshakeTimeoutFor() time.Duration { return handshakeTimeoutFromEnv() }

// ModelCatalog is returned by each ACP session handshake and cached for its lifetime.
type ModelCatalog struct {
	Groups  []adapter.ModelCapabilityGroup
	Current adapter.ModelCapabilityModel
}

// Adapter 是 DeepSeek Harness ACP 桥适配器（spi.Adapter 实现）。
// Detect 做一次性真实握手（spawn 桥 + initialize）并缓存结果，之后不再触碰子进程；
// 每次 Start 独立 spawn 一个 per-session 子进程（ADR-013 §3 方案 A）。
type Adapter struct {
	mu      sync.Mutex
	factory func() (BridgeTransport, error)
	// workspaceFactory 将生产 Start/Resume 的工作区根与无工作区 Detect 探测隔离；
	// fixture 适配器仍可沿用旧的无参数工厂形状。
	workspaceFactory func(string) (BridgeTransport, error)
	// sourceFactory 绑定「既有 DSH 存储根」（v0.9.5 P0）：导入映射携带 artifact
	// 实际所在根与物理编码时，resume 用它把桥精确绑定到该存储，而不是回落
	// <workspace>/.dsh-sessions 缺省根（全局存储来源的会话在缺省根上不可续）。
	sourceFactory func(persistenceRoot, workspaceRoot, compression string) (BridgeTransport, error)
	production    bool

	// 握手结果缓存：首次 Detect 后确定能力口径；成功快照永久命中，
	// 失败结果受控重探（v0.9.2 P1 / C2，见 reprobe.go）。
	handshakeDone bool
	handshakeOK   bool
	version       string
	failReason    string
	modelGroups   []adapter.ModelCapabilityGroup
	defaultModel  string

	// reprobeCooldown 是失败后的最小重探间隔（0 = 不缓存失败，仅诊断/测试使用）。
	reprobeCooldown time.Duration
	// reprobeAllowedAt 是允许下一次重探的时间点；零值表示不限制。
	reprobeAllowedAt time.Time
	// reprobeAttempts 累计重探次数（成功复位），用于诊断与测试观测。
	reprobeAttempts int
	// clock 是可注入时钟（测试不 sleep）；为零值时回退 time.Now。
	clock func() time.Time
}

// New 构造生产适配器（真实 dsh-acp-demo 子进程）。
func New() *Adapter {
	return &Adapter{
		factory:          func() (BridgeTransport, error) { return newBinTransport() },
		workspaceFactory: func(root string) (BridgeTransport, error) { return newBinTransportForWorkspace(root) },
		sourceFactory: func(persistenceRoot, workspaceRoot, compression string) (BridgeTransport, error) {
			return newBinTransportForSource(persistenceRoot, workspaceRoot, compression)
		},
		production:      true,
		reprobeCooldown: reprobeCooldownFromEnv(),
	}
}

// NewWithTransport 构造指定桥工厂的适配器（契约测试注入内存假桥）。
func NewWithTransport(factory func() (BridgeTransport, error)) *Adapter {
	if factory == nil {
		factory = func() (BridgeTransport, error) {
			return nil, errors.New("DSH bridge factory 未配置")
		}
	}
	return &Adapter{
		factory:          factory,
		workspaceFactory: func(string) (BridgeTransport, error) { return factory() },
		// 显式存储根在注入工厂下按同一工厂处理（契约测试不感知根差异）；
		// 需要断言路由时测试可直接覆写该字段。
		sourceFactory:   func(string, string, string) (BridgeTransport, error) { return factory() },
		reprobeCooldown: reprobeCooldownFromEnv(),
	}
}

// now 返回可注入时钟；未注入时使用系统时间（重探判定的唯一时间来源）。
func (a *Adapter) now() time.Time {
	if a.clock != nil {
		return a.clock()
	}
	return time.Now()
}

func (a *Adapter) transportForWorkspace(workspaceRoot string) (BridgeTransport, error) {
	if a.workspaceFactory != nil {
		return a.workspaceFactory(workspaceRoot)
	}
	if a.factory == nil {
		return nil, errors.New("DSH bridge factory 未配置")
	}
	return a.factory()
}

// transportForResume 按 resume 来源选择桥工厂（v0.9.5 P0）：显式持久化根
// （来自导入映射）把桥绑定到 artifact 实际存储位置与编码；否则沿用工作区缺省根。
func (a *Adapter) transportForResume(persistenceRoot, workspaceRoot, compression string) (BridgeTransport, error) {
	if strings.TrimSpace(persistenceRoot) != "" {
		if a.sourceFactory == nil {
			return nil, errors.New("DSH 桥工厂未配置显式持久化根支持")
		}
		return a.sourceFactory(persistenceRoot, workspaceRoot, compression)
	}
	return a.transportForWorkspace(workspaceRoot)
}

// prepareWorkspacePersistence 在 DSH 打开新根前迁移匹配的旧 artifact。
// 缺失/空旧根不阻断启动；格式错误或冲突则保留给 DSH 检查路径可见，绝不覆盖。
func (a *Adapter) prepareWorkspacePersistence(workspaceRoot string) error {
	if !a.production || strings.TrimSpace(workspaceRoot) == "" {
		return nil
	}
	canonical, err := canonicalWorkspacePath(workspaceRoot)
	if err != nil {
		return fmt.Errorf("规约 workspace root: %w", err)
	}
	workspaceRoot = canonical
	destination := filepath.Join(workspaceRoot, ".dsh-sessions")
	roots := LegacyRootsFromEnv()
	if bin, _, err := binConfig(); err == nil {
		checkout := filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(bin)))))
		roots = append(roots, filepath.Join(checkout, ".dsh-sessions"))
	}
	var existing []string
	seen := map[string]bool{}
	for _, root := range roots {
		abs, err := filepath.Abs(root)
		if err != nil {
			continue
		}
		abs = filepath.Clean(abs)
		canonicalRoot, canonicalErr := filepath.EvalSymlinks(abs)
		if canonicalErr != nil {
			continue
		}
		canonicalRoot, canonicalErr = filepath.Abs(canonicalRoot)
		if canonicalErr != nil {
			continue
		}
		canonicalRoot = filepath.Clean(canonicalRoot)
		if canonicalRoot == destination || seen[canonicalRoot] {
			continue
		}
		if info, statErr := os.Stat(canonicalRoot); statErr == nil && info.IsDir() {
			existing = append(existing, canonicalRoot)
			seen[canonicalRoot] = true
		}
	}
	if len(existing) == 0 {
		return nil
	}
	compression, err := configuredPersistenceCompression()
	if err != nil {
		return err
	}
	report, err := MigrateLegacySessionsToCompression(destination, workspaceRoot, existing, compression)
	if err != nil {
		return err
	}
	// 任何无法确认、冲突或复制期间发生变化的 artifact 都不能静默略过；
	// 让调用方在 DSH 启动前看到稳定分类，修复源文件后再重试迁移。
	if report.Unsupported > 0 || report.Conflicts > 0 || report.SourceChanged > 0 {
		return fmt.Errorf("DSH 历史迁移未完成（无效=%d，冲突=%d，源文件变化=%d）", report.Unsupported, report.Conflicts, report.SourceChanged)
	}
	return nil
}

// configuredPersistenceCompression 返回桥和迁移共用的 artifact 编码。
// 默认使用明文 JSONL，便于当前 record 模式与本地 fixture 保持一致；需要压缩时
// 由部署显式设置 AGENT_SESSIONS_DSH_PERSIST_COMPRESSION=zstd。
func configuredPersistenceCompression() (string, error) {
	value := strings.TrimSpace(os.Getenv(EnvPersistCompression))
	if value == "" {
		return PersistenceCompressionNone, nil
	}
	if value != PersistenceCompressionNone && value != PersistenceCompressionZstd {
		return "", fmt.Errorf("%s 仅支持 %q 或 %q", EnvPersistCompression, PersistenceCompressionNone, PersistenceCompressionZstd)
	}
	return value, nil
}

// Detect 做 ACP 握手并缓存：协议版本须为 1 才升级能力矩阵；
// 版本不符或握手失败 → 全部能力 unsupported、各带中文原因、Version 留空（fail-closed）。
//
// 缓存语义（v0.9.2 P1 / C2）：
//   - 成功快照永久命中：后续 Detect 不再 spawn 桥（握手有成本，禁止每请求重探）；
//     此后每次真实会话握手（Start/Resume）仍会把新的动态模型目录写回缓存
//     （见 storeHandshake），能力矩阵不依赖编译期模型白名单。
//   - 失败结果受**受控重探测**约束：首次失败后，冷却窗口（缺省 15s，
//     AGENT_SESSIONS_DSH_REPROBE_COOLDOWN_MS 可配）到期才允许再次 spawn 桥，
//     从而在"环境修复后无需重启进程"与"不把每次请求都变成 spawn"之间取平衡。
//
// 持锁执行（Registry 对每类 Provider 顺序调用，结果需要原子提交；同时使并发
// 重探天然 single-flight）。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.handshakeDone && !a.shouldReprobeLocked() {
		// 命中缓存：成功快照直接返回；失败快照在冷却窗口内也原样返回（保持稳定事实）。
		return a.matrixLocked(), nil
	}
	// 首次探测与冷却后的重探走同一条握手路径；重探成败都由下面统一登记。
	if a.handshakeDone {
		a.reprobeAttempts++
	}
	var tr BridgeTransport
	var err error
	if a.factory == nil {
		err = errors.New("DSH bridge factory 未配置")
	} else {
		tr, err = a.factory()
	}
	if err == nil {
		h := newHandle(tr)
		go h.readLoop()
		initCtx, cancel := withTimeout(ctx, handshakeTimeoutFor())
		info, initErr := h.initialize(initCtx)
		cancel()
		// 握手完成后立即关闭本次探测子进程，避免进程泄漏。
		_ = h.Dispose(context.Background())
		if initErr != nil {
			err = initErr
		} else if info.ProtocolVersion != 1 {
			err = fmt.Errorf("桥协议版本不符（protocolVersion=%v，要求 1）", info.ProtocolVersion)
		} else if gateErr := bridgeHandshakeAllowed(info); gateErr != nil {
			// 版本门（ADR-013 §2）：未登记桥名/版本 → fail-closed 矩阵，Version 留空。
			err = gateErr
		} else {
			// 版本门通过：采集桥 agentInfo 写入能力快照（ADR-013 §2）。
			a.storeHandshakeLocked(info)
		}
	}
	a.handshakeDone = true
	if err != nil {
		// 失败原因实时覆盖：重探的新原因必须比旧原因更新，用户才能看到当前事实。
		a.failReason = err.Error()
		a.noteDetectFailureLocked()
		a.logReprobeFailure(a.reprobeAttempts, a.failReason)
	} else {
		a.noteDetectSuccessLocked()
	}
	return a.matrixLocked(), nil
}

// storeHandshake 把一次成功的 ACP initialize（协议版本 1）写回适配器缓存。
// Detect 之外的真实会话握手（Start/Resume）也会刷新：能力矩阵的模型目录因此是
// "最近一次成功握手快照"——DSH 配置（渠道/模型/上下文窗口/推理档位）变化后，
// 随下一次会话建立自动刷新，绝不依赖编译期模型白名单。
func (a *Adapter) storeHandshake(info initializeResult) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.storeHandshakeLocked(info)
}

// storeHandshakeLocked 是 storeHandshake 的持锁变体（调用方须持 a.mu）。
// 版本门未通过的握手不写回：保持既有快照（fail-closed，不因探测失败清空目录）。
func (a *Adapter) storeHandshakeLocked(info initializeResult) {
	if info.ProtocolVersion != 1 {
		return
	}
	// 版本门（ADR-013 §2）：未登记桥名/版本的握手不写回，保持既有 last-good 快照。
	if err := bridgeHandshakeAllowed(info); err != nil {
		return
	}
	a.handshakeOK = true
	a.handshakeDone = true
	a.failReason = ""
	a.version = info.AgentInfo.Version
	a.modelGroups = info.ModelCatalog.Groups
	a.defaultModel = info.ModelCatalog.Current.Value
}

// Capabilities 返回能力矩阵（复用 Detect 的一次性握手缓存）。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start 启动一个 DSH ACP 会话：spawn 桥 → initialize → session/new(cwd=WorkspaceRoot)，
// 返回实现 InstanceIDHandle 的 handle（InstanceID()=桥返回的真实 sessionId）。
// req.Model 登记为期望模型（ACP 目录公布的 opaque route value），首个 Send 前经
// session/set_config_option 下发；未声明时不覆盖，沿用 DSH 桥自身配置的默认路由
// （目录由本次 initialize 握手带回，见 storeHandshake）。
func (a *Adapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	if strings.TrimSpace(req.WorkspaceRoot) == "" {
		return nil, errors.New("Start 需要 workspace root")
	}
	workspaceRoot := req.WorkspaceRoot
	if a.production {
		var err error
		workspaceRoot, err = canonicalWorkspacePath(workspaceRoot)
		if err != nil {
			return nil, fmt.Errorf("规约 workspace root: %w", err)
		}
	}
	if err := a.prepareWorkspacePersistence(workspaceRoot); err != nil {
		return nil, fmt.Errorf("准备 DSH workspace 持久化: %w", err)
	}
	tr, err := a.transportForWorkspace(workspaceRoot)
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
	initCtx, cancel := withTimeout(ctx, handshakeTimeoutFor())
	info, err := h.initialize(initCtx)
	cancel()
	if err != nil {
		return fail(fmt.Errorf("dsh initialize: %w", err))
	}
	if info.ProtocolVersion != 1 {
		return fail(fmt.Errorf("dsh 协议版本不符: protocolVersion=%v", info.ProtocolVersion))
	}
	// 版本门（ADR-013 §2）：未登记桥名/版本不允许建立会话，统一回收子进程。
	if err := bridgeHandshakeAllowed(info); err != nil {
		return fail(err)
	}
	// 每次真实会话握手都刷新能力矩阵目录：DSH 配置变化后，下一次 Start/Resume
	// 自动把新渠道/模型/档位目录写回适配器缓存（Capabilities/session controls 读取）。
	a.storeHandshake(info)
	// 会话 cwd 取调用方工作区（与 ACP session/new 的 cwd 语义一致）；mcpServers 固定空数组
	// （桥对非空 mcpServers 直接抛 invalidParams，见 acp-demo validateSessionParams）。
	newCtx, cancelNew := withTimeout(ctx, handshakeTimeoutFor())
	sessionID, err := h.newSession(newCtx, workspaceRoot)
	cancelNew()
	if err != nil {
		return fail(fmt.Errorf("dsh session/new: %w", err))
	}
	h.setSessionID(sessionID)
	// 会话创建时声明的模型在首个 Send 前经 set_config_option 生效；空值由 SetModel 忽略。
	h.SetModel(req.Model)
	return h, nil
}

// Resume 恢复已存在会话。直接调用方没有 runtime handle 接收通道，因此
// ResumeStreaming 完成后会释放句柄；Daemon 应使用 ResumeStreaming 接管句柄。
func (a *Adapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	return a.resumeStreaming(ctx, req, nil)
}

// ResumeStreaming 建立新的 DSH ACP 进程并在发送 load/resume 前交出句柄。
// ready 返回错误时不会发送恢复请求；任何失败路径都会回收本机进程组。
func (a *Adapter) ResumeStreaming(ctx context.Context, req adapter.ResumeRequest, ready func(adapter.Handle) error) (adapter.ResumeResult, error) {
	return a.resumeStreaming(ctx, req, ready)
}

func (a *Adapter) resumeStreaming(ctx context.Context, req adapter.ResumeRequest, ready func(adapter.Handle) error) (adapter.ResumeResult, error) {
	if strings.TrimSpace(req.InstanceID) == "" {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	if strings.TrimSpace(req.WorkspaceRoot) == "" {
		return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
	}
	workspaceRoot := req.WorkspaceRoot
	if a.production {
		var err error
		workspaceRoot, err = canonicalWorkspacePath(workspaceRoot)
		if err != nil {
			return adapter.ResumeResult{}, fmt.Errorf("规约 workspace root: %w", err)
		}
	}
	// 显式持久化根（v0.9.5 导入映射）= artifact 实际所在存储，可能是用户的全局
	// 存储 ~/.dsh/sessions：跳过 prepareWorkspacePersistence——它面向工作区缺省根
	// 的旧 artifact 迁移，对显式根既无意义，也可能因无关冲突阻断恢复，更不能
	// 碰用户的全局存储。无显式根时保持既有迁移行为不变。
	persistenceRoot := strings.TrimSpace(req.PersistenceRoot)
	if persistenceRoot == "" {
		if err := a.prepareWorkspacePersistence(workspaceRoot); err != nil {
			return adapter.ResumeResult{}, fmt.Errorf("准备 DSH workspace 持久化: %w", err)
		}
	}
	tr, err := a.transportForResume(persistenceRoot, workspaceRoot, req.Compression)
	if err != nil {
		return adapter.ResumeResult{}, err
	}
	h := newHandle(tr)
	go h.readLoop()
	fail := func(cause error) (adapter.ResumeResult, error) {
		_ = h.Dispose(context.Background())
		return adapter.ResumeResult{}, cause
	}
	initCtx, cancel := withTimeout(ctx, handshakeTimeoutFor())
	info, err := h.initialize(initCtx)
	cancel()
	if err != nil {
		return fail(fmt.Errorf("dsh initialize: %w", err))
	}
	if info.ProtocolVersion != 1 {
		return fail(fmt.Errorf("dsh 协议版本不符: protocolVersion=%v", info.ProtocolVersion))
	}
	// 版本门（ADR-013 §2）：与 Start 同口径，未登记桥名/版本不允许恢复会话。
	if err := bridgeHandshakeAllowed(info); err != nil {
		return fail(err)
	}
	// 恢复会话的握手同样刷新能力矩阵目录（与 Start 口径一致）。
	a.storeHandshake(info)
	h.setSessionID(strings.TrimSpace(req.InstanceID))
	h.setReplayMode(req.ReplayHistory && ready != nil)
	if ready != nil {
		if err := ready(h); err != nil {
			return fail(err)
		}
	}
	resumeCtx, cancelResume := withTimeout(ctx, handshakeTimeoutFor())
	if req.ReplayHistory {
		err = h.loadSession(resumeCtx, workspaceRoot)
	} else {
		err = h.resumeSession(resumeCtx, workspaceRoot)
	}
	cancelResume()
	if err != nil {
		// 上游桥把 cwd 不一致报告为 invalid params；这里转换为带类型的唤醒结果，
		// 让 UI 能解释工作区移动，同时不暴露 Provider wire 细节。
		if strings.Contains(err.Error(), "cwd does not match") || strings.Contains(err.Error(), "cwd 不匹配") {
			// 无论是否交接给 Daemon，当前恢复句柄都已启动，必须统一回收，
			// 避免直接调用 Resume 时遗留桥进程和临时资源。
			_ = h.Dispose(context.Background())
			return adapter.ResumeResult{Result: adapter.WakeWorkspaceMoved, InstanceID: req.InstanceID}, nil
		}
		return fail(fmt.Errorf("dsh session resume: %w", err))
	}
	result := adapter.ResumeResult{Result: adapter.WakeResumed, InstanceID: req.InstanceID}
	if ready == nil {
		_ = h.Dispose(context.Background())
	}
	return result, nil
}

// matrixLocked 根据握手缓存构造能力矩阵（调用方须持锁）。
func (a *Adapter) matrixLocked() adapter.Capabilities {
	if a.handshakeDone && a.handshakeOK {
		return successMatrix(a.version, ModelCatalog{Groups: a.modelGroups, Current: adapter.ModelCapabilityModel{Value: a.defaultModel}})
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
func successMatrix(version string, catalogs ...ModelCatalog) adapter.Capabilities {
	var catalog ModelCatalog
	if len(catalogs) > 0 {
		catalog = catalogs[0]
	}
	modelGroups := catalog.Groups
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
			// 当前桥已实现 session/load 与 session/resume；适配器会先交接句柄，
			// 再发出恢复请求，确保回放与恢复后发送均走同一事件流。
		case "permission":
			// 决策通道（session/request_permission）已接通，但当前策略为取消而非静默批准。
			status = adapter.CapabilityEmulated
			reason = "决策通道已接通但当前策略为取消而非静默批准"
		case "permission_mode":
			// v0.8.3 P5 升格：桥 session/set_mode（preset 原子 bundle）+ Go
			// SessionModeHandle + runner mode.set + Relay 命令通道 + 客户端矩阵门控
			// 全链路成立，dsh-v083-overlay deterministic gate 15/15 通过（mode 目录/
			// set_mode/current_mode_update/目录外拒绝）。mode 目录为 session 级，
			// 静态 Options 留空（空目录语义：不暴露静态目录，客户端按 Status 放行入口）。
			status = adapter.CapabilityNative
			reason = "全链路成立且 deterministic overlay 通过；session 级 mode 目录经 session 响应下发"
		case "question":
			// v0.8.3 P5 升格（dsh/* 上限 emulated）：桥 userQuestions provider +
			// Go pending registry + 编码映射 + 移动端 question_request composer 已接通；
			// 触发需真实模型 turn（V083-26 待授权复验）。
			status = adapter.CapabilityEmulated
			reason = "dsh/question 链路已接通；真实模型 turn 复验待授权（V083-26）"
		case "plan":
			// v0.8.3 P5 升格（extension 承载）：桥 plan mode/审核 + runner plan.action
			// 已接通；plan-review 触发需真实模型 turn（V083-26 待授权复验）。
			status = adapter.CapabilityEmulated
			reason = "dsh/plan 链路已接通；真实模型 turn 复验待授权（V083-26）"
		case "goal":
			// v0.8.3 P5 升格（extension 承载）：桥 goal 服务 + dsh/goal/get|mutate +
			// runner goal.action 已接通；空 projection 经 deterministic overlay 验证。
			status = adapter.CapabilityEmulated
			reason = "dsh/goal 链路已接通；空 projection 经 overlay 验证，mutate 复验待授权（V083-26）"
		case "skill_catalog":
			// v0.8.3 P5 升格（extension 承载）：桥目录快照 + 摘要 revision +
			// dsh/skill/catalog + runner skill.invoke 已接通；部署需配置 skills，
			// 真实目录复验待授权（V083-26）。
			status = adapter.CapabilityEmulated
			reason = "dsh/skill 链路已接通（descriptor 白名单 + 摘要 revision）；部署目录复验待授权"
		case "invoke_skill":
			// v0.8.3 P5 升格（extension 承载）：调用 admission（userInvocable +
			// catalogRevision）进入既有 prompt slot；真实执行复验待授权（V083-26）。
			status = adapter.CapabilityEmulated
			reason = "skill invoke admission 已接通（复用 prompt/cancel 生命周期）；真实执行复验待授权"
		case "model_select":
			// ACP session/set_config_option(configId=model) 已接入 Go handle：
			// send 前 fail-closed 下发；目录由 initialize 的 DSH ACP 扩展动态提供。
			status = adapter.CapabilityNative
		case "effort_select":
			status = adapter.CapabilityUnsupported
			reason = "DSH ACP 当前模型目录未公布推理档位"
			for _, group := range modelGroups {
				for _, model := range group.Models {
					if len(model.Efforts) > 0 {
						status, reason = adapter.CapabilityNative, ""
					}
				}
			}
		case "attachments":
			// v0.8.8 P1-P4 升格（emulated）：opaque attachment ref 全链路成立——
			// daemon 拉取出口（NewRelayLoop 注册 fetchAndOpenAttachment）+ 本机 DEK
			// Open 契约（attachment_open.go，迭代计划 §9.1）+ mobile Seal 同构字节级
			// 回归（V088-02/03）+ localdev 端到端（V088-09）。明文只经内存；
			// 桥 admission 上限 emulated，Keystore 实机 gate 承接 V085。
			status = adapter.CapabilityEmulated
			reason = "opaque attachment ref 全链路成立（daemon 拉取出口 + 本机 DEK Open 契约 §9.1 + 全链回归 V088-02/03）；明文只经内存，桥 admission 上限 emulated，Keystore 实机 gate 承接 V085"
		case "file_read":
			// v0.8.8 P2-P4 升格（native）：应用层只读命令通道成立——daemonCapabilities
			// 恒声明（V088-05）+ ReadOnlyDispatcher 沙箱 + 文件树/查看消费者真实传输
			// （V088-08/10）。桥 ACP fs/* 维持 -32601（ADR-014 §9 两套授权真相不变）。
			status = adapter.CapabilityNative
			reason = "应用层只读命令通道成立（恒声明 + ReadOnlyDispatcher 沙箱 + 文件树/查看消费者 V088-08/10 证据）；桥 ACP fs/* 维持 -32601（ADR-014 §9）"
		case "git_read":
			// v0.8.8 P2-P4 升格（native）：应用层只读命令通道成立——恒声明 +
			// ReadOnlyDispatcher 沙箱（internal/gitread）+ GitDiff 真实传输
			// （V088-07/10）。桥 ACP git 工具维持不做（ADR-014 §9 理由不变）。
			status = adapter.CapabilityNative
			reason = "应用层只读命令通道成立（恒声明 + ReadOnlyDispatcher 沙箱 + GitDiff 真实传输 V088-07/10 证据）；桥 ACP git 工具维持不做（ADR-014 §9）"
		case "usage":
			status = adapter.CapabilityNative
		case "fork":
			// v0.8.3 P5 升格：桥 committed-prefix fork（deterministic overlay 验证）
			// + Relay fork API → daemon 子会话绑定（TestSessionRunnerForkBindsChildInstance）
			// + 客户端既有 fork 入口按矩阵放行，全链路成立。
			status = adapter.CapabilityNative
			reason = "全链路成立且 deterministic overlay 通过（committed-prefix + 子会话绑定）"
		case "delegate_session":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现会话委托"
		case "delegate_cross_provider":
			status = adapter.CapabilityUnsupported
			reason = "桥未实现跨 Provider 委托"
		}
		capability := adapter.Capability{Name: name, Status: status, Reason: reason}
		if name == "model_select" {
			capability.ModelGroups = cloneModelGroups(modelGroups)
			capability.ModelDetails = make(map[string]adapter.ModelCapabilityDetail)
			for _, group := range modelGroups {
				for _, model := range group.Models {
					capability.Options = append(capability.Options, model.Value)
					capability.ModelDetails[model.Value] = adapter.ModelCapabilityDetail{
						ContextWindowTokens: model.ContextWindowTokens,
						Reasoning:           model.Reasoning,
						Efforts:             append([]string(nil), model.Efforts...),
					}
					if capability.Default == "" && model.Value != "" {
						capability.Default = model.Value
					}
				}
			}
			capability.Default = catalog.Current.Value
			if !catalogContains(capability.Options, capability.Default) {
				capability.Default = ""
			}
		}
		caps = append(caps, capability)
	}
	return adapter.Capabilities{Provider: "dsh", Version: version, Capabilities: caps}
}

func catalogContains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func cloneModelGroups(groups []adapter.ModelCapabilityGroup) []adapter.ModelCapabilityGroup {
	cloned := make([]adapter.ModelCapabilityGroup, 0, len(groups))
	for _, group := range groups {
		copyGroup := adapter.ModelCapabilityGroup{ID: group.ID, Name: group.Name, Models: make([]adapter.ModelCapabilityModel, len(group.Models))}
		copy(copyGroup.Models, group.Models)
		for i := range copyGroup.Models {
			copyGroup.Models[i].Efforts = append([]string(nil), group.Models[i].Efforts...)
		}
		cloned = append(cloned, copyGroup)
	}
	return cloned
}

// withTimeout 在 ctx 无截止时间时套上默认超时，避免桥异常时请求挂死；
// ctx 已有截止时间则原样返回（不剥夺调用方控制权）。
func withTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if _, ok := ctx.Deadline(); ok {
		return ctx, func() {}
	}
	return context.WithTimeout(ctx, d)
}
