# Agent Sessions

类 Happy 的远程编码会话平台，目标是让 Android、Web 与多台 PC 上的本地编码 Agent 通过一个自托管中继服务协作。

## 当前状态

当前仓库包含 Go Relay/Daemon、Vue 只读客户端、Flutter Android 客户端、协议/密码学向量与 SQLite 本地基线。迭代已推进到 v0.9.7（2026-09 收尾）：v0.9.6 交付 DSH 历史默认隔离与显式接续入口；v0.9.7 完成桥可用性预检与补丁入库（`tools/dsh-bridge-patches/`）、CI 静态门与协议生成物漂移 job、无人值守运行与数据生命周期收口，CI 恢复绿色。当前口径仍以本地/受限真实链路为主，不能把 fixture、局部 CLI 或历史报告表述为完整远程控制能力；逐版本事实以[项目文档](docs/zh/项目文档.md)为准。

以下文档是当前实现和后续迭代的事实来源：

- [项目文档](docs/zh/项目文档.md)：当前架构、边界、数据模型和运行约束。
- [实施计划](docs/zh/实施计划.md)：P0-P5 阶段、依赖关系和交付门槛。
- [分项目实施计划](docs/zh/实施计划/)：16 份协议/安全、Relay、Daemon、Provider、Android、Web、Admin、测试和发布的独立工作包。
- [自动化测试文档](docs/zh/自动化测试文档.md)：测试分层、验收矩阵和证据口径。
- [测试套件索引](docs/test/测试套件索引.json)：唯一测试 ID 归属、依赖和真实上游 gate 约束。
- [基础验收用例](docs/test/基础验收用例.json)：跨项目关键用户旅程用例。
- [架构决策记录](docs/adr/)：协议、安全、会话和适配器等不可随意改变的设计决策。
- [v0.9.5 迭代计划](docs/zh/迭代计划/迭代计划v0.9.5.md)：DSH 会话接续完整化——全局会话续聊、增量同步与历史导入。
- [实施记录 35（v0.9.5）](docs/zh/实施记录/35-v0.9.5-DSH会话接续完整化.md)：真实模型续聊旅程与残余风险。
- [实施记录 36（v0.9.6）](docs/zh/实施记录/36-DSH历史默认隔离与同源去重.md)：DSH 历史默认隔离、origin/visibility 与同源去重。
- [v0.9.7 迭代计划](docs/zh/迭代计划/迭代计划v0.9.7.md)：长期稳定运行硬化。
- [实施记录 37（v0.9.7）](docs/zh/实施记录/37-v0.9.7-长期稳定运行硬化.md)：桥可用性预检、CI 静态门与稳定性演练。

## 目标边界

- Go + Gin 生态：Relay Server 与跨 macOS、Windows、Linux 的 PC Daemon；Relay 实现 HTTP/REST、账号级 SSE 与仅 Terminal 可访问的 Daemon 专用 SSE。当前不实现 WebSocket；生产 E2EE event encoder、真实 Provider 与完整会话控制仍未完成。
- Vue3 + TypeScript：管理平台和只读简易 Web App。
- Flutter + Dart：Android 完整编码会话控制端。Flutter 不能使用 TypeScript；若要求所有客户端都使用 TypeScript，必须把 Android 技术栈改为 React Native。
- 支持 Claude、Codex、OpenCode、OpenClaw，按统一能力模型对原生能力进行声明和降级。
- 单租户自托管、SQLite 权威存储、REST + 账号级 SSE 与端到端加密。

首版只读 Git diff，不支持远程开机、Git 写操作、语音、社交、付费和 Happy 协议兼容。

## 本地启动

**本地环境默认用仓库根目录的 `restart.sh` 脚本启动**：直接运行 `./restart.sh`（无参数，等价于 `restart` 动作）即可拉起完整本地栈——Relay（8787）、Daemon（真实 `go run`，心跳就绪确认）与 Flutter macOS 客户端，全部就绪后输出 "selected services are running"。这是本地开发/验收的标准启动方式。

```bash
./restart.sh                # 默认完整启动（等价 restart：清理端口 + 拉起全部服务）

./restart.sh start          # 启动（不清理外部监听进程）
./restart.sh status
./restart.sh stop
./restart.sh restart

# Relay 恢复后只重连 Flutter，不打断 Daemon/OpenCode
./restart.sh restart-flutter

# 本机 macOS Flutter（默认）
./restart.sh restart --flutter-mode mac

# 已连接的物理 Android：脚本自动选择唯一 online 设备
AGENT_SESSIONS_FLUTTER_RELAY_BASE=http://<本机局域网地址>:8787 \
  ./restart.sh restart --flutter-mode device

# Web/Admin 仅在需要时显式打开
./restart.sh restart --with-web --with-admin
```

Relay 委托给 `tools/relayctl.sh`，Daemon 使用真实 `go run ./apps/daemon run`，Flutter 使用真实 `flutter run -d <target> --no-pub`；日志和 PID 状态写入 `.task/restart/`，不会写入 `testbox/`。Daemon 默认开启，必须存在已配对的 `AGENT_SESSIONS_DAEMON_TOKEN`，否则入口在启动任何组件前 fail-closed。Flutter 目标可通过 `--flutter-mode mac|device`、`--flutter-device <adb-serial>` 或 `AGENT_SESSIONS_FLUTTER_DEVICE` 覆盖；device 模式只接受脚本发现的 online 物理 Android，不启动 AVD。设备访问 Relay 时必须设置 host 可达的 `AGENT_SESSIONS_FLUTTER_RELAY_BASE`。

`restart` 会清理所选 Relay/Web/Admin 端口上遗留的监听进程；`start` 默认不清理外部进程，可显式加 `--clean-ports`，也可用 `--no-clean-ports` 禁止清理。`--no-daemon`、`--no-flutter` 可用于分段调试，`--with-web`、`--with-admin` 开启可选调试面。`stop` 只停止本脚本记录且命令签名匹配的进程。清理范围只包含配置的服务端口，不会扫描其他端口。脚本回归使用 `task test:restart`。

DSH 桥是可选 Provider：桥 bin 缺省按 `~/code/deepseek-harness` 检出回退（`AGENT_SESSIONS_DSH_BIN` 可覆盖）；组合文件没有内置缺省，`restart.sh` 默认注入仓库根 `cordis.yml`（个人端点与渠道配置，已 gitignore）。新机器从 `cordis.yml.example` 复制为 `cordis.yml`，按文件头注释补齐检出路径与渠道即可；检出缺失或产物被清理时的重建链见 `tools/dsh-bridge-patches/README.md`。
