# P3 四类 Provider Adapter

> 状态：`in_progress`（fixture/contract；OpenCode CLI live smoke 已通过，Adapter transport 未实现）
> 开始日期：2026-08-14  
> 完成日期：2026-08-14  
> 对应计划：[Adapter 平台](../实施计划/06-Adapter平台与Mock运行时.md)、[Claude](../实施计划/07-Adapter-Claude.md)、[Codex](../实施计划/08-Adapter-Codex.md)、[OpenCode](../实施计划/09-Adapter-OpenCode.md)、[OpenClaw](../实施计划/10-Adapter-OpenClaw.md)

## 实施总结（2026-08-14）

四类 Provider 各自交付独立的 `internal/adapter/<kind>/` 包，实现统一 SPI 的 `Detect`/`Capabilities`/`Start`/`Resume`：

- 每个 Adapter 通过环境变量探测可执行/地址（`AGENT_SESSIONS_*_BIN/URL`），未配置时仅返回安全能力子集，绝不伪造 native。
- 能力矩阵遵循 native/emulated/unsupported 三态，未知能力（如 `delegate_cross_provider`）一律 unsupported。
- `internal/adapterreg` 聚合四类 Provider，供 `/v1/capabilities` 输出；客户端据此渲染入口，不按 Agent 类型硬编码。
- `Start`/`Resume` 尚未接入真实传输，明确返回 unsupported；OpenCode 的配置地址过去会错误地将部分能力标为 native，本轮已改为 fail-closed：未接入 transport 时全部显示 unsupported 并给出原因，避免客户端显示无法兑现的写入口。

## 覆盖的测试 ID

`ADPT-CLAUDE-01/02`、`ADPT-CODEX-01/02`、`ADPT-OPENCODE-01/02`、`ADPT-OPENCLAW-01/02`（能力矩阵与 SPI 契约）、`ADPT-01`、`MODE-04`。`ADPT-OPENCODE-04`已在本机 OpenCode Go 的`opencode-go/deepseek-v4-flash`上通过授权 CLI smoke；`HAPPY-OPENCODE-01`以同一真实模型确认最高优先级缺口为`provider_transport`。两项都不替代`ADPT-OPENCODE-01/02/03`的本地 API/WS/SSE、session 和能力 contract。Claude、Codex、OpenClaw 的 live smoke 与各 Provider 的 permission/plan/goal/skill 细分仍为`blocked`/`incomplete`。

## 验证口径

fixture/contract 保持`local_test=true`、`fixture_data=true`、`real_upstream=false`、`real_model=false`、`headless=false`。OpenCode live smoke 报告为`local_test=true`、`fixture_data=false`、`real_upstream=true`、`real_model=true`、`real_browser=false`、`headless=false`；它只使用临时空目录、`--pure`和无工具 prompt，报告不保存凭据、原始 prompt、回复或 session ID。

## 残余风险

- OpenCode CLI 已证明真实模型可用，但`internal/adapter/opencode`仍未接入 HTTP/SSE/WS 的 create/send/abort、canonical event stream、session handle 持久化和 resume；移动端真实控制仍是 P0，不能宣称 native。
- Claude、Codex、OpenClaw 的真实版本矩阵、resume handle、权限审批与 skills 未在本地证明；需在授权环境中完成各自 live smoke 后才能宣称 native。
- OpenCode/OpenClaw 依赖本地服务/Gateway 可用性，发布时需纳入版本矩阵。Happy Mobile 的功能差距与优先级见[专题实施记录](07-HappyMobile功能对比与OpenCode验证.md)。
