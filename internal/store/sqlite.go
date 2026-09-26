package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/packages/protocol"
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

func (r *sqliteRepo) RecoveryByCodeHash(ctx context.Context, codeHash string) (RecoveryRow, error) {
	var rc RecoveryRow
	var locked int64
	var created int64
	if err := r.db.QueryRowContext(ctx,
		`SELECT account_id,code_hash,failed_attempts,locked_until,created_at FROM recovery_codes WHERE code_hash=?`, codeHash).
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
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms,
			presence_revision,presence_projected_state,provider_facts_json
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		t.ID, t.DeviceID, t.AccountID, t.Hostname, t.Platform, t.Status, t.LastSeenUnixMS,
		t.ProtocolVersion, t.DaemonVersion, t.CapabilitiesJSON, t.LastHeartbeatUnixMS,
		t.PresenceRevision, t.PresenceProjectedState, t.ProviderFactsJSON)
	return err
}

// terminalColumns 是 Terminal 行读取的统一列清单；新增 additive 列时必须同步
// scanTerminal 与 ListTerminals 的扫描顺序。
const terminalColumns = `id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms,
			presence_revision,presence_projected_state,provider_facts_json`

func (r *sqliteRepo) TerminalByID(ctx context.Context, id string) (TerminalRow, error) {
	return scanTerminal(r.db.QueryRowContext(ctx,
		`SELECT `+terminalColumns+` FROM terminals WHERE id=?`, id))
}

func (r *sqliteRepo) TerminalByDeviceID(ctx context.Context, deviceID string) (TerminalRow, error) {
	return scanTerminal(r.db.QueryRowContext(ctx,
		`SELECT `+terminalColumns+` FROM terminals WHERE device_id=?`, deviceID))
}

func scanTerminal(row *sql.Row) (TerminalRow, error) {
	var t TerminalRow
	if err := row.Scan(
		&t.ID, &t.DeviceID, &t.AccountID, &t.Hostname, &t.Platform, &t.Status, &t.LastSeenUnixMS,
		&t.ProtocolVersion, &t.DaemonVersion, &t.CapabilitiesJSON, &t.LastHeartbeatUnixMS,
		&t.PresenceRevision, &t.PresenceProjectedState, &t.ProviderFactsJSON,
	); err != nil {
		return TerminalRow{}, err
	}
	return t, nil
}

func (r *sqliteRepo) ListTerminals(ctx context.Context, accountID string) ([]TerminalRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+terminalColumns+` FROM terminals WHERE account_id=? ORDER BY last_seen_unix_ms DESC`, accountID)
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
			&t.PresenceRevision, &t.PresenceProjectedState, &t.ProviderFactsJSON,
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

// TouchTerminalPresence 幂等推进 Terminal 活性（v0.9.1 C1/V091-02）。单事务内
// 「读旧值 -> 比较 -> 条件更新」，避免并发心跳互相覆盖 revision：
//   - last_heartbeat_unix_ms 只前进不倒退（乱序/更旧的心跳不能把活性拉回过去）；
//   - prevAvailability 是调用方（领域层）以服务端时钟对「本心跳到达前状态」的
//     时间投影：与 nextState 不同即为一次真实 presence 转换（如恢复回 online），
//     presence_revision 单调 +1 并返回 changed=true；无真实状态变化的重复
//     heartbeat 不制造 revision（V091-02）。prev 为空串视为与 nextState 相同
//     （hello 首拍/无先前事实），不制造变化。
//   - status 列保持 legacy 语义：有效活性一律置回 online；reaper 的持久 offline
//     由恢复路径的自然覆盖翻转。
//
// 返回最新 revision 与是否发生投影变化，供 presence invalidation 按 revision
// 去重、单次发布（计划 §3.3）。
// providerFactsJSON 为 nil 时表示本次心跳未携带 Provider 事实（旧 Daemon 或未变更），
// 保持既有快照不动；非 nil 时整体替换（含"执行侧现在报告不可用"的空事实），
// 这样环境变化后一个心跳周期内即可纠正 Relay 的对外表述。
func (r *sqliteRepo) TouchTerminalPresence(ctx context.Context, terminalID string, nowUnixMS int64, prevAvailability string, nextState string, providerFactsJSON *string) (int64, bool, error) {
	var revision int64
	var changed bool
	err := r.WithTx(ctx, func(ctx context.Context, tx Repository) error {
		row, err := tx.TerminalByID(ctx, terminalID)
		if err != nil {
			return err
		}
		changed = prevAvailability != "" && prevAvailability != nextState
		revision = row.PresenceRevision
		if changed {
			revision++
		}
		lastHeartbeat := row.LastHeartbeatUnixMS
		if nowUnixMS > lastHeartbeat {
			lastHeartbeat = nowUnixMS
		}
		// WithTx 在本包内只构造 *sqliteRepo（见 WithTx），此处断言取回事务级执行器。
		exec, ok := tx.(*sqliteRepo)
		if !ok {
			return errors.New("terminal presence touch: transaction repository type mismatch")
		}
		if providerFactsJSON != nil {
			_, err = exec.db.ExecContext(ctx,
				`UPDATE terminals SET status='online', last_seen_unix_ms=?, last_heartbeat_unix_ms=?,
				 presence_revision=?, presence_projected_state=?, provider_facts_json=? WHERE id=?`,
				nowUnixMS, lastHeartbeat, revision, nextState, *providerFactsJSON, terminalID)
			return err
		}
		_, err = exec.db.ExecContext(ctx,
			`UPDATE terminals SET status='online', last_seen_unix_ms=?, last_heartbeat_unix_ms=?,
			 presence_revision=?, presence_projected_state=? WHERE id=?`,
			nowUnixMS, lastHeartbeat, revision, nextState, terminalID)
		return err
	})
	return revision, changed, err
}

