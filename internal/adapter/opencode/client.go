// Package opencodeadapter 实现 OpenCode adapter（P3 -> v0.2/P1）。
// 通过本地 opencode server HTTP API 完成会话创建、发送、中止与 SSE 事件映射；
// 会话 ID 只在内存与本地 handle 中流转，不进入公共协议、日志或 Flutter 卡片正文。
package opencode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// EnvURL 是 OpenCode 本地 server 地址。
const EnvURL = "AGENT_SESSIONS_OPENCODE_URL"

// EnvUsername / EnvPassword 是 opencode serve 的 Basic Auth 凭据环境变量名。
// 凭据只在内存中使用，禁止写入日志、报告或命令行参数。
const (
	EnvUsername = "OPENCODE_SERVER_USERNAME"
	EnvPassword = "OPENCODE_SERVER_PASSWORD"
)

// HealthResult 是 /global/health 的响应。只有 healthy 时才允许声明 Version。
type HealthResult struct {
	Healthy bool   `json:"healthy"`
	Version string `json:"version"`
}

// Session 是 opencode 会话元数据（脱敏子集）。
// 不保存 prompt/回复正文；tokens 只用于 usage 摘要。
type Session struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Version string `json:"version"`
	Tokens  struct {
		Input     int64 `json:"input"`
		Output    int64 `json:"output"`
		Reasoning int64 `json:"reasoning"`
	} `json:"tokens"`
}

// Part 是会话消息的一个组成部分（text/step-start/step-finish/tool/reasoning）。
// 只保留映射 canonical 事件所需的字段，Provider 私有 metadata 不进入公共协议。
// 空字段必须省略（omitempty）：opencode 1.17 服务端校验 part.id 必须是 prt 开头，
// 传空字符串会被拒绝；缺省字段则按服务端默认处理。
type Part struct {
	ID string `json:"id,omitempty"`
	// MessageID 把 part 关联到所属消息；配合 message.updated 的 info.role 可区分
	// user/assistant，避免把用户输入回显成助手事件。
	MessageID string `json:"messageID,omitempty"`
	Type      string `json:"type,omitempty"`
	Text      string `json:"text,omitempty"`
	State     string `json:"state,omitempty"`
	Tool      string `json:"tool,omitempty"`
	Input     any    `json:"input,omitempty"`
	// Output 只对已完成工具生效；不完整工具调用不携带正文。
	Output string `json:"output,omitempty"`
	Reason string `json:"reason,omitempty"`
	Tokens *struct {
		Total  int64 `json:"total"`
		Input  int64 `json:"input"`
		Output int64 `json:"output"`
	} `json:"tokens,omitempty"`
}

// Message 是会话消息的元信息 + 组成部分。
type Message struct {
	Info struct {
		ID        string `json:"id"`
		Role      string `json:"role"`
		SessionID string `json:"sessionID"`
	} `json:"info"`
	Parts []Part `json:"parts"`
}

// RawEvent 是 opencode SSE 事件行（/event 与 /global/event 共用的数据形状）。
type RawEvent struct {
	ID         string          `json:"id"`
	Type       string          `json:"type"`
	Properties json.RawMessage `json:"properties"`
}

// requestTimeout 是普通 HTTP 请求的默认超时（SSE 流不适用，由调用方生命周期控制）。
const requestTimeout = 30 * time.Second

// Client 是 OpenCode server 的薄 HTTP 客户端。所有方法都幂等或可安全重入。
type Client struct {
	base string
	http *http.Client
	user string
	pass string
}

// NewClient 构造客户端。URL 来自 EnvURL，凭据来自 OPENCODE_SERVER_USERNAME/PASSWORD。
// 未配置 URL 时返回 (nil, error)，调用方应 fail-closed。
func NewClient() (*Client, error) {
	raw := strings.TrimSpace(os.Getenv(EnvURL))
	if raw == "" {
		return nil, errors.New("AGENT_SESSIONS_OPENCODE_URL 未配置")
	}
	base, err := url.Parse(raw)
	if err != nil || base.Scheme == "" || base.Host == "" {
		return nil, fmt.Errorf("AGENT_SESSIONS_OPENCODE_URL 格式无效: %q", raw)
	}
	user := strings.TrimSpace(os.Getenv(EnvUsername))
	if user == "" {
		user = "opencode"
	}
	pass := os.Getenv(EnvPassword)
	return &Client{
		base: strings.TrimSuffix(raw, "/"),
		// 不设全局 Timeout：SSE 流需要长连接；普通请求在 do 内按上下文加超时。
		http: &http.Client{},
		user: user,
		pass: pass,
	}, nil
}

