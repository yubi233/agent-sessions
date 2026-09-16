package store

// v0.9.2 P1 回归：terminals 的列清单与所有 Scan 目标必须一一对应。
//
// 背景：新增 additive 列（provider_facts_json）时漏改 ListTerminals 的 Scan，
// 会让原本正常的接口在运行期报 "expected 14 destination arguments in Scan, not 13"，
// 并把用户可见操作变成 500。该缺陷在集成测试里才暴露，因此这里加一条
// 低层回归：读取 3 条路径都能成功扫描，且列数被显式断言。

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

// TestV092TerminalColumnsMatchScan 用真实读写验证列清单与 Scan 目标一致。
func TestV092TerminalColumnsMatchScan(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	repo := NewRepository(db)
	ctx := context.Background()

	// 列清单条数必须与 TerminalRow 的读取契约一致（14 列）。
	declared := strings.Split(strings.ReplaceAll(terminalColumns, "\n", ""), ",")
	want := 14
	if len(declared) != want {
		t.Fatalf("terminalColumns 列数 = %d, want %d: %v", len(declared), want, declared)
	}

	const (
		initialFacts = `[{"kind":"dsh","available":true}]`
		updatedFacts = `[{"kind":"dsh","available":false}]`
	)
	// terminals 对 devices 有外键约束：先落一条账号与设备，再登记 Terminal。
	if _, err := db.Exec(
		`INSERT INTO accounts(id,email,password_hash,created_at) VALUES('acc_v092_columns','v092@fixture.local',x'00',1)`); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	if _, err := db.Exec(
		`INSERT INTO devices(id,account_id,role,status,display_name,identity_public_key,encryption_public_key)
		 VALUES('dev_v092_columns','acc_v092_columns','terminal','active','fixture','','')`); err != nil {
		t.Fatalf("seed device: %v", err)
	}

	row := TerminalRow{
		ID: "term_v092_columns", DeviceID: "dev_v092_columns", AccountID: "acc_v092_columns",
		Hostname: "host", Platform: "darwin", Status: "online", LastSeenUnixMS: 1000,
		ProtocolVersion: 1, DaemonVersion: "fixture", CapabilitiesJSON: `["start"]`,
		LastHeartbeatUnixMS: 1000, PresenceRevision: 1, PresenceProjectedState: "online",
		ProviderFactsJSON: initialFacts,
	}
	if err := repo.CreateTerminal(ctx, row); err != nil {
		t.Fatalf("CreateTerminal: %v", err)
	}
	// 三条读取路径都必须能扫描（任一遗漏都会在运行期 500）。
	byID, err := repo.TerminalByID(ctx, row.ID)
	if err != nil {
		t.Fatalf("TerminalByID: %v", err)
	}
	if byID.ProviderFactsJSON != row.ProviderFactsJSON {
		t.Fatalf("TerminalByID 未读到 ProviderFactsJSON: %q", byID.ProviderFactsJSON)
	}
	byDevice, err := repo.TerminalByDeviceID(ctx, row.DeviceID)
	if err != nil {
		t.Fatalf("TerminalByDeviceID: %v", err)
	}
	if byDevice.ProviderFactsJSON != row.ProviderFactsJSON {
		t.Fatalf("TerminalByDeviceID 未读到 ProviderFactsJSON: %q", byDevice.ProviderFactsJSON)
	}
	listed, err := repo.ListTerminals(ctx, row.AccountID)
	if err != nil {
		t.Fatalf("ListTerminals: %v", err)
	}
	if len(listed) != 1 || listed[0].ProviderFactsJSON != row.ProviderFactsJSON {
		t.Fatalf("ListTerminals 未读到 ProviderFactsJSON: %#v", listed)
	}

	// 心跳上报时整体替换事实快照；未携带（nil）时保持既有快照。
	facts := updatedFacts
	if _, _, err := repo.TouchTerminalPresence(ctx, row.ID, 2000, "online", "online", &facts); err != nil {
		t.Fatalf("TouchTerminalPresence(替换): %v", err)
	}
	updated, err := repo.TerminalByID(ctx, row.ID)
	if err != nil {
		t.Fatalf("TerminalByID after update: %v", err)
	}
	if updated.ProviderFactsJSON != facts {
		t.Fatalf("心跳必须替换事实快照: %q", updated.ProviderFactsJSON)
	}
	if _, _, err := repo.TouchTerminalPresence(ctx, row.ID, 3000, "online", "online", nil); err != nil {
		t.Fatalf("TouchTerminalPresence(nil): %v", err)
	}
	kept, err := repo.TerminalByID(ctx, row.ID)
	if err != nil {
		t.Fatalf("TerminalByID after nil update: %v", err)
	}
	if kept.ProviderFactsJSON != facts {
		t.Fatalf("未携带事实时不得清空既有快照: %q", kept.ProviderFactsJSON)
	}
}
