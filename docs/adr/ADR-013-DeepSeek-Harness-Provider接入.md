# ADR-013：DeepSeek Harness 作为第五类 Provider 的接入契约

- 状态：Proposed（v0.8 开工准备修订；Resume/迁移/同步实现完成前仍不得把相关能力标为 native）
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
| `session/load` / `session/resume` | Resume 六态 | 当前 DSH checkout 已实现 load/resume；本仓库已完成 ready handle 交接、回放去重和恢复后 send，Resume=`native`；真实模型往返仍由 P4 live gate 复核 |
| `session/list` | 本地会话发现 | ACP 仍未提供 list；v0.8 只在已确认 workspace/legacy root 内扫描 JSONL，不把任意 DSH checkout 当作数据源 |
| 进程组终止（stdin EOF + 信号） | Dispose / ForceKillHandle | native；EOF 后 exit 0 |

## 5. 安全与凭据边界

- 桥自身无凭据，报告 `credential_source="none"`；LLM key 由 DSH 侧 gitignored `.env` 承载，本仓库 runner 不读取不转储；
- Daemon spawn 时最小环境注入（PATH/HOME/TMPDIR/显式配置），scrub 其他 Provider 凭据变量；
- stdout 专用于协议帧，诊断只走 stderr 且脱敏后归档；canonical event 白名单剥离 persona/系统提示等私有 payload；
- E2EE 边界不变：进入 Relay 的内容仍走既有 AES-256-GCM 信封。

## 6. 影响与回滚

- 影响面：新增 `internal/adapter/dsh/`、registry 第五 kind `"dsh"`、Flutter provider 入口展示；无 SQLite 迁移、无公开 API 破坏性变更。
- 回滚：registry 移除 `"dsh"` 即整体下线，客户端按未知 provider fail-closed；不需要数据动作。

## 7. v0.8 开工前修订决策

- **持久化所有权。** Start/Resume 的 canonical `WorkspaceRoot` 对应 `<workspaceRoot>/.dsh-sessions`，由工作区拥有且 Close 永不删除；Detect 才能创建并清理自有临时根。`DSH_SNAPSHOT_SESSIONS_ROOT` 只接收本次桥实例的精确根，不能被旧的临时 `sessions/` 注入逻辑劫持。
- **存量迁移。** P0 先对显式授权的旧 checkout/bridge/workspace roots 做只读预检，再按 JSONL header 的 `cwd` 归属复制或登记 legacy root。迁移保留源文件，不复制派生 query index；重复 ID、双编码、未知格式、header/path 不一致或源文件变化均 fail-closed。
- **Resume 时序。** Adapter 必须在发出 `session/load` 或 `session/resume` 前将新 Handle 通过 typed ready callback 交给 Runner，由 Runner 原子登记并启动事件转发。回放状态 `pending/loading/complete` 和 checkpoint 只保存在 Daemon 本机；公共 command 不透传 `replay_history`。
- **回放映射。** `user_message_chunk` 映射 `EventUserMessage`，`agent_message_chunk` 映射 `EventMessageCompleted`。source key 由 Relay session id + 回放 ordinal 的版本化哈希派生，只用于本机回放标记和稳定 outbox `event_id`，不进入事件正文或导入元数据，也不暴露 DSH session id。
- **工作区/Terminal 边界。** DSH Workspace identity 为 `account + home Terminal + canonical root`；跨 Terminal 仅可查看安全投影，不能 scan/import/resume/send。Daemon 不持有 owner bearer，扫描/导入必须由 owner/write 通过专用 signed result 触发。
- **能力真值。** Resume 的 ready/转发/继续发送闭环已通过契约测试，能力矩阵为 `native`；未真正下发的 `model_select` 保持 `unsupported`；`policy: never` 正常路径不会向 Agent Sessions 发 permission request，异常桥请求仍以 `cancelled` fail-closed。
