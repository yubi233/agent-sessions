package opencode

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 模型目录 fixture 只验证白名单字段；其中故意放入类似凭据的字段，确保 decoder
// 不会把 provider 原始配置带入 ModelCatalog 或错误摘要。
func newModelCatalogServer(t *testing.T, useFallback bool) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	configHandler := func(w http.ResponseWriter, r *http.Request) {
		if useFallback {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		writeModelCatalogJSON(w, false)
	}
	mux.HandleFunc("/config/providers", configHandler)
	mux.HandleFunc("/provider", func(w http.ResponseWriter, r *http.Request) {
		writeModelCatalogJSON(w, true)
	})
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"healthy": true, "version": "1.17.13"})
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func writeModelCatalogJSON(w http.ResponseWriter, fallback bool) {
	w.Header().Set("Content-Type", "application/json")
	providersKey := "providers"
	if fallback {
		providersKey = "all"
	}
	body := map[string]any{
		providersKey: []any{
			map[string]any{
				"id": "opencode",
				"models": map[string]any{
					"big-pickle": map[string]any{
						"id": "big-pickle", "providerID": "opencode", "status": "active",
						"cost":         map[string]any{"input": 0, "output": 0},
						"capabilities": map[string]any{"reasoning": true},
						"limit":        map[string]any{"context": 200000},
					},
					"mimo-v2.5-free": map[string]any{
						"id": "mimo-v2.5-free", "providerID": "opencode", "status": "active",
						"cost": map[string]any{"input": 0.1, "output": 0.2},
					},
					"disabled-free": map[string]any{
						"id": "disabled-free", "providerID": "opencode", "status": "disabled",
					},
				},
			},
			map[string]any{
				"id": "opencode-go",
				"models": map[string]any{
					"paid": map[string]any{
						"id": "paid", "providerID": "opencode-go", "status": "active",
						"cost": map[string]any{"input": 0, "output": 0},
					},
				},
			},
			map[string]any{
				"id": "openai",
				"models": map[string]any{
					"proxy-zero": map[string]any{
						"id": "proxy-zero", "providerID": "openai", "status": "active",
						"cost": map[string]any{"input": 0, "output": 0},
					},
				},
			},
		},
		"default": map[string]string{"opencode": "big-pickle"},
		// 该字段模拟服务端可能返回的敏感配置；白名单 decoder 应忽略它。
		"key": "do-not-copy",
	}
	_ = json.NewEncoder(w).Encode(body)
}

func modelCatalogClient(t *testing.T, server *httptest.Server) *Client {
	t.Helper()
	t.Setenv(EnvURL, server.URL)
	t.Setenv(EnvUsername, "opencode")
	t.Setenv(EnvPassword, "fixture-password")
	client, err := NewClient()
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	return client
}

func TestValidateModelRefAndDefaultModelFromEnv(t *testing.T) {
	for _, value := range []string{"opencode/big-pickle", "zen/model-v1", "provider/model.id"} {
		if err := ValidateModelRef(value); err != nil {
			t.Fatalf("ValidateModelRef(%q): %v", value, err)
		}
	}
	for _, value := range []string{"", "big-pickle", "/model", "provider/", "provider/model/extra", "provider/model\n"} {
		if value == "" {
			continue
		}
		if err := ValidateModelRef(value); err == nil {
			t.Fatalf("ValidateModelRef(%q) unexpectedly succeeded", value)
		}
	}
	t.Setenv(EnvDefaultModel, " opencode/big-pickle ")
	if got := DefaultModelFromEnv(); got != "opencode/big-pickle" {
		t.Fatalf("default model = %q", got)
	}
	t.Setenv(EnvDefaultModel, "paid-model")
	if got := DefaultModelFromEnv(); got != "" {
		t.Fatalf("invalid default model = %q, want empty", got)
	}
}

func TestDiscoverZenFreeModelsFiltersProviderAndPicksDefault(t *testing.T) {
	t.Setenv(EnvDefaultModel, "")
	server := newModelCatalogServer(t, false)
	catalog, err := modelCatalogClient(t, server).DiscoverZenFreeModels(context.Background())
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	if got, want := catalog.Options, []string{"opencode/big-pickle", "opencode/mimo-v2.5-free"}; !equalStrings(got, want) {
		t.Fatalf("options = %#v, want %#v", got, want)
	}
	if catalog.Default != "opencode/big-pickle" {
		t.Fatalf("default = %q", catalog.Default)
	}
	detail, ok := catalog.Details["opencode/big-pickle"]
	if !ok || !detail.Reasoning || detail.ContextWindowTokens != 200000 || len(detail.Efforts) != 0 {
		t.Fatalf("big-pickle details = %#v", detail)
	}
}

func TestDiscoverZenFreeModelsSupportsProviderFallback(t *testing.T) {
	server := newModelCatalogServer(t, true)
	catalog, err := modelCatalogClient(t, server).DiscoverZenFreeModels(context.Background())
	if err != nil {
		t.Fatalf("fallback discover: %v", err)
	}
	if len(catalog.Options) != 2 || catalog.Default != "opencode/big-pickle" {
		t.Fatalf("fallback catalog = %#v", catalog)
	}
}

func TestDetectExposesDynamicModelCapability(t *testing.T) {
	server := newModelCatalogServer(t, false)
	client := modelCatalogClient(t, server)
	a := NewWithClient(client)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	entry := byCapabilityName(caps, "model_select")
	if entry.Status != adapter.CapabilityNative {
		t.Fatalf("model_select status = %q, reason=%q", entry.Status, entry.Reason)
	}
	if !equalStrings(entry.Options, []string{"opencode/big-pickle", "opencode/mimo-v2.5-free"}) {
		t.Fatalf("model options = %#v", entry.Options)
	}
	if entry.Default != "opencode/big-pickle" {
		t.Fatalf("model default = %q", entry.Default)
	}
	effort := byCapabilityName(caps, "effort_select")
	if effort.Status != adapter.CapabilityUnsupported || effort.Reason != "OpenCode 当前默认模型使用自动推理，未提供可选推理档位。" {
		t.Fatalf("effort_select = %#v", effort)
	}
}

