# ADR-009：Daemon-Relay 命令流与版本协商

- 状态：Accepted，P2 已完成受限本地实现；完整会话/Provider/Android 仍未完成
- 日期：2026-08-16
- 修订（2026-09-06，v0.8.9 P1-P4，迭代计划 §3 契约冻结）：
  1. **Relay DB generation 契约**：`relay_generation`（additive，hello/heartbeat 返回）
     是数据库实例代际——同库重启稳定、删除重建必变、备份随文件走。Daemon 以 hello 为
     启动权威、heartbeat 为运行期发现；变化时在单事务内完成本地收口（未终态命令 →
     `completed/result_status=failed/RELAY_GENERATION_RESET`、事件/usage outbox →
     quarantined、delivery cursor 清零、Terminal 绑定清除）。不新增 wire 终态；该字段
     不进入 event envelope、不替代 lease epoch。旧 Relay 无此字段时进入受控 legacy
     模式（告警一次、legacy 404 一次收口）；回滚开关
     `AGENT_SESSIONS_RELAY_GENERATION_ENFORCEMENT=0` 只关闭强制不回退迁移。
  2. **SSE 调度解耦**：scanner（Stream consume=handleDelivery）只做"解码→落盘→推进
     cursor→received ack→入队"；普通命令与控制命令（approve/reject/abort/question
     answer + rejecting 重放）分队列由独立 worker 消费——审批/中止/问答不再被
     Provider 执行队头阻塞（v0.8.8 实证故障链）。processMu 只保护扫描与去重。
  3. **reset 生命周期边界**：任何重建 Relay DB 的 owner bootstrap 路径必须先停止
     受管与孤儿 Daemon（restart.sh 生命周期锁）；restart-flutter 禁止静默 reset。
     stale 命令 404 按世代证据分类：世代错位 → 本地收口不再重试；世代一致 →
     原样传播；outbox 查询与 requeue 入口按世代过滤（升级期空世代行保持活动）。

## 背景

当前 Relay 只有 REST 与账号级 SSE，PC Daemon 的 `run` 和 `runner` 只覆盖本地行为。Android 已能向 Relay 写入异步命令，但没有经过认证的 Daemon 接收、确认、执行和事件回写闭环。把这一缺口伪装成 WebSocket 或本地 outbox 成功会破坏控制权、重连和可审计性。

## 决策

P2 采用 **REST + 专用 SSE**，不新增 WebSocket：

1. Daemon 以已配对设备身份调用 `daemon.hello`，声明 `protocol_version`、平台、Daemon 版本、已确认 Workspace 的摘要与 capability 摘要；Relay 返回协商版本、心跳周期、终端游标和最小兼容版本。
2. Daemon 通过只面向自身终端的 SSE 命令流接收投递，使用 `Last-Event-ID` 或 `after_delivery_seq` 恢复。现有 `/v1/events` 保持账号级客户端事件流，不能混用为 Daemon 命令流。
3. Daemon 使用 REST 发送 heartbeat、`ack(received|started|rejected)`、终态 result 和 canonical event bundle。Relay 先校验 Android 写权限、目标终端、当前 lease epoch 和幂等键，再让命令进入投递队列。
4. 所有命令有不可变 `command_id`、目标 `terminal_id`、`delivery_seq`、租约 `lease_epoch` 与请求幂等键。Daemon 以 `(terminal_id, command_id, ack_kind)` 幂等确认；事件上传有独立 `event_id` 并按唯一约束去重。传输按至少一次投递设计，执行按命令 ID 去重。
5. Daemon 只执行已确认 Workspace 内、当前 capability 允许的动作。即使 Relay 已接受命令，Daemon 仍必须拒绝失效授权、旧 epoch、路径逃逸、目标不匹配和不支持的 command kind；拒绝只返回白名单错误元数据。**Fence 的范围限于命令 ack/执行——canonical event 上传（`/v1/daemon/events`）只校验命令存在性与终端归属，不做 epoch fence**：回合是会话所有的后台任务，已发生的事实性事件（含 `turn.completed`）必须在任何 lease 变更后仍能送达客户端，否则客户端将永久滞留于 streaming 态（2026-09-05 V085-25 事故回归）。
6. 协议采用 N/N-1 兼容窗口。请求在 hello 与每个写请求中携带版本；Relay 仅接受当前 N 或 N-1。低于最小版本返回稳定的 `UPGRADE_REQUIRED`，高于当前版本返回 `PROTOCOL_UNSUPPORTED`，不得静默降级新 command kind。

**Lease 续期与接管语义（2026-09-05 修订，V085-25）**：同设备重复获取 lease 是幂等续期——epoch 原位保留、不作废任何命令；不同设备获取是接管——epoch 递增并在同一事务内把旧 epoch 仍未终态（accepted/running）的命令收敛为 expired，且只影响之后的命令准入。lease 无 TTL、无释放端点，接管是唯一的控制权转移方式；不提供冲突拒绝路径。

P2 已将以下接口写入 OpenAPI 和 Gin handler：`/v1/daemon/hello`、`/v1/daemon/heartbeat`、`/v1/daemon/commands/stream`、`/v1/daemon/commands/{id}/ack`、`/v1/daemon/commands/{id}/result`、`/v1/daemon/events`。生成物和契约测试仍是字段的唯一事实来源；本文不能替代 schema。

## 数据与重连规则

- Relay 的 SQLite 是命令状态、投递游标、ack、结果与 canonical event 的权威来源；进程内 presence 只能加速展示，重启后可重建。
- 命令投递记录在 ack 前保留；SSE 断开后 Daemon 从最后已确认 `delivery_seq` 恢复。重复 delivery 不得重复启动 Provider 子进程。
- heartbeat 失联只改变在线状态，不能删除命令、租约或历史事件。设备撤销立即阻止新连接和新 ack/result 上传，并让未开始命令进入可审计的拒绝或过期状态。
- 版本升级只允许 additive schema、显式 capability 与 N/N-1 双读；迁移失败时按 SQLite 备份/恢复策略回滚，不能回退已接受命令的 fencing epoch。

## 安全与后果

- 命令流不承载明文工作区文件、diff、Provider 正文、私钥或 token。Relay 只保存密文 envelope 与白名单元数据；日志记录脱敏 ID、状态和错误码。
- Android 继续是唯一远程写控制端；Web/Admin 不获得命令流或 Daemon 写权限。
- 已沉淀 `P0-SCHEMA-02`、`MIG-02`、`CTRL-04`、`SYNC-05`、`RELAY-LEASE-03`、`DAEMON-RPC-01` 与 `GIT-07` 的本地根因回归，以及 `task test:e2e:relay` 的窄纵向 fixture gate。`SESS-05` 已覆盖确定性 `session.start/send/resume/abort`；`session.kill` 已进入 schema、Relay capability gate 和仅限 owned-process Handle 的 Daemon 兑现边界。`DAEMON-PROC-02` 已以本地 helper 覆盖进程组、超时、崩溃、重复 kill 与 fail-closed，但尚未绑定真实 Provider；完整 `E2E-RELAY-02` 仍缺 kill、断线/重启矩阵和生产 key provisioning，必须保持 `partial`。
- WebSocket 的 `WS-01/WS-02` 已被明确排除，不能作为命令流实现证据。
