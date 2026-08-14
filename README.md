# Agent Sessions

类 Happy 的远程编码会话平台，目标是让 Android、Web 与多台 PC 上的本地编码 Agent 通过一个自托管中继服务协作。

## 当前状态

当前仓库处于文档基线阶段，尚未提交运行时代码。以下文档是后续实现的事实来源：

- [项目文档](docs/zh/项目文档.md)：当前架构、边界、数据模型和运行约束。
- [实施计划](docs/zh/实施计划.md)：P0-P5 阶段、依赖关系和交付门槛。
- [分项目实施计划](docs/zh/实施计划/)：16 份协议/安全、Relay、Daemon、Provider、Android、Web、Admin、测试和发布的独立工作包。
- [自动化测试文档](docs/zh/自动化测试文档.md)：测试分层、验收矩阵和证据口径。
- [测试套件索引](docs/test/测试套件索引.json)：唯一测试 ID 归属、依赖和真实上游 gate 约束。
- [基础验收用例](docs/test/基础验收用例.json)：跨项目关键用户旅程用例。
- [架构决策记录](docs/adr/)：协议、安全、会话和适配器等不可随意改变的设计决策。

## 目标边界

- Go + Gin 生态：Relay Server 与跨 macOS、Windows、Linux 的 PC Daemon；Gin 负责 HTTP/REST，WebSocket/SSE 按协议层单独实现。
- Vue3 + TypeScript：管理平台和只读简易 Web App。
- Flutter + Dart：Android 完整编码会话控制端。Flutter 不能使用 TypeScript；若要求所有客户端都使用 TypeScript，必须把 Android 技术栈改为 React Native。
- 支持 Claude、Codex、OpenCode、OpenClaw，按统一能力模型对原生能力进行声明和降级。
- 单租户自托管、SQLite 权威存储、REST + SSE + WebSocket、端到端加密。

首版只读 Git diff，不支持远程开机、Git 写操作、语音、社交、付费和 Happy 协议兼容。
