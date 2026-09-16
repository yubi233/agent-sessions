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
// 用法（在能访问 Relay SQLite 的机器上执行）：
//   go run ./e2e-verify/helpers/reissue_terminal_token.go \
//     -db /path/to/relay.db -device dev_xxx [--role terminal]
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

func main() {
	databasePath := flag.String("db", "", "Relay SQLite 路径")
	deviceID := flag.String("device", "", "既有 Terminal device ID")
	role := flag.String("role", string(domain.RoleTerminal), "签发角色（缺省 terminal）")
	attach := flag.Bool("audit", true, "是否写入审计事件（device.reissued）")
	flag.Parse()
	if *databasePath == "" || *deviceID == "" {
		fmt.Fprintln(os.Stderr, "missing -db and -device")
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

	// 前置校验：先证明"这是一台既有且可用的设备"，再签发。
	device, err := repo.DeviceByID(ctx, *deviceID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "device not found; refusing to create one")
		os.Exit(1)
	}
	if string(device.Role) != *role {
		fmt.Fprintf(os.Stderr, "device role mismatch: have %q want %q\n", device.Role, *role)
		os.Exit(1)
	}
	if device.Status != domain.DeviceActive {
		fmt.Fprintf(os.Stderr, "device is not active (status=%q); refusing\n", device.Status)
		os.Exit(1)
	}

	access := authz.RandomToken()
	ttl := authz.AccessTTLOf(*role)
	expiresAt := time.Now().Add(ttl)
	if err := repo.PutAccessToken(ctx, store.AccessTokenRow{
		Token: access, AccountID: device.AccountID, DeviceID: device.ID,
		Role: *role, ExpiresAt: expiresAt,
	}); err != nil {
		fmt.Fprintln(os.Stderr, "persist access token failed")
		os.Exit(1)
	}
	if *attach {
		// 审计只记事实，不记令牌值（account_id 由仓库层落库）。
		_ = repo.AppendAudit(ctx, device.AccountID, "device.reissued",
			fmt.Sprintf(`{"device_id":%q,"role":%q,"expires_at_unix_ms":%d}`, device.ID, *role, expiresAt.UnixMilli()))
	}

	// stdout 只有令牌本身，便于调用方直接重定向到 600 权限文件；
	// 元信息走 stderr，避免混入令牌文件。
	fmt.Fprintln(os.Stderr, "reissued terminal token for device", device.ID,
		"role", *role, "expires_in_s", int64(ttl.Seconds()))
	fmt.Println(access)
}
