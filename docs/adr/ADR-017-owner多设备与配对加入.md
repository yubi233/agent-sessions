# ADR-017：Owner 多设备模型与配对加入

状态：已接受（2026-09-29）；P1 服务端契约与 P2/P3 移动端已实施（c3545c5 / 0d965ad），P4 双机真机旅程待两台 Android 设备同时在场后执行。关联：ADR-002（设备身份与端到端加密）、ADR-016（会话内容密钥分发）、ADR-012（Terminal 认证）。

## 背景

当前产品是**单 active owner** 模型：owner 设备的唯一上线路径是「恢复码接管」，其语义为互斥替换——同一事务内撤销旧 owner、建立新 owner。用户换机/增购设备时，旧设备必然被踢出，无法实现「日常机 + 测试机并存」。设备初始化（bootstrap）仅在中继**零账号**时开放，已部署实例上不可用。二维码配对仅面向 terminal 角色（PC/daemon）。

## 决策

1. **一个账号允许多台 active owner 设备并存**（N ≥ 1）。既有设备零变化是硬不变量：任何加入路径不得撤销、不得改写既有设备的行、令牌、绑定。
2. **新增「owner 配对」加入路径**（与恢复码接管并存，互不替代）：
   - 新设备在连接页选择「配对到已有 Relay」→ 本机生成 identity/encryption 公钥对 → `POST /v1/pairing/requests`（role=android_owner）→ 获得 pairing_id 并展示 payload（二维码 + 文本）。
   - 现役 owner 在配对页看到 pending 的 owner 请求（含新设备名称与公钥指纹前 8 位）→ 人工确认后批准 → 同一事务内：创建 active owner 设备行、签发 token pair、写审计 `device.paired`（含 role）。
   - 新设备轮询既有 pairing 状态接口领取令牌 → 进入已认证主页。
3. **防滥用（创建端点未认证，必须收紧）**：请求 TTL 10 分钟过期清理；单账号同时最多 1 个 pending owner 请求；批准必须由 active owner 认证态完成；首版加**数字比对确认**（双方各显示 6 位短码，同源自 pairing 密钥材料）；总开关 env `AGENT_SESSIONS_OWNER_PAIRING`（默认 off，云端显式开启）。
4. **撤销语义**：撤销任一非末位 owner 不影响其他 owner；撤销最后一个 active owner 后回到「无 owner」态，此时 bootstrap 重新开放（回到首次部署语义，与既有 `CountAccounts=0` 守卫一致——注意此处开放的是**同账号重新初始化**语义的等价物，实现上以「无 active owner 时允许 bootstrap 重建」表达，不改单账号行）。
5. **恢复码接管语义不变**：仍为互斥替换，用于「换机放弃旧机」场景。
6. **内容密钥（ADR-016）**：owner 批准成功后，daemon 在下一次同步时按新设备的 encryption pubkey 对既有会话 DEK 逐会话补 wrap（`device_key_wraps` 机制已存在，补批量触发）；新会话照常由 daemon 首条命令时 wrap。

## 不变量

- 单账号单租户不变；bootstrap 的「首个 owner」语义在「已有 active owner」时保持关闭。
- 撤销恢复码接管互斥替换语义不变。
- 手机端永远不是被二维码配对的对象——二维码配对仍仅面向 terminal。
- 审计：`pairing.created`（role=android_owner，不含密钥材料）与 `device.paired` 全量落库。

## 后果

- 正面：多设备并存（日常机 + 测试机）、换机可先加新后撤旧（零中断）、测试矩阵不再互相踢。
- 代价/风险：批准一个 owner 即授予全权（控制会话、批准终端、撤销设备、生成恢复码）——误批准 = 完全失陷。缓解：数字比对、批准二次确认、审计、总开关。实现面：pairing 存储需补 role 列（additive 迁移）、配对页需区分角色展示。
