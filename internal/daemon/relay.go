package daemon

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const daemonProtocolVersion = 1

// TerminalRequestSigner 为 Daemon 出站的 Terminal 协议请求生成 v0.6 Ed25519 签名
// （ADR-012 canonical bytes）。私钥只保存在调用方内存中，不进入日志、报告或状态文件。
// DeviceID 是 bearer 绑定的设备 ID 并进入 canonical bytes；KeyID 在桥接期等于 DeviceID，
// 公钥登记轮换后为 tkey_ 前缀的登记密钥。
type TerminalRequestSigner struct {
	DeviceID string
	KeyID    string
	Priv     ed25519.PrivateKey
	// Nonce 允许测试注入确定性值；生产默认使用 crypto/rand 十六进制串。
	Nonce func() string
}

// sign 构造并签名一个 TerminalSignature。nonceOverride 非 0 时使用指定 nonce
// （hello 必须使用 Relay 预签发的一次性 challenge），否则生成随机 nonce。
func (s *TerminalRequestSigner) sign(method, path string, rawBody []byte, nonceOverride string) (authz.TerminalSignature, error) {
	if s.DeviceID == "" || s.KeyID == "" {
		return authz.TerminalSignature{}, errors.New("terminal request signer missing device or key id")
	}
	nonce := nonceOverride
	if nonce == "" {
		nonce = s.nextNonce()
	}
	sig := authz.TerminalSignature{
		ProtocolVersion: daemonProtocolVersion,
		KeyID:           s.KeyID,
		TimestampMS:     time.Now().UnixMilli(),
		Nonce:           nonce,
		BodyHash:        authz.HashBody(rawBody),
	}
	signature, err := authz.SignTerminalRequest(s.Priv, sig, s.DeviceID, method, path)
	if err != nil {
		return authz.TerminalSignature{}, err
	}
	sig.Signature = signature
	return sig, nil
}

// nextNonce 生成一次性随机 nonce；重复 nonce 会被 Relay 按重放拒绝。
func (s *TerminalRequestSigner) nextNonce() string {
	if s.Nonce != nil {
		return s.Nonce()
	}
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand 失败属于进程级异常，不能降级为可预测 nonce。
		panic("terminal signer entropy unavailable: " + err.Error())
	}
	return hex.EncodeToString(b)
}

// RelayClient 是 Daemon 到 Relay 的受限 REST + SSE 客户端。它只保存 bearer 在调用者提供的
// 配置中，不会记录到日志、report 或命令行输出。
// Signer 非 nil 时所有 POST 请求自动附加 v0.6 Terminal 签名；hello 先取一次性 challenge。
type RelayClient struct {
	BaseURL          string
	AccessToken      string
	HTTPClient       *http.Client
	StreamHTTPClient *http.Client
	Signer           *TerminalRequestSigner
}

type RelayHTTPError struct {
	Status int
	Code   string
}

func (e *RelayHTTPError) Error() string {
	if e.Code == "" {
		return fmt.Sprintf("relay http status %d", e.Status)
	}
	return fmt.Sprintf("relay http status %d: %s", e.Status, e.Code)
}

type RelayHello struct {
	TerminalID               string `json:"terminal_id"`
	ProtocolVersion          int    `json:"protocol_version"`
	MinProtocolVersion       int    `json:"min_protocol_version"`
	HeartbeatIntervalSeconds int    `json:"heartbeat_interval_seconds"`
	AfterDeliverySeq         int64  `json:"after_delivery_seq"`
}

// RelayCommandReceipt 是 Relay 对 result 的权威持久化投影。Daemon 重放请求时必须以该值
// 回填本地 SQLite，不能用本机旧意图覆盖 Relay 已提交的终态。
type RelayCommandReceipt struct {
	CommandID   string `json:"command_id"`
	DeliverySeq int64  `json:"delivery_seq"`
	AckKind     string `json:"ack_kind"`
	Status      string `json:"status"`
	ErrorCode   string `json:"error_code"`
}

// WorkspaceCommandReceipt 是 workspace.create 专用回执；canonical_root 只由 daemon 上传，
// Relay 不把它放进普通 command result，也不会回传给客户端。
type WorkspaceCommandReceipt struct {
	CommandID   string `json:"command_id"`
	DeliverySeq int64  `json:"delivery_seq"`
	WorkspaceID string `json:"workspace_id"`
	Status      string `json:"status"`
	ErrorCode   string `json:"error_code"`
}

// DSHSyncCommandReceipt 是 workspace.sync_dsh 专用回执。canonical roots 只由 daemon 上传，
// Relay 不把它们放进普通 command result，也不会回传给客户端。
type DSHSyncCommandReceipt struct {
	CommandID    string   `json:"command_id"`
	DeliverySeq  int64    `json:"delivery_seq"`
	Status       string   `json:"status"`
	ErrorCode    string   `json:"error_code"`
	WorkspaceIDs []string `json:"workspace_ids"`
}

// DSHImportCommandReceipt 是 session.import_dsh 专用回执。只包含 opaque session ids。
type DSHImportCommandReceipt struct {
	CommandID   string   `json:"command_id"`
	DeliverySeq int64    `json:"delivery_seq"`
	Status      string   `json:"status"`
	ErrorCode   string   `json:"error_code"`
	SessionIDs  []string `json:"session_ids"`
}

type RelayDelivery struct {
	DeliverySeq int64        `json:"delivery_seq"`
	Command     RelayCommand `json:"command"`
}

type RelayCommandWire struct {
	ID               string          `json:"id"`
	SessionID        string          `json:"session_id"`
	WorkspaceID      string          `json:"workspace_id"`
	Kind             string          `json:"kind"`
	LeaseEpoch       int64           `json:"lease_epoch"`
	TargetInstanceID string          `json:"target_instance_id"`
	TargetTerminalID string          `json:"target_terminal_id"`
	Ciphertext       json.RawMessage `json:"ciphertext"`
}

// Hello 协商版本和 Terminal ID。Caller 应把 Terminal ID 仅保存在本机 state，作为诊断元数据。
// 配置了 Signer 时先取一次性 challenge，再以 challenge 作为 hello 签名 nonce（ADR-012）。
func (c *RelayClient) Hello(ctx context.Context, daemonVersion, hostname, platform string, capabilities []string) (RelayHello, error) {
	var out RelayHello
	challenge := ""
	if c.Signer != nil {
		issued, err := c.Challenge(ctx)
		if err != nil {
			return RelayHello{}, err
		}
		challenge = issued
	}
	err := c.postJSONSigned(ctx, "/v1/daemon/hello", map[string]any{
		"protocol_version": daemonProtocolVersion,
		"daemon_version":   daemonVersion,
		"hostname":         hostname,
		"platform":         platform,
		"capabilities":     capabilities,
	}, challenge, &out)
	if err != nil {
		return RelayHello{}, err
	}
	if out.TerminalID == "" || out.ProtocolVersion == 0 || out.HeartbeatIntervalSeconds <= 0 {
		return RelayHello{}, errors.New("relay hello response incomplete")
	}
	return out, nil
}

// relayChallenge 是 GET /v1/daemon/challenge 的响应投影。
type relayChallenge struct {
	Challenge       string `json:"challenge"`
	ExpiresAtUnixMS int64  `json:"expires_at_unix_ms"`
}

// Challenge 获取绑定当前设备的一次性 hello challenge。GET 无 body；challenge 本身
// 不签名，由随后的 signed hello 以 nonce 形式一次性消费。
func (c *RelayClient) Challenge(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		strings.TrimRight(c.BaseURL, "/")+"/v1/daemon/challenge", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.AccessToken)
	response, err := c.restClient().Do(req)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return "", readRelayHTTPError(response)
	}
	var payload relayChallenge
	if err := json.NewDecoder(io.LimitReader(response.Body, 64*1024)).Decode(&payload); err != nil {
		return "", err
	}
	if strings.TrimSpace(payload.Challenge) == "" {
		return "", errors.New("relay challenge response incomplete")
	}
	return payload.Challenge, nil
}

func (c *RelayClient) Heartbeat(ctx context.Context) error {
	return c.postJSON(ctx, "/v1/daemon/heartbeat", map[string]any{"protocol_version": daemonProtocolVersion}, &struct{}{})
}