// ListPresenceSweepCandidates 列出「需要过期投影转换」的 Terminal（v0.9.1 P1 reaper）。
// 只返回会发生真实转换的行，避免已转换行反复占用有界批次饿死其他 Terminal：
//   - 持久投影为 online（空串按 legacy status 初始化）且心跳已退出 suspect 窗
//     （last_heartbeat < suspectBeforeUnixMS）-> 需要 online -> unknown/offline；
//   - 持久投影为 unknown 且心跳已过 offline deadline（last_heartbeat <
//     deadlineBeforeUnixMS）-> 需要 unknown -> offline。
//
// 按 last_heartbeat 升序返回最多 limit 条；超出部分留给下一 tick 自愈
// （计划 §3.3：丢唤醒只损失延迟，不损失事实）。
func (r *sqliteRepo) ListPresenceSweepCandidates(ctx context.Context, suspectBeforeUnixMS, deadlineBeforeUnixMS int64, limit int) ([]TerminalRow, error) {
	if limit <= 0 {
		limit = 1
	}
	effectiveProjection := `COALESCE(NULLIF(presence_projected_state,''), CASE WHEN status='online' THEN 'online' ELSE 'unknown' END)`
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+terminalColumns+` FROM terminals
		 WHERE last_heartbeat_unix_ms > 0 AND (
		   (`+effectiveProjection+` = 'online' AND last_heartbeat_unix_ms < ?)
		OR (`+effectiveProjection+` = 'unknown' AND last_heartbeat_unix_ms < ?)
		 )
		 ORDER BY last_heartbeat_unix_ms ASC LIMIT ?`,
		suspectBeforeUnixMS, deadlineBeforeUnixMS, limit)
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
			&t.PresenceRevision, &t.PresenceProjectedState, &t.ProviderFactsJSON,
		); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// PersistPresenceProjection 原子推进持久投影（v0.9.1 P1 reaper 专用）。
// 与 TouchTerminalPresence 的区别：不推进 last_heartbeat、不把 status 置回 online——
// reaper 没有「新活性事实」，只把过期投影落库。
//   - current 持久投影为空串（升级前存量行）时按 legacy status 列初始化；
//   - 与 nextState 相同则为 no-op（changed=false），不重复制造 revision；
//   - setStatus 非空时同步 legacy status 列（offline 持久化写 'offline'；
//     unknown 不降级 legacy status，避免旧客户端把「事实不可确认」误读为离线）。
func (r *sqliteRepo) PersistPresenceProjection(ctx context.Context, terminalID string, nextState string, setStatus string) (int64, bool, error) {
	var revision int64
	var changed bool
	err := r.WithTx(ctx, func(ctx context.Context, tx Repository) error {
		row, err := tx.TerminalByID(ctx, terminalID)
		if err != nil {
			return err
		}
		current := row.PresenceProjectedState
		if current == "" {
			if strings.EqualFold(row.Status, "online") {
				current = "online"
			} else {
				current = "unknown"
			}
		}
		changed = current != nextState
		revision = row.PresenceRevision
		if !changed {
			return nil
		}
		revision++
		// WithTx 在本包内只构造 *sqliteRepo（见 WithTx），此处断言取回事务级执行器。
		exec, ok := tx.(*sqliteRepo)
		if !ok {
			return errors.New("persist presence projection: transaction repository type mismatch")
		}
		_, err = exec.db.ExecContext(ctx,
			`UPDATE terminals SET presence_revision=?, presence_projected_state=? WHERE id=?`,
			revision, nextState, terminalID)
		if err != nil {
			return err
		}
		if setStatus != "" {
			_, err = exec.db.ExecContext(ctx,
				`UPDATE terminals SET status=? WHERE id=?`, setStatus, terminalID)
		}
		return err
	})
	return revision, changed, err
}

// UpsertDaemonTerminal 以 device_id 作为 Terminal 身份锚点。Daemon 只能声明自身版本、
// capabilities 与脱敏主机信息，不能借此覆盖账号、设备或 Workspace 归属。
// presence_revision / presence_projected_state 由调用方（Hello 投影变化检测）给出，
// 本语句不自行计算，保证 revision 语义集中在领域层。
func (r *sqliteRepo) UpsertDaemonTerminal(ctx context.Context, t TerminalRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO terminals(
			id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms,
			presence_revision,presence_projected_state,provider_facts_json
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(device_id) DO UPDATE SET
			hostname=excluded.hostname,
			platform=excluded.platform,
			status=excluded.status,
			last_seen_unix_ms=excluded.last_seen_unix_ms,
			protocol_version=excluded.protocol_version,
			daemon_version=excluded.daemon_version,
			capabilities_json=excluded.capabilities_json,
			last_heartbeat_unix_ms=excluded.last_heartbeat_unix_ms,
			presence_revision=excluded.presence_revision,
			presence_projected_state=excluded.presence_projected_state,
			provider_facts_json=excluded.provider_facts_json`,
		t.ID, t.DeviceID, t.AccountID, t.Hostname, t.Platform, t.Status, t.LastSeenUnixMS,
		t.ProtocolVersion, t.DaemonVersion, t.CapabilitiesJSON, t.LastHeartbeatUnixMS,
		t.PresenceRevision, t.PresenceProjectedState, t.ProviderFactsJSON)
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
	// 旧调用方没有 origin 时保守写成 managed，避免历史 Workspace 被误当作 DSH。
	w.Origin = workspaceOriginOrManaged(w.Origin)
	w.DisplayName = strings.TrimSpace(w.DisplayName)
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO workspaces(id,project_id,terminal_id,canonical_root,branch,status,origin,display_name) VALUES(?,?,?,?,?,?,?,?)`,
		w.ID, w.ProjectID, w.TerminalID, w.CanonicalRoot, w.Branch, w.Status, w.Origin, w.DisplayName)
	return err
}

// UpdateWorkspaceDSHMetadata 只更新经 Daemon 回执确认的公开投影；根路径与 Terminal 归属不变。
func (r *sqliteRepo) UpdateWorkspaceDSHMetadata(ctx context.Context, id, displayName string) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE workspaces SET origin=?,display_name=? WHERE id=?`,
		WorkspaceOriginDSH, strings.TrimSpace(displayName), id)
	return err
}

func (r *sqliteRepo) WorkspaceByID(ctx context.Context, id string) (WorkspaceRow, error) {
	var w WorkspaceRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,project_id,terminal_id,canonical_root,branch,status,origin,display_name FROM workspaces WHERE id=?`, id).
		Scan(&w.ID, &w.ProjectID, &w.TerminalID, &w.CanonicalRoot, &w.Branch, &w.Status, &w.Origin, &w.DisplayName); err != nil {
		return WorkspaceRow{}, err
	}
	return w, nil
}

