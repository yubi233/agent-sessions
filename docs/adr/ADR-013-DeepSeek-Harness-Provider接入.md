# ADR-013：DeepSeek Harness 作为第五类 Provider 的接入契约

- 状态：Proposed（v0.5.next P0 冻结版；P1–P4 实施中如有修订必须更新本 ADR）
- 关联：迭代计划 v0.5.next、`internal/adapter/spi.go`、`e2e-verify/real/dsh-acp-smoke.mjs`

## 1. 决策

以 DeepSeek Harness（DSH）官方 ACP 自动化桥为唯一集成面，将 `dsh` 作为第五类 Provider 注册进 Adapter SPI：

- transport 为 JSON-RPC over stdio（ndjson 帧协议版本 `PROTOCOL_VERSION=1`），由本仓库 Daemon spawn `dsh-acp-demo` 子进程承载；
- 不复用 DSH Web GUI 的 BFF/API proxy（developer preview 面向 UI，稳定性不满足 gate 要求）；
- 不修改 DSH 上游源码。

## 2. 版本门

- `Detect` 先 `initialize` 握手并比对 `protocolVersion`（当前实测返回 `1`）；
- 同时采集桥 `agentInfo`（实测 `deepseek-harness-acp@0.0.1`）写入能力快照；
- 锁定区间：`protocolVersion=1` 且 agentInfo.version 匹配实施记录登记的已验证 checkout；越界即 available=false、全部 unsupported、中文原因，不写 Version 字段。

## 3. 进程拓扑

**选型：方案 A —— per-session 子进程。**

依据（P0 实测，报告 `e2e-verify/reports/ADAPTER-DSH/p0-smoke-2026-08-23T17-48-37-906Z.json`）：

- 冷启动到 initialize 应答仅 **359ms**（预构建 lib、无 HMR），远低于"秒级"担忧；
- 会话生命周期与进程树一一对应，`ForceKillHandle` 所有权证明成立，直接复用 SESS-05 监督回归；
- EOF dispose 受控退出（实测 exit code 0），无孤儿残留。
- 共享长驻桥方案保留为未来优化项；切换必须重跑 P2 全部回归并修订本节。

## 4. wire ↔ SPI 映射（P0 冻结）

| ACP wire | SPI/canonical | P0 实测结论 |
| --- | --- | --- |
| `initialize` | Detect / 能力矩阵基线 | native；应答含 protocolVersion 与 agentInfo |
| `session/new`(cwd/mcpServers) | Start(StartRequest) | native；返回 sessionId（实测前缀 `c790235f…`） |
| `session/prompt` | Send | native（形状确认 `{sessionId, prompt[]}`）；真实模型往返留待 P4 live gate |
| cancel notification | Abort | 通知型无应答帧；对空闲会话容错（进程存活） |
| assistant 文本增量/提交 | message_delta / message_completed | P0 未触发（无 prompt），P1 用假桥定帧形 |
| 权限请求/一次性决策 | permission_request / permission_decision | 同上，P1 假桥先行，P4 真实链路复核 |
| 工具调用明细 | tool_call / tool_result | **未在桥承诺面内**；P1 假桥按缺失设计，能力标 unsupported（除非后续上游扩展） |
| `session/load` / `session/list` | Resume 六态 | **wire 级证据：`-32601 Method not found`**（桥处理面仅 initialize/authenticate/newSession/prompt/cancel）→ Resume=`unsupported` |
| 进程组终止（stdin EOF + 信号） | Dispose / ForceKillHandle | native；EOF 后 exit 0 |

## 5. 安全与凭据边界

- 桥自身无凭据，报告 `credential_source="none"`；LLM key 由 DSH 侧 gitignored `.env` 承载，本仓库 runner 不读取不转储；
- Daemon spawn 时最小环境注入（PATH/HOME/TMPDIR/显式配置），scrub 其他 Provider 凭据变量；
- stdout 专用于协议帧，诊断只走 stderr 且脱敏后归档；canonical event 白名单剥离 persona/系统提示等私有 payload；
- E2EE 边界不变：进入 Relay 的内容仍走既有 AES-256-GCM 信封。

## 6. 影响与回滚

- 影响面：新增 `internal/adapter/dsh/`、registry 第五 kind `"dsh"`、Flutter provider 入口展示；无 SQLite 迁移、无公开 API 破坏性变更。
- 回滚：registry 移除 `"dsh"` 即整体下线，客户端按未知 provider fail-closed；不需要数据动作。
