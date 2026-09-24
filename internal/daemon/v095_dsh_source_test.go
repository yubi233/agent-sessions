package daemon

// v0.9.5 P0（全局会话可续聊）先红回归。
//
// 1. 导入必须把 artifact 来源根与物理编码写进 instance 映射（providerThread），
//    resume 才能把桥绑定到真实存储位置；此前映射只有 provider/instance/workspace，
//    全局存储（~/.dsh/sessions，zstd）来源的会话「能看不能续」。
// 2. 旧映射（无 persistence_root）首次 resume 时必须按会话 id 在两源定位 artifact
//    并回写映射（一次性自升级），让存量导入会话同样可续。

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/yubi233/agent-sessions/internal/adapter"
)

// writeDSHZstdArtifactForTest 写一个 zstd 编码的全局布局 artifact。
func writeDSHZstdArtifactForTest(t *testing.T, globalRoot, cwd, id, body string) string {
	t.Helper()
	path := filepath.Join(globalRoot, dshProjectKeyForTest(cwd), dshEncodeSegmentForTest(id), "session.jsonl.zstd")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header, _ := json.Marshal(map[string]any{
		"type": "session", "version": 0, "id": id, "createdAt": 1,
		"cwd": cwd, "delegationDepth": 0,
	})
	payload := append(append(header, '\n'), []byte(body)...)
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	encoded := encoder.EncodeAll(payload, nil)
	encoder.Close()
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// 1. 项目绑定布局导入：映射必须记录来源根（<project>/.dsh-sessions）与 artifact
// 实际编码（此处 none）。
func TestV095ImportRecordsSourceRootAndCompression(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustGitInit(t, project)
	canonicalProject := canonicalTestPath(t, project)
	writeDSHSessionArtifactForTest(t, filepath.Join(project, ".dsh-sessions"), canonicalProject, "dsh-src-1", `{"type":"user/message"}`)

	imported := importSingleForV095Test(t, root, project, "dsh-src-1")
	if imported.PersistenceRoot != filepath.Join(canonicalProject, ".dsh-sessions") {
		t.Fatalf("映射来源根 = %q, want 工作区绑定布局根", imported.PersistenceRoot)
	}
	if imported.Compression != "none" {
		t.Fatalf("映射编码 = %q, want none", imported.Compression)
	}
}

// 2. 全局存储布局导入：HOME 指向临时目录，artifact 只存在于 ~/.dsh/sessions
// （zstd）；映射必须记录全局根与 zstd 编码。
func TestV095ImportGlobalLayoutRecordsGlobalSourceRootAndZstd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	globalRoot := filepath.Join(home, ".dsh", "sessions")
	root := t.TempDir()
	project := dshImportFixtureProject(t, root)
	canonicalProject := canonicalTestPath(t, project)
	writeDSHZstdArtifactForTest(t, globalRoot, canonicalProject, "dsh-global-1", `{"type":"user/message"}`)

	imported := importSingleForV095Test(t, root, project, "dsh-global-1")
	if imported.PersistenceRoot != globalRoot {
		t.Fatalf("映射来源根 = %q, want 全局存储根 %q", imported.PersistenceRoot, globalRoot)
	}
	if imported.Compression != "zstd" {
		t.Fatalf("映射编码 = %q, want zstd", imported.Compression)
	}
}

// 3. 旧映射自升级（工作区来源）：映射无 persistence_root，resume 必须按会话 id
// 在工作区绑定布局定位 artifact，把来源根/编码传给适配器并回写映射。
func TestV095ResumeUpgradesLegacyMappingFromWorkspaceStore(t *testing.T) {
	workspace := t.TempDir()
	canonicalWorkspace := canonicalTestPath(t, workspace)
	writeDSHSessionArtifactForTest(t, filepath.Join(workspace, ".dsh-sessions"), canonicalWorkspace, "legacy-ws-1", `{"type":"user/message"}`)

	resumes := resumeLegacyMappingForV095Test(t, workspace, "legacy-ws-1")
	if len(resumes) != 1 {
		t.Fatalf("resume 次数 = %d, want 1（自升级未生效或未回写映射）", len(resumes))
	}
	if resumes[0].PersistenceRoot != filepath.Join(canonicalWorkspace, ".dsh-sessions") {
		t.Fatalf("resume 来源根 = %q, want 工作区绑定布局根", resumes[0].PersistenceRoot)
	}
	if resumes[0].Compression != "none" {
		t.Fatalf("resume 编码 = %q, want none", resumes[0].Compression)
	}
}

