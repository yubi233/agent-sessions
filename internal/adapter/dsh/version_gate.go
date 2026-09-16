package dsh

import (
	"fmt"
	"os"
	"strings"
)

// EnvAllowedVersions 覆盖已验证桥版本白名单（逗号分隔 agentInfo.version）。
// 语义对齐 binConfig：未设置→内置默认；显式置空→报错（fail-loud，不静默回落）。
// 桥升级/换桥必须先人工复验登记，再经本变量或修订内置默认放行（ADR-013 §2）。
const EnvAllowedVersions = "AGENT_SESSIONS_DSH_ALLOWED_VERSIONS"

// verifiedBridgeName 是已登记桥的 agentInfo.name（ADR-013 §2 冻结），
// 与 deepseek-harness packages/acp/acp 桥实现和全部假桥 fixture 一致。
const verifiedBridgeName = "deepseek-harness-acp"

// defaultVerifiedBridgeVersions 是实施记录登记的已验证 agentInfo.version 集合。
// 已知限制：桥在 wire 上回报静态版本（不随 DSH checkout 包版本变化），本门保证
// "未登记的桥名/版本一律 fail-closed（升级必须显式复验）"，不提供 checkout 内容级校验。
var defaultVerifiedBridgeVersions = []string{"0.0.1"}

// verifiedBridgeVersions 解析生效的版本白名单：默认集合或环境变量覆盖。
func verifiedBridgeVersions() ([]string, error) {
	raw, ok := os.LookupEnv(EnvAllowedVersions)
	if !ok {
		return defaultVerifiedBridgeVersions, nil
	}
	if strings.TrimSpace(raw) == "" {
		return nil, fmt.Errorf("%s 显式置空，视为未配置", EnvAllowedVersions)
	}
	var versions []string
	seen := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		version := strings.TrimSpace(part)
		if version == "" || seen[version] {
			continue
		}
		seen[version] = true
		versions = append(versions, version)
	}
	if len(versions) == 0 {
		return nil, fmt.Errorf("%s 未包含任何版本", EnvAllowedVersions)
	}
	return versions, nil
}

// bridgeHandshakeAllowed 实现 ADR-013 §2 版本门：initialize 应答的 agentInfo
// 桥名必须精确匹配、版本必须在白名单内；越界返回中文错误，调用方
// （Detect/storeHandshake/Start/Resume）据此 fail-closed，不写 Version 字段。
func bridgeHandshakeAllowed(info initializeResult) error {
	if info.AgentInfo.Name != verifiedBridgeName {
		return fmt.Errorf("桥名 %q 不在已登记范围（要求 %q），能力矩阵已安全禁用", info.AgentInfo.Name, verifiedBridgeName)
	}
	versions, err := verifiedBridgeVersions()
	if err != nil {
		return err
	}
	for _, version := range versions {
		if info.AgentInfo.Version == version {
			return nil
		}
	}
	return fmt.Errorf("桥版本 %q 不在已验证区间 %v，请复验登记后再接入", info.AgentInfo.Version, versions)
}
