package dsh

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/yubi233/agent-sessions/internal/adapter"
)

// v0.9.5 P0 真实桥链路验证（无模型）：全局存储布局（~/.dsh/sessions，zstd）的
// 既有 artifact，经 newBinTransportForSource 按来源根+编码绑定的桥必须能
// session/load——这是「导入的全局会话可在原会话上继续」的桥层事实（上游按
// 「根编码归属」校验，根或编码不对会被整根拒绝）。真实 DSH 不会在 session/new
// 时立即物化 JSONL（首事件才写），因此 artifact 由测试按 DSH 布局手工构造，
// 与 DSH CLI 写入形态一致。与 live_transport_test.go 同口径：门控
// AGENT_SESSIONS_DSH_LIVE=1 才运行，默认跳过；全程不发送 prompt（不触发模型
// 调用、不联网）。
func TestLiveBridgeSourceBoundGlobalLayoutResume(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_DSH_LIVE") != "1" {
		t.Skip("AGENT_SESSIONS_DSH_LIVE != 1：跳过真实子进程集成测试")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// 模拟 DSH 全局存储：<home>/.dsh/sessions/<projectKey>/session-<uuid>/session.jsonl.zstd。
	home := t.TempDir()
	globalRoot := filepath.Join(home, ".dsh", "sessions")
	if err := os.MkdirAll(globalRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	workspace := t.TempDir()
	canonicalWorkspace, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		t.Fatal(err)
	}
	canonicalWorkspace, err = filepath.Abs(canonicalWorkspace)
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "sess-v095-live-1"
	header, _ := json.Marshal(map[string]any{
		"type": "session", "version": 0, "id": sessionID, "createdAt": 1,
		"cwd": canonicalWorkspace, "delegationDepth": 0,
	})
	// 真实全局 artifact 的多数形态不含 agent-preset/selected（实测 508 个真实
	// artifact 仅 41 条该事件）：demo 桥组合未挂 presets 服务，携带该事件反而
	// 会 fail-closed 拒载；fixture 按多数形态构造。
	body, _ := json.Marshal(map[string]any{
		"type": "user/message", "seq": 0, "time": 3, "surfaceOp": "append",
		"data": map[string]any{
			"role": "user", "id": "m-live-1", "source": map[string]any{"kind": "user"},
			"content": []map[string]any{{"type": "text", "text": "历史问题"}},
		},
	})
	// DSH zstd artifact 是拼接帧容器：首帧只含 header 行（校验「帧明文仅一行」），
	// 事件批次各占一帧（行间 \n、帧尾 \n）。用 klauspost 两次 EncodeAll 复刻。
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	headerFrame := encoder.EncodeAll([]byte(string(header)+"\n"), nil)
	eventFrame := encoder.EncodeAll([]byte(string(body)+"\n"), nil)
	encoder.Close()
	encoded := headerFrame
	encoded = append(encoded, eventFrame...)
	artifactDir := filepath.Join(globalRoot, dshProjectKey(canonicalWorkspace), dshEncodeSegment(sessionID))
	if err := os.MkdirAll(artifactDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(artifactDir, "session.jsonl.zstd"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}

	// 按来源根+编码绑定桥（导入映射的 resume 路径），initialize → session/load。
	tr, err := newBinTransportForSource(globalRoot, workspace, PersistenceCompressionZstd)
	if err != nil {
		t.Fatalf("source 绑定启动桥: %v", err)
	}
	h := newHandle(tr)
	go h.readLoop()
	defer func() { _ = h.Dispose(context.Background()) }()
	initCtx, cancelInit := withTimeout(ctx, handshakeTimeoutFor())
	info, err := h.initialize(initCtx)
	cancelInit()
	if err != nil {
		t.Fatalf("initialize: %v", err)
	}
	if err := bridgeHandshakeAllowed(info); err != nil {
		t.Fatalf("版本门: %v", err)
	}
	h.setSessionID(sessionID)
	loadCtx, cancelLoad := withTimeout(ctx, handshakeTimeoutFor())
	err = h.loadSession(loadCtx, canonicalWorkspace)
	cancelLoad()
	if err != nil {
		t.Fatalf("session/load（显式全局根 + zstd）: %v\n桥 stderr:\n%s", err, tr.stderr.digest())
	}
	t.Logf("LIVE_SUMMARY provider=dsh protocol=1 source_bound=global,zstd load=ok")
}

// 真实全局 artifact（本机 ~/.dsh/sessions）经「来源根+编码」绑定路径的 session/load
// 验证：整目录复制到临时根（绝不写用户存储、不上传任何内容），选样条件为不含
// agent-preset/selected 且原工作区目录仍存在；日志只输出会话 id 与结论。
// 无真实存储或 live 门未开时跳过。
func TestLiveBridgeRealGlobalArtifactResume(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_DSH_LIVE") != "1" {
		t.Skip("AGENT_SESSIONS_DSH_LIVE != 1：跳过真实子进程集成测试")
	}
	realRoot, err := GlobalSessionsDir()
	if err != nil {
		t.Skip("本机无 DSH 全局存储：跳过真实 artifact 验证")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	var chosenPath, chosenID, chosenCWD string
	filepath.Walk(realRoot, filepath.WalkFunc(func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil || info == nil || info.IsDir() || chosenPath != "" {
			return nil
		}
		if !strings.HasSuffix(path, "session.jsonl.zstd") {
			return nil
		}
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		decoder, decodeErr := zstd.NewReader(nil)
		if decodeErr != nil {
			return nil
		}
		text, decodeErr := decoder.DecodeAll(raw, nil)
		decoder.Close()
		if decodeErr != nil {
			return nil
		}
		// 选样：不含 preset 事件（demo 桥组合无 presets 服务会 fail-closed）。
		if strings.Contains(string(text), "agent-preset/selected") {
			return nil
		}
		firstLine := strings.SplitN(string(text), "\n", 2)[0]
		var header struct {
			ID  string `json:"id"`
			CWD string `json:"cwd"`
		}
		if json.Unmarshal([]byte(firstLine), &header) != nil || header.ID == "" || header.CWD == "" {
			return nil
		}
		if statInfo, statErr := os.Stat(header.CWD); statErr != nil || !statInfo.IsDir() {
			return nil // 桥 cwd 校验要求原工作区目录存在。
		}
		chosenPath, chosenID, chosenCWD = path, header.ID, header.CWD
		return filepath.SkipAll
	}))
	if chosenPath == "" {
		t.Skip("全局存储中没有满足条件的 artifact（无 preset 事件且 cwd 仍存在）")
	}
	t.Logf("chosen_id=%s", chosenID)

	// 整目录副本（保留编码 cwd 目录名）到临时全局根。
	rel := filepath.Dir(chosenPath[len(realRoot)+1:]) // <编码 cwd>/session-<uuid>
	tmpHome := t.TempDir()
	tmpGlobal := filepath.Join(tmpHome, ".dsh", "sessions")
	dstDir := filepath.Join(tmpGlobal, rel)
	if err := os.MkdirAll(dstDir, 0o700); err != nil {
		t.Fatal(err)
	}
	srcRaw, err := os.ReadFile(chosenPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dstDir, "session.jsonl.zstd"), srcRaw, 0o600); err != nil {
		t.Fatal(err)
	}

	tr, err := newBinTransportForSource(tmpGlobal, chosenCWD, PersistenceCompressionZstd)
	if err != nil {
		t.Fatalf("source 绑定启动桥: %v", err)
	}
	h := newHandle(tr)
	go h.readLoop()
	defer func() { _ = h.Dispose(context.Background()) }()
	initCtx, cancelInit := withTimeout(ctx, handshakeTimeoutFor())
	info, err := h.initialize(initCtx)
	cancelInit()
	if err != nil {
		t.Fatalf("initialize: %v", err)
	}
	if err := bridgeHandshakeAllowed(info); err != nil {
		t.Fatalf("版本门: %v", err)
	}
	h.setSessionID(chosenID)
	loadCtx, cancelLoad := withTimeout(ctx, handshakeTimeoutFor())
	err = h.loadSession(loadCtx, chosenCWD)
	cancelLoad()
	if err != nil {
		t.Fatalf("session/load（真实全局 artifact 副本）: %v\n桥 stderr:\n%s", err, tr.stderr.digest())
	}
	t.Logf("LIVE_SUMMARY provider=dsh protocol=1 source_bound=real_global,zstd load=ok")
}

