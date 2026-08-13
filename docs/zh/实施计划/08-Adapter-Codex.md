# Codex Adapter 实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ADAPTER-CODEX` |
| owner | Codex Adapter |
| status | `planned` |
| target | M4 / P3 |
| protocol_revision | `DAEMON-SPI@v1-draft` |
| adr | ADR-004、ADR-006 |

## 1. 目标与明确排除项

通过 Codex app-server JSON-RPC/stdio 的明确支持边界实现 thread resume、stream、审批、skills 与模式映射。不得用 CLI 文本 scraping 代替稳定协议，也不得要求 Relay 读取内容。

## 2. 进入条件、输入和依赖

依赖 `ADAPTER-PLATFORM`、本机 Codex app-server 版本/协议证据和确定性 JSON-RPC fixtures。真实 live smoke 必须单独授权；无授权只交付 fixture/unsupported。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 JSON-RPC transport | SPI/fixture | process lifecycle、request IDs、cancel、JSON-RPC error 分类 | typed stdio client | `ADPT-CODEX-01` | contract | RPC fixture trace | `codex` flag off |
| W2 thread/session 映射 | W1 | start/resume/send/abort、thread handle persistence、delta/tool/final mapping | adapter mapper | `ADPT-CODEX-02` | contract | golden trace | mock/unsupported fallback |
| W3 approval/skills/mode | W2 | 审批、skills、plan/goal/model/effort capability 探测 | capabilities evidence | `ADPT-CODEX-03` | contract | matrix report | per-capability disable |
| W4 live smoke | W1-W3、授权 | 最小本机 workspace、限量请求、显式 stop | live/blocked report | `ADPT-CODEX-04` | authorized upstream | scrubbed report | abort child process |

## 4. 数据、权限、错误和事件边界

所有 JSON-RPC 参数/结果经 canonical mapper 后才离开 Daemon；审批请求带原始 command correlation、deadline 和当前 lease。未知方法/版本必须安全降级。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

计划命令为 `task test:contract -- provider=codex` 和经授权的 `task test:real -- provider=codex`。fixture 先覆盖 stdio/JSON-RPC 的取消和未知方法；live smoke 严格限制一个隔离 Workspace 和最小请求数。

## 6. 退出条件、阻塞和残余风险

退出：四个 `ADPT-CODEX-*` fixture contract 可重复，能力状态不伪造，live gate 有真实证据或 blocked 标记。回滚：feature flag 隔离。阻塞：app-server 协议不稳定、无明确授权或需要服务端明文。

## 7. 文档回填清单

回填 Codex 版本矩阵、RPC fixture revision、thread mapping 和能力差异。
