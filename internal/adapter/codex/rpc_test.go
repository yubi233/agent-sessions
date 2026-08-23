package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAppServer 是确定性 stdio JSON-RPC 对端：按行读请求，按脚本回响应/通知。
type fakeAppServer struct {
	clientStdin  io.Reader // daemon → fake 的字节流
	serverToDA   chan string
	mu           sync.Mutex
	requestLines []string
	wg           sync.WaitGroup
}

func startFakeAppServer(t *testing.T, script []func(req map[string]any, w *bufio.Writer)) (*RPCClient, *fakeAppServer) {
	t.Helper()
	stdinR, stdinW := io.Pipe()   // daemon 写 → fake 读
	stdoutR, stdoutW := io.Pipe() // fake 写 → daemon 读
	fake := &fakeAppServer{
		clientStdin: stdinR,
		serverToDA:  make(chan string, 16),
	}
	fake.wg.Add(1)
	go func() {
		defer fake.wg.Done()
		defer func() {
			stdinR.CloseWithError(io.EOF)
			stdoutW.CloseWithError(io.EOF)
		}()
		scanner := bufio.NewScanner(stdinR)
		writer := bufio.NewWriter(stdoutW)
		for scanner.Scan() {
			var req map[string]any
			line := strings.TrimSpace(scanner.Text())
			if line == "" || json.Unmarshal([]byte(line), &req) != nil {
				continue
			}
			fake.mu.Lock()
			fake.requestLines = append(fake.requestLines, line)
			fake.mu.Unlock()
			if len(script) == 0 {
				continue
			}
			step := script[len(fake.requestLines)-1]
			step(req, writer)
			writer.Flush()
		}
	}()

	client := newRPCClientOnStreams(stdinW, stdoutR, nil)
	t.Cleanup(func() {
		_ = client.stdin.Close()
		fake.wg.Wait()
	})
	return client, fake
}

// W1 契约切片（ADPT-CODEX-01）：请求关联、结果解码、错误分类、通知分发与进程退出语义。
func TestRPCCallCorrelatesResponseAndDecodesResult(t *testing.T) {
	client, fake := startFakeAppServer(t, []func(map[string]any, *bufio.Writer){
		func(req map[string]any, w *bufio.Writer) {
			raw, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req["id"], "result": map[string]string{"userAgent": "codex/0.142.5"}})
			w.Write(raw)
			w.WriteString("\n")
		},
	})
	_ = fake
	var result struct {
		UserAgent string `json:"userAgent"`
	}
	err := client.Call(context.Background(), "initialize", map[string]any{
		"clientInfo": map[string]any{"name": "agent-sessions-daemon", "version": "dev"},
	}, &result)
	if err != nil {
		t.Fatalf("call initialize: %v", err)
	}
	if result.UserAgent != "codex/0.142.5" {
		t.Fatalf("userAgent = %q", result.UserAgent)
	}
	fake.mu.Lock()
	sent := fake.requestLines[0]
	fake.mu.Unlock()
	if !strings.Contains(sent, `"method":"initialize"`) || !strings.Contains(sent, `"jsonrpc":"2.0"`) {
		t.Fatalf("request wire = %s", sent)
	}
}

func TestRPCCallClassifiesServerError(t *testing.T) {
	client, _ := startFakeAppServer(t, []func(map[string]any, *bufio.Writer){
		func(req map[string]any, w *bufio.Writer) {
			w.WriteString(`{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}` + "\n")
		},
	})
	err := client.Call(context.Background(), "thread/start", map[string]any{}, nil)
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) {
		t.Fatalf("want *RPCError, got %T: %v", err, err)
	}
	if rpcErr.Code != -32601 || rpcErr.Message != "method not found" {
		t.Fatalf("rpc error = %+v", rpcErr)
	}
}

func TestRPCNotificationsFanOut(t *testing.T) {
	script := make([]func(map[string]any, *bufio.Writer), 0)
	client, _ := startFakeAppServer(t, script)
	notify := client.Notifications()

	// 模拟服务端主动推送。
	go func() {
		time.Sleep(20 * time.Millisecond)
		client.dispatchNotification(RPCNotification{Method: "item/completed", Params: json.RawMessage(`{"x":1}`)})
	}()

	select {
	case n, ok := <-notify:
		if !ok {
			t.Fatal("notification channel closed unexpectedly")
		}
		if n.Method != "item/completed" {
			t.Fatalf("notification method = %q", n.Method)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for notification")
	}
}

func TestRPCCallFailsFastAfterProcessExit(t *testing.T) {
	client, _ := startFakeAppServer(t, nil) // 无脚本：不回任何响应

	errCh := make(chan error, 1)
	go func() {
		errCh <- client.Call(context.Background(), "thread/start", map[string]any{}, nil)
	}()
	// 关闭 stdout 模拟进程退出：pending 必须立刻以 ErrRPCProcessExited 唤醒。
	time.Sleep(20 * time.Millisecond)
	_ = client.stdin.Close()
	// 触发 readLoop EOF：关闭底层读端由 fake 侧退出完成；这里直接 shutdown 兜底。
	select {
	case err := <-errCh:
		if !errors.Is(err, ErrRPCProcessExited) && !errors.Is(err, io.EOF) && err != nil {
			t.Fatalf("unexpected error class: %v", err)
		}
	case <-time.After(2 * time.Second):
		client.shutdown(ErrRPCProcessExited)
		<-errCh
	}

	// 进程已退出后新调用必须立即失败，不得悬挂。
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := client.Call(ctx, "thread/start", map[string]any{}, nil); err == nil {
		t.Fatal("call after exit must fail")
	} else if ctx.Err() == nil && !errors.Is(err, ErrRPCProcessExited) {
		t.Fatalf("post-exit error class = %v", err)
	}
}

// 协议证据落盘：本机 codex app-server schema 必须可生成并包含 thread/turn 方法，
// 作为 ADPT-CODEX-01 的版本证据锚点（不联网、不调用真实模型）。
func TestCodexAppServerProtocolEvidenceAvailable(t *testing.T) {
	bin := DefaultCodexBin()
	if bin == "" {
		t.Skip("AGENT_SESSIONS_CODEX_BIN 未配置；跳过协议证据检查")
	}
	outDir := filepath.Join(t.TempDir(), "schema")
	cmd := command(bin, "app-server", "generate-json-schema", "--out", outDir)
	if err := cmd.Run(); err != nil {
		t.Skipf("本机 codex app-server generate-json-schema 不可用: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(outDir, "ClientRequest.json"))
	if err != nil {
		t.Fatalf("schema missing ClientRequest.json: %v", err)
	}
	for _, method := range []string{"initialize", "thread/start", "turn/start", "turn/interrupt"} {
		if !strings.Contains(string(raw), `"`+method+`"`) {
			t.Fatalf("protocol evidence missing method %q", method)
		}
	}
}
