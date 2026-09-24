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
