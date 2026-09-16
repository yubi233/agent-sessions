package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	// ProviderFacts 是执行侧 Provider 运行时事实（v0.9.2 P1）。用指针区分
	// "上报了空数组"（有效事实：当前没有任何可用 Provider）与"旧 Daemon 完全没有
	// 该字段"（保持既有快照，不把未知当成不可用）。
	ProviderFacts *[]providerFactPayload `json:"provider_facts"`
}

// providerFactPayload 是执行侧事实的 wire 形状（与 openapi ProviderFact 对齐）。
// 只承载安全元数据：版本、中文失败原因与模型目录；不接受路径、凭据或正文。
type providerFactPayload struct {
	Kind             string                      `json:"kind"`
	Available        bool                        `json:"available"`
	Version          string                      `json:"version"`
	Reason           string                      `json:"reason"`
	DefaultModel     string                      `json:"default_model"`
	ObservedAtUnixMS int64                       `json:"observed_at_unix_ms"`
	ModelGroups      []providerModelGroupPayload `json:"model_groups"`
}

type providerModelGroupPayload struct {
	ID     string                     `json:"id"`
	Name   string                     `json:"name"`
	Models []providerModelFactPayload `json:"models"`
}

type providerModelFactPayload struct {
	Provider            string   `json:"provider"`
	Value               string   `json:"value"`
	ID                  string   `json:"id"`
	Name                string   `json:"name"`
	ContextWindowTokens int64    `json:"context_window_tokens"`
	Reasoning           bool     `json:"reasoning"`
	Efforts             []string `json:"efforts"`
}

// providerFactFields 是长度上限（与 openapi schema 的 maxLength 对齐）。
// 越界即拒绝整条请求：静默截断会让客户端展示与执行侧不一致的目录。
const (
	maxProviderFactKindLength    = 32
	maxProviderFactVersionLength = 64
	maxProviderFactReasonLength  = 256
	maxProviderFactModelLength   = 192
	maxProviderFactGroupLength   = 96
	maxProviderFactEffortLength  = 64
	maxProviderFactsPerTerminal  = 8
	maxProviderFactGroups        = 8
	maxProviderFactModels        = 64
	maxProviderFactEfforts       = 16
)

// providerFactsToDomain 把 wire 事实转换为领域事实，并做边界校验。
// 校验失败一律拒绝（fail-closed）：宁可让旧快照继续生效，也不接受越界内容。
func providerFactsToDomain(in *[]providerFactPayload) ([]domain.ProviderFact, bool, error) {
	if in == nil {
		return nil, false, nil
	}
	payloads := *in
	if payloads == nil {
		payloads = []providerFactPayload{}
	}
	if len(payloads) > maxProviderFactsPerTerminal {
		return nil, true, fmt.Errorf("provider_facts 最多 %d 条", maxProviderFactsPerTerminal)
	}
	out := make([]domain.ProviderFact, 0, len(payloads))
	for _, payload := range payloads {
		kind := strings.TrimSpace(payload.Kind)
		if kind == "" {
			return nil, true, errors.New("provider_facts 缺少 kind")
		}
		if len(kind) > maxProviderFactKindLength {
			return nil, true, fmt.Errorf("provider_facts kind 超长（上限 %d）", maxProviderFactKindLength)
		}
		reason := strings.TrimSpace(payload.Reason)
		if len(reason) > maxProviderFactReasonLength {
			return nil, true, fmt.Errorf("provider_facts reason 超长（上限 %d）", maxProviderFactReasonLength)
		}
		version := strings.TrimSpace(payload.Version)
		if len(version) > maxProviderFactVersionLength {
			return nil, true, fmt.Errorf("provider_facts version 超长（上限 %d）", maxProviderFactVersionLength)
		}
		if len(payload.ModelGroups) > maxProviderFactGroups {
			return nil, true, fmt.Errorf("provider_facts model_groups 最多 %d 组", maxProviderFactGroups)
		}
		fact := domain.ProviderFact{
			Kind:             kind,
			Available:        payload.Available,
			Version:          version,
			Reason:           reason,
			ObservedAtUnixMS: payload.ObservedAtUnixMS,
		}
		for _, group := range payload.ModelGroups {
			if len(group.Models) > maxProviderFactModels {
				return nil, true, fmt.Errorf("provider_facts 分组 %q 模型数超上限 %d", group.ID, maxProviderFactModels)
			}
			converted := domain.ProviderFactGroup{ID: strings.TrimSpace(group.ID), Name: strings.TrimSpace(group.Name)}
			if len(converted.ID) > maxProviderFactGroupLength {
				return nil, true, fmt.Errorf("provider_facts 分组 id 超长（上限 %d）", maxProviderFactGroupLength)
			}
			for _, model := range group.Models {
				value := strings.TrimSpace(model.Value)
				if value == "" {
					return nil, true, errors.New("provider_facts 模型缺少 value（opaque 选择值不可猜测）")
				}
				if len(value) > maxProviderFactModelLength {
					return nil, true, fmt.Errorf("provider_facts 模型 value 超长（上限 %d）", maxProviderFactModelLength)
				}
				if len(model.Efforts) > maxProviderFactEfforts {
					return nil, true, fmt.Errorf("provider_facts 模型 efforts 最多 %d 项", maxProviderFactEfforts)
				}
				efforts := make([]string, 0, len(model.Efforts))
				for _, effort := range model.Efforts {
					trimmed := strings.TrimSpace(effort)
					if len(trimmed) > maxProviderFactEffortLength {
						return nil, true, fmt.Errorf("provider_facts effort 超长（上限 %d）", maxProviderFactEffortLength)
					}
					if trimmed != "" {
						efforts = append(efforts, trimmed)
					}
				}
				converted.Models = append(converted.Models, domain.ProviderFactModel{
					Provider:            strings.TrimSpace(model.Provider),
					Value:               value,
					ID:                  strings.TrimSpace(model.ID),
					Name:                strings.TrimSpace(model.Name),
					ContextWindowTokens: model.ContextWindowTokens,
					Reasoning:           model.Reasoning,
					Efforts:             efforts,
				})
			}
			fact.ModelGroups = append(fact.ModelGroups, converted)
		}
		if defaultModel := strings.TrimSpace(payload.DefaultModel); defaultModel != "" {
			// 默认模型必须落在目录内：否则客户端会展示一个无法提交的默认项。
			if !providerFactHasModel(fact.ModelGroups, defaultModel) {
				return nil, true, fmt.Errorf("provider_facts 默认模型 %q 不在模型目录内", defaultModel)
			}
			fact.DefaultModel = defaultModel
		}
		out = append(out, fact)
	}
	return out, true, nil
}

