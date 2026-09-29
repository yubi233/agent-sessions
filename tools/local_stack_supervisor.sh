#!/usr/bin/env bash
# v0.9.7 阶段 2.1：launchd 监督循环（com.agentsessions.localstack）。
# 职责（每 60s 一轮）：
#   1. Relay /readyz 不健康时调用 restart.sh start 拉起缺失组件（幂等）；
#   2. 对已连接的 Android 设备补挂 adb reverse tcp:8787（USB 重插自愈）。
# 停栈入口：touch .task/restart/supervisor.paused 后再执行 ./restart.sh stop；
# 恢复监督：删除该标志文件。launchctl bootout 会终止本循环（KeepAlive 只管崩溃）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# v0.10.0：daemon 令牌滚动续期与保活（24h TTL 无刷新机制致每 24h 必死——
# token.go 已知设计局限；此处用 reissue 工具周期重签 720h 长效 token 实现
# 「至少一个月」连续运行：每 6 天轮换，单 token 30 天兜底）。
daemon_state_dir="$root/.task/restart"
daemon_token_file="$daemon_state_dir/local-daemon-token"
daemon_device="dev_1790369304036_322f5a9f278142dd"
daemon_token_max_age_s=$((6 * 24 * 3600))  # 6 天轮换（token 本体 30 天）
daemon_bin_marker="daemon.bin"
pause_flag="$root/.task/restart/supervisor.paused"
interval="${AGENT_SESSIONS_SUPERVISOR_INTERVAL:-60}"
adb_bin="${AGENT_SESSIONS_ADB:-$(command -v adb || echo /Users/yubi/Library/Android/sdk/platform-tools/adb)}"

while true; do
  if [[ ! -f "$pause_flag" ]]; then
    if ! curl -fsS -m 3 http://127.0.0.1:8787/readyz >/dev/null 2>&1; then
      echo "[supervisor] $(date '+%F %T') readyz 不健康，执行 start" >&2
      (cd "$root" && AGENT_SESSIONS_OWNER_PAIRING=on ./restart.sh start --no-flutter --no-opencode) >&2 || true
    fi
    if [[ -x "$adb_bin" ]]; then
      while IFS= read -r serial; do
        [[ -n "$serial" ]] || continue
        if ! "$adb_bin" -s "$serial" reverse --list 2>/dev/null | grep -q 'tcp:8787'; then
          "$adb_bin" -s "$serial" reverse tcp:8787 tcp:8787 2>/dev/null \
            && echo "[supervisor] $(date '+%F %T') 已为 $serial 补挂 reverse 8787" >&2
        fi
      done < <("$adb_bin" devices 2>/dev/null | awk '$2=="device"{print $1}')
    fi
  fi
  # v0.10.0：daemon 保活——进程不在（401 退出等）时用长效 token 拉起；
  # token 文件超过 6 天则先滚动重签（reissue 720h，永不逼近 24h 死线）。
  if [[ ! -f "$pause_flag" ]]; then
    if ! pgrep -f "$daemon_bin_marker" >/dev/null 2>&1; then
      echo "[supervisor] $(date '+%F %T') daemon 不在场，执行令牌检查与拉起" >&2
      token_file_mtime=$(stat -f %m "$daemon_token_file" 2>/dev/null || echo 0)
      now_s=$(date +%s)
      token_age=$(( now_s - token_file_mtime ))
      if (( token_age > daemon_token_max_age_s )) || (( token_file_mtime == 0 )); then
        new_token=$(cd "$root" && go run ./e2e-verify/helpers/reissue-terminal-token           -db "$daemon_state_dir/relay.db" -device "$daemon_device" -ttl 720h 2>/dev/null | tail -1)
        if [[ -n "$new_token" ]]; then
          printf '%s' "$new_token" > "$daemon_token_file"
          chmod 600 "$daemon_token_file"
          echo "[supervisor] $(date '+%F %T') daemon token 已滚动重签（720h）" >&2
        fi
      fi
      daemon_token_now=$(cat "$daemon_token_file" 2>/dev/null || true)
      if [[ -n "$daemon_token_now" ]]; then
        (cd "$root" && AGENT_SESSIONS_DAEMON_TOKEN="$daemon_token_now" AGENT_SESSIONS_OWNER_PAIRING=on           ./restart.sh start --state-dir "$daemon_state_dir" --no-relay --no-flutter           --no-web --no-admin --no-opencode --no-local-dev-pairing) >&2 || true
      fi
    fi
  fi
  sleep "$interval"
done
