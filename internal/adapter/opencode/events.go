package opencode

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// canonicalEvent 是经过映射的规范化事件；origin 记录来源事件类型，仅用于调试、不进公共协议。
type canonicalEvent struct {
	Event  adapter.Event
	Origin string
}

// opencode SSE 事件类型常量（1.17 server bus）。
const (
	evMessagePartDelta  = "message.part.delta"
	evMessagePartUpdate = "message.part.updated"
	evSessionUpdated    = "session.updated"
	evSessionStatus     = "session.status"
	evSessionIdle       = "session.idle"
	evSessionError      = "session.error"
	evMessageUpdated    = "message.updated"
	evServerConnected   = "server.connected"
)

// partDeltaProps 是 message.part.delta 的 properties。
type partDeltaProps struct {
	SessionID string `json:"sessionID"`
	MessageID string `json:"messageID"`
	PartID    string `json:"partID"`
	Field     string `json:"field"`
	Delta     string `json:"delta"`
}

// partUpdatedProps 是 message.part.updated 的 properties（部分字段）。
type partUpdatedProps struct {
	SessionID string `json:"sessionID"`
	Part      Part   `json:"part"`
}

// sessionStatusProps 是 session.status 的 properties。
type sessionStatusProps struct {
	SessionID string `json:"sessionID"`
	Status    struct {
		Type string `json:"type"`
	} `json:"status"`
}

// sessionUpdatedProps 是 session.updated 的 properties（只保留 usage 脱敏摘要）。
type sessionUpdatedProps struct {
	SessionID string  `json:"sessionID"`
	Info      Session `json:"info"`
}

// errorProps 是 session.error 的 properties。opencode 1.17 的 error 既可能是
// 字符串，也可能是 {name, data:{message}} 对象（异步模型调用失败的真实形态），
// 两种形状都必须兼容，否则反序列化失败会把模型错误整个吞掉。
type errorProps struct {
	SessionID string          `json:"sessionID"`
	Error     json.RawMessage `json:"error"`
}

// errorMessage 提取面向用户的错误摘要：优先对象形态的 data.message，
// 回退 name，再回退字符串形态本身。
func (p errorProps) errorMessage() string {
	var text string
	if err := json.Unmarshal(p.Error, &text); err == nil {
		return strings.TrimSpace(text)
	}
	var info struct {
		Name string `json:"name"`
		Data struct {
			Message string `json:"message"`
		} `json:"data"`
	}
	if err := json.Unmarshal(p.Error, &info); err == nil {
		if strings.TrimSpace(info.Data.Message) != "" {
			return strings.TrimSpace(info.Data.Message)
		}
		return strings.TrimSpace(info.Name)
	}
	return ""
}

// parseProperties 解析 SSE 事件的 properties 字段。
func parseProperties[T any](raw json.RawMessage) (T, error) {
	var props T
	if len(raw) == 0 {
		return props, nil
	}
	if err := json.Unmarshal(raw, &props); err != nil {
		return props, fmt.Errorf("解析事件 properties: %w", err)
	}
	return props, nil
}

