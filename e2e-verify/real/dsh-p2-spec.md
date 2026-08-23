# DSH 适配器 P2 实施规格：进程所有权与 Resume 回归

仓库：/Users/yubi/code/agentProject/agent-sessions。先读：internal/adapter/dsh/{bridge,adapter,handle}.go、internal/adapter/dsh/fakebridge_test.go、docs/adr/ADR-013-DeepSeek-Harness-Provider接入.md。

## 目标
为 per-session 子进程拓扑补齐进程所有权回归（对齐 SESS-05 断言风格），并把 Resume 六态定级固化为显式用例。纯 Go 实现，子进程用 `/bin/sh` 脚本，不依赖 node/DSH checkout；单个用例运行时长必须 <5s。

## 允许的产品代码改动（最小局部重构）
仅 internal/adapter/dsh/bridge.go：若宽限期(当前固定 10s)不可注入，则为其增加可配置项（保持缺省值 10s 与既有调用点不变），并加中文注释说明用途。除此之外不得改任何产品文件。

## 新建 internal/adapter/dsh/process_test.go（全部中文注释）
1. TestForceKillTerminatesWholeProcessGroup：启动 sh 脚本（后台再 spawn 一个 sleep 孙进程后自身长睡），经 transport.ForceKill 后断言：主进程与孙进程均消失（按 pid 探活），重复 ForceKill 幂等不报错。
2. TestDisposeGracefulExitOnEOF：正常子进程读到 EOF 自行退出；Dispose 返回后进程已退出且未触发 SIGKILL 路径。
3. TestDisposeEscalatesToKillWhenChildIgnoresEOF：子脚本忽略 stdin 关闭持续长睡；把宽限期调短(如 200ms)；Dispose 后进程被强杀，耗时 >= 宽限期。
4. TestEventsChannelClosedAfterDispose：Dispose 后 Events() 通道最终关闭。
5. TestStderrRingBufferCapsAndRedacts：子进程向 stderr 输出超长行(>8KiB)与伪造 sk-xxxx 形态密钥；断言采集摘要中存在截断标记、单行不超过上限、完整原文不出现在缓冲导出中（若 ring 无导出方法则补一个仅测试可见的导出或快照函数，加注释说明仅供诊断脱敏使用）。
6. TestResumeAlwaysUnsupported：adapter.Resume 对任意输入恒返回 WakeUnsupported 且不产生子进程。

## 验收（全绿才算完成）
gofmt -l 新改文件为空；go vet ./internal/adapter/dsh/...；go build ./...；go test ./internal/adapter/dsh/... -count=1 通过且总时长 <60s。禁止网络访问。不改 registry/spi/opencode 及其他文件。

## 回复要求
创建/修改文件清单；产品代码改动点（若有）；每条验收命令输出摘要；各用例实测时长；自由裁量说明。
