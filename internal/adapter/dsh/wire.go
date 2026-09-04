package dsh

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 本文件是 v0.8.3 P0 冻结的 DSH ACP 扩展 wire 契约（ADR-014 §7/§8 的代码化事实源）。
// 桥侧（deepseek-harness TS）按同一形状实现；两侧只依赖这里的类型与校验，
// 禁止直接复用 DSH 插件私有 JSON（未稳定、含路径/正文/凭据等非白名单字段）。
//
// 设计要点：
//   - 每个扩展帧至少携带 protocolVersion 与 sessionId；长交互另带 requestId，
//     状态修改另带 expectedRevision（CAS）。JSON-RPC id 仍用于单次 method response。
//   - 未知字段一律拒绝（严格 schema），版本只允许向后兼容的 minor 升级。
//   - 所有脱敏白名单在这里收口：路径、skill body、凭据、task envelope、child 正文
//     都不定义字段，天然无法进入公共协议。

// DshExtensionNamespace 是扩展方法/通知的命名空间前缀（ADR-014 §7 冻结）。
// 方法形如 dsh/<domain>/<verb>，通知形如 dsh/<domain>/changed。
const DshExtensionNamespace = "dsh/"

// DshExtensionMetaKey 是 initialize 双向协商使用的 namespaced _meta 键。
// 客户端在 clientCapabilities._meta 声明可处理的扩展及版本；
// 桥在 agentCapabilities._meta 的同名键报告自己的目录。
const DshExtensionMetaKey = "com.deepseek.dsh/extensions"

// DshExtensionProtocolVersion 是当前扩展契约的协议 major 版本。
// 只允许向后兼容的 minor 升级；major 不匹配 fail-closed。
const DshExtensionProtocolVersion = 1

// dsh/* 方法与通知名（P0 冻结清单；新增必须先修订 ADR-014）。
// 客户端→桥的方法名以 adapter 包公共常量为唯一事实源（daemon runner 经
// ExtensionDispatchHandle 分发同一批名字），这里只保留语义别名。
const (
	// question/plan/goal/skill 的扩展方法。
	MethodDshQuestionAnswer  = adapter.ExtensionMethodQuestionAnswer // 客户端 → 桥：一次性回答
	MethodDshPlanSetMode     = adapter.ExtensionMethodPlanSetMode    // 客户端 → 桥：切换 session-scoped plan mode
	MethodDshGoalGet         = adapter.ExtensionMethodGoalGet        // 客户端 → 桥：读取 goal projection
	MethodDshGoalMutate      = adapter.ExtensionMethodGoalMutate     // 客户端 → 桥：CAS 变更 goal
	MethodDshSkillCatalogGet = adapter.ExtensionMethodSkillCatalog   // 客户端 → 桥：读取安全目录（含 catalogRevision）
	MethodDshSkillInvoke     = adapter.ExtensionMethodSkillInvoke    // 客户端 → 桥：显式调用 user-invocable skill
	// 状态变更通知（桥 → 客户端，只读投影）。
	NotifyDshPlanChanged       = "dsh/plan/changed" // committed {active,pending} projection
	NotifyDshGoalChanged       = "dsh/goal/changed" // goal projection / round 状态
	NotifyDshSkillCatalogChg   = "dsh/skill/catalog_changed"
	NotifyDshDelegationChanged = "dsh/delegation/changed" // subagent 生命周期 observe-only 投影
	// NotifyDshTurnStatus 是 v0.8.4 的回合阶段通知（ADR-015 §3 冻结）：
	// 桥是实时 phase 的唯一权威；未协商 "dsh/turn/status" 的客户端不得收到。
	NotifyDshTurnStatus = "dsh/turn/status"
	// DshChunkMetaKey 是流式增量/committed 帧的 namespaced _meta 键（ADR-015 §4）：
	// { kind: "text-delta"|"committed", turn, step, seq, messageId? }。
	DshChunkMetaKey = "com.deepseek.dsh/chunk"
	// DshThoughtMetaKey 是 thought 帧的 namespaced _meta 键（ADR-015 §5）：
	// { kind: "thought-delta", turn, step, seq, visibility: "raw" }。
	DshThoughtMetaKey = "com.deepseek.dsh/thought"
	// DshUsageMetaKey 是 usage_update 帧的 timing _meta 键（v0.8.5 §3.7）：
	// { turn, step, ttftMs, decodeThroughput, outputTokens }——折算公式与 dsh 前端/
	// session-stats fold 完全一致；无流式/replay 轮次桥不发该 meta。
	DshUsageMetaKey = "com.deepseek.dsh/usage-timing"
	// NegotiationEntryTurnStatus / NegotiationEntryThought 是 initialize 协商
	// 目录中的扩展条目名（复用 com.deepseek.dsh/extensions 的 major.minor 规则）。
	NegotiationEntryTurnStatus = "dsh/turn/status"
	NegotiationEntryThought    = "dsh/thought"
)

