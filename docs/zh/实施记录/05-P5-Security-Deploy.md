# P5 安全、性能、灾备与发布门禁

> 状态：`done`（本地可验证门禁；真实签名/上传/生产备份目标标记 `blocked`）  
> 开始日期：2026-08-14  
> 完成日期：2026-08-14  
> 对应计划：[部署发布与灾备](../实施计划/15-部署发布与灾备.md)

## 实施总结（2026-08-14）

- **灾备与恢复（`internal/deploy`）**：SQLite `VACUUM INTO` 在线备份、恢复、`PRAGMA integrity_check` 完整性校验与事件序号单调校验、权威表 schema 校验；`apps/deployctl` CLI（backup/restore/integrity/scan）。
- **安全门禁（`internal/securityscan`）**：明文泄漏扫描（token/密钥/恢复码等），跳过测试夹具与已审阅 allowlist 路径，命中即失败；`deployctl scan` 作为 gate。
- **部署**：`deploy/docker-compose.yml`（Relay + SQLite 卷 + healthcheck）与多阶段 `deploy/Dockerfile`。
- **Taskfile**：新增 `test:deploy`（备份/完整性/泄漏扫描 gate）、`deploy:backup`、`deploy:restore`、`deploy:scan`。
- **可靠性回归**：outbox 跨 Relay 重启重放且幂等键不重复（SYNC-02）、lease 竞争下 epoch 递增/唯一写端（PERF-03）。

## 覆盖的测试 ID

`DEPLOY-02`（备份）、`DEPLOY-03`（恢复演练完整性）、`SYNC-02`（重启 outbox 重放）、`PERF-03`（lease 竞争）、`SEC-01`（泄漏扫描无明文）。`DEPLOY-04`（签名/SBOM）、真实签名与上传、生产备份目标与 `PERF-01/02` 大负载标记 `blocked`/`incomplete`（需授权与真实环境）。

## 验证口径

`local_test=true`、`fixture_data=true`（隔离 SQLite）、`real_upstream=false`、`real_model=false`、`headless=false`。备份/恢复在隔离临时库演练；未触达生产数据。

## 残余风险

- 签名、SBOM、容器漏洞扫描、生产备份目标与 RPO/RTO 实测需授权与真实环境，标记 `blocked`。
- 大消息/大 diff 背压（PERF-01/02）需真实负载环境验证，标记 `incomplete`。
- 泄漏扫描对 DTO 字段（refresh_token 等）使用显式 allowlist，任何新增敏感字段须登记并复核。