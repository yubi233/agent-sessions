# P4 Web 只读、Admin 运维只读与 Android mock 控制壳

> 状态：`done`（mock/fixture 层；真实传输与完整能力标记 `incomplete`）  
> 开始日期：2026-08-14  
> 完成日期：2026-08-14  
> 对应计划：[Web 只读客户端](../实施计划/12-Web只读客户端.md)、[Admin 运维平台](../实施计划/13-Admin运维平台.md)、[Android 移动控制端](../实施计划/11-Android移动控制端.md)

## 实施总结（2026-08-14）

- **Web 只读客户端（`apps/web`）**：登录后只读展示设备、会话与 Provider 能力矩阵；组件测试覆盖只读渲染，headed 回归 `p1-web-readonly` 扩展断言能力矩阵（WEB-01）。
- **Admin 运维控制台（`apps/admin-web`）**：新建 Vue 应用，只读展示脱敏设备与会话元数据，无配对/撤销/写入口；组件测试覆盖登录、只读与空状态（ADMIN-01/02），headed 回归 `p4-admin-readonly` 验证只读约束（ADMIN-05、E2E-ADMIN-01）。
- **Android mock 控制壳（`apps/mobile`）**：将 Flutter Demo 替换为控制壳（登录态 + 会话 start/stream/abort 与消息列表）；widget 测试覆盖登录、新建会话、流式显示与 abort 禁用（MOBILE-02 widget 层）。
- **基础设施**：`e2e-verify/lib/web.mjs` 抽取 `startVite` 支持多应用；`run.mjs` 并行启动 Web 与 Admin；Relay 健康/API CORS 加入 admin 端口，空设备/会话列表返回 `[]` 而非 null。

## 已交付证据

- `task check` 通过（生成无漂移、web/admin typecheck 通过）；Go 全部回归通过。
- Web/Admin headed 回归 `p1-web-readonly`、`p4-admin-readonly` 通过（`real_browser=true`、`headless=false`）。
- Flutter `flutter test --machine` 通过（含 MOBILE-02 widget 测试）。

## 覆盖的测试 ID

`WEB-01`、`ADMIN-01/02/05`、`E2E-ADMIN-01`、`MOBILE-02`（widget 层）。SSE cursor（WEB-02）、Git DiffView（WEB-03）、PWA（WEB-04）、完整 Android integration（MOBILE-01/03/04）、附件（ATTACH-01）等标记 `incomplete`，等待真实传输与完整能力接入。

## 残余风险与未做

- 真实 Relay 双向传输、端到端解密消费、SSE 刷新恢复、Git DiffView 渲染与 Android integration_test 未在本阶段落地，按计划标记 `incomplete`。
- 管理面写权限约束已通过 headed 回归验证（无写入口 + 服务端只读错误），但真实多设备 E2EE 行为需 P5 联合验证。