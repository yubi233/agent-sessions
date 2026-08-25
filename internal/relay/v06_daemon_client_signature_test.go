package relay

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/daemon"
)

// TestV06DaemonClientSignedProductionLoop 是 P4 发布门的补口回归：
// v0.6 P1 的纵向签名闭环使用的是测试侧手工签名 helper，生产 Daemon 客户端
// （internal/daemon.RelayClient 携带 Signer，含"hello 前先取一次性 challenge"的
// 出站链路）此前没有任何测试覆盖。本用例在真实 HTTP 服务器（httptest.NewServer，
// 完整 TCP 栈）上驱动生产客户端走完
// signed hello → heartbeat → 命令投递(SSE) → ack → 密文事件上传 → result 收口。
// 口径：local_test=true、fixture_data=true、real_browser=false、real_model=false、headless=false。
func TestV06DaemonClientSignedProductionLoop(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v06-prod-client@test.dev")
	terminal, token := env.newV06SignedTerminal(t, owner, "v06-prod-client-terminal")

	// 真实 HTTP 服务器：与既有 P2 重启矩阵同一装配方式，覆盖完整网络栈。
	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)

	// 生产客户端：Signer 非 nil 时所有 Terminal POST 自动附加 v0.6 签名。
	client := &daemon.RelayClient{
		BaseURL:     server.URL,
		AccessToken: token,
		Signer: &daemon.TerminalRequestSigner{
			DeviceID: terminal.deviceID,
			KeyID:    terminal.keyID,
			Priv:     terminal.priv,
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// 1) signed hello：客户端内部先取一次性 challenge，再以 challenge 作为 nonce 签名。
	hello, err := client.Hello(ctx, "v06-prod-client", "prod-host", "darwin", []string{"start"})
	if err != nil {
		t.Fatalf("production signed hello: %v", err)
	}
	if hello.TerminalID == "" || hello.ProtocolVersion != 1 || hello.HeartbeatIntervalSeconds <= 0 {
		t.Fatalf("production hello projection incomplete: %+v", hello)
	}
	if len(hello.TerminalID) == 0 || !strings.HasPrefix(hello.TerminalID, "term_") {
		t.Fatalf("hello must project a terminal id, got %q", hello.TerminalID)
	}

	// 2) signed heartbeat：随机 nonce 自动生成；重复 nonce 由 Relay fail-closed（由契约套件覆盖）。
	if err := client.Heartbeat(ctx); err != nil {
		t.Fatalf("production signed heartbeat: %v", err)
	}

	// 3) owner 绑定会话并提交命令；命令必须经 Relay outbox / SSE 投递到生产客户端。
	// workspace.terminal_id 使用 hello 返回的 Terminal ID（term_ 前缀）。
	sessionID, _ := env.createBoundSession(t, owner, hello.TerminalID, "v06-prod-client-project")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v06-prod-client-1", "lease_epoch": epoch,
		"target_terminal_id": hello.TerminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit production-loop command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)

	// 4) 生产 SSE 消费：收到投递后取消流。Stream 使用 bearer GET（只读投递不进入签名面）。
	type delivery struct {
		seq int64
		id  string
	}
	deliveries := make(chan delivery, 1)
	streamCtx, stopStream := context.WithCancel(ctx)
	streamDone := make(chan error, 1)
	go func() {
		err := client.Stream(streamCtx, 0, func(_ context.Context, d daemon.RelayDelivery) error {
			select {
			case deliveries <- delivery{seq: d.DeliverySeq, id: d.Command.CommandID}:
			default:
			}
			return nil
		})
		streamDone <- err
		close(streamDone)
	}()
	select {
	case got := <-deliveries:
		if got.id != submitted.ID || got.seq <= 0 {
			t.Fatalf("unexpected first delivery: %+v want command %s", got, submitted.ID)
		}
	case <-time.After(5 * time.Second):
		stopStream()
		t.Fatalf("production client did not receive command delivery in time")
	}
	stopStream()
	<-streamDone // 等待 SSE 连接完全退出，避免泄漏到下一个阶段。

	// 5) signed ack：received → started，全部经生产 postJSONSigned 链路。
	if err := client.Ack(ctx, submitted.ID, 1, "received", ""); err != nil {
		t.Fatalf("production signed received ack: %v", err)
	}
	if err := client.Ack(ctx, submitted.ID, 1, "started", ""); err != nil {
		t.Fatalf("production signed started ack: %v", err)
	}

	// 6) signed 事件上传：envelope 只允许 opaque 密文（fixture AEAD 形状），Relay 不见明文。
	event := daemon.RelayEvent{
		EventID:      "evt-v06-prod-client-1",
		CommandID:    submitted.ID,
		SessionID:    sessionID,
		EventType:    "turn.started",
		EnvelopeJSON: `{"alg":"fixture-aead","key_id":"fixture-key","nonce":"fixture-nonce","ciphertext":"v06-prod-opaque","aad_hash":"fixture-aad","payload_version":1}`,
	}
	if err := client.UploadEvent(ctx, event); err != nil {
		t.Fatalf("production signed event upload: %v", err)
	}

	// 7) signed result 收口：Relay 返回权威终态回执。
	receipt, err := client.Resolve(ctx, submitted.ID, 1, "succeeded", "")
	if err != nil {
		t.Fatalf("production signed result: %v", err)
	}
	if receipt.CommandID != submitted.ID || receipt.Status != "succeeded" {
		t.Fatalf("production result receipt mismatch: %+v", receipt)
	}

	// 8) 幂等重放保护同样作用于生产客户端：重复 event_id（新 nonce）返回幂等回执而非二次追加。
	if err := client.UploadEvent(ctx, event); err != nil {
		t.Fatalf("duplicate event must be idempotent receipt: %v", err)
	}
}
