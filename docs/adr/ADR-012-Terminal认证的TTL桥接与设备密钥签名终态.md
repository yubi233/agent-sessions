# ADR-012：Terminal 认证的 TTL 桥接与设备密钥签名终态

- 状态：Accepted（桥接已实施；签名认证协议与兼容窗口已交付；生产 Daemon 进程私钥接线已于 2026-08-26 落地——`daemon keygen` 生成 0600 本机种子文件、配对请求携带真实 `identity_public_key`、`AGENT_SESSIONS_DAEMON_SIGNING_KEY_FILE/B64` 互斥供给、签名类错误 fail-fast 不回退 bearer，测试 ID `RELEASE-V06-02`）
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

### 终态（v0.6 实施中）

Terminal 认证从 bearer 令牌对迁移为**设备密钥挑战签名**（参考 Happy 的架构取向）。v0.6 仅做 additive 协议和兼容窗口，不删除旧 bearer 路径；签名模式未通过完整门禁前不得作为唯一认证方式。

1. 配对时 Terminal 设备生成并保存 Ed25519 身份密钥（ADR-002 已有设备密钥模型）；hello、heartbeat、命令 ack/result、事件上传均携带时间戳 nonce 并以身份私钥签名。
2. Relay 只存公钥与设备状态，校验签名与重放窗口；移除 terminal 角色的 access/refresh 令牌签发与 TTL 逻辑仅在签名模式完全接管后执行。
3. 协议版本走 N/N-1 兼容窗口（ADR-009 第 6 条）：旧 bearer Daemon 在 N-1 内继续可用，超窗返回 `UPGRADE_REQUIRED`。
4. 签名失败不静默回退 bearer；只有明确登记的 N-1 客户端才允许 bearer。
5. 迁移完成后删除 `TerminalAccessTTL` 与本 ADR 的桥接章节事实，回填项目文档。

#### 签名 canonical bytes

v0.6 冻结以下 canonical 拼接规则，任何 handler 不得自行拼接字符串：

```text
protocol_version | device_id | request_method | request_path |
timestamp_ms | nonce | sha256(body) | key_id
```

字段使用 UTF-8 字符串和 `|` 分隔；整数/时间戳使用十进制 ASCII；`body` 为原始请求体字节，空 body 使用 `sha256("")`。Ed25519 签名对象为上述 canonical bytes 的 UTF-8 编码。

`sha256(body)` 的 body 定义（P1 冻结）：签名以 JSON 对象形式存放在请求体的顶层 `signature` 成员中；`body_hash` 覆盖**删除该成员后**的紧凑 UTF-8 JSON 字节，其中顶层成员按键名字典序排列、无多余空白，嵌套值保持发送方序列化原样。两端都不得把 signature 字段纳入哈希——否则签名需要覆盖自身，构成循环依赖。Go/Dart/TypeScript 各端按同一规则实现确定一致的字节。

#### 校验规则

- 时间窗口：`timestamp_ms` 与 Relay 当前时间差不超过 300 秒；超窗返回稳定错误。
- nonce：签名请求的 nonce 必须先在 SQLite 一次性记录中消费，跨 Relay 重启仍可查重；重复 nonce 返回稳定错误。
- hello challenge：hello 的 `nonce` 字段必须使用 Relay 预先签发的一次性 challenge（`GET /v1/daemon/challenge`）。challenge 由 SQLite 持久化并绑定设备，5 分钟有效、只能消费一次；消费与 nonce 记录在同一事务内完成，Relay 重启后未完成/已完成的 challenge 都不能被重复使用。
- 设备状态：设备必须属于该账号、角色为 `terminal`、状态为 `active`；撤销立即拒绝。
- key id：必须对应设备当前已登记且未轮换撤销的 Ed25519 公钥。
- 失败路径不得产生 command 状态变化、lease 变化、事件序号推进或 outbox 副作用。

#### N/N-1 与回滚

- 签名模式通过 capability/feature flag 开启；默认保留已验证 bearer bridge。
- Relay 以 `terminal_signature_mode=off|optional|required` 表达窗口进度：`optional` 为兼容窗口（签名可选、bearer 可用），`required` 表示窗口结束——旧 bearer Daemon 的 hello/heartbeat/ack/result/event 一律返回稳定 `UPGRADE_REQUIRED`，不再接受。
- hello 响应以 additive 字段 `auth_modes` 声明当前接受的认证方式（如 `["bearer","signature_v1"]`）；Daemon 据此决定是否升级，不得自行猜测。
- 兼容窗口内旧 bearer Daemon 可继续 hello/heartbeat/ack/result/event。
- 回滚时把 signature mode 降回 `optional`/`off`，旧 bearer 路径立即恢复；不删除设备公钥、命令、事件或 outbox 历史。
- 密钥轮换只允许旧/新 key 在短暂窗口内双读，一写；新 key 完成首次成功签名后旧 key 标记为轮换撤销（`retired`），撤销立即拒绝新签名。
- 所有回滚操作必须重新执行签名失败、设备撤销、命令幂等和 outbox 重放测试。

## 后果

- restart.sh 本地栈不再出现"运行 15 分钟后 Daemon 静默消失"；命令不再滞留 accepted。
- 双端需要共享测试向量：签名覆盖的字节序列、nonce 格式与重放窗口必须进入协议向量测试。
- Android/Web 不受影响：owner/web 角色继续使用现有令牌轮换。
- 若在迁移前出现多机共享 state 目录等新部署形态，必须重新评估桥接 TTL，不能默认沿用。