func (r *sqliteRepo) ListWorkspaces(ctx context.Context, accountID string) ([]WorkspaceRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT w.id,w.project_id,w.terminal_id,w.canonical_root,w.branch,w.status,w.origin,w.display_name
		 FROM workspaces w JOIN projects p ON p.id=w.project_id
		 WHERE p.account_id=? ORDER BY w.id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WorkspaceRow
	for rows.Next() {
		var w WorkspaceRow
		if err := rows.Scan(&w.ID, &w.ProjectID, &w.TerminalID, &w.CanonicalRoot, &w.Branch, &w.Status, &w.Origin, &w.DisplayName); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

func workspaceOriginOrManaged(origin string) string {
	if strings.TrimSpace(origin) == WorkspaceOriginDSH {
		return WorkspaceOriginDSH
	}
	return WorkspaceOriginManaged
}

func (r *sqliteRepo) CreateSession(ctx context.Context, s SessionRow) error {
	if s.Origin == "" {
		s.Origin = SessionOriginManaged
	}
	if s.Visibility == "" {
		s.Visibility = SessionVisibilityDefault
	}
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO sessions(
			id,workspace_id,account_id,status,provider,model,last_seq,current_instance_id,
			parent_session_id,forked_from_message_id,fork_idempotency_key,display_name,origin,visibility
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		s.ID, s.WorkspaceID, s.AccountID, s.Status, s.Provider, s.Model, s.LastSeq, s.CurrentInstanceID,
		s.ParentSessionID, s.ForkedFromMessageID, s.ForkIdempotencyKey, s.DisplayName, s.Origin, s.Visibility)
	return err
}

func (r *sqliteRepo) SessionByID(ctx context.Context, id string) (SessionRow, error) {
	var s SessionRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,workspace_id,account_id,status,provider,model,last_seq,current_instance_id,
		        parent_session_id,forked_from_message_id,fork_idempotency_key,archived_at_unix_ms,
		        last_activity_at_unix_ms,permission_mode,available_permission_modes,agent_preset_id,content_dek_id,display_name,
			COALESCE(NULLIF(origin,''),'managed'),COALESCE(NULLIF(visibility,''),'default')
		   FROM sessions WHERE id=?`, id).
		Scan(&s.ID, &s.WorkspaceID, &s.AccountID, &s.Status, &s.Provider, &s.Model, &s.LastSeq, &s.CurrentInstanceID,
			&s.ParentSessionID, &s.ForkedFromMessageID, &s.ForkIdempotencyKey, &s.ArchivedAtUnixMS,
			&s.LastActivityAtUnixMS, &s.PermissionMode, &s.AvailablePermissionModesJSON, &s.AgentPresetID, &s.ContentDEKID, &s.DisplayName, &s.Origin, &s.Visibility); err != nil {
		return SessionRow{}, err
	}
	return s, nil
}

func (r *sqliteRepo) ListSessions(ctx context.Context, accountID string) ([]SessionRow, error) {
	return r.listSessions(ctx, accountID, false, SessionVisibilityDefault)
}

func (r *sqliteRepo) ListHistorySessions(ctx context.Context, accountID string) ([]SessionRow, error) {
	return r.listSessions(ctx, accountID, false, SessionVisibilityHistory)
}

func (r *sqliteRepo) ListArchivedSessions(ctx context.Context, accountID string) ([]SessionRow, error) {
	return r.listSessions(ctx, accountID, true, "")
}

func (r *sqliteRepo) ManageSession(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET visibility='default' WHERE id=? AND visibility='history'`, id)
	return err
}

func (r *sqliteRepo) UpdateSessionImportProgress(ctx context.Context, id string, activityAtUnixMS int64) error {
	// 导入只修正事件游标并推进真实活动时间；不能用导入时刻把旧历史顶到列表最前。
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET
		last_seq=(SELECT COALESCE(MAX(event_seq),0) FROM session_events WHERE session_id=sessions.id),
		last_activity_at_unix_ms=MAX(last_activity_at_unix_ms,?) WHERE id=?`, activityAtUnixMS, id)
	return err
}

func (r *sqliteRepo) ListRunningSessions(ctx context.Context, accountID string) ([]SessionRow, error) {
	const query = `SELECT id,workspace_id,account_id,status,provider,model,last_seq,current_instance_id,
		parent_session_id,forked_from_message_id,fork_idempotency_key,archived_at_unix_ms,last_activity_at_unix_ms,
		permission_mode,available_permission_modes,agent_preset_id,content_dek_id,display_name,
			COALESCE(NULLIF(origin,''),'managed'),COALESCE(NULLIF(visibility,''),'default')
		FROM sessions WHERE account_id=? AND status='running' ORDER BY last_activity_at_unix_ms ASC, id ASC`
	return r.scanSessions(ctx, query, accountID)
}

func (r *sqliteRepo) listSessions(ctx context.Context, accountID string, archived bool, visibility string) ([]SessionRow, error) {
	const selectSessions = `SELECT id,workspace_id,account_id,status,provider,model,last_seq,current_instance_id,
		        parent_session_id,forked_from_message_id,fork_idempotency_key,archived_at_unix_ms,
		        last_activity_at_unix_ms,permission_mode,available_permission_modes,agent_preset_id,content_dek_id,display_name,
			COALESCE(NULLIF(origin,''),'managed'),COALESCE(NULLIF(visibility,''),'default')
		 FROM sessions`
	var query string
	if archived {
		query = selectSessions + ` WHERE account_id=? AND archived_at_unix_ms<>0 ORDER BY last_seq DESC`
	} else {
		// 默认列表按真实活动时间倒序：最后事件/状态写入最近者在前。last_seq 是
		// 会话内局部序号，跨会话不可比；last_activity=0（旧数据未知）自然沉底。
		query = selectSessions + ` WHERE account_id=? AND archived_at_unix_ms=0
			AND COALESCE(NULLIF(visibility,''),'default')=? ORDER BY last_activity_at_unix_ms DESC, last_seq DESC`
		return r.scanSessions(ctx, query, accountID, visibility)
	}
	return r.scanSessions(ctx, query, accountID)
}

func (r *sqliteRepo) scanSessions(ctx context.Context, query string, args ...any) ([]SessionRow, error) {
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionRow
	for rows.Next() {
		var s SessionRow
		if err := rows.Scan(&s.ID, &s.WorkspaceID, &s.AccountID, &s.Status, &s.Provider, &s.Model, &s.LastSeq, &s.CurrentInstanceID,
			&s.ParentSessionID, &s.ForkedFromMessageID, &s.ForkIdempotencyKey, &s.ArchivedAtUnixMS,
			&s.LastActivityAtUnixMS, &s.PermissionMode, &s.AvailablePermissionModesJSON, &s.AgentPresetID, &s.ContentDEKID, &s.DisplayName, &s.Origin, &s.Visibility); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) ArchiveSession(ctx context.Context, id string, archivedAtUnixMS int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET archived_at_unix_ms=? WHERE id=?`, archivedAtUnixMS, id)
	return err
}