// RecoverSessions 在进程启动后向 Relay 声明一次「上一进程已死亡」，触发 Relay
// 对本 Terminal 工作区遗留 running 会话的历史收口。端点幂等，重试安全。
func (c *RelayClient) RecoverSessions(ctx context.Context) error {
	return c.postJSON(ctx, "/v1/daemon/sessions/recover", map[string]any{"protocol_version": daemonProtocolVersion}, &struct{}{})
}

func (c *RelayClient) Ack(ctx context.Context, commandID string, deliverySeq int64, ackKind, errorCode string) error {
	return c.postJSON(ctx, "/v1/daemon/commands/"+commandID+"/ack", map[string]any{
		"protocol_version": daemonProtocolVersion, "delivery_seq": deliverySeq, "ack_kind": ackKind, "error_code": errorCode,
	}, &struct{}{})
}

func (c *RelayClient) Resolve(ctx context.Context, commandID string, deliverySeq int64, status, errorCode string) (RelayCommandReceipt, error) {
	var out RelayCommandReceipt
	err := c.postJSON(ctx, "/v1/daemon/commands/"+commandID+"/result", map[string]any{
		"protocol_version": daemonProtocolVersion, "delivery_seq": deliverySeq, "status": status, "error_code": errorCode,
	}, &out)
	if err != nil {
		return RelayCommandReceipt{}, err
	}
	if !validRelayResultStatus(out.Status) {
		return RelayCommandReceipt{}, errors.New("relay command result receipt incomplete")
	}
	return out, nil
}

// ResolveWorkspace 上传 workspace.create 的受控结果。路径字段只存在于该专用请求，
// 普通 ack/result 端点永远不接受或返回 canonical_root。
func (c *RelayClient) ResolveWorkspace(ctx context.Context, commandID string, deliverySeq int64, workspaceID, canonicalRoot, status, errorCode string) (WorkspaceCommandReceipt, error) {
	var out WorkspaceCommandReceipt
	err := c.postJSON(ctx, "/v1/daemon/commands/"+commandID+"/workspace-result", map[string]any{
		"protocol_version": daemonProtocolVersion,
		"delivery_seq":     deliverySeq,
		"workspace_id":     workspaceID,
		"canonical_root":   canonicalRoot,
		"status":           status,
		"error_code":       errorCode,
	}, &out)
	if err != nil {
		return WorkspaceCommandReceipt{}, err
	}
	if out.CommandID == "" || out.WorkspaceID == "" || !validRelayResultStatus(out.Status) {
		return WorkspaceCommandReceipt{}, errors.New("relay workspace result receipt incomplete")
	}
	return out, nil
}

// ResolveDSHWorkspace 上传 workspace.sync_dsh 的受控结果。候选路径只存在于该专用请求，
// DisplayName 已由本机 scanner 派生；普通 ack/result 端点永远不接受或返回 canonical roots。
func (c *RelayClient) ResolveDSHWorkspace(ctx context.Context, commandID string, deliverySeq int64, candidates []DSHWorkspaceCandidate, status, errorCode string) (DSHSyncCommandReceipt, error) {
	var out DSHSyncCommandReceipt
	err := c.postJSON(ctx, "/v1/daemon/commands/"+commandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": daemonProtocolVersion,
		"delivery_seq":     deliverySeq,
		"candidates":       candidates,
		"status":           status,
		"error_code":       errorCode,
	}, &out)
	if err != nil {
		return DSHSyncCommandReceipt{}, err
	}
	if out.CommandID == "" || !validRelayResultStatus(out.Status) {
		return DSHSyncCommandReceipt{}, errors.New("relay dsh sync result receipt incomplete")
	}
	return out, nil
}

// ResolveDSHImport 上传 session.import_dsh 的受控结果。session ids 只存在于该专用请求，
// 普通 ack/result 端点永远不接受或返回它们。
func (c *RelayClient) ResolveDSHImport(ctx context.Context, commandID string, deliverySeq int64, sessionIDs []string, status, errorCode string) (DSHImportCommandReceipt, error) {
	var out DSHImportCommandReceipt
	err := c.postJSON(ctx, "/v1/daemon/commands/"+commandID+"/dsh-import-result", map[string]any{
		"protocol_version": daemonProtocolVersion,
		"delivery_seq":     deliverySeq,
		"session_ids":      sessionIDs,
		"status":           status,
		"error_code":       errorCode,
	}, &out)
	if err != nil {
		return DSHImportCommandReceipt{}, err
	}
	if out.CommandID == "" || !validRelayResultStatus(out.Status) {
		return DSHImportCommandReceipt{}, errors.New("relay dsh import result receipt incomplete")
	}
	return out, nil
}

// UploadWebReadResponse 把只属于浏览器临时公钥的响应 envelope 回写 Relay。Relay 只保存密文和
// command 状态；文件、代码、Git 状态或 diff 的明文不会进入该 HTTP body 之外的任何 Relay 逻辑。
func (c *RelayClient) UploadWebReadResponse(ctx context.Context, commandID string, deliverySeq int64, envelope WebReadResponseEnvelope) error {
	return c.postJSON(ctx, "/v1/daemon/commands/"+commandID+"/readonly-response", map[string]any{
		"protocol_version": daemonProtocolVersion,
		"delivery_seq":     deliverySeq,
		"envelope":         envelope,
	}, &struct{}{})
}

func (c *RelayClient) UploadEvent(ctx context.Context, event RelayEvent) error {
	var envelope json.RawMessage = json.RawMessage(event.EnvelopeJSON)
	body := map[string]any{
		"protocol_version": daemonProtocolVersion, "event_id": event.EventID, "command_id": event.CommandID,
		"session_id": event.SessionID, "event_type": event.EventType, "envelope": envelope,
	}
	if event.TerminalStatus != "" {
		body["terminal_status"] = event.TerminalStatus
	}
	if event.CreatedAtUnixMS > 0 {
		body["created_at_unix_ms"] = event.CreatedAtUnixMS
	}
	return c.postJSON(ctx, "/v1/daemon/events", body, &struct{}{})
}

// UploadUsage 只上传白名单整数计数与 UTC 日桶（ADR-010）。usage key 由 Daemon
// 对来源事件生成，重复上传返回同一 canonical receipt，不重复累加。
// SessionModeItem 是上行 mode 目录行的最小安全投影（v0.8.5 §3.4）。
type SessionModeItem struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
}

// SyncSessionModes 把会话级 permission mode 目录快照上行到 Relay（PUT 端点）。
// 这是会话运行期 handle 的事实；签名由 postJSON 在 Signer 非 nil 时自动附加
// （兼容窗口内旧 bearer 放行由 Relay 端处理）。失败只记录不阻断主流程。
func (c *RelayClient) SyncSessionModes(ctx context.Context, sessionID, modeID, agentPresetID string, modes []SessionModeItem) error {
	body := map[string]any{
		"protocol_version":           daemonProtocolVersion,
		"mode_id":                    modeID,
		"available_permission_modes": modes,
	}
	if agentPresetID != "" {
		body["agent_preset_id"] = agentPresetID
	}
	return c.postJSON(ctx, "/v1/daemon/sessions/"+sessionID+"/modes", body, &struct{}{})
}

// AttachmentFetchProjection 是 Relay §3.3 读取端点的最小密文投影（Daemon 侧）：
// 全部分块密文按存储顺序拼接后由本机会话 DEK 解密；sha256 供校验。
type AttachmentFetchProjection struct {
	AttachmentID       string   `json:"attachment_id"`
	MimeType           string   `json:"mime_type"`
	ByteSize           int64    `json:"byte_size"`
	TotalChunks        int      `json:"total_chunks"`
	MetadataCiphertext []byte   `json:"metadata_ciphertext"`
	Chunks             [][]byte `json:"chunks"`
	ChunkSHA256        []string `json:"chunk_sha256"`
}

// FetchAttachment 经 §3.3 端点拉取附件密文投影（v0.8.5 §3.1）。GET 幂等只读不签名；
// 只做密文搬运（不解析 metadata、不解密），解密由调用方按会话 DEK 完成。
func (c *RelayClient) FetchAttachment(ctx context.Context, attachmentID string) (AttachmentFetchProjection, error) {
	var out AttachmentFetchProjection
	if strings.TrimSpace(c.BaseURL) == "" || strings.TrimSpace(c.AccessToken) == "" {
		return out, errors.New("relay base URL or daemon credential missing")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(c.BaseURL, "/")+"/v1/daemon/attachments/"+attachmentID, nil)
	if err != nil {
		return out, err
	}
	req.Header.Set("Authorization", "Bearer "+c.AccessToken)
	response, err := c.restClient().Do(req)
	if err != nil {
		return out, err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return out, readRelayHTTPError(response)
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 12<<20)).Decode(&out); err != nil {
		return out, err
	}
	return out, nil
}

