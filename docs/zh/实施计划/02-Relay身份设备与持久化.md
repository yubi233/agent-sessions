# Relay 身份、设备与持久化实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `RELAY-IDENTITY` |
| owner | Relay Server / Identity |
| status | `planned` |
| next_work_package | W1 账户与 token |
| blocked_by | `PROTO-CRYPTO` 未冻结；无 Compose/Goose/sqlc |
| target | M2 / P1 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-001、ADR-002、ADR-003、ADR-006 |

## 1. 目标与明确排除项

交付 Gin 中继的账号、设备、配对、恢复、SQLite 权威元数据与进程内可重建短状态。服务器只处理身份公钥、密钥包装、密文索引和白名单运维元数据，绝不解密会话、文件、diff 或工具参数。

不包含 SSE/WS 事件路由、Session 命令、lease/outbox worker，它们由 `RELAY-REALTIME` 负责；不允许 Admin 或 Web 执行会话写命令。

## 2. 进入条件、输入和依赖

- 输入：P0 的 OpenAPI/JSON Schema、错误码、envelope、设备密钥格式和 crypto vectors 已冻结。
- 依赖：本地 Compose、Go module、Gin、`modernc.org/sqlite`、编号 SQL 迁移与脱敏日志基线。
- 授权：首个 Android 为 owner/key-admin；所有后续设备经 owner Android 批准。Admin 仅查看运维元数据，不批准/撤销设备，不生成恢复码。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 账户与 token | 协议错误码 | Argon2id、opaque access token、轮换 refresh token、logout/reuse 检测；Gin handler 只绑定和映射错误 | `auth` application service、OpenAPI 路由、token 表和审计字段 | `AUTH-01` | 集成 | `reports/<ts>/RELAY-IDENTITY/auth.json` | 兼容旧 token 校验窗口；发现 refresh reuse 时撤销 family |
| W2 配对与设备授权 | W1、设备 key 格式 | Android bootstrap owner、二维码/短码、待批准/取消/过期、X25519 key wrap、撤销与恢复码 | `devices`、`pairing_requests`、`device_key_wraps`、配对 API | `PAIR-01..04`、`SEC-03` | 集成 + crypto | `reports/<ts>/RELAY-IDENTITY/pairing.json` | 停止新 wrap、关闭撤销设备连接；保留历史密文 |
| W3 SQLite 权威模型 | W1/W2 数据模型 | 编号 SQL 迁移、唯一键和外键；创建 accounts/devices/terminals/projects/workspaces/sessions 基础表 | 迁移、查询、schema version、迁移 runbook | `RELAY-DB-01..03`、`MIG-01` | 集成 | 迁移报告和 test DB dump 摘要 | 仅 additive migration；旧列双读，禁止未演练 destructive down |
| W4 presence 与审计 | W3 | presence、限流、配对短状态、广播指针（进程内 TTL map，可由 DB/连接重建） | TTL 清单、限流中间件、脱敏审计 | `RELAY-REDIS-01` | 集成 | presence 重建报告、敏感日志扫描 | presence 可丢；不把业务真相写入内存短状态 |

## 4. 数据、权限、错误和事件边界

- SQLite 是账号、设备、撤销、项目索引和所有关系的权威；presence、限流与配对短状态为进程内可重建状态，不依赖 Redis。
- 设备角色必须区分 Android owner、Android controller、Terminal、Web readonly、Admin readonly；会话写权限只授予当前 Android controller，设备管理只授予 owner Android。
- 服务器返回 `DEVICE_REVOKED`、`PAIRING_EXPIRED`、`OWNER_REQUIRED`、`TOKEN_REUSED` 等稳定错误码，详细原因不泄露二维码、token 或账户存在性。
- 终端连接与 session 事件本计划只登记身份/元数据，实时帧由 `RELAY-REALTIME` 定义。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

P0 初始化后使用 `task test:relay`、`task test:integration`、`task compose:up`、`task compose:down` 和 `task docs:verify`。先以本地 SQLite 完成 owner bootstrap、第二设备批准、撤销和 refresh reuse diagnostic；真实浏览器、真实 Provider、真实模型均不是本计划 gate。

## 6. 退出条件、阻塞和残余风险

退出：空库/升级库迁移、owner 配对、第二 Terminal 批准、设备撤销、新密钥包装阻断、token 轮换和 presence 重建全部有可重复结果；数据库和日志扫描没有正文、密钥或 token。

阻塞：P0 key format 未冻结、owner/recovery 语义未定、任何服务端路径需要解密正文、或迁移无法提供兼容窗口。残余风险是浏览器/Android UI 尚未实现，不能用 API 通过替代用户流程。

## 7. 文档回填清单

回填 `项目文档.md` 的路由、角色和表模型，`测试套件索引.json` 的新增 ID，ADR 中的身份或密码学变更，以及迁移/恢复 runbook。