// 扩展错误码（ADR-014 §7.1 冻结）。字符串码进扩展 payload/日志，
// JSON-RPC code 沿用标准语义：-32601 方法不存在、-32602 参数非法、-32000 自定义失败。
const (
	ErrCodeExtensionUnsupported    = "dsh_extension_unsupported"     // 客户端未声明或桥未启用
	ErrCodeExtensionMajorMismatch  = "dsh_extension_major_mismatch"  // 协议 major 不兼容
	ErrCodeExtensionInvalidPayload = "dsh_extension_invalid_payload" // 严格 schema 校验失败（含未知字段）
	ErrCodeExtensionDuplicateReq   = "dsh_extension_duplicate_request"
	ErrCodeExtensionStaleRevision  = "dsh_extension_stale_revision"
	ErrCodeExtensionCrossSession   = "dsh_extension_cross_session"
	ErrCodeExtensionCancelled      = "dsh_extension_cancelled" // 超时/断线/dispose 收口终态
)

// ExtensionNegotiation 是 initialize _meta 协商载体：
// 客户端声明 { method: "major.minor" }；桥按 major 相同且 minor ≤ 自身版本启用。
type ExtensionNegotiation map[string]string

// ParseExtensionNegotiation 从 initialize 的 _meta 值解析客户端声明。
// 形状非法（非对象、版本串不合法）返回错误——协商失败按未声明处理，
// 桥不得对未声明的扩展发送任何请求或通知（fail-closed）。
func ParseExtensionNegotiation(raw json.RawMessage) (ExtensionNegotiation, error) {
	if len(raw) == 0 {
		return ExtensionNegotiation{}, nil
	}
	var declared map[string]string
	dec := json.NewDecoder(bytes.NewReader(raw))
	// 严格 schema：未知形状（数组/标量）直接拒绝；对象值必须是 "major.minor" 版本串。
	dec.DisallowUnknownFields()
	if err := dec.Decode(&declared); err != nil {
		return nil, fmt.Errorf("%s: %w", ErrCodeExtensionInvalidPayload, err)
	}
	for method, version := range declared {
		if !strings.HasPrefix(method, DshExtensionNamespace) {
			return nil, fmt.Errorf("%s: 扩展方法必须位于 %s 命名空间: %q", ErrCodeExtensionInvalidPayload, DshExtensionNamespace, method)
		}
		if !validExtensionVersion(version) {
			return nil, fmt.Errorf("%s: 非法扩展版本 %q (%s)", ErrCodeExtensionInvalidPayload, version, method)
		}
	}
	return declared, nil
}

