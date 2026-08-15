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

专题记录：[Happy Mobile 功能对比与 OpenCode 验证](07-HappyMobile功能对比与OpenCode验证.md)补充了本机 OpenCode Go 的授权 live smoke、能力 fail-closed 修复和下一阶段的 Provider transport 优先级。
