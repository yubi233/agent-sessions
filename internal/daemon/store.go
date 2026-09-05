// Package daemon 实现 PC Daemon 核心：CLI、本地状态、进程监督与离线 outbox。
// 平台差异（service 安装、keyring）通过接口隔离，测试使用 fake 实现。
package daemon

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
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
-- relay_generation 是 v0.8.9 P1 的世代关联列（§3.2）：新行由 Store 打上当前世代，
-- 世代切换时旧行据此被事务性隔离，保证旧命令不进入新 Relay 执行。
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
	relay_generation TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_commands_pending_idx
	ON relay_commands(status, delivery_seq);
-- Provider canonical event 在本机 outbox 内等待可靠上传；payload 只能是已加密 envelope。
-- attempts/next_attempt_at/last_error 由 migrate() 的 additive 列迁移补齐（v0.6 P2）；
-- relay_generation 由 v0.8.9 P1 补齐（世代隔离，见 relay_commands 注释）。
CREATE TABLE IF NOT EXISTS relay_event_outbox (
	event_id TEXT PRIMARY KEY,
	command_id TEXT NOT NULL,
	session_id TEXT NOT NULL,
	event_type TEXT NOT NULL,
	terminal_status TEXT NOT NULL DEFAULT '',
	envelope_json TEXT NOT NULL,
	created_at_unix_ms INTEGER NOT NULL DEFAULT 0,
	status TEXT NOT NULL DEFAULT 'pending',
	relay_generation TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL
);
-- Provider usage 的白名单投影单独出队上传到 Relay usage API；这里不保存 prompt、
-- 回复正文、工具参数、路径、费用或 provider 私有 payload。relay_generation 同上（v0.8.9 P1）。
CREATE TABLE IF NOT EXISTS relay_usage_outbox (
	usage_key TEXT PRIMARY KEY,
	session_id TEXT NOT NULL DEFAULT '',
	provider TEXT NOT NULL,
	model TEXT NOT NULL DEFAULT '',
	utc_day TEXT NOT NULL,
	input_tokens INTEGER NOT NULL,
	output_tokens INTEGER NOT NULL,
	cache_read_tokens INTEGER NOT NULL DEFAULT 0,
	cache_write_tokens INTEGER NOT NULL DEFAULT 0,
	context_window_tokens INTEGER NOT NULL DEFAULT 0,
	ttft_ms INTEGER,
	decode_throughput REAL,
	status TEXT NOT NULL DEFAULT 'pending',
	relay_generation TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_usage_outbox_pending_idx
	ON relay_usage_outbox(status, created_at, usage_key);
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
	DSH  bool   `json:"dsh,omitempty"`
}

