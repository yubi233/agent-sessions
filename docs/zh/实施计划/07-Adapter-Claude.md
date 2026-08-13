# Claude Adapter 实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `ADAPTER-CLAUDE` |
| owner | Claude Adapter |
| status | `planned` |
| target | M4 / P3 |
| protocol_revision | `DAEMON-SPI@v1-draft` |
| adr | ADR-004、ADR-006 |

## 1. 目标与明确排除项

通过 Claude 官方支持的本地 SDK 或 stream-json 接口实现 detect、start、resume、send、abort、权限、计划、goal 与 skills 的能力探测和 canonical 映射。只使用明确支持的进程/API 边界；PTY 只能作为标记的兼容降级路径。

不修改 Relay、公共 schema 或其他 Provider；不能把未验证的 Claude 功能写成 `native`。

## 2. 进入条件、输入和依赖

- `ADAPTER-PLATFORM` SPI、fixture harness、能力枚举稳定。
- 已记录受测 Claude 版本、官方/本机协议证据和合法测试安装方式。
- 真实 live smoke 需要用户授权、凭据和额度；缺失时只做 fixture，结果为 `real_upstream=false`。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 探测与版本矩阵 | platform SPI | 安装/版本探测、最低版本、未知版本安全降级 | `Detect/Capabilities`、matrix file | `ADPT-CLAUDE-01` | contract | version report | `claude` feature flag off |
| W2 会话与事件 | W1、fixture | start/resume/send/abort，映射 stream/turn/tool/final/error | typed client、golden trace | `ADPT-CLAUDE-02` | contract | fixture trace | unsupported/mock fallback |
| W3 交互能力 | W2 | permission/question/plan/goal/skill 探测和映射；无法保真时标 emulated/unsupported | capability table | `ADPT-CLAUDE-03` | contract | capability report | 单能力 flag off |
| W4 live smoke | W1-W3、授权 | 单受控 workspace、最小请求、停止点和脱敏报告 | live evidence 或 blocked record | `ADPT-CLAUDE-04` | authorized upstream | smoke report | 立即中止进程，保留 fixture gate |

## 4. 数据、权限、错误和事件边界

原生 thread handle 仅以本机加密状态/协议密文保存；权限请求必须等待 Android 决策并校验 deadline/lease。未知 stream 字段记录为脱敏兼容错误，不进入公共 payload。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

计划命令为 `task test:contract -- provider=claude` 和经授权的 `task test:real -- provider=claude`。先执行 fixture smoke/diagnostic，再在隔离 Workspace 运行最小 live smoke；没有授权时不执行真实请求。

## 6. 退出条件、阻塞和残余风险

退出：fixture contract 覆盖版本缺失、未知版本、start/resume/send/abort、权限和能力三态；授权时 live smoke 有独立证据，否则明确 `blocked`。回滚：关闭 Claude feature flag 不影响其他 provider/session history。阻塞：无协议证据、上游漂移、需服务器明文或 PTY 作为唯一方案。

## 7. 文档回填清单

回填版本矩阵、fixture revision、能力证据、最低版本和 live gate 状态。