func (c *RelayClient) UploadUsage(ctx context.Context, usage RelayUsage) error {
	body := map[string]any{
		"usage_key": usage.UsageKey, "provider": usage.Provider, "utc_day": usage.UTCDay,
		"input_tokens": usage.InputTokens, "output_tokens": usage.OutputTokens,
		"cache_read_tokens": usage.CacheReadTokens, "cache_write_tokens": usage.CacheWriteTokens,
	}
	if usage.ContextWindowTokens > 0 {
		body["context_window_tokens"] = usage.ContextWindowTokens
	}
	if strings.TrimSpace(usage.SessionID) != "" {
		body["session_id"] = strings.TrimSpace(usage.SessionID)
	}
	if strings.TrimSpace(usage.Model) != "" {
		body["model"] = strings.TrimSpace(usage.Model)
	}
	if usage.TTFTMS != nil {
		body["ttft_ms"] = *usage.TTFTMS
	}
	if usage.DecodeThroughput != nil {
		body["decode_throughput"] = *usage.DecodeThroughput
	}
	return c.postJSON(ctx, "/v1/daemon/usage/events", body, &struct{}{})
}

// Stream 从终端自己的 delivery_seq 重放，再持续接收推送。SSE 数据由 Relay 生成且只包含目标
// Terminal 的密文命令；客户端不能自己指定 terminal_id。
func (c *RelayClient) Stream(ctx context.Context, afterDeliverySeq int64, consume func(context.Context, RelayDelivery) error) error {
	if afterDeliverySeq < 0 {
		return errors.New("negative relay delivery cursor")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		strings.TrimRight(c.BaseURL, "/")+"/v1/daemon/commands/stream?after_delivery_seq="+strconv.FormatInt(afterDeliverySeq, 10), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.AccessToken)
	req.Header.Set("Accept", "text/event-stream")
	response, err := c.streamClient().Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return readRelayHTTPError(response)
	}

	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 2<<20)
	var eventType, data string
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if eventType == "command" && data != "" {
				var wire struct {
					DeliverySeq int64            `json:"delivery_seq"`
					Command     RelayCommandWire `json:"command"`
				}
				if err := json.Unmarshal([]byte(data), &wire); err != nil {
					return fmt.Errorf("decode relay command SSE: %w", err)
				}
				delivery := RelayDelivery{DeliverySeq: wire.DeliverySeq, Command: RelayCommand{
					CommandID: wire.Command.ID, SessionID: wire.Command.SessionID, WorkspaceID: wire.Command.WorkspaceID,
					Kind:       wire.Command.Kind,
					LeaseEpoch: wire.Command.LeaseEpoch, TargetInstanceID: wire.Command.TargetInstanceID,
					TargetTerminalID: wire.Command.TargetTerminalID, PayloadJSON: string(wire.Command.Ciphertext),
				}}
				if err := consume(ctx, delivery); err != nil {
					return err
				}
			}
			eventType, data = "", ""
			continue
		}
		if strings.HasPrefix(line, "event: ") {
			eventType = strings.TrimSpace(strings.TrimPrefix(line, "event: "))
		} else if strings.HasPrefix(line, "data: ") {
			data += strings.TrimPrefix(line, "data: ")
		}
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, context.Canceled) {
		return err
	}
	return ctx.Err()
}

func (c *RelayClient) postJSON(ctx context.Context, path string, body any, output any) error {
	return c.postJSONSigned(ctx, path, body, "", output)
}