// 4. 旧映射自升级（全局来源）：artifact 只在全局存储（zstd），定位必须落在全局根。
func TestV095ResumeUpgradesLegacyMappingFromGlobalStore(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	globalRoot := filepath.Join(home, ".dsh", "sessions")
	workspace := t.TempDir()
	canonicalWorkspace := canonicalTestPath(t, workspace)
	writeDSHZstdArtifactForTest(t, globalRoot, canonicalWorkspace, "legacy-global-1", `{"type":"user/message"}`)

	resumes := resumeLegacyMappingForV095Test(t, workspace, "legacy-global-1")
	if len(resumes) != 1 {
		t.Fatalf("resume 次数 = %d, want 1（自升级未生效或未回写映射）", len(resumes))
	}
	if resumes[0].PersistenceRoot != globalRoot {
		t.Fatalf("resume 来源根 = %q, want 全局存储根", resumes[0].PersistenceRoot)
	}
	if resumes[0].Compression != "zstd" {
		t.Fatalf("resume 编码 = %q, want zstd", resumes[0].Compression)
	}
}

// ---- 测试脚手架 ----

func canonicalTestPath(t *testing.T, path string) string {
	t.Helper()
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatalf("resolve %s: %v", path, err)
	}
	canonical, err = filepath.Abs(canonical)
	if err != nil {
		t.Fatalf("abs %s: %v", path, err)
	}
	return filepath.Clean(canonical)
}

// importSingleForV095Test 建库、确认工作区并执行一次导入，断言恰好导入目标会话。
func importSingleForV095Test(t *testing.T, root, project, dshID string) DSHImportedSession {
	t.Helper()
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-v095", canonicalTestPath(t, project)); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	imported, err := manager.ImportDSHSessions(context.Background(), "ws-v095", state, false)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(imported) != 1 || imported[0].DSHSessionID != dshID {
		t.Fatalf("expected 1 imported (%s), got %+v", dshID, imported)
	}
	return imported[0]
}

