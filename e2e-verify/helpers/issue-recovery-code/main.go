// 受限运维工具：为**既有**账号补发一枚恢复码（v0.9.2 云端验收 T6-B-2 执行路径）。
//
// 背景与边界（为什么需要它）：
// 云端验收账号是 bootstrap 产生的一次性内部账号
// （acct_…@local.agent-sessions.invalid），既无可用密码也无恢复码，于是手机端
// 无法自服务取得该账号的 owner 身份：app 的令牌存储是单键 auth_tokens、不按 relay
// 区分（apps/mobile/lib/storage/secure_token_store.dart），9/17 的本地 bootstrap
// 已覆盖云端令牌；而 owner 的加密私钥只存在于手机当时的存储里，重置即不可恢复。
// 协议设计内唯一可用的路径是「恢复码」：消费恢复码会在同一个事务里撤销旧 Android
// owner、创建新的 owner 设备并签发新令牌（internal/httpapi/handlers.go 的
// /v1/recovery-codes/restore）。
//
// 本工具只做该路径的**准备**——写入一行 recovery_codes，不消费、不撤销、不建设备。
// 真正撤销旧 owner 的动作发生在手机端提交恢复码时，属于用户可见的显式操作。
//
// 安全边界：
//   - fail-closed：账号必须已存在（按 -account 或 -email 精确解析），绝不创建账号；
//   - 只写一行 recovery_codes，且经**生产同源的领域路径**
//     （domain.PairingService.GenerateRecoveryCode）落库，附带
//     recovery_code.generated 审计——不手写 SQL，避免形状漂移；
//   - 明文恢复码只打印到 stdout，由调用方写入本地 600 权限文件；不落日志、不进仓库、
//     不进报告；
//   - 该工具**不属于生产链路**，只允许在受控运维窗口内对受控数据库执行。
//
// 文档回链：docs/zh/实施记录/32-v0.9.2-能力事实源与受控重探测.md（T6-B 云端验收）。
//
// 用法（在能访问 Relay SQLite 的机器上执行）：
//
//	go run ./e2e-verify/helpers/issue-recovery-code -db /path/to/relay.db -account acct_xxx
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

// issueRecoveryCode 是补发恢复码的可测核心：fail-closed 解析既有账号 → 走生产同源
// 领域路径写入一行 recovery_codes（含审计）→ 返回明文码（调用方负责只交付一次）。
func issueRecoveryCode(
	ctx context.Context,
	repo store.Repository,
	accountRef string,
	byEmail bool,
) (accountID string, code string, err error) {
	ref := strings.TrimSpace(accountRef)
	if ref == "" {
		return "", "", fmt.Errorf("empty account reference")
	}
	var account store.AccountRow
	if byEmail {
		account, err = repo.AccountByEmail(ctx, ref)
	} else {
		account, err = repo.AccountByID(ctx, ref)
	}
	if err != nil {
		return "", "", fmt.Errorf("account not found; refusing to create one: %w", err)
	}

	// 生产同源：GenerateRecoveryCode 内部做 UpsertRecoveryCode（authz.HashToken）
	// 并写 recovery_code.generated 审计。
	code, err = domain.NewPairingService(repo).GenerateRecoveryCode(ctx, account.ID)
	if err != nil {
		return "", "", fmt.Errorf("persist recovery code: %w", err)
	}
	return account.ID, code, nil
}

func main() {
	databasePath := flag.String("db", "", "Relay SQLite 路径")
	accountID := flag.String("account", "", "既有账号 ID（与 -email 二选一）")
	email := flag.String("email", "", "既有账号邮箱（与 -account 二选一）")
	flag.Parse()

	if *databasePath == "" || (*accountID == "" && *email == "") {
		fmt.Fprintln(os.Stderr, "missing -db and one of -account/-email")
		os.Exit(2)
	}
	if *accountID != "" && *email != "" {
		fmt.Fprintln(os.Stderr, "-account 与 -email 只能给一个，避免解析到不同账号")
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

	byEmail := *email != ""
	ref := *accountID
	if byEmail {
		ref = *email
	}
	resolvedAccountID, code, err := issueRecoveryCode(ctx, repo, ref, byEmail)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// stdout 只有恢复码本身，便于调用方直接重定向到 600 权限文件；
	// 元信息走 stderr，避免混入恢复码文件。
	fmt.Fprintln(os.Stderr, "issued recovery code for account", resolvedAccountID, "delivery caller_once")
	fmt.Println(code)
}