// providerFactHasModel 判断模型引用是否出现在目录中。
func providerFactHasModel(groups []domain.ProviderFactGroup, value string) bool {
	for _, group := range groups {
		for _, model := range group.Models {
			if model.Value == value {
				return true
			}
		}
	}
	return false
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
	providerFacts, factsReported, err := providerFactsToDomain(req.ProviderFacts)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, err.Error()))
		return
	}
	result, err := a.Daemons.Hello(c.Request.Context(), domain.DaemonHelloInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		ProtocolVersion: req.ProtocolVersion, DaemonVersion: req.DaemonVersion,
		Hostname: req.Hostname, Platform: req.Platform, Capabilities: req.Capabilities,
		ProviderFacts: providerFacts, ProviderFactsReported: factsReported,
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
		RelayGeneration:          result.RelayGeneration,
	})
}

type daemonSessionRecoveryRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	Signature       authz.TerminalSignature `json:"signature"`
}

type daemonSessionRecoveryView struct {
	RecoveredIdle    int `json:"recovered_idle"`
	RecoveredStopped int `json:"recovered_stopped"`
}

// handleDaemonSessionRecovery 接收 Daemon 进程启动后的一次性历史收口声明。
// 只有已配对 Terminal 可以调用；收口范围锁定该 Terminal 的工作区，语义见
// domain.RecoverTerminalSessions（不 archive，不要求心跳失联，幂等）。
func (a *API) handleDaemonSessionRecovery(c *gin.Context) {
	var req daemonSessionRecoveryRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon session recovery"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	summary, err := a.Daemons.RecoverTerminalSessions(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, req.ProtocolVersion)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, daemonSessionRecoveryView{RecoveredIdle: summary.RecoveredIdle, RecoveredStopped: summary.RecoveredStopped})
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
	// ProviderFacts 语义同 hello：指针区分"上报空快照"与"未携带"。
	ProviderFacts *[]providerFactPayload `json:"provider_facts"`
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
	providerFacts, factsReported, err := providerFactsToDomain(req.ProviderFacts)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, err.Error()))
		return
	}
	result, err := a.Daemons.Heartbeat(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, req.ProtocolVersion, providerFacts, factsReported)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, daemonHeartbeatView{TerminalID: result.TerminalID, ServerTimeUnixMS: result.ServerTimeUnixMS, RelayGeneration: result.RelayGeneration})
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

// contentDEKPutRequest 是 Terminal 上行的会话内容密钥 wrap（v0.8.5 §3.2 / ADR-016 §3.1）。
// wrapped_dek 对 Relay 不透明：只落 device_key_wraps，不回显、不落日志。
type contentDEKPutRequest struct {
	ProtocolVersion   int                     `json:"protocol_version"`
	DEKID             string                  `json:"dek_id"`
	WrappedDEK        []byte                  `json:"wrapped_dek"`
	RecipientDeviceID string                  `json:"recipient_device_id"`
	Signature         authz.TerminalSignature `json:"signature"`
}

