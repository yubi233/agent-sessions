package relay

import (
	"net/http"
	"testing"
	"time"
)

// v0.9.1 P0（迭代计划 §4 P0）：deadline 权威投影与统一命令安全门的 HTTP 集成回归。
// 覆盖 V091-03/04；根因层单元口径（V091-01/02/05）见 internal/domain/v091_presence_contract_test.go。
//
// 模拟方式：presence 投影只依赖「服务端当前时间 - last_heartbeat_unix_ms」，
// 因此测试直接把存量 last_heartbeat 拨回过去即可确定性地推进服务端时钟视角，
// 无需缩短阈值或依赖真实 sleep，也不启动任何后台 sweeper。

// v091AgeLastHeartbeat 把 Terminal 的最后心跳拨回到 now-ageMS，模拟心跳停止。
func v091AgeLastHeartbeat(t *testing.T, env *testEnv, terminalID string, ageMS int64) {
	t.Helper()
	cutoff := time.Now().UnixMilli() - ageMS
	if _, err := env.db.Exec(
		`UPDATE terminals SET last_heartbeat_unix_ms=? WHERE id=?`, cutoff, terminalID); err != nil {
		t.Fatalf("age last heartbeat: %v", err)
	}
}

// v091TerminalsView 解析 GET /v1/terminals 的 additive presence 投影。
func v091TerminalsView(t *testing.T, env *testEnv, token string) []struct {
	ID                  string `json:"id"`
	Status              string `json:"status"`
	Availability        string `json:"availability"`
	PresenceRevision    int64  `json:"presence_revision"`
	LastHeartbeatUnixMS int64  `json:"last_heartbeat_unix_ms"`
	NextCheckUnixMS     int64  `json:"next_check_unix_ms"`
} {
	t.Helper()
	response := env.do(t, http.MethodGet, "/v1/terminals", nil, token)
	if response.Code != http.StatusOK {
		t.Fatalf("list terminals status=%d body=%s", response.Code, response.Body.String())
	}
	var view struct {
		Terminals []struct {
			ID                  string `json:"id"`
			Status              string `json:"status"`
			Availability        string `json:"availability"`
			PresenceRevision    int64  `json:"presence_revision"`
			LastHeartbeatUnixMS int64  `json:"last_heartbeat_unix_ms"`
			NextCheckUnixMS     int64  `json:"next_check_unix_ms"`
		} `json:"terminals"`
	}
	decodeW1(t, response.Body.Bytes(), &view)
	if len(view.Terminals) == 0 {
		t.Fatalf("empty terminals view: %s", response.Body.String())
	}
	return view.Terminals
}

// v091DeliveryCount 读取该 Terminal 的命令投递行数（脱敏计数，不读正文）。
func v091DeliveryCount(t *testing.T, env *testEnv, terminalID string) int {
	t.Helper()
	var count int
	if err := env.db.QueryRow(
		`SELECT COUNT(1) FROM daemon_command_deliveries WHERE terminal_id=?`, terminalID).Scan(&count); err != nil {
		t.Fatalf("count deliveries: %v", err)
	}
	return count
}