// postJSONSigned 发送 POST JSON；Signer 非 nil 时为请求附加 v0.6 Terminal 签名。
// nonceOverride 非 0 时使用指定 nonce（hello challenge），否则由 signer 生成随机 nonce。
// 签名对象是"未包含 signature 字段的原始 body 字节"，与 Relay 的 body hash 校验一致。
func (c *RelayClient) postJSONSigned(ctx context.Context, path string, body any, nonceOverride string, output any) error {
	if strings.TrimSpace(c.BaseURL) == "" || strings.TrimSpace(c.AccessToken) == "" {
		return errors.New("relay base URL or daemon credential missing")
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	if c.Signer != nil {
		raw, err = c.signBody(path, raw, nonceOverride)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.AccessToken)
	req.Header.Set("Content-Type", "application/json")
	response, err := c.restClient().Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return readRelayHTTPError(response)
	}
	if output == nil {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(output); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

// signBody 把 TerminalSignature 注入请求 JSON 的 signature 字段。
// body hash 覆盖注入前的原始字节，Relay 端以同样顺序校验，两端不允许自行拼接 canonical bytes。
func (c *RelayClient) signBody(path string, raw []byte, nonceOverride string) ([]byte, error) {
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, err
	}
	sig, err := c.Signer.sign(http.MethodPost, path, raw, nonceOverride)
	if err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(sig)
	if err != nil {
		return nil, err
	}
	payload["signature"] = encoded
	return json.Marshal(payload)
}

func (c *RelayClient) restClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// streamClient 保留调用方自定义的 Transport/Jar/redirect 策略，但移除覆盖整个响应生命周期的
// Client.Timeout。SSE 连接由 request context、Relay heartbeat 和重连状态机管理；继承普通 REST
// 的总超时会让生产命令流固定每 30 秒断开。
func (c *RelayClient) streamClient() *http.Client {
	if c.StreamHTTPClient != nil {
		return c.StreamHTTPClient
	}
	if c.HTTPClient != nil {
		stream := *c.HTTPClient
		stream.Timeout = 0
		return &stream
	}
	return &http.Client{}
}

func readRelayHTTPError(response *http.Response) error {
	var payload struct {
		Code string `json:"code"`
	}
	_ = json.NewDecoder(io.LimitReader(response.Body, 16*1024)).Decode(&payload)
	return &RelayHTTPError{Status: response.StatusCode, Code: payload.Code}
}

// EventEncoder 是 Daemon 把规范化 Provider event 封装为 Relay 可存储密文的边界。生产端必须注入
// 真正的账户密钥实现；缺失 encoder 时 RelayLoop 只保留本地状态，不上传明文或伪造密文。
type EventEncoder interface {
	Encode(sessionID string, event adapter.Event) (string, error)
}

type EventEncoderFunc func(sessionID string, event adapter.Event) (string, error)

func (f EventEncoderFunc) Encode(sessionID string, event adapter.Event) (string, error) {
	return f(sessionID, event)
}

// FixtureEventEncoder 是 deterministic integration 专用编码器。它将事件结构哈希放入一个
// protocol-shaped opaque envelope，不保存任何 payload 正文；它不是真实 E2EE，调用方必须明确标记 fixture。
type FixtureEventEncoder struct{}

func (FixtureEventEncoder) Encode(sessionID string, event adapter.Event) (string, error) {
	raw, err := json.Marshal(struct {
		SessionID string            `json:"session_id"`
		Type      adapter.EventType `json:"type"`
		Seq       int64             `json:"seq"`
	}{SessionID: sessionID, Type: event.Type, Seq: event.Seq})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return `{"alg":"fixture-aead","key_id":"fixture","nonce":"fixture-nonce","ciphertext":"` + hex.EncodeToString(sum[:]) + `","aad_hash":"fixture-aad","payload_version":1}`, nil
}

type usageContext struct {
	Provider string
	Model    string
}

// RelayLoop 把持久化接收、ack、Adapter 执行、终态和事件 outbox 串成最小可靠循环。
// 它刻意不读取/输出 Provider 正文，且任何网络失败都会留下可安全重试的本机记录。
type RelayLoop struct {
	Store    *Store
	Client   *RelayClient
	Runner   *SessionRunner
	ReadOnly *ReadOnlyDispatcher
	Encoder  EventEncoder
	// WorkspaceManager 是 workspace.create 的本机执行器；缺失时必须 fail-closed。
	WorkspaceManager *WorkspaceManager
	// WebRead 只用于 browser -> Daemon -> browser 的临时密钥只读响应；它与 Provider event
	// encoder 分离，不能把浏览器文件结果塞进账号事件或复用共享 DEK。
	WebRead       *WebReadTransport
	DaemonVersion string
	Hostname      string
	Platform      string
	Capabilities  []string
	Logger        *slog.Logger

	mu                    sync.RWMutex
	commandBySession      map[string]string
	usageContextBySession map[string]usageContext
	eventWake             chan struct{}
	// processMu keeps durable command state transitions serialized. A send may run
	// asynchronously, but only one caller may advance received/starting/started
	// rows at a time.
	processMu sync.Mutex
	// commandCtx is the current RunWithRetry context. It deliberately outlives
	// an individual SSE stream so an accepted async send can finish and resolve
	// its command when the stream reconnects.
	commandCtxMu sync.RWMutex
	commandCtx   context.Context
	// inFlightSend prevents a second processPending pass from executing an already
	// accepted send while its Provider call is still running. It is intentionally
	// process-local: a restart leaves a durable started row for the existing
	// DAEMON_RESTART_RECOVERY fail-closed path.
	inFlightMu    sync.Mutex
	inFlightSends map[string]struct{}
	// sessionRecoveryDone 门限每进程一次的启动清扫声明；runOnce 串行执行，无需加锁。
	sessionRecoveryDone bool
}

func NewRelayLoop(store *Store, client *RelayClient, runner *SessionRunner, encoder EventEncoder, logger *slog.Logger) *RelayLoop {
	if logger == nil {
		logger = slog.Default()
	}
	loop := &RelayLoop{
		Store: store, Client: client, Runner: runner, Encoder: encoder, Logger: logger,
		ReadOnly: NewReadOnlyDispatcher(store, ""), commandBySession: make(map[string]string),
		usageContextBySession: make(map[string]usageContext), eventWake: make(chan struct{}, 1),
		inFlightSends: make(map[string]struct{}),
	}
	if runner != nil {
		runner.SetEventSinkResult(loop.enqueueCanonicalEventResult)
		runner.SetModeInfoSink(loop.enqueueModeInfo)
	}
	return loop
}

// enqueueModeInfo 是 runner mode 目录的本机出口（v0.8.5 §3.4）：把会话级
// mode 快照异步上行到 Relay。上行失败只记录日志，不阻断 start/setMode 命令
// 兑现（目录下次同步会再覆盖）；commandCtx 失效时用短超时上下文兜底。
func (l *RelayLoop) enqueueModeInfo(sessionID string, info adapter.SessionModeInfo, agentPreset string) {
	if l.Client == nil || strings.TrimSpace(sessionID) == "" {
		return
	}
	modes := make([]SessionModeItem, 0, len(info.AvailableModes))
	for _, mode := range info.AvailableModes {
		modes = append(modes, SessionModeItem{
			ID: mode.ID, Name: mode.Name, Description: mode.Description,
		})
	}
	go func() {
		ctx := context.Background()
		if l.commandCtx != nil {
			ctx = l.commandCtx
		}
		if err := l.Client.SyncSessionModes(ctx, sessionID, info.CurrentModeID, agentPreset, modes); err != nil {
			if l.Logger != nil {
				l.Logger.Warn("sync session modes failed", "session", sessionID, "error", err)
			}
		}
	}()
}

// RunWithRetry 保持每次只有一条真实 SSE 连接，并使用有界指数退避重连。
// 在身份撤销、协议不兼容等不可恢复 HTTP 错误上直接退出，避免后台无意义重试。
func (l *RelayLoop) RunWithRetry(ctx context.Context) error {
	backoff := 100 * time.Millisecond
	for {
		err := l.runOnce(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		var httpErr *RelayHTTPError
		if errors.As(err, &httpErr) && (httpErr.Status == http.StatusForbidden || httpErr.Status == http.StatusUnauthorized || httpErr.Status == http.StatusConflict || httpErr.Status == http.StatusUpgradeRequired) {
			return err
		}
		// v0.6 残余项收口：配置了 Terminal 签名后，签名类协议错误由 Relay 以 400 +
		// 稳定错误码返回（SIGNATURE_INVALID/NONCE_REUSED/TIMESTAMP_EXPIRED/
		// KEY_UNKNOWN_OR_REVOKED/SIGNATURE_REQUIRED）。这类失败是密钥供给、时钟或
		// 重放状态的确定性故障，重试不可能自愈；继续退避重试只会掩盖配置错误。
		// 因此签名模式下立即退出并保留原始错误；未配置签名的 bearer 路径行为不变。
		if l.Client != nil && l.Client.Signer != nil && errors.As(err, &httpErr) && IsTerminalAuthErrorCode(httpErr.Code) {
			return err
		}
		l.Logger.Warn("daemon relay reconnect deferred", "error", err, "backoff_ms", backoff.Milliseconds())
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
		if backoff < 5*time.Second {
			backoff *= 2
		}
	}
}

// adoptTerminalIdentity 登记本次 hello 协商的 Terminal 身份。delivery_seq 是 Terminal
// 局部序号：重新配对会更换 Terminal 身份，沿用旧身份的游标会让 SSE 以过大的
// after_delivery_seq 重放并静默跳过新身份的全部投递，因此换身份时必须先清零游标。
func (l *RelayLoop) adoptTerminalIdentity(helloTerminalID string) error {
	previousTerminalID, prevErr := l.Store.Get("terminal_id")
	if prevErr == nil && strings.TrimSpace(previousTerminalID) != "" &&
		previousTerminalID != helloTerminalID {
		if err := l.Store.ResetRelayDeliveryCursor(); err != nil {
			return err
		}
		l.Logger.Warn("relay terminal identity changed; delivery cursor reset",
			"previous_terminal_id", previousTerminalID)
	}
	return l.Store.Set("terminal_id", helloTerminalID)
}

// ensureStartupSessionRecovery 每进程最多成功声明一次「进程已重启」。Relay 侧
// 收口幂等，但成功后重复往返没有意义；返回 error 只表示本次未完成，调用方
// 下一次 runOnce 重试，失败不阻塞命令主循环。
func (l *RelayLoop) ensureStartupSessionRecovery(ctx context.Context) error {
	if l.sessionRecoveryDone {
		return nil
	}
	if err := l.Client.RecoverSessions(ctx); err != nil {
		return err
	}
	l.sessionRecoveryDone = true
	return nil
}

func (l *RelayLoop) runOnce(ctx context.Context) error {
	if l.Store == nil || l.Client == nil || l.Runner == nil {
		return errors.New("relay loop dependencies missing")
	}
	hello, err := l.Client.Hello(ctx, nonEmpty(l.DaemonVersion, "agent-sessions-daemon"), nonEmpty(l.Hostname, "localhost"), nonEmpty(l.Platform, "unknown"), l.Capabilities)
	if err != nil {
		return err
	}
	if err := l.adoptTerminalIdentity(hello.TerminalID); err != nil {
		return err
	}
	if err := l.Client.Heartbeat(ctx); err != nil {
		return err
	}
	// hello 会在同一进程的网络重连中重复发送，不能作为进程启动信号；进程级
	// 「上一进程已死亡」声明由这里的一次性清扫端点承载。
	if err := l.ensureStartupSessionRecovery(ctx); err != nil {
		l.Logger.Warn("daemon startup session recovery failed; retrying next relay loop", "error", err)
	}
	// hello/heartbeat 成功说明 Relay 可达：自动恢复上一轮因瞬态故障转入 failed 的事件。
	// 确定性毒丸（RELAY_REJECTED_PERMANENT）不参与自动恢复，只能显式全量恢复。
	if recovered, recoverErr := l.Store.RequeueTransientFailedRelayEvents(); recoverErr != nil {
		return recoverErr
	} else if recovered > 0 {
		l.Logger.Info("daemon event outbox auto recovery", "requeued", recovered)
	}
	// delivery cursor 已跳过已落盘命令。进程重启后先收敛本地 pending 状态，不能只等待 SSE
	// 重放，否则 started 命令会永久滞留，或依赖下一条无关命令才恢复。
	if err := l.processPending(ctx); err != nil {
		return err
	}
	if err := l.flushOutboxes(ctx); err != nil {
		return err
	}
	l.commandCtxMu.Lock()
	l.commandCtx = ctx
	l.commandCtxMu.Unlock()
	defer func() {
		l.commandCtxMu.Lock()
		if l.commandCtx == ctx {
			l.commandCtx = nil
		}
		l.commandCtxMu.Unlock()
	}()
	cursor, err := l.Store.RelayDeliveryCursor()
	if err != nil {
		return err
	}
	// SSE 长连接期间仍要发送 heartbeat 和清空异步 Adapter event outbox。stream 退出时取消
	// 同一个 child context，避免留下读取 goroutine 或半开的 HTTP body。
	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	streamResult := make(chan error, 1)
	go func() {
		streamResult <- l.Client.Stream(streamCtx, cursor, l.handleDelivery)
	}()
	interval := time.Duration(hello.HeartbeatIntervalSeconds) * time.Second
	if interval <= 0 {
		interval = 15 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case err := <-streamResult:
			return err
		case <-ticker.C:
			if err := l.Client.Heartbeat(ctx); err != nil {
				return err
			}
			if err := l.flushOutboxes(ctx); err != nil {
				return err
			}
		case <-l.eventWake:
			if err := l.flushOutboxes(ctx); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (l *RelayLoop) handleDelivery(ctx context.Context, delivery RelayDelivery) error {
	command := delivery.Command
	command.DeliverySeq = delivery.DeliverySeq
	inserted, err := l.Store.RecordRelayCommand(command)
	if err != nil {
		return err
	}
	// 已持久化的重复 delivery 只重放协议回执和本机 pending 状态。不能用当前 capability
	// 重新解释一个已经收敛的历史命令，更不能覆盖其终态。
	if !inserted {
		if err := l.Client.Ack(ctx, command.CommandID, command.DeliverySeq, "received", ""); err != nil {
			return err
		}
		return l.processPending(l.commandExecutionContext(ctx))
	}
	// 专用 SSE 已由 Relay 按 Terminal 隔离，但 Daemon 仍要把 payload 当作不可信输入：
	// 只有本机 hello 绑定的 Terminal、非空 Workspace 和已声明 capability 才能进入执行器。
	// 先落盘再拒绝可推进 cursor 并留下可审计、幂等的 rejected receipt，不能让恶意 delivery
	// 反复触发 Provider 或无限重连。
	if err := l.validateLocalDelivery(command); err != nil {
		return l.rejectDelivery(ctx, command, CommandErrorCode(err))
	}
	// 即使是重复 delivery，received ack 也可安全重放，帮助 Relay 收敛至少一次投递状态。
	if err := l.Client.Ack(ctx, command.CommandID, command.DeliverySeq, "received", ""); err != nil {
		return err
	}
	return l.processPending(l.commandExecutionContext(ctx))
}

func (l *RelayLoop) commandExecutionContext(fallback context.Context) context.Context {
	l.commandCtxMu.RLock()
	ctx := l.commandCtx
	l.commandCtxMu.RUnlock()
	if ctx != nil {
		return ctx
	}
	return fallback
}

func (l *RelayLoop) validateLocalDelivery(command RelayCommand) error {
	if l == nil || l.Store == nil {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("daemon store unavailable"))
	}
	localTerminalID, err := l.Store.Get("terminal_id")
	if err != nil || localTerminalID == "" || command.TargetTerminalID != localTerminalID {
		return newCommandExecutionError(protocol.ErrScopeDenied, errors.New("terminal target mismatch"))
	}
	if strings.TrimSpace(command.WorkspaceID) == "" && command.Kind != "workspace.sync_dsh" {
		return newCommandExecutionError(protocol.ErrWorkspacePathDenied, errors.New("workspace id missing"))
	}
	if !l.declaresCapability(command.Kind) {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("command capability not declared"))
	}
	return nil
}

func (l *RelayLoop) rejectDelivery(ctx context.Context, command RelayCommand, errorCode string) error {
	if err := l.Store.MarkRelayCommandRejecting(command.CommandID, errorCode); err != nil {
		return err
	}
	return l.replayRejected(ctx, command.CommandID, command.DeliverySeq, errorCode)
}

func (l *RelayLoop) replayRejected(ctx context.Context, commandID string, deliverySeq int64, errorCode string) error {
	if err := l.Client.Ack(ctx, commandID, deliverySeq, "rejected", errorCode); err != nil {
		return err
	}
	return l.Store.MarkRelayCommandResult(commandID, "rejected", errorCode)
}

func (l *RelayLoop) declaresCapability(kind string) bool {
	required := capabilityForCommand(kind)
	if required == "" {
		return false
	}
	for _, capability := range l.Capabilities {
		if strings.TrimSpace(capability) == required {
			return true
		}
	}
	return false
}

func capabilityForCommand(kind string) string {
	switch kind {
	case "session.start":
		return "start"
	case "session.send":
		return "send"
	case "session.resume":
		return "resume"
	case "session.abort":
		return "abort"
	case "session.kill":
		return "kill"
	case "session.model_select":
		return "model_select"
	case "session.effort_select":
		return "effort_select"
	case "workspace.create":
		return "workspace_create"
	case "workspace.sync_dsh":
		return "dsh_workspace_sync"
	case "session.import_dsh":
		return "dsh_session_import"
	case "file.tree", "file.read", "code.read":
		return "file_read"
	case "git.status", "git.changes", "git.diff":
		return "git_read"
	default:
		return ""
	}
}

func (l *RelayLoop) processPending(ctx context.Context) error {
	l.processMu.Lock()
	defer l.processMu.Unlock()
	commands, err := l.Store.PendingRelayCommands()
	if err != nil {
		return err
	}
	for _, command := range commands {
		startedThisPass := false
		if command.Status == "rejecting" {
			if err := l.replayRejected(ctx, command.CommandID, command.DeliverySeq, command.ErrorCode); err != nil {
				return err
			}
			continue
		}
		if command.Status == "received" {
			// runOnce 会在建立 SSE 前主动恢复本地 pending。这里必须重新执行本机目标与 capability
			// 校验，否则 rejected 响应丢失留下的 received 行会在重启后绕过 handleDelivery。
			if err := l.validateLocalDelivery(command); err != nil {
				if rejectErr := l.rejectDelivery(ctx, command, CommandErrorCode(err)); rejectErr != nil {
					return rejectErr
				}
				continue
			}
			// 先持久化 starting，再向 Relay 发送 started。这样崩溃窗口只会留下可重放的
			// started 回执，不会在重启后把同一个 command_id 再次交给 Provider。
			if err := l.Store.MarkRelayCommandStarting(command.CommandID); err != nil {
				return err
			}
			command.Status = "starting"
		}
		if command.Status == "starting" {
			if err := l.Client.Ack(ctx, command.CommandID, command.DeliverySeq, "started", ""); err != nil {
				// stale lease/target 等拒绝需回写 rejected；Relay 允许该 ack 不经过旧 fence。
				var httpErr *RelayHTTPError
				if errors.As(err, &httpErr) && httpErr.Status == http.StatusConflict {
					if rejectErr := l.Client.Ack(ctx, command.CommandID, command.DeliverySeq, "rejected", "TARGET_STALE"); rejectErr != nil {
						return rejectErr
					}
					if markErr := l.Store.MarkRelayCommandResult(command.CommandID, "rejected", "TARGET_STALE"); markErr != nil {
						return markErr
					}
					continue
				}
				return err
			}
			if err := l.Store.MarkRelayCommandStarted(command.CommandID); err != nil {
				return err
			}
			command.Status = "started"
			startedThisPass = true
		}
		if command.ResultStatus != "" {
			continue
		}
		if command.Kind == "session.import_dsh" {
			// 会话按需导入没有 Session lease；只允许 home Terminal 在本机已确认工作区下
			// 扫描 JSONL 元数据并回传 opaque Relay session ids。
			status, errorCode := "succeeded", ""
			var sessionIDs []string
			if l.WorkspaceManager == nil {
				status, errorCode = "failed", protocol.ErrCapabilityUnsupported
			} else {
				var payload struct {
					WorkspaceID string `json:"workspace_id"`
				}
				if err := json.Unmarshal([]byte(command.PayloadJSON), &payload); err != nil || strings.TrimSpace(payload.WorkspaceID) == "" {
					status, errorCode = "failed", protocol.ErrWorkspacePathDenied
				} else {
					imported, importErr := l.WorkspaceManager.ImportDSHSessions(ctx, payload.WorkspaceID, l.Store)
					if importErr != nil {
						status, errorCode = "failed", CommandErrorCode(importErr)
						l.Logger.Warn("daemon dsh session import failed", "command", command.CommandID, "error_code", errorCode)
					} else {
						for _, item := range imported {
							sessionIDs = append(sessionIDs, item.RelaySessionID)
						}
					}
				}
			}
			receipt, resolveErr := l.Client.ResolveDSHImport(ctx, command.CommandID, command.DeliverySeq, sessionIDs, status, errorCode)
			if resolveErr != nil {
				return resolveErr
			}
			if err := l.Store.MarkRelayCommandResult(command.CommandID, receipt.Status, receipt.ErrorCode); err != nil {
				return err
			}
			continue
		}
		if command.Kind == "workspace.sync_dsh" {
			// DSH 同步命令没有 Session lease；只在本机授权根内扫描并确认已有工作区，
			// 结果必须走专用 dsh-workspace-result 通道。
			status, errorCode := "succeeded", ""
			var candidates []DSHWorkspaceCandidate
			if l.WorkspaceManager == nil {
				status, errorCode = "failed", protocol.ErrCapabilityUnsupported
			} else {
				scanner := NewDSHWorkspaceScanner(l.WorkspaceManager.Root())
				scannedCandidates, summary, scanErr := scanner.Scan(ctx)
				if scanErr != nil {
					status, errorCode = "failed", CommandErrorCode(scanErr)
					l.Logger.Warn("daemon dsh workspace scan failed", "command", command.CommandID, "error_code", errorCode)
				} else {
					if summary.LimitReached {
						status, errorCode = "failed", protocol.ErrWorkspacePathDenied
					} else {
						candidates = scannedCandidates
					}
				}
			}
			receipt, resolveErr := l.Client.ResolveDSHWorkspace(ctx, command.CommandID, command.DeliverySeq, candidates, status, errorCode)
			if resolveErr != nil {
				return resolveErr
			}
			l.confirmDSHWorkspaceCandidates(ctx, command.CommandID, candidates, receipt)
			if err := l.Store.MarkRelayCommandResult(command.CommandID, receipt.Status, receipt.ErrorCode); err != nil {
				return err
			}
			continue
		}
		if command.Kind == "workspace.create" {
			// 工作区命令没有 Session lease；名称解析、mkdir、git init 和本机确认
			// 全部在授权根边界内完成，结果必须走专用回执通道。
			status, errorCode := "succeeded", ""
			var confirmed ConfirmedWorkspace
			var err error
			if l.WorkspaceManager == nil {
				status, errorCode = "failed", protocol.ErrCapabilityUnsupported
			} else {
				var payload WorkspaceCreatePayload
				payload, err = DecodeWorkspaceCreatePayload(command.PayloadJSON, command.WorkspaceID)
				if err == nil {
					confirmed, err = l.WorkspaceManager.Create(ctx, command.WorkspaceID, payload.Name)
				}
				if err != nil {
					status, errorCode = "failed", WorkspaceCreateErrorCode(err)
					l.Logger.Warn("daemon workspace creation failed", "command", command.CommandID, "error_code", errorCode)
				}
			}
			receipt, resolveErr := l.Client.ResolveWorkspace(ctx, command.CommandID, command.DeliverySeq,
				command.WorkspaceID, confirmed.Root, status, errorCode)
			if resolveErr != nil {
				return resolveErr
			}
			if err := l.Store.MarkRelayCommandResult(command.CommandID, receipt.Status, receipt.ErrorCode); err != nil {
				return err
			}
			continue
		}
		if command.Kind == "session.send" && startedThisPass {
			// Send is the only command that can hold the Provider for an entire
			// generation. Register it before returning to the SSE reader so a
			// following session.abort can be consumed immediately.
			if l.claimInFlightSend(command.CommandID) {
				go l.executeSendAsync(ctx, command)
			}
			continue
		}
		if command.Kind == "session.send" && l.isInFlightSend(command.CommandID) {
			continue
		}
		if command.Status == "started" && !startedThisPass {
			// Daemon 在已确认 started 后崩溃时，不知道本地 Provider 是否仍活着或是否已部分执行。
			// 为避免 at-least-once delivery 把同一 command 再次交给 Provider，这里 fail-closed，
			// 由客户端根据明确失败状态重新创建带新 lease/idempotency key 的动作。
			if err := l.resolveAndPersist(ctx, command, "failed", "DAEMON_RESTART_RECOVERY"); err != nil {
				return err
			}
			continue
		}
		if err := l.executeAndResolve(ctx, command); err != nil {
			return err
		}
	}
	return l.flushOutboxes(ctx)
}

func (l *RelayLoop) claimInFlightSend(commandID string) bool {
	l.inFlightMu.Lock()
	defer l.inFlightMu.Unlock()
	if _, exists := l.inFlightSends[commandID]; exists {
		return false
	}
	l.inFlightSends[commandID] = struct{}{}
	return true
}

func (l *RelayLoop) isInFlightSend(commandID string) bool {
	l.inFlightMu.Lock()
	defer l.inFlightMu.Unlock()
	_, exists := l.inFlightSends[commandID]
	return exists
}

func (l *RelayLoop) releaseInFlightSend(commandID string) {
	l.inFlightMu.Lock()
	delete(l.inFlightSends, commandID)
	l.inFlightMu.Unlock()
}

// executeSendAsync is deliberately bound to the active RelayLoop context. On a
// disconnect the context is cancelled, so a stale Provider send cannot outlive
// the stream that accepted it. A restart sees the durable started command and
// follows the existing fail-closed recovery rule instead of retrying a send.
func (l *RelayLoop) executeSendAsync(ctx context.Context, command RelayCommand) {
	defer l.releaseInFlightSend(command.CommandID)
	if err := l.executeAndResolve(l.commandExecutionContext(ctx), command); err != nil {
		l.Logger.Warn("daemon async send execution failed", "command", command.CommandID, "error", err)
	}
}

func (l *RelayLoop) executeAndResolve(ctx context.Context, command RelayCommand) error {
	var err error
	if isReadOnlyCommandKind(command.Kind) {
		var event adapter.Event
		if l.ReadOnly == nil {
			// 手工构造 RelayLoop 的旧调用方可能尚未注入 dispatcher。缺失本机安全边界时
			// 必须 fail-closed，而不能 panic 或退回到未受限的文件/Git 执行路径。
			err = newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("read-only dispatcher unavailable"))
		} else if isWebReadTransportRequest(command.PayloadJSON) {
			var envelope WebReadResponseEnvelope
			envelope, err = l.ReadOnly.ExecuteWeb(ctx, command, l.WebRead)
			if err == nil {
				err = l.Client.UploadWebReadResponse(ctx, command.CommandID, command.DeliverySeq, envelope)
			}
		} else {
			event, err = l.ReadOnly.Execute(ctx, command)
			if err == nil {
				err = l.enqueueCommandEvent(command, event)
			}
		}
	} else {
		l.bindCommand(command.SessionID, command.CommandID)
		l.bindUsageContext(command)
		err = l.Runner.ConsumeCommand(ctx, Command{
			RequestID: command.CommandID, Kind: command.Kind, PayloadJSON: command.PayloadJSON,
			WorkspaceID: command.WorkspaceID,
		})
	}
	status, errorCode := "succeeded", ""
	if err != nil {
		status, errorCode = "failed", CommandErrorCode(err)
		l.Logger.Warn("daemon command execution failed", "command", command.CommandID, "kind", command.Kind, "error", err)
	}
	if err := l.flushOutboxes(ctx); err != nil {
		return err
	}
	return l.resolveAndPersist(ctx, command, status, errorCode)
}

// resolveAndPersist 以 Relay receipt 为本机最终状态。若 Relay 已提交 result、但 HTTP 响应在
// 网络中丢失，重启重放会返回已有终态；使用原始请求会错误地把成功覆盖为恢复失败。
func (l *RelayLoop) resolveAndPersist(ctx context.Context, command RelayCommand, requestedStatus, requestedErrorCode string) error {
	receipt, err := l.Client.Resolve(ctx, command.CommandID, command.DeliverySeq, requestedStatus, requestedErrorCode)
	if err != nil {
		return err
	}
	return l.Store.MarkRelayCommandResult(command.CommandID, receipt.Status, receipt.ErrorCode)
}

// validRelayResultStatus 判定 Relay 回显的收据终态是否合法。Relay 对已收敛命令的
// 重复 result 请求回显的是命令当前权威终态（含 cancelled/expired——终端离线或 lease
// 失效时 Relay 会先收敛），而不是本次请求提交的状态；Daemon 必须以回显状态落盘并
// 停止重试，否则 started 命令会在重启后永久卡在重连循环，阻塞后续所有命令投递。
func validRelayResultStatus(status string) bool {
	switch status {
	case "succeeded", "failed", "rejected", "cancelled", "expired":
		return true
	default:
		return false
	}
}

// isWebReadTransportRequest 只按 envelope 的公开算法标识选择 Web 分支；真正的字段、AAD 和
// 密文认证仍由 ExecuteWeb 完成。无法识别的数据按既有 P2 fixture 路径处理，不产生明文降级。
func isWebReadTransportRequest(payload string) bool {
	var marker struct {
		Alg string `json:"alg"`
	}
	return json.Unmarshal([]byte(payload), &marker) == nil && marker.Alg == webReadAlgorithm
}

// enqueueCommandEvent 把只读结果送入同一条 canonical event outbox。没有 EventEncoder 时不能把
// 内存结果当作已回写成功；生产 Daemon 必须注入真实 E2EE encoder，fixture 只上传哈希 envelope。
func (l *RelayLoop) enqueueCommandEvent(command RelayCommand, event adapter.Event) error {
	if l.Encoder == nil {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("event encoder unavailable"))
	}
	if event.CreatedAtUnixMS <= 0 {
		event.CreatedAtUnixMS = time.Now().UnixMilli()
	}
	envelope, err := l.Encoder.Encode(command.SessionID, event)
	if err != nil {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, err)
	}
	if err := l.Store.EnqueueRelayEvent(RelayEvent{
		EventID: relayEventID(command.SessionID, event), CommandID: command.CommandID, SessionID: command.SessionID,
		EventType: relayEventType(event.Type), TerminalStatus: terminalStatusForEvent(event), EnvelopeJSON: envelope,
		CreatedAtUnixMS: event.CreatedAtUnixMS,
	}); err != nil {
		return err
	}
	select {
	case l.eventWake <- struct{}{}:
	default:
	}
	return nil
}

