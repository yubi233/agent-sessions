// Package codexadapter 中 app-server JSON-RPC/stdio 的 typed 客户端（ADPT-CODEX-01 W1）。
// codex app-server 使用换行分隔的 JSON-RPC 2.0：请求/响应带 id 关联，服务端推送为无 id 通知。
// 本文件只负责传输层：进程生命周期、id 关联、取消与错误分类；thread/turn 语义在 W2 映射。
package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
)

// appServerSubcommand 是进入 app-server 模式的固定子命令。
const appServerSubcommand = "app-server"

// rpcScanBufferBytes 限制单条 JSON-RPC 消息上限，防止失控输出拖垮 Daemon 内存。
const rpcScanBufferBytes = 1 << 20

// ErrRPCProcessExited 表示 app-server 进程已退出，后续调用不可恢复。
var ErrRPCProcessExited = errors.New("codex app-server exited")

// RPCError 是服务端返回的 JSON-RPC error 对象。Code 用于分类，Message 只进诊断日志，
// 不得原样透传给客户端 UI（可能携带 Provider 明文细节）。
type RPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("codex rpc error %d", e.Code)
}

// RPCNotification 是服务端主动推送（无 id）。
type RPCNotification struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// RPCServerRequest 是服务端发起的带 id 请求（如审批回调），必须经 Respond 回答。
type RPCServerRequest struct {
	ID     json.RawMessage `json:"-"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type rpcResponse struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *RPCError       `json:"error"`
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int64           `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

// RPCClient 是与单个 codex app-server 进程绑定的 JSON-RPC 客户端。
type RPCClient struct {
	bin string

	cmd    *exec.Cmd
	stdin  io.WriteCloser
	closed chan struct{}

	writeMu sync.Mutex
	idMu    sync.Mutex
	nextID  int64

	pendingMu sync.Mutex
	pending   map[int64]chan rpcResult

	notifyMu   sync.Mutex
	notifyWait []chan RPCNotification

	serverReqMu   sync.Mutex
	serverReqWait []chan RPCServerRequest

	exited       chan struct{}
	exitErr      error
	shutdownOnce sync.Once
}

type rpcResult struct {
	payload json.RawMessage
	err     error
}

// NewRPCClient 启动 app-server 子进程并完成绑定。bin 为 codex 可执行文件路径。
func NewRPCClient(ctx context.Context, bin string) (*RPCClient, error) {
	bin = strings.TrimSpace(bin)
	if bin == "" {
		return nil, errors.New("codex binary path is empty")
	}
	cmd := exec.CommandContext(ctx, bin, appServerSubcommand)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("app-server stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("app-server stdout pipe: %w", err)
	}
	// stderr 只收集不透传：app-server 的告警属于本机诊断，禁止进入公共事件流。
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("app-server stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start %s %s: %w", bin, appServerSubcommand, err)
	}

	c := newRPCClientOnStreams(stdin, stdout, stderr)
	c.cmd = cmd
	go c.awaitExit()
	return c, nil
}

// newRPCClientOnStreams 是传输层核心：进程无关，便于以确定性管道驱动契约测试。
func newRPCClientOnStreams(stdin io.WriteCloser, stdout io.Reader, stderr io.ReadCloser) *RPCClient {
	c := &RPCClient{
		stdin:   stdin,
		closed:  make(chan struct{}),
		nextID:  1,
		pending: map[int64]chan rpcResult{},
		exited:  make(chan struct{}),
	}
	if stderr != nil {
		go c.drainStderr(stderr)
	}
	go c.readLoop(stdout)
	return c
}