// validExtensionVersion 校验 "major.minor" 形状（两段均为非负整数）。
func validExtensionVersion(v string) bool {
	major, minor, ok := strings.Cut(v, ".")
	if !ok || major == "" || minor == "" {
		return false
	}
	for _, part := range []string{major, minor} {
		for _, r := range part {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

// ExtensionAccepted 判断桥是否应响应该扩展：客户端已声明、major 与桥一致、
// minor 不超过桥实现版本（向后兼容）。任何不满足都返回 false（fail-closed）。
func ExtensionAccepted(declared ExtensionNegotiation, method string, bridgeMajor, bridgeMinor int) bool {
	version, ok := declared[method]
	if !ok {
		return false
	}
	majorStr, minorStr, ok := strings.Cut(version, ".")
	if !ok {
		return false
	}
	var major, minor int
	if _, err := fmt.Sscanf(majorStr, "%d", &major); err != nil || major != bridgeMajor {
		return false
	}
	if _, err := fmt.Sscanf(minorStr, "%d", &minor); err != nil || minor > bridgeMinor {
		return false
	}
	return true
}

// ExtensionEnvelope 是所有 dsh/* 扩展帧的公共信封（ADR-014 §7）。
// 各具体 payload 结构体内嵌本信封；sessionId 缺失或与目标会话不一致按
// dsh_extension_cross_session / invalid_payload 拒绝。
type ExtensionEnvelope struct {
	ProtocolVersion  int    `json:"protocolVersion"`
	SessionID        string `json:"sessionId"`
	RequestID        string `json:"requestId,omitempty"`        // 长交互幂等键；状态修改可省略
	ExpectedRevision int64  `json:"expectedRevision,omitempty"` // CAS：状态修改必带
}

// validateEnvelope 校验公共信封：协议 major 必须匹配、sessionId 必填；
// bindSession 非空时进一步要求一致（防跨 session 请求）。
func validateEnvelope(env ExtensionEnvelope, bindSession string) error {
	if env.ProtocolVersion != DshExtensionProtocolVersion {
		return fmt.Errorf("%s: 扩展协议版本 %d 与桥版本 %d 不兼容", ErrCodeExtensionMajorMismatch, env.ProtocolVersion, DshExtensionProtocolVersion)
	}
	if strings.TrimSpace(env.SessionID) == "" {
		return errors.New(ErrCodeExtensionInvalidPayload + ": 缺少 sessionId")
	}
	if bindSession != "" && env.SessionID != bindSession {
		return fmt.Errorf("%s: 请求绑定 %s 与目标会话 %s 不一致", ErrCodeExtensionCrossSession, env.SessionID, bindSession)
	}
	return nil
}

// decodeStrict 用严格 schema 解析扩展 payload：未知字段拒绝，禁止静默丢弃。
// raw 为空或非对象同样拒绝，保证桥/适配器两侧形状一致。
func decodeStrict(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return errors.New(ErrCodeExtensionInvalidPayload + ": 空 payload")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(target); err != nil {
		return fmt.Errorf("%s: %w", ErrCodeExtensionInvalidPayload, err)
	}
	// 拒绝尾随 token（{"a":1}{"b":2} 之类拼接帧）。
	if dec.More() {
		return errors.New(ErrCodeExtensionInvalidPayload + ": payload 含多余数据")
	}
	return nil
}

// ---------------------------------------------------------------------------
// question（B-5/B-6）：DSH AskUserQuestionItem → ACP elicitation / dsh/question。
// ---------------------------------------------------------------------------

// 允许的 question 字段类型（ADR-014 §8：string / single-select / multi-select）。
const (
	QuestionTypeText     = "string"
	QuestionTypeSingle   = "single-select"
	QuestionTypeMulti    = "multi-select"
	QuestionIntentReview = "plan-review" // 计划审核意图：必须携带 markdown detail
)

// DshQuestionItem 是单个问题项的白名单投影。
// DSH 侧无法表达的字段类型直接拒绝，不静默丢失 intent/detail。
type DshQuestionItem struct {
	ID             string   `json:"id"`
	Title          string   `json:"title"`
	Type           string   `json:"type"` // string | single-select | multi-select
	Options        []string `json:"options,omitempty"`
	MultiSelect    bool     `json:"multiSelect,omitempty"`
	AllowCustom    bool     `json:"allowCustomText,omitempty"` // 允许自由输入（Other 语义用独立 custom 表达）
	Intent         string   `json:"intent,omitempty"`
	DetailMarkdown string   `json:"detailMarkdown,omitempty"` // plan-review 被审核的完整 markdown（DSH 已校验）
	MaxSelectable  int      `json:"maxSelectable,omitempty"`  // multi-select 上限；0 表示不限
}

// DshQuestionRequest 是桥发起的一次提问（可多题）。
type DshQuestionRequest struct {
	ExtensionEnvelope
	// BridgeRequestID 是桥侧原始 JSON-RPC id（server → client 请求），应答必须回显。
	BridgeRequestID int64             `json:"-"`
	Items           []DshQuestionItem `json:"items"`
}

// DshQuestionAnswerItem 是单题回答；selected 与 customText 互斥表达，
// multi-select 时 selected 可多项且可并入 custom。
type DshQuestionAnswerItem struct {
	ID         string   `json:"id"`
	Selected   []string `json:"selected,omitempty"`
	CustomText string   `json:"customText,omitempty"`
	Skipped    bool     `json:"skipped,omitempty"`
}

// DshQuestionAnswer 是客户端的一次性回答批次（一个 request 只消费一次）。
type DshQuestionAnswer struct {
	ExtensionEnvelope
	Answers []DshQuestionAnswerItem `json:"answers"`
}

// Validate 检查 question 请求的 schema 边界：
// 至少一题、每题有 id/title、类型合法、选项类型约束、plan-review 必须携带 detail。
func (r *DshQuestionRequest) Validate() error {
	if err := validateEnvelope(r.ExtensionEnvelope, ""); err != nil {
		return err
	}
	if len(r.Items) == 0 {
		return errors.New(ErrCodeExtensionInvalidPayload + ": question 至少包含一题")
	}
	seen := map[string]bool{}
	for _, item := range r.Items {
		if strings.TrimSpace(item.ID) == "" || strings.TrimSpace(item.Title) == "" {
			return errors.New(ErrCodeExtensionInvalidPayload + ": 问题缺少 id 或 title")
		}
		if seen[item.ID] {
			return fmt.Errorf("%s: 问题 id 重复: %s", ErrCodeExtensionInvalidPayload, item.ID)
		}
		seen[item.ID] = true
		switch item.Type {
		case QuestionTypeText:
			if len(item.Options) > 0 {
				return fmt.Errorf("%s: 文本题不得携带选项 (%s)", ErrCodeExtensionInvalidPayload, item.ID)
			}
		case QuestionTypeSingle, QuestionTypeMulti:
			if len(item.Options) == 0 {
				return fmt.Errorf("%s: 选择题必须携带选项 (%s)", ErrCodeExtensionInvalidPayload, item.ID)
			}
		default:
			return fmt.Errorf("%s: 不支持的问题类型 %q (%s)", ErrCodeExtensionInvalidPayload, item.Type, item.ID)
		}
		if item.Intent == QuestionIntentReview && strings.TrimSpace(item.DetailMarkdown) == "" {
			return fmt.Errorf("%s: plan-review 问题缺少被审核 markdown (%s)", ErrCodeExtensionInvalidPayload, item.ID)
		}
	}
	return nil
}

// Validate 校验回答批次：逐题关联、选项属于原问题、一次性 batch 非空。
// plan-review 的 approve label 必须属于原问题选项（ADR-014 §8；服务端复验）。
func (a *DshQuestionAnswer) Validate(request *DshQuestionRequest) error {
	if err := validateEnvelope(a.ExtensionEnvelope, request.SessionID); err != nil {
		return err
	}
	if len(a.Answers) == 0 {
		return errors.New(ErrCodeExtensionInvalidPayload + ": 回答批次为空")
	}
	items := map[string]DshQuestionItem{}
	for _, item := range request.Items {
		items[item.ID] = item
	}
	answered := map[string]bool{}
	for _, ans := range a.Answers {
		item, ok := items[ans.ID]
		if !ok {
			return fmt.Errorf("%s: 回答引用了未知问题 %s", ErrCodeExtensionInvalidPayload, ans.ID)
		}
		if answered[ans.ID] {
			return fmt.Errorf("%s: 问题 %s 被重复回答", ErrCodeExtensionDuplicateReq, ans.ID)
		}
		answered[ans.ID] = true
		if ans.Skipped {
			continue
		}
		for _, sel := range ans.Selected {
			if !containsString(item.Options, sel) {
				return fmt.Errorf("%s: 回答选项 %q 不属于问题 %s 的选项", ErrCodeExtensionInvalidPayload, sel, ans.ID)
			}
		}
		if item.Type == QuestionTypeSingle && len(ans.Selected) > 1 {
			return fmt.Errorf("%s: 单选题 %s 收到多个选项", ErrCodeExtensionInvalidPayload, ans.ID)
		}
		if item.MaxSelectable > 0 && len(ans.Selected) > item.MaxSelectable {
			return fmt.Errorf("%s: 问题 %s 选择数量超过上限", ErrCodeExtensionInvalidPayload, ans.ID)
		}
		if !item.AllowCustom && strings.TrimSpace(ans.CustomText) != "" {
			return fmt.Errorf("%s: 问题 %s 不允许自由输入", ErrCodeExtensionInvalidPayload, ans.ID)
		}
		// 有 customText 或 selected 至少一项；都没有视为跳过校验失败（不静默通过）。
		if len(ans.Selected) == 0 && strings.TrimSpace(ans.CustomText) == "" {
			return fmt.Errorf("%s: 问题 %s 缺少有效回答", ErrCodeExtensionInvalidPayload, ans.ID)
		}
	}
	return nil
}

func containsString(list []string, target string) bool {
	for _, item := range list {
		if item == target {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// plan（B-7）：committed projection 只有 {active,pending}，经 dsh/plan/changed 发送；
// 审核内容走 ACP plan_update(type=markdown)/plan_removed，不从 projection 合成 entries。
// ---------------------------------------------------------------------------

// DshPlanState 是 DSH committed plan projection 的脱敏投影。
// 只有 active/pending 两个布尔事实源字段；entries/markdown 一律不进公共协议。
type DshPlanState struct {
	ExtensionEnvelope
	Active  bool `json:"active"`
	Pending bool `json:"pending"`
}

// Validate 保证 projection 不携带伪造内容：active/pending 至少一个可观察，
// 且不同时为 true（DSH committed 语义互斥）。
func (p *DshPlanState) Validate() error {
	if err := validateEnvelope(p.ExtensionEnvelope, ""); err != nil {
		return err
	}
	if p.Active && p.Pending {
		return errors.New(ErrCodeExtensionInvalidPayload + ": plan projection 的 active/pending 互斥")
	}
	return nil
}

// ---------------------------------------------------------------------------
// goal（B-8）：CAS 变更 + changed 通知；不返回 session event 原文/路径/内部对象。
// ---------------------------------------------------------------------------

// 允许的 goal 显式操作（dsh/goal/mutate operation 白名单）。
const (
	GoalOpCreate   = "create"
	GoalOpEdit     = "edit"
	GoalOpPause    = "pause"
	GoalOpResume   = "resume"
	GoalOpComplete = "complete"
	GoalOpClear    = "clear"
)

// DshGoalProjection 是 goal 的只读投影（dsh/goal/get 与 changed 通知共用）。
type DshGoalProjection struct {
	ExtensionEnvelope
	Text          string `json:"text,omitempty"`   // 目标文本（用户可见）
	Phase         string `json:"phase,omitempty"`  // DSH goal phase 安全投影
	Revision      int64  `json:"revision"`         // 变更版本；CAS 依据
	RoundActive   int    `json:"roundActiveCount"` // round 计数器（脱敏数值）
	RoundTotal    int    `json:"roundTotalCount"`
	Paused        bool   `json:"paused"`
	Cleared       bool   `json:"cleared"`
	BlockedReason string `json:"blockedReason,omitempty"` // DSH 明确给出的受阻原因（脱敏）
}

// DshGoalMutateRequest 是显式 goal 变更请求：operation 白名单 + CAS revision。
type DshGoalMutateRequest struct {
	ExtensionEnvelope
	Operation     string `json:"operation"` // create/edit/pause/resume/complete/clear
	Text          string `json:"text,omitempty"`
	MaxTextLength int    `json:"-"` // 审计上限（由调用方注入，默认 DshGoalMaxTextLength）
}

// DshGoalMaxTextLength 是目标文本的 schema/审计上限（ADR-014 §8：长度受限）。
const DshGoalMaxTextLength = 4096

// Validate 校验 goal 变更：operation 必须在白名单内、文本长度受限；
// create/edit 必须携带文本，clear 不得携带文本（防误覆盖）。
func (m *DshGoalMutateRequest) Validate() error {
	if err := validateEnvelope(m.ExtensionEnvelope, ""); err != nil {
		return err
	}
	switch m.Operation {
	case GoalOpCreate, GoalOpEdit:
		if strings.TrimSpace(m.Text) == "" {
			return fmt.Errorf("%s: goal %s 必须携带文本", ErrCodeExtensionInvalidPayload, m.Operation)
		}
	case GoalOpPause, GoalOpResume, GoalOpComplete:
	case GoalOpClear:
		if strings.TrimSpace(m.Text) != "" {
			return errors.New(ErrCodeExtensionInvalidPayload + ": goal clear 不得携带文本")
		}
	default:
		return fmt.Errorf("%s: 不支持的 goal 操作 %q", ErrCodeExtensionInvalidPayload, m.Operation)
	}
	limit := m.MaxTextLength
	if limit <= 0 {
		limit = DshGoalMaxTextLength
	}
	if len(m.Text) > limit {
		return fmt.Errorf("%s: goal 文本超过长度上限 %d", ErrCodeExtensionInvalidPayload, limit)
	}
	return nil
}

// ---------------------------------------------------------------------------
// skill（B-9/B-10）：descriptor 白名单目录 + 内容摘要 revision + 显式调用。
// ---------------------------------------------------------------------------

// DshSkillDescriptor 是技能目录的安全字段白名单。
// path/resourceBase/locator/provider metadata/skill body 故意没有字段，无法泄露。
type DshSkillDescriptor struct {
	Name          string `json:"name"`
	Description   string `json:"description,omitempty"`
	WhenToUse     string `json:"whenToUse,omitempty"`
	Invocation    string `json:"invocation,omitempty"` // 广播给客户端的调用形式（slash 命令等）
	UserInvocable bool   `json:"userInvocable"`
}

// DshSkillCatalog 是 complete snapshot 的安全目录投影。
// CatalogRevision 只在 Complete=true 时有意义：对排序后 descriptor 计算内容摘要，
// incomplete observation 保留 last-good 或保持 unavailable，不发布半套目录。
type DshSkillCatalog struct {
	ExtensionEnvelope
	Complete        bool                 `json:"complete"`
	CatalogRevision string               `json:"catalogRevision,omitempty"`
	Skills          []DshSkillDescriptor `json:"skills"`
}

// ComputeCatalogRevision 对排序后的安全 descriptor 集合计算内容摘要（sha256 前 16 字节 hex）。
// 排序保证同一集合无论快照顺序如何都得到同一 revision；摘要不包含路径或正文。
func ComputeCatalogRevision(catalog DshSkillCatalog) string {
	names := make([]string, 0, len(catalog.Skills))
	byName := map[string]DshSkillDescriptor{}
	for _, skill := range catalog.Skills {
		names = append(names, skill.Name)
		byName[skill.Name] = skill
	}
	sort.Strings(names)
	h := sha256.New()
	for _, name := range names {
		skill := byName[name]
		// 只写入白名单字段；格式固定以便跨端复算一致。
		fmt.Fprintf(h, "%s\x1f%s\x1f%s\x1f%s\x1f%t\x1e",
			skill.Name, skill.Description, skill.WhenToUse, skill.Invocation, skill.UserInvocable)
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// DshSkillInvokeRequest 是显式 skill 调用：必须引用当前 catalogRevision 与已广播的
// userInvocable skill name；未知/未广播/过期 revision 一律拒绝，不降级为普通 prompt。
type DshSkillInvokeRequest struct {
	ExtensionEnvelope
	RequestID       string `json:"requestId"` // 复用 prompt/cancel 生命周期的业务幂等键
	Name            string `json:"name"`
	CatalogRevision string `json:"catalogRevision"`
}

// ValidateAgainstCatalog 对照当前 complete 目录校验调用请求。
// catalog 为空、snapshot 不完整、目录过期、name 未知或非 userInvocable 都 fail-closed。
func (r *DshSkillInvokeRequest) ValidateAgainstCatalog(catalog *DshSkillCatalog) error {
	if err := validateEnvelope(r.ExtensionEnvelope, ""); err != nil {
		return err
	}
	if strings.TrimSpace(r.Name) == "" {
		return errors.New(ErrCodeExtensionInvalidPayload + ": skill 调用缺少 name")
	}
	if catalog == nil || !catalog.Complete {
		return fmt.Errorf("%s: skill 目录不可用（未完成快照）", ErrCodeExtensionUnsupported)
	}
	if r.CatalogRevision != catalog.CatalogRevision {
		return errors.New(ErrCodeExtensionStaleRevision + ": skill 目录已变化，请刷新后重试")
	}
	for _, skill := range catalog.Skills {
		if skill.Name == r.Name {
			if !skill.UserInvocable {
				return fmt.Errorf("%s: skill %s 不可被用户显式调用", ErrCodeExtensionInvalidPayload, r.Name)
			}
			return nil
		}
	}
	return fmt.Errorf("%s: skill %s 不在已广播目录中", ErrCodeExtensionInvalidPayload, r.Name)
}

// ---------------------------------------------------------------------------
// delegation（B-12）：subagent start/end 的 observe-only 投影。
// 不创建伪 ACP session，不开放 child 写控制，delegate_session 保持 unsupported。
// ---------------------------------------------------------------------------

// delegation 状态白名单（start→running；end→completed/failed/cancelled）。
const (
	DelegationStateRunning   = "running"
	DelegationStateCompleted = "completed"
	DelegationStateFailed    = "failed"
	DelegationStateCancelled = "cancelled"
	DelegationStateProposed  = "proposed" // 禁止：start 只在 child 已发布后出现，不得合成
)

// DshDelegationEvent 是一次 subagent 生命周期投影。
// 字段白名单：runId、父子会话、状态、provider、local、stopReason 与受限摘要；
// task envelope、child 正文、凭据、本地路径没有字段位置。
type DshDelegationEvent struct {
	ExtensionEnvelope
	RunID           string `json:"runId"`
	ParentSessionID string `json:"parentSessionId"`
	State           string `json:"state"` // running | completed | failed | cancelled
	Provider        string `json:"provider,omitempty"`
	Local           bool   `json:"local"`
	StopReason      string `json:"stopReason,omitempty"`
	Summary         string `json:"summary,omitempty"` // 受限结果摘要（长度受限）
}

// DshDelegationSummaryMaxBytes 限制摘要长度，防止 child 正文经摘要泄露或拖垮桥。
const DshDelegationSummaryMaxBytes = 512

// Validate 校验 delegation 投影：状态白名单、禁止 proposed、终态必须可归因、摘要受限。
func (d *DshDelegationEvent) Validate() error {
	if err := validateEnvelope(d.ExtensionEnvelope, ""); err != nil {
		return err
	}
	if strings.TrimSpace(d.RunID) == "" || strings.TrimSpace(d.ParentSessionID) == "" {
		return errors.New(ErrCodeExtensionInvalidPayload + ": delegation 事件缺少 runId 或 parentSessionId")
	}
	if d.State == DelegationStateProposed {
		return errors.New(ErrCodeExtensionInvalidPayload + ": delegation 禁止合成 proposed 状态")
	}
	switch d.State {
	case DelegationStateRunning:
	case DelegationStateCompleted, DelegationStateFailed, DelegationStateCancelled:
		// 终态必须能归因：stopReason 或摘要至少一项（cancelled 可仅 stopReason）。
		if strings.TrimSpace(d.StopReason) == "" && strings.TrimSpace(d.Summary) == "" {
			return fmt.Errorf("%s: delegation 终态 %s 缺少归因信息", ErrCodeExtensionInvalidPayload, d.State)
		}
	default:
		return fmt.Errorf("%s: 不支持的 delegation 状态 %q", ErrCodeExtensionInvalidPayload, d.State)
	}
	if len(d.Summary) > DshDelegationSummaryMaxBytes {
		return fmt.Errorf("%s: delegation 摘要超过 %d 字节上限", ErrCodeExtensionInvalidPayload, DshDelegationSummaryMaxBytes)
	}
	return nil
}
