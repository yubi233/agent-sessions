package dsh

// 本文件实现 v0.8.3 P3 的 Go 适配器扩展面（ADR-014 §3-§8 的 SPI 代码化）：
// permission mode（B-1）、session lifecycle（B-3）、question 一次性回答（B-5）、
// dsh/* 扩展统一分发（B-7/8/10）与混合内容发送（B-2）。
// 全部实现挂在外部 *handle 上；失败路径与 P1 权限 one-shot 相同口径：
// 未知/重复/已收口一律 fail-closed，断线不悬挂。

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// JSON-RPC 错误码（桥→客户端请求的收口应答使用）。
const (
	errCodeInvalidParams = -32602
	errCodeCancelled     = -32000
)

// pendingQuestion 是一条等待一次性回答的桥 question 请求。
// requestKey 是桥携带的业务 requestId；bridgeID 是桥发来请求的原始 JSON-RPC id，
// 回答/收口必须原样回写到该 id。
type pendingQuestion struct {
	requestKey string
	bridgeID   int64
	sessionID  string
	resolved   bool
}

// storeAgentPreset 从会话状态响应 _meta 中解析 agent preset（v0.8.5 §3.8）。
// 键 com.deepseek.dsh/agent-preset 只在会话 joined 预设时由桥回带；响应不含
// _meta/键时清空快照（旧值不保留），客户端看到的就是最近一次会话状态事实。
func (h *handle) storeAgentPreset(raw json.RawMessage) {
	preset := ""
	if len(raw) > 0 {
		var meta struct {
			AgentPreset string `json:"com.deepseek.dsh/agent-preset"`
		}
		if json.Unmarshal(raw, &meta) == nil {
			preset = strings.TrimSpace(meta.AgentPreset)
		}
	}
	h.agentPresetMu.Lock()
	defer h.agentPresetMu.Unlock()
	h.agentPreset = preset
}

// AgentPreset 返回会话实际 joined 的 DSH agent preset（空 = 未 joined）。
func (h *handle) AgentPreset() string {
	h.agentPresetMu.Lock()
	defer h.agentPresetMu.Unlock()
	return h.agentPreset
}

