#!/usr/bin/env bash
# 本地栈一键监控（v0.9.7 阶段 5 后补的可观测性入口）。
#
# 用法：
#   bash tools/stack_monitor.sh            # 单次输出面板
#   bash tools/stack_monitor.sh --watch 60 # 每 60s 刷新（默认 300s）
#   bash tools/stack_monitor.sh --json     # 机器可读（逐行 KEY=VALUE）
#
# 数据源全部只读：进程表、/healthz|/readyz、本地两个 SQLite（只读连接）、
# 备份目录、relay/daemon 日志尾部。不写任何状态、不影响运行中的服务。
# 退出码：0=全部 OK；1=存在 WARN/FAIL（便于接入 cron/launchd 告警）。
set -u

ROOT="${AGENT_SESSIONS_MONITOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RELAY_DB="${RELAY_DB:-$ROOT/.task/restart/relay.db}"
DAEMON_DB="${DAEMON_DB:-$ROOT/.task/restart/daemon/daemon.db}"
RELAY_LOG="${RELAY_LOG:-$ROOT/.task/relay.log}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT/.task/backups}"
BRIDGE_BIN="${AGENT_SESSIONS_DSH_BIN:-$HOME/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js}"
BRIDGE_CFG="${AGENT_SESSIONS_DSH_CONFIG:-$ROOT/cordis.yml}"
HEARTBEAT_STALE_S="${HEARTBEAT_STALE_S:-300}"
BACKUP_STALE_H="${BACKUP_STALE_H:-36}"
TAIL_LINES="${TAIL_LINES:-400}"

WATCH=0; INTERVAL=300; JSON=0
while [[ $# -ge 1 ]]; do
  case "$1" in
    --watch) WATCH=1; INTERVAL="${2:-300}"; shift 2;;
    --json) JSON=1; shift;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

now_s() { date +%s; }
fmt_age() { # 秒 → 人读
  local s="$1"
  if [[ "$s" -lt 0 ]]; then echo "-"; return; fi
  if [[ "$s" -lt 120 ]]; then echo "${s}s"; return; fi
  if [[ "$s" -lt 7200 ]]; then echo "$((s/60))m"; return; fi
  if [[ "$s" -lt 172800 ]]; then echo "$((s/3600))h"; return; fi
  echo "$((s/86400))d"
}
has() { command -v "$1" >/dev/null 2>&1; }

