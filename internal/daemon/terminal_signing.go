// Package daemon 内的 Terminal 签名私钥加载器（v0.6 P4 决策 2 的收口实现）。
//
// 背景：v0.6 主迭代交付了 Relay 侧签名校验与生产 RelayClient.Signer 出站链路，
// 但"生产 Daemon 进程从哪里拿到 Ed25519 私钥"被显式 deferred。本文件把该残余项
// 收口为可审计的环境契约：
//
//   - AGENT_SESSIONS_DAEMON_SIGNING_KEY_FILE：指向本机 0600 私钥种子文件
//     （内容为一行 base64url 编码的 ed25519 seed，32 字节）。restart.sh 在配对时
//     通过 `daemon keygen` 生成本机身份密钥，并把公钥写入配对请求。
//   - AGENT_SESSIONS_DAEMON_SIGNING_KEY_B64：内联 base64 种子，仅供测试/CI 注入，
//     避免测试读写真实文件系统。
//
// 安全边界：
//   - 两个来源互斥，同时配置视为操作者意图不明确，拒绝启动。
//   - 未配置任何来源时返回 (nil, nil)，进程行为与 bearer 桥接期完全一致（回滚安全）。
//   - 私钥字节只存在于 TerminalRequestSigner 内存中；本文件不打印、不记录任何
//     密钥材料，错误信息只包含环境变量名与长度分类。
package daemon

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"
)

const (
	// TerminalSigningKeyFileEnvironment 是生产/本地开发推荐的私钥供给方式：
	// 指向 Daemon 本机状态目录内的 0600 种子文件，随设备身份一起生命周期管理。
	TerminalSigningKeyFileEnvironment = "AGENT_SESSIONS_DAEMON_SIGNING_KEY_FILE"

	// TerminalSigningKeyEnvironment 是内联种子注入入口，仅用于测试/CI 短生命周期进程；
	// 生产部署优先使用文件方式，避免超长环境变量进入进程快照类诊断工具。
	TerminalSigningKeyEnvironment = "AGENT_SESSIONS_DAEMON_SIGNING_KEY_B64"
)

// terminalAuthErrorCodes 是 v0.6 协议冻结的五类签名认证稳定错误码（ADR-012/OpenAPI）。
// 配置了签名的 Daemon 收到其中任意一个都意味着"密钥供给或时钟存在确定性故障"，
// 必须立即退出而不是无限重试；未配置签名的 bearer 客户端行为不受影响。
var terminalAuthErrorCodes = map[string]struct{}{
	"SIGNATURE_REQUIRED":     {},
	"SIGNATURE_INVALID":      {},
	"NONCE_REUSED":           {},
	"TIMESTAMP_EXPIRED":      {},
	"KEY_UNKNOWN_OR_REVOKED": {},
}

// IsTerminalAuthErrorCode 判断协议错误码是否属于签名认证类失败。
func IsTerminalAuthErrorCode(code string) bool {
	_, ok := terminalAuthErrorCodes[code]
	return ok
}

