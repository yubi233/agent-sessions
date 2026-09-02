package dsh

import (
	"encoding/json"
	"strings"
	"testing"
)

// 本文件是 V083 P0 的扩展 wire 契约回归（ADR-014 §7/§8）：
// 校验协商矩阵、严格 schema、CAS/会话绑定、脱敏白名单与状态白名单。
// 这些测试只覆盖 P0 已冻结的纯契约层，不依赖 P1/P2 的桥 handler 实现。

// contractSession 是契约测试共用的会话绑定值。
const contractSession = "sess-contract"

func mustMarshal(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("编码契约载荷: %v", err)
	}
	return raw
}

// (V083-09) 协商矩阵：未声明/-major 不匹配/minor 超前 均 fail-closed；兼容组合放行。
func TestExtensionNegotiationMatrix(t *testing.T) {
	declared, err := ParseExtensionNegotiation(mustMarshal(t, map[string]string{
		"dsh/goal/mutate":  "1.0",
		"dsh/plan/changed": "2.0", // major 不匹配
		"dsh/skill/invoke": "1.9", // minor 超前
	}))
	if err != nil {
		t.Fatalf("解析协商声明: %v", err)
	}
	if ExtensionAccepted(declared, "dsh/goal/mutate", 1, 0) != true {
		t.Fatalf("兼容声明（1.0 ≤ 桥 1.0）应被接受")
	}
	if ExtensionAccepted(declared, "dsh/plan/changed", 1, 0) {
		t.Fatalf("major 不匹配必须拒绝")
	}
	if ExtensionAccepted(declared, "dsh/skill/invoke", 1, 0) {
		t.Fatalf("minor 超前（客户端比桥新）必须拒绝")
	}
	if ExtensionAccepted(declared, "dsh/goal/get", 1, 0) {
		t.Fatalf("未声明的扩展必须拒绝")
	}
}

// (V083-09) 协商声明形状非法：非 dsh/ 命名空间、版本串不合法都拒绝。
func TestExtensionNegotiationRejectsBadShapes(t *testing.T) {
	cases := []struct {
		name  string
		input map[string]string
	}{
		{"非 dsh 命名空间", map[string]string{"other/verb": "1.0"}},
		{"缺 minor", map[string]string{"dsh/goal/mutate": "1"}},
		{"非数字", map[string]string{"dsh/goal/mutate": "a.b"}},
		{"空版本", map[string]string{"dsh/goal/mutate": ""}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := ParseExtensionNegotiation(mustMarshal(t, tc.input)); err == nil {
				t.Fatalf("非法声明应被拒绝: %v", tc.input)
			}
		})
	}
	// 数组形状（非对象）同样拒绝。
	if _, err := ParseExtensionNegotiation(mustMarshal(t, []string{"dsh/goal/mutate"})); err == nil {
		t.Fatalf("数组形状的协商声明应被拒绝")
	}
}

// (V083-09/V083-10) 严格 schema：未知字段拒绝；跨 session 请求拒绝。
func TestQuestionAnswerStrictSchema(t *testing.T) {
	req := &DshQuestionRequest{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
		Items: []DshQuestionItem{{
			ID: "q1", Title: "选择方案", Type: QuestionTypeSingle,
			Options: []string{"方案 A", "方案 B"}, AllowCustom: true,
		}},
	}
	if err := req.Validate(); err != nil {
		t.Fatalf("合法 question 请求不应拒绝: %v", err)
	}
	// 未知字段（插件私有 JSON 混入）必须被严格拒绝。
	raw := mustMarshal(t, map[string]any{
		"protocolVersion": 1, "sessionId": contractSession,
		"answers": []map[string]any{{"id": "q1", "selected": []string{"方案 A"}, "harnessInternalPath": "/tmp/x"}},
	})
	var ans DshQuestionAnswer
	if err := decodeStrict(raw, &ans); err == nil {
		t.Fatalf("未知字段必须被严格 schema 拒绝")
	}
	// 合法回答可解码并通过校验。
	valid := mustMarshal(t, DshQuestionAnswer{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
		Answers:           []DshQuestionAnswerItem{{ID: "q1", Selected: []string{"方案 A"}}},
	})
	var ans2 DshQuestionAnswer
	if err := decodeStrict(valid, &ans2); err != nil {
		t.Fatalf("合法回答解码失败: %v", err)
	}
	if err := ans2.Validate(req); err != nil {
		t.Fatalf("合法回答校验失败: %v", err)
	}
	// 跨 session 回答拒绝。
	ans2.SessionID = "sess-other"
	if err := ans2.Validate(req); err == nil || !strings.Contains(err.Error(), ErrCodeExtensionCrossSession) {
		t.Fatalf("跨 session 回答应报 cross_session，得到: %v", err)
	}
}

