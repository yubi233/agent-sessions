package daemon

import (
	"context"
	"errors"
	"testing"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// DELEG-03/04：deterministic Dispatcher 可启动独立 mock child，未知 Provider 显式 unsupported。
func TestDeterministicDelegationDispatcherStartsAndStopsMockChild(t *testing.T) {
	dispatcher := NewDeterministicDelegationDispatcher()
	if err := dispatcher.ValidateTarget(context.Background(), "mock", "codex"); err != nil {
		t.Fatalf("cross-provider mock target: %v", err)
	}
	if err := dispatcher.ValidateTarget(context.Background(), "mock", "not-authorized"); !errors.Is(err, domain.ErrDelegationUnsupported) {
		t.Fatalf("unsupported target error=%v", err)
	}
	result, err := dispatcher.Start(context.Background(), domain.DelegationDispatchRequest{
		DelegationID: "deleg-1", ChildSessionID: "sess-child", ParentSessionID: "sess-parent",
		WorkspaceID: "fixture-workspace", TargetProvider: "codex",
		TaskEnvelope: []byte(`{"alg":"v1","key_id":"k","nonce":"n","ciphertext":"opaque","aad_hash":"a","payload_version":1}`),
	})
	if err != nil || result.InstanceID == "" {
		t.Fatalf("start result=%+v err=%v", result, err)
	}
	if err := dispatcher.Stop(context.Background(), "deleg-1"); err != nil {
		t.Fatalf("stop child: %v", err)
	}
	if err := dispatcher.Stop(context.Background(), "deleg-1"); err != nil {
		t.Fatalf("second stop must be idempotent: %v", err)
	}
}
