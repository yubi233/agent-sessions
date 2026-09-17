// 受限运维工具：为**既有** Terminal 设备重发 bearer 令牌（v0.9.2 T6-B 执行路径）。
//
// 背景与边界（为什么必须重发而不是重新配对）：
// 云端验收环境的 Terminal 访问令牌已过期，且没有留存 refresh 令牌，导致 Daemon
// 无法上线（hello 401）、该 Terminal 的 DSH 工作区无法被路由。
// 走正常配对流程会**新建**一个 device（ApprovePairing 恒用 id.New("dev")），
// device_id 一变，工作区就会另建并遗留孤儿绑定（违反计划 §7 T4/T6 的
// 「不新建设备、不改工作区 terminal 绑定、不重置数据库」约束）。
// 因此本工具只做一件事：在**已配对且仍为 active** 的设备上追加一条新的 access
// token 行——不建设备、不改绑定、不改任何既有数据、不触碰 refresh family。
//
// 安全边界：
//   - 只读校验：设备必须存在、角色必须是 terminal、状态必须是 active，任一不满足
//     立即拒绝（fail-closed），绝不"顺手创建"；
//   - 只追加一行 access_tokens（与生产签发路径 store.PutAccessToken 同形状）；
//   - 令牌只打印到 stdout，由调用方写入本地 600 权限运行文件；不落日志、不进仓库、
//     不进报告；审计记录只写 device_id 与到期时间，绝不含令牌值；
//   - 该工具**不属于生产链路**，只允许在受控运维窗口内对本机/受控数据库执行。
//
// -ttl（2026-09-17 云端验收窗口新增）：
// authz.AccessTTLOf(terminal) 是 24h。云端验收环境不具备随时重签的条件（验收期间
// 宿主机 SSH 窗口可能关闭，而 Daemon 在 401 上按不可恢复错误退出，见
// internal/daemon/relay.go 的 RelayLoop.RunWithRetry 分支），一旦令牌过期就再也
// 无法自行恢复。因此本工具允许运维窗口显式指定更长的 TTL（例如 720h），
// **只影响本次签发的那一行**，不改动 authz 的生产常量、不影响任何其他设备。
// 留空时行为与旧版完全一致（按角色默认 TTL）。
// 文档回链：docs/zh/实施记录/32-v0.9.2-能力事实源与受控重探测.md（T6-B 云端验收）。
//
// 用法（在能访问 Relay SQLite 的机器上执行）：
//
//	go run ./e2e-verify/helpers/reissue-terminal-token -db /path/to/relay.db \
//	  -device dev_xxx [--role terminal] [--ttl 720h]
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

// reissueResult 描述一次重发的结果。Token 只经 stdout 交付给调用方，
// 调用方负责写入 600 权限文件；本结构不参与任何日志输出。
type reissueResult struct {
	Token     string
	DeviceID  string
	Role      string
	ExpiresAt time.Time
	TTL       time.Duration
}

// issueTerminalToken 是重发的可测核心：先 fail-closed 证明「这是一台既有且可用的
// 设备」，再追加一行 access_tokens，最后按需写审计。ttlOverride <= 0 表示按角色默认
// TTL（见 authz.AccessTTLOf）。
func issueTerminalToken(
	ctx context.Context,
	repo store.Repository,
	deviceID, role string,
	ttlOverride time.Duration,
	audit bool,
	now func() time.Time,
) (reissueResult, error) {
	device, err := repo.DeviceByID(ctx, deviceID)
	if err != nil {
		return reissueResult{}, fmt.Errorf("device not found; refusing to create one: %w", err)
	}
	if string(device.Role) != role {
		return reissueResult{}, fmt.Errorf("device role mismatch: have %q want %q", device.Role, role)
	}
	if device.Status != domain.DeviceActive {
		return reissueResult{}, fmt.Errorf("device is not active (status=%q); refusing", device.Status)
	}

	ttl := authz.AccessTTLOf(role)
	if ttlOverride > 0 {
		ttl = ttlOverride
	}
	access := authz.RandomToken()
	expiresAt := now().Add(ttl)
	if err := repo.PutAccessToken(ctx, store.AccessTokenRow{
		Token: access, AccountID: device.AccountID, DeviceID: device.ID,
		Role: role, ExpiresAt: expiresAt,
	}); err != nil {
		return reissueResult{}, fmt.Errorf("persist access token: %w", err)
	}
	if audit {
		// 审计只记事实，不记令牌值（account_id 由仓库层落库）；ttl_seconds 让运维窗口
		// 事后可核这次签发为何不是默认 24h。
		_ = repo.AppendAudit(ctx, device.AccountID, "device.reissued",
			fmt.Sprintf(`{"device_id":%q,"role":%q,"expires_at_unix_ms":%d,"ttl_seconds":%d}`,
				device.ID, role, expiresAt.UnixMilli(), int64(ttl.Seconds())))
	}
	return reissueResult{Token: access, DeviceID: device.ID, Role: role, ExpiresAt: expiresAt, TTL: ttl}, nil
}

// parseTTLOverride 解析可选的 -ttl：留空表示按角色默认；非法或非正数一律拒绝，
// 避免"写错一个字就签发出一枚寿命不明的令牌"。
func parseTTLOverride(raw string) (time.Duration, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return 0, nil
	}
	parsed, err := time.ParseDuration(trimmed)
	if err != nil {
		return 0, fmt.Errorf("invalid -ttl %q: 需要 Go duration（例如 720h）", raw)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("invalid -ttl %q: 必须为正数", raw)
	}
	return parsed, nil
}

func main() {
	databasePath := flag.String("db", "", "Relay SQLite 路径")
	deviceID := flag.String("device", "", "既有 Terminal device ID")
	role := flag.String("role", string(domain.RoleTerminal), "签发角色（缺省 terminal）")
	ttlRaw := flag.String("ttl", "", "可选：覆盖访问令牌寿命（Go duration，例如 720h）；留空按角色默认 TTL")
	attach := flag.Bool("audit", true, "是否写入审计事件（device.reissued）")
	flag.Parse()
	if *databasePath == "" || *deviceID == "" {
		fmt.Fprintln(os.Stderr, "missing -db and -device")
		os.Exit(2)
	}
	ttlOverride, err := parseTTLOverride(*ttlRaw)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	database, err := store.Open(*databasePath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open relay database failed")
		os.Exit(1)
	}
	defer database.Close()
	repo := store.NewRepository(database)
	ctx := context.Background()

	result, err := issueTerminalToken(ctx, repo, *deviceID, *role, ttlOverride, *attach, time.Now)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// stdout 只有令牌本身，便于调用方直接重定向到 600 权限文件；
	// 元信息走 stderr，避免混入令牌文件。
	fmt.Fprintln(os.Stderr, "reissued terminal token for device", result.DeviceID,
		"role", result.Role,
		"ttl_s", int64(result.TTL.Seconds()),
		"expires_at", result.ExpiresAt.UTC().Format(time.RFC3339))
	fmt.Println(result.Token)
}
