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
	imported, err := manager.ImportDSHSessions(context.Background(), "ws-v095", state)
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
