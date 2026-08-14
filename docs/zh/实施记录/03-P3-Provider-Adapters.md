# P3 四类 Provider Adapter

> 状态：`done`（fixture/contract；live gate 为 `blocked`）  
> 开始日期：2026-08-14  
> 完成日期：2026-08-14  
> 对应计划：[Adapter 平台](../实施计划/06-Adapter平台与Mock运行时.md)、[Claude](../实施计划/07-Adapter-Claude.md)、[Codex](../实施计划/08-Adapter-Codex.md)、[OpenCode](../实施计划/09-Adapter-OpenCode.md)、[OpenClaw](../实施计划/10-Adapter-OpenClaw.md)

## 实施总结（2026-08-14）

四类 Provider 各自交付独立的 `internal/adapter/<kind>/` 包，实现统一 SPI 的 `Detect`/`Capabilities`/`Start`/`Resume`：

- 每个 Adapter 通过环境变量探测可执行/地址（`AGENT_SESSIONS_*_BIN/URL`），未配置时仅返回安全能力子集，绝不伪造 native。
- 能力矩阵遵循 native/emulated/unsupported 三态，未知能力（如 `delegate_cross_provider`）一律 unsupported。
- `internal/adapterreg` 聚合四类 Provider，供 `/v1/capabilities` 输出；客户端据此渲染入口，不按 Agent 类型硬编码。
- `Start`/`Resume` 尚未接入真实传输，明确返回 unsupported；真实 CLI/Gateway 集成与授权 live smoke（ADPT-*-04）标记 `blocked`，等待真实凭据与协议 fixture。

## 覆盖的测试 ID

`ADPT-CLAUDE-01/02`、`ADPT-CODEX-01/02`、`ADPT-OPENCODE-01/02`、`ADPT-OPENCLAW-01/02`（能力矩阵与 SPI 契约）、`ADPT-01`、`MODE-04`。live smoke（`ADPT-*-04`）与 permission/plan/goal/skill 细分（`ADPT-*-03`）因缺少真实 Provider 凭据与完整协议而标记 `blocked`/`incomplete`。

## 验证口径

`local_test=true`、`fixture_data=true`（能力矩阵 fixture）、`real_upstream=false`、`real_model=false`、`headless=false`。真实 Provider live gate 需要授权与凭据，按计划标记 `blocked`，不伪造通过。

## 残余风险

- 真实 Provider 版本矩阵、resume handle、权限审批与 skills 未在本地证明；需在授权环境中用真实二进制完成 live smoke 后才能宣称 native。
- OpenCode/OpenClaw 依赖本地服务/Gateway 可用性，发布时需纳入版本矩阵。
