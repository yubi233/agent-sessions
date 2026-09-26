package domain

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// v0.9.6 展示边界回归：历史候选只有显式接续（ManageSession）才进入默认列表；
// 确证重复副本不可借接续复活；只读设备不可接续。
func TestManageSessionPromotesHistoryOnly(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	seedAccountProjectWorkspace(t, repo)
	svc := NewSessionService(repo)

	seed := func(id, provider, origin, visibility string) {
		t.Helper()
		if err := repo.CreateSession(ctx, store.SessionRow{
			ID: id, WorkspaceID: "ws", AccountID: "acct", Status: SessionIdle,
			Provider: provider, Origin: origin, Visibility: visibility,
		}); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	seed("sess_hist", "dsh", store.SessionOriginDSHImport, store.SessionVisibilityHistory)
	seed("sess_dup", "dsh", store.SessionOriginDSHImport, store.SessionVisibilityDuplicate)
	seed("sess_default", "mock", store.SessionOriginManaged, store.SessionVisibilityDefault)

	if _, err := svc.ManageSession(ctx, "acct", "android_owner", "sess_hist"); err != nil {
		t.Fatalf("manage history: %v", err)
	}
	managed, err := repo.SessionByID(ctx, "sess_hist")
	if err != nil {
		t.Fatal(err)
	}
	if managed.Visibility != store.SessionVisibilityDefault || managed.Origin != store.SessionOriginDSHImport {
		t.Fatalf("接续只提升可见性并保留来源: %+v", managed)
	}
	// 幂等：重复接续不报错、不改来源。
	if _, err := svc.ManageSession(ctx, "acct", "android_owner", "sess_hist"); err != nil {
		t.Fatalf("second manage must be idempotent: %v", err)
	}
	if _, err := svc.ManageSession(ctx, "acct", "android_owner", "sess_dup"); err == nil {
		t.Fatal("重复副本不可接续复活")
	} else if !strings.Contains(err.Error(), "scope") && err != ErrScopeDenied {
		t.Fatalf("重复副本应拒绝且归因 scope: %v", err)
	}
	// 跨账号拒绝。
	if _, err := svc.ManageSession(ctx, "other", "android_owner", "sess_hist"); err != ErrScopeDenied {
		t.Fatalf("跨账号应拒绝: %v", err)
	}
	// 只读设备拒绝。
	if _, err := svc.ManageSession(ctx, "acct", "web_readonly", "sess_hist"); err != ErrReadOnlyDevice {
		t.Fatalf("只读设备应拒绝: %v", err)
	}
}

func seedAccountProjectWorkspace(t *testing.T, repo store.Repository) {
	t.Helper()
	ctx := context.Background()
	if err := repo.CreateAccount(ctx, "acct", "manage-t@t", []byte("h"), time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := repo.CreateProject(ctx, store.ProjectRow{ID: "proj", AccountID: "acct", Fingerprint: "fp"}); err != nil {
		t.Fatal(err)
	}
	if err := repo.CreateWorkspace(ctx, store.WorkspaceRow{ID: "ws", ProjectID: "proj", CanonicalRoot: filepath.Clean("/ws"), Status: "active"}); err != nil {
		t.Fatal(err)
	}
}
