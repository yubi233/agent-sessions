package daemon

import (
	"bufio"
	"bytes"
	"context"
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
	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const daemonProtocolVersion = 1

// RelayClient 是 Daemon 到 Relay 的受限 REST + SSE 客户端。它只保存 bearer 在调用者提供的
// 配置中，不会记录到日志、report 或命令行输出。
type RelayClient struct {
	BaseURL     string
	AccessToken string
	HTTPClient  *http.Client
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
func (c *RelayClient) Hello(ctx context.Context, daemonVersion, hostname, platform string, capabilities []string) (RelayHello, error) {
	var out RelayHello
	err := c.postJSON(ctx, "/v1/daemon/hello", map[string]any{
		"protocol_version": daemonProtocolVersion,
		"daemon_version":   daemonVersion,
		"hostname":         hostname,
		"platform":         platform,
		"capabilities":     capabilities,
	}, &out)
	if err != nil {
		return RelayHello{}, err
	}
	if out.TerminalID == "" || out.ProtocolVersion == 0 || out.HeartbeatIntervalSeconds <= 0 {
		return RelayHello{}, errors.New("relay hello response incomplete")
	}
	return out, nil
}

func (c *RelayClient) Heartbeat(ctx context.Context) error {
	return c.postJSON(ctx, "/v1/daemon/heartbeat", map[string]any{"protocol_version": daemonProtocolVersion}, &struct{}{})
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
	return c.postJSON(ctx, "/v1/daemon/events", map[string]any{
		"protocol_version": daemonProtocolVersion, "event_id": event.EventID, "command_id": event.CommandID,
		"session_id": event.SessionID, "event_type": event.EventType, "envelope": envelope,
	}, &struct{}{})
}

// UploadUsage 只上传白名单整数计数与 UTC 日桶（ADR-010）。usage key 由 Daemon
// 对来源事件生成，重复上传返回同一 canonical receipt，不重复累加。
func (c *RelayClient) UploadUsage(ctx context.Context, usage RelayUsage) error {
	return c.postJSON(ctx, "/v1/daemon/usage/events", map[string]any{
		"usage_key": usage.UsageKey, "provider": usage.Provider, "utc_day": usage.UTCDay,
		"input_tokens": usage.InputTokens, "output_tokens": usage.OutputTokens,
		"cache_read_tokens": usage.CacheReadTokens, "cache_write_tokens": usage.CacheWriteTokens,
	}, &struct{}{})
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
	response, err := c.client().Do(req)
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
	if strings.TrimSpace(c.BaseURL) == "" || strings.TrimSpace(c.AccessToken) == "" {
		return errors.New("relay base URL or daemon credential missing")
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.AccessToken)
	req.Header.Set("Content-Type", "application/json")
	response, err := c.client().Do(req)
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

func (c *RelayClient) client() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{Timeout: 30 * time.Second}
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

// RelayLoop 把持久化接收、ack、Adapter 执行、终态和事件 outbox 串成最小可靠循环。
// 它刻意不读取/输出 Provider 正文，且任何网络失败都会留下可安全重试的本机记录。
type RelayLoop struct {
	Store    *Store
	Client   *RelayClient
	Runner   *SessionRunner
	ReadOnly *ReadOnlyDispatcher
	Encoder  EventEncoder
	// WebRead 只用于 browser -> Daemon -> browser 的临时密钥只读响应；它与 Provider event
	// encoder 分离，不能把浏览器文件结果塞进账号事件或复用共享 DEK。
	WebRead       *WebReadTransport
	DaemonVersion string
	Hostname      string
	Platform      string
	Capabilities  []string
	Logger        *slog.Logger

	mu               sync.RWMutex
	commandBySession map[string]string
	eventWake        chan struct{}
}

func NewRelayLoop(store *Store, client *RelayClient, runner *SessionRunner, encoder EventEncoder, logger *slog.Logger) *RelayLoop {
	if logger == nil {
		logger = slog.Default()
	}
	loop := &RelayLoop{
		Store: store, Client: client, Runner: runner, Encoder: encoder, Logger: logger,
		ReadOnly: NewReadOnlyDispatcher(store, ""), commandBySession: make(map[string]string), eventWake: make(chan struct{}, 1),
	}
	if runner != nil {
		runner.SetEventSink(loop.enqueueCanonicalEvent)
	}
	return loop
}

// RunWithRetry keeps one real SSE connection at a time and reconnects with bounded exponential backoff.
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

func (l *RelayLoop) runOnce(ctx context.Context) error {
	if l.Store == nil || l.Client == nil || l.Runner == nil {
		return errors.New("relay loop dependencies missing")
	}
	hello, err := l.Client.Hello(ctx, nonEmpty(l.DaemonVersion, "agent-sessions-daemon"), nonEmpty(l.Hostname, "localhost"), nonEmpty(l.Platform, "unknown"), l.Capabilities)
	if err != nil {
		return err
	}
	if err := l.Store.Set("terminal_id", hello.TerminalID); err != nil {
		return err
	}
	if err := l.Client.Heartbeat(ctx); err != nil {
		return err
	}
	// delivery cursor 已跳过已落盘命令。进程重启后先收敛本地 pending 状态，不能只等待 SSE
	// 重放，否则 started 命令会永久滞留，或依赖下一条无关命令才恢复。
	if err := l.processPending(ctx); err != nil {
		return err
	}
	if err := l.flushEvents(ctx); err != nil {
		return err
	}
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
			if err := l.flushEvents(ctx); err != nil {
				return err
			}
		case <-l.eventWake:
			if err := l.flushEvents(ctx); err != nil {
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
	if !inserted {
		return l.processPending(ctx)
	}
	return l.processPending(ctx)
}

func (l *RelayLoop) validateLocalDelivery(command RelayCommand) error {
	if l == nil || l.Store == nil {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("daemon store unavailable"))
	}
	localTerminalID, err := l.Store.Get("terminal_id")
	if err != nil || localTerminalID == "" || command.TargetTerminalID != localTerminalID {
		return newCommandExecutionError(protocol.ErrScopeDenied, errors.New("terminal target mismatch"))
	}
	if strings.TrimSpace(command.WorkspaceID) == "" {
		return newCommandExecutionError(protocol.ErrWorkspacePathDenied, errors.New("workspace id missing"))
	}
	if !l.declaresCapability(command.Kind) {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("command capability not declared"))
	}
	return nil
}

func (l *RelayLoop) rejectDelivery(ctx context.Context, command RelayCommand, errorCode string) error {
	if err := l.Client.Ack(ctx, command.CommandID, command.DeliverySeq, "rejected", errorCode); err != nil {
		return err
	}
	return l.Store.MarkRelayCommandResult(command.CommandID, "rejected", errorCode)
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
	case "file.tree", "file.read", "code.read":
		return "file_read"
	case "git.status", "git.changes", "git.diff":
		return "git_read"
	default:
		return ""
	}
}

func (l *RelayLoop) processPending(ctx context.Context) error {
	commands, err := l.Store.PendingRelayCommands()
	if err != nil {
		return err
	}
	for _, command := range commands {
		startedThisPass := false
		if command.Status == "received" {
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
		if command.Status == "started" && !startedThisPass {
			// Daemon 在已确认 started 后崩溃时，不知道本地 Provider 是否仍活着或是否已部分执行。
			// 为避免 at-least-once delivery 把同一 command 再次交给 Provider，这里 fail-closed，
			// 由客户端根据明确失败状态重新创建带新 lease/idempotency key 的动作。
			if err := l.resolveAndPersist(ctx, command, "failed", "DAEMON_RESTART_RECOVERY"); err != nil {
				return err
			}
			continue
		}
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
			err = l.Runner.ConsumeCommand(ctx, Command{
				RequestID: command.CommandID, Kind: command.Kind, PayloadJSON: command.PayloadJSON,
			})
		}
		status, errorCode := "succeeded", ""
		if err != nil {
			status, errorCode = "failed", CommandErrorCode(err)
			l.Logger.Warn("daemon command execution failed", "command", command.CommandID, "kind", command.Kind, "error", err)
		}
		if err := l.flushEvents(ctx); err != nil {
			return err
		}
		if err := l.resolveAndPersist(ctx, command, status, errorCode); err != nil {
			return err
		}
	}
	return l.flushEvents(ctx)
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

func validRelayResultStatus(status string) bool {
	switch status {
	case "succeeded", "failed", "rejected":
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
	envelope, err := l.Encoder.Encode(command.SessionID, event)
	if err != nil {
		return newCommandExecutionError(protocol.ErrCapabilityUnsupported, err)
	}
	if err := l.Store.EnqueueRelayEvent(RelayEvent{
		EventID: id.New("evt"), CommandID: command.CommandID, SessionID: command.SessionID,
		EventType: relayEventType(event.Type), EnvelopeJSON: envelope,
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

func (l *RelayLoop) enqueueCanonicalEvent(sessionID string, event adapter.Event) {
	if l.Encoder == nil {
		l.Logger.Warn("daemon event withheld: encryption encoder unavailable", "event_type", event.Type)
		return
	}
	l.mu.RLock()
	commandID := l.commandBySession[sessionID]
	l.mu.RUnlock()
	if commandID == "" {
		l.Logger.Warn("daemon event withheld: no command correlation", "event_type", event.Type)
		return
	}
	envelope, err := l.Encoder.Encode(sessionID, event)
	if err != nil {
		l.Logger.Warn("daemon event withheld: encryption failed", "event_type", event.Type, "error", err)
		return
	}
	if err := l.Store.EnqueueRelayEvent(RelayEvent{
		EventID: id.New("evt"), CommandID: commandID, SessionID: sessionID,
		EventType: relayEventType(event.Type), EnvelopeJSON: envelope,
	}); err != nil {
		l.Logger.Warn("daemon event outbox enqueue failed", "event_type", event.Type, "error", err)
		return
	}
	select {
	case l.eventWake <- struct{}{}:
	default:
	}
}

func (l *RelayLoop) flushEvents(ctx context.Context) error {
	events, err := l.Store.PendingRelayEvents()
	if err != nil {
		return err
	}
	for _, event := range events {
		if err := l.Client.UploadEvent(ctx, event); err != nil {
			return err
		}
		if err := l.Store.MarkRelayEventDelivered(event.EventID); err != nil {
			return err
		}
	}
	return nil
}

func relayEventType(value adapter.EventType) string {
	switch value {
	case adapter.EventTurnStarted:
		return "turn.started"
	case adapter.EventMessageDelta:
		return "message.delta"
	case adapter.EventMessageCompleted:
		return "message.completed"
	case adapter.EventToolCall:
		return "tool.call"
	case adapter.EventToolResult:
		return "tool.result"
	case adapter.EventUsage:
		return "usage.updated"
	case adapter.EventFileChange:
		return "file.changed"
	default:
		return "command.updated"
	}
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) != "" {
		return value
	}
	return fallback
}
