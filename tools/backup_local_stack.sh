#!/usr/bin/env bash
# v0.9.7 阶段 2.2：本地栈每日备份。
# 备份 Relay 与 Daemon 两个 SQLite（deployctl backup 走 VACUUM INTO：在线语义、
# 自动并入 WAL、顺带产出紧凑副本），逐份跑 integrity，滚动保留 14 份。
# 手动入口：task local:backup；定时入口：launchd com.agentsessions.localbackup。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="$root/.task/restart"
backup_root="${AGENT_SESSIONS_BACKUP_DIR:-$root/.task/backups}"
keep="${AGENT_SESSIONS_BACKUP_KEEP:-14}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$backup_root/$stamp"

targets=(
  "relay:$state_dir/relay.db"
  "daemon:$state_dir/daemon/daemon.db"
)

mkdir -p "$dest"
chmod 700 "$dest" 2>/dev/null || true
failed=0
for entry in "${targets[@]}"; do
  name="${entry%%:*}"
  src="${entry#*:}"
  out="$dest/$name.db"
  if [[ ! -f "$src" ]]; then
    echo "backup: 跳过不存在的源 $src" >&2
    continue
  fi
  if (cd "$root" && go run ./apps/deployctl backup -src "$src" -dst "$out") \
    && (cd "$root" && go run ./apps/deployctl integrity -db "$out") >/dev/null; then
    echo "backup: $name -> $out"
  else
    echo "backup: $name 失败" >&2
    failed=1
  fi
done

# 滚动保留：只留最近 $keep 份成功时间戳目录（兼容 macOS 自带 bash 3.2：无 mapfile）。
if (( failed == 0 )); then
  olds=()
  while IFS= read -r d; do olds+=("$d"); done < <(ls -1d "$backup_root"/20* 2>/dev/null | sort)
  total=${#olds[@]}
  if (( total > keep )); then
    for old in "${olds[@]:0:total-keep}"; do
      rm -rf "$old"
      echo "backup: 清理过期备份 $old"
    done
  fi
fi
exit "$failed"
