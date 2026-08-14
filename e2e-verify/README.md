# 可见端到端回归与录屏

`e2e-verify/`是 Agent Sessions 所有可重复 browser/Flutter 本地回归、录屏、脱敏报告和诊断证据的唯一入口。稳定验收 ID 定义在[测试套件索引](../docs/test/测试套件索引.json)，测试范围和口径见[自动化测试文档](../docs/zh/自动化测试文档.md)。

## 当前入口

| 命令 | 场景 | 可见性与证据 |
| --- | --- | --- |
| `task test:e2e` | Web/Admin headed Playwright 回归 | 默认启动系统 Chrome，`real_browser=true`、`headless=false` |
| `node e2e-verify/run.mjs --suite p0-health` | 单个 headed Web smoke | 报告写入 `e2e-verify/reports/<timestamp>/<plan_id>/` |
| `task test:record` | 已通过 browser gate 后的 CDP 录屏 | 帧、manifest、mp4 写入 `e2e-verify/screencasts/<timestamp>/` |
| `task test:flutter:local` | v0.1 MacBook Flutter macOS integration gate | 启动可见桌面窗口；不能由 headless 或 widget 测试替代 |
| `task test:android:e2e` | 后续 Android AVD integration diagnostic | 不属于本轮 v0.1 gate |
| `e2e-verify/mobile/` | MacBook Flutter macOS full gate、后续 AVD 诊断和报告脚本 | 本轮 `run-macos.mjs` 启动可见桌面窗口；Android 原生验收留待后续阶段 |

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

## MacBook Flutter macOS gate

`task test:flutter:local`先运行`e2e-verify/mobile/macos*.test.mjs`的纯 Node 编排回归，再执行一次`flutter build macos --debug --no-pub`。随后运行`apps/mobile/test/`长期 unit/widget 套件；全部断言通过后，runner 直接启动固定 debug 可执行文件，按已登记 fixture 场景在真实 macOS 窗口以 5fps 连续抓取 1 秒 PNG。当前场景为`VISUAL-MOBILE-01..05`与`VISUAL-PAIR-01`：P2 增加会话列表、完整会话详情和只读详情，且必须在录制前由`MACOS_SCREENSHOT_SCENARIOS`固定登记。启动器只给 debug macOS 进程注入`LOCAL_FIXTURE_MODE=true`和固定场景名，并只终止本轮 CoreGraphics 已观测到的 PID；它不再依赖当前 macOS 26/Xcode 26 上不稳定的`flutter run -d macos`设备发现链路。

报告标记`real_browser=false`、`visible_desktop_app=true`、`headless=false`、`host_platform="macos"`、`real_device=false`、`simulated_device=false`。本轮按用户约束可以保存 deterministic fixture 的 QR 与请求标识截图，但绝不启动真实账号、token、恢复码、会话正文、附件或 diff；macOS 结果也不能写成 Android Keystore/Drift 原生通过。`flutter test -d macos`的 native integration 仍因 Flutter open/VM 握手回归留待工具链修复后重启。浏览器验收仍由`task test:e2e`的 headed Chrome 提供。

## 后续 Android AVD diagnostic

`task test:android:e2e`先运行`e2e-verify/mobile/android.test.mjs`的纯编排回归，再发现并执行`apps/mobile/integration_test/**/*_test.dart`。默认行为如下：

1. 仅在 macOS 主机复用已启动的`Nexus_5X_API_32`；不存在时用 Emulator 图形窗口冷启动该 AVD，传入`-no-snapshot -no-audio -no-boot-anim`避免旧快照/CoreAudio 卡死，绝不传`-no-window`或`--headless`。
2. 等待 ADB 设备和`sys.boot_completed=1`，再以`flutter test ... -d <adb-serial> --machine`驱动实际 Android 应用；machine 仅用于脱敏事件统计，不会隐藏模拟器窗口。
3. 将报告写入`e2e-verify/reports/<timestamp>/ANDROID/android-integration-gate.json`。报告标记`real_browser=false`、`real_device=false`、`simulated_device=true`、`headless=false`、`host_platform="macos"`与`browser="n/a"`，因此不会把 AVD 或 Chrome 声明为实机/浏览器验收。
4. 仅在本轮启动 AVD 时才在结束后请求关闭它；复用的用户 AVD 和其他模拟器一律不触碰。传入`--keep-avd`可保留本轮 AVD 用于人工诊断。

可用参数：`--avd <name>`、重复的`--test <apps/mobile-relative-test>`和`--case <stable-test-id>`、`--keep-avd`。本阶段拒绝`--device-id`和`--headless`；录屏不属于此 gate，必须在对应 full gate 通过且录屏用例已登记后单独执行。