// resumeLegacyMappingForV095Test 写一条旧形状映射（无 persistence_root）并执行
// session.resume，收集流式假适配器收到的 ResumeRequest（runner 对 DSH 走
// ResumeStreaming 句柄交接，普通 Resume 会按 fail-closed 语义无句柄报错）；
// 映射回写完成后才返回（自升级是 resume 路径内的尽力而为动作，轮询等待避免竞态）。
func resumeLegacyMappingForV095Test(t *testing.T, workspace, dshID string) []adapter.ResumeRequest {
	t.Helper()
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = state.Close() })
	streaming := &streamingFakeAdapter{fakeAdapter: newFakeAdapter("dsh")}
	runner := NewSessionRunner(state, map[string]adapter.Adapter{"dsh": streaming}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(func() { _ = runner.Close(context.Background()) })
	if err := state.Set(instanceKey("relay-v095"), string(mustMarshalV095(providerThread{
		Provider: "dsh", InstanceID: dshID, WorkspaceRoot: canonicalTestPath(t, workspace),
	}))); err != nil {
		t.Fatalf("写入旧映射: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.resume",
		PayloadJSON: `{"session_id":"relay-v095","workspace_root":` +
			string(mustMarshalV095(canonicalTestPath(t, workspace))) + `}`,
	}); err != nil {
		t.Fatalf("resume: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		streaming.mu.Lock()
		resumes := append([]adapter.ResumeRequest(nil), streaming.resumes...)
		streaming.mu.Unlock()
		if len(resumes) > 0 {
			if raw, err := state.Get(instanceKey("relay-v095")); err == nil {
				var th providerThread
				if json.Unmarshal([]byte(raw), &th) == nil && th.PersistenceRoot != "" {
					return resumes
				}
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	streaming.mu.Lock()
	defer streaming.mu.Unlock()
	return append([]adapter.ResumeRequest(nil), streaming.resumes...)
}

func mustMarshalV095(value any) []byte {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}

// v0.9.5 P1（持续同步）先红回归：已导入线程的再次导入必须做增量补齐——
// 只携带 watermark 之后的正文（不是重新回填 14 条预览），水位随导入推进，
// 无新行时零事件（去重，不翻倍）。
func TestV095ImportIncrementalSyncsNewMessagesOnly(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	project := filepath.Join(root, "p")
	wsRoot := filepath.Join(project, ".dsh-sessions")
	mustMkdirAll(t, wsRoot)
	mustGitInit(t, project)
	canonicalProject := canonicalTestPath(t, project)

	// 初始 artifact：标题 + 两条消息（行 seq 0..2）。
	writeDSHSessionArtifactForTest(t, wsRoot, canonicalProject, "dsh-incr-1", strings.Join([]string{
		`{"type":"session/title","seq":0,"time":1,"data":{"title":"旧标题"}}`,
		`{"type":"user/message","seq":1,"time":2,"data":{"content":[{"type":"text","text":"旧问题"}]}}`,
		`{"type":"assistant/message","seq":2,"time":3,"data":{"message":{"content":[{"type":"text","text":"旧回答"}]}}}`,
	}, "\n")+"\n")

	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(ctx, "ws-v095-incr", canonicalProject); err != nil {
		t.Fatalf("confirm: %v", err)
	}

	first, err := manager.ImportDSHSessions(ctx, "ws-v095-incr", state, false)
	if err != nil {
		t.Fatalf("first import: %v", err)
	}
	if len(first) != 1 || len(first[0].Messages) != 2 {
		t.Fatalf("首次导入应携带 2 条预览: %+v", first)
	}
	// 回执成功收口后水位才落账（seq=2）；收口前不得提前推进。
	if got, err := state.Get(threadSeqKey(canonicalProject, "dsh-incr-1")); err == nil && got != "" {
		t.Fatalf("回执收口前水位不应落账，实际 %q", got)
	}
	manager.CommitDSHImportWatermarks(state, first)
	if got, err := state.Get(threadSeqKey(canonicalProject, "dsh-incr-1")); err != nil || got != "2" {
		t.Fatalf("首次导入水位 = %q, %v, want \"2\"", got, err)
	}

	// DSH 侧追加：助手回答 + 重写标题 + 新用户消息（seq 3..5）。
	appendLines := strings.Join([]string{
		`{"type":"assistant/message","seq":3,"time":4,"data":{"message":{"content":[{"type":"text","text":"补充回答"}]}}}`,
		`{"type":"session/title","seq":4,"time":5,"data":{"title":"新标题"}}`,
		`{"type":"user/message","seq":5,"time":6,"data":{"content":[{"type":"text","text":"新问题"}]}}`,
	}, "\n") + "\n"
	f, err := os.OpenFile(filepath.Join(wsRoot, dshProjectKeyForTest(canonicalProject), dshEncodeSegmentForTest("dsh-incr-1"), "session.jsonl"), os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(appendLines); err != nil {
		t.Fatal(err)
	}
	f.Close()

	second, err := manager.ImportDSHSessions(ctx, "ws-v095-incr", state, false)
	if err != nil {
		t.Fatalf("second import: %v", err)
	}
	if len(second) != 1 {
		t.Fatalf("第二次导入应复用同一线程: %+v", second)
	}
	if second[0].RelaySessionID != first[0].RelaySessionID {
		t.Fatalf("增量导入必须复用 Relay 会话 id: %s vs %s", second[0].RelaySessionID, first[0].RelaySessionID)
	}
	if len(second[0].Messages) != 2 {
		t.Fatalf("增量应只携带 watermark 之后的 2 条消息: %+v", second[0].Messages)
	}
	if second[0].Messages[0].Text != "补充回答" || second[0].Messages[1].Text != "新问题" {
		t.Fatalf("增量消息内容不符: %+v", second[0].Messages)
	}
	if second[0].Title != "新标题" {
		t.Fatalf("增量标题 = %q, want 新标题", second[0].Title)
	}
	manager.CommitDSHImportWatermarks(state, second)
	if got, err := state.Get(threadSeqKey(canonicalProject, "dsh-incr-1")); err != nil || got != "5" {
		t.Fatalf("增量导入后水位 = %q, %v, want \"5\"", got, err)
	}

	// 第三次：无新行 → 零消息、零标题（不重复回填）。
	third, err := manager.ImportDSHSessions(ctx, "ws-v095-incr", state, false)
	if err != nil {
		t.Fatalf("third import: %v", err)
	}
	if len(third) != 1 || len(third[0].Messages) != 0 || third[0].Title != "" {
		t.Fatalf("无新行时应为零增量: %+v", third)
	}
}

// v0.9.5 P2（按需导入全部）：includeAll=true 时绕过 72h 活跃窗口，把窗口外的
// 历史会话也按需带入；默认（false）维持活跃过滤。
func TestV095ImportIncludeAllBypassesActiveWindow(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}

	staleProject := dshImportFixtureProject(t, filepath.Join(root, "stale"))
	staleCanonical := canonicalTestPath(t, staleProject)
	stalePath := writeDSHSessionArtifactForTest(t,
		filepath.Join(staleProject, ".dsh-sessions"), staleCanonical, "stale-include-1",
		`{"type":"user/message"}`)
	staleTime := time.Now().Add(-10 * 24 * time.Hour)
	if err := os.Chtimes(stalePath, staleTime, staleTime); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(ctx, "ws-v095-all", staleCanonical); err != nil {
		t.Fatalf("confirm: %v", err)
	}

	// 默认：窗口外跳过。
	plain, err := manager.ImportDSHSessions(ctx, "ws-v095-all", state, false)
	if err != nil {
		t.Fatalf("plain import: %v", err)
	}
	if len(plain) != 0 {
		t.Fatalf("窗口外会话默认不得导入: %+v", plain)
	}
	// includeAll：按需带入。
	all, err := manager.ImportDSHSessions(ctx, "ws-v095-all", state, true)
	if err != nil {
		t.Fatalf("include-all import: %v", err)
	}
	if len(all) != 1 || all[0].DSHSessionID != "stale-include-1" {
		t.Fatalf("includeAll 应导入窗口外会话: %+v", all)
	}
}
