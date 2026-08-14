# P2 Daemon 核心、Git 只读与 Adapter 平台

> 状态：`done`  
> 开始日期：2026-08-14  
> 完成日期：2026-08-14  
> 对应计划：[Daemon 核心与 Workspace 安全](../实施计划/04-Daemon核心与Workspace安全.md)、[Daemon Git 只读服务](../实施计划/05-Daemon-Git只读服务.md)、[Adapter 平台与 Mock 运行时](../实施计划/06-Adapter平台与Mock运行时.md)

## 实施总结（2026-08-14）

本阶段用可移植的纯 Go 实现 Daemon 核心纵向基础，规避平台锁定的 service/keyring 依赖，保证本地与 CI 可验证：

- **Adapter SPI（`internal/adapter`）**：统一 `Detect/Capabilities/Start/Resume` 接口、能力三态（native/emulated/unsupported）、canonical 事件类型与六种唤醒结果；`mock` runtime 生成完整会话控制事件，支持注入唤醒结果。
- **Workspace 安全（`internal/workspacesafe`）**：canonical root、realpath、符号链接逃逸、`..` 越界、控制字符、repo-relative 路径解析；候选 Git 根扫描。
- **Git 只读 RPC（`internal/gitread`）**：`git status --porcelain=v2 -z` 结构化解析、文件/全量 diff、snapshot token 漂移检测、输出字节上限保护；全部参数数组执行不经过 shell。
- **Daemon 本地状态与监督（`internal/daemon`）**：SQLite 本地状态、离线命令 outbox（request_id 幂等）、supervisor 重连重放；`apps/daemon` CLI（status/doctor/run/doctor-path）。

## 已交付证据

- `task test:daemon`、`task test:contract` 通过；全部 Go 包回归通过。
- Git 只读回归使用临时仓库覆盖 status/diff/非仓库/snapshot 漂移/超大输出。
- 路径安全回归覆盖 `..`、符号链接逃逸、控制字符与根内合法路径。

## 覆盖的测试 ID

`DAEMON-BOOT-01`（本地状态）、`SYNC-03`（离线 outbox 幂等与重放）、`WORKSPACE-01`（路径不可逃逸）、`DAEMON-PROC-01`（参数数组执行）、`GIT-01/02/03/05/06`、`ADPT-01`、`MODE-04`（Resume 六种唤醒）。

## 残余风险与未做

- 真实 Provider（Claude/Codex/OpenCode/OpenClaw）协议、Terminal WebSocket 完整 hello/challenge、平台 service 安装与系统 Keychain 未在本阶段落地；按计划归 P3/P4 与平台/发布 gate，标记 `incomplete`/`blocked`。
- Git rename/binary/submodule/LFS 细分与 snapshot 分页校验为部分覆盖，跨 Git 版本差异进入发布版本矩阵。