// mapRawEvent 把 opencode 原始事件映射为规范化事件（纯函数，可单测）。
// 返回 ok=false 表示该事件无需对外广播（如 heartbeat、server.connected）。
// 映射规则（ADPT-OPENCODE-02）：
//   - message.part.delta(field=text)        -> EventMessageDelta
//   - message.part.updated(part.type=text)  -> EventMessageCompleted
//   - message.part.updated(part.type=tool)  -> EventToolCall / EventToolResult（按 state）
//   - message.part.updated(part.type=step-finish) -> EventUsage（含 tokens 摘要）
//   - session.status(busy)                  -> EventTurnStarted
//   - session.idle / session.status(idle)   -> EventTurnCompleted
//   - session.error                         -> EventSessionError
//
// step-finish 是一个内部推理/工具步骤的结算，不一定是整个回合的结算；整个回合以
// session.idle 为权威终态。终态去重必须在 subscription 层完成，不能只依赖单条原始事件映射。
func mapRawEvent(raw RawEvent) (canonicalEvent, bool) {
	switch raw.Type {
	case evMessagePartDelta:
		props, err := parseProperties[partDeltaProps](raw.Properties)
		if err != nil || props.Field != "text" {
			return canonicalEvent{}, false
		}
		// 只映射文本流 delta；reasoning/tool 的 delta 字段不进公共协议。
		return canonicalEvent{Event: adapter.Event{
			Type: adapter.EventMessageDelta,
			Payload: map[string]any{
				"instance_id": props.SessionID,
				"message_id":  props.MessageID,
				"text":        props.Delta,
			},
		}, Origin: raw.Type}, true

	case evMessagePartUpdate:
		props, err := parseProperties[partUpdatedProps](raw.Properties)
		if err != nil {
			return canonicalEvent{}, false
		}
		switch props.Part.Type {
		case "text":
			// 文本 part 完整落地（非增量）。
			return canonicalEvent{Event: adapter.Event{
				Type: adapter.EventMessageCompleted,
				Payload: map[string]any{
					"instance_id": props.SessionID,
					"message_id":  props.Part.MessageID,
					"text":        props.Part.Text,
				},
			}, Origin: raw.Type}, true
		case "tool":
			return mapToolPart(props)
		case "step-finish":
			// turn 结束 + usage 摘要（脱敏计数，不含正文）。
			payload := map[string]any{
				"instance_id": props.SessionID,
				"reason":      props.Part.Reason,
			}
			if props.Part.Tokens != nil {
				payload["input_tokens"] = props.Part.Tokens.Input
				payload["output_tokens"] = props.Part.Tokens.Output
				payload["total_tokens"] = props.Part.Tokens.Total
			}
			return canonicalEvent{Event: adapter.Event{
				Type:    adapter.EventUsage,
				Payload: payload,
			}, Origin: raw.Type}, true
		default:
			// step-start / reasoning 等事件不广播。
			return canonicalEvent{}, false
		}

	case evSessionStatus:
		props, err := parseProperties[sessionStatusProps](raw.Properties)
		if err != nil {
			return canonicalEvent{}, false
		}
		switch props.Status.Type {
		case "busy":
			if props.SessionID == "" {
				return canonicalEvent{}, false
			}
			return canonicalEvent{Event: adapter.Event{
				Type: adapter.EventTurnStarted,
				Payload: map[string]any{
					"instance_id": props.SessionID,
				},
			}, Origin: raw.Type}, true
		case "idle":
			if props.SessionID == "" {
				return canonicalEvent{}, false
			}
			return turnCompletedEvent(props.SessionID, "status_idle"), true
		default:
			return canonicalEvent{}, false
		}

	case evSessionIdle:
		props, err := parseProperties[struct {
			SessionID string `json:"sessionID"`
		}](raw.Properties)
		if err != nil || props.SessionID == "" {
			return canonicalEvent{}, false
		}
		return turnCompletedEvent(props.SessionID, "session_idle"), true

	case evSessionError:
		props, err := parseProperties[errorProps](raw.Properties)
		if err != nil || props.SessionID == "" {
			return canonicalEvent{}, false
		}
		message := props.errorMessage()
		if message == "" {
			return canonicalEvent{}, false
		}
		return canonicalEvent{Event: adapter.Event{
			Type: adapter.EventSessionError,
			Payload: map[string]any{
				"instance_id": props.SessionID,
				"message":     truncateText(message, 512),
			},
		}, Origin: raw.Type}, true

	default:
		// server.connected / heartbeat / busy / idle / catalog.updated / plugin.added /
		// integration.updated / reference.updated / session.diff 等不进入公共协议。
		return canonicalEvent{}, false
	}
}

func turnCompletedEvent(sessionID, reason string) canonicalEvent {
	return canonicalEvent{Event: adapter.Event{
		Type: adapter.EventTurnCompleted,
		Payload: map[string]any{
			"instance_id": sessionID,
			"stop_reason": reason,
		},
	}}
}