// storeModes 把 new/load/resume 响应中的 modes 字段合并进句柄目录快照。
// 桥未广告 mode（字段缺失或目录为空）时保持空快照——能力真值不被伪造。
func (h *handle) storeModes(raw json.RawMessage) {
	if len(raw) == 0 {
		return
	}
	var decoded struct {
		CurrentModeID  string `json:"currentModeId"`
		AvailableModes []struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			Description string `json:"description"`
		} `json:"availableModes"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return
	}
	h.modesMu.Lock()
	defer h.modesMu.Unlock()
	h.modes.CurrentModeID = decoded.CurrentModeID
	h.modes.AvailableModes = h.modes.AvailableModes[:0]
	for _, m := range decoded.AvailableModes {
		h.modes.AvailableModes = append(h.modes.AvailableModes, adapter.SessionMode{
			ID: m.ID, Name: m.Name, Description: m.Description,
		})
	}
}

// Modes 返回最近的 mode 目录快照（SessionModeHandle）。
func (h *handle) Modes() adapter.SessionModeInfo {
	h.modesMu.Lock()
	defer h.modesMu.Unlock()
	out := adapter.SessionModeInfo{CurrentModeID: h.modes.CurrentModeID}
	out.AvailableModes = append(out.AvailableModes, h.modes.AvailableModes...)
	return out
}

// SetMode 运行期切换权限 mode（session/set_mode；ADR-014 §3）。
// 未知/custom mode 由桥拒绝并原样返回错误；成功后以响应中的 modes 刷新快照，
// current_mode_update 通知随后由读循环路径更新 CurrentModeID。
func (h *handle) SetMode(ctx context.Context, modeID string) error {
	modeID = strings.TrimSpace(modeID)
	if modeID == "" {
		return errors.New("session/set_mode 缺少 modeId")
	}
	raw, err := h.request(ctx, "session/set_mode", map[string]any{
		"sessionId": h.sessionID,
		"modeId":    modeID,
	})
	if err != nil {
		return fmt.Errorf("dsh set_mode(%s): %w", modeID, err)
	}
	var res struct {
		Modes json.RawMessage `json:"modes"`
	}
	if json.Unmarshal(raw, &res) == nil {
		h.storeModes(res.Modes)
	}
	return nil
}

// handleQuestionRequest 处理桥的 dsh/question/request（v0.8.3 B-5）：
//  1. 校验 envelope（protocolVersion/sessionId），登记到 pendingQuestions；
//  2. 广播 EventUserQuestion（载荷白名单：request_id/instance_id/questions[]，
//     每题只带 id/title/options/multiSelect/intent/detail 等安全字段）；
//  3. 回答由 ResolveQuestion 一次性回写；断线/Dispose 统一错误应答收口。
//
// 缺 requestId 或重复请求均 fail-closed（错误应答 + 计数）。
func (h *handle) handleQuestionRequest(id int64, params json.RawMessage) {
	var req struct {
		ProtocolVersion int             `json:"protocolVersion"`
		SessionID       string          `json:"sessionId"`
		RequestID       string          `json:"requestId"`
		Items           json.RawMessage `json:"items"`
	}
	if err := json.Unmarshal(params, &req); err != nil || req.RequestID == "" {
		h.respondError(id, errCodeInvalidParams, "dsh/question/request 缺少 requestId 或形状非法")
		h.countDrop("question_bad_request")
		return
	}
	h.questionMu.Lock()
	if _, dup := h.pendingQuestions[req.RequestID]; dup {
		h.questionMu.Unlock()
		h.respondError(id, errCodeInvalidParams, "dsh/question/request 重复 requestId")
		h.countDrop("question_dup_request")
		return
	}
	h.pendingQuestions[req.RequestID] = &pendingQuestion{
		requestKey: req.RequestID,
		bridgeID:   id,
		sessionID:  req.SessionID,
	}
	h.questionMu.Unlock()
	// 广播用户可见的 question 事件。questions 原文是桥已按 wire 契约生成的
	// 白名单数组；这里整体透传（含 intent/detail），不解析拆包避免丢字段。
	payload := map[string]any{
		"instance_id": req.SessionID,
		"request_id":  req.RequestID,
	}
	if len(req.Items) > 0 {
		var items any
		if json.Unmarshal(req.Items, &items) == nil {
			payload["questions"] = items
		}
	}
	h.pushEvent(adapter.Event{Type: adapter.EventUserQuestion, Payload: payload})
}

// ResolveQuestion 把一次性回答写回桥的原始 dsh/question/request（QuestionAnswerHandle）。
// 每个请求只消费一次；未知/重复 requestKey 返回错误（fail-closed）。
func (h *handle) ResolveQuestion(requestKey string, answers []adapter.QuestionAnswerItem) error {
	requestKey = strings.TrimSpace(requestKey)
	if requestKey == "" {
		return errors.New("question 回答缺少 requestKey")
	}
	h.questionMu.Lock()
	pq := h.pendingQuestions[requestKey]
	if pq == nil {
		h.questionMu.Unlock()
		return fmt.Errorf("未知或已处理的 question 请求: %s", requestKey)
	}
	if pq.resolved {
		h.questionMu.Unlock()
		return fmt.Errorf("question 请求已消费，禁止重复回答: %s", requestKey)
	}
	pq.resolved = true
	delete(h.pendingQuestions, requestKey)
	h.questionMu.Unlock()
	// 应答形状与桥 answerFromContent 消费的一致：{answers: [{id, selected, custom}]}。
	items := make([]map[string]any, 0, len(answers))
	for _, ans := range answers {
		item := map[string]any{"id": ans.ID, "selected": ans.Selected}
		if ans.CustomText != "" {
			item["custom"] = ans.CustomText
		}
		items = append(items, item)
	}
	h.respondResult(pq.bridgeID, map[string]any{"answers": items})
	return nil
}

// cancelPendingQuestions 在句柄关闭/断线时把所有未决 question 请求收口为
// 错误应答（桥侧 ask() 快速失败，客户端不悬挂面板；v0.8.3 P3）。
func (h *handle) cancelPendingQuestions() {
	h.questionMu.Lock()
	pending := h.pendingQuestions
	h.pendingQuestions = map[string]*pendingQuestion{}
	h.questionMu.Unlock()
	for _, pq := range pending {
		if pq.resolved {
			continue
		}
		h.respondError(pq.bridgeID, errCodeCancelled, "dsh_extension_cancelled: 会话已关闭")
	}
}

// CallExtension 统一分发 dsh/* 扩展方法（ExtensionDispatchHandle）。
// method 必须在 dsh/ 命名空间且为本文件冻结的调用面；params 注入
// protocolVersion/sessionId envelope（调用方不得伪造跨会话请求）。
func (h *handle) CallExtension(ctx context.Context, method string, params map[string]any) (map[string]any, error) {
	if !strings.HasPrefix(method, DshExtensionNamespace) {
		return nil, fmt.Errorf("扩展方法必须位于 %s 命名空间: %s", DshExtensionNamespace, method)
	}
	if !allowedExtensionMethods[method] {
		return nil, fmt.Errorf("未冻结的扩展方法: %s", method)
	}
	envelope := map[string]any{"protocolVersion": DshExtensionProtocolVersion}
	for k, v := range params {
		envelope[k] = v
	}
	envelope["sessionId"] = h.sessionID
	raw, err := h.request(ctx, method, envelope)
	if err != nil {
		return nil, fmt.Errorf("dsh 扩展调用 %s: %w", method, err)
	}
	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("解析 %s 响应: %w", method, err)
	}
	return result, nil
}

// allowedExtensionMethods 是 CallExtension 的冻结调用面（ADR-014 §7/§8）；
// 通知（dsh/*/changed）不在此列——它们是桥→客户端方向的只读投影。
var allowedExtensionMethods = map[string]bool{
	MethodDshQuestionAnswer:  true, // 异步回答通道（dsh/question/request 的补充）
	MethodDshPlanSetMode:     true,
	MethodDshGoalGet:         true,
	MethodDshGoalMutate:      true,
	MethodDshSkillCatalogGet: true,
	MethodDshSkillInvoke:     true,
}

// CloseSession 执行可恢复的 graceful close（session/close；B-3）：
// 先取消当前 turn，再请求桥关闭会话。幂等：桥对未知/已关闭会话幂等成功；
// 桥进程已退出时同样视为已关闭（无需再请求）。
func (h *handle) CloseSession(ctx context.Context) error {
	if h.transportClosed() {
		return nil
	}
	_ = h.Abort(ctx)
	if _, err := h.request(ctx, "session/close", map[string]any{"sessionId": h.sessionID}); err != nil {
		if h.transportClosed() {
			return nil
		}
		return fmt.Errorf("dsh session/close: %w", err)
	}
	return nil
}

// DeleteSession 删除冷会话（session/delete；B-3）。冷状态门由桥执行：
// 运行中会话桥拒绝（invalid params），墓碑/审计在桥侧 artifact 层完成。
// 句柄侧不做本地状态猜测，只透传桥的判定结果。
func (h *handle) DeleteSession(ctx context.Context) error {
	if _, err := h.request(ctx, "session/delete", map[string]any{"sessionId": h.sessionID}); err != nil {
		return fmt.Errorf("dsh session/delete: %w", err)
	}
	return nil
}

// ForkSession 复制 committed 前缀到新会话并返回桥生成的新 sessionId（B-3）。
// cwd 必填（fork 的完整工作区语义由调用方提供）。
func (h *handle) ForkSession(ctx context.Context, cwd string) (string, error) {
	if strings.TrimSpace(cwd) == "" {
		return "", errors.New("session/fork 缺少 cwd")
	}
	raw, err := h.request(ctx, "session/fork", map[string]any{
		"sessionId":  h.sessionID,
		"cwd":        cwd,
		"mcpServers": []any{},
	})
	if err != nil {
		return "", fmt.Errorf("dsh session/fork: %w", err)
	}
	var res struct {
		SessionID string `json:"sessionId"`
	}
	if err := json.Unmarshal(raw, &res); err != nil || res.SessionID == "" {
		return "", errors.New("session/fork 响应缺少新 sessionId")
	}
	return res.SessionID, nil
}

// SendContent 发送混合内容块（ContentHandle；B-2 图像链路）。
// 复用与 Send 完全相同的 model/effort 前置下发、prompt 槽位与失败收口：
// 文本块转 ACP text，图像块转 ACP image（base64 + MIME；字节只经内存，
// 不写日志/事件/回执）。桥侧 admission（attachment 服务 + 模型 modality）
// 拒绝时按既有 prompt 失败路径广播 session_error/turn_completed。
func (h *handle) SendContent(ctx context.Context, blocks []adapter.ContentBlock) error {
	if len(blocks) == 0 {
		return errors.New("SendContent 需要至少一个内容块")
	}
	prompt := make([]map[string]any, 0, len(blocks))
	for i, block := range blocks {
		switch block.Type {
		case "text":
			prompt = append(prompt, map[string]any{"type": "text", "text": block.Text})
		case "image":
			if len(block.ImageData) == 0 || block.ImageMIME == "" {
				return fmt.Errorf("内容块 %d：图像块缺少数据或 MIME", i)
			}
			prompt = append(prompt, map[string]any{
				"type":     "image",
				"data":     base64.StdEncoding.EncodeToString(block.ImageData),
				"mimeType": block.ImageMIME,
			})
		default:
			return fmt.Errorf("不支持的内容块类型: %s", block.Type)
		}
	}
	return h.sendPromptBlocks(ctx, prompt)
}

// transportClosed 报告桥进程是否已不可用（读循环退出 = EOF/崩溃/Dispose）。
func (h *handle) transportClosed() bool {
	select {
	case <-h.readDone:
		return true
	default:
		return false
	}
}

// ListSessions 通过短生命周期桥连接执行 session/list（SessionListProvider；B-3）。
// 列表是脱敏元数据（sessionId/cwd/updatedAt）；分页游标由桥定义、原样回传。
// 每次调用独立 spawn 探测桥并在完成后回收，不触碰任何运行中会话。
func (a *Adapter) ListSessions(ctx context.Context, cwd string, cursor string) (adapter.SessionListResult, error) {
	tr, err := a.factory()
	if err != nil {
		return adapter.SessionListResult{}, err
	}
	h := newHandle(tr)
	go h.readLoop()
	defer func() { _ = h.Dispose(context.Background()) }()

	initCtx, cancel := withTimeout(ctx, handshakeTimeout)
	defer cancel()
	info, err := h.initialize(initCtx)
	if err != nil {
		return adapter.SessionListResult{}, fmt.Errorf("dsh initialize: %w", err)
	}
	if info.ProtocolVersion != 1 {
		return adapter.SessionListResult{}, fmt.Errorf("dsh 协议版本不符: protocolVersion=%v", info.ProtocolVersion)
	}
	params := map[string]any{}
	if strings.TrimSpace(cwd) != "" {
		params["cwd"] = cwd
	}
	if strings.TrimSpace(cursor) != "" {
		params["cursor"] = cursor
	}
	listCtx, cancelList := withTimeout(ctx, handshakeTimeout)
	defer cancelList()
	raw, err := h.request(listCtx, "session/list", params)
	if err != nil {
		return adapter.SessionListResult{}, fmt.Errorf("dsh session/list: %w", err)
	}
	var res struct {
		Sessions []struct {
			SessionID string `json:"sessionId"`
			CWD       string `json:"cwd"`
			UpdatedAt string `json:"updatedAt"`
		} `json:"sessions"`
		NextCursor string `json:"nextCursor"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return adapter.SessionListResult{}, fmt.Errorf("解析 session/list 响应: %w", err)
	}
	out := adapter.SessionListResult{NextCursor: res.NextCursor}
	for _, s := range res.Sessions {
		if s.SessionID == "" || s.CWD == "" {
			// ACP SessionInfo 要求 cwd；缺失条目跳过而非伪造。
			continue
		}
		out.Sessions = append(out.Sessions, adapter.SessionSummary{
			SessionID: s.SessionID, CWD: s.CWD, UpdatedAt: s.UpdatedAt,
		})
	}
	return out, nil
}
