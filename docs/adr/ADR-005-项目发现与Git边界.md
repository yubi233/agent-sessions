# ADR-005：项目发现与 Git 只读边界

- 状态：Accepted（本地 Daemon 边界）；经 Relay 的远程 Git/文件请求为 P2 计划
- 日期：2026-08-13

## 背景

Android 需要查看 PC 项目的 Git diff，但不能获得任意文件系统或任意 shell 权限。用户选择的是扫描常用目录，而不是每次在手机输入任意路径。

## 决策

- Daemon 扫描配置的常用目录，发现候选 Git 根目录。
- 用户在 PC 端确认后才登记 Project/Workspace。
- 手机只能请求已登记 Workspace。
- Git 服务使用 `exec.CommandContext` 的参数数组，不拼接 shell。
- 所有路径先做 canonical root、realpath、符号链接和 repo-relative 校验。
- Daemon 本地 Git 服务只读，支持 status、changes、file diff、all diff、分页、压缩、大小限制和 snapshot token。经 Relay 的远程 Git/文件 command contract 尚未实现，必须按 ADR-009 先进入 OpenAPI/JSON Schema。
- 首版不提供 stage、unstage、discard、commit、push 或任意 shell。

## 后果

项目发现体验依赖 PC 端确认流程；跨平台 Git 输出必须使用结构化解析并覆盖特殊文件名、rename、binary、submodule、LFS 和 untracked。P2 实现远程只读链路后，Git diff 只在线实时生成或以密文/受限摘要流转，不在 Relay 缓存明文。