// v0.9.5 P3 真实模型续聊旅程（用户已授权 1–2 次调用；门控
// AGENT_SESSIONS_DSH_REAL=1）：两段式验证「导入的全局会话可在原上下文继续」——
// 桥①在临时全局根新建会话（新会话可切免费池模型）发送暗号；桥②按导入映射
// 路径（来源根+编码）回放同一 artifact 并续问暗号。共 2 次真实调用，与授权
// 上限一致；全程在临时目录，绝不触碰用户真实会话。
func TestV095LiveGlobalResumeRealPrompt(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_DSH_REAL") != "1" {
		t.Skip("AGENT_SESSIONS_DSH_REAL != 1：跳过真实模型旅程（需用户授权）")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
	defer cancel()

	// 模拟 DSH 全局存储：<home>/.dsh/sessions；工作区独立目录。
	home := t.TempDir()
	globalRoot := filepath.Join(home, ".dsh", "sessions")
	if err := os.MkdirAll(globalRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	workspace := t.TempDir()

	// v095AuthorizedModels 是用户逐渠道授权的真实模型白名单（2026-09-25，
	// 仅测试环节，固化于此）：sub2api/gemini-3.8-flash、goat/deepseek-v4.1-flash、
	// goat/xiaomi/mimo-v2.6-flash、opencode-zen 全部模型。白名单之外的渠道
	// 不得进入候选——首版回退曾让 xiaomi-token-plan-cn 插队接活，属越权
	// （记录 35 §4.3），该渠道现明确不在白名单。
	v095AuthorizedModels := map[string]map[string]bool{
		"sub2api":      {"gemini-3.8-flash": true},
		"goat":         {"deepseek/deepseek-v4.1-flash": true, "xiaomi/mimo-v2.6-flash": true},
		"opencode-zen": {"deepseek-v4-flash-free": true, "mimo-v2.5-free": true, "big-pickle": true, "ling-3.0-flash-fin-free": true, "nemotron-3-ultra-free": true, "nemotron-3.5-lightning-free": true},
	}
	// 尝试顺序（2026-09-25 用户指定）：goat xiaomi → sub2api gemini →
	// goat deepseek，opencode-zen 免费档殿后（当前对非 OpenCode 客户端
	// 403/400，失败不计额度）。
	authorizedModels := func(info initializeResult) []string {
		type route struct{ provider, id string }
		order := []route{
			{"goat", "xiaomi/mimo-v2.6-flash"},
			{"sub2api", "gemini-3.8-flash"},
			{"goat", "deepseek/deepseek-v4.1-flash"},
			{"opencode-zen", "deepseek-v4-flash-free"},
			{"opencode-zen", "mimo-v2.5-free"},
			{"opencode-zen", "big-pickle"},
			{"opencode-zen", "ling-3.0-flash-fin-free"},
			{"opencode-zen", "nemotron-3-ultra-free"},
			{"opencode-zen", "nemotron-3.5-lightning-free"},
		}
		byRoute := map[string]string{}
		for _, group := range info.ModelCatalog.Groups {
			for _, model := range group.Models {
				t.Logf("catalog model: provider=%s value=%s id=%s", group.ID, model.Value, model.ID)
				byRoute[group.ID+"/"+model.ID] = model.Value
			}
		}
		var picked []string
		for _, r := range order {
			if !v095AuthorizedModels[r.provider][r.id] {
				continue // 双保险：顺序表本身也只含白名单路由。
			}
			if value, ok := byRoute[r.provider+"/"+r.id]; ok {
				picked = append(picked, value)
			}
		}
		return picked
	}
	startBridge := func() (*dshBinTransport, *handle, initializeResult, error) {
		tr, err := newBinTransportForSource(globalRoot, workspace, PersistenceCompressionZstd)
		if err != nil {
			return nil, nil, initializeResult{}, err
		}
		h := newHandle(tr)
		go h.readLoop()
		// settings 热发布有 debounce（~100ms）+ 文档读取：立即握手会抢在
		// llm-pi-ai 路由注册之前，目录退化为合成默认路由。等一拍再握手。
		time.Sleep(1500 * time.Millisecond)
		initCtx, cancelInit := withTimeout(ctx, handshakeTimeoutFor())
		info, err := h.initialize(initCtx)
		cancelInit()
		if err != nil {
			_ = h.Dispose(context.Background())
			return nil, nil, initializeResult{}, err
		}
		if err := bridgeHandshakeAllowed(info); err != nil {
			_ = h.Dispose(context.Background())
			return nil, nil, initializeResult{}, err
		}
		return tr, h, info, nil
	}
	runTurn := func(h *handle, prompt string) (string, error) {
		events := make(chan adapter.Event, 256)
		go func() {
			for event := range h.Events() {
				select {
				case events <- event:
				case <-ctx.Done():
					return
				}
			}
			close(events)
		}()
		sendErr := h.Send(ctx, prompt)
		reply := ""
		deadline := time.After(5 * time.Second)
		for {
			select {
			case event, ok := <-events:
				if !ok {
					return reply, sendErr
				}
				if event.Type == adapter.EventMessageCompleted {
					if text, _ := event.Payload["text"].(string); strings.TrimSpace(text) != "" {
						reply = text
					}
				}
			case <-deadline:
				return reply, sendErr
			}
		}
	}

	// 桥①：新建会话 + 免费池模型 + 暗号。
	tr1, h1, info1, err := startBridge()
	if err != nil {
		t.Fatalf("桥①启动: %v", err)
	}
	newCtx, cancelNew := withTimeout(ctx, handshakeTimeoutFor())
	sessionID, err := h1.newSession(newCtx, workspace)
	cancelNew()
	if err != nil {
		_ = h1.Dispose(context.Background())
		t.Fatalf("session/new: %v", err)
	}
	h1.setSessionID(sessionID)
	candidates := authorizedModels(info1)
	if len(candidates) == 0 {
		_ = h1.Dispose(context.Background())
		t.Skip("目录中没有免费池档模型，未经授权不消耗付费调用")
	}
	// 逐个免费档重试：上游对个别免费模型返回 400 unavailable（不消耗额度），
	// 取第一个接活的模型建立会话；成功即真实消耗 1 次调用（授权 ≤2 次）。
	var reply1 string
	var lastErr error
	picked := ""
	for _, candidate := range candidates {
		h1.SetModel(candidate)
		reply, err := runTurn(h1, "请记住暗号：芝麻开门。现在只回复两个字：好的")
		if err == nil && strings.TrimSpace(reply) != "" {
			reply1, picked = reply, candidate
			break
		}
		lastErr = err
		t.Logf("candidate unavailable: %s err=%v", candidate, err)
	}
	_ = h1.Dispose(context.Background())
	if picked == "" {
		if lastErr != nil && strings.Contains(lastErr.Error(), "no API key") {
			t.Skipf("credential_or_quota_blocker：部署路由缺 API key（env 与 credentials 均未配置）：%v", lastErr)
		}
		t.Fatalf("桥①首轮（真实调用）全部免费档不可用: lastErr=%v\n桥 stderr:\n%s", lastErr, tr1.stderr.digest())
	}
	t.Logf("bridge1 model=%s reply=%q", picked, reply1)

	// artifact 必须已落在全局布局（zstd）。
	artifacts, err := ScanGlobalSessionArtifacts(globalRoot)
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("全局布局 artifact 未生成: n=%d err=%v", len(artifacts), err)
	}

	// 桥②：按导入映射路径（来源根+编码）回放并续问暗号。
	tr2, h2, _, err := startBridge()
	if err != nil {
		t.Fatalf("桥②启动: %v", err)
	}
	defer func() { _ = h2.Dispose(context.Background()) }()
	h2.setSessionID(sessionID)
	loadCtx, cancelLoad := withTimeout(ctx, handshakeTimeoutFor())
	loadErr := h2.loadSession(loadCtx, workspace)
	cancelLoad()
	if loadErr != nil {
		t.Fatalf("session/load（续聊路径）: %v\n桥 stderr:\n%s", loadErr, tr2.stderr.digest())
	}
	reply2, err := runTurn(h2, "暗号是什么？只回复暗号两个字面内容。")
	if err != nil || !strings.Contains(reply2, "芝麻开门") {
		t.Fatalf("续聊未继承原上下文: err=%v reply=%q\n桥 stderr:\n%s", err, reply2, tr2.stderr.digest())
	}
	t.Logf("LIVE_SUMMARY provider=dsh protocol=1 source_bound=global,zstd real_model=2 model=%s context_inherited=1", picked)
	_ = tr1
}
