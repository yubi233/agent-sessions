package relay

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// 休眠自动归档契约：idle 且最后活动超过 24h（或活动时间未知）的会话在读取列表时
// 自动转入归档；fresh idle、streaming、stopped 不参与。归档可逆（unarchive 恢复），
// 写审计；GET /v1/sessions?archived=true 读取归档列表且不触发 sweep。
func TestIdleSessionsAutoArchiveAfterTTL(t *testing.T) {
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
	if defaultIDs[staleIdle] || defaultIDs[legacyIdle] {
		t.Fatalf("stale/legacy idle sessions must be auto-archived out of the default list")
	}
	if !defaultIDs[freshIdle] || !defaultIDs[stoppedOld] {
		t.Fatalf("fresh idle and stopped sessions must stay in the default list")
	}

	archivedIDs := listIDs(true)
	if !archivedIDs[staleIdle] || !archivedIDs[legacyIdle] {
		t.Fatalf("archived list must contain the auto-archived sessions")
	}
	if archivedIDs[freshIdle] || archivedIDs[stoppedOld] {
		t.Fatalf("fresh idle / stopped sessions must not be archived")
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
	if auditCount < 2 {
		t.Fatalf("auto_archived audit rows=%d, want at least 2", auditCount)
	}

	// 归档可逆：unarchive 后回到默认列表。
	unarchive := env.do(t, http.MethodPost, "/v1/sessions/"+staleIdle+"/unarchive", nil, owner.AccessToken)
	if unarchive.Code != http.StatusOK {
		t.Fatalf("unarchive status=%d body=%s", unarchive.Code, unarchive.Body.String())
	}
	defaultIDs = listIDs(false)
	if !defaultIDs[staleIdle] {
		t.Fatalf("unarchived session must return to the default list")
	}
}
