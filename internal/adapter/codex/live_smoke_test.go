package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// EnvLiveSmoke 是 W4 live smoke 的显式授权门禁：只有操作者显式设置才执行真实模型请求。
// 缺省（含常规 go test ./...）一律 skip，不产生任何上游调用。
const EnvLiveSmoke = "AGENT_SESSIONS_CODEX_LIVE_SMOKE"

// ADPT-CODEX-04：授权 live smoke。
// 约束：最小隔离 workspace（t.TempDir）、限量请求（一个对话 turn + 一个 abort turn）、
// 显式 stop（Dispose+Close 终止 app-server 进程树）、报告脱敏（不落模型正文）。
func TestCodexLiveSmoke(t *testing.T) {
	if os.Getenv(EnvLiveSmoke) == "" {
		t.Skipf("%s 未设置：未经授权不执行 live smoke", EnvLiveSmoke)
	}
	bin := DefaultCodexBin()
	if bin == "" {
		if path, err := execLookPath("codex"); err == nil {
			bin = path
		}
	}
	if bin == "" {
		t.Fatal("未找到 codex 可执行文件（设置 AGENT_SESSIONS_CODEX_BIN）")
	}
	t.Setenv(EnvBin, bin) // New() 从环境读取；PATH 发现结果回填给探测逻辑

	report := map[string]any{
		"test_id":        "ADPT-CODEX-04",
		"started_at":     time.Now().UTC().Format(time.RFC3339),
		"bin":            filepath.Base(bin),
		"isolated":       true,
		"request_budget": "1 chat turn + 1 abort turn",
	}
	defer func() {
		report["finished_at"] = time.Now().UTC().Format(time.RFC3339)
		writeLiveSmokeReport(t, report)
	}()

	a := New()
	caps, err := a.Detect(context.Background())
	if err != nil || !a.Available() {
		t.Fatalf("detect: %v / available=%v", err, a.Available())
	}
	report["version"] = caps.Version

	ws := t.TempDir() // 最小隔离 workspace
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	h, err := a.Start(ctx, adapter.StartRequest{
		WorkspaceRoot: ws,
		Prompt:        "这是一个连通性冒烟测试。只回复两个字符：OK",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	report["start"] = "ok"
	instanceID := ""
	if ih, ok := h.(adapter.InstanceIDHandle); ok {
		instanceID = ih.InstanceID()
	}
	report["instance_id_present"] = instanceID != ""

	// 收集首个 turn 的 canonical 事件；正文脱敏，只记录类型与 delta 计数。
	var gotFinal bool
	deltaCount := 0
	eventTypes := map[string]int{}
	deadline := time.After(2 * time.Minute)
collect:
	for !gotFinal {
		select {
		case ev, ok := <-h.Events():
			if !ok {
				break collect
			}
			key := string(ev.Type)
			eventTypes[key]++
			switch ev.Type {
			case adapter.EventMessageDelta:
				deltaCount++
			case adapter.EventMessageCompleted:
				gotFinal = true
				break collect
			case adapter.EventSessionError:
				t.Fatalf("session_error: %v", ev.Payload)
			}
		case <-deadline:
			t.Fatalf("等待回复超时；events=%v", eventTypes)
		case <-ctx.Done():
			t.Fatalf("ctx: %v", ctx.Err())
		}
	}
	report["chat_turn"] = map[string]any{
		"final_received": gotFinal,
		"delta_count":    deltaCount,
		"event_types":    eventTypes,
	}

	// 显式 stop 链路验证：发起第二个 turn 并立即 abort（限量预算内的第二个请求）。
	sendCtx, sendCancel := context.WithTimeout(ctx, 15*time.Second)
	err = h.Send(sendCtx, "请开始一个非常长的任务，不需要真的执行。")
	sendCancel()
	report["abort_turn_started"] = err == nil
	if err == nil {
		abortCtx, abortCancel := context.WithTimeout(ctx, 10*time.Second)
		abortErr := h.Abort(abortCtx)
		abortCancel()
		// 模型秒回时 turn 可能已 completed，interrupt 被服务端拒绝属可接受结局；
		// 报告只记录错误类别，不落原始明文。
		var rpcErr *RPCError
		class := errorClass(abortErr)
		if errors.As(abortErr, &rpcErr) {
			class = fmt.Sprintf("rpc_error_%d", rpcErr.Code)
			abortErr = nil
		}
		report["abort"] = map[string]any{"ok": abortErr == nil, "error_class": class}
	}

	dispenseCtx, dispenseCancel := context.WithTimeout(context.Background(), 10*time.Second)
	_ = h.Dispose(dispenseCtx)
	dispenseCancel()
	closeErr := a.Close()
	report["dispose_close"] = map[string]any{"ok": closeErr == nil || errors.Is(closeErr, ErrRPCProcessExited)}
	if !gotFinal {
		t.Fatal("live smoke 未收到最终回复")
	}
}

func errorClass(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	for _, marker := range []string{"context deadline exceeded", "interrupt", "exited"} {
		if strings.Contains(s, marker) {
			return marker
		}
	}
	return "other" // 不落原始错误明文（可能包含 Provider 信息）
}

// writeLiveSmokeReport 把脱敏报告写到 e2e-verify/reports/<ts>/ADAPTER-CODEX/04.json。
func writeLiveSmokeReport(t *testing.T, report map[string]any) {
	t.Helper()
	raw, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Logf("marshal live smoke report: %v", err)
		return
	}
	dir := filepath.Join("..", "..", "..", "e2e-verify", "reports", time.Now().UTC().Format("20060102T150405Z"), "ADAPTER-CODEX")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Logf("mkdir report dir: %v", err)
		return
	}
	path := filepath.Join(dir, "04.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Logf("write report: %v", err)
		return
	}
	fmt.Printf("live smoke report: %s\n", path)
}

func execLookPath(name string) (string, error) { return exec.LookPath(name) }
