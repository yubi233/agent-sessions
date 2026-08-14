# P1 Relay 身份、设备与实时同步

> 状态：`done`  
> 开始日期：2026-08-14  
> 完成日期：2026-08-14  
> 对应计划：[Relay 身份、设备与持久化](../实施计划/02-Relay身份设备与持久化.md)、[Relay 实时会话与同步](../实施计划/03-Relay实时会话与同步.md)

## 开始前待办

- [x] 审计 P0 退出证据与 Relay 现有领域草稿。
- [x] 实现账户注册、登录、刷新、注销和 refresh reuse 撤销；token 只保存 hash。
- [x] 实现 owner bootstrap、设备配对、审批、取消、撤销与恢复码边界。
- [x] 以 SQLite 迁移建立账户、设备、配对、Terminal、Session、Command、ControlLease、Outbox 的权威约束。
- [x] 实现 REST 认证边界、错误映射与 Android/Web/Admin 权限校验。
- [x] 实现 Session 命令幂等、ControlLease epoch fencing、outbox 和进程内 presence。
- [x] 实现账号级 SSE cursor 恢复与 Terminal WebSocket hello/challenge 基线。
- [x] 追加 `AUTH-*`、`PAIR-*`、`HTTP-*`、`SSE-*`、`WS-*`、`CTRL-*`、`SYNC-*` 长期集成回归。
- [x] 增加 Web headed P1 登录/只读拒绝回归；先通过全量 gate，再录制用户流程。
- [x] 回填项目文档、测试矩阵、suite 状态、证据和残余风险。
- [x] 运行 P1 full gate，归档脱敏报告并提交 `feat(p1): ...`。

## 验证口径

P1 使用隔离 SQLite 和 fixture 账号：`local_test=true`、`fixture_data=true`、`real_upstream=false`、`real_model=false`。Web 回归由 headed Chrome 执行；真实 Provider 不属于本阶段。

## 实施总结（2026-08-14）

- 领域层新增 `internal/domain/realtime.go`（Session/Command/lease/outbox）与 `internal/domain/presence.go`（进程内在线与广播）。
- 仓储层扩展 `internal/store/repository.go` 与 `sqlite.go`，覆盖 Terminal/Project/Workspace/Session/Instance/Event/Command/Lease/Outbox 持久化；事件 seq 用 `MAX+1` 保证并发单调。
- 传输层 `internal/httpapi/handlers.go` 挂载 /v1 路由：auth/register/login/refresh/logout、pairing、devices、sessions、commands、lease、workspaces、SSE；`error.go` 补齐 lease/target stale 映射；本地 CORS 与 OPTIONS 预检处理。
- 集成回归 `internal/relay/p1_integration_test.go`、`p1_authorization_test.go` 与 `internal/domain/realtime_test.go` 覆盖 AUTH-01、PAIR-01/03、HTTP-01、SESS-01、CTRL-01/02、SYNC-01、SEC-01 及 seq 单调、lease fencing、幂等、outbox drain、presence 与唤醒结果。
- Web 只读登录页新增 `apps/web/src/App.vue`；headed 回归 `e2e-verify/suites/p1-web-readonly.mjs` 与录屏 `e2e-verify/record.mjs` 均已通过。

## 已交付证据

- Go 集成/单元回归全部通过；`task check` 通过（生成无漂移、typecheck 通过）。
- headed 回归 `p1-web-readonly` 通过（`real_browser=true, headless=false`）。
- 录屏：`e2e-verify/screencasts/2026-08-14T03-51-36-622Z/demo.mp4`。
- 报告：`e2e-verify/reports/` 下按 plan_id 归档。

## 回滚

迁移保持 additive；新 API 只增加版本化路由。测试数据库与 outbox 均由本轮脚本创建并销毁，生产数据不在 P1 操作范围内。

## 残余风险

- SSE 目前按会话回放并订阅账号级广播，未实现 Terminal WebSocket hello/challenge 完整帧协商（WS-01/WS-02 由 P2 Daemon 接入时闭环）。
- Git RPC 路由（HTTP-03）、真实 Provider（P3）与完整客户端能力（P4）未在本阶段交付，按计划标记 `incomplete`/`planned`。
