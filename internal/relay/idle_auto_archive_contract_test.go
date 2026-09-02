package relay

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// 会话永不因空闲时长自动休眠或归档：默认列表始终保留 Relay/Terminal 上报的状态。
// 归档仍是显式用户操作，GET /v1/sessions?archived=true 只读取显式归档结果。
func TestIdleSessionsRemainVisibleWithoutAutomaticArchive(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "idle-auto-archive@test.dev")
	terminal := env.pairTerminal(t, owner, "idle-auto-archive-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	ctx := t.Context()

	seed := func(t *testing.T, name, status string, activity time.Time) string {
		t.Helper()
		sessionID, _ := env.createBoundSession(t, owner, terminalID, "idle-archive-"+name)
		if err := env.repo.SetSessionStatusAt(ctx, sessionID, status, activity.UnixMilli()); err != nil {
			t.Fatalf("set status: %v", err)
		}
		return sessionID
	}

	now := time.Now()
	staleIdle := seed(t, "stale", domain.SessionIdle, now.Add(-48*time.Hour))
	legacyIdle := seed(t, "legacy", domain.SessionIdle, time.Time{}) // 活动时间未知
	freshIdle := seed(t, "fresh", domain.SessionIdle, now.Add(-time.Minute))
	stoppedOld := seed(t, "stopped", domain.SessionStopped, now.Add(-72*time.Hour))

	listIDs := func(archived bool) map[string]bool {
		t.Helper()
		path := "/v1/sessions"
		if archived {
			path += "?archived=true"
		}
		response := env.do(t, http.MethodGet, path, nil, owner.AccessToken)
		if response.Code != http.StatusOK {
			t.Fatalf("list sessions status=%d body=%s", response.Code, response.Body.String())
		}
		var list struct {
			Sessions []struct {
				ID               string `json:"id"`
				ArchivedAtUnixMS int64  `json:"archived_at_unix_ms"`
			} `json:"sessions"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &list); err != nil {
			t.Fatalf("decode list: %v", err)
		}
		ids := map[string]bool{}
		for _, item := range list.Sessions {
			ids[item.ID] = true
			if archived && item.ArchivedAtUnixMS == 0 {
				t.Fatalf("archived session %s missing archived_at_unix_ms", item.ID)
			}
		}
		return ids
	}

	defaultIDs := listIDs(false)
	for _, id := range []string{staleIdle, legacyIdle, freshIdle, stoppedOld} {
		if !defaultIDs[id] {
			t.Fatalf("session %s must remain in the default list regardless of age", id)
		}
	}

	archivedIDs := listIDs(true)
	if len(archivedIDs) != 0 {
		t.Fatalf("no session should be auto-archived, got %v", archivedIDs)
	}

	var auditCount int
	rows, err := env.repo.ListAudit(ctx, owner.AccountID, 100, 0)
	if err != nil {
		t.Fatalf("list audit: %v", err)
	}
	for _, row := range rows {
		if row.Action == "session.auto_archived" {
			auditCount++
		}
	}
	if auditCount != 0 {
		t.Fatalf("auto_archived audit rows=%d, want 0", auditCount)
	}

	// 显式归档仍然可逆：归档后从默认列表隐藏，再恢复到默认列表。
	archive := env.do(t, http.MethodPost, "/v1/sessions/"+staleIdle+"/archive", nil, owner.AccessToken)
	if archive.Code != http.StatusOK {
		t.Fatalf("archive status=%d body=%s", archive.Code, archive.Body.String())
	}
	defaultIDs = listIDs(false)
	if defaultIDs[staleIdle] {
		t.Fatalf("explicitly archived session must leave the default list")
	}
	unarchive := env.do(t, http.MethodPost, "/v1/sessions/"+staleIdle+"/unarchive", nil, owner.AccessToken)
	if unarchive.Code != http.StatusOK {
		t.Fatalf("unarchive status=%d body=%s", unarchive.Code, unarchive.Body.String())
	}
	defaultIDs = listIDs(false)
	if !defaultIDs[staleIdle] {
		t.Fatalf("unarchived session must return to the default list")
	}
}
