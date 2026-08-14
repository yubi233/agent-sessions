// Package daemon 实现 PC Daemon 核心：CLI、本地状态、进程监督与离线 outbox。
// 平台差异（service 安装、keyring）通过接口隔离，测试使用 fake 实现。
package daemon

import (
	"database/sql"
	"errors"
	"path/filepath"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// 本地 SQLite 状态表。仅存最小元数据、游标与命令 outbox；正文/密钥不落明文。
const localSchema = `
CREATE TABLE IF NOT EXISTS local_state (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS command_outbox (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	request_id TEXT NOT NULL,
	kind TEXT NOT NULL,
	payload_json TEXT NOT NULL,
	status TEXT NOT NULL DEFAULT 'pending',
	attempts INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL
);
`

// Store 是 Daemon 本地状态仓储（SQLite）。
type Store struct {
	db *sql.DB
	mu sync.Mutex
}

// OpenStore 打开或创建本地状态库。
func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(`PRAGMA journal_mode=WAL;`); err != nil {
		_ = db.Close()
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	if _, err := s.db.Exec(localSchema); err != nil {
		return err
	}
	return nil
}

// Close 关闭本地状态库。
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.db.Close()
}

// Get 读取本地状态。
func (s *Store) Get(key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var v string
	err := s.db.QueryRow("SELECT value FROM local_state WHERE key=?", key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errors.New("not found")
	}
	return v, err
}

// Set 写入本地状态。
func (s *Store) Set(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(
		"INSERT INTO local_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
		key, value)
	return err
}

// EnqueueCommand 把离线命令写入 outbox；幂等键用 request_id 去重。
func (s *Store) EnqueueCommand(requestID, kind, payload string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	_ = s.db.QueryRow("SELECT COUNT(1) FROM command_outbox WHERE request_id=?", requestID).Scan(&n)
	if n > 0 {
		// 幂等：相同 request_id 不重复入队（SYNC-03）。
		return nil
	}
	_, err := s.db.Exec(
		"INSERT INTO command_outbox(request_id,kind,payload_json,status,created_at) VALUES(?,?,?,?,?)",
		requestID, kind, payload, "pending", time.Now().UnixMilli())
	return err
}

// PendingCommands 返回待投递命令。
func (s *Store) PendingCommands() ([]Command, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		"SELECT id,request_id,kind,payload_json,status,attempts FROM command_outbox WHERE status='pending' ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Command{}
	for rows.Next() {
		var c Command
		if err := rows.Scan(&c.ID, &c.RequestID, &c.Kind, &c.PayloadJSON, &c.Status, &c.Attempts); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

// MarkDelivered 标记命令已投递。
func (s *Store) MarkDelivered(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec("UPDATE command_outbox SET status='delivered', attempts=attempts+1 WHERE id=?", id)
	return err
}

// Command 是本地 outbox 中的一条命令。
type Command struct {
	ID          int64
	RequestID   string
	Kind        string
	PayloadJSON string
	Status      string
	Attempts    int
}

// DefaultStatePath 返回默认本地状态库路径。
func DefaultStatePath(root string) string {
	return filepath.Join(root, "daemon.db")
}
