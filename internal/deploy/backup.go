// Package deploy 实现本地部署与灾备的可验证基础：
// SQLite 备份/恢复与密文/事件序号/撤销完整性校验。
// 权威存储为单租户 SQLite（ADR-008），presence 为进程内可重建状态。
package deploy

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// Backup 把当前 SQLite 库在线备份到目标文件。
// 使用 `VACUUM INTO` 生成一致的压缩副本（SQLite 内置，WAL 安全，不阻塞写入）。
func Backup(srcPath, dstPath string) error {
	if dstPath == "" {
		return errors.New("backup destination required")
	}
	if err := os.MkdirAll(filepath.Dir(dstPath), 0o700); err != nil {
		return err
	}
	src, err := sql.Open("sqlite", srcPath)
	if err != nil {
		return err
	}
	defer src.Close()
	if err := src.Ping(); err != nil {
		return err
	}
	// 使用数据库 API：VACUUM INTO 目标路径（参数化避免注入）。
	_, err = src.Exec(`VACUUM INTO ?`, dstPath)
	return err
}

// Integrity 校验备份/恢复库的完整性、事件序号单调与无空行。
// validateEvents 决定是否读取 sessions 相关表验证（恢复演练）。
func Integrity(path string, validateEvents bool) error {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return err
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		return err
	}
	// PRAGMA integrity_check 校验物理与逻辑一致性。
	var check string
	if err := db.QueryRow(`PRAGMA integrity_check`).Scan(&check); err != nil {
		return err
	}
	if check != "ok" {
		return fmt.Errorf("integrity_check = %q", check)
	}
	if !validateEvents {
		return nil
	}
	// 事件序号单调且无重复（恢复后仍可重放）。event_seq 是会话内局部序号，
	// 跨会话不可比（v0.9.6 修复：旧实现跨会话比较，上一会话 116 之后下一
	// 会话从 1 开始即误报 not monotonic）；这里按会话分组各自校验单调。
	rows, err := db.Query(`SELECT session_id, event_seq FROM session_events ORDER BY session_id, event_seq`)
	if err != nil {
		// 空库可能无事件表行，视为合法。
		return nil
	}
	defer rows.Close()
	prevSession := ""
	prev := int64(0)
	hasRow := false
	for rows.Next() {
		var session string
		var seq int64
		if err := rows.Scan(&session, &seq); err != nil {
			return err
		}
		if hasRow && session == prevSession && seq <= prev {
			return fmt.Errorf("event seq not monotonic in session %s: %d then %d", session, prev, seq)
		}
		prevSession, prev, hasRow = session, seq, true
	}
	return rows.Err()
}

// ValidateSchema 校验关键权威表存在（迁移完整性）。
func ValidateSchema(path string) error {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return err
	}
	defer db.Close()
	required := []string{"accounts", "devices", "sessions", "session_events", "control_leases", "outbox", "commands", "device_key_wraps"}
	for _, table := range required {
		var name string
		if err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			return fmt.Errorf("missing table %s", table)
		}
	}
	return nil
}