// mapToolPart 把 tool part 映射为 tool_call 或 tool_result。
// state=pending/running 视为调用开始；completed/error/aborted 视为结果。
func mapToolPart(props partUpdatedProps) (canonicalEvent, bool) {
	part := props.Part
	base := map[string]any{
		"instance_id": props.SessionID,
		"tool_id":     part.ID,
		"tool_name":   part.Tool,
	}
	switch part.State {
	case "pending", "running", "":
		// 输入参数可能包含文件路径等敏感内容：只映射已结构化工具名，不复制完整 input 正文。
		input := ""
		if part.Input != nil {
			if raw, err := json.Marshal(part.Input); err == nil {
				input = truncateText(string(raw), 1024)
			}
		}
		payload := map[string]any{}
		for k, v := range base {
			payload[k] = v
		}
		payload["input"] = input
		return canonicalEvent{Event: adapter.Event{
			Type:    adapter.EventToolCall,
			Payload: payload,
		}, Origin: evMessagePartUpdate}, true
	default:
		// completed / error / aborted：输出同样截断，避免把超大工具输出灌进公共协议。
		payload := map[string]any{}
		for k, v := range base {
			payload[k] = v
		}
		payload["output"] = truncateText(part.Output, 4096)
		payload["state"] = part.State
		return canonicalEvent{Event: adapter.Event{
			Type:    adapter.EventToolResult,
			Payload: payload,
		}, Origin: evMessagePartUpdate}, true
	}
}

// truncateText 截断超长文本并补齐提示，防止把大正文带入报告或公共协议。
func truncateText(s string, max int) string {
	s = strings.ToValidUTF8(s, "")
	if len(s) <= max {
		return s
	}
	return s[:max] + "...(truncated)"
}

// subscription 是一个会话的事件订阅：handle 通过它接收该会话的规范化事件。
type subscription struct {
	raw chan RawEvent
	ev  chan adapter.Event
	// roles 记录 message.updated 观察到的 messageID → role。part.updated 只带
	// messageID 不带角色；没有这张表就无法把用户输入从助手事件流中剔除。
	roles map[string]string
	// turnClosed 对 session.idle/status-idle 的终态做每回合去重。
	turnClosed bool
}

// streamReader 是 /event SSE 的消费者。它以 goroutine 读取流并解析事件；
// 只有被订阅的 session 事件才会被广播，避免无关会话事件泄漏。
type streamReader struct {
	client *Client
	cancel context.CancelFunc
	raw    chan RawEvent
	mu     sync.Mutex
	subs   map[string][]*subscription
	closed chan struct{}
	// closedFlag is guarded by mu. It closes the small race where a provider
	// stream EOF happens between dispatchLoop's final fan-out and close(closed).
	// A late subscriber must fail instead of waiting on an event channel that
	// can never receive.
	closedFlag bool
}

// openStream 建立 /event SSE 连接并启动分发 goroutine。
// 流生命周期独立于调用方 context：以 background 为基，由 adapter 在全部句柄释放后关闭。
func (c *Client) openStream() (*streamReader, error) {
	streamCtx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(streamCtx, http.MethodGet, c.base+"/event", nil)
	if err != nil {
		cancel()
		return nil, err
	}
	req.Header.Set("Accept", "text/event-stream")
	req.SetBasicAuth(c.user, c.pass)
	resp, err := c.http.Do(req)
	if err != nil {
		cancel()
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		cancel()
		return nil, fmt.Errorf("opencode /event: status %d", resp.StatusCode)
	}
	sr := &streamReader{
		client: c,
		cancel: cancel,
		raw:    make(chan RawEvent, 64),
		subs:   map[string][]*subscription{},
		closed: make(chan struct{}),
	}
	go sr.readLoop(resp.Body)
	go sr.dispatchLoop()
	return sr, nil
}

// readLoop 逐行解析 SSE data: 事件并送入 raw 通道。
func (s *streamReader) readLoop(body io.ReadCloser) {
	defer body.Close()
	defer close(s.raw)
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		// SSE 事件体以 data: 开头；多个 data: 行拼接为一条（opencode 单行输出）。
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" {
			continue
		}
		var raw RawEvent
		if err := json.Unmarshal([]byte(data), &raw); err != nil {
			continue
		}
		select {
		case s.raw <- raw:
		case <-s.closed:
			return
		}
	}
}

// dispatchLoop 把原始事件按 sessionID 分发给订阅者；无订阅者时丢弃。
func (s *streamReader) dispatchLoop() {
	defer func() {
		// Propagate provider EOF to every live subscription. Without closing
		// sub.raw, the per-session forwarder (and therefore the Daemon runner)
		// would wait forever after the shared SSE stream died.
		s.mu.Lock()
		s.closedFlag = true
		subs := make([]*subscription, 0)
		for sessionID, sessionSubs := range s.subs {
			for _, sub := range sessionSubs {
				subs = append(subs, sub)
			}
			delete(s.subs, sessionID)
		}
		s.mu.Unlock()
		for _, sub := range subs {
			close(sub.raw)
		}
		close(s.closed)
	}()
	for raw := range s.raw {
		sessionID := rawSessionID(raw)
		if sessionID == "" {
			continue
		}
		s.mu.Lock()
		sessionSubs := append([]*subscription(nil), s.subs[sessionID]...)
		s.mu.Unlock()
		for _, sub := range sessionSubs {
			select {
			case sub.raw <- raw:
			default:
				// 订阅者消费过慢时丢弃增量，防背压；完整正文仍可从 /message 恢复。
			}
		}
	}
}

