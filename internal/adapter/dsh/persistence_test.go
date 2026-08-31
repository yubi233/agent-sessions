package dsh

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func writeSessionArtifact(t *testing.T, root, cwd, id, body string) string {
	return writeSessionArtifactWithSuffix(t, root, cwd, id, body, ".jsonl")
}

func writeSessionArtifactWithSuffix(t *testing.T, root, cwd, id, body, suffix string) string {
	t.Helper()
	path := filepath.Join(root, dshProjectKey(cwd), dshEncodeSegment(id), "session"+suffix)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header, _ := json.Marshal(map[string]any{
		"type": "session", "version": 0, "id": id, "createdAt": 1,
		"cwd": cwd, "delegationDepth": 0,
	})
	payload := append(append(header, '\n'), []byte(body)...)
	if suffix == ".jsonl.zstd" {
		encoder, err := zstd.NewWriter(nil)
		if err != nil {
			t.Fatal(err)
		}
		payload = encoder.EncodeAll(payload, nil)
		encoder.Close()
	}
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestMigrateLegacySessionsSupportsZstdArtifact(t *testing.T) {
	legacy := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	source := writeSessionArtifactWithSuffix(t, legacy, workspace, "zstd-1", `{"type":"user/message"}`, ".jsonl.zstd")
	artifacts, err := ScanSessionArtifacts(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Compression != "zstd" || artifacts[0].ID != "zstd-1" {
		t.Fatalf("扫描压缩 artifact = %+v", artifacts)
	}
	report, err := MigrateLegacySessions(destination, workspace, []string{legacy})
	if err != nil {
		t.Fatal(err)
	}
	if report.Copied != 1 || report.Unsupported != 0 || report.Conflicts != 0 {
		t.Fatalf("压缩迁移报告 = %+v", report)
	}
	if _, err := os.Stat(source); err != nil {
		t.Fatalf("压缩源文件必须保留: %v", err)
	}
	canonicalWorkspace, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(destination, dshProjectKey(canonicalWorkspace), dshEncodeSegment("zstd-1"), "session.jsonl.zstd")
	if _, err := os.Stat(want); err != nil {
		t.Fatalf("压缩目标文件缺失: %v", err)
	}
}

func TestMigrateLegacySessionsTranscodesZstdToPlain(t *testing.T) {
	legacy := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifactWithSuffix(t, legacy, workspace, "zstd-to-plain", `{"type":"user/message"}`, ".jsonl.zstd")
	report, err := MigrateLegacySessionsToCompression(destination, workspace, []string{legacy}, PersistenceCompressionNone)
	if err != nil {
		t.Fatal(err)
	}
	if report.Copied != 1 || report.Conflicts != 0 {
		t.Fatalf("zstd 到 plain 迁移报告 = %+v", report)
	}
	artifacts, _, scanErr := scanSessionArtifacts(destination)
	err = scanErr
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Compression != PersistenceCompressionNone || artifacts[0].ID != "zstd-to-plain" {
		t.Fatalf("zstd 到 plain 目标 = %+v", artifacts)
	}
}

func TestMigrateLegacySessionsTranscodesPlainToZstd(t *testing.T) {
	legacy := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifact(t, legacy, workspace, "plain-to-zstd", `{"type":"user/message"}`)
	report, err := MigrateLegacySessionsToCompression(destination, workspace, []string{legacy}, PersistenceCompressionZstd)
	if err != nil {
		t.Fatal(err)
	}
	if report.Copied != 1 || report.Conflicts != 0 {
		t.Fatalf("plain 到 zstd 迁移报告 = %+v", report)
	}
	artifacts, _, scanErr := scanSessionArtifacts(destination)
	err = scanErr
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Compression != PersistenceCompressionZstd || artifacts[0].ID != "plain-to-zstd" {
		t.Fatalf("plain 到 zstd 目标 = %+v", artifacts)
	}
}

func TestMigrateLegacySessionsRejectsOppositeDestinationEncoding(t *testing.T) {
	legacy := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifact(t, legacy, workspace, "destination-conflict", `{"type":"user/message"}`)
	// 先放入同一会话的另一种后缀，模拟目标根已被错误配置污染。
	canonicalWorkspace, err := canonicalWorkspacePath(workspace)
	if err != nil {
		t.Fatal(err)
	}
	writeSessionArtifactWithSuffix(t, destination, canonicalWorkspace, "destination-conflict", `{"type":"user/message"}`, ".jsonl.zstd")
	report, err := MigrateLegacySessionsToCompression(destination, workspace, []string{legacy}, PersistenceCompressionNone)
	if err != nil {
		t.Fatal(err)
	}
	if report.Conflicts != 1 || report.ConflictReasons["destination_dual_compression"] != 1 {
		t.Fatalf("目标双编码冲突报告 = %+v", report)
	}
}

func TestMigrateLegacySessionsBlocksDualCompression(t *testing.T) {
	legacyPlain := t.TempDir()
	legacyZstd := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifact(t, legacyPlain, workspace, "same", `{"body":"same"}`)
	writeSessionArtifactWithSuffix(t, legacyZstd, workspace, "same", `{"body":"same"}`, ".jsonl.zstd")
	report, err := MigrateLegacySessions(destination, workspace, []string{legacyPlain, legacyZstd})
	if err != nil {
		t.Fatal(err)
	}
	if report.Copied != 0 || report.Conflicts != 1 || report.ConflictReasons["duplicate_id_dual_compression"] != 1 {
		t.Fatalf("双编码冲突报告 = %+v", report)
	}
	destinationPath := filepath.Join(destination, dshProjectKey(workspace), dshEncodeSegment("same"), "session.jsonl")
	if _, err := os.Stat(destinationPath); !os.IsNotExist(err) {
		t.Fatalf("冲突会话不得写入目标，stat err=%v", err)
	}
}

func TestPersistRootForWorkspaceNeverUsesOrCleansTempRoot(t *testing.T) {
	workspace := t.TempDir()
	path, retain, owns, canonical, err := persistRootForWorkspace(workspace)
	if err != nil {
		t.Fatal(err)
	}
	canonicalWorkspace, _ := filepath.EvalSymlinks(workspace)
	want := filepath.Join(canonicalWorkspace, ".dsh-sessions")
	if path != want || !retain || owns || canonical != canonicalWorkspace {
		t.Fatalf("workspace root = path %q retain=%v owns=%v canonical=%q", path, retain, owns, canonical)
	}
	marker := filepath.Join(path, "marker")
	if err := os.WriteFile(marker, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	cleanupPersistPath(path, owns, retain, canonical)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("workspace session marker must survive cleanup: %v", err)
	}
}

func TestCleanupPersistPathProtectsWorkspaceAliasesAndDescendants(t *testing.T) {
	workspace := t.TempDir()
	canonical, err := canonicalWorkspacePath(workspace)
	if err != nil {
		t.Fatal(err)
	}
	protected := filepath.Join(canonical, ".dsh-sessions", "nested")
	if err := os.MkdirAll(protected, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(protected, "marker")
	if err := os.WriteFile(marker, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	cleanupPersistPath(protected, true, false, canonical)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("workspace 持久化子路径必须保留: %v", err)
	}
	alias := filepath.Join(t.TempDir(), "workspace-alias")
	if err := os.Symlink(canonical, alias); err != nil {
		t.Skipf("当前平台不支持符号链接: %v", err)
	}
	cleanupPersistPath(filepath.Join(alias, ".dsh-sessions", "nested"), true, false, alias)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("workspace 符号链接别名下的持久化子路径必须保留: %v", err)
	}
}

func TestMigrateLegacySessionsIsIdempotentAndPreservesSource(t *testing.T) {
	legacy := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	// 保证工作区路径稳定存在；迁移只需要用 header cwd 判断归属。
	source := writeSessionArtifact(t, legacy, workspace, "sess-1", `{"type":"user/message"}`)
	report, err := MigrateLegacySessions(destination, workspace, []string{legacy})
	if err != nil {
		t.Fatal(err)
	}
	if report.Copied != 1 || report.Conflicts != 0 {
		t.Fatalf("first migration report = %+v", report)
	}
	if _, err := os.Stat(source); err != nil {
		t.Fatalf("source must not be deleted: %v", err)
	}
	report, err = MigrateLegacySessions(destination, workspace, []string{legacy})
	if err != nil {
		t.Fatal(err)
	}
	if report.AlreadyPresent != 1 || report.Copied != 0 || report.Conflicts != 0 {
		t.Fatalf("second migration report = %+v", report)
	}
}

func TestMigrateLegacySessionsBlocksDigestConflict(t *testing.T) {
	legacyA := t.TempDir()
	legacyB := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifact(t, legacyA, workspace, "same", `{"body":"a"}`)
	writeSessionArtifact(t, legacyB, workspace, "same", `{"body":"b"}`)
	report, err := MigrateLegacySessions(destination, workspace, []string{legacyA, legacyB})
	if err != nil {
		t.Fatal(err)
	}
	if report.Copied != 0 || report.Conflicts != 1 || report.ConflictReasons["duplicate_id_digest_mismatch"] != 1 {
		t.Fatalf("conflict report = %+v", report)
	}
	destinationPath := filepath.Join(destination, dshProjectKey(workspace), dshEncodeSegment("same"), "session.jsonl")
	if _, err := os.Stat(destinationPath); !os.IsNotExist(err) {
		t.Fatalf("摘要冲突会话不得写入目标，stat err=%v", err)
	}
}

func TestMigrateLegacySessionsCountsInvalidArtifacts(t *testing.T) {
	legacy := t.TempDir()
	destination := t.TempDir()
	workspace := t.TempDir()
	path := filepath.Join(legacy, dshProjectKey(workspace), dshEncodeSegment("bad"), "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("not-json\nsecret-body\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	report, err := MigrateLegacySessions(destination, workspace, []string{legacy})
	if err != nil {
		t.Fatal(err)
	}
	if report.Unsupported != 1 || report.Copied != 0 {
		t.Fatalf("无效 artifact 报告 = %+v", report)
	}
}

func TestSessionPathEncodingMatchesDSHUTF16Layout(t *testing.T) {
	if got, want := dshEncodeSegment("😀"), "~D83D~DE00"; got != want {
		t.Fatalf("非 BMP 会话 id 编码 = %q, want %q", got, want)
	}
	if got, want := dshProjectKey("/tmp/😀"), "--tmp-~D83D~DE00--"; got != want {
		t.Fatalf("非 BMP 工作区键 = %q, want %q", got, "--tmp-~D83D~DE00--")
	}
}

func TestScanSessionArtifactsRejectsHeaderPathMismatch(t *testing.T) {
	legacy := t.TempDir()
	workspace := t.TempDir()
	path := filepath.Join(legacy, dshProjectKey(workspace), dshEncodeSegment("directory-id"), "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header, _ := json.Marshal(map[string]any{
		"type": "session", "version": 0, "id": "header-id", "createdAt": 1,
		"cwd": workspace, "delegationDepth": 0,
	})
	if err := os.WriteFile(path, append(append(header, '\n'), []byte(`{"type":"user/message"}`)...), 0o600); err != nil {
		t.Fatal(err)
	}
	artifacts, err := ScanSessionArtifacts(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("路径与 header 不一致的 artifact 不得被接受: %+v", artifacts)
	}
}

func TestScanSessionArtifactsRejectsUnexpectedNesting(t *testing.T) {
	legacy := t.TempDir()
	workspace := t.TempDir()
	path := filepath.Join(legacy, "nested", dshProjectKey(workspace), dshEncodeSegment("nested-id"), "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header, _ := json.Marshal(map[string]any{
		"type": "session", "version": 0, "id": "nested-id", "createdAt": 1,
		"cwd": workspace, "delegationDepth": 0,
	})
	if err := os.WriteFile(path, append(append(header, '\n'), []byte(`{"type":"user/message"}`)...), 0o600); err != nil {
		t.Fatal(err)
	}
	artifacts, err := ScanSessionArtifacts(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("层级异常的 artifact 不得被接受: %+v", artifacts)
	}
}

func TestPrepareWorkspacePersistenceUsesConfiguredCompression(t *testing.T) {
	legacy := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifact(t, legacy, workspace, "prepare-zstd", `{"type":"user/message"}`)
	t.Setenv(legacyRootsEnv, legacy)
	t.Setenv(EnvBin, filepath.Join(t.TempDir(), "bin.js"))
	t.Setenv(EnvPersistCompression, PersistenceCompressionZstd)
	a := &Adapter{production: true}
	if err := a.prepareWorkspacePersistence(workspace); err != nil {
		t.Fatalf("准备 workspace 持久化: %v", err)
	}
	canonicalWorkspace, err := canonicalWorkspacePath(workspace)
	if err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(canonicalWorkspace, ".dsh-sessions")
	artifacts, err := ScanSessionArtifacts(destination)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Compression != PersistenceCompressionZstd {
		t.Fatalf("目标压缩格式 = %+v", artifacts)
	}
	if artifacts[0].CWD != canonicalWorkspace {
		t.Fatalf("迁移 header cwd = %q, want %q", artifacts[0].CWD, canonicalWorkspace)
	}
}

func TestPrepareWorkspacePersistenceFailsClosedOnMigrationConflict(t *testing.T) {
	legacyA := t.TempDir()
	legacyB := t.TempDir()
	workspace := t.TempDir()
	writeSessionArtifact(t, legacyA, workspace, "prepare-conflict", `{"body":"a"}`)
	writeSessionArtifact(t, legacyB, workspace, "prepare-conflict", `{"body":"b"}`)
	t.Setenv(legacyRootsEnv, legacyA+string(os.PathListSeparator)+legacyB)
	t.Setenv(EnvBin, filepath.Join(t.TempDir(), "bin.js"))
	t.Setenv(EnvPersistCompression, PersistenceCompressionNone)
	a := &Adapter{production: true}
	if err := a.prepareWorkspacePersistence(workspace); err == nil {
		t.Fatal("迁移摘要冲突必须 fail-closed")
	}
}

func TestConfiguredPersistenceCompressionRejectsUnknownValue(t *testing.T) {
	t.Setenv(EnvPersistCompression, "brotli")
	if _, err := configuredPersistenceCompression(); err == nil {
		t.Fatal("未知 artifact 编码必须拒绝")
	}
}
