package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

type daemonHelloRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	DaemonVersion   string                  `json:"daemon_version"`
	Hostname        string                  `json:"hostname"`
	Platform        string                  `json:"platform"`
	Capabilities    []string                `json:"capabilities"`
	Signature       authz.TerminalSignature `json:"signature"`
}

func (a *API) handleDaemonHello(c *gin.Context) {
	var req daemonHelloRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon hello"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	result, err := a.Daemons.Hello(c.Request.Context(), domain.DaemonHelloInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		ProtocolVersion: req.ProtocolVersion, DaemonVersion: req.DaemonVersion,
		Hostname: req.Hostname, Platform: req.Platform, Capabilities: req.Capabilities,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, daemonHelloView{
		TerminalID: result.Terminal.ID, ProtocolVersion: result.ProtocolVersion,
		MinProtocolVersion:       result.MinProtocolVersion,
		HeartbeatIntervalSeconds: result.HeartbeatIntervalSeconds,
		AfterDeliverySeq:         result.AfterDeliverySeq,
		AuthModes:                result.AuthModes,
	})
}

// handleDaemonChallenge 为 Terminal 签发一次性 hello challenge（ADR-012）。
// 挑战绑定当前 bearer 设备且只能被 signed hello 消费一次；不返回任何设备元数据。
func (a *API) handleDaemonChallenge(c *gin.Context) {
	subj := subject(c)
	challenge, err := a.Daemons.IssueTerminalAuthChallenge(c.Request.Context(), subj.AccountID, subj.DeviceID)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, challenge)
}

type daemonHeartbeatRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	Signature       authz.TerminalSignature `json:"signature"`
}

func (a *API) handleDaemonHeartbeat(c *gin.Context) {
	var req daemonHeartbeatRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon heartbeat"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	result, err := a.Daemons.Heartbeat(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, req.ProtocolVersion)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, daemonHeartbeatView{TerminalID: result.TerminalID, ServerTimeUnixMS: result.ServerTimeUnixMS})
}

// handleDaemonCommandSSE 是专用 Terminal stream。它只发送 SQLite 已持久化的 command
// delivery；Hub 的实时通知丢失时，Daemon 用 terminal-local delivery_seq 重连回放即可恢复。
func (a *API) handleDaemonCommandSSE(logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		after := daemonLastDeliverySeq(c)
		if after < 0 {
			writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "after_delivery_seq must be a non-negative integer"))
			return
		}
		subj := subject(c)
		terminal, deliveries, err := a.Daemons.ListDeliveries(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, after)
		if err != nil {
			writeError(c, err)
			return
		}

		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Status(http.StatusOK)
		c.Writer.Flush()
		// SSE 连接计数只用于不含正文的可观测性指标（/v1/diagnostics）。
		a.sseConnectedTotal.Add(1)
		a.sseActive.Add(1)
		defer a.sseActive.Add(-1)
		lastSent := after
		for _, delivery := range deliveries {
			if err := a.writeDaemonDelivery(c, terminal, delivery); err != nil {
				logger.Warn("daemon sse initial delivery", "error", err)
				return
			}
			lastSent = delivery.DeliverySeq
		}

		ch, cancel := a.DaemonDeliveries.Subscribe(terminal.ID)
		defer cancel()
		ticker := time.NewTicker(daemonSSEHeartbeatInterval)
		defer ticker.Stop()
		for {
			select {
			case <-c.Request.Context().Done():
				return
			case <-ticker.C:
				// 心跳前复核设备状态：设备撤销后最多一个周期内旧 SSE 被服务端关闭，
				// 不依赖客户端自觉断开（ADR-012 撤销即时生效）。查询失败按 fail-closed 关闭。
				if !a.daemonDeviceActive(c.Request.Context(), subj.AccountID, subj.DeviceID) {
					logger.Warn("daemon sse closed: terminal device no longer active")
					return
				}
				_, _ = c.Writer.Write([]byte(": heartbeat\n\n"))
				c.Writer.Flush()
			case delivery, ok := <-ch:
				if !ok {
					return
				}
				if delivery.DeliverySeq <= lastSent {
					continue
				}
				if err := a.writeDaemonDelivery(c, terminal, delivery); err != nil {
					logger.Warn("daemon sse delivery", "error", err)
					return
				}
				lastSent = delivery.DeliverySeq
			}
		}
	}
}

// daemonSSEHeartbeatInterval 是 Daemon SSE 的心跳/撤销检查周期。
// 使用 var 仅为允许测试注入更短周期；生产代码不得修改。
var daemonSSEHeartbeatInterval = 15 * time.Second

// SetDaemonSSEHeartbeatIntervalForTest 仅供回归测试注入短周期并返回原值；
// 生产路径必须使用默认 15 秒。
func SetDaemonSSEHeartbeatIntervalForTest(d time.Duration) time.Duration {
	previous := daemonSSEHeartbeatInterval
	daemonSSEHeartbeatInterval = d
	return previous
}

