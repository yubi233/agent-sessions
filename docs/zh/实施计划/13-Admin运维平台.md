# Admin 运维平台实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ADMIN` |
| owner | Vue Admin |
| status | `planned` |
| target | M5 / P4 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-001、ADR-002、ADR-003、ADR-006 |

## 1. 目标与明确排除项

交付 Vue 3 + TypeScript strict 管理/运维投影：设备、Terminal、版本、项目别名、Workspace、会话状态、在线性、健康、流量和脱敏审计。复用 Element Plus 管理控件，但不得把会话正文做成可见运维字段。

Admin 默认只读：不批准/撤销设备、不生成恢复码、不发送会话写命令；这些 key-admin 行为由 owner Android 执行。未来若扩展受控运维操作，必须新增 ADR、角色和专属 API/测试，不能复用本计划默认权限。

## 2. 进入条件、输入和依赖

- 输入：Relay metadata API 的明确白名单、设备角色、审计 schema 与脱敏规则。
- 依赖：Vue 3/TypeScript、Element Plus、Pinia、Vue Query、OpenAPI client、Playwright。
- 禁止以管理员后端直连数据库替代 API 权限边界。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 metadata shell | metadata DTO | 登录读取态、设备/Terminal/项目/Workspace/健康页面、空/错误/重试 | Admin routes/read models | `ADMIN-01` | component | component report | route flag |
| W2 privacy allowlist | Relay metadata policy | 字段白名单、敏感字段 redaction、列表虚拟化/筛选、审计分页 | visibility mapper | `ADMIN-02`、`SEC-01` | component + integration | field scan | server allowlist remains authority |
| W3 operational observability | W1/W2 | online/presence、版本、连接错误、流量和脱敏审计关联 | health/audit views | `ADMIN-03..04` | component | screenshots/traces | hide unavailable metrics |
| W4 headed/read-only gate | W1-W3 | 尝试直接 URL/API 写行为、检查无会话正文、响应式/键盘/失败状态 | E2E test | `ADMIN-05`、`E2E-ADMIN-01`、`CTRL-01` | headed E2E + integration | Playwright report | static fallback; endpoint stays denied |

## 4. 数据、权限、错误和事件边界

- Relay 对 Admin 的 response DTO 采用字段白名单，UI 的隐藏不能作为安全机制；正文、文件、diff、附件、工具参数、密钥、token、恢复码永不返回。
- Admin 不拥有 Android controller lease；即便伪造 command endpoint，也必须收到服务端 `READ_ONLY_DEVICE`/权限错误。
- 配对/撤销状态可以展示，但操作入口跳转或提示使用 owner Android；不把管理面变成密钥恢复旁路。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

计划命令 `task test:admin`、`task test:e2e`。headed gate 需检查浏览器网络请求和可见页面，确认无敏感 payload；使用 fixture 时保持 `real_upstream=false`。

## 6. 退出条件、阻塞和残余风险

退出：所有运维元数据可读、不可见字段在 API/UI/缓存三层缺失、Admin 不能写会话或管理密钥、headless 以外的浏览器流程有证据。

阻塞：Relay 缺失字段白名单、角色不清、无法验证浏览器请求。残余风险：将来扩展管理权限必须重新设计 owner/key-admin 与审计模型。

## 7. 文档回填清单

回填 metadata allowlist、角色表、页面路由、审计字段、敏感数据扫描和 E2E 证据。