// ownerKeyView 是 owner 公钥的最小安全投影：只含 encryption_public_key 本体。
type ownerKeyView struct {
	EncryptionPublicKey string `json:"encryption_public_key"`
	DeviceID            string `json:"device_id"`
}

// handleDaemonOwnerEncryptionKey 是 Daemon 获取会话 owner 公钥的端点（ADR-016 §2）：
// home Terminal 在会话启动时用它 wrap 本机 DEK 并上行；GET 幂等只读不签名。
func (a *API) handleDaemonOwnerEncryptionKey(c *gin.Context) {
	subj := subject(c)
	key, deviceID, err := a.Daemons.OwnerEncryptionKeyForSession(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, ownerKeyView{EncryptionPublicKey: key, DeviceID: deviceID})
}

// handleDaemonPutContentDEK 是 Daemon 鉴权的会话内容 DEK 登记端点（ADR-016 §3.1）。
// 归属与幂等校验在 domain（home Terminal、recipient active owner、异 id 拒绝）。
func (a *API) handleDaemonPutContentDEK(c *gin.Context) {
	subj := subject(c)
	var req contentDEKPutRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed content dek put"))
		return
	}
	// 与 modes 上行一致：daemon body PUT 必须带 Terminal 签名。
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	if err := a.Daemons.PutSessionContentDEK(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, c.Param("id"), req.DEKID, req.WrappedDEK, req.RecipientDeviceID); err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"status": "stored"})
}

// attachmentReadView 是 Daemon 附件读取的 wire 投影（v0.8.5 §3.3）：
// 只回传密文与白名单字段；任何文件名/明文正文都不出现在响应或日志。
type attachmentReadView struct {
	AttachmentID       string   `json:"attachment_id"`
	MimeType           string   `json:"mime_type"`
	ByteSize           int64    `json:"byte_size"`
	TotalChunks        int      `json:"total_chunks"`
	MetadataCiphertext []byte   `json:"metadata_ciphertext"`
	Chunks             [][]byte `json:"chunks"`
	ChunkSHA256        []string `json:"chunk_sha256"`
}

// handleDaemonReadAttachment 是 Daemon 鉴权的附件密文只读端点（§3.3）：
// GET 无 body 不签名（GET 幂等只读，Terminal bearer 即可）；归属由 domain
// ReadAttachmentForDaemon 校验（附件 session 的 workspace home terminal）。
func (a *API) handleDaemonReadAttachment(c *gin.Context) {
	subj := subject(c)
	projection, err := a.Daemons.ReadAttachmentForDaemon(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, attachmentReadView{
		AttachmentID: projection.AttachmentID, MimeType: projection.MimeType,
		ByteSize: projection.ByteSize, TotalChunks: projection.TotalChunks,
		MetadataCiphertext: projection.MetadataCiphertext,
		Chunks:             projection.Chunks, ChunkSHA256: projection.ChunkSHA256,
	})
}

type daemonSessionModesRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	ModeID          string                  `json:"mode_id"`
	AgentPresetID   string                  `json:"agent_preset_id"`
	AvailableModes  []daemonModeItem        `json:"available_permission_modes"`
	Signature       authz.TerminalSignature `json:"signature"`
}

// daemonModeItem 是 mode 目录行的最小安全投影（v0.8.5 §3.4）。只含 id/name 等
// 非敏感展示元数据；Relay 不做任何 mode 语义判断，仅原样快照后经 controls 下发。
type daemonModeItem struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
}

// handleDaemonSessionModes 接收 Daemon 上行的会话级 permission mode 目录快照。
// 这是会话运行期 handle 的事实（new/load/resume 响应与 current_mode_update），
// Relay 侧没有任何解密能力，只能由拥有该会话的 Daemon 主动同步（签名校验 +
// home Terminal 归属校验，见 domain SyncSessionPermissionModes）。
func (a *API) handleDaemonSessionModes(c *gin.Context) {
	var req daemonSessionModesRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed daemon session modes"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	modes := make([]map[string]string, 0, len(req.AvailableModes))
	for _, item := range req.AvailableModes {
		if strings.TrimSpace(item.ID) == "" {
			writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "mode id required"))
			return
		}
		modes = append(modes, map[string]string{"id": item.ID, "name": item.Name, "description": item.Description})
	}
	modesJSON, _ := json.Marshal(modes)
	if err := a.Daemons.SyncSessionPermissionModes(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), strings.TrimSpace(req.ModeID), string(modesJSON), strings.TrimSpace(req.AgentPresetID)); err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"ok": true})
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
type daemonDSHWorkspaceResultRequest struct {
	ProtocolVersion int                                `json:"protocol_version"`
	DeliverySeq     int64                              `json:"delivery_seq"`
	Candidates      []domain.WorkspaceDSHSyncCandidate `json:"candidates"`
	Status          string                             `json:"status"`
	ErrorCode       string                             `json:"error_code"`
	Signature       authz.TerminalSignature            `json:"signature"`
}