// DaemonSSEHeartbeatIntervalForTest 返回当前周期（测试断言用）。
func DaemonSSEHeartbeatIntervalForTest() time.Duration {
	return daemonSSEHeartbeatInterval
}

// daemonDeviceActive 复核 Terminal 设备是否仍属于该账号且 active。
func (a *API) daemonDeviceActive(ctx context.Context, accountID, deviceID string) bool {
	device, err := a.Repo.DeviceByID(ctx, deviceID)
	if err != nil {
		return false
	}
	return device.AccountID == accountID && device.Role == domain.RoleTerminal && device.Status == domain.DeviceActive
}

func (a *API) writeDaemonDelivery(c *gin.Context, terminal store.TerminalRow, delivery store.DaemonDeliveryRow) error {
	command, workspaceID, err := a.Daemons.DeliveryCommandForTerminal(c.Request.Context(), terminal, delivery)
	if err != nil {
		return err
	}
	payload, err := json.Marshal(daemonDeliveryView{
		DeliverySeq: delivery.DeliverySeq,
		Command: daemonCommandView{
			ID: command.ID, SessionID: command.SessionID, WorkspaceID: workspaceID, Kind: command.Kind, LeaseEpoch: command.LeaseEpoch,
			TargetInstanceID: command.TargetInstanceID, TargetTerminalID: command.TargetTerminalID,
			Ciphertext: json.RawMessage(command.CiphertextJSON),
		},
	})
	if err != nil {
		return err
	}
	_, _ = c.Writer.Write([]byte("id: " + strconv.FormatInt(delivery.DeliverySeq, 10) + "\n"))
	_, _ = c.Writer.Write([]byte("event: command\n"))
	_, _ = c.Writer.Write([]byte("data: " + string(payload) + "\n\n"))
	c.Writer.Flush()
	return nil
}

type daemonCommandAckRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	DeliverySeq     int64                   `json:"delivery_seq"`
	AckKind         string                  `json:"ack_kind"`
	ErrorCode       string                  `json:"error_code"`
	Signature       authz.TerminalSignature `json:"signature"`
}

func (a *API) handleDaemonCommandAck(c *gin.Context) {
	var req daemonCommandAckRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon command acknowledgement"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	receipt, err := a.Daemons.Acknowledge(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), req.DeliverySeq, req.ProtocolVersion, req.AckKind, req.ErrorCode)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDaemonCommandReceiptView(receipt))
}

type daemonCommandResultRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	DeliverySeq     int64                   `json:"delivery_seq"`
	Status          string                  `json:"status"`
	ErrorCode       string                  `json:"error_code"`
	Signature       authz.TerminalSignature `json:"signature"`
}

type daemonWorkspaceResultRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	DeliverySeq     int64                   `json:"delivery_seq"`
	WorkspaceID     string                  `json:"workspace_id"`
	CanonicalRoot   string                  `json:"canonical_root"`
	Status          string                  `json:"status"`
	ErrorCode       string                  `json:"error_code"`
	Signature       authz.TerminalSignature `json:"signature"`
}

func (a *API) handleDaemonCommandResult(c *gin.Context) {
	var req daemonCommandResultRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon command result"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	receipt, err := a.Daemons.Resolve(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), req.DeliverySeq, req.ProtocolVersion, req.Status, req.ErrorCode)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDaemonCommandReceiptView(receipt))
}

// handleDaemonWorkspaceResult 是 workspace.create 唯一的路径回执入口。Relay 接收
// canonical_root 后只用于受控 Workspace 登记，响应仍使用不含路径的 receipt。
func (a *API) handleDaemonWorkspaceResult(c *gin.Context) {
	var req daemonWorkspaceResultRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed workspace command result"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	result, err := a.Daemons.ResolveWorkspace(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), req.DeliverySeq, req.ProtocolVersion, req.WorkspaceID, req.CanonicalRoot, req.Status, req.ErrorCode)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDaemonWorkspaceResultView(result))
}

type daemonWebReadResponseRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	DeliverySeq     int64                   `json:"delivery_seq"`
	Envelope        json.RawMessage         `json:"envelope"`
	Signature       authz.TerminalSignature `json:"signature"`
}

// handleDaemonWebReadResponse 只接收浏览器临时密钥可解的 envelope。Relay 不会将其投影到
// session_events 或账号 SSE，避免文件/代码/diff 内容穿过普通事件通道。
func (a *API) handleDaemonWebReadResponse(c *gin.Context) {
	var req daemonWebReadResponseRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil || !json.Valid(req.Envelope) {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed web read response"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	receipt, err := a.Daemons.StoreWebReadResponse(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), req.DeliverySeq, req.ProtocolVersion, string(req.Envelope))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDaemonCommandReceiptView(receipt))
}

type daemonEventUploadRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	EventID         string                  `json:"event_id"`
	CommandID       string                  `json:"command_id"`
	SessionID       string                  `json:"session_id"`
	EventType       string                  `json:"event_type"`
	Envelope        json.RawMessage         `json:"envelope"`
	Signature       authz.TerminalSignature `json:"signature"`
}

