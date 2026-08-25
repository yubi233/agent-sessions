package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// ---------- golden trace fixture 结构 ----------

type goldenFixture struct {
	FixtureVersion int             `json:"fixture_version"`
	CodexVersion   string          `json:"codex_version"`
	Scenarios      []goldenSceneio `json:"scenarios"`
}

type goldenSceneio struct {
	Name           string                 `json:"name"`
	Actions        []goldenAction         `json:"actions"`
	Steps          []goldenStep           `json:"steps"`
	ExpectedEvents []expectedAdapterEvent `json:"expected_events"`
	ExpectedSkills []expectedSkill        `json:"expected_skills"`
}

type expectedSkill struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
	Scope       string `json:"scope"`
}

type goldenAction struct {
	Op        string   `json:"op"`
	Workspace string   `json:"workspace,omitempty"`
	Model     string   `json:"model,omitempty"`
	Prompt    string   `json:"prompt,omitempty"`
	Text      string   `json:"text,omitempty"`
	ThreadID  string   `json:"thread_id,omitempty"`
	ItemID    string   `json:"item_id,omitempty"`
	Decision  string   `json:"decision,omitempty"`
	Value     string   `json:"value,omitempty"`
	Cwds      []string `json:"cwds,omitempty"`
}

type goldenStep struct {
	ExpectRequest struct {
		Method         string         `json:"method"`
		ParamsContains map[string]any `json:"params_contains"`
	} `json:"expect_request"`
	ExpectClientResponse struct {
		ID             json.Number    `json:"id"`
		ResultContains map[string]any `json:"result_contains"`
	} `json:"expect_client_response"`
	Respond    map[string]any   `json:"respond"`
	ThenNotify []map[string]any `json:"then_notify"`
}

type expectedAdapterEvent struct {
	Type    adapter.EventType `json:"type"`
	Payload map[string]any    `json:"payload"`
}

func loadGoldenTrace(t *testing.T) goldenFixture {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden_trace.json")
	if err != nil {
		t.Fatalf("read golden trace: %v", err)
	}
	var f goldenFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parse golden trace: %v", err)
	}
	return f
}

// ---------- 确定性 fake app-server（按 fixture 步骤驱动） ----------

type scriptedServer struct {
	mu     sync.Mutex
	steps  []goldenStep
	cursor int
	respQ  []goldenStep // expect_client_response 队列（与请求步骤分开消费）
	lines  []string
	wg     sync.WaitGroup
}

func startScriptedServer(t *testing.T, steps []goldenStep) (*RPCClient, *scriptedServer) {
	t.Helper()
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	s := &scriptedServer{steps: steps}
	for _, st := range steps {
		if st.ExpectClientResponse.ID != "" {
			s.respQ = append(s.respQ, st)
		}
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
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
			s.mu.Lock()
			s.lines = append(s.lines, line)
			if _, hasMethod := req["method"]; !hasMethod && len(s.respQ) > 0 {
				// 客户端响应行（无 method）：按 expect_client_response 队列校验。
				want := s.respQ[0]
				s.respQ = s.respQ[1:]
				s.mu.Unlock()
				gotID := fmt.Sprint(req["id"])
				if gotID != want.ExpectClientResponse.ID.String() {
					t.Errorf("client response id = %s, want %s (%s)", gotID, want.ExpectClientResponse.ID, line)
				}
				result, _ := req["result"].(map[string]any)
				if !paramsContains(result, want.ExpectClientResponse.ResultContains) {
					t.Errorf("client response result mismatch: got %s", line)
				}
				continue
			}
			idx := s.cursor
			s.cursor++
			stepOK := idx < len(s.steps)
			var step goldenStep
			if stepOK {
				step = s.steps[idx]
			}
			s.mu.Unlock()
			if !stepOK {
				continue
			}
			method, _ := req["method"].(string)
			if method != step.ExpectRequest.Method {
				s.mu.Lock()
				s.cursor = len(s.steps) // 停止脚本，让断言在主测程失败
				s.mu.Unlock()
				continue
			}
			if len(step.ExpectRequest.ParamsContains) > 0 && !paramsContains(req["params"], step.ExpectRequest.ParamsContains) {
				t.Errorf("step %d (%s) params mismatch: want contains %v, got %s", idx, method, step.ExpectRequest.ParamsContains, line)
			}
			if resp, ok := step.Respond["error"]; ok {
				raw, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req["id"], "error": resp})
				writer.Write(raw)
				writer.WriteString("\n")
			} else if result, ok := step.Respond["result"]; ok {
				raw, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req["id"], "result": result})
				writer.Write(raw)
				writer.WriteString("\n")
			}
			for _, n := range step.ThenNotify {
				raw, _ := json.Marshal(n)
				writer.Write(raw)
				writer.WriteString("\n")
			}
			writer.Flush()
		}
	}()
	client := newRPCClientOnStreams(stdinW, stdoutR, nil)
	t.Cleanup(func() {
		_ = client.stdin.Close()
		s.wg.Wait()
	})
	return client, s
}

