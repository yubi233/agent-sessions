#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OWN-06 云端收口·修复：pairing_requests 补 claim_device_id 列与单 pending 唯一索引
#
# 现场发现（2026-09-30）：云端 relay.db 的 schema_migrations 已登记全部 77 个
# 版本（含 v0.10.0 的 claim 三列 + 单 pending 唯一索引），但
# pairing_requests 实际只有 claim_access_token / claim_refresh_token 两列，
# claim_device_id 缺失，唯一索引也缺失。relay 每次启动看到版本已登记即跳过
# （migrateWith 的版本闸门优先于列探测），永不自愈；后果：
#   - PairingByID 无条件 SELECT claim_device_id → SQL 报错 →
#     GET /v1/pairing/requests/:id 500、cancel 404、approve 500，
#     OWNER-06 云端批准/领取链路全断；
#   - 无唯一索引时单 pending 约束只剩 CountPendingOwnerPairings 应用层检查。
# 根因推断：该库经 v092 备份恢复链替换（stage/relay.db.bak-v09210 尺寸吻合），
# 替换源已带 77 版本登记行但物理缺列——恢复工具未校验「版本表 vs 实态」一致性。
#
# 本脚本幂等：列/索引已存在则跳过；先备份再动；只 DDL 该表，不触碰业务行。
# 用法（SSH 窗口内）：bash /tmp/repair-cloud-claim-column.sh
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

CONTAINER="agent-sessions-relay"
TS="$(date +%Y%m%d-%H%M%S)"

WORKDIR="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')"
CONFIGS="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')"
PROJNAME="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project" }}')"
DB="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')/relay.db"
echo "db=$DB"
[ -f "$DB" ] || { echo "✗ 未找到 relay.db"; exit 1; }

echo "── [1/4] 停 relay ──"
docker compose --project-name "$PROJNAME" --project-directory "$WORKDIR" -f "$CONFIGS" stop relay

echo "── [2/4] 备份 ──"
BACKUP_DIR="$WORKDIR/stage"; mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/relay.db.bak-claimfix-$TS"
python3 - "$DB" "$BACKUP" <<'PY'
import sqlite3, sys, os
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect(src); d = sqlite3.connect(dst)
s.backup(d); d.close(); s.close()
print(f"backup ok: {dst} ({os.path.getsize(dst)} bytes)")
PY

echo "── [3/4] 补列 + 补索引（与 migrate.go 第 75/76 号迁移同一 SQL）──"
python3 - "$DB" <<'PY'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
cols = [r[1] for r in con.execute("PRAGMA table_info(pairing_requests)")]
print("before:", cols)
if "claim_device_id" not in cols:
    con.execute("ALTER TABLE pairing_requests ADD COLUMN claim_device_id TEXT NOT NULL DEFAULT ''")
    print("added: claim_device_id")
else:
    print("skip: claim_device_id 已存在")
idx = [r[1] for r in con.execute("PRAGMA index_list(pairing_requests)")]
if "pairing_owner_pending_idx" not in idx:
    con.execute("""CREATE UNIQUE INDEX IF NOT EXISTS pairing_owner_pending_idx
        ON pairing_requests(account_id) WHERE role='android_owner' AND status='pending'""")
    print("added: pairing_owner_pending_idx")
else:
    print("skip: pairing_owner_pending_idx 已存在")
con.commit()
print("after:", [r[1] for r in con.execute("PRAGMA table_info(pairing_requests)")])
con.close()
PY

echo "── [4/4] 起 relay + 探针 ──"
docker compose --project-name "$PROJNAME" --project-directory "$WORKDIR" -f "$CONFIGS" up -d relay
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8787/readyz || true)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 1
done
[ "$ok" = "1" ] || { echo "✗ 就绪探针未通过"; exit 1; }
echo "CLOUD_CLAIM_COLUMN_REPAIR_OK backup=$BACKUP ts=$TS"