// do 发送带 Basic Auth 的请求；非 2xx 返回含状态码的脱敏错误。
// ctx 无截止时间时自动套 30s 超时，避免挂死。
func (c *Client) do(ctx context.Context, method, path string, body any) (*http.Response, error) {
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, requestTimeout)
		defer cancel()
	}
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("encode request: %w", err)
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.SetBasicAuth(c.user, c.pass)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// 只读取少量响应体用于错误原因；正文不超过 1 KiB 且不写入日志。
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		_ = resp.Body.Close()
		return nil, fmt.Errorf("opencode %s %s: status %d body %q", method, path, resp.StatusCode, sanitize(msg))
	}
	return resp, nil
}

// decode 读取并解析 JSON 响应体。
func decode[T any](resp *http.Response) (T, error) {
	defer resp.Body.Close()
	var out T
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return out, fmt.Errorf("decode response: %w", err)
	}
	return out, nil
}

// sanitize 只保留脱敏的响应摘要：截断并去除可能的控制字符，防止凭据或敏感正文流入错误消息。
func sanitize(b []byte) string {
	s := string(b)
	if len(s) > 256 {
		s = s[:256] + "..."
	}
	return strings.ToValidUTF8(s, "")
}

// Health 探测 /global/health。返回 healthy 状态与版本；401/网络错误原样返回。
func (c *Client) Health(ctx context.Context) (HealthResult, error) {
	resp, err := c.do(ctx, http.MethodGet, "/global/health", nil)
	if err != nil {
		return HealthResult{}, err
	}
	return decode[HealthResult](resp)
}

// CreateSession 创建新会话（POST /session）。返回会话 ID。
func (c *Client) CreateSession(ctx context.Context, title string) (Session, error) {
	body := map[string]any{"title": title}
	resp, err := c.do(ctx, http.MethodPost, "/session", body)
	if err != nil {
		return Session{}, err
	}
	return decode[Session](resp)
}

// GetSession 读取会话元数据（GET /session/{id}）。
func (c *Client) GetSession(ctx context.Context, id string) (Session, error) {
	resp, err := c.do(ctx, http.MethodGet, "/session/"+url.PathEscape(id), nil)
	if err != nil {
		return Session{}, err
	}
	return decode[Session](resp)
}

// GetMessages 读取会话消息（GET /session/{id}/message），用于 Resume 判断上下文是否仍在。
func (c *Client) GetMessages(ctx context.Context, id string, limit int) ([]Message, error) {
	path := "/session/" + url.PathEscape(id) + "/message?limit=" + fmt.Sprintf("%d", limit)
	resp, err := c.do(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	return decode[[]Message](resp)
}

// PromptAsync 异步发送一条消息（POST /session/{id}/prompt_async）。204 表示已受理。
// model 为空时使用服务端默认模型；显式模型必须是服务端已配置的 provider/model。
// 服务端要求 model 为 {providerID, modelID} 对象，因此把 "provider/model" 拆开透传。
func (c *Client) PromptAsync(ctx context.Context, id string, parts []Part, model string) error {
	body := map[string]any{"parts": parts}
	if model != "" {
		providerID, modelID, ok := strings.Cut(model, "/")
		if !ok {
			return fmt.Errorf("模型必须使用 provider/model 格式: %q", model)
		}
		body["model"] = map[string]string{"providerID": providerID, "modelID": modelID}
	}
	resp, err := c.do(ctx, http.MethodPost, "/session/"+url.PathEscape(id)+"/prompt_async", body)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

// TextPart 构造一个纯文本 part。
func TextPart(text string) Part {
	return Part{Type: "text", Text: text}
}

// Abort 中止当前 turn（POST /session/{id}/abort）。
func (c *Client) Abort(ctx context.Context, id string) error {
	resp, err := c.do(ctx, http.MethodPost, "/session/"+url.PathEscape(id)+"/abort", nil)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}
