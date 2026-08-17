package domain

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// P2 只支持当前版本及其前一个主版本。当前为首个 Daemon REST+SSE 版本，
// 因而兼容窗口暂时为 1；后续升到 2 时应把 minProtocolVersion 降为 1。
const (
	currentDaemonProtocolVersion = 1
	minDaemonProtocolVersion     = 1
	daemonHeartbeatInterval      = 15 * time.Second
)

var (
	ErrTerminalRequired        = errors.New("terminal device required")
	ErrProtocolUpgradeRequired = errors.New("daemon protocol upgrade required")
	ErrProtocolUnsupported     = errors.New("daemon protocol unsupported")
	ErrDaemonCommandState      = errors.New("daemon command state conflict")
)

// DaemonHelloInput 是已配对 Terminal 声明的最小元数据。Workspace 根、Provider 正文和凭据
// 均不属于此协议，避免 Relay 变成工作区内容副本。
type DaemonHelloInput struct {
	AccountID       string
	DeviceID        string
	Role            string
	ProtocolVersion int
	DaemonVersion   string
	Hostname        string
	Platform        string
	Capabilities    []string
}

type DaemonHelloResult struct {
	Terminal                 store.TerminalRow
	ProtocolVersion          int
	MinProtocolVersion       int
	HeartbeatIntervalSeconds int
	AfterDeliverySeq         int64
}

type DaemonHeartbeatResult struct {
	TerminalID       string
	ServerTimeUnixMS int64
}

type DaemonCommandReceipt struct {
	CommandID   string
	DeliverySeq int64
	AckKind     string
	Status      string
	ErrorCode   string
}

type DaemonEventInput struct {
	AccountID       string
	DeviceID        string
	Role            string
	ProtocolVersion int
	EventID         string
	CommandID       string
	SessionID       string
	EventType       string
	EnvelopeJSON    string
}

type DaemonEventResult struct {
	EventID    string
	EventSeq   int64
	Idempotent bool
}

// DaemonService 管理 Terminal 专用协议状态。SessionService 继续拥有 Android 命令创建与
// lease/fencing 语义；DaemonService 只确认目标 Terminal 的接收、执行、结果和事件上传。
type DaemonService struct {
	repo store.Repository
	now  func() time.Time
}

func NewDaemonService(repo store.Repository) *DaemonService {
	return &DaemonService{repo: repo, now: time.Now}
}

// Hello 登记或恢复同一 device_id 的 Terminal。device bearer 已由 HTTP 中间件校验活动状态；
// 此处再次锁定 role/account，防止把 Web/Admin token 当作 Daemon 身份使用。
func (s *DaemonService) Hello(ctx context.Context, in DaemonHelloInput) (DaemonHelloResult, error) {
	if in.Role != RoleTerminal || strings.TrimSpace(in.DeviceID) == "" || strings.TrimSpace(in.AccountID) == "" {
		return DaemonHelloResult{}, ErrTerminalRequired
	}
	if err := validateDaemonProtocol(in.ProtocolVersion); err != nil {
		return DaemonHelloResult{}, err
	}
	if err := validateHelloMetadata(in); err != nil {
		return DaemonHelloResult{}, err
	}

	capabilities, err := json.Marshal(uniqueCapabilityNames(in.Capabilities))
	if err != nil {
		return DaemonHelloResult{}, err
	}
	now := s.now().UnixMilli()
	terminal, err := s.repo.TerminalByDeviceID(ctx, in.DeviceID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return DaemonHelloResult{}, err
	}
	if errors.Is(err, sql.ErrNoRows) {
		terminal = store.TerminalRow{ID: id.New("term"), DeviceID: in.DeviceID, AccountID: in.AccountID}
	} else if terminal.AccountID != in.AccountID {
		return DaemonHelloResult{}, ErrScopeDenied
	}
	terminal.Hostname = strings.TrimSpace(in.Hostname)
	terminal.Platform = strings.TrimSpace(in.Platform)
	terminal.Status = "online"
	terminal.LastSeenUnixMS = now
	terminal.ProtocolVersion = in.ProtocolVersion
	terminal.DaemonVersion = strings.TrimSpace(in.DaemonVersion)
	terminal.CapabilitiesJSON = string(capabilities)
	terminal.LastHeartbeatUnixMS = now
	if err := s.repo.UpsertDaemonTerminal(ctx, terminal); err != nil {
		return DaemonHelloResult{}, err
	}
	if err := s.repo.TouchDeviceLastSeen(ctx, in.DeviceID, now); err != nil {
		return DaemonHelloResult{}, err
	}
	return DaemonHelloResult{
		Terminal:                 terminal,
		ProtocolVersion:          currentDaemonProtocolVersion,
		MinProtocolVersion:       minDaemonProtocolVersion,
		HeartbeatIntervalSeconds: int(daemonHeartbeatInterval.Seconds()),
		AfterDeliverySeq:         0,
	}, nil
}