// paramsContains 递归子集匹配：expected 中每个键都必须出现在实际 params 且值相等。
func paramsContains(params any, expected map[string]any) bool {
	obj, ok := params.(map[string]any)
	if !ok {
		return false
	}
	for k, want := range expected {
		got, exists := obj[k]
		if !exists {
			return false
		}
		switch w := want.(type) {
		case map[string]any:
			if !paramsContains(got, w) {
				return false
			}
		case []any:
			g, ok := got.([]any)
			if !ok || len(g) != len(w) {
				return false
			}
			for i := range w {
				wm, wok := w[i].(map[string]any)
				if wok {
					if !paramsContains(g[i], wm) {
						return false
					}
					continue
				}
				if g[i] != w[i] {
					return false
				}
			}
		default:
			if fmt.Sprint(got) != fmt.Sprint(want) {
				return false
			}
		}
	}
	return true
}

// ---------- ADPT-CODEX-02：thread/session 映射 golden trace 契约 ----------

func TestGoldenTraceThreadSessionMapping(t *testing.T) {
	fixture := loadGoldenTrace(t)
	if fixture.CodexVersion == "" {
		t.Fatal("fixture 缺少 codex_version 锚点")
	}
	for _, scenario := range fixture.Scenarios {
		scenario := scenario
		t.Run(scenario.Name, func(t *testing.T) {
			client, server := startScriptedServer(t, scenario.Steps)
			a := NewWithRPC(func(context.Context) (*RPCClient, error) { return client, nil })
			t.Cleanup(func() { _ = a.Close() })

			var (
				handleMu sync.Mutex
				h        adapter.Handle
			)
			events := make(chan adapter.Event, 256)

			for _, action := range scenario.Actions {
				switch action.Op {
				case "start":
					got, err := a.Start(context.Background(), adapter.StartRequest{
						WorkspaceRoot: action.Workspace,
						Model:         action.Model,
						Prompt:        action.Prompt,
					})
					if err != nil {
						t.Fatalf("Start: %v", err)
					}
					handleMu.Lock()
					h = got
					handleMu.Unlock()
					go collectEvents(got, events)
				case "send":
					handleMu.Lock()
					cur := h
					handleMu.Unlock()
					if cur == nil {
						t.Fatalf("%s: send 前没有 handle", scenario.Name)
					}
					if err := cur.Send(context.Background(), action.Text); err != nil {
						t.Fatalf("Send: %v", err)
					}
				case "abort":
					handleMu.Lock()
					cur := h
					handleMu.Unlock()
					if cur == nil {
						t.Fatalf("%s: abort 前没有 handle", scenario.Name)
					}
					if err := cur.Abort(context.Background()); err != nil {
						t.Fatalf("Abort: %v", err)
					}
				case "resume":
					res, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: action.ThreadID})
					if err != nil {
						t.Fatalf("Resume: %v", err)
					}
					if res.Result != adapter.WakeResumed {
						t.Fatalf("resume result = %q, want resumed", res.Result)
					}
					handleMu.Lock()
					h = resumeHandleOf(a, action.ThreadID)
					handleMu.Unlock()
					go collectEvents(h, events)
				case "resume_expect_unsupported":
					res, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: action.ThreadID})
					if err != nil {
						t.Fatalf("Resume error: %v", err)
					}
					if res.Result != adapter.WakeUnsupported {
						t.Fatalf("resume result = %q, want unsupported（禁止伪装成功）", res.Result)
					}
				case "select_model":
					handleMu.Lock()
					cur := h
					handleMu.Unlock()
					ch, ok := cur.(*handle)
					if !ok {
						t.Fatalf("%s: select_model 需要 *handle", scenario.Name)
					}
					ch.SetModel(action.Value)
				case "select_effort":
					handleMu.Lock()
					cur := h
					handleMu.Unlock()
					ch, ok := cur.(*handle)
					if !ok {
						t.Fatalf("%s: select_effort 需要 *handle", scenario.Name)
					}
					ch.SetEffort(action.Value)
				case "decide":
					// 等待审批请求到达（异步泵）。
					var decided bool
					waitDeadline := time.Now().Add(3 * time.Second)
					for time.Now().Before(waitDeadline) {
						a.mu.Lock()
						_, exists := a.pendingApprovals[action.ItemID]
						a.mu.Unlock()
						if !exists {
							time.Sleep(10 * time.Millisecond)
							continue
						}
						if err := a.Decide(context.Background(), action.ItemID, action.Decision); err != nil {
							t.Fatalf("Decide: %v", err)
						}
						decided = true
						break
					}
					if !decided {
						t.Fatalf("%s: 等待审批请求 item_id=%s 超时", scenario.Name, action.ItemID)
					}
				case "skills":
					skills, err := a.Skills(context.Background(), action.Cwds)
					if err != nil {
						t.Fatalf("Skills: %v", err)
					}
					if len(skills) != len(scenario.ExpectedSkills) {
						t.Fatalf("skills len = %d, want %d; got=%+v", len(skills), len(scenario.ExpectedSkills), skills)
					}
					for i, want := range scenario.ExpectedSkills {
						got := skills[i]
						if got.Name != want.Name || got.Description != want.Description ||
							got.Enabled != want.Enabled || got.Scope != want.Scope {
							t.Errorf("skill[%d] = %+v, want %+v", i, got, want)
						}
					}
				default:
					t.Fatalf("未知 action op %q", action.Op)
				}
			}

			// 收集事件直到达到期望数量或超时。
			// 注意：deadline 命中必须用带标签的 break 退出 for 循环。
			// 裸 break 只能退出 select——并行包测试拖慢事件生产时，
			// 该循环会在 deadline 就绪后永久空转，把整个测试包拖到
			// go test 的 10 分钟超时（v0.6 发布门实测复现）。
			var got []adapter.Event
			deadline := time.After(3 * time.Second)
		collect:
			for len(got) < len(scenario.ExpectedEvents) {
				select {
				case ev := <-events:
					got = append(got, ev)
				case <-deadline:
					break collect
				}
			}
			time.Sleep(50 * time.Millisecond) // 观察窗口：不应出现多余事件
		drain:
			for {
				select {
				case ev := <-events:
					got = append(got, ev)
				default:
					break drain
				}
			}

			if len(got) != len(scenario.ExpectedEvents) {
				t.Fatalf("event count = %d, want %d; got=%+v", len(got), len(scenario.ExpectedEvents), got)
			}
			for i, want := range scenario.ExpectedEvents {
				if got[i].Type != want.Type {
					t.Errorf("event[%d].type = %q, want %q", i, got[i].Type, want.Type)
					continue
				}
				for k, wv := range want.Payload {
					gv, ok := got[i].Payload[k]
					if !ok {
						t.Errorf("event[%d](%s) missing payload key %q", i, want.Type, k)
						continue
					}
					if fmt.Sprint(gv) != fmt.Sprint(wv) {
						t.Errorf("event[%d](%s).%s = %v, want %v", i, want.Type, k, gv, wv)
					}
				}
			}

			// 全部请求步骤必须被消费：防止脚本提前结束掩盖请求缺失。
			wantSteps := 0
			for _, st := range scenario.Steps {
				if st.ExpectRequest.Method != "" {
					wantSteps++
				}
			}
			server.mu.Lock()
			consumed := server.cursor
			respLeft := len(server.respQ)
			server.mu.Unlock()
			if consumed < wantSteps {
				t.Errorf("script steps consumed = %d, want %d（有请求未被发出）", consumed, wantSteps)
			}
			if respLeft > 0 {
				t.Errorf("%d 条期望的客户端响应未被收到", respLeft)
			}
		})
	}
}

