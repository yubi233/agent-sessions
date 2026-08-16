# ADR-009：Daemon-Relay 命令流与版本协商

- 状态：Accepted，P2 已完成受限本地实现；完整会话/Provider/Android 仍未完成
- 日期：2026-08-16

## 背景

当前 Relay 只有 REST 与账号级 SSE，PC Daemon 的 `run` 和 `runner` 只覆盖本地行为。Android 已能向 Relay 写入异步命令，但没有经过认证的 Daemon 接收、确认、执行和事件回写闭环。把这一缺口伪装成 WebSocket 或本地 outbox 成功会破坏控制权、重连和可审计性。

## 决策

P2 采用 **REST + 专用 SSE**，不新增 WebSocket：

1. Daemon 以已配对设备身份调用 `daemon.hello`，声明 `protocol_version`、平台、Daemon 版本、已确认 Workspace 的摘要与 capability 摘要；Relay 返回协商版本、心跳周期、终端游标和最小兼容版本。
2. Daemon 通过只面向自身终端的 SSE 命令流接收投递，使用 `Last-Event-ID` 或 `after_delivery_seq` 恢复。现有 `/v1/events` 保持账号级客户端事件流，不能混用为 Daemon 命令流。
3. Daemon 使用 REST 发送 heartbeat、`ack(received|started|rejected)`、终态 result 和 canonical event bundle。Relay 先校验 Android 写权限、目标终端、当前 lease epoch 和幂等键，再让命令进入投递队列。
4. 所有命令有不可变 `command_id`、目标 `terminal_id`、`delivery_seq`、租约 `lease_epoch` 与请求幂等键。Daemon 以 `(terminal_id, command_id, ack_kind)` 幂等确认；事件上传有独立 `event_id` 并按唯一约束去重。传输按至少一次投递设计，执行按命令 ID 去重。
5. Daemon 只执行已确认 Workspace 内、当前 capability 允许的动作。即使 Relay 已接受命令，Daemon 仍必须拒绝失效授权、旧 epoch、路径逃逸、目标不匹配和不支持的 command kind；拒绝只返回白名单错误元数据。
6. 协议采用 N/N-1 兼容窗口。请求在 hello 与每个写请求中携带版本；Relay 仅接受当前 N 或 N-1。低于最小版本返回稳定的 `UPGRADE_REQUIRED`，高于当前版本返回 `PROTOCOL_UNSUPPORTED`，不得静默降级新 command kind。

P2 已将以下接口写入 OpenAPI 和 Gin handler：`/v1/daemon/hello`、`/v1/daemon/heartbeat`、`/v1/daemon/commands/stream`、`/v1/daemon/commands/{id}/ack`、`/v1/daemon/commands/{id}/result`、`/v1/daemon/events`。生成物和契约测试仍是字段的唯一事实来源；本文不能替代 schema。

## 数据与重连规则

- Relay 的 SQLite 是命令状态、投递游标、ack、结果与 canonical event 的权威来源；进程内 presence 只能加速展示，重启后可重建。
- 命令投递记录在 ack 前保留；SSE 断开后 Daemon 从最后已确认 `delivery_seq` 恢复。重复 delivery 不得重复启动 Provider 子进程。
- heartbeat 失联只改变在线状态，不能删除命令、租约或历史事件。设备撤销立即阻止新连接和新 ack/result 上传，并让未开始命令进入可审计的拒绝或过期状态。
- 版本升级只允许 additive schema、显式 capability 与 N/N-1 双读；迁移失败时按 SQLite 备份/恢复策略回滚，不能回退已接受命令的 fencing epoch。

## 安全与后果

- 命令流不承载明文工作区文件、diff、Provider 正文、私钥或 token。Relay 只保存密文 envelope 与白名单元数据；日志记录脱敏 ID、状态和错误码。
- Android 继续是唯一远程写控制端；Web/Admin 不获得命令流或 Daemon 写权限。
- 已沉淀 `P0-SCHEMA-02`、`MIG-02`、`CTRL-04`、`SYNC-05`、`RELAY-LEASE-03`、`DAEMON-RPC-01` 与 `GIT-07` 的本地根因回归，以及 `task test:e2e:relay` 的窄纵向 fixture gate。`SESS-05` 仅覆盖确定性 `session.start`，`DAEMON-PROC-02` 和完整 `E2E-RELAY-02` 仍未满足，必须保持 `partial/planned`。
- WebSocket 的 `WS-01/WS-02` 已被明确排除，不能作为命令流实现证据。
