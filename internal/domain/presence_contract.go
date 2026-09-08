package domain

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// v0.9.1 C1（迭代计划 §3.2）：Terminal Presence 契约。
//
// 总原则（计划 §0 冻结）：
//   - Relay 以「服务端时间 + 最后一次有效 heartbeat + 集中阈值」计算 availability，
//     客户端墙钟只用于展示，不参与授权或写命令裁决；
//   - read path 与 command path 即时派生过期状态，后台 reaper 只负责通知或持久投影，
//     不是安全正确性的前置条件；
//   - online / offline / unknown / unsupported 四态必须分开；unknown 表示事实不可确认
//     （观察窗内或尚无心跳），不等于执行端离线，不把网络或事实缺口说成执行端故障。
//
// 阈值冻结（裁决 T3）：heartbeat 15s / suspect 观察 40s / offline deadline 60s。
// 投影边界：
//   - delta(now-last_heartbeat) <= 40s            -> online
//   - 40s < delta <= 60s                          -> unknown（suspect 观察窗）
//   - delta > 60s                                 -> offline（权威离线）
//   - 从未上报 heartbeat（last_heartbeat=0）      -> unknown（事实不可确认）

// PresenceAvailability 是 Relay 权威投影的 Terminal 在线态，wire 值直接进入
// /v1/terminals 的 availability 字段。客户端只能消费该值，不得二次裁决。
type PresenceAvailability string

const (
	PresenceOnline      PresenceAvailability = "online"
	PresenceUnknown     PresenceAvailability = "unknown"
	PresenceOffline     PresenceAvailability = "offline"
	PresenceUnsupported PresenceAvailability = "unsupported"
)

// presenceAvailableForWrite 判断投影结果是否允许向该 Terminal 投递写命令。
// unsupported 与 offline 同为 fail-closed（协议不安全等价于不可投递）。
func presenceAvailableForWrite(availability PresenceAvailability) bool {
	return availability == PresenceOnline
}

// PresencePolicy 集中保存 presence 阈值。服务构造时取 DefaultPresencePolicy()；
// 集成测试可整体替换（导出字段），但同一测试内的多个服务必须配置同一份，
// 避免列表投影与命令门控的阈值漂移。
type PresencePolicy struct {
	// HeartbeatInterval 是 Daemon hello/heartbeat 的标称节拍（只作诊断参考，
	// 投影不依赖它，避免把「节拍」误当「授权」）。
	HeartbeatInterval time.Duration
	// SuspectWindow：超过该窗口未收到 heartbeat 即进入 unknown 观察窗。
	SuspectWindow time.Duration
	// OfflineDeadline：超过该窗口未收到 heartbeat 即权威投影 offline。
	OfflineDeadline time.Duration
}

// DefaultPresencePolicy 返回 v0.9.1 冻结的默认阈值（裁决 T3）。
func DefaultPresencePolicy() PresencePolicy {
	return PresencePolicy{
		HeartbeatInterval: daemonHeartbeatInterval,
		SuspectWindow:     40 * time.Second,
		OfflineDeadline:   60 * time.Second,
	}
}

// Project 用服务端时间口径计算 Terminal availability。nowUnixMS 必须来自 Relay
// 服务端时钟；该函数不读取任何进程级时间，保证测试可注入、结果可复现。
//
// 判定顺序（fail-closed）：
//  1. 协议版本超出安全窗口 -> unsupported（事实再新鲜也不能安全消费）；
//  2. 显式持久化 status=offline -> offline（reaper 持久投影/历史离线；
//     恢复路径的 heartbeat 会在同一事务内把 status 写回 online，因此
//     「新鲜心跳 + offline」不是合法稳态，无需活性复核）；
//  3. 从未上报 heartbeat -> unknown（事实不可确认）；
//  4. 活性窗口：<=40s online / <=60s unknown / >60s offline。
func (p PresencePolicy) Project(terminal store.TerminalRow, nowUnixMS int64) PresenceAvailability {
	// 协议版本超出当前安全窗口：事实再新鲜也不能安全消费，优先级最高。
	if terminal.ProtocolVersion <= 0 || terminal.ProtocolVersion > currentDaemonProtocolVersion {
		return PresenceUnsupported
	}
	// 显式持久化的 offline（reaper 持久投影）优先于活性窗口，fail-closed。
	if strings.EqualFold(terminal.Status, "offline") {
		return PresenceOffline
	}
	if terminal.LastHeartbeatUnixMS <= 0 {
		return PresenceUnknown
	}
	delta := nowUnixMS - terminal.LastHeartbeatUnixMS
	if delta < 0 {
		// 心跳时间在未来只可能是服务端时钟微抖；以最新上报事实为准按 online 处理。
		delta = 0
	}
	switch {
	case delta <= p.SuspectWindow.Milliseconds():
		return PresenceOnline
	case delta <= p.OfflineDeadline.Milliseconds():
		return PresenceUnknown
	default:
		return PresenceOffline
	}
}