func (s *DaemonService) Heartbeat(ctx context.Context, accountID, deviceID, role string, protocolVersion int) (DaemonHeartbeatResult, error) {
	if role != RoleTerminal || deviceID == "" {
		return DaemonHeartbeatResult{}, ErrTerminalRequired
	}
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonHeartbeatResult{}, err
	}
	terminal, err := s.terminalForDevice(ctx, accountID, deviceID)
	if err != nil {
		return DaemonHeartbeatResult{}, err
	}
	now := s.now().UnixMilli()
	if err := s.repo.TouchTerminal(ctx, terminal.ID, now); err != nil {
		return DaemonHeartbeatResult{}, err
	}
	if err := s.repo.TouchDeviceLastSeen(ctx, deviceID, now); err != nil {
		return DaemonHeartbeatResult{}, err
	}
	return DaemonHeartbeatResult{TerminalID: terminal.ID, ServerTimeUnixMS: now}, nil
}

func (s *DaemonService) TerminalForDevice(ctx context.Context, accountID, deviceID, role string) (store.TerminalRow, error) {
	if role != RoleTerminal || deviceID == "" {
		return store.TerminalRow{}, ErrTerminalRequired
	}
	return s.terminalForDevice(ctx, accountID, deviceID)
}

func (s *DaemonService) terminalForDevice(ctx context.Context, accountID, deviceID string) (store.TerminalRow, error) {
	terminal, err := s.repo.TerminalByDeviceID(ctx, deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.TerminalRow{}, ErrTerminalOffline
		}
		return store.TerminalRow{}, err
	}
	if terminal.AccountID != accountID {
		return store.TerminalRow{}, ErrScopeDenied
	}
	return terminal, nil
}

func (s *DaemonService) ListDeliveries(ctx context.Context, accountID, deviceID, role string, afterDeliverySeq int64) (store.TerminalRow, []store.DaemonDeliveryRow, error) {
	if afterDeliverySeq < 0 {
		return store.TerminalRow{}, nil, protocol.NewError(protocol.ErrInvalidRequest, "after_delivery_seq must be a non-negative integer")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return store.TerminalRow{}, nil, err
	}
	deliveries, err := s.repo.ListDaemonDeliveriesAfter(ctx, terminal.ID, afterDeliverySeq)
	if err != nil {
		return store.TerminalRow{}, nil, err
	}
	return terminal, deliveries, nil
}

