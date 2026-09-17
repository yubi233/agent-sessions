package domain

import (
	"encoding/base64"
	"strings"
	"testing"
)

// v0.9.2 §19.3（跨端公钥编码契约）Relay 侧回归。
//
// 背景：Flutter 侧把设备公钥编码统一为 **standard raw base64** 之后，Relay 的 X25519
// 公钥校验（validX25519PublicKey）必须接受该编码。该校验只尝试 RawStd/Std 两种字母表，
// 这正是 R17 之后残留的另一半不对称——编码侧统一后校验侧无需放宽，但必须被回归钉住，
// 否则任何一次"顺手改回 url-safe"都会让设备注册/Web 只读通道静默失效。
//
// 固定向量与 packages/crypto/box_test.go、apps/mobile/test/v092_public_key_encoding_test.dart
// 三处必须一致。
const (
	v092ContractGoldenStd = "+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s"
)

// TestV092ValidX25519PublicKeyAcceptsFlutterStandardRaw 断言 Relay 接受 Flutter 契约编码，
// 同时确认 fail-closed 边界没有被这次改动放宽。
func TestV092ValidX25519PublicKeyAcceptsFlutterStandardRaw(t *testing.T) {
	// 前置：固定向量必须真的落在能区分两种字母表的分组上，否则本回归形同虚设。
	if !strings.ContainsAny(v092ContractGoldenStd, "+/") {
		t.Fatal("固定向量必须包含 '+' 或 '/'，否则无法区分 standard 与 url-safe 字母表")
	}

	if !validX25519PublicKey(v092ContractGoldenStd) {
		t.Fatalf("Flutter 侧 standard raw 公钥必须被判合法: %q", v092ContractGoldenStd)
	}
	// 带 padding 的 standard 编码同样接受（PEM 风格/其他客户端）。
	if padded := v092ContractGoldenStd + "="; !validX25519PublicKey(padded) {
		t.Fatalf("带 padding 的 standard 编码必须被判合法: %q", padded)
	}
	// fail-closed 边界不放宽：长度不符与空值一律拒绝。
	if validX25519PublicKey(base64.RawStdEncoding.EncodeToString([]byte("short"))) {
		t.Fatal("非 32 字节公钥必须被拒绝")
	}
	if validX25519PublicKey("") {
		t.Fatal("空公钥必须被拒绝")
	}
}