func resumeHandleOf(a *Adapter, threadID string) adapter.Handle {
	a.mu.Lock()
	defer a.mu.Unlock()
	h := a.handles[threadID]
	if h == nil {
		return nil
	}
	return h
}

func collectEvents(h adapter.Handle, into chan<- adapter.Event) {
	if h == nil {
		return
	}
	for ev := range h.Events() {
		into <- ev
	}
}

// Abort 在无活跃 turn 时必须报错，不得伪造成功。
func TestAbortWithoutActiveTurnFails(t *testing.T) {
	step := goldenStep{}
	step.ExpectRequest.Method = "thread/start"
	step.Respond = map[string]any{"result": map[string]any{"thread": map[string]any{"id": "thr_abort"}}}
	client, _ := startScriptedServer(t, []goldenStep{step})
	a := NewWithRPC(func(context.Context) (*RPCClient, error) { return client, nil })
	defer func() { _ = a.Close() }()
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := h.Abort(context.Background()); err == nil {
		t.Fatal("abort without active turn must fail")
	} else if strings.Contains(err.Error(), "interrupt") {
		t.Fatalf("abort 不应发出 turn/interrupt: %v", err)
	}
}

// Detect 能力口径：未配置 bin 时全 unsupported；契约只覆盖 start/resume/abort。
func TestDetectFailClosedWithoutBin(t *testing.T) {
	t.Setenv(EnvBin, "")
	a := NewWithRPC(nil)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	for _, c := range caps.Capabilities {
		if c.Status != adapter.CapabilityUnsupported {
			t.Errorf("capability %s = %s, want unsupported", c.Name, c.Status)
		}
	}
}