// DeliveryCommandForTerminal 将已持久化的 delivery 投影为 Daemon 可执行的最小命令。这里再次验证
// Session -> Workspace -> Terminal 关系，避免历史/损坏记录或错误 Hub 投递让 Terminal 获得别的
// Workspace 的 opaque payload；canonical_root 永远不离开 Relay。
func (s *DaemonService) DeliveryCommandForTerminal(ctx context.Context, terminal store.TerminalRow, delivery store.DaemonDeliveryRow) (store.CommandRow, string, error) {
	if terminal.ID == "" || delivery.TerminalID != terminal.ID || delivery.CommandID == "" {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	command, err := s.repo.CommandByID(ctx, delivery.CommandID)
	if err != nil {
		return store.CommandRow{}, "", err
	}
	if command.AccountID != terminal.AccountID || command.TargetTerminalID != terminal.ID {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	session, err := s.repo.SessionByID(ctx, command.SessionID)
	if err != nil {
		return store.CommandRow{}, "", err
	}
	if session.AccountID != terminal.AccountID || session.WorkspaceID == "" {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	workspace, err := s.repo.WorkspaceByID(ctx, session.WorkspaceID)
	if err != nil {
		return store.CommandRow{}, "", err
	}
	if workspace.TerminalID != terminal.ID {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	return command, workspace.ID, nil
}

// Acknowledge 把收到/开始/拒绝写为可重放状态。received 不改变 command 状态；started 重新检查
// 当前 lease/instance，防止旧控制权在网络重连后继续启动 Provider。
func (s *DaemonService) Acknowledge(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, ackKind, errorCode string) (DaemonCommandReceipt, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonCommandReceipt{}, err
	}
	if !validAckKind(ackKind) || deliverySeq <= 0 {
		return DaemonCommandReceipt{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon command acknowledgement")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	var result DaemonCommandReceipt
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if delivery.AckKind == ackKind {
			result = daemonReceipt(cmd, delivery)
			return nil
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			result = daemonReceipt(cmd, delivery)
			return nil
		}
		switch ackKind {
		case "received":
			// 不用 received 覆盖 started/rejected；重试只返回已有更强状态。
			if delivery.AckKind != "" {
				result = daemonReceipt(cmd, delivery)
				return nil
			}
		case "started":
			// browser 只读请求没有 Android lease；只有 lease_epoch=0 且固定 kind 的命令可走
			// 该分支，其他命令仍必须经过既有 owner/instance fencing。
			if !isWebReadCommand(cmd) {
				if err := validateCommandFence(ctx, tx, cmd); err != nil {
					return err
				}
			}
			if cmd.Status == CommandAccepted {
				if err := tx.UpdateCommandStatus(ctx, cmd.ID, CommandRunning); err != nil {
					return err
				}
				cmd.Status = CommandRunning
			}
		case "rejected":
			if err := tx.UpdateCommandStatus(ctx, cmd.ID, CommandRejected); err != nil {
				return err
			}
			cmd.Status = CommandRejected
		}
		delivery.AckKind = ackKind
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		result = daemonReceipt(cmd, delivery)
		return nil
	})
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	return result, nil
}

// Resolve 把 Terminal 的终态写回命令。详细输出不能塞入 result API，必须走 event_id 幂等的
// 密文 event 上传；这样 status 轮询不会扩大 Provider 文本可见范围。
func (s *DaemonService) Resolve(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, status, errorCode string) (DaemonCommandReceipt, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonCommandReceipt{}, err
	}
	if deliverySeq <= 0 || !validDaemonResultStatus(status) {
		return DaemonCommandReceipt{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon command result")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	var result DaemonCommandReceipt
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			result = daemonReceipt(cmd, delivery)
			return nil
		}
		if !isWebReadCommand(cmd) {
			if err := validateCommandFence(ctx, tx, cmd); err != nil {
				return err
			}
		}
		if cmd.Status != CommandRunning && cmd.Status != CommandAccepted {
			return ErrDaemonCommandState
		}
		if err := tx.UpdateCommandStatus(ctx, cmd.ID, status); err != nil {
			return err
		}
		cmd.Status = status
		delivery.ResultStatus = status
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, cmd.AccountID, "daemon.command_resolved", `{"command_id":"`+cmd.ID+`","status":"`+status+`"}`); err != nil {
			return err
		}
		result = daemonReceipt(cmd, delivery)
		return nil
	})
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	return result, nil
}

// StoreWebReadResponse 保存 Daemon 对浏览器临时公钥回封的结果。该 endpoint 不接受普通 event，
// 因此文件、代码和 diff 不会流入 account SSE 或 session_events；Relay 只保留 opaque envelope。
func (s *DaemonService) StoreWebReadResponse(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, envelopeJSON string) (DaemonCommandReceipt, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonCommandReceipt{}, err
	}
	if deliverySeq <= 0 || len(envelopeJSON) == 0 || len(envelopeJSON) > maxWebReadEnvelopeBytes || !validWebReadResponseEnvelope(envelopeJSON) {
		return DaemonCommandReceipt{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid web read response envelope")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	var result DaemonCommandReceipt
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if !isWebReadCommand(cmd) {
			return ErrScopeDenied
		}
		// 只有 Terminal 已确认开始处理的 delivery 才能回填响应。否则任意持有 Terminal token 的
		// 调用方都可能抢在本机 fence/解密前写入伪造 envelope，破坏 command 状态机。
		if delivery.AckKind != "started" {
			return ErrDaemonCommandState
		}
		if cmd.ReadResponseEnvelopeJSON != "" && cmd.ReadResponseEnvelopeJSON != envelopeJSON {
			return ErrDaemonCommandState
		}
		if cmd.Status != CommandRunning && cmd.Status != CommandSucceeded {
			return ErrDaemonCommandState
		}
		if cmd.Status == CommandSucceeded && cmd.ReadResponseEnvelopeJSON == "" {
			return ErrDaemonCommandState
		}
		if cmd.ReadResponseEnvelopeJSON == "" {
			if err := tx.SetCommandReadResponse(ctx, cmd.ID, envelopeJSON); err != nil {
				return err
			}
		}
		result = daemonReceipt(cmd, delivery)
		return nil
	})
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	return result, nil
}