func (r *sqliteRepo) UnarchiveSession(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET archived_at_unix_ms=0 WHERE id=?`, id)
	return err
}

func (r *sqliteRepo) SetSessionStatus(ctx context.Context, id, status string) error {
	return r.SetSessionStatusAt(ctx, id, status, time.Now().UnixMilli())
}

func (r *sqliteRepo) SetSessionStatusAt(ctx context.Context, id, status string, activityAtUnixMS int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET status=?, last_activity_at_unix_ms=? WHERE id=?`, status, activityAtUnixMS, id)
	return err
}

// SetSessionDisplayName 只更新展示标题，不触碰状态与活跃时间（v0.9.5 P1：
// 导入增量同步把 DSH 侧的新标题带给已存在会话）。
func (r *sqliteRepo) SetSessionDisplayName(ctx context.Context, id, displayName string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET display_name=? WHERE id=?`, displayName, id)
	return err
}

// SetSessionStatusKeepActivity 只翻转状态，保留 last_activity_at_unix_ms。
// 确定性对账/启动清扫用：历史收口不制造虚假的“刚刚活跃”，最后消息时间
// 继续反映真实的最后一次事件/命令写入。
func (r *sqliteRepo) SetSessionStatusKeepActivity(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET status=? WHERE id=?`, status, id)
	return err
}

func (r *sqliteRepo) SetSessionLastSeq(ctx context.Context, id string, lastSeq int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET last_seq=?, last_activity_at_unix_ms=? WHERE id=?`, lastSeq, time.Now().UnixMilli(), id)
	return err
}

func (r *sqliteRepo) SetSessionInstance(ctx context.Context, id, instanceID string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET current_instance_id=? WHERE id=?`, instanceID, id)
	return err
}

func (r *sqliteRepo) SetSessionModel(ctx context.Context, id, model string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET model=? WHERE id=?`, model, id)
	return err
}

// SetSessionPermissionModes 保存会话级 permission mode 快照（v0.8.5 §3.4）。
// modeID 为空字符串时保留原值不清空；modesJSON 为空时写 []. 这是 Daemon 上行
// 同步的结果，Relay 不解释 mode 语义，只做账号内会话的安全快照存储。
func (r *sqliteRepo) SetSessionPermissionModes(ctx context.Context, id, modeID, modesJSON string) error {
	if modesJSON == "" {
		modesJSON = "[]"
	}
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET permission_mode=?, available_permission_modes=? WHERE id=?`, modeID, modesJSON, id)
	return err
}

// SetSessionContentDEK 记录会话内容 DEK 的 opaque id（v0.8.5 §3.2 / ADR-016）。
// 空字符串清除（无 DEK 会话 fail-closed）；wrapped blob 由 device_key_wraps 承载。
func (r *sqliteRepo) SetSessionContentDEK(ctx context.Context, id, dekID string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET content_dek_id=? WHERE id=?`, dekID, id)
	return err
}

// SetSessionAgentPreset 保存会话 joined 的 DSH agent preset id（v0.8.5 §3.8）。
// 空字符串表示会话未 joined 预设（清空快照）。
func (r *sqliteRepo) SetSessionAgentPreset(ctx context.Context, id, presetID string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE sessions SET agent_preset_id=? WHERE id=?`, presetID, id)
	return err
}