func (l *RelayLoop) bindCommand(sessionID, commandID string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.commandBySession[sessionID] = commandID
}

func (l *RelayLoop) bindUsageContext(command RelayCommand) {
	env, err := parseEnvelope(command.PayloadJSON)
	if err != nil {
		return
	}
	provider := strings.TrimSpace(env.provider())
	model := strings.TrimSpace(env.model())
	if provider == "" && model == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	current := l.usageContextBySession[command.SessionID]
	if provider != "" {
		current.Provider = provider
	}
	if model != "" {
		current.Model = model
	}
	l.usageContextBySession[command.SessionID] = current
}

func (l *RelayLoop) enqueueCanonicalEvent(sessionID string, event adapter.Event) {
	if err := l.enqueueCanonicalEventResult(sessionID, event); err != nil {
		l.Logger.Warn("daemon canonical event enqueue failed", "event_type", event.Type, "error", err)
	}
}

// relayEventID 为回放事件生成跨重启稳定的 outbox 主键；普通实时事件继续使用随机 ID。
// 回放序号本身不含 DSH 正文或路径，哈希只用于 Relay 幂等，不进入事件正文。
func relayEventID(sessionID string, event adapter.Event) string {
	if event.ReplayOrdinal > 0 {
		return "evt-replay-" + replaySourceKey(sessionID, event.ReplayOrdinal)
	}
	return id.New("evt")
}

