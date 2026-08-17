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

// CountAccounts 只用于单租户首个 owner bootstrap 门禁，不返回账号内容。
func (r *sqliteRepo) CountAccounts(ctx context.Context) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM accounts`).Scan(&count)
	return count, err
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

// UpdateBootstrapDevice 只允许初始 owner 写入一次公钥，防止已配对设备被静默换钥。
func (r *sqliteRepo) UpdateBootstrapDevice(ctx context.Context, d DeviceRow) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE devices
		 SET display_name=?, platform=?, identity_public_key=?, encryption_public_key=?
		 WHERE id=? AND account_id=? AND role=? AND status=?
		   AND identity_public_key='' AND encryption_public_key=''`,
		d.DisplayName, d.Platform, d.IdentityPublicKey, d.EncryptionPublicKey,
		d.ID, d.AccountID, d.Role, d.Status)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
}

func (r *sqliteRepo) CreateTokenFamily(ctx context.Context, tf TokenFamilyRow) error {
	revoked := 0
	if tf.Revoked {
		revoked = 1
	}
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO token_families(id,account_id,device_id,role,refresh_hash,revoked,created_at) VALUES(?,?,?,?,?,?,?)`,
		tf.ID, tf.AccountID, tf.DeviceID, tf.Role, tf.RefreshHash, revoked, tf.CreatedAt.UnixMilli())
	return err
}

func (r *sqliteRepo) TokenFamilyByID(ctx context.Context, id string) (TokenFamilyRow, error) {
	var tf TokenFamilyRow
	var revoked int
	var created int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,account_id,device_id,role,refresh_hash,revoked,created_at FROM token_families WHERE id=?`, id).
		Scan(&tf.ID, &tf.AccountID, &tf.DeviceID, &tf.Role, &tf.RefreshHash, &revoked, &created); err != nil {
		return TokenFamilyRow{}, err
	}
	tf.Revoked = revoked == 1
	tf.CreatedAt = time.UnixMilli(created)
	return tf, nil
}

// RotateTokenFamilyRefreshHash 是 refresh rotation 的比较交换操作。
// 设备 family 在 SQL 条件中复核活跃状态，避免校验与落库之间被撤销后仍签发 access。
func (r *sqliteRepo) RotateTokenFamilyRefreshHash(ctx context.Context, id, currentHash, nextHash string, notBefore time.Time) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE token_families
		 SET refresh_hash=?
		 WHERE id=? AND refresh_hash=? AND revoked=0 AND created_at>=?
		   AND (
			 device_id='' OR EXISTS (
				 SELECT 1 FROM devices
				 WHERE devices.id=token_families.device_id
				   AND devices.account_id=token_families.account_id
				   AND devices.status='active'
			 )
		   )`,
		nextHash, id, currentHash, notBefore.UnixMilli())
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
}

func (r *sqliteRepo) TokenFamilyByRefreshHash(ctx context.Context, hash string) (TokenFamilyRow, error) {
	var tf TokenFamilyRow
	var revoked int
	var created int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,account_id,device_id,role,refresh_hash,revoked,created_at FROM token_families WHERE refresh_hash=?`, hash).
		Scan(&tf.ID, &tf.AccountID, &tf.DeviceID, &tf.Role, &tf.RefreshHash, &revoked, &created); err != nil {
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

// RevokeTokenFamilyIfCurrent 只撤销当前认证主体持有的 refresh，避免仅凭 family ID 造成跨账号注销。
func (r *sqliteRepo) RevokeTokenFamilyIfCurrent(ctx context.Context, id, accountID, refreshHash string) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE token_families SET revoked=1
		 WHERE id=? AND account_id=? AND refresh_hash=? AND revoked=0`,
		id, accountID, refreshHash)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
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

// SetPairingStatusIfCurrent 通过条件更新原子认领配对请求，避免并发批准创建重复设备。
func (r *sqliteRepo) SetPairingStatusIfCurrent(ctx context.Context, id, currentStatus, nextStatus string) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE pairing_requests SET status=? WHERE id=? AND status=?`, nextStatus, id, currentStatus)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
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
		 ON CONFLICT(account_id) DO UPDATE SET
		 code_hash=excluded.code_hash,
		 failed_attempts=excluded.failed_attempts,
		 locked_until=excluded.locked_until,
		 created_at=excluded.created_at`,
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

// ConsumeRecoveryCode 以哈希和冷却时间作为条件原子消费恢复码，避免并发重放。
func (r *sqliteRepo) ConsumeRecoveryCode(ctx context.Context, accountID, codeHash string, now time.Time) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`DELETE FROM recovery_codes
		 WHERE account_id=? AND code_hash=? AND locked_until<=?`,
		accountID, codeHash, now.UnixMilli())
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
}

func (r *sqliteRepo) AppendAudit(ctx context.Context, accountID, action, metadataJSON string) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO audit_events(account_id,action,metadata_json) VALUES(?,?,?)`,
		accountID, action, metadataJSON)
	return err
}

