package daemon

// v0.8.8 P1 附件生产接线回归（V088-02/03）：
// 1. V088-02 用 mobile _sealDraft 同构的 Go Seal（逐块 envelope、AAD
//    sessionId/attachment:chunk/seq/dekId、chunk sha256 登记）经真实 Relay §3.3
//    形状的 httptest 端点 + 真实 RelayLoop 生产 sink（fetchAndOpenAttachment）
//    + runner refs 路径，做字节级全链往返——全程不用测试替身 sink。
// 2. V088-03 逐分支 fail-closed：DEK 缺失 / 块哈希不符 / AAD 不符 / refs 哈希
//    不符，断言稳定脱敏失败收口且明文不进错误文本与事件。

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/packages/crypto"
)

// sealLikeMobile 按 mobile attachment_picker._sealEnvelope 契约密封一块：
// nonce = 种子小端 12 字节；AAD 字段顺序与 Dart AssociatedData.toJson 一致；
// 返回值 = envelope JSON 序列化字节（即上传块密文）。此 helper 只在测试内
// 复刻 Seal 侧事实，daemon 生产代码只依赖 §9.1 冻结契约的 Open 面。
func sealLikeMobile(t *testing.T, dek []byte, dekID, sessionID, scope string, seq int, plaintext []byte, nonceSeed int64) []byte {
	t.Helper()
	nonce := make([]byte, 12)
	binary.LittleEndian.PutUint64(nonce, uint64(nonceSeed))
	env, err := crypto.Seal(dek, dekID, 1, crypto.AAD{
		EntityID:        sessionID,
		EventType:       scope,
		ProtocolVersion: 1,
		EventSeq:        int64(seq),
	}, plaintext, nonce)
	if err != nil {
		t.Fatalf("seal chunk: %v", err)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	return raw
}

// sha256Hex 是 refs/projection 共用的明文摘要口径（hex 小写）。
func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// newAttachmentSinkFixture 构造生产接线全链：真实 Store + runner（fake dsh 桥）
// + 真实 RelayLoop（NewRelayLoop 注册生产 sink）+ Relay §3.3 形状 httptest 端点。
// httptest 端点按 serve 投影返回密文；owner-key 端点返回 404 模拟「无 owner 公钥
// 时 DEK 上行失败只记日志、本机 DEK 仍可用」的 localdev/降级形态。
func newAttachmentSinkFixture(t *testing.T, serve func(w http.ResponseWriter, r *http.Request)) (*Store, *SessionRunner, *fakeAdapter, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/owner-key") {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
			return
		}
		serve(w, r)
	}))
	t.Cleanup(server.Close)
	s, runner, fake := newRunnerFixture(t, "dsh")
	// NewRelayLoop 在 runner 上注册生产 attachmentFetchSink/dekSink/modeInfoSink。
	_ = NewRelayLoop(s, &RelayClient{BaseURL: server.URL, AccessToken: "test-token"}, runner, FixtureEventEncoder{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return s, runner, fake, server
}

// seedSessionDEK 预置会话 DEK（等价 SessionDEKManager 已持久化的幂等形态；
// dekSink 异步重放时读到已有 DEK 直接返回，不再访问 owner-key）。
func seedSessionDEK(t *testing.T, s *Store, sessionID string, dek []byte) {
	t.Helper()
	if err := s.Set(sessionDEKLocalStateKey+sessionID, base64.RawStdEncoding.EncodeToString(dek)); err != nil {
		t.Fatalf("seed session dek: %v", err)
	}
}

// startDshSession 消费 session.start（与既有 fixture 形状一致）。
func startDshSession(t *testing.T, runner *SessionRunner, sessionID string) {
	t.Helper()
	start := Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"` + sessionID + `","workspace_root":"/tmp/ws","provider":"dsh",` +
			`"ciphertext":{"fixture_payload":{"prompt":"开始"}}}`,
	}
	if err := runner.ConsumeCommand(context.Background(), start); err != nil {
		t.Fatalf("consume session.start: %v", err)
	}
}

// TestV088AttachmentProductionSinkRoundTrip（V088-02）：mobile 同构 Seal →
// Relay §3.3 投影 → 生产 sink → runner refs → SendContent 图像块字节级一致。
func TestV088AttachmentProductionSinkRoundTrip(t *testing.T) {
	dekBytes := []byte(strings.Repeat("k", 32))
	dekID := "dek-sess-v088-1"
	sessionID := "sess-v088-1"
	attachmentID := "att_v088_1"
	imageBytes := []byte("v088-production-sink-image-bytes-01")

	// mobile Seal 同构：明文切两块，逐块密封（chunk scope，seq 从 0 起）。
	mid := len(imageBytes) / 2
	chunkPlain := [][]byte{imageBytes[:mid], imageBytes[mid:]}
	chunkCiphertext := make([][]byte, 0, len(chunkPlain))
	chunkSHA := make([]string, 0, len(chunkPlain))
	for i, plain := range chunkPlain {
		chunkCiphertext = append(chunkCiphertext, sealLikeMobile(t, dekBytes, dekID, sessionID, "attachment:chunk", i, plain, 1000+int64(i)))
		chunkSHA = append(chunkSHA, sha256Hex(plain))
	}
	proj := AttachmentFetchProjection{
		AttachmentID: attachmentID,
		MimeType:     "image/png",
		ByteSize:     int64(len(imageBytes)),
		TotalChunks:  len(chunkCiphertext),
		Chunks:       chunkCiphertext,
		ChunkSHA256:  chunkSHA,
	}
	projectionJSON, err := json.Marshal(proj)
	if err != nil {
		t.Fatalf("marshal projection: %v", err)
	}

	s, runner, fake, server := newAttachmentSinkFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/attachments/"+attachmentID) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(projectionJSON)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	seedSessionDEK(t, s, sessionID, dekBytes)
	startDshSession(t, runner, sessionID)

	send := Command{
		Kind: "session.send",
		PayloadJSON: `{"session_id":"` + sessionID + `","ciphertext":{"fixture_payload":{"message":"看图",` +
			`"attachments":[{"attachment_id":"` + attachmentID + `","mime":"image/png",` +
			`"size_bytes":` + itoa(len(imageBytes)) + `,"sha256":"` + sha256Hex(imageBytes) + `"}]}}}`,
	}
	if err := runner.ConsumeCommand(context.Background(), send); err != nil {
		t.Fatalf("consume session.send(refs): %v", err)
	}
	h := fake.handles[0]
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.contentSends) != 1 {
		t.Fatalf("生产 sink 应路由到 SendContent，得到 %d 次", len(h.contentSends))
	}
	blocks := h.contentSends[0]
	if len(blocks) != 2 || blocks[0].Type != "text" || blocks[0].Text != "看图" {
		t.Fatalf("内容块形状不正确: %+v", blocks)
	}
	if blocks[1].Type != "image" || blocks[1].ImageMIME != "image/png" {
		t.Fatalf("图像块头不正确: %+v", blocks[1])
	}
	if string(blocks[1].ImageData) != string(imageBytes) {
		t.Fatalf("解密明文字节不一致: 得到 %d 字节", len(blocks[1].ImageData))
	}
	_ = server
}

// itoa 把 int 序列化为 JSON 数字字面量（拼接 refs JSON 用）。
func itoa(n int) string {
	raw, _ := json.Marshal(n)
	return string(raw)
}

// TestV088AttachmentSinkFailClosedBranches（V088-03）：逐分支 fail-closed。
func TestV088AttachmentSinkFailClosedBranches(t *testing.T) {
	dekBytes := []byte(strings.Repeat("k", 32))
	dekID := "dek-sess-v088-2"
	sessionID := "sess-v088-2"
	attachmentID := "att_v088_2"
	imageBytes := []byte("v088-fail-closed-image-bytes")

	chunkCiphertext := sealLikeMobile(t, dekBytes, dekID, sessionID, "attachment:chunk", 0, imageBytes, 2000)
	corruptSHAProjection, err := json.Marshal(AttachmentFetchProjection{
		AttachmentID: attachmentID,
		MimeType:     "image/png",
		ByteSize:     int64(len(imageBytes)),
		TotalChunks:  1,
		Chunks:       [][]byte{chunkCiphertext},
		ChunkSHA256:  []string{sha256Hex([]byte("其它内容"))},
	})
	if err != nil {
		t.Fatalf("marshal projection: %v", err)
	}
	// AAD 不符：块用另一 sessionId 密封（模拟跨会话 AAD 漂移）。
	wrongAAD := sealLikeMobile(t, dekBytes, dekID, "sess-other", "attachment:chunk", 0, imageBytes, 2001)
	wrongAADProjection, err := json.Marshal(AttachmentFetchProjection{
		AttachmentID: attachmentID,
		MimeType:     "image/png",
		ByteSize:     int64(len(imageBytes)),
		TotalChunks:  1,
		Chunks:       [][]byte{wrongAAD},
	})
	if err != nil {
		t.Fatalf("marshal projection: %v", err)
	}

	// served 供 httptest handler goroutine 读取、测试 goroutine 切换用例载荷；
	// 两侧无其他同步点，必须走 atomic（-race 抓到的真实竞争）。
	var served atomic.Value // []byte
	s, runner, fake, server := newAttachmentSinkFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if payload, ok := served.Load().([]byte); ok {
			_, _ = w.Write(payload)
		}
	})
	serverURL := server.URL
	seedSessionDEK(t, s, sessionID, dekBytes)
	startDshSession(t, runner, sessionID)

	sendWithRef := func(sha, size string) Command {
		return Command{
			Kind: "session.send",
			PayloadJSON: `{"session_id":"` + sessionID + `","ciphertext":{"fixture_payload":{"message":"m",` +
				`"attachments":[{"attachment_id":"` + attachmentID + `","mime":"image/png",` +
				`"size_bytes":` + size + `,"sha256":"` + sha + `"}]}}}`,
		}
	}

	cases := []struct {
		name    string
		serving []byte
		refSHA  string
		refSize string
	}{
		{"块哈希不符", corruptSHAProjection, sha256Hex(imageBytes), itoa(len(imageBytes))},
		{"AAD 跨会话不符", wrongAADProjection, sha256Hex(imageBytes), itoa(len(imageBytes))},
		{"refs 全件哈希不符", mustMarshal(t, AttachmentFetchProjection{
			AttachmentID: attachmentID,
			MimeType:     "image/png",
			ByteSize:     int64(len(imageBytes)),
			TotalChunks:  1,
			Chunks:       [][]byte{chunkCiphertext},
			ChunkSHA256:  []string{sha256Hex(imageBytes)},
		}), sha256Hex([]byte("被篡改的登记值")), itoa(len(imageBytes))},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			served.Store(tc.serving)
			err := runner.ConsumeCommand(context.Background(), sendWithRef(tc.refSHA, tc.refSize))
			if err == nil {
				t.Fatalf("%s 应 fail-closed 拒绝", tc.name)
			}
			// 红线：错误文本不得包含明文内容。
			if strings.Contains(err.Error(), string(imageBytes)) {
				t.Fatalf("错误文本泄漏明文: %q", err.Error())
			}
			h := fake.handles[0]
			h.mu.Lock()
			sends := len(h.contentSends)
			h.mu.Unlock()
			if sends != 0 {
				t.Fatalf("失败路径不得产生 SendContent")
			}
		})
	}

	// DEK 缺失分支：未播种 DEK 的会话，生产 sink 必须直接失败（errSessionDEKUnavailable）。
	// 用可达端点保证失败发生在 DEK 检查而非 HTTP 层。
	loop := NewRelayLoop(s, &RelayClient{BaseURL: serverURL, AccessToken: "t"}, nil, FixtureEventEncoder{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	served.Store(mustMarshal(t, AttachmentFetchProjection{
		AttachmentID: "att_x",
		MimeType:     "image/png",
		ByteSize:     1,
		TotalChunks:  1,
		Chunks:       [][]byte{chunkCiphertext},
	}))
	if _, err := loop.fetchAndOpenAttachment(context.Background(), "sess-no-dek", "att_x"); !errors.Is(err, errSessionDEKUnavailable) {
		t.Fatalf("DEK 缺失应返回 errSessionDEKUnavailable，得到 %v", err)
	}
}

func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw
}

// 编译期锚点：确保 adapter 包引用不因重构漂移（fake handle 断言面在 adapter.ContentBlock）。
var _ = adapter.Event{}