func (r *sqliteRepo) SessionByParentForkKey(ctx context.Context, parentSessionID, idempotencyKey string) (SessionRow, error) {
	var s SessionRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,workspace_id,account_id,status,provider,model,last_seq,current_instance_id,
		        parent_session_id,forked_from_message_id,fork_idempotency_key,archived_at_unix_ms,
		        last_activity_at_unix_ms,permission_mode,available_permission_modes,agent_preset_id,content_dek_id,display_name,
			COALESCE(NULLIF(origin,''),'managed'),COALESCE(NULLIF(visibility,''),'default')
		   FROM sessions WHERE parent_session_id=? AND fork_idempotency_key=?`,
		parentSessionID, idempotencyKey).
		Scan(&s.ID, &s.WorkspaceID, &s.AccountID, &s.Status, &s.Provider, &s.Model, &s.LastSeq, &s.CurrentInstanceID,
			&s.ParentSessionID, &s.ForkedFromMessageID, &s.ForkIdempotencyKey, &s.ArchivedAtUnixMS,
			&s.LastActivityAtUnixMS, &s.PermissionMode, &s.AvailablePermissionModesJSON, &s.AgentPresetID, &s.ContentDEKID, &s.DisplayName, &s.Origin, &s.Visibility); err != nil {
		return SessionRow{}, err
	}
	return s, nil
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
		`INSERT INTO session_events(session_id,event_seq,event_type,terminal_status,envelope_json,created_at_unix_ms) VALUES(?,?,?,?,?,?)`,
		e.SessionID, e.EventSeq, e.EventType, e.TerminalStatus, e.EnvelopeJSON, e.CreatedAtUnixMS); err != nil {
		return 0, err
	}
	if _, err := r.db.ExecContext(ctx,
		`INSERT INTO account_event_log(session_id,event_seq) VALUES(?,?)`, e.SessionID, e.EventSeq); err != nil {
		return 0, err
	}
	return e.EventSeq, nil
}

func (r *sqliteRepo) ListEventsAfter(ctx context.Context, sessionID string, afterSeq int64) ([]SessionEventRow, error) {
	// V094-06：LEFT JOIN daemon_event_receipts 回投事件的关联命令 ID。
	// receipt 与事件同 session 且 event_seq 唯一（appendDaemonEventInTx 单点写入），
	// 无 receipt 的旧事件/非命令事件保持空串，不放大可见面（命令 ID 无正文语义）。
	rows, err := r.db.QueryContext(ctx,
		`SELECT events.session_id,events.event_seq,event_log.cursor,events.event_type,events.terminal_status,events.envelope_json,events.created_at_unix_ms,COALESCE(receipt.command_id,'')
		 FROM session_events AS events
		 JOIN account_event_log AS event_log
		   ON event_log.session_id=events.session_id AND event_log.event_seq=events.event_seq
		 LEFT JOIN daemon_event_receipts AS receipt
		   ON receipt.session_id=events.session_id AND receipt.event_seq=events.event_seq
		 WHERE events.session_id=? AND events.event_seq>? ORDER BY events.event_seq`, sessionID, afterSeq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionEventRow
	for rows.Next() {
		var e SessionEventRow
		if err := rows.Scan(&e.SessionID, &e.EventSeq, &e.AccountEventCursor, &e.EventType, &e.TerminalStatus, &e.EnvelopeJSON, &e.CreatedAtUnixMS, &e.CommandID); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// ListEventsBefore 返回 event_seq < beforeSeq 的最近 limit 条事件（v0.9.5 P2
// 历史向前翻页）：SQL 侧 DESC LIMIT 取最新一页，再反转为升序交付，调用方按
// 既有升序 timeline 合并。投影口径与 ListEventsAfter 相同（receipt 关联回投）。
func (r *sqliteRepo) ListEventsBefore(ctx context.Context, sessionID string, beforeSeq int64, limit int) ([]SessionEventRow, error) {
	if limit <= 0 {
		return nil, fmt.Errorf("limit 必须为正整数")
	}
	rows, err := r.db.QueryContext(ctx,
		`SELECT events.session_id,events.event_seq,event_log.cursor,events.event_type,events.terminal_status,events.envelope_json,events.created_at_unix_ms,COALESCE(receipt.command_id,'')
		 FROM session_events AS events
		 JOIN account_event_log AS event_log
		   ON event_log.session_id=events.session_id AND event_log.event_seq=events.event_seq
		 LEFT JOIN daemon_event_receipts AS receipt
		   ON receipt.session_id=events.session_id AND receipt.event_seq=events.event_seq
		 WHERE events.session_id=? AND events.event_seq<? ORDER BY events.event_seq DESC LIMIT ?`, sessionID, beforeSeq, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionEventRow
	for rows.Next() {
		var e SessionEventRow
		if err := rows.Scan(&e.SessionID, &e.EventSeq, &e.AccountEventCursor, &e.EventType, &e.TerminalStatus, &e.EnvelopeJSON, &e.CreatedAtUnixMS, &e.CommandID); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// DESC 取页后反转为升序，调用方按时间正序合并。
	for left, right := 0, len(out)-1; left < right; left, right = left+1, right-1 {
		out[left], out[right] = out[right], out[left]
	}
	return out, nil
}

// CountSessionEvents 返回会话事件总数（v0.9.5 P2：快照分页 has_more 判定）。
func (r *sqliteRepo) CountSessionEvents(ctx context.Context, sessionID string) (int64, error) {
	var total int64
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM session_events WHERE session_id=?`, sessionID).Scan(&total)
	return total, err
}

// ListAccountEventsAfter 以账号 SSE cursor 的严格总序回放事件。查询从 sessions 推导账号范围，
// 不能相信调用方提供的 session_id 或把其他账号的 event log 暴露到流中。
func (r *sqliteRepo) ListAccountEventsAfter(ctx context.Context, accountID string, afterCursor int64) ([]SessionEventRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT events.session_id,events.event_seq,event_log.cursor,events.event_type,events.terminal_status,events.envelope_json,events.created_at_unix_ms
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
		if err := rows.Scan(&e.SessionID, &e.EventSeq, &e.AccountEventCursor, &e.EventType, &e.TerminalStatus, &e.EnvelopeJSON, &e.CreatedAtUnixMS); err != nil {
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

func (r *sqliteRepo) ReleaseCommandIdempotencyKey(ctx context.Context, id, newKey string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE commands SET idempotency_key=? WHERE id=?`, newKey, id)
	return err
}

// UpdateCommandStatus 直接改写命令状态；状态机合法性由领域层校验。
func (r *sqliteRepo) UpdateCommandStatus(ctx context.Context, id, status string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE commands SET status=? WHERE id=?`, status, id)
	return err
}

// ExpireStaleCommands 在 lease epoch 递增的同一事务内，把旧 epoch 下仍未终态的命令
// 收敛为 expired。只有 accepted/running 会被过期；已终态行保持历史不变。
func (r *sqliteRepo) ExpireStaleCommands(ctx context.Context, sessionID string, belowEpoch int64) (int64, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE commands
		 SET status='expired'
		 WHERE session_id=? AND status IN ('accepted','running') AND lease_epoch < ?`,
		sessionID, belowEpoch)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
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

// UpsertWorkspaceCommandResult 保存 workspace.create 的唯一结果；重复回执只能重放同一结果，
// 不允许用新的 canonical_root 覆盖已确认的本机路径。
func (r *sqliteRepo) UpsertWorkspaceCommandResult(ctx context.Context, result WorkspaceCommandResultRow) error {
	if result.CreatedAtUnixMS == 0 {
		result.CreatedAtUnixMS = time.Now().UnixMilli()
	}
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO workspace_command_results(command_id,account_id,workspace_id,canonical_root,status,error_code,created_at_unix_ms)
		 VALUES(?,?,?,?,?,?,?)
		 ON CONFLICT(command_id) DO UPDATE SET
			status=CASE WHEN workspace_command_results.status='succeeded' THEN workspace_command_results.status ELSE excluded.status END,
			error_code=CASE WHEN workspace_command_results.status='succeeded' THEN workspace_command_results.error_code ELSE excluded.error_code END,
			canonical_root=CASE WHEN workspace_command_results.status='succeeded' THEN workspace_command_results.canonical_root ELSE excluded.canonical_root END`,
		result.CommandID, result.AccountID, result.WorkspaceID, result.CanonicalRoot, result.Status, result.ErrorCode, result.CreatedAtUnixMS)
	return err
}

