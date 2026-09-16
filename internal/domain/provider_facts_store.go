package domain

// v0.9.2 P1：从 Relay 存储读取执行侧 Terminal 上报的 Provider 事实。
//
// 为什么必须按 Terminal 粒度读取（而不是账号级笼统合并）：
//   - Provider 事实描述的是"**这台执行侧**现在能不能真实跑起该 Provider"；
//   - 手机发出的命令最终只能投递给在线且归属该工作区的 Terminal；
//   - 因此只有**在线** Terminal 的事实才可能兑现为一次真实会话。
//     已离线 Terminal 的历史事实即使标记可用，也无法承载任何会话，
//     采信它只会制造"看到可发送、发出去失败"的假象。

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// OnlineTerminalFacts 返回账号下所有**在线** Terminal 上送的 Provider 事实。
//
// 安全性：
//   - 只读取 terminals 表已落库的上报内容，不触发任何网络或进程探测；
//   - 单条 Terminal 的 JSON 损坏或字段越界时丢弃该 Terminal（不丢弃其它 Terminal，
//     也不把损坏内容当作"不可用事实"污染矩阵）；
//   - nowUnixMS 由调用方提供（HTTP 路径传服务端当前时间），保证可用性判定可注入测试。
func OnlineTerminalFacts(ctx context.Context, repo store.Repository, presence PresencePolicy, accountID string, nowUnixMS int64) ([]TerminalFact, error) {
	if repo == nil || strings.TrimSpace(accountID) == "" {
		return nil, nil
	}
	terminals, err := repo.ListTerminals(ctx, accountID)
	if err != nil {
		return nil, err
	}
	out := make([]TerminalFact, 0, len(terminals))
	for _, terminal := range terminals {
		// 只有权威投影为 online 的 Terminal 才可能兑现会话命令。
		if presence.Project(terminal, nowUnixMS) != PresenceOnline {
			continue
		}
		facts, ok := parseReportedProviderFacts(terminal.ProviderFactsJSON)
		if !ok || len(facts) == 0 {
			continue
		}
		out = append(out, TerminalFact{
			TerminalID:    terminal.ID,
			Hostname:      terminal.Hostname,
			ObservedAtMS:  latestObservedAt(facts),
			ProviderFacts: facts,
		})
	}
	return out, nil
}

// parseReportedProviderFacts 解析存储中的事实快照。
// 返回 ok=false 表示"没有可用事实"（空串、格式错误或字段越界）——调用方按
// "该 Terminal 未提供事实"处理，绝不猜测。
func parseReportedProviderFacts(raw string) ([]ProviderFact, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, false
	}
	var facts []ProviderFact
	if err := json.Unmarshal([]byte(trimmed), &facts); err != nil {
		return nil, false
	}
	if len(facts) == 0 {
		return nil, false
	}
	// 逐条做与入口相同的边界校验：存储内容可能来自更早版本或被篡改的写入路径，
	// 消费端必须独立复核（不信任"入库时已校验"这一假设）。
	valid := make([]ProviderFact, 0, len(facts))
	for _, fact := range facts {
		if err := validateProviderFact(fact); err != nil {
			continue
		}
		valid = append(valid, fact)
	}
	if len(valid) == 0 {
		return nil, false
	}
	return valid, true
}

// validateProviderFact 复核单条事实的结构约束（与 wire 层上限一致）。
func validateProviderFact(fact ProviderFact) error {
	kind := strings.TrimSpace(fact.Kind)
	if kind == "" || len(kind) > 32 {
		return errInvalidProviderFact
	}
	if len(fact.Reason) > 256 || len(fact.Version) > 64 {
		return errInvalidProviderFact
	}
	if len(fact.ModelGroups) > 8 {
		return errInvalidProviderFact
	}
	for _, group := range fact.ModelGroups {
		if len(group.ID) > 96 || len(group.Models) > 64 {
			return errInvalidProviderFact
		}
		for _, model := range group.Models {
			if strings.TrimSpace(model.Value) == "" || len(model.Value) > 192 {
				return errInvalidProviderFact
			}
		}
	}
	if fact.DefaultModel != "" && !providerFactHasModelValue(fact.ModelGroups, fact.DefaultModel) {
		return errInvalidProviderFact
	}
	return nil
}

// providerFactHasModelValue 是目录包含关系判定（默认模型必须可被客户端提交）。
func providerFactHasModelValue(groups []ProviderFactGroup, value string) bool {
	for _, group := range groups {
		for _, model := range group.Models {
			if model.Value == value {
				return true
			}
		}
	}
	return false
}

// latestObservedAt 取事实快照中最新的观测时间（用于跨 Terminal 的择优比较）。
func latestObservedAt(facts []ProviderFact) int64 {
	var latest int64
	for _, fact := range facts {
		if fact.ObservedAtUnixMS > latest {
			latest = fact.ObservedAtUnixMS
		}
	}
	return latest
}

// errInvalidProviderFact 是内部校验哨兵（不进入公共协议）。
var errInvalidProviderFact = errProviderFactInvalid{}

type errProviderFactInvalid struct{}

func (errProviderFactInvalid) Error() string { return "invalid provider fact" }

// NowUnixMS 返回服务端毫秒时间（可用性判定的唯一时间来源）。
func NowUnixMS() int64 { return time.Now().UnixMilli() }
