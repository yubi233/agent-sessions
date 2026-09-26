package daemon

import (
	"path/filepath"
	"testing"
)

// v0.9.7 阶段 3.1 回归：outbox 终态行清理的删除边界。
// delivered 全删；quarantined 保留当前世代 + 全局最近 N 条；pending/failed
// 与当前世代已收口命令永不触碰。
func TestCompactRelayOutbox(t *testing.T) {
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	if err := state.Set("relay_generation", "relgen_current"); err != nil {
		t.Fatal(err)
	}
	insert := func(t *testing.T, table, id, generation, status string) {
		t.Helper()
		var query string
		switch table {
		case "relay_event_outbox":
			// command_id 非空约束：测试行统一挂占位命令 ID。
			query = `INSERT INTO relay_event_outbox(event_id,command_id,session_id,event_type,envelope_json,status,relay_generation,created_at,created_at_unix_ms) VALUES(?,'cmd_fixture','sess','user.message','{}',?,?,1,1)`
		case "relay_usage_outbox":
			query = `INSERT INTO relay_usage_outbox(usage_key,session_id,provider,utc_day,input_tokens,output_tokens,status,relay_generation,created_at) VALUES(?,'sess','mock','2026-09-27',0,0,?,?,1)`
		default:
			t.Fatalf("bad table %s", table)
		}
		if _, err := state.db.Exec(query, id, status, generation); err != nil {
			t.Fatalf("insert %s: %v", table, err)
		}
	}
	// 事件：旧世代 delivered/quarantined×3 + 当前世代 quarantined + pending/failed。
	insert(t, "relay_event_outbox", "evt_del_old", "relgen_old", "delivered")
	insert(t, "relay_event_outbox", "evt_qua_old_1", "relgen_old", "quarantined")
	insert(t, "relay_event_outbox", "evt_qua_old_2", "relgen_old", "quarantined")
	insert(t, "relay_event_outbox", "evt_qua_old_3", "relgen_old", "quarantined")
	insert(t, "relay_event_outbox", "evt_qua_cur", "relgen_current", "quarantined")
	insert(t, "relay_event_outbox", "evt_pend", "relgen_old", "pending")
	insert(t, "relay_event_outbox", "evt_fail", "relgen_old", "failed")
	// 用量：delivered 与 pending。
	insert(t, "relay_usage_outbox", "usg_del", "relgen_old", "delivered")
	insert(t, "relay_usage_outbox", "usg_pend", "relgen_current", "pending")
	// 命令：旧世代已收口可删；旧世代未收口与当前世代已收口都保留。
	cmd := func(id, generation, result string) {
		t.Helper()
		if _, err := state.db.Exec(
			`INSERT INTO relay_commands(command_id,delivery_seq,session_id,kind,lease_epoch,payload_json,status,result_status,created_at,updated_at)
			 VALUES(?,1,'sess','session.start',1,'{}','completed',?,1,2)`, id, result); err != nil {
			t.Fatal(err)
		}
		if generation != "" {
			if _, err := state.db.Exec(`UPDATE relay_commands SET relay_generation=? WHERE command_id=?`, generation, id); err != nil {
				t.Fatal(err)
			}
		}
	}
	cmd("cmd_old_done", "relgen_old", "succeeded")
	cmd("cmd_old_live", "relgen_old", "")
	cmd("cmd_cur_done", "relgen_current", "succeeded")

	summary, err := state.CompactRelayOutbox(2)
	if err != nil {
		t.Fatalf("compact: %v", err)
	}
	// 断言删除量。
	if summary.DeliveredEvents != 1 {
		t.Fatalf("delivered 事件应删 1: %d", summary.DeliveredEvents)
	}
	// 旧世代 quarantined 3 条：保留全局最近 2 条样本，只删最老 1 条。
	if summary.QuarantinedEvents != 1 {
		t.Fatalf("quarantined 应删最老 1 条: %d", summary.QuarantinedEvents)
	}
	if summary.DeliveredUsages != 1 {
		t.Fatalf("delivered 用量应删 1: %d", summary.DeliveredUsages)
	}
	if summary.StaleGenerationCmds != 1 {
		t.Fatalf("旧世代已收口命令应删 1: %d", summary.StaleGenerationCmds)
	}
	// 断言逐行存留边界。
	count := func(table, column, id string) int {
		t.Helper()
		var n int
		if err := state.db.QueryRow(`SELECT COUNT(*) FROM `+table+` WHERE `+column+`=?`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for id, want := range map[string]bool{
		"evt_del_old": false, "evt_qua_old_1": true, "evt_qua_old_2": true, "evt_qua_old_3": false,
		"evt_qua_cur": true, "evt_pend": true, "evt_fail": true,
	} {
		if got := count("relay_event_outbox", "event_id", id) == 1; got != want {
			t.Fatalf("事件 %s 存在=%v 期望 %v", id, got, want)
		}
	}
	if count("relay_usage_outbox", "usage_key", "usg_del") != 0 {
		t.Fatal("delivered 用量应已删除")
	}
	if count("relay_usage_outbox", "usage_key", "usg_pend") != 1 {
		t.Fatal("pending 用量必须保留")
	}
	for id, want := range map[string]bool{"cmd_old_done": false, "cmd_old_live": true, "cmd_cur_done": true} {
		if got := count("relay_commands", "command_id", id) == 1; got != want {
			t.Fatalf("命令 %s 存在=%v 期望 %v", id, got, want)
		}
	}
	if err := state.Vacuum(); err != nil {
		t.Fatalf("vacuum: %v", err)
	}
}