type daemonDSHImportResultRequest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	DeliverySeq     int64                   `json:"delivery_seq"`
	SessionIDs      []string                `json:"session_ids"`
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

// handleDaemonDSHWorkspaceResult 是 workspace.sync_dsh 的专用路径回执入口。canonical roots
// 只用于 Relay 内部登记 Workspace，响应只返回 opaque workspace ids。
func (a *API) handleDaemonDSHWorkspaceResult(c *gin.Context) {
	var req daemonDSHWorkspaceResultRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed dsh workspace command result"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	result, err := a.Daemons.ResolveDSHWorkspace(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), req.DeliverySeq, req.ProtocolVersion, req.Candidates, req.Status, req.ErrorCode)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDaemonDSHWorkspaceResultView(result))
}

// handleDaemonDSHImportResult 是 session.import_dsh 的专用路径回执入口。
// session ids 只用于 Relay 内部登记 Session，响应不包含任何本地路径或正文。
func (a *API) handleDaemonDSHImportResult(c *gin.Context) {
	var req daemonDSHImportResultRequest
	raw, err := bindJSONBody(c, &req)
	if err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed dsh import command result"))
		return
	}
	subj := subject(c)
	if err := a.Daemons.VerifySignedTerminalRequest(c.Request.Context(), subj.AccountID, subj.DeviceID, req.Signature, c.Request.Method, c.Request.URL.Path, terminalSignedBody(raw)); err != nil {
		writeError(c, err)
		return
	}
	result, err := a.Daemons.ResolveDSHImport(c.Request.Context(), subj.AccountID, subj.DeviceID, subj.Role,
		c.Param("id"), req.DeliverySeq, req.ProtocolVersion, req.SessionIDs, req.Status, req.ErrorCode)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDaemonDSHImportResultView(result))
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
	TerminalStatus  string                  `json:"terminal_status,omitempty"`
	Envelope        json.RawMessage         `json:"envelope"`
	CreatedAtUnixMS int64                   `json:"created_at_unix_ms,omitempty"`
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
		SessionID: req.SessionID, EventType: req.EventType, TerminalStatus: req.TerminalStatus,
		EnvelopeJSON: string(req.Envelope), CreatedAtUnixMS: req.CreatedAtUnixMS,
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
	// RelayGeneration 是 Relay DB 实例代际（v0.8.9 P1，additive）：同库稳定、重建必变。
	// Daemon 以 hello 为启动权威；空值表示旧 Relay，按 legacy 兼容策略处理。
	RelayGeneration string `json:"relay_generation,omitempty"`
}

type daemonHeartbeatView struct {
	TerminalID       string `json:"terminal_id"`
	ServerTimeUnixMS int64  `json:"server_time_unix_ms"`
	// RelayGeneration 是运行期世代发现通道（v0.8.9 P1，additive）：
	// Daemon 心跳比较该值，变化即说明 Relay DB 已重建，需停止命令处理并收口。
	RelayGeneration string `json:"relay_generation,omitempty"`
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

type daemonDSHWorkspaceResultView struct {
	CommandID    string   `json:"command_id"`
	DeliverySeq  int64    `json:"delivery_seq"`
	Status       string   `json:"status"`
	ErrorCode    string   `json:"error_code,omitempty"`
	WorkspaceIDs []string `json:"workspace_ids,omitempty"`
}

func newDaemonDSHWorkspaceResultView(result domain.WorkspaceDSHSyncResult) daemonDSHWorkspaceResultView {
	return daemonDSHWorkspaceResultView{
		CommandID: result.CommandID, DeliverySeq: result.DeliverySeq, Status: result.Status,
		ErrorCode: result.ErrorCode, WorkspaceIDs: result.WorkspaceIDs,
	}
}

type daemonDSHImportResultView struct {
	CommandID   string   `json:"command_id"`
	DeliverySeq int64    `json:"delivery_seq"`
	Status      string   `json:"status"`
	ErrorCode   string   `json:"error_code,omitempty"`
	SessionIDs  []string `json:"session_ids,omitempty"`
}

func newDaemonDSHImportResultView(result domain.WorkspaceDSHImportResult) daemonDSHImportResultView {
	return daemonDSHImportResultView{
		CommandID: result.CommandID, DeliverySeq: result.DeliverySeq, Status: result.Status,
		ErrorCode: result.ErrorCode, SessionIDs: result.SessionIDs,
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
