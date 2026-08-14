package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// sqliteRepo 是 Repository 的 SQLite 实现，绑定一个 *sql.DB 或 *sql.Tx。
// 所有查询显式使用占位符，禁止字符串拼接 SQL；正文/密钥不得进入列值明文。
type sqliteRepo struct {
	db interface {
		ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
		QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
		QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	}
}

// NewRepository 从 *sql.DB 构造仓储。
func NewRepository(db *sql.DB) Repository {
	return &sqliteRepo{db: db}
}

func (r *sqliteRepo) CreateAccount(ctx context.Context, id, email string, passwordHash []byte, createdAt time.Time) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO accounts(id,email,password_hash,created_at) VALUES(?,?,?,?)`,
		id, email, passwordHash, createdAt.UnixMilli())
	return err
}

func (r *sqliteRepo) AccountByEmail(ctx context.Context, email string) (AccountRow, error) {
	return scanAccount(r.db.QueryRowContext(ctx,
		`SELECT id,email,password_hash,created_at FROM accounts WHERE email=?`, email))
}

func (r *sqliteRepo) AccountByID(ctx context.Context, id string) (AccountRow, error) {
	return scanAccount(r.db.QueryRowContext(ctx,
		`SELECT id,email,password_hash,created_at FROM accounts WHERE id=?`, id))
}

func scanAccount(row *sql.Row) (AccountRow, error) {
	var a AccountRow
	var created int64
	if err := row.Scan(&a.ID, &a.Email, &a.PasswordHash, &created); err != nil {
		return AccountRow{}, err
	}
	a.CreatedAt = time.UnixMilli(created)
	return a, nil
}

func (r *sqliteRepo) CreateDevice(ctx context.Context, d DeviceRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO devices(id,account_id,role,status,display_name,platform,identity_public_key,encryption_public_key,last_seen_unix_ms)
		 VALUES(?,?,?,?,?,?,?,?,?)`,
		d.ID, d.AccountID, d.Role, d.Status, d.DisplayName, d.Platform, d.IdentityPublicKey, d.EncryptionPublicKey, d.LastSeenUnixMS)
	return err
}

func (r *sqliteRepo) DeviceByID(ctx context.Context, id string) (DeviceRow, error) {
	return scanDevice(r.db.QueryRowContext(ctx,
		`SELECT id,account_id,role,status,display_name,platform,identity_public_key,encryption_public_key,last_seen_unix_ms
		 FROM devices WHERE id=?`, id))
}

func (r *sqliteRepo) ListDevices(ctx context.Context, accountID string) ([]DeviceRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,account_id,role,status,display_name,platform,identity_public_key,encryption_public_key,last_seen_unix_ms
		 FROM devices WHERE account_id=? ORDER BY last_seen_unix_ms DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DeviceRow
	for rows.Next() {
		var d DeviceRow
		if err := rows.Scan(&d.ID, &d.AccountID, &d.Role, &d.Status, &d.DisplayName, &d.Platform, &d.IdentityPublicKey, &d.EncryptionPublicKey, &d.LastSeenUnixMS); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func scanDevice(row *sql.Row) (DeviceRow, error) {
	var d DeviceRow
	if err := row.Scan(&d.ID, &d.AccountID, &d.Role, &d.Status, &d.DisplayName, &d.Platform, &d.IdentityPublicKey, &d.EncryptionPublicKey, &d.LastSeenUnixMS); err != nil {
		return DeviceRow{}, err
	}
	return d, nil
}

func (r *sqliteRepo) SetDeviceStatus(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE devices SET status=? WHERE id=?`, status, id)
	return err
}

func (r *sqliteRepo) CreateTokenFamily(ctx context.Context, tf TokenFamilyRow) error {
	revoked := 0
	if tf.Revoked {
		revoked = 1
	}
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO token_families(id,account_id,device_id,refresh_hash,revoked,created_at) VALUES(?,?,?,?,?,?)`,
		tf.ID, tf.AccountID, tf.DeviceID, tf.RefreshHash, revoked, tf.CreatedAt.UnixMilli())
	return err
}

func (r *sqliteRepo) TokenFamilyByID(ctx context.Context, id string) (TokenFamilyRow, error) {
	var tf TokenFamilyRow
	var revoked int
	var created int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,account_id,device_id,refresh_hash,revoked,created_at FROM token_families WHERE id=?`, id).
		Scan(&tf.ID, &tf.AccountID, &tf.DeviceID, &tf.RefreshHash, &revoked, &created); err != nil {
		return TokenFamilyRow{}, err
	}
	tf.Revoked = revoked == 1
	tf.CreatedAt = time.UnixMilli(created)
	return tf, nil
}

func (r *sqliteRepo) UpdateTokenFamilyRefreshHash(ctx context.Context, id, hash string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE token_families SET refresh_hash=? WHERE id=?`, hash, id)
	return err
}

