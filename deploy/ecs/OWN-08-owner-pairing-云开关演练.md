# OWN-08 云端开关演练 runbook（v0.10.0，ADR-017）

> 目的：云端 Relay（https://39.106.135.11，ECS Docker + Caddy 自签 TLS）部署
> v0.10.0 后，实证 owner 配对加入的总开关治理：
>   - OWN-08：开关**关闭**时，未认证创建端点稳定 403/SCOPE_DENIED；
>   - 开关**开启**后：创建 201（比对码）→ 单 pending 409 → 真机批准 → 领取令牌。
>
> 前置（用户动作）：SSH 窗口重开（隧道 `ssh -N -L 18787:127.0.0.1:8787`，令牌至
> 2026-10-17）；窗口内 ECS 可登录。

## 阶段 A：部署 v0.10.0（开关保持关闭）

1. ECS 上更新检出并重建容器（迁移自动执行：`pairing_requests` 补 claim 列 +
   部分唯一索引，`Migrate()` 启动时收口）：
   ```bash
   cd <ecs 检出目录> && git pull
   docker compose -f deploy/ecs/docker-compose.yml up -d --build
   ```
2. 冒烟：`deploy/ecs/smoke.sh https://39.106.135.11 <指纹>`（指纹见
   `deploy/acceptance.env` 的 `AGENT_SESSIONS_ACC_TLS_FINGERPRINT`）。
3. **OWN-08 关闭态断言**（本机执行；无需任何设备/凭据）：
   ```bash
   curl -sS -X POST https://39.106.135.11/v1/owner-pairing/requests \
     -H 'Content-Type: application/json' \
     -d '{"display_name":"own08-probe","platform":"probe",
          "identity_public_key":"own08-identity","encryption_public_key":"own08-encryption"}'
   # 期望：403 {"code":"SCOPE_DENIED","message":"owner pairing disabled"}
   ```
   归档：报告落 e2e-verify/reports/<ts>/OWN-08/（status=passed，real_upstream=true，
   附响应原文；不含密钥）。

## 阶段 B：开启开关并实证加入链路（可复用双机旅程）

4. compose 的 relay 服务 environment 增加：
   ```yaml
   AGENT_SESSIONS_OWNER_PAIRING: "on"
   ```
   再次 `up -d`（容器重建，数据卷不动）。
5. 开启态探针：同一 curl 期望 **201**（`pairing_id` + 6 位 `compare_code`）；
   立即重复一次期望 **409**（单 pending 治理）。
6. 真机加入（与 OWN-06 同路径，云端口径）：
   ```bash
   node e2e-verify/mobile/run-android-pair.mjs --no-stack \
     --lan-ip <不需要——直连云端> ...   # 或用 run-android-device.mjs --endpoint
   ```
   最小真机路径（单设备即可）：`task test:android:device -- --endpoint
   https://39.106.135.11 --tls-fingerprint <指纹>
   --test integration_test/own06_pair_joiner_test.dart`——joiner 创建请求；
   owner 侧批准用现有真机（23113RKC6C，云端 APK）配对页操作；批注
   real_upstream=true。
7. 收尾：如需公网默认收紧，把开关改回 off 并 `up -d`（ADR-017 D1：默认 off）。

## 注意

- 全程**不要**动本地主栈（soak）。
- 云端 DB 是生产库：阶段 B 的探针会在 `pairing_requests` 留一条 pending 行，
  10 分钟 TTL 过期由既有清理收口；无需手工清理（如要立刻清，走配对页取消）。
- 阶段 A 完成即满足 OWN-08 的「总开关关闭拒绝」验收；阶段 B 视窗口时间与
  设备情况执行（不阻塞 OWN-08 关闭态验收的归档）。