// OpenStore 打开或创建本地状态库。
func OpenStore(path string) (*Store, error) {
	dsn, err := daemonSQLiteDSN(path)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// The CLI's workspace-confirm command can briefly overlap the long-lived
	// daemon while both processes open/migrate this store. The DSN applies the
	// wait policy to every pooled connection instead of only the first one.
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

const daemonSQLiteBusyTimeoutMS = 10000

// daemonSQLiteDSN injects connection-level SQLite settings used by every
// process/connection that opens the local daemon store. In particular,
// _busy_timeout prevents the short workspace-confirm helper from racing the
// daemon's initial schema migration and making the daemon appear offline.
func daemonSQLiteDSN(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", fmt.Errorf("daemon sqlite path is required")
	}
	if !strings.HasPrefix(path, "file:") {
		path = "file:" + path
	}
	parsed, err := url.Parse(path)
	if err != nil {
		return "", fmt.Errorf("parse daemon sqlite path: %w", err)
	}
	query := parsed.Query()
	query.Set("_busy_timeout", strconv.Itoa(daemonSQLiteBusyTimeoutMS))
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

func (s *Store) migrate() error {
	if _, err := s.db.Exec(localSchema); err != nil {
		return err
	}
	// P2 新增 workspace_id 时，已有 Daemon 本地库仍可能包含旧版 relay_commands。
	// 这里采用 additive ALTER，保留已落盘的命令、游标和 outbox，避免升级后重放失去状态。
	if err := s.ensureRelayCommandWorkspaceIDColumn(); err != nil {
		return err
	}
	// v0.6 P2：事件 outbox 增加重试退避与失败原因列。旧库升级只加列，不重写历史行，
	// 已落盘的 pending/delivered 状态与密文 envelope 保持原样。
	if err := s.ensureRelayEventOutboxRetryColumns(); err != nil {
		return err
	}
	if err := s.ensureColumnIfExists("relay_event_outbox", "terminal_status", "terminal_status TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumnIfExists("relay_event_outbox", "created_at_unix_ms", "created_at_unix_ms INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumnIfExists("relay_usage_outbox", "context_window_tokens", "context_window_tokens INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	// v0.8.9 P1（V089-03）：relay-scoped 三表增加 generation 关联列。旧行保持空串
	// （"世代未知"），新写入行由 Store 统一打上当前 relay_generation；世代切换时
	// 以该列区分"新世代活动行"与"待隔离旧行"，保证收口可审计、可回滚。
	if err := s.ensureColumnIfExists("relay_commands", "relay_generation", "relay_generation TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumnIfExists("relay_event_outbox", "relay_generation", "relay_generation TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	return s.ensureColumnIfExists("relay_usage_outbox", "relay_generation", "relay_generation TEXT NOT NULL DEFAULT ''")
}

// ensureColumnIfExists 是 additive 列迁移的最小实现：存在即跳过，缺失才 ALTER。
func (s *Store) ensureColumnIfExists(table, column, ddl string) error {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
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
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = s.db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + ddl)
	return err
}

// ensureRelayEventOutboxRetryColumns 为事件 outbox 补齐 v0.6 重试语义列：
// next_attempt_at 控制指数退避的最早重试时间；last_error 只保存脱敏错误分类。
func (s *Store) ensureRelayEventOutboxRetryColumns() error {
	if err := s.ensureColumnIfExists("relay_event_outbox", "attempts", "attempts INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumnIfExists("relay_event_outbox", "next_attempt_at", "next_attempt_at INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	return s.ensureColumnIfExists("relay_event_outbox", "last_error", "last_error TEXT NOT NULL DEFAULT ''")
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

// ConfirmWorkspace 把用户明确确认的 Git 根绑定到 Relay Workspace ID（workspace.create
// 与既有自管项目语义不变：确认时和每次读取时都做 realpath/Git 根校验）。
func (s *Store) ConfirmWorkspace(workspaceID, root string) (ConfirmedWorkspace, error) {
	return s.confirmWorkspace(workspaceID, root, true)
}

// ConfirmDSHWorkspace 把 DSH 证据确认的工作区绑定到 Relay Workspace ID（v0.8.5 §3.6）：
// 不要求 Git 根（有 DSH 持久化证据即登记），但保留同样的 canonical/realpath 安全校验；
// 非 Git 根工作区的 gitread 功能不可用，由调用方按 ConfirmedWorkspace.DSH 标注。
func (s *Store) ConfirmDSHWorkspace(workspaceID, root string) (ConfirmedWorkspace, error) {
	return s.confirmWorkspace(workspaceID, root, false)
}

func (s *Store) confirmWorkspace(workspaceID, root string, requireGit bool) (ConfirmedWorkspace, error) {
	workspaceID = strings.TrimSpace(workspaceID)
	root = strings.TrimSpace(root)
	if workspaceID == "" || len(workspaceID) > 128 || strings.ContainsAny(workspaceID, "\x00\r\n") {
		return ConfirmedWorkspace{}, errors.New("invalid workspace id")
	}
	if !filepath.IsAbs(root) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAbsolute
	}
	if requireGit && !workspacesafe.IsGitRoot(root) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	canonicalRoot, err := workspacesafe.ResolveRepoRelative(root, ".")
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if requireGit && !workspacesafe.IsGitRoot(canonicalRoot) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	confirmed := ConfirmedWorkspace{ID: workspaceID, Root: canonicalRoot, DSH: !requireGit}
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
	// v0.8.5 §3.6：DSH 证据确认的工作区不要求 Git 根（realpath 身份校验保留）；
	// Git 语义条目保持既有 Git 根校验不变，防止目录替换扩大本机读取范围。
	if !confirmed.DSH && !workspacesafe.IsGitRoot(canonicalRoot) {
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
	WorkspaceID string
	Kind        string
	PayloadJSON string
	Status      string
	Attempts    int
}

// RelayCommand 是专用 SSE 下行命令在 Daemon 本机的持久化投影。命令 ID 是执行去重键，
// delivery_seq 仅作为重连游标，二者不能互相替代。RelayGeneration 是行写入时的
// 本机世代标（v0.8.9 P1）：stale 404 分类（§3.3）依赖它区分"旧世代行"与"当前世代行"。
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
	RelayGeneration  string
}

// RelayEvent 是等待上传的 canonical event。envelope_json 已在调用方加密，Store 不解析它。
type RelayEvent struct {
	EventID   string
	CommandID string
	SessionID string
	EventType string
	// TerminalStatus is a stable, non-sensitive lifecycle projection for turn.completed.
	// It is deliberately separate from the opaque event envelope so Relay can update the
	// session status without decrypting provider payloads.
	TerminalStatus  string
	EnvelopeJSON    string
	CreatedAtUnixMS int64
}

// RelayUsage 是等待上传的白名单 usage 计数（ADR-010）。UsageKey 由 Daemon 对
// 来源事件生成，保证断线 outbox 重放幂等；绝不包含 prompt、回复、费用或精确时间。
type RelayUsage struct {
	UsageKey            string
	SessionID           string
	Provider            string
	Model               string
	UTCDay              string
	InputTokens         int64
	OutputTokens        int64
	CacheReadTokens     int64
	CacheWriteTokens    int64
	ContextWindowTokens int64
	TTFTMS              *int64
	DecodeThroughput    *float64
}

// RecordRelayCommand 原子记录一个 SSE delivery。相同 command_id 即使因至少一次投递再次到达，
// 也不能再次触发 Provider 进程；成功写入后才推进本机 delivery cursor。
func (s *Store) RecordRelayCommand(command RelayCommand) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if command.CommandID == "" || command.DeliverySeq <= 0 || command.Kind == "" ||
		(command.SessionID == "" && command.Kind != "workspace.create" && command.Kind != "workspace.sync_dsh" && command.Kind != "session.import_dsh") ||
		(command.Kind == "workspace.create" && command.WorkspaceID == "") ||
		(command.Kind == "workspace.sync_dsh" && command.WorkspaceID != "") ||
		(command.Kind == "session.import_dsh" && command.WorkspaceID == "") {
		return false, errors.New("invalid relay command")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback() }()

	// 世代打标（v0.8.9 P1）：与命令写入同一事务内读取当前 relay_generation，
	// 保证世代切换与打标串行化，不会出现"新世代行被旧值覆盖"的竞态。
	generation, err := s.stateGenerationLocked(tx)
	if err != nil {
		return false, err
	}
	now := time.Now().UnixMilli()
	result, err := tx.Exec(
		`INSERT OR IGNORE INTO relay_commands(
			command_id,delivery_seq,session_id,workspace_id,kind,lease_epoch,target_instance_id,target_terminal_id,
			payload_json,status,result_status,error_code,relay_generation,created_at,updated_at
		) VALUES(?,?,?,?,?,?,?,?,?,?,'','',?,?,?)`,
		command.CommandID, command.DeliverySeq, command.SessionID, command.WorkspaceID, command.Kind, command.LeaseEpoch,
		command.TargetInstanceID, command.TargetTerminalID, command.PayloadJSON, "received", generation, now, now)
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
				payload_json,status,result_status,error_code,relay_generation
			 FROM relay_commands WHERE command_id=?`, command.CommandID).Scan(
			&durable.CommandID, &durable.DeliverySeq, &durable.SessionID, &durable.WorkspaceID, &durable.Kind,
			&durable.LeaseEpoch, &durable.TargetInstanceID, &durable.TargetTerminalID, &durable.PayloadJSON,
			&durable.Status, &durable.ResultStatus, &durable.ErrorCode, &durable.RelayGeneration,
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

// ResetRelayDeliveryCursor 把投递游标清零。仅在 Terminal 身份变更（重新配对）时调用：
// delivery_seq 是 Terminal 局部序号，沿用旧身份的游标会让 SSE 以过大的 after_delivery_seq
// 重放，从而静默跳过新身份的全部投递。
func (s *Store) ResetRelayDeliveryCursor() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(
		`INSERT INTO local_state(key,value) VALUES('relay_delivery_seq','0')
		 ON CONFLICT(key) DO UPDATE SET value='0'`)
	if err != nil {
		return fmt.Errorf("reset relay delivery cursor: %w", err)
	}
	return nil
}

// RelayGeneration 返回本机记录的当前 Relay DB 世代（v0.8.9 P1 / §3.2）。
// 从未记录（首次接触世代感知 Relay）时返回空串。
func (s *Store) RelayGeneration() (string, error) {
	value, err := s.Get("relay_generation")
	if err != nil {
		return "", nil
	}
	return value, nil
}

// stateGenerationLocked 在已持有的锁内读取当前世代。写路径用它给新行打标，
// 避免"读取世代→写入行"之间发生世代切换造成错标。
func (s *Store) stateGenerationLocked(tx *sql.Tx) (string, error) {
	var value string
	err := tx.QueryRow(`SELECT value FROM local_state WHERE key='relay_generation'`).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return value, err
}

// RelayResetSummary 是世代切换收口的脱敏投影：只含计数与原因，不含命令正文、
// envelope、路径或 token。日志与诊断报告只允许使用本结构。
type RelayResetSummary struct {
	PreviousGeneration  string
	NewGeneration       string
	Reason              string
	QuarantinedCommands int64
	QuarantinedEvents   int64
	QuarantinedUsages   int64
}

// RelayGenerationResetErrorCode 是 stale command 世代收口的固定本地错误码（§3.3）。
// 不新增 wire 终态：命令行状态保持 completed + result_status=failed，仅以该错误码
// 与"本机判定"区分于普通执行失败。未知 404 不使用该码。
const RelayGenerationResetErrorCode = "RELAY_GENERATION_RESET"

// IsolateStaleRelayState 在单个 SQLite 事务内完成世代切换收口（V089-03 / §2.2-2）：
//  1. relay_commands 中未终态且不属于新世代的行 → completed/result_status=failed/
//     RELAY_GENERATION_RESET（不再向新 Relay resolve/ack）；
//  2. relay_event_outbox / relay_usage_outbox 中活动状态且不属于新世代的行 →
//     quarantined（保留行供审计，不参与后续 flush/requeue）；
//  3. delivery cursor 清零、旧 Terminal 绑定清除；
//  4. 写入新世代与 reset 原因（脱敏诊断）。
//
// 原子性由单事务保证：任意一步失败整体回滚，不留半清理状态（§8 风险表）。
func (s *Store) IsolateStaleRelayState(newGeneration, reason string) (RelayResetSummary, error) {
	if strings.TrimSpace(newGeneration) == "" {
		return RelayResetSummary{}, errors.New("isolate relay state: new generation is empty")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return RelayResetSummary{}, err
	}
	defer func() { _ = tx.Rollback() }()

	previous, err := s.stateGenerationLocked(tx)
	if err != nil {
		return RelayResetSummary{}, err
	}
	summary := RelayResetSummary{PreviousGeneration: previous, NewGeneration: newGeneration, Reason: reason}

	// 未终态命令按 §3.3 收口为本地终态。旧世代行（含升级期 generation='' 的历史行）
	// 一律隔离；新世代行不存在（本函数运行时新行尚未产生），条件保守排除。
	result, err := tx.Exec(
		`UPDATE relay_commands
		 SET status='completed', result_status='failed', error_code=?, updated_at=?
		 WHERE status IN ('received','rejecting','starting','started') AND relay_generation <> ?`,
		RelayGenerationResetErrorCode, time.Now().UnixMilli(), newGeneration)
	if err != nil {
		return RelayResetSummary{}, err
	}
	if summary.QuarantinedCommands, err = result.RowsAffected(); err != nil {
		return RelayResetSummary{}, err
	}
	// 事件 outbox：pending/failed → quarantined（fail-safe：QuarantinedForRecovery
	// 等恢复入口按状态过滤，世代过滤在 P4 另加查询层防线）。
	result, err = tx.Exec(
		`UPDATE relay_event_outbox
		 SET status='quarantined', next_attempt_at=0
		 WHERE status IN ('pending','failed') AND relay_generation <> ?`, newGeneration)
	if err != nil {
		return RelayResetSummary{}, err
	}
	if summary.QuarantinedEvents, err = result.RowsAffected(); err != nil {
		return RelayResetSummary{}, err
	}
	// usage outbox：仅 pending 是活动状态。
	result, err = tx.Exec(
		`UPDATE relay_usage_outbox
		 SET status='quarantined'
		 WHERE status='pending' AND relay_generation <> ?`, newGeneration)
	if err != nil {
		return RelayResetSummary{}, err
	}
	if summary.QuarantinedUsages, err = result.RowsAffected(); err != nil {
		return RelayResetSummary{}, err
	}
	// 游标清零 + 旧 Terminal 绑定清除（新绑定由 hello 后的 adoptTerminalIdentity 写入）。
	if _, err := tx.Exec(
		`INSERT INTO local_state(key,value) VALUES('relay_delivery_seq','0')
		 ON CONFLICT(key) DO UPDATE SET value='0'`); err != nil {
		return RelayResetSummary{}, err
	}
	if _, err := tx.Exec(`DELETE FROM local_state WHERE key='terminal_id'`); err != nil {
		return RelayResetSummary{}, err
	}
	for key, value := range map[string]string{
		"relay_generation":   newGeneration,
		"relay_reset_reason": reason,
	} {
		if _, err := tx.Exec(
			`INSERT INTO local_state(key,value) VALUES(?,?)
			 ON CONFLICT(key) DO UPDATE SET value=excluded.value`, key, value); err != nil {
			return RelayResetSummary{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return RelayResetSummary{}, err
	}
	return summary, nil
}

// SetRelayGeneration 仅记录世代（不隔离任何行）。用于"首次接触世代感知 Relay"的
// 升级路径：本地旧行保持活动（它们属于当前 Relay），新行开始打标。
func (s *Store) SetRelayGeneration(generation string) error {
	return s.Set("relay_generation", generation)
}

func (s *Store) PendingRelayCommands() ([]RelayCommand, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		`SELECT command_id,delivery_seq,session_id,workspace_id,kind,lease_epoch,target_instance_id,target_terminal_id,
			payload_json,status,result_status,error_code,relay_generation
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
			&command.ResultStatus, &command.ErrorCode, &command.RelayGeneration,
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
			payload_json,status,result_status,error_code,relay_generation
		 FROM relay_commands WHERE command_id=?`, commandID).Scan(
		&command.CommandID, &command.DeliverySeq, &command.SessionID, &command.WorkspaceID, &command.Kind, &command.LeaseEpoch,
		&command.TargetInstanceID, &command.TargetTerminalID, &command.PayloadJSON, &command.Status,
		&command.ResultStatus, &command.ErrorCode, &command.RelayGeneration,
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
	// 世代打标（v0.8.9 P1）：事件随当前 relay_generation 入队，世代切换时旧行被隔离。
	generation, err := s.generationLocked()
	if err != nil {
		return err
	}
	_, err = s.db.Exec(
		`INSERT OR IGNORE INTO relay_event_outbox(event_id,command_id,session_id,event_type,terminal_status,envelope_json,created_at_unix_ms,status,relay_generation,created_at)
		 VALUES(?,?,?,?,?,?,?,'pending',?,?)`,
		event.EventID, event.CommandID, event.SessionID, event.EventType, event.TerminalStatus, event.EnvelopeJSON, event.CreatedAtUnixMS, generation, time.Now().UnixMilli())
	return err
}

// generationLocked 在已持有 s.mu 的前提下读取当前 relay_generation。
func (s *Store) generationLocked() (string, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM local_state WHERE key='relay_generation'`).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return value, err
}

// relayEventRetry 常量定义事件 outbox 的重试上限与指数退避窗口。
// base 30 秒、按 2 的幂增长、封顶 15 分钟；达到 maxRelayEventAttempts 后转入 failed
// 长期保留，由 RequeueFailedRelayEvents 恢复入口重新入队，绝不静默删除。
const (
	relayEventRetryBaseMS = int64(30 * time.Second / time.Millisecond)
	relayEventRetryCapMS  = int64(15 * time.Minute / time.Millisecond)
	maxRelayEventAttempts = 8
)

// relayEventBackoffMS 计算第 attempts 次失败后的退避毫秒数。
func relayEventBackoffMS(attempts int) int64 {
	backoff := relayEventRetryBaseMS
	for i := 1; i < attempts && backoff < relayEventRetryCapMS; i++ {
		backoff *= 2
	}
	if backoff > relayEventRetryCapMS {
		backoff = relayEventRetryCapMS
	}
	return backoff
}

// PendingRelayEvents 返回到达重试时间的 pending 事件。
// 未到 next_attempt_at 的事件保持 pending 但跳过本轮，避免断网期间忙循环重试。
func (s *Store) PendingRelayEvents() ([]RelayEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		`SELECT event_id,command_id,session_id,event_type,terminal_status,envelope_json,created_at_unix_ms
		 FROM relay_event_outbox
		 WHERE status='pending' AND next_attempt_at <= ?
		 ORDER BY created_at,event_id`, time.Now().UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []RelayEvent
	for rows.Next() {
		var event RelayEvent
		if err := rows.Scan(&event.EventID, &event.CommandID, &event.SessionID, &event.EventType, &event.TerminalStatus, &event.EnvelopeJSON, &event.CreatedAtUnixMS); err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

// MarkRelayEventDelivered 只在 Relay 明确确认后调用；网络中断或响应损坏的事件必须保持
// pending 并走 MarkRelayEventAttempt，绝不能被提前标记 delivered。
func (s *Store) MarkRelayEventDelivered(eventID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE relay_event_outbox SET status='delivered', last_error='' WHERE event_id=?`, eventID)
	return err
}

// MarkRelayEventAttempt 在一次上传失败后记录尝试次数与脱敏错误分类，
// 并把下一次重试推迟到指数退避时间点；达到上限后转入 failed 长期保留。
func (s *Store) MarkRelayEventAttempt(eventID, sanitizedError string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var attempts int
	var status string
	if err := s.db.QueryRow(
		`SELECT attempts,status FROM relay_event_outbox WHERE event_id=?`, eventID).
		Scan(&attempts, &status); err != nil {
		return err
	}
	// 已 delivered 的历史事件不允许被失败路径复活；failed 只在未达上限前继续累计。
	if status != "pending" && status != "failed" {
		return errors.New("relay event not retryable: " + eventID)
	}
	nextAttempts := attempts + 1
	now := time.Now().UnixMilli()
	nextStatus := "pending"
	if nextAttempts >= maxRelayEventAttempts || status == "failed" {
		nextStatus = "failed"
	}
	backoff := relayEventBackoffMS(nextAttempts)
	_, err := s.db.Exec(
		`UPDATE relay_event_outbox
		 SET attempts=?, last_error=?, status=?, next_attempt_at=?
		 WHERE event_id=?`,
		nextAttempts, sanitizedError, nextStatus, now+backoff, eventID)
	return err
}

// relayEventPermanentReject 标记 Relay 对该事件内容的确定性拒绝（4xx 除 429）。
// 这类事件重试永远不会成功，转入 failed 长期保留；只有显式全量恢复才会重新入队。
const relayEventPermanentReject = "RELAY_REJECTED_PERMANENT"

// MarkRelayEventFailedNow 把事件立即置为 failed 并保留脱敏原因，不进入自动退避队列。
// 用于确定性拒绝（毒丸）等重试无意义的场景；失败行保留供审计和人工恢复。
func (s *Store) MarkRelayEventFailedNow(eventID, sanitizedReason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	result, err := s.db.Exec(
		`UPDATE relay_event_outbox
		 SET status='failed', last_error=?, next_attempt_at=0
		 WHERE event_id=? AND status IN ('pending','failed')`,
		sanitizedReason, eventID)
	if err != nil {
		return err
	}
	if affected, err := result.RowsAffected(); err == nil && affected == 0 {
		return errors.New("relay event not markable as failed: " + eventID)
	}
	return nil
}

// RequeueFailedRelayEvents 全量恢复 failed 事件（人工恢复入口）。
// 恢复不删除任何历史行，重复 event_id 仍由 Relay 幂等去重兜底。
func (s *Store) RequeueFailedRelayEvents() (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.requeueFailedRelayEventsWhere(`status='failed'`)
}

// RequeueTransientFailedRelayEvents 只恢复瞬态失败的 failed 事件（hello 成功后的自动恢复）。
// 确定性被 Relay 拒绝的毒丸事件保持 failed，避免每次重连都空转烧尽退避窗口。
func (s *Store) RequeueTransientFailedRelayEvents() (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.requeueFailedRelayEventsWhere(`status='failed' AND last_error <> '` + relayEventPermanentReject + `'`)
}

// requeueFailedRelayEventsLocked 把 failed 事件批量恢复为 pending 的内部实现。
func (s *Store) requeueFailedRelayEventsWhere(where string) (int64, error) {
	result, err := s.db.Exec(
		`UPDATE relay_event_outbox
		 SET status='pending', attempts=0, next_attempt_at=0
		 WHERE ` + where)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// RelayEventOutboxRow 是事件 outbox 的诊断/可观测性投影：只含状态元数据，
// 不含密文 envelope，可安全用于日志、健康指标与测试断言。
type RelayEventOutboxRow struct {
	EventID       string
	Status        string
	Attempts      int
	NextAttemptAt int64
	LastError     string
}

// RelayEventOutboxSnapshot 返回事件 outbox 的全量状态投影，供 P3 可观测性与回归使用。
func (s *Store) RelayEventOutboxSnapshot() ([]RelayEventOutboxRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		`SELECT event_id,status,attempts,next_attempt_at,last_error
		 FROM relay_event_outbox ORDER BY created_at,event_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RelayEventOutboxRow
	for rows.Next() {
		var row RelayEventOutboxRow
		if err := rows.Scan(&row.EventID, &row.Status, &row.Attempts, &row.NextAttemptAt, &row.LastError); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

func (s *Store) EnqueueRelayUsage(usage RelayUsage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if usage.UsageKey == "" || usage.Provider == "" || usage.UTCDay == "" ||
		usage.InputTokens < 0 || usage.OutputTokens < 0 ||
		usage.CacheReadTokens < 0 || usage.CacheWriteTokens < 0 {
		return errors.New("invalid relay usage")
	}
	// 世代打标（v0.8.9 P1）：usage 与事件同世代口径，切换后旧行被隔离不参与 flush。
	generation, err := s.generationLocked()
	if err != nil {
		return err
	}
	_, err = s.db.Exec(
		`INSERT OR IGNORE INTO relay_usage_outbox(
			usage_key,session_id,provider,model,utc_day,input_tokens,output_tokens,
			cache_read_tokens,cache_write_tokens,context_window_tokens,ttft_ms,decode_throughput,status,relay_generation,created_at
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'pending',?,?)`,
		usage.UsageKey, usage.SessionID, usage.Provider, usage.Model, usage.UTCDay,
		usage.InputTokens, usage.OutputTokens, usage.CacheReadTokens, usage.CacheWriteTokens,
		usage.ContextWindowTokens, usage.TTFTMS, usage.DecodeThroughput, generation, time.Now().UnixMilli())
	return err
}

func (s *Store) PendingRelayUsages() ([]RelayUsage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(
		`SELECT usage_key,session_id,provider,model,utc_day,input_tokens,output_tokens,
		        cache_read_tokens,cache_write_tokens,context_window_tokens,ttft_ms,decode_throughput
		   FROM relay_usage_outbox WHERE status='pending' ORDER BY created_at,usage_key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var usages []RelayUsage
	for rows.Next() {
		var usage RelayUsage
		var ttft sql.NullInt64
		var throughput sql.NullFloat64
		if err := rows.Scan(
			&usage.UsageKey, &usage.SessionID, &usage.Provider, &usage.Model, &usage.UTCDay,
			&usage.InputTokens, &usage.OutputTokens, &usage.CacheReadTokens, &usage.CacheWriteTokens,
			&usage.ContextWindowTokens, &ttft, &throughput,
		); err != nil {
			return nil, err
		}
		if ttft.Valid {
			value := ttft.Int64
			usage.TTFTMS = &value
		}
		if throughput.Valid {
			value := throughput.Float64
			usage.DecodeThroughput = &value
		}
		usages = append(usages, usage)
	}
	return usages, rows.Err()
}

func (s *Store) MarkRelayUsageDelivered(usageKey string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE relay_usage_outbox SET status='delivered' WHERE usage_key=?`, usageKey)
	return err
}

// DefaultStatePath 返回默认本地状态库路径。
func DefaultStatePath(root string) string {
	return filepath.Join(root, "daemon.db")
}
