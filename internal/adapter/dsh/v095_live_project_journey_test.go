package dsh

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// v0.9.5 真实项目多轮旅程（无模型外依赖；门控 AGENT_SESSIONS_DSH_REAL=1 且
// AGENT_SESSIONS_DSH_PROJECT=<项目绝对路径> 同时设置才运行，默认跳过）：
// 桥按生产路径绑定项目工作区（<project>/.dsh-sessions），模型以项目为 cwd
// 进行多轮真实会话——①审读找交互缺陷（只报告）→ ②实施修复 → ③用项目自带
// 验证命令自检。本测试会把模型改动写入真实项目：调用方须先自行快照备份。
// 模型白名单沿用用户 2026-09-25 授权（goat xiaomi/deepseek、sub2api gemini、
// opencode-zen 全部），尝试顺序 goat xiaomi 优先。
func TestV095LiveProjectInteractionDefectJourney(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_DSH_REAL") != "1" {
		t.Skip("AGENT_SESSIONS_DSH_REAL != 1：跳过真实项目多轮旅程")
	}
	project := strings.TrimSpace(os.Getenv("AGENT_SESSIONS_DSH_PROJECT"))
	if project == "" {
		t.Skip("AGENT_SESSIONS_DSH_PROJECT 未设置：跳过真实项目多轮旅程")
	}
	if !filepath.IsAbs(project) {
		t.Fatalf("项目路径必须是绝对路径: %s", project)
	}
	if info, err := os.Stat(project); err != nil || !info.IsDir() {
		t.Fatalf("项目路径不可用: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	// 桥按生产路径绑定项目工作区。
	tr, err := newBinTransportForWorkspace(project)
	if err != nil {
		t.Fatalf("项目绑定启动桥: %v", err)
	}
	h := newHandle(tr)
	go h.readLoop()
	defer func() { _ = h.Dispose(context.Background()) }()

	// settings 热发布有 debounce：立即握手目录会退化为合成默认路由
	//（记录 35 §4.2），等一拍再握手。
	time.Sleep(1500 * time.Millisecond)
	initCtx, cancelInit := withTimeout(ctx, handshakeTimeoutFor())
	info, err := h.initialize(initCtx)
	cancelInit()
	if err != nil {
		t.Fatalf("initialize: %v\n桥 stderr:\n%s", err, tr.stderr.digest())
	}
	if err := bridgeHandshakeAllowed(info); err != nil {
		t.Fatalf("版本门: %v", err)
	}
	for _, group := range info.ModelCatalog.Groups {
		for _, model := range group.Models {
			t.Logf("catalog model: provider=%s id=%s", group.ID, model.ID)
		}
	}
	newCtx, cancelNew := withTimeout(ctx, handshakeTimeoutFor())
	sessionID, err := h.newSession(newCtx, project)
	cancelNew()
	if err != nil {
		t.Fatalf("session/new: %v", err)
	}
	h.setSessionID(sessionID)

	// 模型白名单（用户 2026-09-25 授权）∩ 目录，goat xiaomi 优先。
	picked := ""
	for _, group := range info.ModelCatalog.Groups {
		for _, model := range group.Models {
			id := strings.ToLower(model.ID)
			if group.ID == "goat" && id == "xiaomi/mimo-v2.6-flash" {
				picked = model.Value
			}
		}
	}
	if picked == "" {
		for _, group := range info.ModelCatalog.Groups {
			for _, model := range group.Models {
				id := strings.ToLower(model.ID)
				if (group.ID == "goat" && strings.Contains(id, "deepseek")) ||
					(group.ID == "sub2api" && id == "gemini-3.8-flash") {
					picked = model.Value
					break
				}
			}
			if picked != "" {
				break
			}
		}
	}
	if picked == "" {
		t.Skip("目录中没有已授权模型")
	}
	t.Logf("model=%s", picked)
	h.SetModel(picked)

	// 持续消费事件：按回合收集 assistant 正文（跨回合共享，互不丢帧）。
	var mu sync.Mutex
	replies := make([]string, 0, 4)
	go func() {
		for event := range h.Events() {
			if event.Type == adapter.EventMessageCompleted {
				if text, _ := event.Payload["text"].(string); strings.TrimSpace(text) != "" {
					mu.Lock()
					replies = append(replies, text)
					mu.Unlock()
				}
			}
		}
	}()

	runTurn := func(label, prompt string) string {
		turnCtx, cancelTurn := context.WithTimeout(ctx, 12*time.Minute)
		defer cancelTurn()
		sendErr := h.Send(turnCtx, prompt)
		if sendErr != nil {
			t.Fatalf("%s 轮真实调用失败: %v\n桥 stderr:\n%s", label, sendErr, tr.stderr.digest())
		}
		// 回合结束（Send 返回）后稍等事件尾帧落账。
		deadline := time.Now().Add(5 * time.Second)
		var before int
		for time.Now().Before(deadline) {
			mu.Lock()
			before = len(replies)
			mu.Unlock()
			time.Sleep(300 * time.Millisecond)
			mu.Lock()
			settled := len(replies) == before
			mu.Unlock()
			if settled && before > 0 {
				break
			}
		}
		mu.Lock()
		defer mu.Unlock()
		if len(replies) == 0 {
			t.Fatalf("%s 轮未收到助手正文\n桥 stderr:\n%s", label, tr.stderr.digest())
		}
		last := replies[len(replies)-1]
		t.Logf("%s 轮回复（截断 600 字）: %s", label, truncateRunes(last, 600))
		return last
	}

	runTurn("T1 审读", "这是一个 Babylon.js + TypeScript 的 3D 幸存者类游戏项目（你的当前工作目录）。请审读玩家交互相关代码（移动、瞄准/朝向、拾取、升级选择、暂停、UI 响应等），找出一个真实存在、影响玩家体验的交互缺陷。本轮只报告不要修改：给出文件路径、复现行为、根因、影响面。")
	runTurn("T2 修复", "按你上一轮报告的缺陷实施修复：改动最小化、保持现有代码风格；完成后列出改动文件与关键改动点。")
	runTurn("T3 自检", "运行 npm run typecheck 验证改动没有破坏编译；如项目存在针对性自检脚本且与本次改动相关，一并运行。如实报告命令结果，失败就说明失败在哪。")

	artifactRel, err := filepath.Rel(project, filepath.Join(project, ".dsh-sessions"))
	if err != nil {
		artifactRel = ".dsh-sessions"
	}
	t.Logf("LIVE_SUMMARY provider=dsh protocol=1 project_bound=%s real_model=3 model=%s turns=3", artifactRel, picked)
}
