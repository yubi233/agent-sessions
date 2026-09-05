// V087-13 回归（全栈往返）：真实 RelayClient.SyncSessionModes → 真实 gin 路由
// （PUT + 终端归属校验）→ controls 下发目录。锁定"客户端方法 vs 服务端契约"
// 不再漂移——历史 defect（POST 打 PUT-only 路由 404）在 handler 层契约测试中
// 不可见，只有客户端→服务端往返才能暴露（V087-12 真实栈首曝）。
package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	daemon "github.com/yubi233/agent-sessions/internal/daemon"
)

func TestV087SessionModeUplinkThroughRelayClient(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v087-modes-client@test.dev")
	terminal := env.pairTerminal(t, owner, "v087-modes-client-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v087-modes-client")

	// 真实 RelayClient（签名窗口内 bearer 放行，与 v085 契约同口径）指向
	// 同一 gin 路由：SyncSessionModes 的 HTTP 方法必须与服务端 PUT 契约一致。
	server := httptest.NewServer(env.router)
	defer server.Close()
	client := &daemon.RelayClient{BaseURL: server.URL, AccessToken: terminal.AccessToken}

	err := client.SyncSessionModes(context.Background(), sessionID, "default", "", []daemon.SessionModeItem{
		{ID: "default", Name: "默认", Description: "标准权限"},
		{ID: "acceptEdits", Name: "自动接受编辑", Description: "接受文件编辑"},
		{ID: "danger-full-access", Name: "完整访问", Description: "无限制"},
	})
	if err != nil {
		t.Fatalf("SyncSessionModes: %v（若为 404，说明客户端方法与服务端 PUT 契约漂移）", err)
	}

	// controls 下发完整目录（落库断言走真实存储）。
	controls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if controls.Code != http.StatusOK {
		t.Fatalf("controls status=%d body=%s", controls.Code, controls.Body.String())
	}
	var body struct {
		PermissionMode           string   `json:"permission_mode"`
		AvailablePermissionModes []string `json:"available_permission_modes"`
	}
	if err := json.Unmarshal(controls.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode controls: %v", err)
	}
	if body.PermissionMode != "default" || len(body.AvailablePermissionModes) != 3 {
		t.Fatalf("controls 目录不完整: mode=%q modes=%v", body.PermissionMode, body.AvailablePermissionModes)
	}
}