// ListAudit 分页读取账号的脱敏审计元数据。limit 上限 100、offset 非负；
// 只返回白名单 action/metadata，绝不包含正文、token 或路径。
func (r *sqliteRepo) ListAudit(ctx context.Context, accountID string, limit, offset int) ([]AuditRow, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,action,metadata_json FROM audit_events
		 WHERE account_id=? ORDER BY id DESC LIMIT ? OFFSET ?`,
		accountID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuditRow
	for rows.Next() {
		var row AuditRow
		if err := rows.Scan(&row.ID, &row.Action, &row.MetadataJSON); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
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
		`INSERT INTO terminals(
			id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms
		) VALUES(?,?,?,?,?,?,?,?,?,?,?)`,
		t.ID, t.DeviceID, t.AccountID, t.Hostname, t.Platform, t.Status, t.LastSeenUnixMS,
		t.ProtocolVersion, t.DaemonVersion, t.CapabilitiesJSON, t.LastHeartbeatUnixMS)
	return err
}

func (r *sqliteRepo) TerminalByID(ctx context.Context, id string) (TerminalRow, error) {
	return scanTerminal(r.db.QueryRowContext(ctx,
		`SELECT id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms
		 FROM terminals WHERE id=?`, id))
}

func (r *sqliteRepo) TerminalByDeviceID(ctx context.Context, deviceID string) (TerminalRow, error) {
	return scanTerminal(r.db.QueryRowContext(ctx,
		`SELECT id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms
		 FROM terminals WHERE device_id=?`, deviceID))
}

func scanTerminal(row *sql.Row) (TerminalRow, error) {
	var t TerminalRow
	if err := row.Scan(
		&t.ID, &t.DeviceID, &t.AccountID, &t.Hostname, &t.Platform, &t.Status, &t.LastSeenUnixMS,
		&t.ProtocolVersion, &t.DaemonVersion, &t.CapabilitiesJSON, &t.LastHeartbeatUnixMS,
	); err != nil {
		return TerminalRow{}, err
	}
	return t, nil
}

func (r *sqliteRepo) ListTerminals(ctx context.Context, accountID string) ([]TerminalRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms
		 FROM terminals WHERE account_id=? ORDER BY last_seen_unix_ms DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TerminalRow
	for rows.Next() {
		var t TerminalRow
		if err := rows.Scan(
			&t.ID, &t.DeviceID, &t.AccountID, &t.Hostname, &t.Platform, &t.Status, &t.LastSeenUnixMS,
			&t.ProtocolVersion, &t.DaemonVersion, &t.CapabilitiesJSON, &t.LastHeartbeatUnixMS,
		); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) TouchTerminal(ctx context.Context, id string, unixMS int64) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE terminals SET status='online', last_seen_unix_ms=?, last_heartbeat_unix_ms=? WHERE id=?`,
		unixMS, unixMS, id)
	return err
}