func (a *API) handleDaemonEventUpload(c *gin.Context) {
	var req daemonEventUploadRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil || !json.Valid(req.Envelope) {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon event"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	result, err := a.Daemons.UploadEvent(c.Request.Context(), domain.DaemonEventInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		ProtocolVersion: req.ProtocolVersion, EventID: req.EventID, CommandID: req.CommandID,
		SessionID: req.SessionID, EventType: req.EventType, EnvelopeJSON: string(req.Envelope),
	})
	if err != nil {
		writeError(c, err)
		return
	}
	if !result.Idempotent {
		a.publishPersistedSessionEvents(c.Request.Context(), subj.AccountID, req.SessionID, result.EventSeq-1)
	}
	writeOK(c, daemonEventUploadView{EventID: result.EventID, EventSeq: result.EventSeq, Idempotent: result.Idempotent})
}

func daemonLastDeliverySeq(c *gin.Context) int64 {
	raw := c.GetHeader("Last-Event-ID")
	if raw == "" {
		raw = c.Query("after_delivery_seq")
	}
	if strings.TrimSpace(raw) == "" {
		return 0
	}
	seq, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return -1
	}
	return seq
}

type daemonHelloView struct {
	TerminalID               string `json:"terminal_id"`
	ProtocolVersion          int    `json:"protocol_version"`
	MinProtocolVersion       int    `json:"min_protocol_version"`
	HeartbeatIntervalSeconds int    `json:"heartbeat_interval_seconds"`
	AfterDeliverySeq         int64  `json:"after_delivery_seq"`
	// AuthModes 是 additive 能力协商字段：客户端据此选择 bearer 或 signature_v1。
	AuthModes []string `json:"auth_modes,omitempty"`
}

type daemonHeartbeatView struct {
	TerminalID       string `json:"terminal_id"`
	ServerTimeUnixMS int64  `json:"server_time_unix_ms"`
}

type daemonCommandView struct {
	ID               string          `json:"id"`
	SessionID        string          `json:"session_id"`
	WorkspaceID      string          `json:"workspace_id"`
	Kind             string          `json:"kind"`
	LeaseEpoch       int64           `json:"lease_epoch"`
	TargetInstanceID string          `json:"target_instance_id,omitempty"`
	TargetTerminalID string          `json:"target_terminal_id"`
	Ciphertext       json.RawMessage `json:"ciphertext"`
}

type daemonDeliveryView struct {
	DeliverySeq int64             `json:"delivery_seq"`
	Command     daemonCommandView `json:"command"`
}

type daemonCommandReceiptView struct {
	CommandID   string `json:"command_id"`
	DeliverySeq int64  `json:"delivery_seq"`
	AckKind     string `json:"ack_kind"`
	Status      string `json:"status"`
	ErrorCode   string `json:"error_code,omitempty"`
}

type daemonWorkspaceResultView struct {
	CommandID   string `json:"command_id"`
	DeliverySeq int64  `json:"delivery_seq"`
	WorkspaceID string `json:"workspace_id"`
	Status      string `json:"status"`
	ErrorCode   string `json:"error_code,omitempty"`
}

func newDaemonWorkspaceResultView(result domain.WorkspaceCommandResult) daemonWorkspaceResultView {
	return daemonWorkspaceResultView{
		CommandID: result.CommandID, DeliverySeq: result.DeliverySeq, WorkspaceID: result.WorkspaceID,
		Status: result.Status, ErrorCode: result.ErrorCode,
	}
}

func newDaemonCommandReceiptView(receipt domain.DaemonCommandReceipt) daemonCommandReceiptView {
	return daemonCommandReceiptView{
		CommandID: receipt.CommandID, DeliverySeq: receipt.DeliverySeq, AckKind: receipt.AckKind,
		Status: receipt.Status, ErrorCode: receipt.ErrorCode,
	}
}

type daemonEventUploadView struct {
	EventID    string `json:"event_id"`
	EventSeq   int64  `json:"event_seq"`
	Idempotent bool   `json:"idempotent"`
}

// bindJSONBody 读取原始请求体并解析 JSON，返回原始字节供签名 body hash 校验。
func bindJSONBody(c *gin.Context, out any) ([]byte, error) {
	raw, err := c.GetRawData()
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return nil, err
	}
	return raw, nil
}

// terminalSignedBody 返回参与签名 body hash 的字节：
// 删除顶层 signature 成员后按"成员原文保持不变"的方式重新序列化。
// 客户端对未注入 signature 的紧凑 JSON 计算哈希；两端都不允许把 signature 字段
// 纳入哈希，否则会形成"签名覆盖自身"的循环依赖。非对象体或无签名字段时原样返回。
func terminalSignedBody(raw []byte) []byte {
	var payload map[string]json.RawMessage
	if json.Unmarshal(raw, &payload) != nil {
		return raw
	}
	if _, exists := payload["signature"]; !exists {
		return raw
	}
	delete(payload, "signature")
	canonical, err := json.Marshal(payload)
	if err != nil {
		return raw
	}
	return canonical
}
