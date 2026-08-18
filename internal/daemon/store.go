// Package daemon 实现 PC Daemon 核心：CLI、本地状态、进程监督与离线 outbox。
// 平台差异（service 安装、keyring）通过接口隔离，测试使用 fake 实现。
package daemon

import (
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"

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
-- Relay 下行命令与本机处理状态分开存放，不能与 Daemon 发起的本地 outbox 混用。
CREATE TABLE IF NOT EXISTS relay_commands (
	command_id TEXT PRIMARY KEY,
	delivery_seq INTEGER NOT NULL,
	session_id TEXT NOT NULL,
	workspace_id TEXT NOT NULL DEFAULT '',
	kind TEXT NOT NULL,
	lease_epoch INTEGER NOT NULL,
	target_instance_id TEXT NOT NULL DEFAULT '',
	target_terminal_id TEXT NOT NULL DEFAULT '',
	payload_json TEXT NOT NULL,
	status TEXT NOT NULL DEFAULT 'received',
	result_status TEXT NOT NULL DEFAULT '',
	error_code TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_commands_pending_idx
	ON relay_commands(status, delivery_seq);
-- Provider canonical event 在本机 outbox 内等待可靠上传；payload 只能是已加密 envelope。
CREATE TABLE IF NOT EXISTS relay_event_outbox (
	event_id TEXT PRIMARY KEY,
	command_id TEXT NOT NULL,
	session_id TEXT NOT NULL,
	event_type TEXT NOT NULL,
	envelope_json TEXT NOT NULL,
	status TEXT NOT NULL DEFAULT 'pending',
	created_at INTEGER NOT NULL
);
`

// Store 是 Daemon 本地状态仓储（SQLite）。
type Store struct {
	db *sql.DB
	mu sync.Mutex
}

const confirmedWorkspaceStatePrefix = "confirmed_workspace:"

// ErrWorkspaceNotConfirmed 表示 Relay 所引用的 Workspace 尚未由本机用户确认。Daemon 不会因为
// Relay 已接受命令就自动授予本机目录读取权限。
var ErrWorkspaceNotConfirmed = errors.New("workspace is not locally confirmed")

// ErrRelayCommandConflict 表示同一个 command_id 被重新投递时携带了不同的不可变字段。
// 这类 delivery 不能推进 cursor，否则攻击者可用冲突命令跳过其间的合法投递。
var ErrRelayCommandConflict = errors.New("relay command conflicts with durable record")

// ConfirmedWorkspace 是本机确认后的 opaque Workspace ID 与 canonical Git 根映射。绝对路径只
// 保留在 Daemon 本机状态中，绝不上传到 Relay、事件、日志或测试报告。
type ConfirmedWorkspace struct {
	ID   string `json:"id"`
	Root string `json:"root"`
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
	// P2 新增 workspace_id 时，已有 Daemon 本地库仍可能包含旧版 relay_commands。
	// 这里采用 additive ALTER，保留已落盘的命令、游标和 outbox，避免升级后重放失去状态。
	return s.ensureRelayCommandWorkspaceIDColumn()
}

func (s *Store) ensureRelayCommandWorkspaceIDColumn() error {
	rows, err := s.db.Query(`PRAGMA table_info(relay_commands)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			cid        int
			name       string
			columnType string
			notNull    int
			defaultVal sql.NullString
			primaryKey int
		)
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultVal, &primaryKey); err != nil {
			return err
		}
		if name == "workspace_id" {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = s.db.Exec(`ALTER TABLE relay_commands ADD COLUMN workspace_id TEXT NOT NULL DEFAULT ''`)
	return err
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

// Delete 删除已失效的本机状态。仅接受稳定内部键；不存在视为成功，确保 kill/关闭清理可重试。
func (s *Store) Delete(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec("DELETE FROM local_state WHERE key=?", key)
	return err
}

// ConfirmWorkspace 把用户明确确认的 Git 根绑定到 Relay Workspace ID。确认时和每次读取时都做
// realpath/Git 根校验，避免目录移动、符号链接替换或 Relay payload 伪造扩大本机读取范围。
func (s *Store) ConfirmWorkspace(workspaceID, root string) (ConfirmedWorkspace, error) {
	workspaceID = strings.TrimSpace(workspaceID)
	root = strings.TrimSpace(root)
	if workspaceID == "" || len(workspaceID) > 128 || strings.ContainsAny(workspaceID, "\x00\r\n") {
		return ConfirmedWorkspace{}, errors.New("invalid workspace id")
	}
	if !filepath.IsAbs(root) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAbsolute
	}
	if !workspacesafe.IsGitRoot(root) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	canonicalRoot, err := workspacesafe.ResolveRepoRelative(root, ".")
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if !workspacesafe.IsGitRoot(canonicalRoot) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	confirmed := ConfirmedWorkspace{ID: workspaceID, Root: canonicalRoot}
	raw, err := json.Marshal(confirmed)
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if err := s.Set(confirmedWorkspaceStatePrefix+workspaceID, string(raw)); err != nil {
		return ConfirmedWorkspace{}, err
	}
	return confirmed, nil
}