func (r *sqliteRepo) TokenFamilyByRefreshHash(ctx context.Context, hash string) (TokenFamilyRow, error) {
	var tf TokenFamilyRow
	var revoked int
	var created int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,account_id,device_id,refresh_hash,revoked,created_at FROM token_families WHERE refresh_hash=?`, hash).
		Scan(&tf.ID, &tf.AccountID, &tf.DeviceID, &tf.RefreshHash, &revoked, &created); err != nil {
		return TokenFamilyRow{}, err
	}
	tf.Revoked = revoked == 1
	tf.CreatedAt = time.UnixMilli(created)
	return tf, nil
}

func (r *sqliteRepo) RevokeTokenFamily(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE token_families SET revoked=1 WHERE id=?`, id)
	return err
}

func (r *sqliteRepo) PutAccessToken(ctx context.Context, at AccessTokenRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO access_tokens(token,account_id,device_id,role,expires_at) VALUES(?,?,?,?,?)`,
		at.Token, at.AccountID, at.DeviceID, at.Role, at.ExpiresAt.UnixMilli())
	return err
}

func (r *sqliteRepo) AccessTokenByValue(ctx context.Context, token string) (AccessTokenRow, error) {
	var at AccessTokenRow
	var expires int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT token,account_id,device_id,role,expires_at FROM access_tokens WHERE token=?`, token).
		Scan(&at.Token, &at.AccountID, &at.DeviceID, &at.Role, &expires); err != nil {
		return AccessTokenRow{}, err
	}
	at.ExpiresAt = time.UnixMilli(expires)
	return at, nil
}

func (r *sqliteRepo) DeleteAccessToken(ctx context.Context, token string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM access_tokens WHERE token=?`, token)
	return err
}

func (r *sqliteRepo) CreatePairingRequest(ctx context.Context, p PairingRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO pairing_requests(id,account_id,role,status,display_name,identity_public_key,encryption_public_key,platform,expires_at)
		 VALUES(?,?,?,?,?,?,?,?,?)`,
		p.ID, p.AccountID, p.Role, p.Status, p.DisplayName, p.IdentityPublicKey, p.EncryptionPublicKey, p.Platform, p.ExpiresAt.UnixMilli())
	return err
}

func (r *sqliteRepo) PairingByID(ctx context.Context, id string) (PairingRow, error) {
	var p PairingRow
	var expires int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,account_id,role,status,display_name,identity_public_key,encryption_public_key,platform,expires_at
		 FROM pairing_requests WHERE id=?`, id).
		Scan(&p.ID, &p.AccountID, &p.Role, &p.Status, &p.DisplayName, &p.IdentityPublicKey, &p.EncryptionPublicKey, &p.Platform, &expires); err != nil {
		return PairingRow{}, err
	}
	p.ExpiresAt = time.UnixMilli(expires)
	return p, nil
}

func (r *sqliteRepo) SetPairingStatus(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE pairing_requests SET status=? WHERE id=?`, status, id)
	return err
}

func (r *sqliteRepo) PutKeyWrap(ctx context.Context, kw KeyWrapRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO device_key_wraps(dek_id,recipient_device_id,sender_device_id,wrapped_dek,created_at) VALUES(?,?,?,?,?)`,
		kw.DEKID, kw.RecipientDeviceID, kw.SenderDeviceID, kw.WrappedDEK, kw.CreatedAt.UnixMilli())
	return err
}

func (r *sqliteRepo) ListKeyWraps(ctx context.Context, dekID string) ([]KeyWrapRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT dek_id,recipient_device_id,sender_device_id,wrapped_dek,created_at FROM device_key_wraps WHERE dek_id=?`, dekID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []KeyWrapRow
	for rows.Next() {
		var kw KeyWrapRow
		var created int64
		if err := rows.Scan(&kw.DEKID, &kw.RecipientDeviceID, &kw.SenderDeviceID, &kw.WrappedDEK, &created); err != nil {
			return nil, err
		}
		kw.CreatedAt = time.UnixMilli(created)
		out = append(out, kw)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) UpsertRecoveryCode(ctx context.Context, rc RecoveryRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO recovery_codes(account_id,code_hash,failed_attempts,locked_until,created_at) VALUES(?,?,?,?,?)
		 ON CONFLICT(account_id) DO UPDATE SET code_hash=excluded.code_hash, failed_attempts=0, locked_until=0`,
		rc.AccountID, rc.CodeHash, rc.FailedAttempts, rc.LockedUntil.UnixMilli(), rc.CreatedAt.UnixMilli())
	return err
}

func (r *sqliteRepo) RecoveryByAccount(ctx context.Context, accountID string) (RecoveryRow, error) {
	var rc RecoveryRow
	var locked int64
	var created int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT account_id,code_hash,failed_attempts,locked_until,created_at FROM recovery_codes WHERE account_id=?`, accountID).
		Scan(&rc.AccountID, &rc.CodeHash, &rc.FailedAttempts, &locked, &created); err != nil {
		return RecoveryRow{}, err
	}
	rc.LockedUntil = time.UnixMilli(locked)
	rc.CreatedAt = time.UnixMilli(created)
	return rc, nil
}

