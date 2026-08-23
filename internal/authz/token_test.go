package authz

import "testing"

// Terminal 是唯一长寿命访问令牌角色：RequireAuth 逐请求查库校验令牌与设备状态，
// 撤销即时生效，TTL 只影响陈旧行清理。该差异是无头 Daemon 免于 15 分钟过期 401 的桥接。
func TestAccessTTLOfTerminalIsLongLived(t *testing.T) {
	if got := AccessTTLOf("terminal"); got != TerminalAccessTTL {
		t.Fatalf("terminal ttl = %v, want %v", got, TerminalAccessTTL)
	}
	for _, role := range []string{"", "android_owner", "web", "future_role"} {
		if got := AccessTTLOf(role); got != AccessTTL {
			t.Fatalf("role %q ttl = %v, want default %v", role, got, AccessTTL)
		}
	}
	if TerminalAccessTTL <= AccessTTL {
		t.Fatalf("terminal ttl %v must exceed interactive ttl %v", TerminalAccessTTL, AccessTTL)
	}
}
