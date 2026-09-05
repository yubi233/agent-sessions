package relay

// v0.8.9 P1（V089-02）：daemon.hello / daemon.heartbeat additive 返回 relay_generation
// 的 HTTP 契约回归。字段随真实 gin 栈从 relay_instance_meta 透出；同库 restart 稳定；
// 删除重建（新 testEnv）后变化。旧字段缺失视为 legacy，客户端兼容策略见 daemon 侧回归。

import (
	"encoding/json"
	"net/http"
	"testing"
)

// hello/heartbeat 响应都必须携带同一非空 relay_generation；同库 restartRelay 后不变。
func TestV089HelloAndHeartbeatCarryRelayGeneration(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v089-gen-owner@example.test")
	terminal := env.pairTerminal(t, owner, "v089-gen-terminal")

	fetchGeneration := func() string {
		t.Helper()
		response := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
			"protocol_version": 1, "daemon_version": "fixture", "hostname": "v089-fixture", "platform": "test",
			"capabilities": []string{"start"},
		}, terminal.AccessToken)
		if response.Code != http.StatusOK {
			t.Fatalf("hello status=%d body=%s", response.Code, response.Body.String())
		}
		var hello struct {
			RelayGeneration string `json:"relay_generation"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &hello); err != nil {
			t.Fatal(err)
		}
		if hello.RelayGeneration == "" {
			t.Fatalf("hello must carry relay_generation: %s", response.Body.String())
		}
		return hello.RelayGeneration
	}

	helloGeneration := fetchGeneration()

	// heartbeat 通道返回同一世代（运行期发现的基准值）。
	response := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{"protocol_version": 1}, terminal.AccessToken)
	if response.Code != http.StatusOK {
		t.Fatalf("heartbeat status=%d body=%s", response.Code, response.Body.String())
	}
	var heartbeat struct {
		RelayGeneration string `json:"relay_generation"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &heartbeat); err != nil {
		t.Fatal(err)
	}
	if heartbeat.RelayGeneration != helloGeneration {
		t.Fatalf("heartbeat generation %q must match hello %q", heartbeat.RelayGeneration, helloGeneration)
	}

	// 同一 SQLite 文件重开（Relay 进程重启语义）：世代稳定。
	env.restartRelay(t)
	if again := fetchGeneration(); again != helloGeneration {
		t.Fatalf("generation must survive relay restart: %q != %q", again, helloGeneration)
	}
}

// 删除重建（reset_default_local_relay_db 语义）：新库世代必然不同，
// Daemon 据此识别"Relay DB 已更换"。
func TestV089RebuiltRelayDatabaseReportsDifferentGeneration(t *testing.T) {
	first := newTestEnv(t)
	owner := first.registerAs(t, "v089-rebuild-owner@example.test")
	terminal := first.pairTerminal(t, owner, "v089-rebuild-terminal")

	hello := func(e *testEnv, token string) string {
		t.Helper()
		response := e.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
			"protocol_version": 1, "daemon_version": "fixture", "hostname": "v089-fixture", "platform": "test",
			"capabilities": []string{"start"},
		}, token)
		if response.Code != http.StatusOK {
			t.Fatalf("hello status=%d body=%s", response.Code, response.Body.String())
		}
		var body struct {
			RelayGeneration string `json:"relay_generation"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if body.RelayGeneration == "" {
			t.Fatalf("hello must carry relay_generation: %s", response.Body.String())
		}
		return body.RelayGeneration
	}

	oldGeneration := hello(first, terminal.AccessToken)

	// 全新 SQLite（模拟 rm -f 后重建）：世代必变。
	second := newTestEnv(t)
	secondOwner := second.registerAs(t, "v089-rebuild-owner2@example.test")
	secondTerminal := second.pairTerminal(t, secondOwner, "v089-rebuild-terminal2")
	newGeneration := hello(second, secondTerminal.AccessToken)

	if oldGeneration == newGeneration {
		t.Fatalf("rebuilt database must report a different generation: %q", oldGeneration)
	}
}
