# DSH 适配器 P1 实施规格（供执行者阅读）

仓库：/Users/yubi/code/agentProject/agent-sessions（Go 后端）。

## 必读文件
- internal/adapter/spi.go（Adapter SPI 全文）
- internal/adapter/opencode/adapter.go、client.go、events.go（既有风格与 fail-closed 文案模式）
- internal/adapterreg/registry.go、registry_test.go
- docs/adr/ADR-013-DeepSeek-Harness-Provider接入.md（协议对照与决策）

## 协议事实（已实测，勿再验证）
桥 `dsh-acp-demo` 为 JSON-RPC over stdio，ndjson 帧。
- bin=/Users/yubi/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js，node 运行，参数 `-c <cordis.yml>`；
- 默认配置=/Users/yubi/code/deepseek-harness/examples/acp-agent/cordis.yml。
- 请求：`initialize`{protocolVersion:1,clientInfo:{name,version},clientCapabilities:{}}→result{protocolVersion,agentInfo:{name,version}}；`session/new`{cwd,mcpServers:[]}→result{sessionId}；`session/prompt`{sessionId,prompt:[{type:"text",text}]}→result{stopReason,...}。
- 通知：出站 `session/cancel`{sessionId}；入站 method=`session/update` params={sessionId,update:{sessionUpdate:"<variant>",...}}（变体权威定义：/Users/yubi/code/deepseek-harness/packages/acp/acp/src/index.ts 与 node_modules/@agentclientprotocol/sdk/dist/schema/types.gen.d.ts）。
- 桥→客户端请求：`session/request_permission`（权限决策）、fs/*。
- 桥仅处理 initialize/authenticate/newSession/prompt/cancel；session/load、session/list 返回 -32601（已实测）。
- EOF 关 stdin 触发受控 dispose（exit 0）；冷启动约 359ms。

## 新建 internal/adapter/dsh/
1. bridge.go：BridgeTransport 接口（帧级读写+Close）+ 子进程实现 dshBinTransport（exec.Cmd 启 node bin，Setpgid 进程组；逐行读 stdout；stdin 写帧；stderr 环形缓冲脱敏上限；Close=关 stdin 等待退出宽限 10s 后 SIGKILL 进程组）。路径 env：AGENT_SESSIONS_DSH_BIN、AGENT_SESSIONS_DSH_CONFIG，缺省上述路径；node 用 exec.LookPath("node")。
2. adapter.go：spi.Adapter 实现。Detect(ctx)：一次性握手采集 protocolVersion/agentInfo；版本!=1 或握手失败→全部能力 unsupported 各带中文原因且 Version 留空。Capabilities()：start/abort/kill=native（kill 因 per-session 进程所有权）；resume=unsupported 原因注明"桥未实现 session/load（实测 -32601）"；permission=emulated 原因说明"决策通道已接通但当前策略为取消而非静默批准"；model_select/question/goal/skill_catalog/plan/permission_mode/attachments/file_read/git_read/usage/fork/delegate_session/delegate_cross_provider=unsupported 带中文原因。Start(ctx,req)：spawn 桥→initialize→session/new(cwd=req.WorkspaceRoot)→返回实现 spi.InstanceIDHandle 的 handle（InstanceID()=sessionId；req.Model 不上 wire，加注释说明模型由桥配置承载）。Resume：返回 unsupported 六态枚举，不得伪装。
3. handle.go：Send(ctx,text)=session/prompt 单文本块；Abort(ctx)=cancel 通知幂等；Events() 缓冲 chan spi.Event；后台读循环把 session/update 经 mapper 转 canonical 事件（未知 variant 计数丢弃不报错）；收到 session/request_permission：先发 spi.EventPermissionRequest 再按 fail-closed 回 {outcome:{type:"cancelled"}}（绝不静默批准）；fs/* 请求回 -32601 错误；Dispose 走 bridge.Close。
4. mapper.go：白名单映射 update 变体→canonical EventType（agent_message_chunk 是桥已提交的完整 assistant content block，映射为 message_completed；无对应类型的丢弃并计数）。所有业务逻辑必须中文注释（用户硬性要求）。
5. fakebridge_test.go：注入 BridgeTransport 接口的内存假桥契约测试：(a)版本不符→Detect 全 unsupported；(b)Start/Send 往返与 message_completed 映射；(c)Abort 幂等；(d)request_permission 收到 cancelled 决策且产出事件；(e)EOF/坏帧容错。真实子进程集成测试单独文件，环境变量 AGENT_SESSIONS_DSH_LIVE=1 门控跳过。另在 internal/adapterreg/registry_test.go 追加新函数（勿动既有用例）：五类聚合与 List 排序稳定。

## 修改 internal/adapterreg/registry.go（当前无未提交改动）
import dsh 包、adapters 表加 `"dsh": dsh.New()`、KnownKinds() 追加 "dsh"。除这三处外不动该文件；不改 spi.go/opencode/ 及其他任何文件。

## 验收（全绿才算完成）
gofmt -l 新改文件为空；go vet ./internal/adapter/dsh/... ./internal/adapterreg/...；go build ./...；go test ./internal/adapter/dsh/... ./internal/adapterreg/... -count=1 通过。禁止网络访问。

## 回复要求
创建/修改文件清单；每条验收命令输出摘要（通过项数）；能力矩阵最终取值列表；自由裁量说明。