// rawSessionID 提取事件归属的会话 ID（无则忽略，不广播）。
func rawSessionID(raw RawEvent) string {
	var props struct {
		SessionID string `json:"sessionID"`
	}
	_ = json.Unmarshal(raw.Properties, &props)
	return props.SessionID
}

// subscribe 注册会话订阅，返回该会话的规范化事件通道（顺序与 SSE 一致）。
func (s *streamReader) subscribe(sessionID string) (*subscription, bool) {
	sub := &subscription{
		raw:   make(chan RawEvent, 128),
		ev:    make(chan adapter.Event, 128),
		roles: map[string]string{},
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closedFlag {
		return nil, false
	}
	s.subs[sessionID] = append(s.subs[sessionID], sub)
	go s.forward(sub, sessionID)
	return sub, true
}

// forward 消费原始事件并映射为规范化事件；订阅者或会话关闭时退出。
func (s *streamReader) forward(sub *subscription, sessionID string) {
	defer close(sub.ev)
	for raw := range sub.raw {
		trackMessageRole(sub, raw)
		mapped, ok := mapRawEvent(raw)
		if !ok {
			continue
		}
		if mapped.Event.Type == adapter.EventTurnStarted {
			sub.turnClosed = false
		}
		if mapped.Event.Type == adapter.EventTurnCompleted {
			if sub.turnClosed {
				continue
			}
			sub.turnClosed = true
		}
		if skipUserMessageEcho(sub, mapped.Event) {
			continue
		}
		select {
		case sub.ev <- mapped.Event:
		case <-s.closed:
			return
		}
		// session.error is terminal for the current Provider turn as well as a
		// user-visible error. OpenCode may omit session.idle on failures, so emit
		// the same de-duplicated terminal marker here.
		if raw.Type == evSessionError && !sub.turnClosed {
			sub.turnClosed = true
			terminal := turnCompletedEvent(sessionID, "error").Event
			select {
			case sub.ev <- terminal:
			case <-s.closed:
				return
			}
		}
	}
}

// messageUpdatedProps 是 message.updated 的 properties（只取角色判定所需字段）。
type messageUpdatedProps struct {
	Info struct {
		ID   string `json:"id"`
		Role string `json:"role"`
	} `json:"info"`
}

// trackMessageRole 从 message.updated 记录消息角色。OpenCode 的 part 事件只携带
// messageID；没有这张映射就无法区分用户输入与助手输出。
func trackMessageRole(sub *subscription, raw RawEvent) {
	if raw.Type != "message.updated" || sub == nil || sub.roles == nil {
		return
	}
	props, err := parseProperties[messageUpdatedProps](raw.Properties)
	if err != nil || props.Info.ID == "" || props.Info.Role == "" {
		return
	}
	sub.roles[props.Info.ID] = props.Info.Role
}

// skipUserMessageEcho 丢弃角色为 user 的文本 delta/completed：用户输入已经由命令链路
// 进入时间线，不能作为助手事件二次广播。
func skipUserMessageEcho(sub *subscription, event adapter.Event) bool {
	if event.Type != adapter.EventMessageDelta && event.Type != adapter.EventMessageCompleted {
		return false
	}
	messageID, _ := event.Payload["message_id"].(string)
	return messageID != "" && sub != nil && sub.roles[messageID] == "user"
}

// unsubscribe 注销会话订阅。
func (s *streamReader) unsubscribe(sessionID string, sub *subscription) {
	s.mu.Lock()
	defer s.mu.Unlock()
	subs := s.subs[sessionID]
	for i, item := range subs {
		if item == sub {
			s.subs[sessionID] = append(subs[:i], subs[i+1:]...)
			break
		}
	}
}

// close 关闭 SSE 连接并回收订阅者。
func (s *streamReader) close() {
	s.cancel()
	<-s.closed
}