// Call 发送请求并等待关联响应；ctx 取消只放弃等待，不中断远端执行（取消语义由 W2 显式发 turn/interrupt）。
func (c *RPCClient) Call(ctx context.Context, method string, params any, result any) error {
	rawParams, err := json.Marshal(params)
	if err != nil {
		return fmt.Errorf("marshal rpc params for %s: %w", method, err)
	}
	c.idMu.Lock()
	id := c.nextID
	c.nextID++
	c.idMu.Unlock()

	waiter := make(chan rpcResult, 1)
	c.pendingMu.Lock()
	c.pending[id] = waiter
	c.pendingMu.Unlock()
	defer func() {
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
	}()

	request := rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: rawParams}
	line, err := json.Marshal(request)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	_, writeErr := c.stdin.Write(append(line, '\n'))
	c.writeMu.Unlock()
	if writeErr != nil {
		select {
		case <-c.exited:
			return ErrRPCProcessExited
		default:
		}
		return fmt.Errorf("write rpc request %s: %w", method, writeErr)
	}

	select {
	case res := <-waiter:
		if res.err != nil {
			return res.err
		}
		if result == nil || len(res.payload) == 0 {
			return nil
		}
		if err := json.Unmarshal(res.payload, result); err != nil {
			return fmt.Errorf("decode rpc result for %s: %w", method, err)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-c.exited:
		return ErrRPCProcessExited
	}
}

// Notifications 返回服务端通知流；close 后通道关闭。消费者必须持续读取，否则会阻塞分发循环。
func (c *RPCClient) Notifications() <-chan RPCNotification {
	ch := make(chan RPCNotification, 64)
	c.notifyMu.Lock()
	c.notifyWait = append(c.notifyWait, ch)
	c.notifyMu.Unlock()
	return ch
}

// Close 终止 app-server 进程并释放资源；幂等。
func (c *RPCClient) Close() error {
	select {
	case <-c.closed:
		return nil
	default:
		close(c.closed)
	}
	if c.cmd == nil {
		// 流注入构造（测试）：无子进程，只需关闭写端。
		return c.stdin.Close()
	}
	if c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	// 主动 kill 的 "signal: killed" 不算错误；真实异常可通过 ExitError() 观察。
	_ = c.cmd.Wait()
	return nil
}

// Done 返回进程退出信号；读侧用于感知异常退出。
func (c *RPCClient) Done() <-chan struct{} { return c.exited }

// ExitError 返回进程退出原因（未退出时为 nil）。
func (c *RPCClient) ExitError() error { return c.exitErr }

func (c *RPCClient) awaitExit() {
	waitErr := c.cmd.Wait()
	c.shutdown(fmt.Errorf("%w: %v", ErrRPCProcessExited, waitErr))
}

// shutdown 幂等：唤醒全部 pending、关闭通知通道并标记进程退出。
// 读循环 EOF 与进程 Wait 竞争时只有先到者生效。
func (c *RPCClient) shutdown(exitErr error) {
	c.shutdownOnce.Do(func() {
		c.exitErr = exitErr
		c.pendingMu.Lock()
		for id, waiter := range c.pending {
			waiter <- rpcResult{err: fmt.Errorf("%w during pending request id=%d", ErrRPCProcessExited, id)}
			delete(c.pending, id)
		}
		c.pendingMu.Unlock()
		c.notifyMu.Lock()
		waiters := c.notifyWait
		c.notifyWait = nil
		c.notifyMu.Unlock()
		for _, ch := range waiters {
			close(ch)
		}
		c.serverReqMu.Lock()
		reqWaiters := c.serverReqWait
		c.serverReqWait = nil
		c.serverReqMu.Unlock()
		for _, ch := range reqWaiters {
			close(ch)
		}
		close(c.exited)
	})
}

