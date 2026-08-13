# OpenCode Adapter 实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ADAPTER-OPENCODE` |
| owner | OpenCode Adapter |
| status | `planned` |
| target | M4 / P3 |
| protocol_revision | `DAEMON-SPI@v1-draft` |
| adr | ADR-004、ADR-005、ADR-006 |

## 1. 目标与明确排除项

通过 OpenCode 本地 API、WebSocket 或 SSE 的正式接口实现 session、stream、abort、权限、技能和 Git 能力探测，输出统一 canonical 事件。OpenCode 自身 UI 或 HTTP 协议不直接暴露给手机；Daemon 是唯一桥接者。

不把 OpenCode diff 实现替代 `DAEMON-GIT` 的安全 Git RPC，不要求 Relay 解释 OpenCode payload，不凭借页面抓取假装支持原生会话恢复。

## 2. 进入条件、输入和依赖

依赖 `ADAPTER-PLATFORM`、`DAEMON-CORE`、受测 OpenCode 版本和离线 API/WS/SSE fixtures。真实 upstream 或模型请求需要单独授权。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 discovery/transport | SPI、版本证据 | detect 本地服务、版本、认证和 endpoint；HTTP/SSE/WS 连接/重连/取消 | typed local client | `ADPT-OPENCODE-01` | contract | connection fixture | `opencode` flag off |
| W2 session 映射 | W1 | create/resume/send/abort、delta/tool/final/error、session handle 加密持久化 | session mapper | `ADPT-OPENCODE-02` | contract | golden trace | unsupported resume result |
| W3 interaction capabilities | W2 | permission/question/plan/goal/skill/model 能力探测，明确 native/emulated/unsupported | matrix/fixtures | `ADPT-OPENCODE-03` | contract | capability report | per-capability flag |
| W4 live smoke | W1-W3、授权 | 本机临时 repo、最小交互、停止和 cleanup | live/blocked report | `ADPT-OPENCODE-04` | authorized upstream | scrubbed report | abort/cleanup local service |

## 4. 数据、权限、错误和事件边界

OpenCode session ID 仅作为本机加密 ProviderThread 状态或 E2EE payload；重连/恢复失败必须映射到规定的 wake outcome。Git 只读能力仍经 Daemon workspace 校验和 snapshot token。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

计划命令为 `task test:contract -- provider=opencode` 和经授权的 `task test:real -- provider=opencode`。先用 API/WS/SSE fixture 覆盖断线，再以隔离 repo 做有停止点的 live smoke。

## 6. 退出条件、阻塞和残余风险

退出：API/WS/SSE 断线、未知版本、session start/resume/send/abort 和能力三态均有 fixture contract；真实 smoke 有证据或明确 blocked。回滚：关闭 OpenCode feature flag。阻塞：本地 API 不可稳定发现、协议缺乏证据或需要服务端明文。

## 7. 文档回填清单

回填最小支持版本、endpoint 矩阵、fixture revision、恢复语义和 capability 证据。