// (V083-10/V083-12) question 校验：选项越界、单选多值、plan-review 缺 detail。
func TestQuestionValidationEdges(t *testing.T) {
	base := func(items ...DshQuestionItem) *DshQuestionRequest {
		return &DshQuestionRequest{
			ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
			Items:             items,
		}
	}
	// plan-review 缺 markdown detail 拒绝（不静默丢 detail）。
	review := base(DshQuestionItem{ID: "p1", Title: "审核计划", Type: QuestionTypeSingle, Intent: QuestionIntentReview, Options: []string{"批准", "继续计划"}})
	if err := review.Validate(); err == nil || !strings.Contains(err.Error(), "markdown") {
		t.Fatalf("plan-review 缺 detail 应拒绝，得到: %v", err)
	}
	review.Items[0].DetailMarkdown = "# 计划\n1. 步骤"
	if err := review.Validate(); err != nil {
		t.Fatalf("携带 detail 的 plan-review 应通过: %v", err)
	}
	// 文本题带选项拒绝。
	if err := base(DshQuestionItem{ID: "t1", Title: "输入", Type: QuestionTypeText, Options: []string{"x"}}).Validate(); err == nil {
		t.Fatalf("文本题携带选项应拒绝")
	}
	// 回答引用未知选项拒绝。
	req := base(DshQuestionItem{ID: "s1", Title: "选择", Type: QuestionTypeSingle, Options: []string{"A", "B"}})
	if err := req.Validate(); err != nil {
		t.Fatalf("前置请求应合法: %v", err)
	}
	ans := &DshQuestionAnswer{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
		Answers:           []DshQuestionAnswerItem{{ID: "s1", Selected: []string{"C"}}},
	}
	if err := ans.Validate(req); err == nil {
		t.Fatalf("越界选项应拒绝")
	}
	// 重复回答同一问题拒绝（一个 request 只消费一次答案形状）。
	dup := &DshQuestionAnswer{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
		Answers: []DshQuestionAnswerItem{
			{ID: "s1", Selected: []string{"A"}},
			{ID: "s1", Selected: []string{"B"}},
		},
	}
	if err := dup.Validate(req); err == nil || !strings.Contains(err.Error(), ErrCodeExtensionDuplicateReq) {
		t.Fatalf("重复回答应报 duplicate，得到: %v", err)
	}
}

// (V083-13) plan projection：{active,pending} 互斥；通知形状不含伪造 entries。
func TestPlanStateValidation(t *testing.T) {
	state := &DshPlanState{ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession}, Active: true}
	if err := state.Validate(); err != nil {
		t.Fatalf("合法 projection 应通过: %v", err)
	}
	state.Active, state.Pending = true, true
	if err := state.Validate(); err == nil {
		t.Fatalf("active/pending 同时为真应拒绝")
	}
	// 版本不匹配拒绝（major 门）。
	state.Active, state.Pending = true, false
	state.ProtocolVersion = 2
	if err := state.Validate(); err == nil || !strings.Contains(err.Error(), ErrCodeExtensionMajorMismatch) {
		t.Fatalf("major 不匹配应拒绝，得到: %v", err)
	}
}

// (V083-15) goal mutate：operation 白名单、CAS 文本约束、长度上限。
func TestGoalMutateValidation(t *testing.T) {
	ok := &DshGoalMutateRequest{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession, ExpectedRevision: 3},
		Operation:         GoalOpEdit, Text: "完成回归测试",
	}
	if err := ok.Validate(); err != nil {
		t.Fatalf("合法 goal 编辑应通过: %v", err)
	}
	// 未知操作拒绝。
	ok.Operation = "restart"
	if err := ok.Validate(); err == nil {
		t.Fatalf("未知 goal 操作应拒绝")
	}
	// create 缺文本拒绝。
	ok.Operation, ok.Text = GoalOpCreate, ""
	if err := ok.Validate(); err == nil {
		t.Fatalf("create 缺文本应拒绝")
	}
	// clear 携带文本拒绝。
	ok.Operation, ok.Text = GoalOpClear, "残留"
	if err := ok.Validate(); err == nil {
		t.Fatalf("clear 携带文本应拒绝")
	}
	// 超长文本拒绝。
	ok.Operation, ok.Text = GoalOpEdit, strings.Repeat("长", DshGoalMaxTextLength+1)
	if err := ok.Validate(); err == nil {
		t.Fatalf("超长 goal 文本应拒绝")
	}
}

// (V083-17) skill 目录摘要：顺序无关、白名单字段参与、userInvocable 变化改变 revision。
func TestSkillCatalogRevision(t *testing.T) {
	skills := []DshSkillDescriptor{
		{Name: "review", Description: "代码审查", WhenToUse: "提交前", Invocation: "/review", UserInvocable: true},
		{Name: "deploy", Description: "发布", WhenToUse: "上线时", Invocation: "/deploy", UserInvocable: false},
	}
	a := ComputeCatalogRevision(DshSkillCatalog{Skills: skills})
	// 逆序快照得到同一 revision（排序后摘要）。
	reversed := []DshSkillDescriptor{skills[1], skills[0]}
	b := ComputeCatalogRevision(DshSkillCatalog{Skills: reversed})
	if a != b || a == "" {
		t.Fatalf("同一集合不同顺序应得到相同非空 revision: %q vs %q", a, b)
	}
	// 描述变化 → revision 变化（内容摘要语义）。
	skills[0].Description = "代码审查（加强）"
	c := ComputeCatalogRevision(DshSkillCatalog{Skills: skills})
	if c == a {
		t.Fatalf("descriptor 内容变化应改变 catalogRevision")
	}
}