// UpsertDaemonTerminal 以 device_id 作为 Terminal 身份锚点。Daemon 只能声明自身版本、
// capabilities 与脱敏主机信息，不能借此覆盖账号、设备或 Workspace 归属。
func (r *sqliteRepo) UpsertDaemonTerminal(ctx context.Context, t TerminalRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO terminals(
			id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms
		) VALUES(?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(device_id) DO UPDATE SET
			hostname=excluded.hostname,
			platform=excluded.platform,
			status=excluded.status,
			last_seen_unix_ms=excluded.last_seen_unix_ms,
			protocol_version=excluded.protocol_version,
			daemon_version=excluded.daemon_version,
			capabilities_json=excluded.capabilities_json,
			last_heartbeat_unix_ms=excluded.last_heartbeat_unix_ms`,
		t.ID, t.DeviceID, t.AccountID, t.Hostname, t.Platform, t.Status, t.LastSeenUnixMS,
		t.ProtocolVersion, t.DaemonVersion, t.CapabilitiesJSON, t.LastHeartbeatUnixMS)
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

func (r *sqliteRepo) SetSessionLastSeq(ctx context.Context, id string, lastSeq int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET last_seq=? WHERE id=?`, lastSeq, id)
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

// AppendEvent 同一事务内写 session-local 序号与账号流 cursor。SQLite 是两种序号的唯一事实源；
// 进程内 SSE Hub 只能在本方法所在事务提交后缩短观察延迟，不能补偿或替代游标日志。
func (r *sqliteRepo) AppendEvent(ctx context.Context, e SessionEventRow) (int64, error) {
	if e.EventSeq <= 0 {
		if err := r.db.QueryRowContext(ctx,
			`SELECT COALESCE(MAX(event_seq),0)+1 FROM session_events WHERE session_id=?`, e.SessionID).
			Scan(&e.EventSeq); err != nil {
			return 0, err
		}
	}
	if _, err := r.db.ExecContext(ctx,
		`INSERT INTO session_events(session_id,event_seq,event_type,envelope_json) VALUES(?,?,?,?)`,
		e.SessionID, e.EventSeq, e.EventType, e.EnvelopeJSON); err != nil {
		return 0, err
	}
	if _, err := r.db.ExecContext(ctx,
		`INSERT INTO account_event_log(session_id,event_seq) VALUES(?,?)`, e.SessionID, e.EventSeq); err != nil {
		return 0, err
	}
	return e.EventSeq, nil
}

func (r *sqliteRepo) ListEventsAfter(ctx context.Context, sessionID string, afterSeq int64) ([]SessionEventRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT events.session_id,events.event_seq,event_log.cursor,events.event_type,events.envelope_json
		 FROM session_events AS events
		 JOIN account_event_log AS event_log
		   ON event_log.session_id=events.session_id AND event_log.event_seq=events.event_seq
		 WHERE events.session_id=? AND events.event_seq>? ORDER BY events.event_seq`, sessionID, afterSeq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionEventRow
	for rows.Next() {
		var e SessionEventRow
		if err := rows.Scan(&e.SessionID, &e.EventSeq, &e.AccountEventCursor, &e.EventType, &e.EnvelopeJSON); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// ListAccountEventsAfter 以账号 SSE cursor 的严格总序回放事件。查询从 sessions 推导账号范围，
// 不能相信调用方提供的 session_id 或把其他账号的 event log 暴露到流中。
func (r *sqliteRepo) ListAccountEventsAfter(ctx context.Context, accountID string, afterCursor int64) ([]SessionEventRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT events.session_id,events.event_seq,event_log.cursor,events.event_type,events.envelope_json
		 FROM account_event_log AS event_log
		 JOIN session_events AS events
		   ON events.session_id=event_log.session_id AND events.event_seq=event_log.event_seq
		 JOIN sessions AS session ON session.id=events.session_id
		 WHERE session.account_id=? AND event_log.cursor>?
		 ORDER BY event_log.cursor`, accountID, afterCursor)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionEventRow
	for rows.Next() {
		var e SessionEventRow
		if err := rows.Scan(&e.SessionID, &e.EventSeq, &e.AccountEventCursor, &e.EventType, &e.EnvelopeJSON); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) CreateCommand(ctx context.Context, c CommandRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO commands(
			id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,
			target_instance_id,target_terminal_id,ciphertext_json,readonly_response_envelope_json
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		c.ID, c.AccountID, c.SessionID, c.Kind, c.Status, c.ScopeHash, c.IdempotencyKey, c.LeaseEpoch,
		c.TargetInstanceID, c.TargetTerminalID, c.CiphertextJSON, c.ReadResponseEnvelopeJSON)
	return err
}

func scanCommand(row *sql.Row) (CommandRow, error) {
	var c CommandRow
	if err := row.Scan(
		&c.ID, &c.AccountID, &c.SessionID, &c.Kind, &c.Status, &c.ScopeHash, &c.IdempotencyKey, &c.LeaseEpoch,
		&c.TargetInstanceID, &c.TargetTerminalID, &c.CiphertextJSON, &c.ReadResponseEnvelopeJSON,
	); err != nil {
		return CommandRow{}, err
	}
	return c, nil
}

func (r *sqliteRepo) CommandByID(ctx context.Context, id string) (CommandRow, error) {
	return scanCommand(r.db.QueryRowContext(ctx,
		`SELECT id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,
			target_instance_id,target_terminal_id,ciphertext_json,readonly_response_envelope_json
		 FROM commands WHERE id=?`, id))
}

func (r *sqliteRepo) CommandByScopeKey(ctx context.Context, scopeHash, idempotencyKey string) (CommandRow, error) {
	return scanCommand(r.db.QueryRowContext(ctx,
		`SELECT id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,
			target_instance_id,target_terminal_id,ciphertext_json,readonly_response_envelope_json
		 FROM commands WHERE scope_hash=? AND idempotency_key=?`, scopeHash, idempotencyKey))
}

func (r *sqliteRepo) UpdateCommandStatus(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE commands SET status=? WHERE id=?`, status, id)
	return err
}

func (r *sqliteRepo) SetCommandReadResponse(ctx context.Context, id, envelopeJSON string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE commands SET readonly_response_envelope_json=? WHERE id=?`, envelopeJSON, id)
	return err
}

