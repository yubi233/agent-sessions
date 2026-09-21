package dsh

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeSessionJSONL 写一个最小合法的 DSH 会话 artifact（header + 指定行）。
func writeSessionJSONL(t *testing.T, dir, sessionID, cwd string, rows []map[string]any) string {
	t.Helper()
	sessionDir := filepath.Join(dir, "--"+strings.ReplaceAll(strings.TrimPrefix(cwd, "/"), "/", "-")+"--")
	if err := os.MkdirAll(sessionDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	lines := []string{marshalRow(map[string]any{
		"type": "session", "version": 0, "id": sessionID,
		"createdAt": int64(1789673554476), "cwd": cwd, "delegationDepth": 0,
	})}
	for _, row := range rows {
		lines = append(lines, marshalRow(row))
	}
	path := filepath.Join(sessionDir, "session.jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	return path
}

func marshalRow(row map[string]any) string {
	raw, err := json.Marshal(row)
	if err != nil {
		panic(err)
	}
	return string(raw)
}

func msgRow(kind, role, text string, seq, timeMS int64) map[string]any {
	content := []map[string]any{{"type": "text", "text": text}}
	if role == "assistant" {
		return map[string]any{"type": kind, "seq": seq, "time": timeMS, "data": map[string]any{
			"message": map[string]any{"role": "assistant", "content": content},
		}}
	}
	return map[string]any{"type": kind, "seq": seq, "time": timeMS, "data": map[string]any{
		"content": content, "role": role,
	}}
}

// v0.9.4（用户需求：每个历史会话保留十几条上下文与真实标题）：导入读取必须
// 提取 session/title、最近的 user/assistant 正文，跳过 reasoning/工具行，坏行容错。
func TestReadSessionContextExtractsTitleAndTailMessages(t *testing.T) {
	dir := t.TempDir()
	rows := []map[string]any{
		{"type": "permission/preset", "seq": int64(0), "data": map[string]any{"preset": "danger-full-access"}},
		msgRow("user/message", "user", "帮我统计本月支出", 7, 1789673555009),
		{"type": "session/title", "seq": int64(11), "data": map[string]any{"title": "本月支出统计"}},
		msgRow("assistant/message", "assistant", "好的，我来统计。", 267, 1789673559248),
		// reasoning 段不计入上下文正文。
		{"type": "assistant/message", "seq": int64(268), "data": map[string]any{
			"message": map[string]any{"role": "assistant", "content": []map[string]any{
				{"type": "reasoning", "text": "内部思考不应出现在客户端时间线"},
				{"type": "text", "text": "统计完成：共 3 笔。"},
			}},
		}},
		{"type": "not-a-message", "seq": int64(269), "data": map[string]any{}},
		msgRow("user/message", "user", "再算上上周。", 900, 1789673600000),
	}
	path := writeSessionJSONL(t, dir, "sess-jsonl-1", "/tmp/ws", rows)
	// 追加一行坏 JSON，验证坏行容错（构造函数只接受 map，坏行单独追加）。
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("open for append: %v", err)
	}
	if _, err := f.WriteString("{broken json line\n"); err != nil {
		t.Fatalf("append broken line: %v", err)
	}
	_ = f.Close()

	ctx, err := ReadSessionContext(path, 14)
	if err != nil {
		t.Fatalf("ReadSessionContext: %v", err)
	}
	if ctx.Title != "本月支出统计" {
		t.Fatalf("标题应取 session/title: %q", ctx.Title)
	}
	if len(ctx.Messages) != 4 {
		t.Fatalf("正文消息应恰好 4 条（reasoning/工具/坏行跳过）: %d", len(ctx.Messages))
	}
	if ctx.Messages[0].Role != "user" || ctx.Messages[0].Text != "帮我统计本月支出" {
		t.Fatalf("首条应为用户消息: %+v", ctx.Messages[0])
	}
	if ctx.Messages[2].Role != "assistant" || !strings.Contains(ctx.Messages[2].Text, "统计完成") {
		t.Fatalf("第 3 条应只含 text 段（跳过 reasoning）: %+v", ctx.Messages[2])
	}
	if ctx.Messages[3].Text != "再算上上周。" {
		t.Fatalf("尾条应为最后一条用户消息: %+v", ctx.Messages[3])
	}
}

// 超过 limit 时必须保留「最近」的十几条（时间升序截尾），而不是开头。
func TestReadSessionContextKeepsTailWithinLimit(t *testing.T) {
	dir := t.TempDir()
	var rows []map[string]any
	for i := 1; i <= 30; i += 1 {
		rows = append(rows, msgRow("user/message", "user", "消息-"+string(rune('0'+i%10))+string(rune('0'+i/10)), int64(i), int64(1789673555000+i)))
	}
	path := writeSessionJSONL(t, dir, "sess-jsonl-2", "/tmp/ws", rows)

	ctx, err := ReadSessionContext(path, 14)
	if err != nil {
		t.Fatalf("ReadSessionContext: %v", err)
	}
	if len(ctx.Messages) != 14 {
		t.Fatalf("应恰好保留 14 条: %d", len(ctx.Messages))
	}
	// 30 条中的最后 14 条 = 第 17..30 条。
	if ctx.Messages[0].Seq != 17 || ctx.Messages[13].Seq != 30 {
		t.Fatalf("应保留尾部窗口 17..30: first=%d last=%d", ctx.Messages[0].Seq, ctx.Messages[13].Seq)
	}
	// 无 session/title 时回退首条用户消息截断。
	if !strings.HasPrefix(ctx.Title, "消息-") {
		t.Fatalf("标题应回退首条用户消息: %q", ctx.Title)
	}
}

// 空会话（无任何对话行）返回空上下文且不报错——deepseek-harness 这类空存储如实为空。
func TestReadSessionContextEmptySessionIsEmpty(t *testing.T) {
	dir := t.TempDir()
	path := writeSessionJSONL(t, dir, "sess-jsonl-3", "/tmp/ws", nil)
	ctx, err := ReadSessionContext(path, 14)
	if err != nil {
		t.Fatalf("ReadSessionContext: %v", err)
	}
	if ctx.Title != "" || len(ctx.Messages) != 0 {
		t.Fatalf("空会话应返回空上下文: %+v", ctx)
	}
}