// enqueueCanonicalEventResult 把事件写入本机 outbox，并向回放调用方返回提交结果。
// 回放 checkpoint 只能在此函数成功后推进；失败时保留 loading 状态，下一次恢复会重新回放。
func (l *RelayLoop) enqueueCanonicalEventResult(sessionID string, event adapter.Event) error {
	l.mu.RLock()
	commandID := l.commandBySession[sessionID]
	usageCtx := l.usageContextBySession[sessionID]
	l.mu.RUnlock()
	if event.Type == adapter.EventUsage {
		if usage, ok := relayUsageFromAdapterEvent(sessionID, commandID, usageCtx, event); ok {
			if err := l.Store.EnqueueRelayUsage(usage); err != nil {
				return err
			} else {
				select {
				case l.eventWake <- struct{}{}:
				default:
				}
			}
		}
	}
	createdAt := event.CreatedAtUnixMS
	if createdAt <= 0 {
		// Events emitted by older adapters may not carry a timestamp. Keep the
		// value unknown instead of using Relay receipt time as a fake send time.
		createdAt = 0
	}
	if l.Encoder == nil {
		return errors.New("event encoder unavailable")
	}
	if commandID == "" {
		return errors.New("event command correlation unavailable")
	}
	envelope, err := l.Encoder.Encode(sessionID, event)
	if err != nil {
		return err
	}
	// 编码器契约：空 envelope 且无错误表示该事件类型不进入账号时间线
	//（本地开发编码器据此过滤 delta/usage 等噪音）。
	if strings.TrimSpace(envelope) == "" {
		return nil
	}
	if err := l.Store.EnqueueRelayEvent(RelayEvent{
		EventID: relayEventID(sessionID, event), CommandID: commandID, SessionID: sessionID,
		EventType: relayEventType(event.Type), TerminalStatus: terminalStatusForEvent(event), EnvelopeJSON: envelope,
		CreatedAtUnixMS: createdAt,
	}); err != nil {
		return err
	}
	select {
	case l.eventWake <- struct{}{}:
	default:
	}
	return nil
}

