# Web 只读客户端实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `WEB` |
| owner | Vue Web App |
| status | `planned` |
| target | M5 / P4 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-001、ADR-002、ADR-005、ADR-006 |

## 1. 目标与明确排除项

交付 Vue 3 + TypeScript strict 的 PWA 只读客户端，查看项目、Workspace、Session、消息、工具事件、状态和 Git diff。使用 Element Plus 基础控件、Pinia、Vue Query、Dexie、原生 WebSocket 与 SSE；时间线/DiffView 是领域组件。

Web 不发送 prompt、审批、Plan、Goal、Skill、模式切换或任何会话写命令；不在 IndexedDB/Service Worker 缓存解密正文。

## 2. 进入条件、输入和依赖

- 输入：OpenAPI TypeScript DTO、Relay 只读 routes/SSE、Git/会话 fixture，端到端解密边界。
- 依赖：Vite、Vue Router、Element Plus、Pinia、`@tanstack/vue-query`、`openapi-fetch`、`@microsoft/fetch-event-source`、Dexie、Playwright。
- 先用 mock/fixture 开发 UI，真实 Relay 字段冻结后接入，不复制 DTO。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 shell/read model | TS DTO、fixtures | 登录读取态、路由、列表/详情、loading/empty/error/retry、connection state | Web app shell | `WEB-01` | component | Vitest report | route-level fallback |
| W2 timeline/recovery | SSE/WS fixtures | encrypted event consumption、cursor 去重、工具/Plan/Goal 展示、刷新恢复 | timeline store/view | `WEB-02`、`SESS-01..02`、`SYNC-01` | component + integration | trace | reconnect backoff; no write fallback |
| W3 Git DiffView | Git contract | 文件树、搜索、unified/split、large/binary/rename/snapshot stale 状态、虚拟行 | DiffView | `WEB-03`、`GIT-01..02` | component + headed E2E | viewport artifacts | summary/unified fallback |
| W4 PWA/cache/privacy | W1-W3 | 静态资源、密文和最小索引缓存；SW exclusion、logout cleanup、content security | PWA policy | `WEB-04` | integration | cache inspection | disable SW/version rollback |
| W5 headed gate | W1-W4、可运行 Relay/mock | headed 浏览器完成 read-only 流程、响应式、键盘、刷新、失败/重试 | Playwright journey | `WEB-05`、`E2E-WEB-01` | headed E2E | trace/video report | static version rollback |

## 4. 数据、权限、错误和事件边界

- UI 只消费对该 Web 设备包装的密文和白名单元数据；服务端无写 endpoint 授权，前端也没有写控件/隐藏请求。
- `401/403`、protocol mismatch、cursor stale、network offline 和 `unsupported` 必须有可观察状态；不通过静默清空掩盖数据问题。
- Diff 文件路径、正文和工具参数按解密边界处理；浏览器日志、错误上报和 PWA cache 仅存脱敏/密文数据。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

计划命令为 `task test:web` 和 `task test:e2e`。full gate 必须用 headed Playwright，报告 `real_browser=true`、`headless=false`；如果仅 mock/fixture，则 `real_upstream=false` 和 `real_model=false`。

## 6. 退出条件、阻塞和残余风险

退出：所有页面有加载/空/失败/重试/断线状态，Web 不可写在 UI 与 Relay 两层成立，长列表/diff 不卡顿或安全降级，headed 流程与移动/桌面视口有证据。

阻塞：浏览器 runner、稳定 DTO 或解密边界不具备。残余风险：PWA offline 和真实 E2EE 多设备行为需要与 Android/Relay 联合 gate。

## 7. 文档回填清单

回填包版本、路由、cache policy、data-testid 契约、可访问性和 headed 报告路径。
