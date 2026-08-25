package relay

import (
	"net/http"
	"strings"
	"testing"
)

// TestV06SignatureModeRollbackDrill 是 P4 的本地回滚演练（计划 §6-P4.2）：
// optional（bearer+签名双轨）→ required（窗口结束）→ 回退 optional。
// 断言分两层：
//  1. 认证语义随模式切换：required 拒绝旧 bearer（426 UPGRADE_REQUIRED）、signed 可用；
//     回退 optional 后旧 bearer 立即恢复、auth_modes 回到双轨。
//  2. 模式切换绝不触碰业务数据：identity keys、会话、命令、事件、outbox 历史
//     行数与命令终态在三次切换前后完全一致；已消费的挑战/nonce 一次性状态保持不可重放。
//
// 口径：local_test=true、fixture_data=true、real_browser=false、real_model=false、headless=false。
func TestV06SignatureModeRollbackDrill(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v06-rollback@test.dev")
	terminal, token := env.newV06SignedTerminal(t, owner, "v06-rollback-terminal")

	countIdentityKeys := func(t *testing.T) int {
		t.Helper()
		response := env.do(t, http.MethodGet, "/v1/devices/"+terminal.deviceID+"/identity-keys", nil, owner.AccessToken)
		if response.Code != http.StatusOK {
			t.Fatalf("list identity keys status=%d", response.Code)
		}
		var view struct {
			Keys []struct {
				KeyID  string `json:"key_id"`
				Status string `json:"status"`
			} `json:"keys"`
		}
		decodeW1(t, response.Body.Bytes(), &view)
		return len(view.Keys)
	}

	helloPayload := map[string]any{
		"protocol_version": 1, "daemon_version": "fixture-drill", "hostname": "drill", "platform": "test",
		"capabilities": []string{"start"},
	}

	// 阶段 A：optional 模式，signed hello 正常，auth_modes 双轨。
	challengeA := env.v06Challenge(t, token)
	helloA := env.postSigned(t, terminal, token, "/v1/daemon/hello", helloPayload, challengeA)
	if helloA.Code != http.StatusOK || !strings.Contains(helloA.Body.String(), `"bearer"`) {
		t.Fatalf("phase A signed hello unexpected: %d %s", helloA.Code, helloA.Body.String())
	}
	var helloView struct {
		TerminalID string `json:"terminal_id"`
	}
	decodeW1(t, helloA.Body.Bytes(), &helloView)

	// 在切换模式前沉淀真实业务数据：绑定会话 + 命令 + 密文事件，
	// 让回滚演练断言的是"业务历史不丢"，而不是空库行数不变。
	sessionID, _ := env.createBoundSession(t, owner, helloView.TerminalID, "v06-rollback-project")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v06-rollback-1", "lease_epoch": epoch,
		"target_terminal_id": helloView.TerminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("seed rollback command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	eventPayload := map[string]any{
		"protocol_version": 1, "event_id": "evt-v06-rollback-1", "command_id": submitted.ID,
		"session_id": sessionID, "event_type": "turn.started",
		"envelope": opaqueFixtureEnvelope("v06-rollback-opaque"),
	}
	if event := env.postSigned(t, terminal, token, "/v1/daemon/events", eventPayload, "v06-rollback-event-1"); event.Code != http.StatusOK {
		t.Fatalf("seed rollback event status=%d body=%s", event.Code, event.Body.String())
	}

	// 快照关键业务表。历史类表必须逐行不变；一次性状态表（挑战/nonce）允许因
	// 演练自身后续签名动作新增行，但绝不允许减少（减少=历史被清理/丢失）。
	tablesToPreserve := []string{
		"accounts", "devices", "sessions", "commands", "session_events",
		"outbox", "terminal_identity_keys",
	}
	appendOnlyTables := []string{"terminal_auth_challenges"}
	countTable := func(table string) int {
		t.Helper()
		var n int
		if err := env.db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		return n
	}
	rowsBefore := map[string]int{}
	for _, table := range append(append([]string{}, tablesToPreserve...), appendOnlyTables...) {
		rowsBefore[table] = countTable(table)
	}
	var commandStatusBefore string
	if err := env.db.QueryRow(`SELECT status FROM commands WHERE id = ?`, submitted.ID).Scan(&commandStatusBefore); err != nil {
		t.Fatalf("read seeded command status: %v", err)
	}
	keysBefore := countIdentityKeys(t)

	// 阶段 B：切换 required（模拟 Relay 以 required 重启）。同一 bearer 旧客户端立即被拒；
	// 已登记的公钥与全部业务数据仍在。
	switchToRequired(t, env)
	legacyHello := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "fixture-drill", "hostname": "drill", "platform": "test",
		"capabilities": []string{"start"},
	}, token)
	if legacyHello.Code != http.StatusUpgradeRequired {
		t.Fatalf("phase B legacy hello status=%d want 426", legacyHello.Code)
	}
	if got := countIdentityKeys(t); got != keysBefore {
		t.Fatalf("required mode must not touch identity keys: %d want %d", got, keysBefore)
	}

	// required 模式下 signed hello 仍可用；该挑战消费后不可复用。
	challengeB := env.v06Challenge(t, token)
	helloB := env.postSigned(t, terminal, token, "/v1/daemon/hello", helloPayload, challengeB)
	if helloB.Code != http.StatusOK || strings.Contains(helloB.Body.String(), `"bearer"`) {
		t.Fatalf("phase B signed hello must advertise signature-only: %d %s", helloB.Code, helloB.Body.String())
	}

	// 阶段 C：回滚到 optional（模拟关闭签名 flag 重启）。旧 bearer 立即恢复；
	// 全部业务表行数不变，命令终态不被改写。
	switchBackToOptional(t, env)
	legacyRecovered := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "legacy-after-rollback", "hostname": "drill", "platform": "test",
		"capabilities": []string{"start"},
	}, token)
	if legacyRecovered.Code != http.StatusOK {
		t.Fatalf("phase C legacy hello status=%d want 200 body=%s", legacyRecovered.Code, legacyRecovered.Body.String())
	}
	if !strings.Contains(legacyRecovered.Body.String(), `"auth_modes":["bearer","signature_v1"]`) {
		t.Fatalf("phase C auth_modes must return to dual-track: %s", legacyRecovered.Body.String())
	}
	if got := countIdentityKeys(t); got != keysBefore {
		t.Fatalf("rollback must not delete identity keys: %d want %d", got, keysBefore)
	}
	for _, table := range tablesToPreserve {
		if got, want := countTable(table), rowsBefore[table]; got != want {
			t.Fatalf("rollback must not mutate %s: %d rows want %d", table, got, want)
		}
	}
	for _, table := range appendOnlyTables {
		if got := countTable(table); got < rowsBefore[table] {
			t.Fatalf("rollback must never shrink %s: %d rows, snapshot had %d", table, got, rowsBefore[table])
		}
	}
	var commandStatusAfter string
	if err := env.db.QueryRow(`SELECT status FROM commands WHERE id = ?`, submitted.ID).Scan(&commandStatusAfter); err != nil {
		t.Fatalf("re-read seeded command status: %v", err)
	}
	if commandStatusAfter != commandStatusBefore {
		t.Fatalf("rollback must not rewrite command status: %s want %s", commandStatusAfter, commandStatusBefore)
	}

	// 已消费的挑战在回滚后仍不可重放：一次性状态属于数据，不属于模式。
	replayAfterRollback := env.postSigned(t, terminal, token, "/v1/daemon/hello", helloPayload, challengeB)
	if !strings.Contains(replayAfterRollback.Body.String(), "NONCE_REUSED") {
		t.Fatalf("consumed challenge must stay consumed after rollback: %d %s", replayAfterRollback.Code, replayAfterRollback.Body.String())
	}
}

// switchToRequired / switchBackToOptional 在同一 SQLite 上重建路由，
// 模拟 Relay 进程以不同 AGENT_SESSIONS_TERMINAL_SIGNATURE_MODE 重启。
func switchToRequired(t *testing.T, env *testEnv) {
	t.Helper()
	env.router = NewServerWithTerminalSignatureRequired(env.db, nil)
}

func switchBackToOptional(t *testing.T, env *testEnv) {
	t.Helper()
	env.router = NewServer(env.db, nil)
}