func (r *sqliteRepo) WorkspaceCommandResultByCommandID(ctx context.Context, commandID string) (WorkspaceCommandResultRow, error) {
	var result WorkspaceCommandResultRow
	err := r.db.QueryRowContext(ctx,
		`SELECT command_id,account_id,workspace_id,canonical_root,status,error_code,created_at_unix_ms
		 FROM workspace_command_results WHERE command_id=?`, commandID).
		Scan(&result.CommandID, &result.AccountID, &result.WorkspaceID, &result.CanonicalRoot, &result.Status, &result.ErrorCode, &result.CreatedAtUnixMS)
	return result, err
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

const messageFeedbackColumns = `account_id,session_id,message_id,rating,note,version,updated_by_device_id,updated_at_unix_ms`

func scanMessageFeedback(row *sql.Row) (MessageFeedbackRow, error) {
	var item MessageFeedbackRow
	var note sql.NullString
	if err := row.Scan(
		&item.AccountID, &item.SessionID, &item.MessageID, &item.Rating, &note,
		&item.Version, &item.UpdatedByDeviceID, &item.UpdatedAtUnixMS,
	); err != nil {
		return MessageFeedbackRow{}, err
	}
	item.Note = note.String
	return item, nil
}

func (r *sqliteRepo) ListMessageFeedback(ctx context.Context, sessionID string) ([]MessageFeedbackRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+messageFeedbackColumns+`
		   FROM message_feedback
		  WHERE session_id=?
		  ORDER BY updated_at_unix_ms ASC, message_id ASC`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MessageFeedbackRow
	for rows.Next() {
		var item MessageFeedbackRow
		var note sql.NullString
		if err := rows.Scan(
			&item.AccountID, &item.SessionID, &item.MessageID, &item.Rating, &note,
			&item.Version, &item.UpdatedByDeviceID, &item.UpdatedAtUnixMS,
		); err != nil {
			return nil, err
		}
		item.Note = note.String
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *sqliteRepo) MessageFeedbackByMessage(ctx context.Context, sessionID, messageID string) (MessageFeedbackRow, error) {
	return scanMessageFeedback(r.db.QueryRowContext(ctx,
		`SELECT `+messageFeedbackColumns+`
		   FROM message_feedback
		  WHERE session_id=? AND message_id=?`, sessionID, messageID))
}

func (r *sqliteRepo) CreateMessageFeedback(ctx context.Context, row MessageFeedbackRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO message_feedback(
			account_id,session_id,message_id,rating,note,version,updated_by_device_id,updated_at_unix_ms
		) VALUES(?,?,?,?,?,?,?,?)`,
		row.AccountID, row.SessionID, row.MessageID, row.Rating, nullableString(row.Note),
		row.Version, row.UpdatedByDeviceID, row.UpdatedAtUnixMS)
	return err
}

func (r *sqliteRepo) UpdateMessageFeedback(ctx context.Context, row MessageFeedbackRow, expectedVersion int64) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE message_feedback
		    SET rating=?, note=?, version=?, updated_by_device_id=?, updated_at_unix_ms=?
		  WHERE session_id=? AND message_id=? AND version=?`,
		row.Rating, nullableString(row.Note), row.Version, row.UpdatedByDeviceID, row.UpdatedAtUnixMS,
		row.SessionID, row.MessageID, expectedVersion)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
}

func (r *sqliteRepo) DeleteMessageFeedback(ctx context.Context, sessionID, messageID string, expectedVersion int64) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`DELETE FROM message_feedback WHERE session_id=? AND message_id=? AND version=?`,
		sessionID, messageID, expectedVersion)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return affected == 1, err
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

// ListAttachmentChunks 按块序返回附件全部密文块（v0.8.5 §3.3）。Relay 不重组
// 明文、不做解码，只按存储顺序搬运密文；调用方（Daemon 读取端点）负责归属校验。
func (r *sqliteRepo) ListAttachmentChunks(ctx context.Context, attachmentID string) ([]AttachmentChunkRow, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT attachment_id,chunk_index,idempotency_key,ciphertext,ciphertext_sha256 FROM attachment_chunks WHERE attachment_id=? ORDER BY chunk_index ASC`, attachmentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AttachmentChunkRow
	for rows.Next() {
		var row AttachmentChunkRow
		if err := rows.Scan(&row.AttachmentID, &row.ChunkIndex, &row.IdempotencyKey, &row.Ciphertext, &row.CiphertextSHA256); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
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

// ConsumeTerminalAuthNonce 先清理"已过期"的 nonce，再以唯一键插入当前 nonce。
// 清理阈值必须是当前时间 nowUnixMS：若误用新记录的过期时间（now+TTL）作为阈值，
// 时钟前进会把仍在重放窗口内的历史 nonce 提前删除，造成重放放行。
// 插入 0 行表示该 nonce 已被使用或仍存在，必须按重放拒绝。
func (r *sqliteRepo) ConsumeTerminalAuthNonce(ctx context.Context, keyID, nonce string, nowUnixMS, expiresAtUnixMS int64) error {
	if _, err := r.db.ExecContext(ctx,
		`DELETE FROM terminal_auth_nonces WHERE expires_at_unix_ms < ?`, nowUnixMS); err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO terminal_auth_nonces(key_id, nonce, expires_at_unix_ms, created_at_unix_ms)
		 VALUES(?,?,?,?)`,
		keyID, nonce, expiresAtUnixMS, expiresAtUnixMS)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected != 1 {
		return protocol.NewError(protocol.ErrNonceReused, "terminal nonce already used")
	}
	return nil
}