// NextCheckUnixMS 返回当前投影的下一个边界时间（0 表示没有更多边界）。
// online -> 进入 unknown 的时刻；unknown -> 进入 offline 的时刻；
// offline/unsupported 不会再变化（直到下一次有效 heartbeat），返回 0。
func (p PresencePolicy) NextCheckUnixMS(terminal store.TerminalRow, nowUnixMS int64) int64 {
	switch p.Project(terminal, nowUnixMS) {
	case PresenceOnline:
		return terminal.LastHeartbeatUnixMS + p.SuspectWindow.Milliseconds()
	case PresenceUnknown:
		return terminal.LastHeartbeatUnixMS + p.OfflineDeadline.Milliseconds()
	default:
		return 0
	}
}

// ErrTerminalUnreachable 表示目标 Terminal 的事实不可确认（unknown），
// 与 ErrTerminalOffline（权威离线/协议不安全）分开：客户端据此区分
// 「执行端离线」与「暂时无法确认」，不把网络或事实缺口说成执行端故障（裁决 T5）。
var ErrTerminalUnreachable = errTerminalUnreachable{}

type errTerminalUnreachable struct{}

func (errTerminalUnreachable) Error() string { return "terminal unreachable" }

// TerminalWriteGate 是所有 Terminal 写命令共用的 freshness + capability predicate
// （v0.9.1 C2）。返回 nil 表示目标可投递；否则返回：
//   - ErrTerminalUnreachable：unknown（事实不可确认，稍后可能自愈）；
//   - ErrTerminalOffline：offline / unsupported / capability 不满足。
//
// Workspace 列表展示与命令门控必须消费同一函数，禁止各自再写 status 判断。
func (p PresencePolicy) TerminalWriteGate(terminal store.TerminalRow, nowUnixMS int64, capability string) error {
	if availability := p.Project(terminal, nowUnixMS); !presenceAvailableForWrite(availability) {
		if availability == PresenceUnknown {
			return ErrTerminalUnreachable
		}
		return ErrTerminalOffline
	}
	if !terminalHasCapability(terminal, capability) {
		// 既有语义保留：能力不满足与离线共用 TERMINAL_OFFLINE 稳定错误码。
		return ErrTerminalOffline
	}
	return nil
}

// RefreshGate 只裁决 freshness（不带 capability），用于目标 Terminal 已被
// Workspace/Session 归属固定的路径（session 命令投递、DSH 导入、web 只读目标）。
func (p PresencePolicy) RefreshGate(terminal store.TerminalRow, nowUnixMS int64) error {
	if availability := p.Project(terminal, nowUnixMS); !presenceAvailableForWrite(availability) {
		if availability == PresenceUnknown {
			return ErrTerminalUnreachable
		}
		return ErrTerminalOffline
	}
	return nil
}

// terminalHasCapability 解析 Daemon hello 声明的白名单能力；解析失败一律按不满足处理。
func terminalHasCapability(terminal store.TerminalRow, capability string) bool {
	var capabilities []string
	if json.Unmarshal([]byte(terminal.CapabilitiesJSON), &capabilities) != nil {
		return false
	}
	for _, name := range capabilities {
		if strings.TrimSpace(name) == capability {
			return true
		}
	}
	return false
}