// ConfirmedWorkspaceByID 只返回仍然是同一 Git 根的本机映射。工作区被移动、删除或替换时返回
// workspacesafe 的稳定错误，调用方必须 fail-closed 而不是尝试按旧路径继续读取。
func (s *Store) ConfirmedWorkspaceByID(workspaceID string) (ConfirmedWorkspace, error) {
	workspaceID = strings.TrimSpace(workspaceID)
	if workspaceID == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceNotConfirmed
	}
	raw, err := s.Get(confirmedWorkspaceStatePrefix + workspaceID)
	if err != nil {
		return ConfirmedWorkspace{}, ErrWorkspaceNotConfirmed
	}
	var confirmed ConfirmedWorkspace
	if err := json.Unmarshal([]byte(raw), &confirmed); err != nil || confirmed.ID != workspaceID || confirmed.Root == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceNotConfirmed
	}
	canonicalRoot, err := workspacesafe.ResolveRepoRelative(confirmed.Root, ".")
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if !workspacesafe.IsGitRoot(canonicalRoot) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	confirmed.Root = canonicalRoot
	return confirmed, nil
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

// RelayCommand 是专用 SSE 下行命令在 Daemon 本机的持久化投影。命令 ID 是执行去重键，
// delivery_seq 仅作为重连游标，二者不能互相替代。
type RelayCommand struct {
	CommandID        string
	DeliverySeq      int64
	SessionID        string
	WorkspaceID      string
	Kind             string
	LeaseEpoch       int64
	TargetInstanceID string
	TargetTerminalID string
	PayloadJSON      string
	Status           string
	ResultStatus     string
	ErrorCode        string
}

// RelayEvent 是等待上传的 canonical event。envelope_json 已在调用方加密，Store 不解析它。
type RelayEvent struct {
	EventID      string
	CommandID    string
	SessionID    string
	EventType    string
	EnvelopeJSON string
}

// RelayUsage 是等待上传的白名单 usage 计数（ADR-010）。UsageKey 由 Daemon 对
// 来源事件生成，保证断线 outbox 重放幂等；绝不包含 prompt、回复、费用或精确时间。
type RelayUsage struct {
	UsageKey         string
	Provider         string
	UTCDay           string
	InputTokens      int64
	OutputTokens     int64
	CacheReadTokens  int64
	CacheWriteTokens int64
}

