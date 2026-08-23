// Package codexadapter 的 W2 canonical 映射层（ADPT-CODEX-02）。
// 只做 codex app-server 通知/参数 → SPI canonical event/请求的纯映射；
// 协议形状以本机 codex app-server generate-json-schema（0.142.5, v2）为证据锚点。
// 未知 item 类型与未知通知必须安全降级为零事件，不得伪造 canonical 语义。
package codex

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// JSON-RPC 方法名（ClientRequest v2 schema）。
const (
	methodInitialize    = "initialize"
	methodThreadStart   = "thread/start"
	methodThreadResume  = "thread/resume"
	methodTurnStart     = "turn/start"
	methodTurnInterrupt = "turn/interrupt"
	methodSkillsList    = "skills/list"

	notifyInitialized = "initialized" // ClientNotification
)

// initializeAppServer 完成 app-server 必需的 initialize 握手（InitializeParams.clientInfo）。
func initializeAppServer(ctx context.Context, client *RPCClient) error {
	if err := client.Call(ctx, methodInitialize, map[string]any{
		"clientInfo": map[string]string{"name": "agent-sessions-daemon", "version": "dev"},
	}, nil); err != nil {
		return err
	}
	return client.Notify(notifyInitialized, nil)
}

// 服务端通知方法名（ServerNotification v2 schema）。
const (
	notifyThreadStarted     = "thread/started"
	notifyTurnStarted       = "turn/started"
	notifyItemStarted       = "item/started"
	notifyItemCompleted     = "item/completed"
	notifyAgentMessageDelta = "item/agentMessage/delta"
	notifyTurnCompleted     = "turn/completed"

	notifyPlanUpdated   = "turn/plan/updated"   // TurnPlanStep{step,status}
	notifyGoalUpdated   = "thread/goal/updated" // ThreadGoal{objective,status}
	notifySkillsChanged = "skills/changed"
)

// 服务端请求方法名（ServerRequest v2 schema，带 id 回调）。
const (
	serverReqCommandApproval = "item/commandExecution/requestApproval"
)

// 审批决策值（CommandExecutionApprovalDecision / FileChangeApprovalDecision）。
const (
	DecisionAccept  = "accept"
	DecisionDecline = "decline"
	DecisionCancel  = "cancel"
)

// textInput 构造 turn/start params.input 的文本项（UserInput::TextUserInput）。
type textInput struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func buildThreadStartParams(req adapter.StartRequest) map[string]any {
	params := map[string]any{}
	if req.WorkspaceRoot != "" {
		params["cwd"] = req.WorkspaceRoot
	}
	if req.Model != "" {
		params["model"] = req.Model
	}
	return params
}

func buildThreadResumeParams(threadID string) map[string]any {
	return map[string]any{"threadId": threadID}
}

func buildTurnStartParams(threadID, text string, model, effort string) map[string]any {
	params := map[string]any{
		"threadId": threadID,
		"input":    []textInput{{Type: "text", Text: text}},
	}
	if model != "" {
		params["model"] = model
	}
	if effort != "" {
		params["effort"] = effort
	}
	return params
}

func buildTurnInterruptParams(threadID, turnID string) map[string]any {
	return map[string]any{"threadId": threadID, "turnId": turnID}
}

// threadStartResponse 是 thread/start|thread/resume 结果中 adapter 关心的子集。
type threadStartResponse struct {
	Thread struct {
		ID    string `json:"id"`
		Turns []struct {
			ID string `json:"id"`
		} `json:"turns"`
	} `json:"thread"`
}

// turnStartResponse 是 turn/start 结果中关心的子集。
type turnStartResponse struct {
	Turn struct {
		ID string `json:"id"`
	} `json:"turn"`
}

