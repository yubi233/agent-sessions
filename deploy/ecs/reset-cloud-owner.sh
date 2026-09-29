#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OWN-06 云端收口·阶段 1：云端孤儿 owner 撤销（服务器端单脚本）
#
# 背景：云端唯一 active android_owner 是「恢复的 Android 控制端」孤儿
# （手机凭据已被 flutter 清理，无人能持其令牌），导致
# POST /v1/auth/device-bootstrap 恒 409（initial owner already exists）。
# 本脚本在服务器上一次跑完：备份 → 事务撤销 → 重启 → 探针，
# 让 bootstrap 重新开放，mac 得以成为云端权威 owner（阶段 2）。
#
# 用法（SSH 窗口内）：
#   bash /tmp/reset-cloud-owner.sh
# 设计约束（见 OWN-06 云端收口计划 §三.1）：
#   - 只 UPDATE 身份行（devices.status / token_families.revoked），
#     sessions/events/usage/工作区全部保留，不 DELETE 任何行；
#   - 先落备份（保底回滚点），再动数据；
#   - access token 无需清理：auth.activeDevice 逐请求校验设备 status，
#     devices 行撤销即全部失效（internal/domain/auth.go:407）。
# 幂等：无 active owner 时跳过 UPDATE，仍输出成功标记。
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

CONTAINER="agent-sessions-relay"
TS="$(date +%Y%m%d-%H%M%S)"

echo "═══ [1/5] 定位 compose 工程与数据卷 ═══"
WORKDIR="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')"
CONFIGS="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')"
PROJNAME="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project" }}')"
DB="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')/relay.db"
echo "workdir=$WORKDIR"
echo "configs=$CONFIGS"
echo "project=$PROJNAME"
echo "db=$DB"
[ -f "$DB" ] || { echo "✗ 未找到 relay.db：$DB"; exit 1; }

echo "═══ [2/5] 先停 relay（避免写竞争；云端此刻无活跃连接设备）═══"
docker compose --project-name "$PROJNAME" --project-directory "$WORKDIR" -f "$CONFIGS" stop relay

echo "═══ [3/5] 备份 + 事务撤销（python3 标准库）═══"
BACKUP_DIR="$WORKDIR/stage"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/relay.db.bak-cloudowner-$TS"
python3 - "$DB" "$BACKUP" <<'PY'
import sqlite3, sys, os

db, backup = sys.argv[1], sys.argv[2]

# 备份用在线 backup API：对 WAL 残留安全，产物是独立完整快照。
src = sqlite3.connect(db)
dst = sqlite3.connect(backup)
src.backup(dst)
dst.close()

n_devices = sqlite3.connect(backup).execute("SELECT count(*) FROM devices").fetchone()[0]
print(f"backup ok: {backup} (devices={n_devices}, {os.path.getsize(backup)} bytes)")

# 事务撤销：只动身份行。先 SELECT 出目标 id，再按 id 精确 UPDATE。
con = sqlite3.connect(db, isolation_level=None)
cur = con.cursor()
cur.execute("BEGIN IMMEDIATE")
rows = cur.execute(
    "SELECT id, display_name FROM devices WHERE role='android_owner' AND status='active'"
).fetchall()
if not rows:
    cur.execute("ROLLBACK")
    print("no active android_owner：已是重置后状态（幂等跳过）")
else:
    ids = [r[0] for r in rows]
    ph = ",".join("?" * len(ids))
    cur.execute(f"UPDATE devices SET status='revoked' WHERE id IN ({ph})", ids)
    cur.execute(f"UPDATE token_families SET revoked=1 WHERE device_id IN ({ph})", ids)
    cur.execute("COMMIT")
    for r in rows:
        print(f"revoked owner device: {r[0]} ({r[1]})")
left = cur.execute(
    "SELECT count(*) FROM devices WHERE role='android_owner' AND status='active'"
).fetchone()[0]
con.close()
print(f"active android_owner remaining: {left}")
PY

echo "═══ [4/5] 重启 relay（内存态刷新）═══"
docker compose --project-name "$PROJNAME" --project-directory "$WORKDIR" -f "$CONFIGS" up -d relay

echo "═══ [5/5] 就绪探针 ═══"
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8787/readyz || true)"
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 1
done
if [ "$ok" != "1" ]; then
  echo "✗ relay 就绪探针未通过（回滚提示：docker compose stop relay 后用 $BACKUP 覆盖 $DB 再 up -d）"
  exit 1
fi
echo "readyz=200"
echo "CLOUD_OWNER_RESET_OK bootstrap_reopened=1 backup=$BACKUP ts=$TS"
