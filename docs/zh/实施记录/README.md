# 实施记录

本目录记录 Agent Sessions 的阶段化实施状态。每个阶段开始前必须创建带复选框的待办；仅当所有退出条件、回归测试和证据均完成后，才允许将阶段标为完成并创建对应 Git 提交。

## 阶段顺序

1. P0：工程、协议、密码学与本地运行基线。
2. P1：Relay 身份、设备、会话、实时同步与控制租约。
3. P2：PC Daemon、Workspace 安全、Git 只读与 mock runtime。
4. P3：Claude、Codex、OpenCode、OpenClaw 的 adapter contract。
5. P4：Android 写控制端、Web 只读端与 Admin 运维端。
6. P5：安全、性能、部署、备份恢复与发布门禁。

每份记录必须链接对应的实施计划、测试 ID、命令、报告目录和回滚点。真实 Provider、真实模型与生产端点没有明确凭据时保持 `blocked`，不得用 fixture 标记为通过。

专题记录：

- [Happy Mobile 功能对比与 OpenCode 验证](07-HappyMobile功能对比与OpenCode验证.md)：固定上游版本对照、CLI live smoke、transport 优先级。
- [v0.2 Android 会话能力对齐 Happy](08-v0.2-Android会话能力对齐Happy.md)：会话快捷操作、文件浏览、composer 控制面与 OpenCode 真实 transport。
- [v0.8 DSH 持久化与 Resume 前置](16-v0.8-DSH持久化与Resume前置.md)：工作区持久化根、非破坏性迁移、Resume 句柄交接、回放契约与 Zen 测试池。
- [v0.8.1 后续 DSH 模型选择接入](19-v0.8.1后续-DSH模型选择接入.md)：`session/set_config_option` 契约、能力矩阵模型目录与 `cordis.yml` 池同步。
- [v0.8.5 中止与轨迹时间修复](23-v0.8.5-中止与轨迹时间修复.md)
- [v0.9.3 事件投递吞吐与 resume 上下文投影收口](33-v0.9.3-事件投递吞吐与resume上下文投影收口.md)：批量事件上传（万级 delta 秒级追平）、桥回放 skill-catalog 过滤 + Go mapper 防御、客户端自动恢复加固与真机零手工收口（V092-10 关单）。
- [v0.8.5 工作区显示名与权限契约](24-v0.8.5-工作区显示名与权限契约.md)：Relay `workspace_name` 贯通（副标题/空状态真实显示名）与权限 mode `mode.set`+`mode_id` wire 契约统一；会话级 mode 目录上行通道与图片/工作区发现/timing/预设待后续阶段。：异步 `session.send`、Abort 可见轨迹、canonical 事件时间和 Flutter 轨迹展示；与 v0.8.5 主计划的图片/权限/工作区等能力分开记录。