# Android 移动控制端实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ANDROID` |
| owner | Android App |
| status | `planned` |
| target | M5 / P4 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-002、ADR-003、ADR-004、ADR-005、ADR-006 |

## 1. 目标与明确排除项

交付 Flutter/Dart Android 唯一会话写控制端：owner 配对、完整会话控制、流式事件、权限/问题、Plan/Goal/Skill、附件、离线恢复、通知和 Git DiffView。Flutter UI/业务代码使用 Dart，Android 平台插件使用 Kotlin；不以 TypeScript 实现 Flutter。

不允许 Android 直接连接 Daemon，不实施 Git 写操作、服务器正文搜索、远程 shell 或未被 Provider capability 支持的伪功能。

## 2. 进入条件、输入和依赖

- 输入：稳定 Dart DTO/crypto vectors、Relay auth/realtime mock、Daemon Git fixture、Adapter capability fixtures。
- 依赖：Material 3、Riverpod、go_router、Dio、web_socket_channel、Freezed/json_serializable、Drift、Keystore、cryptography、UnifiedPush Kotlin plugin。
- 用户选择：首个 Android 是 owner/key-admin；会话写命令始终附当前 controller/lease 语义。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 app shell/security | DTO/crypto | 登录/refresh、QR 配对、Keystore、Drift 密文缓存、路由和连接状态 | app shell、repositories | `MOBILE-01`、`PAIR-01..03` | widget + integration | emulator report | 只读 fallback，旧 envelope 双读 |
| W2 session control | realtime/mock adapter | terminal/project/workspace/session 列表，新建/恢复/终止/删除，delta/tool/permission/question/abort | session feature | `MOBILE-02`、`SESS-01..02`、`CTRL-01..02` | integration | screen trace | 禁用写入口直到 lease/capability 可用 |
| W3 plan/goal/skill/attachment | adapter fixtures | model/effort/permission、Plan、Goal、Skill 风险确认、图片/文本附件与限制 | control panels | `MOBILE-03`、`MODE-01..04`、`ATTACH-01` | widget + integration | capability report | capability flag；拒绝时无 Provider 调用 |
| W4 Git DiffView | daemon Git fixtures | 统计、树、搜索、unified/split、hunk、syntax、binary/submodule/LFS、分页与 snapshot stale | DiffView feature | `MOBILE-04`、`GIT-01..06` | widget + integration | viewport screenshots | unified summary fallback |
| W5 lifecycle/notification | W1-W4 | background/foreground、网络切换、cursor/幂等恢复、UnifiedPush 或应用内降级 | lifecycle/notification adapter | `MOBILE-01..04` | integration/device | device report | notification flag; no lost command replay |

## 4. 数据、权限、错误和事件边界

- Drift 永远只存密文 envelope、cursor 和最小索引；明文解密态只在内存，日志/截图/报告禁含正文。
- Android 发送写意图，Relay 依据认证 device、lease epoch、scope 和 capability 决定接受；客户端不能自行提升权限。
- `native/emulated/unsupported` 决定按钮可用性和说明；不支持时不伪造成功或本地模拟 Provider 写操作。
- Diff 来自 Daemon 加密 RPC，snapshot stale 必须给用户可重试状态，而非混合渲染。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

P0 后使用 `task test:android`、`task test:android:e2e`；模拟器用于主 gate，真机/UnifiedPush/后台行为需显式标记设备型号、Android 版本和授权。录屏必须在 integration gate 后，且不包含真实会话内容。

## 6. 退出条件、阻塞和残余风险

退出：Android 是唯一可写入口；后台/断线/网络切换不会丢事件或重复命令；权限、问题、Plan、Goal、Skill 按能力工作；Git/附件边界通过；真机结果有明确验证口径。

阻塞：缺 Android SDK/模拟器、Keystore/UnifiedPush 无法验证或协议未冻结。残余风险：真实 Provider 能力必须引用专属 adapter evidence，不可由 UI 测试替代。

## 7. 文档回填清单

回填 Flutter/Dart 版本、缓存 schema、通知降级、屏幕/无障碍约束、capability UI 映射和测试设备矩阵。