func (r *sqliteRepo) ListCommands(ctx context.Context, sessionID string) ([]CommandRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,
			target_instance_id,target_terminal_id,ciphertext_json,readonly_response_envelope_json
		 FROM commands WHERE session_id=? ORDER BY id`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CommandRow
	for rows.Next() {
		var c CommandRow
		if err := rows.Scan(
			&c.ID, &c.AccountID, &c.SessionID, &c.Kind, &c.Status, &c.ScopeHash, &c.IdempotencyKey, &c.LeaseEpoch,
			&c.TargetInstanceID, &c.TargetTerminalID, &c.CiphertextJSON, &c.ReadResponseEnvelopeJSON,
		); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// CreateDaemonDelivery 在同一 Terminal 范围内分配单调 delivery_seq。
// 调用者必须和 commands 写入处于同一事务，确保 command 可见时必有且仅有一条投递记录。
func (r *sqliteRepo) CreateDaemonDelivery(ctx context.Context, d DaemonDeliveryRow) (DaemonDeliveryRow, error) {
	if d.CreatedAtUnixMS == 0 {
		d.CreatedAtUnixMS = time.Now().UnixMilli()
	}
	if d.UpdatedAtUnixMS == 0 {
		d.UpdatedAtUnixMS = d.CreatedAtUnixMS
	}
	if err := r.db.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(delivery_seq), 0) + 1 FROM daemon_command_deliveries WHERE terminal_id=?`,
		d.TerminalID).Scan(&d.DeliverySeq); err != nil {
		return DaemonDeliveryRow{}, err
	}
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO daemon_command_deliveries(
			terminal_id,delivery_seq,command_id,ack_kind,result_status,error_code,created_at_unix_ms,updated_at_unix_ms
		) VALUES(?,?,?,?,?,?,?,?)`,
		d.TerminalID, d.DeliverySeq, d.CommandID, d.AckKind, d.ResultStatus, d.ErrorCode,
		d.CreatedAtUnixMS, d.UpdatedAtUnixMS)
	if err != nil {
		return DaemonDeliveryRow{}, err
	}
	return d, nil
}

func scanDaemonDelivery(row *sql.Row) (DaemonDeliveryRow, error) {
	var d DaemonDeliveryRow
	if err := row.Scan(
		&d.TerminalID, &d.DeliverySeq, &d.CommandID, &d.AckKind, &d.ResultStatus, &d.ErrorCode,
		&d.CreatedAtUnixMS, &d.UpdatedAtUnixMS,
	); err != nil {
		return DaemonDeliveryRow{}, err
	}
	return d, nil
}

func (r *sqliteRepo) DaemonDeliveryByCommandID(ctx context.Context, commandID string) (DaemonDeliveryRow, error) {
	return scanDaemonDelivery(r.db.QueryRowContext(ctx,
		`SELECT terminal_id,delivery_seq,command_id,ack_kind,result_status,error_code,created_at_unix_ms,updated_at_unix_ms
		 FROM daemon_command_deliveries WHERE command_id=?`, commandID))
}

func (r *sqliteRepo) ListDaemonDeliveriesAfter(ctx context.Context, terminalID string, afterDeliverySeq int64) ([]DaemonDeliveryRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT terminal_id,delivery_seq,command_id,ack_kind,result_status,error_code,created_at_unix_ms,updated_at_unix_ms
		 FROM daemon_command_deliveries
		 WHERE terminal_id=? AND delivery_seq>? ORDER BY delivery_seq`, terminalID, afterDeliverySeq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DaemonDeliveryRow{}
	for rows.Next() {
		var d DaemonDeliveryRow
		if err := rows.Scan(
			&d.TerminalID, &d.DeliverySeq, &d.CommandID, &d.AckKind, &d.ResultStatus, &d.ErrorCode,
			&d.CreatedAtUnixMS, &d.UpdatedAtUnixMS,
		); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) UpdateDaemonDelivery(ctx context.Context, d DaemonDeliveryRow) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE daemon_command_deliveries
		 SET ack_kind=?, result_status=?, error_code=?, updated_at_unix_ms=?
		 WHERE terminal_id=? AND command_id=?`,
		d.AckKind, d.ResultStatus, d.ErrorCode, d.UpdatedAtUnixMS, d.TerminalID, d.CommandID)
	return err
}

func (r *sqliteRepo) DaemonEventReceiptByID(ctx context.Context, eventID string) (DaemonEventReceiptRow, error) {
	var row DaemonEventReceiptRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT event_id,terminal_id,command_id,session_id,event_seq,created_at_unix_ms
		 FROM daemon_event_receipts WHERE event_id=?`, eventID).
		Scan(&row.EventID, &row.TerminalID, &row.CommandID, &row.SessionID, &row.EventSeq, &row.CreatedAtUnixMS); err != nil {
		return DaemonEventReceiptRow{}, err
	}
	return row, nil
}