func (r *sqliteRepo) AppendAudit(ctx context.Context, accountID, action, metadataJSON string) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO audit_events(account_id,action,metadata_json) VALUES(?,?,?)`,
		accountID, action, metadataJSON)
	return err
}

// WithTx 在事务中执行 fn；fn 接收绑定到同一事务的 Repository。
func (r *sqliteRepo) WithTx(ctx context.Context, fn func(ctx context.Context, tx Repository) error) error {
	db, ok := r.db.(*sql.DB)
	if !ok {
		// 已经处于事务上下文，直接复用当前连接执行（嵌套事务退化为同连接）。
		return fn(ctx, r)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(ctx, &sqliteRepo{db: tx}); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// ErrNotFound 统一表示“行不存在”，供 domain 层映射稳定错误。
var ErrNotFound = errors.New("not found")

func (r *sqliteRepo) TouchDeviceLastSeen(ctx context.Context, deviceID string, unixMS int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE devices SET last_seen_unix_ms=? WHERE id=?`, unixMS, deviceID)
	return err
}

func (r *sqliteRepo) CreateTerminal(ctx context.Context, t TerminalRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO terminals(id,device_id,account_id,hostname,platform,status,last_seen_unix_ms)
		 VALUES(?,?,?,?,?,?,?)`,
		t.ID, t.DeviceID, t.AccountID, t.Hostname, t.Platform, t.Status, t.LastSeenUnixMS)
	return err
}

func (r *sqliteRepo) TerminalByDeviceID(ctx context.Context, deviceID string) (TerminalRow, error) {
	var t TerminalRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,device_id,account_id,hostname,platform,status,last_seen_unix_ms
		 FROM terminals WHERE device_id=?`, deviceID).
		Scan(&t.ID, &t.DeviceID, &t.AccountID, &t.Hostname, &t.Platform, &t.Status, &t.LastSeenUnixMS); err != nil {
		return TerminalRow{}, err
	}
	return t, nil
}

func (r *sqliteRepo) ListTerminals(ctx context.Context, accountID string) ([]TerminalRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,device_id,account_id,hostname,platform,status,last_seen_unix_ms
		 FROM terminals WHERE account_id=? ORDER BY last_seen_unix_ms DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TerminalRow
	for rows.Next() {
		var t TerminalRow
		if err := rows.Scan(&t.ID, &t.DeviceID, &t.AccountID, &t.Hostname, &t.Platform, &t.Status, &t.LastSeenUnixMS); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) TouchTerminal(ctx context.Context, id string, unixMS int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE terminals SET last_seen_unix_ms=? WHERE id=?`, unixMS, id)
	return err
}

func (r *sqliteRepo) CreateProject(ctx context.Context, p ProjectRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO projects(id,account_id,fingerprint,encrypted_name) VALUES(?,?,?,?)`,
		p.ID, p.AccountID, p.Fingerprint, p.EncryptedName)
	return err
}

func (r *sqliteRepo) ListProjects(ctx context.Context, accountID string) ([]ProjectRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,account_id,fingerprint,encrypted_name FROM projects WHERE account_id=? ORDER BY id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ProjectRow
	for rows.Next() {
		var p ProjectRow
		if err := rows.Scan(&p.ID, &p.AccountID, &p.Fingerprint, &p.EncryptedName); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) CreateWorkspace(ctx context.Context, w WorkspaceRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO workspaces(id,project_id,terminal_id,canonical_root,branch,status) VALUES(?,?,?,?,?,?)`,
		w.ID, w.ProjectID, w.TerminalID, w.CanonicalRoot, w.Branch, w.Status)
	return err
}

func (r *sqliteRepo) WorkspaceByID(ctx context.Context, id string) (WorkspaceRow, error) {
	var w WorkspaceRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,project_id,terminal_id,canonical_root,branch,status FROM workspaces WHERE id=?`, id).
		Scan(&w.ID, &w.ProjectID, &w.TerminalID, &w.CanonicalRoot, &w.Branch, &w.Status); err != nil {
		return WorkspaceRow{}, err
	}
	return w, nil
}

