# Daemon 核心与 Workspace 安全实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `DAEMON-CORE` |
| owner | PC Daemon |
| status | `planned` |
| next_work_package | W1 CLI/服务骨架 |
| blocked_by | 根 `go.mod` 与 Terminal hello 协议未落地 |
| target | M3 / P2 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-003、ADR-004、ADR-005、ADR-006 |

## 1. 目标与明确排除项

交付 macOS、Windows、Linux 的 Go Daemon 基础：CLI/服务安装、SQLite、系统 Keychain、Terminal WebSocket、重连与本地命令 outbox、用户确认的项目登记以及 Workspace 安全边界。

不实现 Git 查询细节（归 `DAEMON-GIT`），不实现真实 Provider 协议（归 Adapter 计划），不开放任意远程 shell 或可未经本机确认的目录。

## 2. 进入条件、输入和依赖

- 输入：协议、Terminal hello/challenge、设备凭据格式和 Relay 实时接口。
- 依赖：Go 单 module、Cobra、modernc SQLite、go-keyring、kardianos/service、backoff、平台 CI runners。
- 本机用户必须显式确认每个 project root；扫描仅发现候选路径，不能自动授权。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 CLI/服务骨架 | Go module、配置契约 | `login/pair/status/project/session/doctor/service`；安装、停止、卸载和版本输出 | `apps/daemon` 二进制、service adapters | `DAEMON-BOOT-01` | 单元 + 平台 smoke | 平台安装日志 | 保留 CLI foreground 模式；卸载前停进程树 |
| W2 本地身份与状态 | W1、crypto 格式 | Keychain 保存凭据；SQLite 存 encrypted local state、cursor、command outbox；迁移备份 | local store/keyring adapter | `DAEMON-BOOT-01`、`SYNC-03` | 单元 + 集成 | SQLite migration report | 旧 schema 双读；迁移前备份 |
| W3 Terminal 连通与监督 | Relay WS、W2 | heartbeat、指数退避、ack、deadline、幂等 outbox、进程树/取消/退出码分类 | terminal client、supervisor、doctor diagnostics | `TERM-02`、`SYNC-03` | 集成 | reconnect trace | offline queue 有上限；无法恢复时转 explicit failed |
| W4 项目登记与路径安全 | W2 | 常用目录候选扫描、确认、canonical path/realpath、symlink、跨盘、repo root 与 workspace boundary 校验 | workspace registry、safe path API | `WORKSPACE-01` | 单元 + fuzz + 集成 | fuzz seed/cleanup report | 关闭有风险 workspace；不尝试猜测替代路径 |

## 4. 数据、权限、错误和事件边界

- SQLite 和 Keychain 只保存本机最小状态；会话正文、diff 只以密文存储，解密态不落盘。
- Daemon 验证 Relay 指令的 terminal/workspace/session scope、deadline、lease epoch 和 payload version；不能信任本地 UI 或远端字符串路径。
- 外部进程一律 `exec.CommandContext` 参数数组调用，拒绝 shell 拼接；禁止把 Provider/stdout 原文写入未脱敏日志。
- Workspace 状态为 pending/confirmed/moved/revoked，`workspace_moved` 必须要求本机重新确认。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

先跑 fake Relay + fake service manager 的本地单元/集成；随后三平台最小安装/启动/停止 smoke。真实 Provider、真实模型、生产 Keychain 访问均不是默认 gate，缺失平台 runner 时保留 `blocked`。

## 6. 退出条件、阻塞和残余风险

退出：三平台可安装、停止、卸载；本地状态迁移可恢复；断线重连不重复远端命令；`..`、symlink、非仓库、特殊路径和跨盘边界全部拒绝；mock session 可被 Relay 控制。

阻塞：无法验证实际 realpath 语义、进程树不可清理、需要任意 shell 才能运行 Adapter，或用户确认流程无法区分 moved/revoked。残余风险：平台签名与真实 Agent 属发布/Provider gate。

## 7. 文档回填清单

回填安装方式、SQLite schema、Keychain 兼容性、Workspace 状态机、错误码、平台差异和测试 fixtures。