// 通知 params 的公共信封（按字段惰性解析）。
type notificationEnvelope struct {
	ThreadID string          `json:"threadId"`
	Item     json.RawMessage `json:"item"`
	Turn     struct {
		ID     string `json:"id"`
		Status string `json:"status"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	} `json:"turn"`
	Delta  string `json:"delta"`
	ItemID string `json:"itemId"`
}

// threadItemCore 是 ThreadItem oneOf 各分支中 mapper 消费的公共子集。
type threadItemCore struct {
	ID               string `json:"id"`
	Type             string `json:"type"`
	Text             string `json:"text"`
	Command          string `json:"command"`
	Tool             string `json:"tool"`
	Status           string `json:"status"`
	ExitCode         *int   `json:"exitCode"`
	AggregatedOutput string `json:"aggregatedOutput"`
}

// mapNotification 把一条服务端通知映射为零或多条 canonical 事件（不含 Seq）。
// 返回 (nil, nil) 表示该通知不产生 canonical 语义（安全降级）。
func mapNotification(n RPCNotification) []adapter.Event {
	switch n.Method {
	case notifyTurnStarted:
		var env notificationEnvelope
		if json.Unmarshal(n.Params, &env) != nil || env.Turn.ID == "" {
			return nil
		}
		return []adapter.Event{{
			Type: adapter.EventTurnStarted,
			Payload: map[string]any{
				"thread_id": env.ThreadID,
				"turn_id":   env.Turn.ID,
			},
		}}
	case notifyAgentMessageDelta:
		var env notificationEnvelope
		if json.Unmarshal(n.Params, &env) != nil || env.ItemID == "" {
			return nil
		}
		return []adapter.Event{{
			Type: adapter.EventMessageDelta,
			Payload: map[string]any{
				"item_id": env.ItemID,
				"delta":   env.Delta,
			},
		}}
	case notifyItemStarted:
		return mapItemEvent(n.Params, false)
	case notifyItemCompleted:
		return mapItemEvent(n.Params, true)
	case notifyTurnCompleted:
		var env notificationEnvelope
		if json.Unmarshal(n.Params, &env) != nil {
			return nil
		}
		if env.Turn.Status != "failed" {
			// completed/interrupted 不伪造 canonical 终态事件；失败才需要脱敏错误上报。
			return nil
		}
		// TurnError.message 属 Provider 明文，按隐私边界只上报脱敏固定文案。
		return []adapter.Event{{
			Type:    adapter.EventSessionError,
			Payload: map[string]any{"message": "Codex turn 执行失败（详情仅限本机诊断）。"},
		}}
	case notifyPlanUpdated:
		var env struct {
			Plan []struct {
				Step   string `json:"step"`
				Status string `json:"status"`
			} `json:"plan"`
		}
		if json.Unmarshal(n.Params, &env) != nil || len(env.Plan) == 0 {
			return nil
		}
		steps := make([]string, 0, len(env.Plan))
		statuses := make([]string, 0, len(env.Plan))
		for _, s := range env.Plan {
			steps = append(steps, s.Step)
			statuses = append(statuses, s.Status)
		}
		return []adapter.Event{{
			Type: adapter.EventPlanChanged,
			Payload: map[string]any{
				"steps":    steps,
				"statuses": statuses,
			},
		}}
	case notifyGoalUpdated:
		var env struct {
			Goal struct {
				Objective string `json:"objective"`
				Status    string `json:"status"`
			} `json:"goal"`
		}
		if json.Unmarshal(n.Params, &env) != nil || env.Goal.Objective == "" {
			return nil
		}
		return []adapter.Event{{
			Type: adapter.EventGoalChanged,
			Payload: map[string]any{
				"objective": env.Goal.Objective,
				"status":    env.Goal.Status,
			},
		}}
	default:
		// skills/changed 等其余通知：catalog 刷新走 Skills() 主动拉取，不伪造事件。
		return nil
	}
}

// mapApprovalRequest 把服务端审批请求映射为 canonical permission_request 事件。
// 返回 (itemID, command, event)；无法解析时 itemID 为空。
func mapApprovalRequest(method string, params json.RawMessage) (string, string, adapter.Event) {
	if method != serverReqCommandApproval {
		return "", "", adapter.Event{}
	}
	var p struct {
		ItemID  string `json:"itemId"`
		Command string `json:"command"`
	}
	if json.Unmarshal(params, &p) != nil || p.ItemID == "" {
		return "", "", adapter.Event{}
	}
	command := p.Command
	if command == "" {
		// command 数组形态（ExecCommandApprovalParams.parsedCmd 兄弟字段）兜底。
		var alt struct {
			Command []string `json:"command"`
		}
		if json.Unmarshal(params, &alt) == nil {
			command = strings.Join(alt.Command, " ")
		}
	}
	ev := adapter.Event{
		Type: adapter.EventPermissionRequest,
		Payload: map[string]any{
			"item_id": p.ItemID,
			"tool":    "commandExecution",
			"command": command,
		},
	}
	return p.ItemID, command, ev
}

// mapItemEvent 映射 item/started 与 item/completed。
func mapItemEvent(params json.RawMessage, completed bool) []adapter.Event {
	var env notificationEnvelope
	if json.Unmarshal(params, &env) != nil || len(env.Item) == 0 {
		return nil
	}
	var item threadItemCore
	if json.Unmarshal(env.Item, &item) != nil || item.ID == "" {
		return nil
	}
	switch item.Type {
	case "agentMessage":
		if !completed || item.Text == "" {
			return nil // started 阶段无正文，delta 已覆盖
		}
		return []adapter.Event{{
			Type: adapter.EventMessageCompleted,
			Payload: map[string]any{
				"item_id": item.ID,
				"text":    item.Text,
			},
		}}
	case "commandExecution", "mcpToolCall", "dynamicToolCall":
		name := item.Command
		if name == "" {
			name = item.Tool
		}
		if name == "" {
			name = item.Type
		}
		if completed {
			payload := map[string]any{"item_id": item.ID, "tool": item.Type}
			if item.ExitCode != nil {
				payload["exit_code"] = *item.ExitCode
			}
			if item.AggregatedOutput != "" {
				payload["output"] = item.AggregatedOutput
			}
			return []adapter.Event{{Type: adapter.EventToolResult, Payload: payload}}
		}
		return []adapter.Event{{
			Type: adapter.EventToolCall,
			Payload: map[string]any{
				"tool":    item.Type,
				"item_id": item.ID,
				"command": name,
			},
		}}
	case "fileChange":
		phase := "started"
		if completed {
			phase = "completed"
		}
		return []adapter.Event{{
			Type: adapter.EventFileChange,
			Payload: map[string]any{
				"item_id": item.ID,
				"phase":   phase,
			},
		}}
	case "plan":
		if !completed || item.Text == "" {
			return nil // plan delta/completed 权威口径以 completed 为准
		}
		return []adapter.Event{{
			Type: adapter.EventPlanChanged,
			Payload: map[string]any{
				"text": item.Text,
			},
		}}
	default:
		// reasoning/webSearch/subAgentActivity 等未知或暂不映射的类型：安全降级。
		return nil
	}
}