func (r *sqliteRepo) ListWorkspaces(ctx context.Context, accountID string) ([]WorkspaceRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT w.id,w.project_id,w.terminal_id,w.canonical_root,w.branch,w.status
		 FROM workspaces w JOIN projects p ON p.id=w.project_id
		 WHERE p.account_id=? ORDER BY w.id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WorkspaceRow
	for rows.Next() {
		var w WorkspaceRow
		if err := rows.Scan(&w.ID, &w.ProjectID, &w.TerminalID, &w.CanonicalRoot, &w.Branch, &w.Status); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) CreateSession(ctx context.Context, s SessionRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO sessions(id,workspace_id,account_id,status,provider,last_seq,current_instance_id)
		 VALUES(?,?,?,?,?,?,?)`,
		s.ID, s.WorkspaceID, s.AccountID, s.Status, s.Provider, s.LastSeq, s.CurrentInstanceID)
	return err
}

func (r *sqliteRepo) SessionByID(ctx context.Context, id string) (SessionRow, error) {
	var s SessionRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,workspace_id,account_id,status,provider,last_seq,current_instance_id FROM sessions WHERE id=?`, id).
		Scan(&s.ID, &s.WorkspaceID, &s.AccountID, &s.Status, &s.Provider, &s.LastSeq, &s.CurrentInstanceID); err != nil {
		return SessionRow{}, err
	}
	return s, nil
}

func (r *sqliteRepo) ListSessions(ctx context.Context, accountID string) ([]SessionRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,workspace_id,account_id,status,provider,last_seq,current_instance_id
		 FROM sessions WHERE account_id=? ORDER BY last_seq DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionRow
	for rows.Next() {
		var s SessionRow
		if err := rows.Scan(&s.ID, &s.WorkspaceID, &s.AccountID, &s.Status, &s.Provider, &s.LastSeq, &s.CurrentInstanceID); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) SetSessionStatus(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET status=? WHERE id=?`, status, id)
	return err
}

func (r *sqliteRepo) SetSessionInstance(ctx context.Context, id, instanceID string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET current_instance_id=? WHERE id=?`, instanceID, id)
	return err
}

func (r *sqliteRepo) CreateInstance(ctx context.Context, i InstanceRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO session_instances(id,session_id,lease_epoch,status,wake_result) VALUES(?,?,?,?,?)`,
		i.ID, i.SessionID, i.LeaseEpoch, i.Status, i.WakeResult)
	return err
}

func (r *sqliteRepo) InstanceByID(ctx context.Context, id string) (InstanceRow, error) {
	var i InstanceRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,session_id,lease_epoch,status,wake_result FROM session_instances WHERE id=?`, id).
		Scan(&i.ID, &i.SessionID, &i.LeaseEpoch, &i.Status, &i.WakeResult); err != nil {
		return InstanceRow{}, err
	}
	return i, nil
}

