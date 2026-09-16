package dsh

// v0.9.2 回归：桥握手超时可配置（R4 真机实测暴露 30s 内桥未完成 initialize）。
//
// 契约：
//   - 未配置或非法（空/负数/非数字）→ 回退缺省 30s（绝不静默变成 0，那会让握手必然失败）；
//   - 显式正数 → 生效（供慢速环境与本地调试调大）；
//   - handshakeTimeoutFor 每次重新解析，测试之间不互相污染。

import (
	"testing"
	"time"
)

func TestV092HandshakeTimeoutDefaultsTo30s(t *testing.T) {
	t.Setenv(EnvHandshakeTimeout, "")
	if got := handshakeTimeoutFromEnv(); got != 30*time.Second {
		t.Fatalf("缺省必须是 30s，got %v", got)
	}
}

func TestV092HandshakeTimeoutEnvOverride(t *testing.T) {
	t.Setenv(EnvHandshakeTimeout, "120000")
	if got := handshakeTimeoutFromEnv(); got != 120*time.Second {
		t.Fatalf("显式毫秒值必须生效，got %v", got)
	}
	if got := handshakeTimeoutFor(); got != 120*time.Second {
		t.Fatalf("handshakeTimeoutFor 必须反映当前环境，got %v", got)
	}
}

func TestV092HandshakeTimeoutInvalidFallsBack(t *testing.T) {
	for _, raw := range []string{"0", "-1", "abc", "  "} {
		t.Setenv(EnvHandshakeTimeout, raw)
		if got := handshakeTimeoutFromEnv(); got != 30*time.Second {
			t.Fatalf("非法值 %q 必须回退缺省 30s，got %v", raw, got)
		}
	}
}
