// P4-D 浏览器验收的受限测试辅助程序：为已通过 HTTP 配对的临时 Terminal 签发本地 bearer。
// 生产流程不会暴露此能力；该程序只读取 e2e runner 创建的临时 SQLite，用于让真实 Daemon
// 进程以配对 Terminal 身份连接隔离 Relay。stdout 只传回给父进程，绝不写入报告或日志。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

func main() {
	databasePath := flag.String("db", "", "临时 Relay SQLite 路径")
	deviceID := flag.String("device", "", "已配对 Terminal device ID")
	inspectCommandID := flag.String("inspect-command", "", "只输出指定临时命令的脱敏投递状态")
	flag.Parse()
	if *databasePath == "" || (*deviceID == "" && *inspectCommandID == "") {
		fmt.Fprintln(os.Stderr, "missing -db and -device or -inspect-command")
		os.Exit(2)
	}
	database, err := store.Open(*databasePath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open temporary relay database")
		os.Exit(1)
	}
	defer database.Close()
	repository := store.NewRepository(database)
	if *inspectCommandID != "" {
		// E2E 失败时只暴露状态机事实，帮助区分 SSE 未消费、ack 失败和 result 未回写。
		// 不输出 command payload、response envelope、会话/工作区 ID 或任何临时文件内容。
		command, err := repository.CommandByID(context.Background(), *inspectCommandID)
		if err != nil {
			fmt.Fprintln(os.Stderr, "lookup web read command")
			os.Exit(1)
		}
		delivery, err := repository.DaemonDeliveryByCommandID(context.Background(), command.ID)
		if err != nil {
			fmt.Fprintln(os.Stderr, "lookup web read delivery")
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(struct {
			CommandStatus string `json:"command_status"`
			AckKind       string `json:"ack_kind"`
			ResultStatus  string `json:"result_status"`
			ErrorCode     string `json:"error_code"`
		}{
			CommandStatus: command.Status,
			AckKind:       delivery.AckKind,
			ResultStatus:  delivery.ResultStatus,
			ErrorCode:     delivery.ErrorCode,
		})
		return
	}
	device, err := repository.DeviceByID(context.Background(), *deviceID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "lookup paired terminal")
		os.Exit(1)
	}
	tokens, err := domain.NewAuthService(repository).IssueForDevice(context.Background(), device.AccountID, device.ID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "issue paired terminal token")
		os.Exit(1)
	}
	fmt.Print(tokens.AccessToken)
}
