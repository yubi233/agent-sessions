package store

import (
	"path/filepath"
	"testing"
)

func TestOpenCreatesSQLiteSchema(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	for _, table := range []string{"accounts", "devices", "sessions", "control_leases", "outbox"} {
		var name string
		if err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Fatalf("expected table %q: %v", table, err)
		}
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	if err := Migrate(db); err != nil {
		t.Fatalf("rerun migrations: %v", err)
	}
}