// AppendEvent 写入事件，seq 用 MAX+1 保证并发单调，返回分配的 seq。
func (r *sqliteRepo) AppendEvent(ctx context.Context, e SessionEventRow) (int64, error) {
	if e.EventSeq <= 0 {
		if err := r.db.QueryRowContext(ctx,
			`SELECT COALESCE(MAX(event_seq),0)+1 FROM session_events WHERE session_id=?`, e.SessionID).
			Scan(&e.EventSeq); err != nil {
			return 0, err
		}
	}
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO session_events(session_id,event_seq,event_type,envelope_json) VALUES(?,?,?,?)`,
		e.SessionID, e.EventSeq, e.EventType, e.EnvelopeJSON)
	return e.EventSeq, err
}

func (r *sqliteRepo) ListEventsAfter(ctx context.Context, sessionID string, afterSeq int64) ([]SessionEventRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT session_id,event_seq,event_type,envelope_json FROM session_events
		 WHERE session_id=? AND event_seq>? ORDER BY event_seq`, sessionID, afterSeq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionEventRow
	for rows.Next() {
		var e SessionEventRow
		if err := rows.Scan(&e.SessionID, &e.EventSeq, &e.EventType, &e.EnvelopeJSON); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) CreateCommand(ctx context.Context, c CommandRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO commands(id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,target_instance_id,ciphertext_json)
		 VALUES(?,?,?,?,?,?,?,?,?,?)`,
		c.ID, c.AccountID, c.SessionID, c.Kind, c.Status, c.ScopeHash, c.IdempotencyKey, c.LeaseEpoch, c.TargetInstanceID, c.CiphertextJSON)
	return err
}

func scanCommand(row *sql.Row) (CommandRow, error) {
	var c CommandRow
	if err := row.Scan(&c.ID, &c.AccountID, &c.SessionID, &c.Kind, &c.Status, &c.ScopeHash, &c.IdempotencyKey, &c.LeaseEpoch, &c.TargetInstanceID, &c.CiphertextJSON); err != nil {
		return CommandRow{}, err
	}
	return c, nil
}

func (r *sqliteRepo) CommandByID(ctx context.Context, id string) (CommandRow, error) {
	return scanCommand(r.db.QueryRowContext(ctx,
		`SELECT id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,target_instance_id,ciphertext_json
		 FROM commands WHERE id=?`, id))
}

func (r *sqliteRepo) CommandByScopeKey(ctx context.Context, scopeHash, idempotencyKey string) (CommandRow, error) {
	return scanCommand(r.db.QueryRowContext(ctx,
		`SELECT id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,target_instance_id,ciphertext_json
		 FROM commands WHERE scope_hash=? AND idempotency_key=?`, scopeHash, idempotencyKey))
}

func (r *sqliteRepo) UpdateCommandStatus(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE commands SET status=? WHERE id=?`, status, id)
	return err
}

func (r *sqliteRepo) ListCommands(ctx context.Context, sessionID string) ([]CommandRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,target_instance_id,ciphertext_json
		 FROM commands WHERE session_id=? ORDER BY id`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CommandRow
	for rows.Next() {
		var c CommandRow
		if err := rows.Scan(&c.ID, &c.AccountID, &c.SessionID, &c.Kind, &c.Status, &c.ScopeHash, &c.IdempotencyKey, &c.LeaseEpoch, &c.TargetInstanceID, &c.CiphertextJSON); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) AcquireLease(ctx context.Context, l LeaseRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO control_leases(session_id,device_id,epoch,instance_id) VALUES(?,?,?,?)
		 ON CONFLICT(session_id) DO UPDATE SET device_id=excluded.device_id, epoch=excluded.epoch, instance_id=excluded.instance_id`,
		l.SessionID, l.DeviceID, l.Epoch, l.InstanceID)
	return err
}

func (r *sqliteRepo) LeaseBySession(ctx context.Context, sessionID string) (LeaseRow, error) {
	var l LeaseRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT session_id,device_id,epoch,instance_id FROM control_leases WHERE session_id=?`, sessionID).
		Scan(&l.SessionID, &l.DeviceID, &l.Epoch, &l.InstanceID); err != nil {
		return LeaseRow{}, err
	}
	return l, nil
}

func (r *sqliteRepo) ReleaseLease(ctx context.Context, sessionID string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM control_leases WHERE session_id=?`, sessionID)
	return err
}

func (r *sqliteRepo) EnqueueOutbox(ctx context.Context, o OutboxRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO outbox(kind,payload_json,status,attempts) VALUES(?,?,?,?)`,
		o.Kind, o.PayloadJSON, o.Status, o.Attempts)
	return err
}

func (r *sqliteRepo) ClaimOutbox(ctx context.Context, id int64) (OutboxRow, error) {
	var o OutboxRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,kind,payload_json,status,attempts FROM outbox WHERE id=?`, id).
		Scan(&o.ID, &o.Kind, &o.PayloadJSON, &o.Status, &o.Attempts); err != nil {
		return OutboxRow{}, err
	}
	return o, nil
}

func (r *sqliteRepo) MarkOutboxDone(ctx context.Context, id int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE outbox SET status='done', attempts=attempts+1 WHERE id=?`, id)
	return err
}

func (r *sqliteRepo) MarkOutboxFailed(ctx context.Context, id int64, attempts int) error {
	_, err := r.db.ExecContext(ctx, `UPDATE outbox SET status='failed', attempts=? WHERE id=?`, attempts, id)
	return err
}

func (r *sqliteRepo) ListPendingOutbox(ctx context.Context, limit int) ([]OutboxRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,kind,payload_json,status,attempts FROM outbox WHERE status IN ('pending','failed') ORDER BY id LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OutboxRow
	for rows.Next() {
		var o OutboxRow
		if err := rows.Scan(&o.ID, &o.Kind, &o.PayloadJSON, &o.Status, &o.Attempts); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}
