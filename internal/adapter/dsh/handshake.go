package dsh

// v0.9.2：DSH ACP 桥握手超时的可配置化。
//
// 背景（R4 真机实测）：本机链路里 "session.start" 以
//   adapter start: dsh initialize: context deadline exceeded
// 结束——30 秒内 DSH 桥子进程没能完成 initialize（慢启动/机器负载/首次加载
// 模块都可能是原因）。实例因此没建立，随后的 send 被 local_state_missing 正确
// 拒绝（fail-closed 行为正确），但用户看到的是「发不出去」。
//
// 原实现把 handshakeTimeout 写死为 30s 常量，没有调整余地。这里改为可配置：
//   - 缺省仍为 30s（**不改变任何既有行为**，只是多了一个开关）；
//   - 显式配置时生效，便于慢速环境（CI、冷启动、规格较小的机器）与本地调试；
//   - 非法值（负数、非数字）回退缺省，绝不因为配置错误把超时变成 0（那会让
//     握手必然失败，属于危险的静默降级）。
//
// 环境变量：AGENT_SESSIONS_DSH_HANDSHAKE_TIMEOUT_MS（毫秒）

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// EnvHandshakeTimeout 是桥握手超时（毫秒）的环境变量名。
const EnvHandshakeTimeout = "AGENT_SESSIONS_DSH_HANDSHAKE_TIMEOUT_MS"

// defaultHandshakeTimeout 是缺省握手超时。P0 实测冷启动约 359ms，30s 宽裕量
// 足以覆盖常规慢速磁盘；只有环境明确更慢时才需要调大。
const defaultHandshakeTimeout = 30 * time.Second

// handshakeTimeoutFromEnv 解析握手超时；未配置或非法时回退缺省。
func handshakeTimeoutFromEnv() time.Duration {
	raw, ok := os.LookupEnv(EnvHandshakeTimeout)
	if !ok {
		return defaultHandshakeTimeout
	}
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return defaultHandshakeTimeout
	}
	ms, err := strconv.Atoi(trimmed)
	if err != nil || ms <= 0 {
		// 负数/零会把握手变成必然失败，按"配置无效"处理并回退缺省。
		return defaultHandshakeTimeout
	}
	return time.Duration(ms) * time.Millisecond
}
