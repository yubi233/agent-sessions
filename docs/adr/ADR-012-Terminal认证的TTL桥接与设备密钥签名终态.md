# ADR-012：Terminal 认证的 TTL 桥接与设备密钥签名终态

- 状态：Accepted（桥接已实施；签名认证终态列入后续迭代）
- 日期：2026-08-23

## 背景

本地开发栈（restart.sh）中 Daemon 在启动恰好 15 分钟后退出：`AccessTTL = 15 * time.Minute`，而 `RunWithRetry` 把 hello/heartbeat 收到的 401 视为不可恢复错误直接终止进程。诊断同时确认：

- `RequireAuth` 对每个请求执行 `AccessTokenByValue` 查库，并校验绑定设备的账号、角色与 `DeviceActive` 状态；撤销即时生效，TTL 只影响陈旧行清理。
- refresh token 是单次轮换 + 重用检测（reuse 即吊销整个 family）。Daemon 与 restart.sh 若各自刷新同一 family，后刷的一方会触发 reuse 检测把对方断链；因此"谁持有 family"必须有唯一写者。
- 无头 Daemon 的凭据与其状态目录同域存储：攻击者能读 access token 即能读 refresh token 或未来私钥。短 TTL 对该角色的边际安全价值趋近于零；真正的内容安全边界是 E2EE DEK 包装（ADR-002），不是路由层凭据寿命。

## 决策

### 桥接（已实施）

按角色区分访问令牌寿命：`terminal` 角色 24 小时，`android_owner`、`web` 等交互角色维持 15 分钟轮换。实现于 `internal/authz`（`AccessTTLOf`）并在唯一签发点 `persistAccessWithRepo` 生效；refresh 路径经 token family 的 role 自动继承。

- 不改变撤销语义：设备撤销仍逐请求即时生效。
- 不引入 Daemon 侧刷新机制：避免与 restart.sh 的配对缓存形成双写者竞争。
- 该桥接是过渡态，不得据此把长 TTL 扩散到其他角色或生产部署假设。

### 终态（后续迭代，v0.6 候选）

Terminal 认证从 bearer 令牌对迁移为**设备密钥挑战签名**（参考 Happy 的架构取向）：

1. 配对时 Terminal 设备生成并保存 Ed25519 身份密钥（ADR-002 已有设备密钥模型）；hello、heartbeat、命令 ack/result、事件上传均携带时间戳 nonce 并以身份私钥签名。
2. Relay 只存公钥与设备状态，校验签名与重放窗口；移除 terminal 角色的 access/refresh 令牌签发与 TTL 逻辑。
3. 协议版本走 N/N-1 兼容窗口（ADR-009 第 6 条）：旧 bearer Daemon 在 N-1 内继续可用，超窗返回 `UPGRADE_REQUIRED`。
4. 迁移完成后删除 `TerminalAccessTTL` 与本 ADR 的桥接章节事实，回填项目文档。

## 后果

- restart.sh 本地栈不再出现"运行 15 分钟后 Daemon 静默消失"；命令不再滞留 accepted。
- 双端需要共享测试向量：签名覆盖的字节序列、nonce 格式与重放窗口必须进入协议向量测试。
- Android/Web 不受影响：owner/web 角色继续使用现有令牌轮换。
- 若在迁移前出现多机共享 state 目录等新部署形态，必须重新评估桥接 TTL，不能默认沿用。