// CreateTerminalAuthChallenge 持久化一个绑定设备的 hello challenge。
// challenge 值由领域层用安全随机数生成；这里只负责落库与主键冲突防护。
func (r *sqliteRepo) CreateTerminalAuthChallenge(ctx context.Context, c TerminalAuthChallengeRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO terminal_auth_challenges(challenge,device_id,expires_at_unix_ms,created_at_unix_ms)
		 VALUES(?,?,?,?)`,
		c.Challenge, c.DeviceID, c.ExpiresAtUnixMS, c.CreatedAtUnixMS)
	return err
}

// ConsumeTerminalAuthChallenge 以条件 UPDATE 实现一次性消费：
// 只有"同设备、未过期、未消费"的挑战会被置为已消费，其余情况一律返回 false。
// 条件更新是原子的，天然防住并发重放同一挑战。
func (r *sqliteRepo) ConsumeTerminalAuthChallenge(ctx context.Context, deviceID, challenge string, nowUnixMS int64) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE terminal_auth_challenges
		 SET consumed_at_unix_ms=?
		 WHERE challenge=? AND device_id=? AND consumed_at_unix_ms=0 AND expires_at_unix_ms>=?`,
		nowUnixMS, challenge, deviceID, nowUnixMS)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return affected == 1, nil
}

// DeleteExpiredTerminalAuthChallenges 清理过期挑战。失败不阻塞业务路径，
// 由调用方决定是否记录诊断。
func (r *sqliteRepo) DeleteExpiredTerminalAuthChallenges(ctx context.Context, nowUnixMS int64) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM terminal_auth_challenges WHERE expires_at_unix_ms < ?`, nowUnixMS)
	return err
}

// CreateTerminalIdentityKey 登记一把设备 Ed25519 公钥。key_id 由领域层派生并保证唯一。
func (r *sqliteRepo) CreateTerminalIdentityKey(ctx context.Context, k TerminalIdentityKeyRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO terminal_identity_keys(key_id,device_id,account_id,public_key,status,created_at_unix_ms)
		 VALUES(?,?,?,?,?,?)`,
		k.KeyID, k.DeviceID, k.AccountID, k.PublicKey, k.Status, k.CreatedAtUnixMS)
	return err
}

func (r *sqliteRepo) TerminalIdentityKeyByID(ctx context.Context, keyID string) (TerminalIdentityKeyRow, error) {
	return scanTerminalIdentityKey(r.db.QueryRowContext(ctx,
		`SELECT key_id,device_id,account_id,public_key,status,created_at_unix_ms,retired_at_unix_ms
		 FROM terminal_identity_keys WHERE key_id=?`, keyID))
}

func scanTerminalIdentityKey(row *sql.Row) (TerminalIdentityKeyRow, error) {
	var k TerminalIdentityKeyRow
	if err := row.Scan(&k.KeyID, &k.DeviceID, &k.AccountID, &k.PublicKey, &k.Status, &k.CreatedAtUnixMS, &k.RetiredAtUnixMS); err != nil {
		return TerminalIdentityKeyRow{}, err
	}
	return k, nil
}

func (r *sqliteRepo) ListTerminalIdentityKeys(ctx context.Context, deviceID string) ([]TerminalIdentityKeyRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT key_id,device_id,account_id,public_key,status,created_at_unix_ms,retired_at_unix_ms
		 FROM terminal_identity_keys WHERE device_id=? ORDER BY created_at_unix_ms`, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TerminalIdentityKeyRow
	for rows.Next() {
		var k TerminalIdentityKeyRow
		if err := rows.Scan(&k.KeyID, &k.DeviceID, &k.AccountID, &k.PublicKey, &k.Status, &k.CreatedAtUnixMS, &k.RetiredAtUnixMS); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// CountActiveTerminalIdentityKeys 返回设备当前 active 密钥数量，
// 用于把轮换双读窗口限制为"旧 + 新"两把。
func (r *sqliteRepo) CountActiveTerminalIdentityKeys(ctx context.Context, deviceID string) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM terminal_identity_keys WHERE device_id=? AND status='active'`, deviceID).
		Scan(&count)
	return count, err
}

// RetireOtherTerminalIdentityKeys 把同一设备上除 keepKeyID 外的 active key 全部 retired。
// 轮换收口（新 key 首次成功签名）与设备撤销都走这一条条件 UPDATE，保证一写语义。
func (r *sqliteRepo) RetireOtherTerminalIdentityKeys(ctx context.Context, deviceID, keepKeyID string, nowUnixMS int64) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE terminal_identity_keys
		 SET status='retired', retired_at_unix_ms=?
		 WHERE device_id=? AND status='active' AND key_id<>?`,
		nowUnixMS, deviceID, keepKeyID)
	return err
}

// RetireTerminalIdentityKey 立即撤销单把登记密钥；幂等，重复撤销返回 false。
func (r *sqliteRepo) RetireTerminalIdentityKey(ctx context.Context, keyID string, nowUnixMS int64) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE terminal_identity_keys
		 SET status='retired', retired_at_unix_ms=?
		 WHERE key_id=? AND status='active'`,
		nowUnixMS, keyID)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return affected == 1, nil
}

// RelayOutboxRetryCap 是 Relay outbox 行的最大自动重试次数。
// 超过上限的 failed 行保留在库中，等待 RequeueFailedOutbox 恢复入口复位。
const RelayOutboxRetryCap = 8

func (r *sqliteRepo) EnqueueOutbox(ctx context.Context, o OutboxRow) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO outbox(kind,payload_json,status,attempts) VALUES(?,?,?,?)`,
		o.Kind, o.PayloadJSON, o.Status, o.Attempts)
	return err
}

func (r *sqliteRepo) ClaimOutbox(ctx context.Context, id int64) (OutboxRow, error) {
	var o OutboxRow
	if err := r.db.QueryRowContext(ctx,
		`SELECT id,kind,payload_json,status,attempts,next_attempt_at_unix_ms FROM outbox WHERE id=?`, id).
		Scan(&o.ID, &o.Kind, &o.PayloadJSON, &o.Status, &o.Attempts, &o.NextAttemptAtUnixMS); err != nil {
		return OutboxRow{}, err
	}
	return o, nil
}

func (r *sqliteRepo) MarkOutboxDone(ctx context.Context, id int64) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE outbox SET status='delivered', attempts=attempts+1, next_attempt_at_unix_ms=0 WHERE id=?`, id)
	return err
}

// MarkOutboxFailed 记录失败尝试并按指数退避推迟下一次重试；达到上限后行保持 failed，
// 不再被 ListPendingOutbox 选出，直到显式恢复。历史行永不删除。
func (r *sqliteRepo) MarkOutboxFailed(ctx context.Context, id int64, attempts int) error {
	backoff := int64(30 * time.Second / time.Millisecond)
	for i := 1; i < attempts; i++ {
		backoff *= 2
		if backoff >= int64(15*time.Minute/time.Millisecond) {
			backoff = int64(15 * time.Minute / time.Millisecond)
			break
		}
	}
	_, err := r.db.ExecContext(ctx,
		`UPDATE outbox SET status='failed', attempts=?, next_attempt_at_unix_ms=? WHERE id=?`,
		attempts, time.Now().UnixMilli()+backoff, id)
	return err
}

