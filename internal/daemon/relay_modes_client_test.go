// V087-13 回归（缺陷复现测试）：SyncSessionModes 必须以 PUT 上行 mode 目录。
// 历史 defect（v0.8.5 引入、V087-12 真实栈首曝）：客户端误用 POST 打到
// PUT-only 路由（handlers.go 只注册 daemon.PUT），gin 返回 404，mode 目录
// 从此无法同步，App 侧"权限目录未同步"提示常驻。本测试锁定方法契约。
package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRelayClientSyncSessionModesUsesPut(t *testing.T) {
	var gotMethod string
	var gotPath string
	var gotBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		gotMethod = request.Method
		gotPath = request.URL.Path
		raw, _ := io.ReadAll(request.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":"stored"}`)
	}))
	defer server.Close()

	client := &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}
	err := client.SyncSessionModes(context.Background(), "sess-modes-1", "default", "", []SessionModeItem{
		{ID: "default", Name: "默认"},
		{ID: "acceptEdits", Name: "自动接受编辑"},
	})
	if err != nil {
		t.Fatalf("sync modes: %v（若为 404，说明客户端方法与服务端 PUT 契约漂移）", err)
	}

	// 方法契约：服务端只注册了 daemon.PUT，POST 会被 gin 判 404。
	if gotMethod != http.MethodPut {
		t.Fatalf("SyncSessionModes method = %s, want PUT（方法漂移会让真实 Relay 返回 404）", gotMethod)
	}
	if gotPath != "/v1/daemon/sessions/sess-modes-1/modes" {
		t.Fatalf("path = %s", gotPath)
	}
	if gotBody["mode_id"] != "default" {
		t.Fatalf("mode_id = %v", gotBody["mode_id"])
	}
	modes, ok := gotBody["available_permission_modes"].([]any)
	if !ok || len(modes) != 2 || modes[0].(map[string]any)["id"] != "default" {
		t.Fatalf("available_permission_modes = %v", gotBody["available_permission_modes"])
	}
}
