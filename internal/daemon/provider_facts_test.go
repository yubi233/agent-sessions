package daemon

// V092-03 回归：执行侧 Provider 事实采集器（v0.9.2 P1）。
//
// 契约要点：
//   - 未完成首轮观测时快照为空（nil），Relay 因此不会把"未知"当成"不可用"；
//   - 刷新在**后台**完成，心跳路径永不阻塞在真实探测上；
//   - TTL 内的重复调用不重复探测（避免把握手成本摊到每次心跳）；
//   - 探测失败同样是事实：available=false + 中文原因，随下一次心跳上报。

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapterreg"
)

// countingAdapter 记录 Detect 调用次数并可按需返回成功/失败（fixture 执行侧）。
type countingAdapter struct {
	kind     string
	calls    int
	version  string
	failWith string
	groups   []adapter.ModelCapabilityGroup
}

func (a *countingAdapter) Detect(context.Context) (adapter.Capabilities, error) {
	a.calls++
	if a.failWith != "" {
		return adapter.Capabilities{
			Provider: a.kind,
			Capabilities: []adapter.Capability{
				{Name: "start", Status: adapter.CapabilityUnsupported, Reason: a.failWith},
			},
		}, nil
	}
	return adapter.Capabilities{
		Provider: a.kind,
		Version:  a.version,
		Capabilities: []adapter.Capability{
			{Name: "start", Status: adapter.CapabilityNative},
			{Name: "model_select", Status: adapter.CapabilityNative, Default: "m1", ModelGroups: a.groups},
		},
	}, nil
}

func (a *countingAdapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start/Resume 不参与本文件的契约（只验证事实采集），实现为显式不支持。
func (a *countingAdapter) Start(context.Context, adapter.StartRequest) (adapter.Handle, error) {
	return nil, errFactTestUnsupported
}

func (a *countingAdapter) Resume(context.Context, adapter.ResumeRequest) (adapter.ResumeResult, error) {
	return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
}

var errFactTestUnsupported = errors.New("fixture adapter 不支持真实会话")

func newFactCollector(a adapter.Adapter) (*ProviderFactCollector, string) {
	kind := "dsh"
	if typed, ok := a.(*countingAdapter); ok {
		kind = typed.kind
	}
	return NewProviderFactCollector(adapterreg.NewWithAdapters(map[string]adapter.Adapter{kind: a})), kind
}

// 未观测时快照为空：不上报字段（"未知"不得被当成"不可用"）。
func TestV092ProviderFactSnapshotEmptyBeforeFirstRefresh(t *testing.T) {
	collector, _ := newFactCollector(&countingAdapter{kind: "dsh", version: "0.0.1"})
	if snapshot := collector.Snapshot(context.Background()); snapshot != nil {
		t.Fatalf("首轮观测前必须返回 nil（不上报），got %#v", snapshot)
	}
}

// 刷新后快照包含 kind/available/version 与模型目录；排序稳定。
func TestV092ProviderFactRefreshProducesFacts(t *testing.T) {
	impl := &countingAdapter{kind: "dsh", version: "0.0.1", groups: []adapter.ModelCapabilityGroup{{
		ID: "openai", Name: "OpenAI",
		Models: []adapter.ModelCapabilityModel{{Provider: "openai", Value: "m1", ID: "m1", Name: "Model 1"}},
	}}}
	collector, _ := newFactCollector(impl)
	if err := collector.Refresh(context.Background()); err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	snapshot := collector.Snapshot(context.Background())
	if len(snapshot) != 1 {
		t.Fatalf("快照应包含 1 条事实: %#v", snapshot)
	}
	fact := snapshot[0]
	if fact.Kind != "dsh" || !fact.Available || fact.Version != "0.0.1" {
		t.Fatalf("事实内容不正确: %#v", fact)
	}
	if fact.DefaultModel != "m1" || len(fact.ModelGroups) != 1 {
		t.Fatalf("模型目录必须随事实上报: %#v", fact)
	}
	if fact.ObservedAtUnixMS <= 0 {
		t.Fatalf("必须携带观测时间（供 Relay/客户端判断新鲜度）: %#v", fact)
	}
}

// TTL 内的重复 Snapshot 不重复探测（避免把真实握手成本摊到每次心跳）。
func TestV092ProviderFactSnapshotUsesCachedFactsWithinTTL(t *testing.T) {
	impl := &countingAdapter{kind: "dsh", version: "0.0.1"}
	collector, _ := newFactCollector(impl)
	if err := collector.Refresh(context.Background()); err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	before := impl.calls
	for i := 0; i < 5; i++ {
		collector.Snapshot(context.Background())
	}
	if impl.calls != before {
		t.Fatalf("TTL 内不得重复探测（calls %d → %d）", before, impl.calls)
	}
}

// 失败事实同样上报：available=false + 中文原因，且不抛错到调用方。
func TestV092ProviderFactReportsFailureAsFact(t *testing.T) {
	const reason = `未找到 node 运行时: exec: "node": executable file not found in $PATH`
	collector, _ := newFactCollector(&countingAdapter{kind: "dsh", failWith: reason})
	if err := collector.Refresh(context.Background()); err != nil {
		t.Fatalf("失败事实不应作为错误抛出: %v", err)
	}
	snapshot := collector.Snapshot(context.Background())
	if len(snapshot) != 1 {
		t.Fatalf("失败也必须产生一条事实: %#v", snapshot)
	}
	fact := snapshot[0]
	if fact.Available || fact.Version != "" {
		t.Fatalf("失败事实必须是 fail-closed: %#v", fact)
	}
	if !strings.Contains(fact.Reason, "node") {
		t.Fatalf("失败原因必须可诊断: %#v", fact)
	}
}

// 未配置采集器（nil）时快照为 nil：Relay 保持既有口径。
func TestV092ProviderFactNilCollectorIsNoop(t *testing.T) {
	var collector *ProviderFactCollector
	if snapshot := collector.Snapshot(context.Background()); snapshot != nil {
		t.Fatalf("nil 采集器必须返回 nil: %#v", snapshot)
	}
	if err := collector.Refresh(context.Background()); err != nil {
		t.Fatalf("nil 采集器 Refresh 必须安全: %v", err)
	}
}

// runOnce 主循环使用采集器快照作为上报内容（端到端接线回归）。
func TestV092ProviderFactSnapshotOrderedByKind(t *testing.T) {
	collector := NewProviderFactCollector(adapterreg.NewWithAdapters(map[string]adapter.Adapter{
		"dsh":    &countingAdapter{kind: "dsh", version: "0.0.1"},
		"claude": &countingAdapter{kind: "claude", version: "1.0.0"},
	}))
	if err := collector.Refresh(context.Background()); err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	snapshot := collector.Snapshot(context.Background())
	if len(snapshot) != 2 || snapshot[0].Kind != "claude" || snapshot[1].Kind != "dsh" {
		t.Fatalf("快照必须按 kind 稳定排序（签名 body 不抖动）: %#v", snapshot)
	}
	// 观测时间必须单调不倒退（同一轮刷新内一致）。
	if snapshot[0].ObservedAtUnixMS != snapshot[1].ObservedAtUnixMS {
		t.Fatalf("同一轮刷新的观测时间必须一致: %#v", snapshot)
	}
	_ = time.Now
}
