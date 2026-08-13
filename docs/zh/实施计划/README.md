# 分项目实施计划

这里的文档把总控计划拆成可并行执行的项目计划。权威产品边界仍是上级目录的[项目文档](../项目文档.md)，阶段依赖仍由[总实施计划](../实施计划.md)统一管理。

## 阅读顺序

1. [00-总控计划](00-总控计划.md)：确认里程碑、依赖、分支和交付节奏。
2. [01-协议与密码学](01-协议与密码学.md)：先冻结跨端事实源和密钥边界。
3. [02-Relay 身份、设备与持久化](02-Relay身份设备与持久化.md) 与 [03-Relay 实时会话与同步](03-Relay实时会话与同步.md)。
4. [04-Daemon 核心与 Workspace 安全](04-Daemon核心与Workspace安全.md) 与 [05-Daemon Git 只读服务](05-Daemon-Git只读服务.md)。
5. [06-Adapter 平台与 Mock 运行时](06-Adapter平台与Mock运行时.md)，再并行阅读 [07-Claude](07-Adapter-Claude.md)、[08-Codex](08-Adapter-Codex.md)、[09-OpenCode](09-Adapter-OpenCode.md)、[10-OpenClaw](10-Adapter-OpenClaw.md)。
6. [11-Android 移动控制端](11-Android移动控制端.md)、[12-Web 只读客户端](12-Web只读客户端.md)、[13-Admin 运维平台](13-Admin运维平台.md)。
7. [16-跨工具子代理派发](16-跨工具子代理派发.md)：产品层 Delegation，不依赖 Provider 原生 sub-agent。
8. [14-测试验证与质量门禁](14-测试验证与质量门禁.md) 与 [15-部署发布与灾备](15-部署发布与灾备.md)：从第一天建立，最后汇合。

## 共同规则

- 每个子计划中的工作包都必须有输入、输出、依赖、测试 ID、证据路径、退出条件和回滚点。
- `planned`、`in_progress`、`passed`、`incomplete`、`blocked` 状态只在测试/证据报告中改变；文档完成不等于功能完成。
- 所有跨项目接口以 `packages/protocol` 为唯一事实源；子项目不得复制 DTO 或私自扩展事件。
- 所有真实 Provider、模型、Android 真机、签名发布和生产部署都必须明确授权；没有凭据时保留 blocked，不用 fixture 冒充真实通过。
- 修改公开协议、权限、数据迁移、启动命令或验收 ID 时，必须同步更新总控计划、项目文档、自动化测试文档和 ADR。

## 唯一事实源与所有权

- `01-协议与密码学.md` 独占 OpenAPI、JSON Schema、错误码、能力枚举、envelope 和 crypto vectors。
- `02-Relay身份设备与持久化.md` 独占认证、设备授权、迁移、token 和服务器元数据权限；`03-Relay实时会话与同步.md` 独占命令、ControlLease、SSE、WebSocket、cursor 和 outbox。
- `04-Daemon核心与Workspace安全.md` 独占本地进程、SQLite、Keychain、项目登记和路径安全；`05-Daemon-Git只读服务.md` 独占 Git parser、snapshot token 和只读 RPC。
- `06-Adapter平台与Mock运行时.md` 独占 Adapter SPI、能力状态和 mock；`07` 至 `10` 各自独占一个真实 Provider 的协议、版本矩阵和 live gate。
- `11-Android移动控制端.md` 独占 Android 写意图、缓存、生命周期、通知和 DiffView；`12-Web只读客户端.md` 和 `13-Admin运维平台.md` 分别独占两个 Vue 应用。
- `16-跨工具子代理派发.md` 独占 Delegation 状态机、跨 Provider 派发器和父子 Session 图；各 Adapter 只证明自身 Session 能力。
- `14-测试验证与质量门禁.md` 独占测试 ID 注册、fixture 归属、断言、证据和覆盖审计；`15-部署发布与灾备.md` 独占可运行部署脚本、迁移、备份和发布产物。
- 根目录的 [实施计划](../实施计划.md) 是 P0-P5 阶段总览；本目录文件是执行级计划。两者冲突时先更新总控，再更新子计划，不允许各自维护另一套事实。
- 测试 ID 的实际唯一注册表是[测试套件索引](../../test/测试套件索引.json)；`基础验收用例.json` 只消费领域 suite 的 ID，不能重新定义归属。

旧的 [Relay 服务与管理平台专题计划](../实施计划-Relay服务与管理平台.md) 已降级为归档指针，不再作为实施依据。

## 并行规则

协议生成和加密 vectors 冻结后，Relay、Daemon 本地安全/Git、Web/Admin fixture 页面和 Android mock UI 可以并行；真实 Provider 仍依赖 Daemon SPI；full gate 在所有消费方汇合后执行。

## 子计划完成模板

```text
目标与不做项
依赖与输入
工作包 W0..Wn
输出文件/API/迁移/构建产物
测试 ID、命令和证据路径
退出条件
回滚点与阻塞条件
```

完整模板见[模板.md](模板.md)。