// UploadEvent 写入与 command 绑定的 canonical event。Relay 不解密 event envelope，且 event_id
// 先在同一事务占位，避免失联重试时重复追加 session_events。
func (s *DaemonService) UploadEvent(ctx context.Context, in DaemonEventInput) (DaemonEventResult, error) {
	if err := validateDaemonProtocol(in.ProtocolVersion); err != nil {
		return DaemonEventResult{}, err
	}
	if strings.TrimSpace(in.EventID) == "" || strings.TrimSpace(in.CommandID) == "" || strings.TrimSpace(in.SessionID) == "" || !validDaemonEventType(in.EventType) {
		return DaemonEventResult{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon event metadata")
	}
	envelope, err := normalizeDaemonCipherEnvelope(in.EnvelopeJSON)
	if err != nil {
		return DaemonEventResult{}, err
	}
	terminal, err := s.TerminalForDevice(ctx, in.AccountID, in.DeviceID, in.Role)
	if err != nil {
		return DaemonEventResult{}, err
	}
	var result DaemonEventResult
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if existing, lookupErr := tx.DaemonEventReceiptByID(ctx, in.EventID); lookupErr == nil {
			if existing.TerminalID != terminal.ID || existing.CommandID != in.CommandID || existing.SessionID != in.SessionID {
				return ErrScopeDenied
			}
			if existing.EventSeq <= 0 {
				return ErrDaemonCommandState
			}
			result = DaemonEventResult{EventID: existing.EventID, EventSeq: existing.EventSeq, Idempotent: true}
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		cmd, _, commandErr := daemonCommandForTerminal(ctx, tx, terminal, in.CommandID, 0)
		if commandErr != nil {
			return commandErr
		}
		if cmd.SessionID != in.SessionID {
			return ErrScopeDenied
		}
		if err := validateCommandFence(ctx, tx, cmd); err != nil {
			return err
		}
		if err := tx.CreateDaemonEventReceipt(ctx, store.DaemonEventReceiptRow{
			EventID: in.EventID, TerminalID: terminal.ID, CommandID: in.CommandID, SessionID: in.SessionID,
			CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		seq, appendErr := tx.AppendEvent(ctx, store.SessionEventRow{
			SessionID: in.SessionID, EventType: in.EventType, EnvelopeJSON: envelope,
		})
		if appendErr != nil {
			return appendErr
		}
		if err := tx.SetSessionLastSeq(ctx, in.SessionID, seq); err != nil {
			return err
		}
		if err := tx.SetSessionStatus(ctx, in.SessionID, SessionRunning); err != nil {
			return err
		}
		if err := tx.SetDaemonEventReceiptSeq(ctx, in.EventID, seq); err != nil {
			return err
		}
		result = DaemonEventResult{EventID: in.EventID, EventSeq: seq}
		return nil
	})
	if err != nil {
		return DaemonEventResult{}, err
	}
	return result, nil
}

func daemonCommandForTerminal(ctx context.Context, repo store.Repository, terminal store.TerminalRow, commandID string, deliverySeq int64) (store.CommandRow, store.DaemonDeliveryRow, error) {
	cmd, err := repo.CommandByID(ctx, commandID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.CommandRow{}, store.DaemonDeliveryRow{}, store.ErrNotFound
		}
		return store.CommandRow{}, store.DaemonDeliveryRow{}, err
	}
	if cmd.AccountID != terminal.AccountID || cmd.TargetTerminalID != terminal.ID {
		return store.CommandRow{}, store.DaemonDeliveryRow{}, ErrScopeDenied
	}
	delivery, err := repo.DaemonDeliveryByCommandID(ctx, commandID)
	if err != nil {
		return store.CommandRow{}, store.DaemonDeliveryRow{}, err
	}
	if delivery.TerminalID != terminal.ID || (deliverySeq > 0 && delivery.DeliverySeq != deliverySeq) {
		return store.CommandRow{}, store.DaemonDeliveryRow{}, ErrScopeDenied
	}
	return cmd, delivery, nil
}

func validateCommandFence(ctx context.Context, repo store.Repository, cmd store.CommandRow) error {
	if cmd.SessionID == "" || cmd.LeaseEpoch <= 0 {
		return ErrTargetStale
	}
	session, err := repo.SessionByID(ctx, cmd.SessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrSessionNotFound
		}
		return err
	}
	lease, err := repo.LeaseBySession(ctx, cmd.SessionID)
	if err != nil {
		return ErrTargetStale
	}
	if lease.Epoch != cmd.LeaseEpoch {
		return ErrTargetStale
	}
	if session.CurrentInstanceID != "" && cmd.TargetInstanceID != session.CurrentInstanceID {
		return ErrTargetStale
	}
	if lease.InstanceID != "" && cmd.TargetInstanceID != lease.InstanceID {
		return ErrTargetStale
	}
	return nil
}

