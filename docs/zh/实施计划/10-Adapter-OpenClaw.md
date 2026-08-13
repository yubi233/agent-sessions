# OpenClaw Adapter 实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ADAPTER-OPENCLAW` |
| owner | OpenClaw Adapter |
| status | `planned` |
| target | M4 / P3 |
| protocol_revision | `DAEMON-SPI@v1-draft` |
| adr | ADR-004、ADR-006 |

## 1. 目标与明确排除项

通过 OpenClaw Gateway WebSocket challenge、device auth 和 scoped RPC 实现 chat stream、thinking/tool/final/error、abort 和 skills 映射。Gateway 认证在 Daemon 内完成，手机只接收统一状态和确认卡。

不直接把 Gateway 凭据传给 Relay/Android，不开放任意 RPC，不把 challenge 失败弱化为已授权。

## 2. 进入条件、输入和依赖

依赖 `ADAPTER-PLATFORM`、Daemon Keychain/进程监督、OpenClaw Gateway 协议证据和 fixture。真实 Gateway 连接和模型调用需单独授权。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 challenge/device auth | SPI、Gateway fixture | WebSocket challenge、device auth、token lifecycle、scoped RPC allowlist | gateway client | `ADPT-OPENCLAW-01` | contract | auth trace | `openclaw` flag off |
| W2 chat/session events | W1 | chat start/resume/send/abort，delta/thinking/tool/final/error 映射 | canonical mapper | `ADPT-OPENCLAW-02` | contract | golden trace | mock/unsupported fallback |
| W3 skills/capabilities | W2 | skill catalog/invoke、permission/question/plan/goal capability 检测 | capabilities table | `ADPT-OPENCLAW-03` | contract | matrix report | per-capability disable |
| W4 live smoke | W1-W3、授权 | 限制 scope 的真实 Gateway 连接、最小请求、device auth cleanup | live/blocked report | `ADPT-OPENCLAW-04` | authorized upstream | scrubbed report | revoke local device/session |

## 4. 数据、权限、错误和事件边界

Gateway challenge、device credential 和上游 token 只在 Daemon Keychain/内存中；所有 RPC 经过方法 allowlist、workspace/session scope 和 deadline 校验。Gateway 私有 payload 不进入公共 schema。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

计划命令为 `task test:contract -- provider=openclaw` 和经授权的 `task test:real -- provider=openclaw`。先做 Gateway challenge/device-auth fixture diagnostic；live smoke 使用 scope 受限设备并在结束时撤销本地会话。

## 6. 退出条件、阻塞和残余风险

退出：challenge/device auth、chat/abort、skills 和能力三态有 fixture contract；真实 Gate 有授权证据或 blocked 状态。回滚：单独禁用 OpenClaw adapter，保留其他 Session 历史。阻塞：没有有效协议证据、设备认证不可安全保存、或需要 Relay 保存凭据。

## 7. 文档回填清单

回填 Gateway 支持版本、RPC allowlist、device credential 生命周期和 fixture/live gate 结果。