func (r *sqliteRepo) CreateDaemonEventReceipt(ctx context.Context, receipt DaemonEventReceiptRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO daemon_event_receipts(event_id,terminal_id,command_id,session_id,event_seq,created_at_unix_ms)
		 VALUES(?,?,?,?,?,?)`,
		receipt.EventID, receipt.TerminalID, receipt.CommandID, receipt.SessionID, receipt.EventSeq, receipt.CreatedAtUnixMS)
	return err
}

func (r *sqliteRepo) SetDaemonEventReceiptSeq(ctx context.Context, eventID string, eventSeq int64) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE daemon_event_receipts SET event_seq=? WHERE event_id=?`, eventSeq, eventID)
	return err
}

// CreateDelegation 持久化父子会话图。调用方必须已经完成同一事务内的账号、workspace 与 lease 校验。
func (r *sqliteRepo) CreateDelegation(ctx context.Context, d DelegationRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO delegations(
			id,account_id,parent_session_id,child_session_id,target_provider,status,
			task_envelope_json,task_envelope_sha256,summary_envelope_json,summary_envelope_sha256,
			idempotency_key,parent_lease_epoch,created_by_device_id,created_at_unix_ms,updated_at_unix_ms
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		d.ID, d.AccountID, d.ParentSessionID, nullableString(d.ChildSessionID), d.TargetProvider, d.Status,
		d.TaskEnvelopeJSON, d.TaskEnvelopeSHA256, d.SummaryEnvelopeJSON, d.SummaryEnvelopeSHA256,
		d.IdempotencyKey, d.ParentLeaseEpoch, d.CreatedByDeviceID, d.CreatedAtUnixMS, d.UpdatedAtUnixMS)
	return err
}

