package relay

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// 会话列表契约：session 元数据必须携带 last_activity_at_unix_ms，且默认列表按
// 真实活动时间倒序。Flutter 的「最后消息时间」展示和排序消费这个字段；它不能
// 参与会话状态推断。last_seq 是会话内局部序号，不得作为跨会话排序依据。
func TestSessionListExposesActivityAndOrdersByIt(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "session-activity-order@test.dev")
	terminal := env.pairTerminal(t, owner, "session-activity-order-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	ctx := t.Context()

	base := time.Now().Add(-time.Hour)
	activityBySession := map[string]time.Time{}
	var older, middle, newer string
	for i, name := range []string{"older", "middle", "newer"} {
		sessionID, _ := env.createBoundSession(t, owner, terminalID, "session-activity-order-"+name)
		at := base.Add(time.Duration(i) * time.Minute)
		if err := env.repo.SetSessionStatusAt(ctx, sessionID, domain.SessionIdle, at.UnixMilli()); err != nil {
			t.Fatalf("set activity: %v", err)
		}
		activityBySession[sessionID] = at
		switch name {
		case "older":
			older = sessionID
		case "middle":
			middle = sessionID
		case "newer":
			newer = sessionID
		}
	}

	response := env.do(t, http.MethodGet, "/v1/sessions", nil, owner.AccessToken)
	if response.Code != http.StatusOK {
		t.Fatalf("list sessions status=%d body=%s", response.Code, response.Body.String())
	}
	var list struct {
		Sessions []struct {
			ID                  string `json:"id"`
			LastActivityAtMS    int64  `json:"last_activity_at_unix_ms"`
			LastActivityPresent bool   `json:"-"`
		} `json:"sessions"`
	}
	dec := json.NewDecoder(response.Body)
	if err := dec.Decode(&list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list.Sessions) < 3 {
		t.Fatalf("sessions=%d, want at least 3", len(list.Sessions))
	}
	seen := map[string]int64{}
	order := []string{}
	for _, item := range list.Sessions {
		seen[item.ID] = item.LastActivityAtMS
		order = append(order, item.ID)
		if item.LastActivityAtMS == 0 {
			t.Fatalf("session %s missing last_activity_at_unix_ms", item.ID)
		}
	}
	for sessionID, want := range activityBySession {
		if got := seen[sessionID]; got != want.UnixMilli() {
			t.Fatalf("session %s activity=%d, want %d", sessionID, got, want.UnixMilli())
		}
	}
	// 活动时间新的必须排在旧的前面；同批三个固定相对顺序。
	pos := map[string]int{}
	for i, id := range order {
		pos[id] = i
	}
	if !(pos[newer] < pos[middle] && pos[middle] < pos[older]) {
		t.Fatalf("order=%v, want newer<middle<older (ids %s / %s / %s)", order, newer, middle, older)
	}
}
