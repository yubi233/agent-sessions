package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
)

// V093-01 定向诊断（v0.9.3 P0）：复现并量化 F1「万级 delta 回合出箱积压」的传输瓶颈。
//
// 口径：local_test + fixture_data（假 Relay 是本地 httptest，不触真实上游、不消耗 token）。
// 门控 AGENT_SESSIONS_V093_ATTRIB=1 才运行完整规模（默认跳过，避免常规回归跑数分钟）：
//
//	AGENT_SESSIONS_V093_ATTRIB=1 \
//	AGENT_SESSIONS_V093_ATTRIB_EVENTS=16779 \   # R18 云端实测的单回合 delta 规模
//	AGENT_SESSIONS_V093_ATTRIB_RTT_MS=30 \      # 模拟云端单请求 RTT（R18 实测约 16 条/秒 ≈ 60ms/条）
//	go test ./internal/daemon -run TestV093EventThroughputBaseline -v -timeout 40m
//
// 归因模型：flushEvents 对每条事件执行「1 次 HTTP POST + 1 条 autocommit UPDATE」，
// 串行吞吐 ≈ 1000/(rtt_ms + 本地落账毫秒) 条/秒。R18 云端 16 条/秒与 RTT≈60ms 吻合；
// 本诊断在同机同时测出「带 RTT」与「零 RTT」两组数字，把网络成本与本地落账成本分开。
func TestV093EventThroughputBaseline(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_V093_ATTRIB") != "1" {
		t.Skip("AGENT_SESSIONS_V093_ATTRIB != 1：跳过 V093-01 全量吞吐诊断（定向复跑入口）")
	}

	eventsN := envIntOr("AGENT_SESSIONS_V093_ATTRIB_EVENTS", 16779)
	rttMS := envIntOr("AGENT_SESSIONS_V093_ATTRIB_RTT_MS", 30)
	probeN := envIntOr("AGENT_SESSIONS_V093_ATTRIB_PROBE_EVENTS", 2000)

	report := v093ThroughputReport{
		Suite:       "V093-01",
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Scenario: map[string]int{
			"events":            eventsN,
			"simulated_rtt_ms":  rttMS,
			"zero_rtt_probe_n":  probeN,
			"r18_reference_rps": 16,
		},
	}

	// 场景 A：R18 规模 + 模拟云端 RTT。这是与 R18 实测（约 16 条/秒）对齐的主数字。
	result, samples := runV093ThroughputScenario(t, eventsN, time.Duration(rttMS)*time.Millisecond)
	report.SerialBaseline = result
	report.BacklogSamples = samples

	// 场景 B：零 RTT 探针。分离「本地 SQLite 落账 + HTTP 往返代码路径」的成本占比，
	// 证明瓶颈主要是网络串行而不是本地 store（批量修复因此必须同时批量化两侧）。
	report.ZeroRTTProbe, _ = runV093ThroughputScenario(t, probeN, 0)

	report.Conclusion = fmt.Sprintf(
		"串行逐条上传在 rtt=%dms 时吞吐约 %d 条/秒（%d 条耗时 %.1fs），与 R18 云端实测 16 条/秒同量级；"+
			"零 RTT 探针吞吐约 %d 条/秒，说明本地落账不是主瓶颈。修复方向：批量上传（每批 ≤200 条，1 次 HTTP 往返）"+
			"+ 单事务批量标记 delivered，把万级追平从「N×RTT」降为「⌈N/批⌉×RTT」。",
		rttMS, result.EventsPerSec, eventsN, float64(result.DrainMS)/1000, report.ZeroRTTProbe.EventsPerSec,
	)
	report.Verification = map[string]bool{
		"real_browser": false, "real_model": false, "real_upstream": false,
		"fixture_data": true, "local_test": true, "headless": false,
	}

	path := writeV093Report(t, "v093-throughput-baseline", report)
	t.Logf("V093-01 报告已写入 %s", path)
	t.Logf("场景A（rtt=%dms）：%d 条耗时 %.1fs ≈ %d 条/秒；场景B（零RTT）：%d 条/秒",
		rttMS, eventsN, float64(result.DrainMS)/1000, result.EventsPerSec, report.ZeroRTTProbe.EventsPerSec)
}

// v093ScenarioResult 是单个吞吐场景的量化结果（只含整数与耗时，无任何事件内容）。
type v093ScenarioResult struct {
	Events       int     `json:"events"`
	RTTMS        int     `json:"rtt_ms"`
	HTTPRequests int     `json:"http_requests"`
	Delivered    int     `json:"delivered"`
	DrainMS      int64   `json:"drain_ms"`
	EventsPerSec int64   `json:"events_per_sec"`
	BacklogPeak  int     `json:"backlog_peak"`
	HalfLifeS    float64 `json:"backlog_half_life_s"`
}

type v093ThroughputReport struct {
	Suite          string              `json:"suite"`
	GeneratedAt    string              `json:"generated_at"`
	Scenario       map[string]int      `json:"scenario"`
	SerialBaseline v093ScenarioResult  `json:"serial_baseline"`
	ZeroRTTProbe   v093ScenarioResult  `json:"zero_rtt_probe"`
	BacklogSamples []v093BacklogSample `json:"backlog_samples"`
	Conclusion     string              `json:"conclusion"`
	Verification   map[string]bool     `json:"verification"`
}

// v093BacklogSample 是积压曲线的一个采样点（时间 + pending 数）。
type v093BacklogSample struct {
	ElapsedS     float64 `json:"elapsed_s"`
	PendingCount int64   `json:"pending"`
}

