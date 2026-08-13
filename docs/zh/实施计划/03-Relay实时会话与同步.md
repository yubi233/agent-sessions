# Relay 实时会话与同步实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `RELAY-REALTIME` |
| owner | Relay Server / Realtime |
| status | `planned` |
| next_work_package | W1 REST 与 scope |
| blocked_by | `RELAY-IDENTITY` 认证中间件与迁移未交付 |
| target | M2 / P1 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-001、ADR-003、ADR-006 |

## 1. 目标与明确排除项

交付基于 Gin、SSE 和 `coder/websocket` 的密文事件/命令转发：Terminal 注册、Session/Instance 状态、单调 `event_seq`、cursor 恢复、异步命令、ControlLease/fencing 与 transactional outbox。

Relay 不执行 Provider、不读取 Workspace、不解析 Git；Git 请求只能作为端到端加密 RPC 转给认证 Daemon。身份、配对和迁移基础由 `RELAY-IDENTITY` 提供。

## 2. 进入条件、输入和依赖

- 输入：`RELAY-IDENTITY` 的认证中间件、设备角色、数据库迁移和 Redis presence。
- 输入：`PROTO-CRYPTO` 的 event/command envelope、错误码、能力字段、cursor 规则。
- 输入：Mock Terminal testkit；真实 Daemon 和 Provider 不作为本计划进入条件。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 REST 与 scope | 身份中间件、OpenAPI | snapshot、命令 accepted、附件元数据、加密 Git proxy；服务端从认证上下文推导 scope | Gin routes/application services、错误映射 | `HTTP-01..03` | 集成 | `reports/<ts>/RELAY-REALTIME/http.json` | endpoint version flag；拒绝未知 payload/version |
| W2 SSE/WS | W1、envelope | hello/challenge、heartbeat、ack、Last-Event-ID、backpressure、slow client close、reconnect | controller/terminal transport、cursor store | `SSE-01..02`、`WS-01..02`、`TERM-01..02` | 集成 | WS/SSE trace（脱敏） | 停止在线 fanout 后从 DB history 恢复 |
| W3 会话与命令 | W2、session schema | Session/Instance/ProviderThread 状态机，accepted 后 `command.updated`，幂等键、event_seq 事务递增 | session/command use cases、mock terminal vertical slice | `SESS-01..04`、`SYNC-01` | 集成 | command/event report | 不重置 seq；重复键返回原 canonical result |
| W4 lease、fencing、outbox | W3 | PostgreSQL 权威 lease/epoch、事务校验、`FOR UPDATE SKIP LOCKED` outbox、重试/死信/重放 | lease store、outbox worker、metrics | `CTRL-01..03`、`SYNC-02`、`RELAY-LEASE-01..02` | 集成 | 重启/竞争报告 | 暂停 worker 后重放；Redis hint 可丢，PG epoch 不可回退 |
| W5 密文/可观测性 gate | W1-W4 | 字段白名单、日志 scrub、附件/Git proxy 大小上限、限流 | redaction policy、security query | `SEC-01` | 安全 + 集成 | DB/log scan report | 关闭高风险 endpoint，不记录 payload |

## 4. 数据、权限、错误和事件边界

- PostgreSQL 中 `(session_id,event_seq)`、`(scope_hash,idempotency_key)` 和 `control_leases` 是权威约束；Redis 只作 presence、广播与短 lease hint。
- 只有 Android controller 且携带当前 lease epoch 可以提交会话写命令。Web/Admin 即使构造相同请求也必须在服务端得到只读错误。
- Git REST 路由是密文 RPC proxy：Daemon 完成 canonical path、realpath、Git 执行与 snapshot token；Relay 不缓存明文 diff。
- 未知协议版本、旧 instance、旧 epoch、过期 deadline、越界 scope 都必须被拒绝并产生脱敏审计。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

先验证 `login -> mock terminal register -> session start -> encrypted event -> Android-equivalent abort -> cursor reconnect`。使用 `task test:relay`、`task test:integration`；Web headed、Android、真实 Provider 等后续项目 gate 独立记录。

## 6. 退出条件、阻塞和残余风险

退出：多 Terminal 可并存，事件严格递增并可从 cursor 恢复，重复命令不重复执行，旧 epoch 被 fencing，PostgreSQL/Redis/Relay 重启后 outbox 和历史恢复，Web/Admin 写命令服务端拒绝。

阻塞：schema 不稳定、lease 权威不在 PostgreSQL、数据库/日志出现正文，或任一路径要求 Relay 执行 Git/Provider。残余风险是客户端解密和真实上游尚未验证。

## 7. 文档回填清单

回填路由、WebSocket/SSE 帧、命令状态机、lease SQL、outbox 运维指标和测试注册表。