// RecordRelayCommand 原子记录一个 SSE delivery。相同 command_id 即使因至少一次投递再次到达，
// 也不能再次触发 Provider 进程；成功写入后才推进本机 delivery cursor。
func (s *Store) RecordRelayCommand(command RelayCommand) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if command.CommandID == "" || command.DeliverySeq <= 0 || command.Kind == "" || command.SessionID == "" {
		return false, errors.New("invalid relay command")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback() }()

	now := time.Now().UnixMilli()
	result, err := tx.Exec(
		`INSERT OR IGNORE INTO relay_commands(
			command_id,delivery_seq,session_id,workspace_id,kind,lease_epoch,target_instance_id,target_terminal_id,
			payload_json,status,result_status,error_code,created_at,updated_at
		) VALUES(?,?,?,?,?,?,?,?,?,?,'','',?,?)`,
		command.CommandID, command.DeliverySeq, command.SessionID, command.WorkspaceID, command.Kind, command.LeaseEpoch,
		command.TargetInstanceID, command.TargetTerminalID, command.PayloadJSON, "received", now, now)
	if err != nil {
		return false, err
	}
	insertedRows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if insertedRows == 0 {
		var durable RelayCommand
		err = tx.QueryRow(
			`SELECT command_id,delivery_seq,session_id,workspace_id,kind,lease_epoch,target_instance_id,target_terminal_id,
				payload_json,status,result_status,error_code
			 FROM relay_commands WHERE command_id=?`, command.CommandID).Scan(
			&durable.CommandID, &durable.DeliverySeq, &durable.SessionID, &durable.WorkspaceID, &durable.Kind,
			&durable.LeaseEpoch, &durable.TargetInstanceID, &durable.TargetTerminalID, &durable.PayloadJSON,
			&durable.Status, &durable.ResultStatus, &durable.ErrorCode,
		)
		if err != nil {
			return false, err
		}
		if !sameRelayCommandDelivery(durable, command) {
			return false, ErrRelayCommandConflict
		}
	}

	var current int64
	var cursorValue string
	err = tx.QueryRow("SELECT value FROM local_state WHERE key='relay_delivery_seq'").Scan(&cursorValue)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	if err == nil {
		current, err = strconv.ParseInt(cursorValue, 10, 64)
		if err != nil || current < 0 {
			return false, errors.New("invalid relay delivery cursor")
		}
	}
	if command.DeliverySeq > current {
		_, err = tx.Exec(
			`INSERT INTO local_state(key,value) VALUES('relay_delivery_seq',?)
			 ON CONFLICT(key) DO UPDATE SET value=excluded.value`, strconv.FormatInt(command.DeliverySeq, 10))
		if err != nil {
			return false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return insertedRows == 1, nil
}

func sameRelayCommandDelivery(left, right RelayCommand) bool {
	return left.CommandID == right.CommandID &&
		left.DeliverySeq == right.DeliverySeq &&
		left.SessionID == right.SessionID &&
		left.WorkspaceID == right.WorkspaceID &&
		left.Kind == right.Kind &&
		left.LeaseEpoch == right.LeaseEpoch &&
		left.TargetInstanceID == right.TargetInstanceID &&
		left.TargetTerminalID == right.TargetTerminalID &&
		left.PayloadJSON == right.PayloadJSON
}

// RelayDeliveryCursor 返回已安全落盘的最大 delivery_seq。Daemon 仅在持久化后推进，
// 因而进程崩溃时 Relay 可以重投最近一条而不会丢命令。
func (s *Store) RelayDeliveryCursor() (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var value string
	err := s.db.QueryRow("SELECT value FROM local_state WHERE key='relay_delivery_seq'").Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(value, 10, 64)
}

func (s *Store) PendingRelayCommands() ([]RelayCommand, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		`SELECT command_id,delivery_seq,session_id,workspace_id,kind,lease_epoch,target_instance_id,target_terminal_id,
			payload_json,status,result_status,error_code
			 FROM relay_commands WHERE status IN ('received','rejecting','starting','started') ORDER BY delivery_seq`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var commands []RelayCommand
	for rows.Next() {
		var command RelayCommand
		if err := rows.Scan(
			&command.CommandID, &command.DeliverySeq, &command.SessionID, &command.WorkspaceID, &command.Kind, &command.LeaseEpoch,
			&command.TargetInstanceID, &command.TargetTerminalID, &command.PayloadJSON, &command.Status,
			&command.ResultStatus, &command.ErrorCode,
		); err != nil {
			return nil, err
		}
		commands = append(commands, command)
	}
	return commands, rows.Err()
}

// RelayCommandByID 读取本机命令恢复诊断所需的最小状态。它只返回已持久化的协议元数据和密文
// payload，不解密或记录 Provider 正文；RelayLoop 用它的同一行状态判断重放是否已收敛。
func (s *Store) RelayCommandByID(commandID string) (RelayCommand, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var command RelayCommand
	err := s.db.QueryRow(
		`SELECT command_id,delivery_seq,session_id,workspace_id,kind,lease_epoch,target_instance_id,target_terminal_id,
			payload_json,status,result_status,error_code
		 FROM relay_commands WHERE command_id=?`, commandID).Scan(
		&command.CommandID, &command.DeliverySeq, &command.SessionID, &command.WorkspaceID, &command.Kind, &command.LeaseEpoch,
		&command.TargetInstanceID, &command.TargetTerminalID, &command.PayloadJSON, &command.Status,
		&command.ResultStatus, &command.ErrorCode,
	)
	return command, err
}

func (s *Store) MarkRelayCommandStarted(commandID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE relay_commands SET status='started', updated_at=? WHERE command_id=?`, time.Now().UnixMilli(), commandID)
	return err
}

// MarkRelayCommandStarting 在发送 started 回执前先将本机状态落盘。网络在 Relay 接收回执后
// 中断时，重启只会幂等重放 started 回执，不会把同一 command_id 再交给 Provider。
func (s *Store) MarkRelayCommandStarting(commandID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE relay_commands SET status='starting', updated_at=? WHERE command_id=?`, time.Now().UnixMilli(), commandID)
	return err
}

