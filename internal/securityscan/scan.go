// Package securityscan 提供明文泄漏与敏感字段扫描门禁（P5.0）。
// 扫描日志、响应与文件，确保不含明文密钥、token、恢复码或会话正文探针。
package securityscan

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
)

// 敏感标记。命中即认为存在明文泄漏风险。
// 使用更精确的模式避免误报表名/列名（如 recovery_codes 表名）。
var sensitiveMarkers = []string{
	"Bearer ", "\"password\":", "\"refresh_token\":", "\"recovery_code\":",
	"-----BEGIN PRIVATE KEY-----", "BEGIN RSA PRIVATE KEY", "\"api_key\":", "\"secret\":",
	"client_secret=", "access_key=",
}

// sensitiveFiles 是需要扫描的后缀。
var sensitiveExts = map[string]bool{
	".go": true, ".ts": true, ".dart": true, ".mjs": true, ".json": true, ".yaml": true, ".md": true,
}

// 已审阅的允许路径：其命中是合法的协议契约字段或鉴权边界，不是明文泄漏。
// 任何新增命中都必须在此显式登记并说明理由。
var allowlisted = map[string]string{
	"internal/httpapi/api.go":       "RequireAuth 解析 Bearer 头是鉴权边界，不输出 token",
	"internal/httpapi/handlers.go":  "refresh_token 为服务端已哈希的 opaque 令牌 DTO 字段（api contract）",
	"internal/securityscan/scan.go": "扫描器自身的标记定义，非泄漏",
}

// ScanPath 递归扫描目录，返回包含敏感标记的文件路径（已排除 allowlist 与测试夹具）。
func ScanPath(root string) ([]string, error) {
	hits := []string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			// 跳过依赖与构建产物，避免误报。
			name := info.Name()
			if name == "node_modules" || name == ".git" || name == "dist" || name == "build" || name == "coverage" || name == ".dart_tool" {
				return filepath.SkipDir
			}
			return nil
		}
		ext := filepath.Ext(path)
		if !sensitiveExts[ext] {
			return nil
		}
		// 跳过测试夹具与 allowlist 已审阅路径。
		if strings.HasSuffix(path, "_test.go") {
			return nil
		}
		if _, ok := allowlisted[path]; ok {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		if containsMarker(data) {
			hits = append(hits, path)
		}
		return nil
	})
	return hits, err
}

func containsMarker(data []byte) bool {
	for _, m := range sensitiveMarkers {
		if bytes.Contains(data, []byte(m)) {
			return true
		}
	}
	return false
}

// ContainsSensitive 判断字符串是否含敏感片段。
func ContainsSensitive(s string) bool {
	for _, m := range sensitiveMarkers {
		if strings.Contains(s, m) {
			return true
		}
	}
	return false
}
