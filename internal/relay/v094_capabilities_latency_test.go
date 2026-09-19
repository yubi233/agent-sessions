package relay

import (
	"os/exec"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter/dsh"
)

// 使用真实 node 进程加载不存在的桥，覆盖生产 EOF 路径而非更换为静态能力矩阵。
func TestV094CapabilitiesMissingBridgeReturnsWithoutHandshakeTimeout(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("本回归需要 node 复现桥进程退出")
	}
	v092ForceRelayCannotExecuteDSH(t)
	t.Setenv(dsh.EnvHandshakeTimeout, "5000")
	t.Setenv(dsh.EnvReprobeCooldown, "0")
	for _, key := range []string{"AGENT_SESSIONS_CLAUDE_BIN", "AGENT_SESSIONS_CODEX_BIN", "AGENT_SESSIONS_OPENCODE_URL", "AGENT_SESSIONS_OPENCLAW_URL"} {
		t.Setenv(key, "")
	}
	env := newTestEnv(t)
	owner := env.registerAs(t, "v094-missing-bridge@test.dev")
	for attempt := range 3 {
		started := time.Now()
		providers := v092FetchProviders(t, env, owner.AccessToken)
		elapsed := time.Since(started)
		if elapsed >= 2*time.Second {
			t.Fatalf("EOF 不应等待握手超时: %s", elapsed)
		}
		if provider := providers["dsh"]; provider.Available || provider.FactsSource != "unavailable" {
			t.Fatalf("缺失桥必须保持 fail-closed: %+v", provider)
		}
		t.Logf("attempt=%d capabilities_elapsed=%s", attempt+1, elapsed)
	}
}
