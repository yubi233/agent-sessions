package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

// V081-01：存量 Workspace 升级后必须保守标记为 managed，不能因为项目 ID 或路径猜测成 DSH。
func TestWorkspaceProjectionMigrationBackfillsManagedOrigin(t *testing.T) {
	path := filepath.Join(t.TempDir(), "workspace-projection-upgrade.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	legacyCount := len(migrations) - 2
	if legacyCount <= 0 {
		t.Fatal("workspace projection migration boundary is invalid")
	}
	if err := migrateWith(db, migrations[:legacyCount]); err != nil {
		t.Fatalf("build legacy schema: %v", err)
	}
	ctx := context.Background()
	repo := NewRepository(db)
	if err := repo.CreateAccount(ctx, "acct-v081", "v081@test.dev", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	if err := repo.CreateProject(ctx, ProjectRow{ID: "proj-v081", AccountID: "acct-v081", Fingerprint: "fp"}); err != nil {
		t.Fatalf("seed project: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO workspaces(id,project_id,terminal_id,canonical_root,branch,status) VALUES(?,?,?,?,?,?)`,
		"ws-v081", "proj-v081", "term-v081", "/private/legacy/project", "main", "active"); err != nil {
		t.Fatalf("seed legacy workspace: %v", err)
	}

	if err := migrateWith(db, migrations); err != nil {
		t.Fatalf("upgrade workspace projection: %v", err)
	}
	workspace, err := repo.WorkspaceByID(ctx, "ws-v081")
	if err != nil {
		t.Fatalf("read upgraded workspace: %v", err)
	}
	if workspace.Origin != WorkspaceOriginManaged || workspace.DisplayName != "" || workspace.CanonicalRoot != "/private/legacy/project" {
		t.Fatalf("unexpected legacy projection after upgrade: %+v", workspace)
	}
	if err := repo.UpdateWorkspaceDSHMetadata(ctx, workspace.ID, "project"); err != nil {
		t.Fatalf("upgrade same identity to DSH projection: %v", err)
	}
	workspace, err = repo.WorkspaceByID(ctx, workspace.ID)
	if err != nil || workspace.Origin != WorkspaceOriginDSH || workspace.DisplayName != "project" || workspace.CanonicalRoot != "/private/legacy/project" {
		t.Fatalf("unexpected dsh projection after update: %+v err=%v", workspace, err)
	}
}