collect() {
  local now; now=$(now_s)
  WARN=0

  # ---- 进程 ----
  R_PID=$(pgrep -f 'restart/relay' 2>/dev/null | head -1 || true)
  [[ -z "$R_PID" ]] && R_PID=$(pgrep -f 'relay.*8787|cmdRelay' 2>/dev/null | head -1 || true)
  curl_ok() { curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null; }
  HZ=$(curl_ok http://127.0.0.1:8787/healthz)
  RZ=$(curl_ok http://127.0.0.1:8787/readyz)

  D_PID=$(pgrep -f 'daemon.bin run' 2>/dev/null | head -1 || true)

  # ---- 终端心跳（本地库只读）----
  HB_AGE="-"; HB_STATUS="-"
  if [[ -f "$RELAY_DB" ]] && has sqlite3; then
    local last_hb
    last_hb=$(sqlite3 -readonly "$RELAY_DB" \
      "SELECT max(last_heartbeat_unix_ms) FROM terminals;" 2>/dev/null || true)
    if [[ -n "$last_hb" && "$last_hb" != "0" ]]; then
      HB_AGE=$(fmt_age $(( now - last_hb/1000 )))
      if [[ $(( now - last_hb/1000 )) -gt $HEARTBEAT_STALE_S ]]; then
        HB_STATUS="stale"; WARN=1
      else HB_STATUS="ok"; fi
    else
      HB_STATUS="none"; WARN=1
    fi
  fi

  # ---- 数据尺寸与 outbox ----
  R_SZ="-"; D_SZ="-"; OB_RELAY="-"; OB_DAEMON="-"
  if [[ -f "$RELAY_DB" ]]; then R_SZ=$(du -sh "$RELAY_DB" 2>/dev/null | cut -f1); fi
  if [[ -f "$DAEMON_DB" ]]; then D_SZ=$(du -sh "$DAEMON_DB" 2>/dev/null | cut -f1); fi
  if [[ -f "$RELAY_DB" ]] && has sqlite3; then
    OB_RELAY=$(sqlite3 -readonly "$RELAY_DB" \
      "SELECT group_concat(status||':'||n, ' ') FROM (SELECT status, count(*) AS n FROM outbox GROUP BY status);" 2>/dev/null || echo "-")
  fi
  if [[ -f "$DAEMON_DB" ]] && has sqlite3; then
    OB_DAEMON=$(sqlite3 -readonly "$DAEMON_DB" \
      "SELECT group_concat(status||':'||n, ' ') FROM (SELECT status, count(*) AS n FROM relay_event_outbox GROUP BY status);" 2>/dev/null || echo "-")
    local pend
    pend=$(sqlite3 -readonly "$DAEMON_DB" \
      "SELECT count(*) FROM relay_event_outbox WHERE status='pending';" 2>/dev/null || echo 0)
    if [[ "${pend:-0}" -gt 200 ]]; then WARN=1; fi
  fi

  # ---- DSH 桥 ----
  BR="ok"
  if [[ ! -f "$BRIDGE_BIN" ]]; then BR="bin缺失"; WARN=1; fi
  if [[ ! -f "$BRIDGE_CFG" ]]; then BR="$BR cfg缺失"; WARN=1; fi
  if has sqlite3 && [[ -f "$BRIDGE_CFG" ]]; then
    local miss=0 p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ -f "$p" ]] || miss=$((miss+1))
    done < <(sed -n "s/^.*name: '\(\/[^']*\)'.*$/\1/p" "$BRIDGE_CFG")
    if [[ "$miss" -gt 0 ]]; then BR="$BR 插件缺失x$miss"; WARN=1; fi
  fi

  # ---- 备份 ----
  BK_AGE_H="-"; BK_COUNT=0
  if [[ -d "$BACKUP_ROOT" ]]; then
    BK_COUNT=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | wc -l | tr -d ' ')
    local newest
    newest=$(ls -1t "$BACKUP_ROOT" 2>/dev/null | head -1)
    if [[ -n "$newest" && "$newest" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
      # 目录名即时间戳：YYYYMMDDTHHMMSSZ（UTC）
      local y=${newest:0:4} mo=${newest:4:2} d=${newest:6:2} h=${newest:9:2} mi=${newest:11:2}
      local bep
      bep=$(date -j -u -f '%Y%m%d %H%M %S' "$y$mo$d $h$mi 00" +%s 2>/dev/null || echo 0)
      if [[ "$bep" -gt 0 ]]; then
        local bk_age_s=$(( now - bep ))
        BK_AGE_H=$(fmt_age "$bk_age_s")
        if [[ "$bk_age_s" -gt $(( BACKUP_STALE_H * 3600 )) ]]; then BK_AGE_H="${BK_AGE_H}*"; WARN=1; fi
      fi
    fi
  else
    BK_AGE_H="无备份"; WARN=1
  fi

  # ---- 日志尾部错误计数 ----
  E_RELAY=0; E_DAEMON=0
  [[ -f "$RELAY_LOG" ]] && E_RELAY=$(tail -n "$TAIL_LINES" "$RELAY_LOG" 2>/dev/null | grep -c 'level=ERROR' || true)
  local DLOG
  DLOG=$(ls -1t "$ROOT"/.task/restart/logs/*/daemon.log 2>/dev/null | head -1)
  [[ -n "$DLOG" && -f "$DLOG" ]] && E_DAEMON=$(tail -n "$TAIL_LINES" "$DLOG" 2>/dev/null | grep -c 'level=ERROR' || true)
  if [[ "${E_RELAY:-0}" -gt 0 || "${E_DAEMON:-0}" -gt 0 ]]; then WARN=1; fi
}

render_text() {
  echo "┌─ 本地栈监控 ────────────────────────────── $(date '+%F %T')"
  echo "│ Relay   : healthz=$HZ readyz=$RZ pid=${R_PID:-无}"
  echo "│ Daemon  : pid=${D_PID:-无}  终端心跳=${HB_AGE}(${HB_STATUS})"
  echo "│ DSH 桥  : $BR"
  echo "│ 数据    : relay=$R_SZ daemon=$D_SZ"
  echo "│ outbox  : relay[$OB_RELAY] daemon[$OB_DAEMON]"
  echo "│ 备份    : ${BK_COUNT} 份，最新 ${BK_AGE_H}（阈值 ${BACKUP_STALE_H}h）"
  echo "│ 日志ERROR(尾${TAIL_LINES}行): relay=$E_RELAY daemon=$E_DAEMON"
  if [[ "$WARN" -eq 1 ]]; then
    echo "└─ 状态: WARN（见上方加粗项；退出码 1）"
  else
    echo "└─ 状态: OK"
  fi
}

render_json() {
  printf 'relay_pid=%s\nhealthz=%s\nreadyz=%s\ndaemon_pid=%s\nheartbeat_age=%s\nheartbeat=%s\nbridge=%s\nrelay_db=%s\ndaemon_db=%s\noutbox_relay=%s\noutbox_daemon=%s\nbackup_count=%s\nbackup_age=%s\nerr_relay=%s\nerr_daemon=%s\nwarn=%s\n' \
    "${R_PID:-}" "$HZ" "$RZ" "${D_PID:-}" "$HB_AGE" "$HB_STATUS" "$BR" "$R_SZ" "$D_SZ" "$OB_RELAY" "$OB_DAEMON" "$BK_COUNT" "$BK_AGE_H" "$E_RELAY" "$E_DAEMON" "$WARN"
}

while true; do
  collect
  if [[ "$JSON" -eq 1 ]]; then render_json; else render_text; fi
  if [[ "$WATCH" -eq 0 ]]; then
    [[ "$WARN" -eq 1 ]] && exit 1 || exit 0
  fi
  sleep "$INTERVAL"
done