func TestDetectExposesEffortSelectWhenDefaultHasVariants(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"healthy": true, "version": "1.17.13"})
	})
	mux.HandleFunc("/config/providers", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"providers": []any{
				map[string]any{
					"id": "opencode",
					"models": map[string]any{
						"reasoner-free": map[string]any{
							"id": "reasoner-free", "providerID": "opencode", "status": "active",
							"cost":         map[string]any{"input": 0, "output": 0},
							"capabilities": map[string]any{"reasoning": true},
							"limit":        map[string]any{"context": 128000},
							"variants": map[string]any{
								"low":  map[string]any{},
								"high": map[string]any{},
							},
						},
					},
				},
			},
			"default": map[string]string{"opencode": "reasoner-free"},
		})
	})
	mux.HandleFunc("/provider", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	a := NewWithClient(modelCatalogClient(t, server))
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	entry := byCapabilityName(caps, "effort_select")
	if entry.Status != adapter.CapabilityNative {
		t.Fatalf("effort_select status = %q, reason=%q", entry.Status, entry.Reason)
	}
	if !equalStrings(entry.Options, []string{"high", "low"}) {
		t.Fatalf("effort options = %#v", entry.Options)
	}
}

func TestDetectExposesEffortSelectWhenAnyModelHasVariants(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"healthy": true, "version": "1.17.13"})
	})
	mux.HandleFunc("/config/providers", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"providers": []any{
				map[string]any{
					"id": "opencode",
					"models": map[string]any{
						"big-pickle": map[string]any{
							"id": "big-pickle", "providerID": "opencode", "status": "active",
							"cost":         map[string]any{"input": 0, "output": 0},
							"capabilities": map[string]any{"reasoning": true},
							"limit":        map[string]any{"context": 200000},
						},
						"mimo-v2.5-free": map[string]any{
							"id": "mimo-v2.5-free", "providerID": "opencode", "status": "active",
							"cost":         map[string]any{"input": 0, "output": 0},
							"capabilities": map[string]any{"reasoning": true},
							"limit":        map[string]any{"context": 128000},
							"variants": map[string]any{
								"medium": map[string]any{},
								"high":   map[string]any{},
							},
						},
					},
				},
			},
			"default": map[string]string{"opencode": "big-pickle"},
		})
	})
	mux.HandleFunc("/provider", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	a := NewWithClient(modelCatalogClient(t, server))
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	entry := byCapabilityName(caps, "effort_select")
	if entry.Status != adapter.CapabilityNative {
		t.Fatalf("effort_select status = %q, reason=%q", entry.Status, entry.Reason)
	}
	if !equalStrings(entry.Options, []string{"high", "medium"}) {
		t.Fatalf("effort options = %#v", entry.Options)
	}
}

func TestDetectKeepsModelSelectionFailClosedWhenCatalogMissing(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"healthy": true, "version": "1.17.13"})
	})
	mux.HandleFunc("/config/providers", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"providers": []any{}})
	})
	mux.HandleFunc("/provider", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	a := NewWithClient(modelCatalogClient(t, server))
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	entry := byCapabilityName(caps, "model_select")
	if entry.Status != adapter.CapabilityUnsupported || entry.Reason == "" {
		t.Fatalf("missing catalog entry = %#v", entry)
	}
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

// R16 回归：provider facts（v0.9.2 P1）只消费 SPI 的 ModelGroups。Detect 产出的
// model_select 能力必须同时填充 ModelGroups，否则 fact 会以“有默认值、无目录”
// 上行并被 Relay 整条拒绝。这里直接钉住目录 → groups 的映射契约。
func TestModelGroupsFromCatalogGroupsByProviderPrefix(t *testing.T) {
	catalog := ModelCatalog{
		Options: []string{"opencode/a-model", "opencode/b-model", "other/c-model"},
		Default: "opencode/a-model",
		Details: map[string]ModelDetails{
			"opencode/a-model": {ContextWindowTokens: 272000, Reasoning: true, Efforts: []string{"low", "high"}},
		},
	}
	groups := modelGroupsFromCatalog(catalog)
	if len(groups) != 2 {
		t.Fatalf("应按 provider 前缀分成两组: %#v", groups)
	}
	if groups[0].ID != "opencode" || len(groups[0].Models) != 2 {
		t.Fatalf("opencode 组应包含两个模型: %#v", groups[0])
	}
	first := groups[0].Models[0]
	if first.Value != "opencode/a-model" || first.ID != "a-model" || first.Provider != "opencode" {
		t.Fatalf("模型引用映射不正确: %#v", first)
	}
	if first.ContextWindowTokens != 272000 || !first.Reasoning {
		t.Fatalf("Details 安全元数据必须随目录复制: %#v", first)
	}
	if len(first.Efforts) != 2 {
		t.Fatalf("推理档位元数据必须随目录复制: %#v", first)
	}
	if groups[1].ID != "other" || groups[1].Models[0].Value != "other/c-model" {
		t.Fatalf("第二个 provider 分组不正确: %#v", groups[1])
	}
}

func TestModelGroupsFromCatalogEmptyOptionsIsNil(t *testing.T) {
	if groups := modelGroupsFromCatalog(ModelCatalog{}); len(groups) != 0 {
		t.Fatalf("空目录应返回空 groups: %#v", groups)
	}
}
