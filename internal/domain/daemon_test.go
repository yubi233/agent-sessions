package domain

import (
	"testing"

	"github.com/yubi233/agent-sessions/packages/protocol"
)

// P2-F：只读投影只能消费协议登记的错误码；Terminal 的自由文本不得离开受限执行边界。
func TestSafeErrorCodeAllowsOnlyPublicDaemonCodes(t *testing.T) {
	if got := safeErrorCode(protocol.ErrDaemonRestartRecovery); got != protocol.ErrDaemonRestartRecovery {
		t.Fatalf("restart recovery code=%q", got)
	}
	if got := safeErrorCode("adapter raw stderr: /private/workspace"); got != protocol.ErrDaemonExecutionFailed {
		t.Fatalf("unknown daemon code=%q want %q", got, protocol.ErrDaemonExecutionFailed)
	}
	if got := safeErrorCode("  "); got != "" {
		t.Fatalf("empty daemon code=%q", got)
	}
}
