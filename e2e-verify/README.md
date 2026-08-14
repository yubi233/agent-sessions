# 浏览器回归与录屏

本目录统一管理可重复执行的浏览器回归、录屏入口和脱敏报告；不是一次性人工截图目录。

## P0 回归清单

| 测试 ID | 场景 | 前置条件 | 可观察断言 | 命令 |
| --- | --- | --- | --- | --- |
| `P0-TOOL-01` | 本地开发链路 | Go、pnpm、Google Chrome 可用 | Vue 页面由可见 Chrome 打开 | `pnpm --filter @agent-sessions/e2e-verify test` |
| `P0-DEPLOY-01` | Relay + SQLite 就绪 | 测试脚本创建临时 SQLite | 页面显示 `Relay 已就绪`，点击重试后仍保持就绪 | `pnpm --filter @agent-sessions/e2e-verify test` |

`run.mjs` 启动独立 Relay、临时 SQLite 与 Vite 开发服务器。浏览器必须等待页面的 `relay-ready` 状态并点击重试按钮；脚本只关闭自己启动的子进程。所有报告写入 `e2e-verify/reports/<timestamp>/P0/`，不得记录令牌、正文、diff 或解密附件。

## 验证口径

P0 浏览器 gate 使用真实可见 Google Chrome：`real_browser=true`、`headless=false`、`local_test=true`、`fixture_data=true`、`real_upstream=false`、`real_model=false`。

录屏必须在上述回归通过后执行；录屏脚本将另行复用同一用户旅程，不允许用录屏代替断言。
