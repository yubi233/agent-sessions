package domain

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// seedUsageAccount 创建满足外键链的 account + terminal，供 usage 测试使用。
func seedUsageAccount(t *testing.T, repo store.Repository, acctID, termID string) {
	t.Helper()
	ctx := context.Background()
	if err := repo.CreateAccount(ctx, acctID, acctID+"@test.dev", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: termID + "-dev", AccountID: acctID, Role: "terminal", Status: "active",
		DisplayName: "fixture-terminal", Platform: "macos",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	if err := repo.CreateTerminal(ctx, store.TerminalRow{
		ID: termID, DeviceID: termID + "-dev", AccountID: acctID,
		Hostname: "fixture-host", Platform: "macos", Status: "online",
	}); err != nil {
		t.Fatalf("create terminal: %v", err)
	}
}

// TestUsageUploadDeduplicatesByKey 验证 usage_key_hash 唯一约束去重：
// 相同 key 第二次上传返回 inserted=false，聚合数字不重复累加。
func TestUsageUploadDeduplicatesByKey(t *testing.T) {
	db, err := store.Open(t.TempDir() + "/relay.db")
	repo := store.NewRepository(db)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	seedUsageAccount(t, repo, "acct-1", "term-1")
	svc := NewUsageService(repo)

	ctx := context.Background()
	inserted, err := svc.UploadUsageEvent(ctx, "acct-1", "term-1", UsageEventInput{
		UsageKey: "session-1:event-5:codex", Provider: "codex",
		UTCDay: "2026-08-16", InputTokens: 100, OutputTokens: 50,
	})
	if err != nil {
		t.Fatalf("first upload: %v", err)
	}
	if !inserted {
		t.Fatal("first upload should insert")
	}
	inserted, err = svc.UploadUsageEvent(ctx, "acct-1", "term-1", UsageEventInput{
		UsageKey: "session-1:event-5:codex", Provider: "codex",
		UTCDay: "2026-08-16", InputTokens: 100, OutputTokens: 50,
	})
	if err != nil {
		t.Fatalf("second upload: %v", err)
	}
	if inserted {
		t.Fatal("duplicate usage key must not re-insert")
	}

	summary, err := svc.Summary(ctx, "acct-1", 7, time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if summary.TotalInput != 100 || summary.TotalOutput != 50 {
		t.Fatalf("aggregate must count once: input=%d output=%d", summary.TotalInput, summary.TotalOutput)
	}
}

// TestUsageSummaryScopedToAccount 验证聚合按账号隔离：其它账号的事件不出现在当前账号摘要。
func TestUsageSummaryScopedToAccount(t *testing.T) {
	db, err := store.Open(t.TempDir() + "/relay.db")
	repo := store.NewRepository(db)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	seedUsageAccount(t, repo, "acct-a", "term-a")
	seedUsageAccount(t, repo, "acct-b", "term-b")
	svc := NewUsageService(repo)
	ctx := context.Background()

	for _, acct := range []string{"acct-a", "acct-b"} {
		termID := "term-" + acct[len(acct)-1:]
		if _, err := svc.UploadUsageEvent(ctx, acct, termID, UsageEventInput{
			UsageKey: acct + ":event:codex", Provider: "codex",
			UTCDay: "2026-08-16", InputTokens: 999, OutputTokens: 1,
		}); err != nil {
			t.Fatal(err)
		}
	}

	summary, err := svc.Summary(ctx, "acct-a", 7, time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if summary.TotalInput != 999 || summary.TotalOutput != 1 {
		t.Fatalf("account scope broken: %+v", summary)
	}
	if len(summary.Providers) != 1 || summary.Providers[0].Provider != "codex" {
		t.Fatalf("providers projection unexpected: %+v", summary.Providers)
	}
}

// TestUsageRejectsInvalidInput 验证无效时间桶、超限值与空 key 返回稳定错误。
func TestUsageRejectsInvalidInput(t *testing.T) {
	db, err := store.Open(t.TempDir() + "/relay.db")
	repo := store.NewRepository(db)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	svc := NewUsageService(repo)
	ctx := context.Background()

	cases := []UsageEventInput{
		{UsageKey: "", Provider: "codex", UTCDay: "2026-08-16", InputTokens: 1},
		{UsageKey: "k", Provider: "", UTCDay: "2026-08-16", InputTokens: 1},
		{UsageKey: "k", Provider: "codex", UTCDay: "16-08-2026", InputTokens: 1},
		{UsageKey: "k", Provider: "codex", UTCDay: "2026-08-16", InputTokens: -1},
		{UsageKey: "k", Provider: "codex", UTCDay: "2026-08-16", InputTokens: UsageMaxTokenValue + 1},
	}
	for i, input := range cases {
		_, err := svc.UploadUsageEvent(ctx, "acct-1", "term-1", input)
		if err == nil {
			t.Fatalf("case %d should fail", i)
		}
		// protocol.NewError 返回值类型 APIError；这里直接断言其稳定错误码存在。
		if !errors.Is(err, protocol.APIError{}) && strings.Contains(err.Error(), "INVALID_REQUEST") == false {
			t.Fatalf("case %d must be stable protocol error, got: %v", i, err)
		}
	}

	// 非法 days 参数拒绝。
	if _, err := svc.Summary(ctx, "acct-1", 5, time.Now()); err == nil {
		t.Fatal("days=5 should be rejected")
	}
}