// MarkRelayCommandRejecting 在发送 rejected 回执前持久化本机判定。若 Relay 已提交回执但响应
// 丢失，重启只能重放 rejected，不能把仍标为 received 的不可信命令送入 Provider。
func (s *Store) MarkRelayCommandRejecting(commandID, errorCode string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(
		`UPDATE relay_commands SET status='rejecting', error_code=?, updated_at=? WHERE command_id=?`,
		errorCode, time.Now().UnixMilli(), commandID)
	return err
}

func (s *Store) MarkRelayCommandResult(commandID, status, errorCode string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(
		`UPDATE relay_commands SET status='completed', result_status=?, error_code=?, updated_at=? WHERE command_id=?`,
		status, errorCode, time.Now().UnixMilli(), commandID)
	return err
}

func (s *Store) EnqueueRelayEvent(event RelayEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if event.EventID == "" || event.CommandID == "" || event.SessionID == "" || event.EventType == "" || event.EnvelopeJSON == "" {
		return errors.New("invalid relay event")
	}
	_, err := s.db.Exec(
		`INSERT OR IGNORE INTO relay_event_outbox(event_id,command_id,session_id,event_type,envelope_json,status,created_at)
		 VALUES(?,?,?,?,?,'pending',?)`,
		event.EventID, event.CommandID, event.SessionID, event.EventType, event.EnvelopeJSON, time.Now().UnixMilli())
	return err
}

func (s *Store) PendingRelayEvents() ([]RelayEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		`SELECT event_id,command_id,session_id,event_type,envelope_json
		 FROM relay_event_outbox WHERE status='pending' ORDER BY created_at,event_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []RelayEvent
	for rows.Next() {
		var event RelayEvent
		if err := rows.Scan(&event.EventID, &event.CommandID, &event.SessionID, &event.EventType, &event.EnvelopeJSON); err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

func (s *Store) MarkRelayEventDelivered(eventID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE relay_event_outbox SET status='delivered' WHERE event_id=?`, eventID)
	return err
}

// DefaultStatePath 返回默认本地状态库路径。
func DefaultStatePath(root string) string {
	return filepath.Join(root, "daemon.db")
}