func scanDelegation(row *sql.Row) (DelegationRow, error) {
	var d DelegationRow
	var child sql.NullString
	err := row.Scan(
		&d.ID, &d.AccountID, &d.ParentSessionID, &child, &d.TargetProvider, &d.Status,
		&d.TaskEnvelopeJSON, &d.TaskEnvelopeSHA256, &d.SummaryEnvelopeJSON, &d.SummaryEnvelopeSHA256,
		&d.IdempotencyKey, &d.ParentLeaseEpoch, &d.CreatedByDeviceID, &d.CreatedAtUnixMS, &d.UpdatedAtUnixMS,
	)
	if err != nil {
		return DelegationRow{}, err
	}
	d.ChildSessionID = child.String
	return d, nil
}

const delegationColumns = `id,account_id,parent_session_id,child_session_id,target_provider,status,
	task_envelope_json,task_envelope_sha256,summary_envelope_json,summary_envelope_sha256,
	idempotency_key,parent_lease_epoch,created_by_device_id,created_at_unix_ms,updated_at_unix_ms`

// DelegationByID 供决策与子会话状态监督读取；调用方仍须复核 account_id。
func (r *sqliteRepo) DelegationByID(ctx context.Context, id string) (DelegationRow, error) {
	return scanDelegation(r.db.QueryRowContext(ctx,
		`SELECT `+delegationColumns+` FROM delegations WHERE id=?`, id))
}

// DelegationByParentKey 实现创建请求的幂等重放，避免产生重复 child Session。
func (r *sqliteRepo) DelegationByParentKey(ctx context.Context, parentSessionID, idempotencyKey string) (DelegationRow, error) {
	return scanDelegation(r.db.QueryRowContext(ctx,
		`SELECT `+delegationColumns+` FROM delegations WHERE parent_session_id=? AND idempotency_key=?`,
		parentSessionID, idempotencyKey))
}

func (r *sqliteRepo) ListDelegationsByParent(ctx context.Context, parentSessionID string) ([]DelegationRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+delegationColumns+` FROM delegations WHERE parent_session_id=? ORDER BY created_at_unix_ms ASC, id ASC`,
		parentSessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DelegationRow
	for rows.Next() {
		var d DelegationRow
		var child sql.NullString
		if err := rows.Scan(
			&d.ID, &d.AccountID, &d.ParentSessionID, &child, &d.TargetProvider, &d.Status,
			&d.TaskEnvelopeJSON, &d.TaskEnvelopeSHA256, &d.SummaryEnvelopeJSON, &d.SummaryEnvelopeSHA256,
			&d.IdempotencyKey, &d.ParentLeaseEpoch, &d.CreatedByDeviceID, &d.CreatedAtUnixMS, &d.UpdatedAtUnixMS,
		); err != nil {
			return nil, err
		}
		d.ChildSessionID = child.String
		out = append(out, d)
	}
	return out, rows.Err()
}

// UpdateDelegation 只允许改变状态、child 关联和更新时间，密文任务书与摘要在创建后不可被 Relay 改写。
func (r *sqliteRepo) UpdateDelegation(ctx context.Context, id, status, childSessionID string, updatedAtUnixMS int64) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE delegations SET status=?, child_session_id=?, updated_at_unix_ms=? WHERE id=?`,
		status, nullableString(childSessionID), updatedAtUnixMS, id)
	return err
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

func (r *sqliteRepo) CreateAttachment(ctx context.Context, a AttachmentRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO attachments(id,session_id,account_id,mime_type,byte_size,compression,total_chunks,metadata_ciphertext,created_by_device_id,lease_epoch,status,complete_idempotency_key)
		 VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		a.ID, a.SessionID, a.AccountID, a.MimeType, a.ByteSize, a.Compression,
		a.TotalChunks, a.MetadataCiphertext, a.CreatedByDeviceID, a.LeaseEpoch,
		a.Status, nullableString(a.CompleteIdempotencyKey))
	return err
}

func (r *sqliteRepo) AttachmentByID(ctx context.Context, id string) (AttachmentRow, error) {
	var a AttachmentRow
	var complete sql.NullString
	err := r.db.QueryRowContext(ctx,
		`SELECT id,session_id,account_id,mime_type,byte_size,compression,total_chunks,metadata_ciphertext,created_by_device_id,lease_epoch,status,complete_idempotency_key
		 FROM attachments WHERE id=?`, id).
		Scan(&a.ID, &a.SessionID, &a.AccountID, &a.MimeType, &a.ByteSize,
			&a.Compression, &a.TotalChunks, &a.MetadataCiphertext, &a.CreatedByDeviceID,
			&a.LeaseEpoch, &a.Status, &complete)
	if err != nil {
		return AttachmentRow{}, err
	}
	a.CompleteIdempotencyKey = complete.String
	return a, nil
}

func (r *sqliteRepo) CreateAttachmentChunk(ctx context.Context, c AttachmentChunkRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO attachment_chunks(attachment_id,chunk_index,idempotency_key,ciphertext,ciphertext_sha256)
		 VALUES(?,?,?,?,?)`,
		c.AttachmentID, c.ChunkIndex, c.IdempotencyKey, c.Ciphertext, c.CiphertextSHA256)
	return err
}