// LoadTerminalSignerFromEnv 按环境契约加载出站签名器。
// deviceID 是 bearer 绑定的设备 ID；桥接期内 KeyID 与 DeviceID 相同
// （Relay 用设备配对时登记的 identity_public_key 验签，见 internal/domain/signed_terminal.go）。
// 返回值约定：(nil, nil) 表示未配置签名，保持既有 bearer 行为；(nil, err) 表示配置非法，
// 调用方必须拒绝启动，不能静默降级为 bearer。
func LoadTerminalSignerFromEnv(getenv func(string) string, deviceID string) (*TerminalRequestSigner, error) {
	if getenv == nil {
		return nil, errors.New("terminal signing environment reader missing")
	}
	keyFile := strings.TrimSpace(getenv(TerminalSigningKeyFileEnvironment))
	keyInline := strings.TrimSpace(getenv(TerminalSigningKeyEnvironment))
	switch {
	case keyFile != "" && keyInline != "":
		// 双来源同时配置说明意图不明确（与事件 E2EE 半配置拒绝启动同一取舍），
		// 必须拒绝启动而不是猜测优先级。
		return nil, fmt.Errorf("%s 与 %s 互斥，只能选择一种私钥供给方式",
			TerminalSigningKeyFileEnvironment, TerminalSigningKeyEnvironment)
	case keyFile == "" && keyInline == "":
		// 未配置：保持 bearer 桥接路径，零行为变化（计划 §8.2 回滚顺序第 1 条）。
		return nil, nil
	case deviceID == "":
		// 没有 device id 就无法构造 canonical bytes 的 device 绑定；此时继续运行
		// 只会在每次 hello 处失败，直接 fail-closed 更可诊断。
		return nil, fmt.Errorf("已配置 %s/%s 但缺少已配对的 device id，无法绑定 Terminal 签名身份",
			TerminalSigningKeyFileEnvironment, TerminalSigningKeyEnvironment)
	}

	var encodedSeed string
	if keyFile != "" {
		raw, err := os.ReadFile(keyFile)
		if err != nil {
			return nil, fmt.Errorf("读取 %s=%s 失败: %w", TerminalSigningKeyFileEnvironment, keyFile, err)
		}
		encodedSeed = strings.TrimSpace(string(raw))
		if encodedSeed == "" {
			return nil, fmt.Errorf("%s=%s 内容为空", TerminalSigningKeyFileEnvironment, keyFile)
		}
	} else {
		encodedSeed = keyInline
	}

	priv, err := decodeTerminalSigningSeed(encodedSeed)
	if err != nil {
		return nil, fmt.Errorf("Terminal 签名种子格式非法: %w", err)
	}
	// 桥接期 KeyID=deviceID；公钥登记轮换后由 owner 通过 identity-keys API 登记新 key，
	// 届时在此处扩展 KeyID 覆盖配置即可，不影响本次接线。
	return &TerminalRequestSigner{DeviceID: deviceID, KeyID: deviceID, Priv: priv}, nil
}

// decodeTerminalSigningSeed 兼容 base64/base64url 四种常见编码并校验 seed 长度。
// 与 Relay 侧 decodeEd25519PublicKey 保持同一兼容口径，避免多端格式漂移。
func decodeTerminalSigningSeed(encoded string) (ed25519.PrivateKey, error) {
	if encoded == "" {
		return nil, errors.New("empty seed")
	}
	encodings := []*base64.Encoding{
		base64.RawURLEncoding,
		base64.URLEncoding,
		base64.RawStdEncoding,
		base64.StdEncoding,
	}
	for _, enc := range encodings {
		raw, err := enc.DecodeString(encoded)
		if err != nil || len(raw) != ed25519.SeedSize {
			continue
		}
		// NewKeyFromSeed 会从 seed 派生完整私钥；解码切片仅在此处使用。
		return ed25519.NewKeyFromSeed(raw), nil
	}
	return nil, fmt.Errorf("需要 base64 编码的 %d 字节 ed25519 seed", ed25519.SeedSize)
}

// DecodeTerminalSigningSeed 是 seed 解析的导出入口：apps/daemon keygen 幂等回放公钥时
// 复用同一解析规则，保证"写文件"与"读文件"两侧格式永不漂移。
func DecodeTerminalSigningSeed(encoded string) (ed25519.PrivateKey, error) {
	return decodeTerminalSigningSeed(encoded)
}

// GenerateTerminalSigningSeed 生成本机 Terminal 身份密钥对，供 `daemon keygen` 子命令与
// restart.sh 配对流程使用。返回值：
//   - seedB64：base64url(raw url, 无 padding) 编码的 32 字节 seed，即密钥文件的唯一内容；
//   - pubB64：同编码公钥，写入配对请求 identity_public_key 后由 owner/Relay 持久化。
//
// 公私钥同源生成保证"配对时登记的公钥 == 运行期验签公钥"，这是 ADR-002/ADR-012
// 规定的生产形态；随机性来自 crypto/rand，失败即报错，不允许降级为可预测种子。
func GenerateTerminalSigningSeed() (seedB64 string, pubB64 string, err error) {
	seed := make([]byte, ed25519.SeedSize)
	if _, err = rand.Read(seed); err != nil {
		return "", "", fmt.Errorf("生成 Terminal 身份种子失败: %w", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		return "", "", errors.New("ed25519 public key type assertion failed")
	}
	return base64.RawURLEncoding.EncodeToString(seed), base64.RawURLEncoding.EncodeToString(pub), nil
}
