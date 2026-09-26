#!/usr/bin/env bash
# v0.9.7 阶段 2.1：launchd 监督循环（com.agentsessions.localstack）。
# 职责（每 60s 一轮）：
#   1. Relay /readyz 不健康时调用 restart.sh start 拉起缺失组件（幂等）；
#   2. 对已连接的 Android 设备补挂 adb reverse tcp:8787（USB 重插自愈）。
# 停栈入口：touch .task/restart/supervisor.paused 后再执行 ./restart.sh stop；
# 恢复监督：删除该标志文件。launchctl bootout 会终止本循环（KeepAlive 只管崩溃）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pause_flag="$root/.task/restart/supervisor.paused"
interval="${AGENT_SESSIONS_SUPERVISOR_INTERVAL:-60}"
adb_bin="${AGENT_SESSIONS_ADB:-$(command -v adb || echo /Users/yubi/Library/Android/sdk/platform-tools/adb)}"

while true; do
  if [[ ! -f "$pause_flag" ]]; then
    if ! curl -fsS -m 3 http://127.0.0.1:8787/readyz >/dev/null 2>&1; then
      echo "[supervisor] $(date '+%F %T') readyz 不健康，执行 start" >&2
      (cd "$root" && ./restart.sh start --no-flutter --no-opencode) >&2 || true
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
  sleep "$interval"
done