func (r *sqliteRepo) AttachmentChunkByIndex(ctx context.Context, attachmentID string, chunkIndex int) (AttachmentChunkRow, error) {
	return scanAttachmentChunk(r.db.QueryRowContext(ctx,
		`SELECT attachment_id,chunk_index,idempotency_key,ciphertext,ciphertext_sha256
		 FROM attachment_chunks WHERE attachment_id=? AND chunk_index=?`, attachmentID, chunkIndex))
}

func (r *sqliteRepo) AttachmentChunkByIdempotency(ctx context.Context, attachmentID, idempotencyKey string) (AttachmentChunkRow, error) {
	return scanAttachmentChunk(r.db.QueryRowContext(ctx,
		`SELECT attachment_id,chunk_index,idempotency_key,ciphertext,ciphertext_sha256
		 FROM attachment_chunks WHERE attachment_id=? AND idempotency_key=?`, attachmentID, idempotencyKey))
}

func scanAttachmentChunk(row *sql.Row) (AttachmentChunkRow, error) {
	var c AttachmentChunkRow
	if err := row.Scan(&c.AttachmentID, &c.ChunkIndex, &c.IdempotencyKey, &c.Ciphertext, &c.CiphertextSHA256); err != nil {
		return AttachmentChunkRow{}, err
	}
	return c, nil
}

func (r *sqliteRepo) CountAttachmentChunks(ctx context.Context, attachmentID string) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM attachment_chunks WHERE attachment_id=?`, attachmentID).Scan(&count)
	return count, err
}

func (r *sqliteRepo) CompleteAttachment(ctx context.Context, attachmentID, idempotencyKey string) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE attachments
		 SET status='completed', complete_idempotency_key=?
		 WHERE id=? AND status='pending'`, idempotencyKey, attachmentID)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
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

// UpsertUsageEvent 以 usage_key_hash 唯一约束写入 usage 事件。重复 key 返回
// (false, nil)，调用方按 ADR-010 去重语义返回同一 canonical receipt。
func (r *sqliteRepo) UpsertUsageEvent(ctx context.Context, u UsageEventRow) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO usage_events
			(usage_key_hash, account_id, terminal_id, provider, utc_day,
			 input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
			 schema_version, created_at_unix_ms)
		 VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
		u.UsageKeyHash, u.AccountID, u.TerminalID, u.Provider, u.UTCDay,
		u.InputTokens, u.OutputTokens, u.CacheReadTokens, u.CacheWriteTokens,
		u.SchemaVersion, u.CreatedAtUnixMS)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// AggregateUsage 按账号在 [startDay, endDay] UTC 日桶内聚合 usage 事件。
// 只返回白名单整数计数；查询只按账号 scope，客户端不能读取其它账号或单条事件。
func (r *sqliteRepo) AggregateUsage(ctx context.Context, accountID, startDay, endDay string) ([]UsageDayAggregateRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT provider, utc_day,
		        SUM(input_tokens), SUM(output_tokens),
		        SUM(cache_read_tokens), SUM(cache_write_tokens)
		 FROM usage_events
		 WHERE account_id = ? AND utc_day >= ? AND utc_day <= ?
		 GROUP BY provider, utc_day
		 ORDER BY utc_day, provider`,
		accountID, startDay, endDay)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []UsageDayAggregateRow
	for rows.Next() {
		var row UsageDayAggregateRow
		if err := rows.Scan(&row.Provider, &row.UTCDay, &row.InputTokens,
			&row.OutputTokens, &row.CacheReadTokens, &row.CacheWriteTokens); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
}