func (l *RelayLoop) flushOutboxes(ctx context.Context) error {
	if err := l.flushEvents(ctx); err != nil {
		return err
	}
	return l.flushUsages(ctx)
}

func (l *RelayLoop) flushEvents(ctx context.Context) error {
	events, err := l.Store.PendingRelayEvents()
	if err != nil {
		return err
	}
	for _, event := range events {
		if err := l.Client.UploadEvent(ctx, event); err != nil {
			// 4xx（除 429）是 Relay 对该事件内容的确定性拒绝：重试永远不会成功。
			// 按毒丸处理：立即转入 failed 并保留脱敏原因，不占用退避队列；
			// 只有显式全量恢复才会重新入队。其余错误保持可安全重试。
			var httpErr *RelayHTTPError
			if errors.As(err, &httpErr) && httpErr.Status >= 400 && httpErr.Status < 500 && httpErr.Status != http.StatusTooManyRequests {
				l.Logger.Warn("daemon event failed permanently: relay rejected payload",
					"event_id", event.EventID, "session_id", event.SessionID,
					"event_type", event.EventType, "status", httpErr.Status)
				if failErr := l.Store.MarkRelayEventFailedNow(event.EventID, relayEventPermanentReject); failErr != nil {
					return failErr
				}
				continue
			}
			// 瞬态失败（网络断开、5xx、超时）：记录尝试次数与指数退避后交给既有重连路径。
			// 事件保持 pending，达到重试上限后转入 failed 等待恢复入口，绝不静默删除。
			if attemptErr := l.Store.MarkRelayEventAttempt(event.EventID, sanitizeRelayUploadError(err)); attemptErr != nil {
				l.Logger.Warn("daemon event attempt accounting failed", "event_id", event.EventID, "error", attemptErr)
			}
			return err
		}
		if err := l.Store.MarkRelayEventDelivered(event.EventID); err != nil {
			return err
		}
	}
	return nil
}

// sanitizeRelayUploadError 把上传失败压缩为脱敏错误分类，只写入 outbox 的 last_error。
// 不记录 body、envelope 或原始错误文本，防止密文或环境细节进入本地状态文件。
func sanitizeRelayUploadError(err error) string {
	var httpErr *RelayHTTPError
	switch {
	case errors.As(err, &httpErr):
		return fmt.Sprintf("RELAY_HTTP_%d", httpErr.Status)
	case errors.Is(err, context.DeadlineExceeded):
		return "RELAY_TIMEOUT"
	default:
		return "RELAY_NETWORK"
	}
}

