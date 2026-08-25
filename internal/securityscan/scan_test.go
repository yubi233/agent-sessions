package securityscan

import (
	"os"
	"path/filepath"
	"testing"
)

// 含敏感标记的文件应被扫描命中。
func TestScanDetectsSecret(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "leak.go"), []byte("const token = \"Bearer abc123\"\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "safe.go"), []byte("package x\n"), 0o600)

	hits, err := ScanPath(dir)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(hits) != 1 || filepath.Base(hits[0]) != "leak.go" {
		t.Fatalf("want 1 hit leak.go, got %v", hits)
	}
}

// 表名/列名不是泄漏。
func TestScanIgnoresColumnNames(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "mig.go"), []byte("CREATE TABLE recovery_codes(account_id TEXT, password_hash BLOB);\n"), 0o600)
	hits, err := ScanPath(dir)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(hits) != 0 {
		t.Fatalf("column names should not be flagged, got %v", hits)
	}
}

// 依赖目录应被跳过。
func TestScanSkipsDeps(t *testing.T) {
	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, "node_modules"), 0o700)
	_ = os.WriteFile(filepath.Join(dir, "node_modules", "x.js"), []byte("secret=xxx\n"), 0o600)

	hits, err := ScanPath(dir)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(hits) != 0 {
		t.Fatalf("expected no hits in deps, got %v", hits)
	}
}

// 本地 .task 运行态可能包含测试 token，但该目录已被 .gitignore 排除，不能阻塞交付扫描。
func TestScanSkipsLocalRuntimeState(t *testing.T) {
	dir := t.TempDir()
	runtimeDir := filepath.Join(dir, ".task", "restart")
	if err := os.MkdirAll(runtimeDir, 0o700); err != nil {
		t.Fatalf("mkdir runtime state: %v", err)
	}
	if err := os.WriteFile(filepath.Join(runtimeDir, "owner.json"), []byte(`{"refresh_token":"local-only"}`), 0o600); err != nil {
		t.Fatalf("write runtime state: %v", err)
	}
	hits, err := ScanPath(dir)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(hits) != 0 {
		t.Fatalf("local runtime state should be skipped, got %v", hits)
	}
}

func TestScanAllowsDynamicAuthorizationButRejectsHardcodedBearer(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "dynamic.ts"), []byte("headers: { Authorization: `Bearer ${accessToken}` }\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "dynamic.go"), []byte("req.Header.Set(\"Authorization\", \"Bearer \"+token)\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "hardcoded.ts"), []byte("const authorization = 'Bearer production-secret-value'\n"), 0o600)

	hits, err := ScanPath(dir)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(hits) != 1 || filepath.Base(hits[0]) != "hardcoded.ts" {
		t.Fatalf("want only hardcoded bearer hit, got %v", hits)
	}
}

func TestScanSkipsNonGoTestFixtures(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "authorization.test.mjs"), []byte("const token = 'Bearer fixture-owner-access-token'\n"), 0o600)

	hits, err := ScanPath(dir)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(hits) != 0 {
		t.Fatalf("test fixture should not be scanned, got %v", hits)
	}
}

// 明文探针标记（正文、diff）应被捕获。
func TestContainsSensitive(t *testing.T) {
	if !ContainsSensitive(`"refresh_token":"tf_x.y"`) {
		t.Fatalf("should detect refresh_token")
	}
	if ContainsSensitive("hello world") {
		t.Fatalf("should not detect normal text")
	}
}
