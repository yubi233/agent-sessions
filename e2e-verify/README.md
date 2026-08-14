# 可见端到端回归与录屏

`e2e-verify/`是 Agent Sessions 所有可重复 browser/AVD 回归、录屏、脱敏报告和诊断证据的唯一入口。稳定验收 ID 定义在[测试套件索引](../docs/test/测试套件索引.json)，测试范围和口径见[自动化测试文档](../docs/zh/自动化测试文档.md)。

## 当前入口

| 命令 | 场景 | 可见性与证据 |
| --- | --- | --- |
| `task test:e2e` | Web/Admin headed Playwright 回归 | 默认启动系统 Chrome，`real_browser=true`、`headless=false` |
| `node e2e-verify/run.mjs --suite p0-health` | 单个 headed Web smoke | 报告写入 `e2e-verify/reports/<timestamp>/<plan_id>/` |
| `task test:record` | 已通过 browser gate 后的 CDP 录屏 | 帧、manifest、mp4 写入 `e2e-verify/screencasts/<timestamp>/` |
| `task test:android:e2e` | v0.1 Android AVD full gate | P1 建立脚本后可用；不能由 widget 测试替代 |
| `e2e-verify/mobile/` | Android AVD/真机启动、报告和录屏脚本 | P1/P6 创建；命令由 `Taskfile.yml` 统一转发 |

不要使用不存在的`pnpm --filter @agent-sessions/e2e-verify test`命令；当前 package 公开的是`test:e2e`，推荐始终从根目录`task test:e2e`运行。

## 已注册浏览器场景

| 测试 ID | 场景 | 前置条件 | 可观察断言 | 命令 |
| --- | --- | --- | --- | --- |
| `P0-TOOL-01`、`P0-DEPLOY-01` | Relay 就绪状态页 | 脚本创建隔离 SQLite Relay | 可见页面显示 ready，点击刷新后仍就绪 | `task test:e2e` |
| `WEB-01` | 只读 Web 登录和能力矩阵 | 隔离 Relay 与测试账号 | 设备/会话/能力显示，页面没有写入口 | `task test:e2e` |
| `ADMIN-01`、`ADMIN-05` | Admin 脱敏只读视图 | 隔离 Relay 与测试账号 | 不显示正文/密钥/写控件 | `task test:e2e` |
| `E2E-DELEG-01` | Android/Chrome delegation 演示 | `DELEG-01..07` full gate 已通过 | 只显示摘要、确认和子会话切入 | P6 的 `task test:record` |

## 录屏门槛

录屏不是测试替代物。启动录屏前必须满足：

1. 对应结构化用例已登记在`docs/test/`。
2. 本轮根因层和 full gate 已通过，报告内标明测试 ID。
3. manifest 记录浏览器或 AVD、`headless`、fixture revision、命令和脱敏规则。
4. 视频、帧、报告、trace 中不含 token、密钥、会话正文、diff 正文或解密附件。

`run.mjs`只停止自己启动的 Relay/Vite 子进程。可见浏览器默认选择系统 Chrome；显式`--headless`只允许 CI/快速回归，不能作为本轮用户可见验收依据。