// V091-03：漏 heartbeat 后，/v1/terminals 的 availability 由 read path 在 deadline
// 边界即时投影 offline，不依赖后台 sweeper/reaper；多次读取稳定且不重复翻转；
// additive 字段（presence_revision / last_heartbeat / next_check）与事实一致。
func TestV091RelayProjectsOfflineAfterDeadlineWithoutSweeper(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v091-deadline@test.dev")
	terminal := env.pairTerminal(t, owner, "v091-deadline-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)

	// 新鲜心跳：online + next_check 指向 online->unknown 边界。
	view := v091TerminalsView(t, env, owner.AccessToken)
	if view[0].Availability != "online" || view[0].Status != "online" {
		t.Fatalf("fresh availability=%q status=%q, want online/online", view[0].Availability, view[0].Status)
	}
	if view[0].PresenceRevision != 0 || view[0].LastHeartbeatUnixMS == 0 {
		t.Fatalf("fresh presence fields: %+v", view[0])
	}
	if view[0].NextCheckUnixMS == 0 {
		t.Fatalf("online terminal must expose next_check: %+v", view[0])
	}

	// 40-60s 观察窗：unknown（事实不可确认），不是 offline。
	v091AgeLastHeartbeat(t, env, terminalID, 50_000)
	for _, got := range v091TerminalsView(t, env, owner.AccessToken) {
		if got.Availability != "unknown" {
			t.Fatalf("50s availability=%q, want unknown", got.Availability)
		}
		if got.NextCheckUnixMS == 0 {
			t.Fatalf("unknown terminal must expose next_check toward offline: %+v", got)
		}
	}

	// 跨过 60s deadline：read path 即时投影 offline（未运行任何 reaper）。
	v091AgeLastHeartbeat(t, env, terminalID, 61_000)
	first := v091TerminalsView(t, env, owner.AccessToken)
	if first[0].Availability != "offline" {
		t.Fatalf("61s availability=%q, want offline（不依赖 sweeper）", first[0].Availability)
	}
	if first[0].NextCheckUnixMS != 0 {
		t.Fatalf("offline terminal must not expose next_check: %+v", first[0])
	}
	// 重复读取稳定：多次投影不翻转、revision 不漂移。
	second := v091TerminalsView(t, env, owner.AccessToken)
	if second[0].Availability != "offline" || second[0].PresenceRevision != first[0].PresenceRevision {
		t.Fatalf("unstable read: first=%+v second=%+v", first[0], second[0])
	}
}

// V091-04：统一命令安全门 —— stale/offline/unknown 目标不得新建 Workspace/DSH 投递。
// 稳定错误码 TERMINAL_OFFLINE / TERMINAL_UNREACHABLE；命令表与投递表零新增；
// 「列表 online 后、提交前再次过期」以 Relay 提交时判断为准。
func TestV091CommandGateRejectsUnavailableTerminalsWithoutDelivery(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v091-gate@test.dev")
	terminal := env.pairTerminal(t, owner, "v091-gate-terminal")
	terminalID := daemonHelloWithCapabilities(t, env, terminal.AccessToken,
		[]string{"workspace_create", "dsh_workspace_sync"})
	deliveriesBefore := v091DeliveryCount(t, env, terminalID)

	expectGateError := func(name, endpoint string, body map[string]any, wantCode string) {
		t.Helper()
		response := env.do(t, http.MethodPost, endpoint, body, owner.AccessToken)
		if response.Code != http.StatusConflict {
			t.Fatalf("%s status=%d body=%s, want 409", name, response.Code, response.Body.String())
		}
		var errBody struct {
			Code string `json:"code"`
		}
		decodeW1(t, response.Body.Bytes(), &errBody)
		if errBody.Code != wantCode {
			t.Fatalf("%s error code=%q, want %q", name, errBody.Code, wantCode)
		}
	}

	t.Run("unknown 目标返回 TERMINAL_UNREACHABLE", func(t *testing.T) {
		v091AgeLastHeartbeat(t, env, terminalID, 50_000)
		expectGateError("workspace create", "/v1/workspaces/create-with-folder",
			map[string]any{"name": "v091-gate-unknown"}, "TERMINAL_UNREACHABLE")
		expectGateError("dsh sync", "/v1/workspaces/sync-dsh",
			map[string]any{"terminal_id": terminalID}, "TERMINAL_UNREACHABLE")
	})

	t.Run("offline 目标返回 TERMINAL_OFFLINE", func(t *testing.T) {
		v091AgeLastHeartbeat(t, env, terminalID, 61_000)
		expectGateError("workspace create", "/v1/workspaces/create-with-folder",
			map[string]any{"name": "v091-gate-offline"}, "TERMINAL_OFFLINE")
		expectGateError("dsh sync", "/v1/workspaces/sync-dsh",
			map[string]any{"terminal_id": terminalID}, "TERMINAL_OFFLINE")
	})

	t.Run("列表 online 后到提交之间过期以提交时判断为准", func(t *testing.T) {
		// 先用一次真实 heartbeat 恢复新鲜事实（前序子用例已把目标拨旧），
		// 再断言列表此刻显示 online。
		heartbeat := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{
			"protocol_version": 1,
		}, terminal.AccessToken)
		if heartbeat.Code != http.StatusOK {
			t.Fatalf("heartbeat status=%d body=%s", heartbeat.Code, heartbeat.Body.String())
		}
		for _, got := range v091TerminalsView(t, env, owner.AccessToken) {
			if got.Availability != "online" {
				t.Fatalf("pre-submit availability=%q, want online", got.Availability)
			}
		}
		// 列表与提交之间目标过期：Relay 在提交时刻 fail-closed。
		v091AgeLastHeartbeat(t, env, terminalID, 61_000)
		expectGateError("workspace create after list", "/v1/workspaces/create-with-folder",
			map[string]any{"name": "v091-gate-race"}, "TERMINAL_OFFLINE")
	})

	// 负向断言：没有创建可投递命令，也没有任何投递落表。
	if got := v091DeliveryCount(t, env, terminalID); got != deliveriesBefore {
		t.Fatalf("deliveries after gate rejections=%d, want %d（不创建投递）", got, deliveriesBefore)
	}
	var commandCount int
	if err := env.db.QueryRow(
		`SELECT COUNT(1) FROM commands WHERE account_id=? AND kind IN ('workspace.create','workspace.sync_dsh')`,
		owner.AccountID).Scan(&commandCount); err != nil {
		t.Fatalf("count commands: %v", err)
	}
	if commandCount != 0 {
		t.Fatalf("gated requests created %d commands, want 0", commandCount)
	}
}
