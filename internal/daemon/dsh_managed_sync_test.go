package daemon

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

// v0.9.6 受管同步回归：缺省（discover=false）绝不发现未知 artifact；原生会话
// 复用原 Relay ID 且零正文；来源绑定冲突 fail-closed；导入事件 ID 稳定。
func TestDSHManagedSyncNeverDiscoversUnknownArtifacts(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustGitInit(t, project)
	canonicalProject, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatalf("resolve project: %v", err)
	}
	writeDSHSessionArtifactForTest(t, filepath.Join(project, ".dsh-sessions"), canonicalProject, "dsh-unknown", `{"type":"user/message"}`)

	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	// 空允许列表的同步：不扫描发现、不产生新投影。
	imported, err := manager.ImportDSHSessionsWithOptions(context.Background(), "ws-dsh", state, DSHImportOptions{SessionIDs: []string{}})
	if err != nil {
		t.Fatalf("managed sync: %v", err)
	}
	if len(imported) != 0 {
		t.Fatalf("缺省同步不得发现未知 artifact: %+v", imported)
	}
	// 显式发现（活跃窗口内）才能带回候选。
	imported, err = manager.ImportDSHSessionsWithOptions(context.Background(), "ws-dsh", state, DSHImportOptions{Discover: true})
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	if len(imported) != 1 {
		t.Fatalf("显式发现应带回 1 个候选: %+v", imported)
	}
}

func TestDSHNativeBindingReusedByImportWithoutBody(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustGitInit(t, project)
	canonicalProject, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatalf("resolve project: %v", err)
	}
	writeDSHSessionArtifactForTest(t, filepath.Join(project, ".dsh-sessions"), canonicalProject, "dsh-native-1",
		`{"type":"user/message"}`+"\n"+`{"type":"assistant/message"}`)

	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	// 原生 start 先注册绑定（与 runner.startSession 同路径）。
	thread := providerThread{Provider: "dsh", InstanceID: "dsh-native-1", WorkspaceRoot: canonicalProject}
	if _, err := state.BindDSHThread("sess_native", thread, dshSourceNative); err != nil {
		t.Fatalf("native bind: %v", err)
	}
	// 允许列表同步：复用原生 ID，且绝不携带正文/水位。
	imported, err := manager.ImportDSHSessionsWithOptions(context.Background(), "ws-dsh", state, DSHImportOptions{SessionIDs: []string{"sess_native"}})
	if err != nil {
		t.Fatalf("managed sync: %v", err)
	}
	if len(imported) != 1 {
		t.Fatalf("expected native item, got %+v", imported)
	}
	if imported[0].RelaySessionID != "sess_native" {
		t.Fatalf("原生源必须复用原 Relay ID: %+v", imported[0])
	}
	if len(imported[0].Messages) != 0 || imported[0].WatermarkValid {
		t.Fatalf("原生正文只属于实时/回放链路: %+v", imported[0])
	}
	// 重复同步不增长、不重复导入。
	again, err := manager.ImportDSHSessionsWithOptions(context.Background(), "ws-dsh", state, DSHImportOptions{SessionIDs: []string{"sess_native"}})
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if len(again) != 1 || again[0].RelaySessionID != "sess_native" || len(again[0].Messages) != 0 {
		t.Fatalf("重复同步语义漂移: %+v", again)
	}
	// 原生源已绑定管理，不是历史候选：显式发现不得把它当作候选重复上报。
	discovered, err := manager.ImportDSHSessionsWithOptions(context.Background(), "ws-dsh", state, DSHImportOptions{Discover: true})
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	for _, item := range discovered {
		if item.DSHSessionID == "dsh-native-1" {
			t.Fatalf("已绑定的原生源不得进入发现候选: %+v", item)
		}
	}
}

func TestDSHBindConflictFailsClosed(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "p")
	mustGitInit(t, project)
	canonicalProject, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatalf("resolve project: %v", err)
	}
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	thread := providerThread{Provider: "dsh", InstanceID: "dsh-src-1",
		WorkspaceRoot: canonicalProject, PersistenceRoot: filepath.Join(project, ".dsh-sessions")}
	if _, err := state.BindDSHThread("sess_imported", thread, dshSourceImported); err != nil {
		t.Fatalf("import bind: %v", err)
	}
	// 另一个会话声称拥有同一来源：必须冲突，绝不静默覆盖或合并。
	if _, err := state.BindDSHThread("sess_native", thread, dshSourceNative); !errors.Is(err, ErrDSHSourceConflict) {
		t.Fatalf("expected source conflict, got %v", err)
	}
	reverse, err := state.Get(dshThreadKey(canonicalProject, "dsh-src-1"))
	if err != nil || reverse != "sess_imported" {
		t.Fatalf("冲突后反向映射不得被改写: %q %v", reverse, err)
	}
}

func TestDSHImportEventIDStable(t *testing.T) {
	first := dshImportEventID("sess_a", 12, "user.message")
	if first != dshImportEventID("sess_a", 12, "user.message") {
		t.Fatal("同源消息的事件 ID 必须跨命令稳定")
	}
	for _, other := range []struct {
		session string
		seq     int64
		event   string
	}{
		{"sess_b", 12, "user.message"},
		{"sess_a", 13, "user.message"},
		{"sess_a", 12, "message.completed"},
	} {
		if dshImportEventID(other.session, other.seq, other.event) == first {
			t.Fatalf("不同源消息不得共用事件 ID: %+v", other)
		}
	}
}
