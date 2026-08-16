# ADR-005：项目发现与 Git 只读边界

- 状态：Accepted（本地 Daemon 边界）；P2 已实现受限 Relay command dispatcher，仍未完成生产 E2EE 与客户端旅程
- 日期：2026-08-13

## 背景

Android 需要查看 PC 项目的 Git diff，但不能获得任意文件系统或任意 shell 权限。用户选择的是扫描常用目录，而不是每次在手机输入任意路径。

## 决策

- Daemon 扫描配置的常用目录，发现候选 Git 根目录。
- 用户在 PC 端确认后才登记 Project/Workspace。
- 手机只能请求已登记 Workspace。
- Git 服务使用 `exec.CommandContext` 的参数数组，不拼接 shell。
- 所有路径先做 canonical root、realpath、符号链接和 repo-relative 校验。
- Daemon 本地 Git 服务只读，支持 status、changes、file diff、all diff、分页、压缩、大小限制和 snapshot token。P2 已通过 ADR-009 的 opaque command 把 `file.tree`、`file.read`、`code.read`、`git.status`、`git.changes`、`git.diff` 接入已确认 Workspace dispatcher；生产 event encoder 缺失时必须 fail-closed，不能把文本或 diff 上传到 Relay。
- 首版不提供 stage、unstage、discard、commit、push 或任意 shell。

## 后果

项目发现体验依赖 PC 端确认流程；跨平台 Git 输出必须使用结构化解析并覆盖特殊文件名、rename、binary、submodule、LFS 和 untracked。P2 的 fixture 已验证真实临时 Git 根、路径逃逸和 `file.read` 的 opaque event 边界；在生产 encoder、全部命令负例和 Android/Web 可见消费者完成前，不能称为完整远程只读链路。Git diff 只在线实时生成或以密文/受限摘要流转，不在 Relay 缓存明文。