// runV093ThroughputScenario 执行一个吞吐场景：入箱 events 条 delta、以指定 RTT 的
// 假 Relay 排空，返回量化结果与积压曲线采样。事件内容全部是协议形态合法的 fixture
// 密文外形，不含正文；报告只保留计数。
func runV093ThroughputScenario(t *testing.T, events int, rtt time.Duration) (v093ScenarioResult, []v093BacklogSample) {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	var mu sync.Mutex
	httpRequests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rtt > 0 {
			time.Sleep(rtt)
		}
		mu.Lock()
		httpRequests++
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{}`)
	}))
	defer server.Close()

	// 入箱 events 条 message.delta（R18 故障链的规模口径；envelope 为 fixture 外形）。
	for i := 0; i < events; i++ {
		if err := store.EnqueueRelayEvent(RelayEvent{
			EventID: id.New("evt"), CommandID: "cmd-v093", SessionID: "sess-v093",
			EventType:       "message.delta",
			EnvelopeJSON:    `{"alg":"fixture-aead","key_id":"k","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`,
			CreatedAtUnixMS: time.Now().UnixMilli(),
		}); err != nil {
			t.Fatalf("enqueue event %d: %v", i, err)
		}
	}

	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}, nil,
		FixtureEventEncoder{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	// V093-02 起新 RelayLoop 默认走批量路径；基线诊断必须显式钉回逐条路径，
	// 否则「串行基线」的数字会随默认值漂移、失去与 R18 的可比性。
	loop.eventBatchSize = 1

	// 积压曲线采样：每 200ms 记录一次 pending 数，用于追平形态（半衰期）可视化。
	stopSampling := make(chan struct{})
	var sampleMu sync.Mutex
	var samples []v093BacklogSample
	started := time.Now()
	go func() {
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stopSampling:
				return
			case <-ticker.C:
				count, err := store.PendingRelayEventCount()
				if err != nil {
					continue
				}
				sampleMu.Lock()
				samples = append(samples, v093BacklogSample{
					ElapsedS:     time.Since(started).Seconds(),
					PendingCount: count,
				})
				sampleMu.Unlock()
			}
		}
	}()

	// 排空：单次 flushEvents 会取出「查询时刻全部 pending」并串行上传。
	// 极端情况下入箱与查询有竞态，这里循环到 pending 归零（上限保护防死循环）。
	ctx := context.Background()
	for drain := 0; drain < 100; drain++ {
		pending, err := store.PendingRelayEventCount()
		if err != nil {
			t.Fatalf("pending count: %v", err)
		}
		if pending == 0 {
			break
		}
		if err := loop.flushEvents(ctx); err != nil {
			t.Fatalf("flush: %v", err)
		}
	}
	drainMS := time.Since(started).Milliseconds()
	close(stopSampling)

	sampleMu.Lock()
	defer sampleMu.Unlock()
	remaining, err := store.PendingRelayEventCount()
	if err != nil {
		t.Fatalf("final pending count: %v", err)
	}
	if remaining != 0 {
		t.Fatalf("排空后仍有 %d 条 pending", remaining)
	}
	mu.Lock()
	requests := httpRequests
	mu.Unlock()
	if requests != events {
		t.Fatalf("HTTP 请求数 %d != 事件数 %d：逐条上传契约被破坏", requests, events)
	}

	// 半衰期：积压首次降到峰值一半的耗时。R18 的 UI 迟收敛体感对应这段曲线的尾部。
	peak := 0
	for _, s := range samples {
		if int(s.PendingCount) > peak {
			peak = int(s.PendingCount)
		}
	}
	halfLife := -1.0
	if peak > 0 {
		for _, s := range samples {
			if float64(s.PendingCount) <= float64(peak)/2 {
				halfLife = s.ElapsedS
				break
			}
		}
	}
	if halfLife < 0 && len(samples) > 0 {
		halfLife = samples[len(samples)-1].ElapsedS
	}

	rate := int64(0)
	if drainMS > 0 {
		rate = int64(events) * 1000 / drainMS
	}
	return v093ScenarioResult{
		Events: events, RTTMS: int(rtt.Milliseconds()), HTTPRequests: requests,
		Delivered: events, DrainMS: drainMS, EventsPerSec: rate,
		BacklogPeak: peak, HalfLifeS: halfLife,
	}, samples
}

// writeV093Report 把诊断报告写入 e2e-verify/reports/V093-ATTRIB/（时间戳命名，可重复运行不覆盖）。
func writeV093Report(t *testing.T, name string, report v093ThroughputReport) string {
	t.Helper()
	root, err := findRepoRoot()
	if err != nil {
		t.Fatalf("定位仓库根： %v", err)
	}
	dir := filepath.Join(root, "e2e-verify", "reports", "V093-ATTRIB")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("创建报告目录： %v", err)
	}
	path := filepath.Join(dir, fmt.Sprintf("%s-%s.json", name, time.Now().Format("20060102T150405Z")))
	payload, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatalf("序列化报告： %v", err)
	}
	if err := os.WriteFile(path, payload, 0o644); err != nil {
		t.Fatalf("写入报告： %v", err)
	}
	return path
}

// findRepoRoot 从当前目录向上定位含 e2e-verify 的仓库根（go test 的 CWD 是包目录）。
func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		if info, err := os.Stat(filepath.Join(dir, "e2e-verify")); err == nil && info.IsDir() {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("未找到仓库根（缺少 e2e-verify 目录）")
}

func envIntOr(key string, fallback int) int {
	if raw := os.Getenv(key); raw != "" {
		var value int
		if _, err := fmt.Sscanf(raw, "%d", &value); err == nil && value > 0 {
			return value
		}
	}
	return fallback
}
