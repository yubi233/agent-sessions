package dsh

// v0.9.2 P1（C2/V092-05）：DSH 适配器的**受控重探测**。
//
// 问题（P0 实测 L3，证据 e2e-verify/reports/2026-09-16T04-36-52-300Z/V092-ATTRIB/）：
// Detect 首轮结果被 handshakeDone 永久缓存——首次失败（云端 Relay 容器无 node、
// 桥路径写错、临时权限问题）之后，即使环境已经修好，同一进程内仍然一直
// fail-closed，移动端因此持续显示"Provider 当前不可用"，只能重启进程。
//
// 修复口径（迭代计划 §3.2 C2，冻结契约）：
//   1) 受控：失败才允许重探，且受最小重探间隔约束；成功快照仍然零成本命中，
//      绝不退化为"每个请求都 spawn 桥"（握手要 spawn 子进程，有真实成本）。
//   2) 集中：触发条件只在本文件里判定（handshakeDone && !handshakeOK && 冷却已过），
//      不散落到调用方；并发调用由 a.mu 串行化，天然 single-flight。
//   3) 可注入：时钟与日志走可通过环境变量配置的注入点，测试不需要 sleep。
//   4) 可解释：重探失败的**新**原因实时覆盖旧原因（用户能看到最新事实），
//      重探成功即恢复能力矩阵与模型目录。
//
// 环境变量：
//   AGENT_SESSIONS_DSH_REPROBE_COOLDOWN_MS  最小重探间隔毫秒；缺省 15000；
//                                           0 表示"不缓存失败"（每次 Detect 都重探，
//                                           仅限诊断/测试）；显式置空视为未配置。
//   AGENT_SESSIONS_DSH_REPROBE_LOG=1        打开重探诊断日志（stderr，脱敏：只记原因长度）。

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// EnvReprobeCooldown 是失败后最小重探间隔（毫秒）的环境变量名。
const EnvReprobeCooldown = "AGENT_SESSIONS_DSH_REPROBE_COOLDOWN_MS"

// EnvReprobeLog 打开重探诊断日志（与 AGENT_SESSIONS_DSH_STATUS_* 诊断口径一致）。
const EnvReprobeLog = "AGENT_SESSIONS_DSH_REPROBE_LOG"

// defaultReprobeCooldown 是失败后的缺省最小重探间隔。
// 取值理由：足够长以避免把"每请求探测"变成隐式的 spawn 风暴（移动端 capability
// 轮询可达秒级），又足够短以让用户在修好环境后十几秒内自愈、无需重启 Daemon。
const defaultReprobeCooldown = 15 * time.Second

// reprobeCooldownFromEnv 解析最小重探间隔。负值视为未配置（回退缺省），
// 显式置空同样回退缺省——该开关不具备"关闭安全门"的语义。
func reprobeCooldownFromEnv() time.Duration {
	raw, ok := os.LookupEnv(EnvReprobeCooldown)
	if !ok {
		return defaultReprobeCooldown
	}
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return defaultReprobeCooldown
	}
	ms, err := strconv.Atoi(trimmed)
	if err != nil || ms < 0 {
		return defaultReprobeCooldown
	}
	return time.Duration(ms) * time.Millisecond
}

// reprobeLogEnabled 报告是否开启重探诊断日志。
func reprobeLogEnabled() bool {
	v := strings.TrimSpace(os.Getenv(EnvReprobeLog))
	return v == "1" || strings.EqualFold(v, "true")
}

// logReprobeFailure 输出脱敏重探诊断：只记阶段、原因长度与冷却，不记路径/凭据/正文。
func (a *Adapter) logReprobeFailure(attempt int, reason string) {
	if !reprobeLogEnabled() {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[dsh-reprobe] attempt=%d result=failed reason_bytes=%d cooldown_ms=%d\n",
		attempt, len(reason), a.reprobeCooldown.Milliseconds())
}

// noteDetectFailureLocked 在**持锁**状态下登记一次探测失败。
// 预算是"允许下一次重探"的时间点：只有在冷却到期后，Detect 才会再次 spawn 桥。
func (a *Adapter) noteDetectFailureLocked() {
	if a.reprobeCooldown <= 0 {
		// 显式关闭失败缓存：下一次 Detect 立即重探（诊断/测试用，不用于生产缺省）。
		a.reprobeAllowedAt = time.Time{}
		return
	}
	a.reprobeAllowedAt = a.now().Add(a.reprobeCooldown)
}

// shouldReprobeLocked 判定当前是否满足受控重探条件（调用方须持 a.mu）。
//
// 条件集中在此处，是有意为之：Detect 只在"已经探测过、结果是失败、且冷却已过"
// 三种条件同时成立时才重探。任一条件不成立都直接返回缓存矩阵——
// 成功快照永不重探（零成本命中），冷却未到也不重探（防 spawn 风暴）。
func (a *Adapter) shouldReprobeLocked() bool {
	if !a.handshakeDone || a.handshakeOK {
		return false
	}
	if a.reprobeCooldown <= 0 {
		return true
	}
	return !a.now().Before(a.reprobeAllowedAt)
}

// noteDetectSuccessLocked 在**持锁**状态下登记一次探测成功：
// 清空重探预算并复位计数，后续 Detect 回到纯缓存命中路径。
func (a *Adapter) noteDetectSuccessLocked() {
	a.reprobeAllowedAt = time.Time{}
	a.reprobeAttempts = 0
}

// reprobeAttemptCount 返回累计重探次数（诊断/测试观测点；成功即复位）。
func (a *Adapter) reprobeAttemptCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.reprobeAttempts
}