// ListPendingOutbox 返回到达重试时间的 pending/failed(未达上限) 行，按序出队。
// 已达重试上限的 failed 行必须通过 RequeueFailedOutbox 显式恢复后才会再次出现。
func (r *sqliteRepo) ListPendingOutbox(ctx context.Context, limit int) ([]OutboxRow, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id,kind,payload_json,status,attempts,next_attempt_at_unix_ms FROM outbox
		 WHERE (status IN ('pending','failed','in_flight'))
		   AND attempts < ?
		   AND next_attempt_at_unix_ms <= ?
		 ORDER BY id LIMIT ?`,
		RelayOutboxRetryCap, time.Now().UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OutboxRow
	for rows.Next() {
		var o OutboxRow
		if err := rows.Scan(&o.ID, &o.Kind, &o.PayloadJSON, &o.Status, &o.Attempts, &o.NextAttemptAtUnixMS); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// RequeueFailedOutbox 把全部 failed 行复位为 pending（恢复入口），返回受影响行数。
// 复位同时清零 attempts 与退避时间，否则达到上限的行会立即再次被上限过滤。
func (r *sqliteRepo) RequeueFailedOutbox(ctx context.Context) (int64, error) {
	result, err := r.db.ExecContext(ctx,
		`UPDATE outbox SET status='pending', attempts=0, next_attempt_at_unix_ms=0 WHERE status='failed'`)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// CountOutboxByStatus 统计 outbox 状态分布；'done' 为历史 delivered 别名，一并计入。
func (r *sqliteRepo) CountOutboxByStatus(ctx context.Context) (int64, int64, int64, error) {
	var pending, failed, delivered int64
	count := func(status string) (int64, error) {
		var n int64
		err := r.db.QueryRowContext(ctx,
			`SELECT COUNT(1) FROM outbox WHERE status=?`, status).Scan(&n)
		return n, err
	}
	var err error
	if pending, err = count("pending"); err != nil {
		return 0, 0, 0, err
	}
	if failed, err = count("failed"); err != nil {
		return 0, 0, 0, err
	}
	if delivered, err = count("delivered"); err != nil {
		return 0, 0, 0, err
	}
	legacyDone, err := count("done")
	if err != nil {
		return 0, 0, 0, err
	}
	return pending, failed, delivered + legacyDone, nil
}

// RelayGeneration 读取持久化的 relay 实例代际（v0.8.9 P1）。
// 行不存在时返回空串（而非错误），调用方按"世代未知"处理。
func (r *sqliteRepo) RelayGeneration(ctx context.Context) (string, error) {
	var value string
	err := r.db.QueryRowContext(ctx,
		`SELECT value FROM relay_instance_meta WHERE key='relay_generation'`).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return value, nil
}

// UpsertUsageEvent 以 usage_key_hash 唯一约束写入 usage 事件。重复 key 返回
// (false, nil)，调用方按 ADR-010 去重语义返回同一 canonical receipt。
func (r *sqliteRepo) UpsertUsageEvent(ctx context.Context, u UsageEventRow) (bool, error) {
	result, err := r.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO usage_events
			(usage_key_hash, account_id, terminal_id, session_id, provider, model, utc_day,
			 input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
			 context_window_tokens, ttft_ms, decode_throughput, schema_version, created_at_unix_ms)
		 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		u.UsageKeyHash, u.AccountID, u.TerminalID, u.SessionID, u.Provider, u.Model, u.UTCDay,
		u.InputTokens, u.OutputTokens, u.CacheReadTokens, u.CacheWriteTokens, u.ContextWindowTokens,
		u.TTFTMS, u.DecodeThroughput,
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

// SessionUsageSummary 汇总单会话白名单 usage，并返回最近一次 Provider 回填的模型和计时字段。
func (r *sqliteRepo) SessionUsageSummary(ctx context.Context, accountID, sessionID string) (SessionUsageSummaryRow, error) {
	var out SessionUsageSummaryRow
	var input, output, cacheRead, cacheWrite sql.NullInt64
	if err := r.db.QueryRowContext(ctx,
		`SELECT SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), SUM(cache_write_tokens)
		   FROM usage_events
		  WHERE account_id=? AND session_id=?`, accountID, sessionID).
		Scan(&input, &output, &cacheRead, &cacheWrite); err != nil {
		return SessionUsageSummaryRow{}, err
	}
	if input.Valid {
		out.InputTokens = input.Int64
		out.HasData = true
	}
	if output.Valid {
		out.OutputTokens = output.Int64
		out.HasData = true
	}
	if cacheRead.Valid {
		out.CacheReadTokens = cacheRead.Int64
		out.HasData = true
	}
	if cacheWrite.Valid {
		out.CacheWriteTokens = cacheWrite.Int64
		out.HasData = true
	}

	var model sql.NullString
	var contextWindow sql.NullInt64
	var ttft sql.NullInt64
	var throughput sql.NullFloat64
	err := r.db.QueryRowContext(ctx,
		`SELECT model, context_window_tokens, ttft_ms, decode_throughput
		   FROM usage_events
		  WHERE account_id=? AND session_id=?
		    AND (model <> '' OR context_window_tokens > 0 OR ttft_ms IS NOT NULL OR decode_throughput IS NOT NULL)
		  ORDER BY created_at_unix_ms DESC, usage_key_hash DESC
		  LIMIT 1`, accountID, sessionID).
		Scan(&model, &contextWindow, &ttft, &throughput)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return SessionUsageSummaryRow{}, err
	}
	if model.Valid {
		out.Model = model.String
	}
	if contextWindow.Valid {
		out.ContextWindowTokens = contextWindow.Int64
	}
	if ttft.Valid {
		value := ttft.Int64
		out.TTFTMS = &value
	}
	if throughput.Valid {
		value := throughput.Float64
		out.DecodeThroughput = &value
	}
	return out, nil
}