// (V083-18) skill invoke admission：未广播 name、过期 revision、非 userInvocable 全部拒绝。
func TestSkillInvokeAdmission(t *testing.T) {
	catalog := &DshSkillCatalog{
		Complete:        true,
		CatalogRevision: ComputeCatalogRevision(DshSkillCatalog{Skills: []DshSkillDescriptor{{Name: "review", UserInvocable: true}, {Name: "internal", UserInvocable: false}}}),
		Skills: []DshSkillDescriptor{
			{Name: "review", UserInvocable: true},
			{Name: "internal", UserInvocable: false},
		},
	}
	catalog.CatalogRevision = ComputeCatalogRevision(*catalog)
	req := &DshSkillInvokeRequest{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
		RequestID:         "req-1", Name: "review", CatalogRevision: catalog.CatalogRevision,
	}
	if err := req.ValidateAgainstCatalog(catalog); err != nil {
		t.Fatalf("合法 skill 调用应通过: %v", err)
	}
	// 未广播 name 拒绝（不得降级为普通 prompt）。
	req.Name = "not-in-catalog"
	if err := req.ValidateAgainstCatalog(catalog); err == nil {
		t.Fatalf("未广播的 skill 应拒绝")
	}
	// 非 userInvocable 拒绝。
	req.Name = "internal"
	if err := req.ValidateAgainstCatalog(catalog); err == nil {
		t.Fatalf("非 userInvocable skill 应拒绝")
	}
	// 过期 revision 拒绝。
	req.Name = "review"
	req.CatalogRevision = "0000000000000000"
	if err := req.ValidateAgainstCatalog(catalog); err == nil || !strings.Contains(err.Error(), ErrCodeExtensionStaleRevision) {
		t.Fatalf("过期目录 revision 应报 stale，得到: %v", err)
	}
	// incomplete snapshot 拒绝（不发布半套目录）。
	stale := *catalog
	stale.Complete = false
	req.CatalogRevision = catalog.CatalogRevision
	if err := req.ValidateAgainstCatalog(&stale); err == nil {
		t.Fatalf("不完整快照应拒绝调用")
	}
}

// (V083-20) delegation 投影：状态白名单、禁止 proposed、终态归因、摘要上限。
func TestDelegationEventValidation(t *testing.T) {
	base := func(state, stopReason, summary string) *DshDelegationEvent {
		return &DshDelegationEvent{
			ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
			RunID:             "run-1", ParentSessionID: contractSession,
			State: state, Provider: "dsh", Local: true,
			StopReason: stopReason, Summary: summary,
		}
	}
	if err := base(DelegationStateRunning, "", "").Validate(); err != nil {
		t.Fatalf("running 投影应通过: %v", err)
	}
	if err := base(DelegationStateCompleted, "end_turn", "已完成 2 个步骤").Validate(); err != nil {
		t.Fatalf("带归因的 completed 应通过: %v", err)
	}
	if err := base(DelegationStateProposed, "", "").Validate(); err == nil {
		t.Fatalf("proposed 状态必须拒绝（不合成未发布 child）")
	}
	if err := base(DelegationStateFailed, "", "").Validate(); err == nil {
		t.Fatalf("终态缺少归因应拒绝")
	}
	long := &DshDelegationEvent{
		ExtensionEnvelope: ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession},
		RunID:             "run-1", ParentSessionID: contractSession, State: DelegationStateCompleted,
		StopReason: "end_turn", Summary: strings.Repeat("x", DshDelegationSummaryMaxBytes+1),
	}
	if err := long.Validate(); err == nil {
		t.Fatalf("超限摘要应拒绝")
	}
	// 未知状态拒绝。
	if err := base("queued", "", "").Validate(); err == nil {
		t.Fatalf("未知 delegation 状态应拒绝")
	}
}

// (V083-09) envelope 公共校验：版本门与 sessionId 必填。
func TestEnvelopeValidation(t *testing.T) {
	env := ExtensionEnvelope{ProtocolVersion: DshExtensionProtocolVersion, SessionID: contractSession}
	if err := validateEnvelope(env, ""); err != nil {
		t.Fatalf("合法 envelope 应通过: %v", err)
	}
	env.SessionID = ""
	if err := validateEnvelope(env, ""); err == nil {
		t.Fatalf("缺少 sessionId 应拒绝")
	}
	env.SessionID = contractSession
	env.ProtocolVersion = 99
	if err := validateEnvelope(env, ""); err == nil || !strings.Contains(err.Error(), ErrCodeExtensionMajorMismatch) {
		t.Fatalf("未知 major 应拒绝，得到: %v", err)
	}
}
