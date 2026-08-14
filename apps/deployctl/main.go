// Package main 是本地运维/灾备 CLI：backup、restore、integrity、scan。
// 部署与灾备门禁的隔离本地入口；生产备份目标与签名属授权后操作。
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/yubi233/agent-sessions/internal/deploy"
	"github.com/yubi233/agent-sessions/internal/securityscan"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "deployctl:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("用法: deployctl {backup|restore|integrity|scan}")
	}
	cmd := args[0]
	rest := args[1:]

	switch cmd {
	case "backup":
		fs := flag.NewFlagSet("backup", flag.ExitOnError)
		src := fs.String("src", "./data/relay.db", "源 SQLite")
		dst := fs.String("dst", "", "备份目标")
		fs.Parse(rest)
		if *dst == "" {
			return fmt.Errorf("需要 -dst")
		}
		if err := deploy.Backup(*src, *dst); err != nil {
			return err
		}
		fmt.Printf("backup OK: %s\n", *dst)
		return nil

	case "restore":
		fs := flag.NewFlagSet("restore", flag.ExitOnError)
		backup := fs.String("backup", "", "备份文件")
		restoreTo := fs.String("to", "", "恢复目标")
		fs.Parse(rest)
		if *backup == "" || *restoreTo == "" {
			return fmt.Errorf("需要 -backup 与 -to")
		}
		if err := deploy.Backup(*backup, *restoreTo); err != nil {
			return err
		}
		if err := deploy.Integrity(*restoreTo, true); err != nil {
			return err
		}
		fmt.Printf("restore OK: %s（完整性已校验）\n", *restoreTo)
		return nil

	case "integrity":
		fs := flag.NewFlagSet("integrity", flag.ExitOnError)
		path := fs.String("db", "./data/relay.db", "库路径")
		fs.Parse(rest)
		if err := deploy.Integrity(*path, true); err != nil {
			return err
		}
		fmt.Printf("integrity OK: %s\n", *path)
		return nil

	case "scan":
		fs := flag.NewFlagSet("scan", flag.ExitOnError)
		root := fs.String("root", ".", "扫描根目录")
		fs.Parse(rest)
		hits, err := securityscan.ScanPath(*root)
		if err != nil {
			return err
		}
		if len(hits) > 0 {
			for _, h := range hits {
				fmt.Printf("SENSITIVE: %s\n", h)
			}
			return fmt.Errorf("发现 %d 个敏感泄漏", len(hits))
		}
		fmt.Println("scan OK: 未发现明文敏感泄漏")
		return nil

	default:
		return fmt.Errorf("未知命令 %q", cmd)
	}
}