func daemonReceipt(cmd store.CommandRow, delivery store.DaemonDeliveryRow) DaemonCommandReceipt {
	return DaemonCommandReceipt{
		CommandID: cmd.ID, DeliverySeq: delivery.DeliverySeq, AckKind: delivery.AckKind,
		Status: cmd.Status, ErrorCode: delivery.ErrorCode,
	}
}

func validateDaemonProtocol(version int) error {
	if version < minDaemonProtocolVersion {
		return ErrProtocolUpgradeRequired
	}
	if version > currentDaemonProtocolVersion {
		return ErrProtocolUnsupported
	}
	return nil
}

func validateHelloMetadata(in DaemonHelloInput) error {
	if strings.TrimSpace(in.DaemonVersion) == "" || strings.TrimSpace(in.Hostname) == "" || strings.TrimSpace(in.Platform) == "" || len(in.Capabilities) > 64 {
		return protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon hello metadata")
	}
	for _, capability := range in.Capabilities {
		if value := strings.TrimSpace(capability); value == "" || len(value) > 96 {
			return protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon capability")
		}
	}
	return nil
}

func uniqueCapabilityNames(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, raw := range values {
		value := strings.TrimSpace(raw)
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func validAckKind(value string) bool {
	switch value {
	case "received", "started", "rejected":
		return true
	}
	return false
}

func validDaemonResultStatus(value string) bool {
	switch value {
	case CommandSucceeded, CommandFailed, CommandCancelled:
		return true
	}
	return false
}

func validWebReadResponseEnvelope(raw string) bool {
	if !validWebReadEnvelopeObject(raw, "alg", "payload_version", "nonce", "ciphertext", "aad_hash") {
		return false
	}
	var envelope struct {
		Alg            string `json:"alg"`
		PayloadVersion int    `json:"payload_version"`
		Nonce          string `json:"nonce"`
		Ciphertext     string `json:"ciphertext"`
		AADHash        string `json:"aad_hash"`
	}
	return json.Unmarshal([]byte(raw), &envelope) == nil &&
		envelope.Alg == WebReadEnvelopeAlgorithm && envelope.PayloadVersion == 1 &&
		validWebReadCipherFields(envelope.Nonce, envelope.Ciphertext, envelope.AADHash)
}

func validDaemonEventType(value string) bool {
	switch value {
	case "session.lifecycle", "turn.started", "message.delta", "message.completed", "tool.call", "tool.result", "usage.updated", "file.changed", "git.snapshot", "command.updated":
		return true
	}
	return false
}

// normalizeDaemonCipherEnvelope 只检查可转发的加密外形，不解析业务 payload。任何像正文、路径
// 或 Provider 原始响应的顶层键都在入库前拒绝，减少测试 fixture 或调用方误传造成的泄漏面。
func normalizeDaemonCipherEnvelope(raw string) (string, error) {
	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &envelope) != nil || len(envelope) == 0 {
		return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope is invalid")
	}
	for _, forbidden := range []string{"content", "message", "text", "path", "prompt", "provider_response", "raw"} {
		if _, found := envelope[forbidden]; found {
			return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope contains plaintext field")
		}
	}
	for _, key := range []string{"alg", "key_id", "nonce", "ciphertext", "aad_hash", "payload_version"} {
		if len(envelope[key]) == 0 {
			return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope is incomplete")
		}
	}
	var alg, keyID, nonce, ciphertext, aadHash string
	var payloadVersion int
	if json.Unmarshal(envelope["alg"], &alg) != nil || strings.TrimSpace(alg) == "" ||
		json.Unmarshal(envelope["key_id"], &keyID) != nil || strings.TrimSpace(keyID) == "" ||
		json.Unmarshal(envelope["nonce"], &nonce) != nil || strings.TrimSpace(nonce) == "" ||
		json.Unmarshal(envelope["ciphertext"], &ciphertext) != nil || strings.TrimSpace(ciphertext) == "" ||
		json.Unmarshal(envelope["aad_hash"], &aadHash) != nil || strings.TrimSpace(aadHash) == "" ||
		json.Unmarshal(envelope["payload_version"], &payloadVersion) != nil || payloadVersion < 1 {
		return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope is invalid")
	}
	normalized, err := json.Marshal(envelope)
	if err != nil {
		return "", err
	}
	return string(normalized), nil
}

func safeErrorCode(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 96 {
		return value[:96]
	}
	return value
}