func (l *RelayLoop) flushUsages(ctx context.Context) error {
	usages, err := l.Store.PendingRelayUsages()
	if err != nil {
		return err
	}
	for _, usage := range usages {
		if err := l.Client.UploadUsage(ctx, usage); err != nil {
			// 与 flushEvents 相同的毒丸语义：确定性 4xx 重试无意义，丢弃并告警。
			var httpErr *RelayHTTPError
			if errors.As(err, &httpErr) && httpErr.Status >= 400 && httpErr.Status < 500 && httpErr.Status != http.StatusTooManyRequests {
				l.Logger.Warn("daemon usage dropped: relay permanently rejected payload",
					"usage_key", usage.UsageKey, "status", httpErr.Status)
				if dropErr := l.Store.MarkRelayUsageDelivered(usage.UsageKey); dropErr != nil {
					return dropErr
				}
				continue
			}
			return err
		}
		if err := l.Store.MarkRelayUsageDelivered(usage.UsageKey); err != nil {
			return err
		}
	}
	return nil
}

func relayUsageFromAdapterEvent(sessionID, commandID string, ctx usageContext, event adapter.Event) (RelayUsage, bool) {
	input, inputOK := int64FromPayload(event.Payload, "input_tokens", "inputTokens")
	output, outputOK := int64FromPayload(event.Payload, "output_tokens", "outputTokens")
	cacheRead, _ := int64FromPayload(event.Payload, "cache_read_tokens", "cacheReadTokens")
	cacheWrite, _ := int64FromPayload(event.Payload, "cache_write_tokens", "cacheWriteTokens", "cache_creation_tokens", "cacheCreationTokens")
	if !inputOK && !outputOK && cacheRead == 0 && cacheWrite == 0 {
		return RelayUsage{}, false
	}
	if input < 0 || output < 0 || cacheRead < 0 || cacheWrite < 0 {
		return RelayUsage{}, false
	}
	provider := strings.TrimSpace(stringFromPayload(event.Payload, "provider"))
	if provider == "" {
		provider = strings.TrimSpace(ctx.Provider)
	}
	if provider == "" {
		return RelayUsage{}, false
	}
	model := strings.TrimSpace(stringFromPayload(event.Payload, "model"))
	if model == "" {
		model = strings.TrimSpace(ctx.Model)
	}
	ttft := ttftFromPayload(event.Payload)
	throughput := throughputFromPayload(event.Payload, output)
	contextWindow, _ := int64FromPayload(event.Payload, "context_window_tokens", "contextWindowTokens", "contextWindow")
	if contextWindow < 0 {
		return RelayUsage{}, false
	}
	keySuffix := id.New("usage")
	if strings.TrimSpace(commandID) != "" {
		keySuffix = commandID + ":" + keySuffix
	}
	return RelayUsage{
		UsageKey:            "daemon:" + sessionID + ":" + keySuffix,
		SessionID:           sessionID,
		Provider:            provider,
		Model:               model,
		UTCDay:              time.Now().UTC().Format("2006-01-02"),
		InputTokens:         input,
		OutputTokens:        output,
		CacheReadTokens:     cacheRead,
		CacheWriteTokens:    cacheWrite,
		ContextWindowTokens: contextWindow,
		TTFTMS:              ttft,
		DecodeThroughput:    throughput,
	}, true
}

func int64FromPayload(payload map[string]any, keys ...string) (int64, bool) {
	for _, key := range keys {
		switch value := payload[key].(type) {
		case int:
			return int64(value), true
		case int64:
			return value, true
		case int32:
			return int64(value), true
		case float64:
			if value == float64(int64(value)) {
				return int64(value), true
			}
		case json.Number:
			if parsed, err := value.Int64(); err == nil {
				return parsed, true
			}
		}
	}
	return 0, false
}

func float64FromPayload(payload map[string]any, keys ...string) (float64, bool) {
	for _, key := range keys {
		switch value := payload[key].(type) {
		case float64:
			return value, true
		case float32:
			return float64(value), true
		case int:
			return float64(value), true
		case int64:
			return float64(value), true
		case json.Number:
			if parsed, err := value.Float64(); err == nil {
				return parsed, true
			}
		}
	}
	return 0, false
}

func stringFromPayload(payload map[string]any, key string) string {
	value, _ := payload[key].(string)
	return value
}

func timingPayload(payload map[string]any) map[string]any {
	if timing, ok := payload["timing"].(map[string]any); ok {
		return timing
	}
	return payload
}

func ttftFromPayload(payload map[string]any) *int64 {
	if direct, ok := int64FromPayload(payload, "ttft_ms", "ttftMs"); ok && direct >= 0 {
		return &direct
	}
	timing := timingPayload(payload)
	stepStart, hasStart := int64FromPayload(timing, "step_start_time", "stepStartTime")
	firstToken, hasFirst := int64FromPayload(timing, "first_token_time", "firstTokenTime")
	if !hasStart || !hasFirst {
		return nil
	}
	value := firstToken - stepStart
	if value < 0 {
		value = 0
	}
	return &value
}

func throughputFromPayload(payload map[string]any, outputTokens int64) *float64 {
	if direct, ok := float64FromPayload(payload, "decode_throughput", "decodeThroughput", "tokens_per_second", "tokensPerSecond"); ok && direct > 0 {
		return &direct
	}
	timing := timingPayload(payload)
	firstToken, hasFirst := int64FromPayload(timing, "first_token_time", "firstTokenTime")
	completed, hasCompleted := int64FromPayload(timing, "completed_time", "completedTime")
	if !hasFirst || !hasCompleted || outputTokens <= 0 {
		return nil
	}
	decodeMS := completed - firstToken
	if decodeMS <= 0 {
		return nil
	}
	value := float64(outputTokens) / (float64(decodeMS) / 1000)
	return &value
}

func relayEventType(value adapter.EventType) string {
	switch value {
	case adapter.EventTurnStarted:
		return "turn.started"
	case adapter.EventUserMessage:
		return "user.message"
	case adapter.EventMessageDelta:
		return "message.delta"
	case adapter.EventThoughtDelta:
		// v0.8.4（ADR-015 §5）：raw reasoning 增量走独立 thought 通道，
		// 与 assistant answer 分开建模，绝不并入 message.delta。
		return "message.thought_delta"
	case adapter.EventTurnPhase:
		// v0.8.4（ADR-015 §3）：回合阶段投影；旧客户端忽略未知事件类型，
		// 仍按 message.completed/turn.completed 正确关闭 streaming 状态。
		return "turn.phase"
	case adapter.EventSessionActivity:
		// session 级聚合镜像（最新 active turn 的 phase），供粗粒度消费方。
		return "session.activity"
	case adapter.EventMessageCompleted:
		return "message.completed"
	case adapter.EventTurnCompleted:
		return "turn.completed"
	case adapter.EventSessionAborted:
		return "session.aborted"
	case adapter.EventToolCall:
		return "tool.call"
	case adapter.EventToolResult:
		return "tool.result"
	case adapter.EventPermissionRequest:
		// v0.8.2：权限请求/决策是独立事件类型（openapi event enum 已定义
		// permission.request/permission.decision），不能落入 command.updated 兜底，
		// 否则移动端无法识别挂起的审批请求。
		return "permission.request"
	case adapter.EventPermissionDecision:
		return "permission.decision"
	case adapter.EventUsage:
		return "usage.updated"
	case adapter.EventFileChange:
		return "file.changed"
	default:
		return "command.updated"
	}
}

// terminalStatusForEvent 只投影 Relay 所需的生命周期结果。Provider 的 stop_reason
// 保留在加密 envelope 内；未知原因按 stopped 关闭，避免中断回合一直显示为运行中。
func terminalStatusForEvent(event adapter.Event) string {
	if event.Type == adapter.EventSessionAborted {
		// Abort 成功本身就是非敏感的停止事实，Relay 可在不解密 payload 的
		// 前提下立即把会话投影为 stopped；后续 cancelled 终态只负责幂等收口。
		return "stopped"
	}
	if event.Type != adapter.EventTurnCompleted {
		return ""
	}
	reason, _ := event.Payload["stop_reason"].(string)
	switch strings.TrimSpace(reason) {
	case "session_idle", "status_idle", "end_turn", "completed", "complete", "idle":
		return "idle"
	default:
		return "stopped"
	}
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) != "" {
		return value
	}
	return fallback
}
