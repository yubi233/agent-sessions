package relay

import (
	"net/http"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// USAGE-01 / MOBILE-20：Terminal 上传白名单 usage 事件后，owner 只能读取
// 自己账号的 UTC 日桶聚合；重复 usage key 不重复累加；Web/只读 token 不能上传。
func TestUsageUploadAndSummaryHTTP(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "usage-owner@test.dev")
	terminal := env.pairTerminal(t, owner, "usage-terminal")
	daemonHello(t, env, terminal.AccessToken)

	// Terminal 上传两条不同 usage key 的事件。
	upload := func(usageKey, day string, input, output int64) int {
		response := env.do(t, http.MethodPost, "/v1/daemon/usage/events", map[string]any{
			"usage_key": usageKey, "provider": "codex", "utc_day": day,
			"input_tokens": input, "output_tokens": output,
		}, terminal.AccessToken)
		return response.Code
	}
	if code := upload("usage-1", "2026-08-16", 100, 50); code != http.StatusOK {
		t.Fatalf("upload usage status=%d", code)
	}
	if code := upload("usage-2", "2026-08-16", 200, 60); code != http.StatusOK {
		t.Fatalf("upload usage status=%d", code)
	}

	// 重复上传同一 usage key：返回 200 且 inserted=false，不重复累加。
	dup := env.do(t, http.MethodPost, "/v1/daemon/usage/events", map[string]any{
		"usage_key": "usage-1", "provider": "codex", "utc_day": "2026-08-16",
		"input_tokens": 100, "output_tokens": 50,
	}, terminal.AccessToken)
	if dup.Code != http.StatusOK {
		t.Fatalf("duplicate upload status=%d", dup.Code)
	}
	var receipt struct {
		UsageKeyHash string `json:"usage_key_hash"`
		Inserted     bool   `json:"inserted"`
	}
	decodeW1(t, dup.Body.Bytes(), &receipt)
	if receipt.UsageKeyHash == "" || receipt.Inserted {
		t.Fatalf("duplicate receipt unexpected: %+v", receipt)
	}

	// owner 读取 7 天聚合：两条去重后的事件合计 input=300 output=110。
	summary := env.do(t, http.MethodGet, "/v1/usage/summary?days=7", nil, owner.AccessToken)
	if summary.Code != http.StatusOK {
		t.Fatalf("summary status=%d body=%s", summary.Code, summary.Body.String())
	}
	var body struct {
		Days      int    `json:"days"`
		UTCToday  string `json:"utc_today"`
		Providers []struct {
			Provider     string `json:"provider"`
			UTCDay       string `json:"utc_day"`
			InputTokens  int64  `json:"input_tokens"`
			OutputTokens int64  `json:"output_tokens"`
		} `json:"providers"`
		TotalInput  int64 `json:"total_input_tokens"`
		TotalOutput int64 `json:"total_output_tokens"`
	}
	decodeW1(t, summary.Body.Bytes(), &body)
	if body.Days != 7 || body.UTCToday == "" {
		t.Fatalf("summary meta unexpected: %+v", body)
	}
	if body.TotalInput != 300 || body.TotalOutput != 110 {
		t.Fatalf("summary totals unexpected: %+v", body)
	}
	if len(body.Providers) != 1 || body.Providers[0].Provider != "codex" {
		t.Fatalf("providers projection unexpected: %+v", body.Providers)
	}

	// 非法 days 拒绝。
	if bad := env.do(t, http.MethodGet, "/v1/usage/summary?days=5", nil, owner.AccessToken); bad.Code != http.StatusBadRequest {
		t.Fatalf("invalid days status=%d", bad.Code)
	}

	// Web 只读 token 不能上传 usage（RequireTerminal 拒绝）。
	web := env.provisionAdditionalAccount(t, "usage-web@test.dev")
	if code := env.do(t, http.MethodPost, "/v1/daemon/usage/events", map[string]any{
		"usage_key": "web-1", "provider": "codex", "utc_day": "2026-08-16",
		"input_tokens": 1,
	}, web.AccessToken).Code; code == http.StatusOK {
		t.Fatal("web token must not upload usage")
	}
}

// USAGE-01：账号隔离——另一个账号上传的事件不出现在当前账号摘要中。
func TestUsageSummaryAccountIsolationHTTP(t *testing.T) {
	env := newTestEnv(t)
	ownerA := env.registerAs(t, "usage-a@test.dev")
	ownerB := env.provisionAdditionalAccount(t, "usage-b@test.dev")
	termA := env.pairTerminal(t, ownerA, "usage-term-a")
	daemonHello(t, env, termA.AccessToken)
	termB := env.pairTerminal(t, ownerB, "usage-term-b")
	daemonHello(t, env, termB.AccessToken)

	for _, item := range []struct {
		token string
		key   string
		input int64
	}{
		{termA.AccessToken, "acct-a-1", 111},
		{termB.AccessToken, "acct-b-1", 222},
	} {
		response := env.do(t, http.MethodPost, "/v1/daemon/usage/events", map[string]any{
			"usage_key": item.key, "provider": "codex", "utc_day": time.Now().UTC().Format("2006-01-02"),
			"input_tokens": item.input, "output_tokens": 0,
		}, item.token)
		if response.Code != http.StatusOK {
			t.Fatalf("upload status=%d", response.Code)
		}
	}

	summary := env.do(t, http.MethodGet, "/v1/usage/summary?days=1", nil, ownerA.AccessToken)
	if summary.Code != http.StatusOK {
		t.Fatalf("summary status=%d", summary.Code)
	}
	var body struct {
		TotalInput int64 `json:"total_input_tokens"`
	}
	decodeW1(t, summary.Body.Bytes(), &body)
	if body.TotalInput != 111 {
		t.Fatalf("account isolation broken: %d", body.TotalInput)
	}
}

var _ = domain.UsageService{}