func (c *RPCClient) readLoop(stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), rpcScanBufferBytes)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var probe struct {
			ID     *json.RawMessage `json:"id"`
			Method string           `json:"method"`
		}
		if err := json.Unmarshal([]byte(line), &probe); err != nil {
			continue // 非 JSON 行（启动横幅等）直接忽略
		}
		if probe.Method != "" && probe.ID == nil {
			var notification RPCNotification
			if err := json.Unmarshal([]byte(line), &notification); err == nil && notification.Method != "" {
				c.dispatchNotification(notification)
			}
			continue
		}
		if probe.Method != "" && probe.ID != nil {
			// 服务端请求（如审批回调）：带 id + method，必须由调用方 Respond。
			var req RPCServerRequest
			if err := json.Unmarshal([]byte(line), &req); err == nil && req.Method != "" {
				req.ID = *probe.ID
				c.dispatchServerRequest(req)
			}
			continue
		}
		var response rpcResponse
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			continue
		}
		var id int64
		if err := json.Unmarshal(response.ID, &id); err != nil {
			continue
		}
		c.pendingMu.Lock()
		waiter, ok := c.pending[id]
		if ok {
			delete(c.pending, id)
		}
		c.pendingMu.Unlock()
		if !ok {
			continue
		}
		if response.Error != nil {
			waiter <- rpcResult{err: response.Error}
		} else {
			waiter <- rpcResult{payload: response.Result}
		}
	}
	// stdout 关闭即进程退出（或管道被测试关闭）；唤醒全部 pending，避免调用方永久等待。
	c.shutdown(c.exitErr)
}

// Requests 返回服务端请求流（审批等带 id 回调）。消费者必须持续读取，
// 并对每条请求调用 Respond；close 后通道关闭。
func (c *RPCClient) Requests() <-chan RPCServerRequest {
	ch := make(chan RPCServerRequest, 16)
	c.serverReqMu.Lock()
	c.serverReqWait = append(c.serverReqWait, ch)
	c.serverReqMu.Unlock()
	return ch
}

// Respond 回答一条服务端请求；result 为响应负载（如 {"decision":"accept"}）。
func (c *RPCClient) Respond(id json.RawMessage, result any) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("marshal rpc response: %w", err)
	}
	line, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  json.RawMessage(payload),
	})
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, werr := c.stdin.Write(append(line, '\n'))
	return werr
}

// Notify 发送客户端通知（无 id，无响应）；params 为 nil 时省略字段。
func (c *RPCClient) Notify(method string, params any) error {
	message := map[string]any{"jsonrpc": "2.0", "method": method}
	if params != nil {
		rawParams, err := json.Marshal(params)
		if err != nil {
			return fmt.Errorf("marshal rpc params for %s: %w", method, err)
		}
		message["params"] = json.RawMessage(rawParams)
	}
	line, err := json.Marshal(message)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, werr := c.stdin.Write(append(line, '\n'))
	return werr
}

func (c *RPCClient) dispatchServerRequest(req RPCServerRequest) {
	c.serverReqMu.Lock()
	waiters := append([]chan RPCServerRequest(nil), c.serverReqWait...)
	c.serverReqMu.Unlock()
	for _, ch := range waiters {
		select {
		case ch <- req:
		default:
		}
	}
}

func (c *RPCClient) dispatchNotification(n RPCNotification) {
	c.notifyMu.Lock()
	waiters := append([]chan RPCNotification(nil), c.notifyWait...)
	c.notifyMu.Unlock()
	for _, ch := range waiters {
		select {
		case ch <- n:
		default: // 慢消费者丢弃通知，避免阻塞分发循环；canonical 语义不依赖每条通知必达
		}
	}
}

func (c *RPCClient) drainStderr(stderr io.ReadCloser) {
	// 按隐私边界静默丢弃 app-server 告警；不进入日志、事件或报告。
	_, _ = io.Copy(io.Discard, stderr)
}

// DefaultCodexBin 返回 Codex 可执行文件的环境配置值（与既有 EnvBin 一致）。
func DefaultCodexBin() string { return os.Getenv(EnvBin) }

// command 构造 app-server 相关子进程命令（测试注入点）。
func command(name string, args ...string) *exec.Cmd {
	return exec.Command(name, args...)
}
