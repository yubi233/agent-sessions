#!/usr/bin/env bash
# Local development entrypoint: Relay -> Daemon -> Flutter, with optional
# Web/Admin inspection surfaces. It owns only processes recorded under the
# selected state directory and delegates Relay ownership to relayctl.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AGENT_SESSIONS_RESTART_STATE_DIR:-$ROOT_DIR/.task/restart}"
LOG_ROOT="${AGENT_SESSIONS_RESTART_LOG_DIR:-$STATE_DIR/logs}"
RELAY_ADDR="${AGENT_SESSIONS_RELAY_ADDR:-127.0.0.1:8787}"
RELAY_DB_PATH="${AGENT_SESSIONS_SQLITE_PATH:-}"
WEB_PORT="${AGENT_SESSIONS_WEB_PORT:-5173}"
ADMIN_PORT="${AGENT_SESSIONS_ADMIN_PORT:-5174}"
DAEMON_STATE_DIR="${AGENT_SESSIONS_DAEMON_STATE_DIR:-$STATE_DIR/daemon}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
OPENCODE_HOST="${AGENT_SESSIONS_OPENCODE_HOST:-127.0.0.1}"
OPENCODE_PORT="${AGENT_SESSIONS_OPENCODE_PORT:-4096}"
OPENCODE_URL="${AGENT_SESSIONS_OPENCODE_URL:-http://$OPENCODE_HOST:$OPENCODE_PORT}"
# v0.7：默认模型只作为显式 provider/model 配置透传给 Relay 与 Daemon；为空时
# 由 OpenCode Adapter 的健康目录动态决定，启动脚本不猜测或硬编码付费模型。
OPENCODE_DEFAULT_MODEL="${AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL:-}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
FLUTTER_MODE="${AGENT_SESSIONS_FLUTTER_MODE:-mac}"
FLUTTER_DEVICE="${AGENT_SESSIONS_FLUTTER_DEVICE:-}"
# 冷启动（重启系统/清理缓存后）构建常超过 30s，默认放宽到 180s；
# 环境变量 AGENT_SESSIONS_FLUTTER_TIMEOUT_MS 仍可覆盖。
FLUTTER_TIMEOUT_MS="${AGENT_SESSIONS_FLUTTER_TIMEOUT_MS:-180000}"
FLUTTER_RELAY_BASE="${AGENT_SESSIONS_FLUTTER_RELAY_BASE:-}"
FLUTTER_TARGET_SESSION_ID="${AGENT_SESSIONS_FLUTTER_TARGET_SESSION_ID:-}"
FLUTTER_DEVICE_HELPER="${AGENT_SESSIONS_FLUTTER_DEVICE_HELPER:-$ROOT_DIR/tools/flutter_device.sh}"
LOCAL_DEV_PAIRING="${AGENT_SESSIONS_LOCAL_DEV_PAIRING:-true}"
LOCAL_DEV_PROJECT_ID="${AGENT_SESSIONS_LOCAL_DEV_PROJECT_ID:-local-dev}"
LOCAL_DEV_WORKSPACE_ID="ws_${LOCAL_DEV_PROJECT_ID}"
# v0.6 残余项收口：Terminal 签名模式接线。默认关闭（保持 bearer 兼容窗口），
# 显式 --terminal-signing / AGENT_SESSIONS_DAEMON_SIGNING=true 后：
#   1) 本机状态目录缺少密钥文件时用 `daemon keygen` 生成 Ed25519 身份密钥（0600）；
#   2) 配对请求携带真实 identity_public_key，使 Relay 可验签（桥接期 key_id=device_id）；
#   3) Daemon 进程通过 AGENT_SESSIONS_DAEMON_SIGNING_KEY_FILE 读取私钥并全程签名。
TERMINAL_SIGNING="${AGENT_SESSIONS_DAEMON_SIGNING:-false}"
DAEMON_SIGNING_KEY_FILE=""
FLUTTER_TARGET=""
if [[ -n "$FLUTTER_DEVICE" && "$FLUTTER_DEVICE" != "macos" && "$FLUTTER_MODE" == "mac" ]]; then
  FLUTTER_MODE=device
fi

ACTION="restart"
WITH_RELAY=true
WITH_WEB=false
WITH_ADMIN=false
WITH_DAEMON=true
WITH_OPENCODE=true
WITH_FLUTTER=true
FIXTURE_DAEMON=false
DRY_RUN=false
CLEAN_PORTS=false
CLEAN_PORTS_SET=false
LOG_DIR=""
RESTART_LOG=""
DAEMON_ACCESS_TOKEN="${AGENT_SESSIONS_DAEMON_TOKEN:-}"
DAEMON_TOKEN_SOURCE=""
LOCAL_DEV_TERMINAL_DEVICE_ID=""
LOCAL_OWNER_ACCESS_TOKEN=""
LOCAL_OWNER_BOOTSTRAP_B64=""
LOCAL_DEV_DSH_WORKSPACE_ID=""
# v0.8.8 P1：localdev owner X25519 私钥（ensure_local_owner_bootstrap 经
# encryption-keygen 幂等生成；dry-run/无 pairing 路径保持空）。
LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64=""
LOCAL_DEV_WORKSPACE_CONFIRMED=false
DAEMON_HEARTBEAT_BASELINE=0

STARTED_RELAY=false
STARTED_WEB=false
STARTED_ADMIN=false
STARTED_DAEMON=false
STARTED_OPENCODE=false
STARTED_FLUTTER=false

# v0.8.9 P2（V089-07/08，G3 生命周期边界）：是否允许重建 Relay DB。
# start/restart 默认允许（配合 reset 内的生命周期锁）；restart-flutter 强制关闭——
# 它不重建 Daemon 进程，静默 reset 会让运行中的 Daemon 以旧 token/旧世代继续
# SSE/heartbeat，制造 v0.8.8 实证的 generation 错位窗口。
RELAY_DB_RESET_ALLOWED=true

usage() {
  cat <<'EOF'
Usage: ./restart.sh [start|stop|restart|restart-flutter|status] [options]

`restart-flutter` restarts only the managed Flutter process without requiring an
interactive Flutter terminal. The default action is restart. The default local stack is Relay + local dev-paired
fixture Daemon + Flutter. When AGENT_SESSIONS_DAEMON_TOKEN is absent, the script
uses the real Relay HTTP pairing flow to bootstrap a local owner, approve a
Terminal, and inject the owner session into Flutter macOS.
Web/Admin are optional inspection surfaces and require explicit flags.

Options:
  --no-relay             Do not manage the local Relay
  --no-web               Do not start apps/web (compatibility flag)
  --with-web             Start apps/web
  --no-admin             Do not start apps/admin-web (compatibility flag)
  --with-admin           Start apps/admin-web
  --no-daemon            Do not start apps/daemon
  --with-daemon          Start apps/daemon run (default)
  --no-opencode          Do not start OpenCode Server
  --with-opencode        Start OpenCode Server (default)
  --opencode-port PORT   OpenCode Server port (default: 4096)
  --opencode-url URL     OpenCode URL passed to Daemon
  --no-local-dev-pairing Disable automatic local owner/terminal pairing/session
                         injection when AGENT_SESSIONS_DAEMON_TOKEN is missing
  --local-dev-pairing    Enable automatic local owner/terminal pairing/session
                         injection
  --no-flutter           Do not start apps/mobile
  --flutter-mode MODE    Flutter target mode: mac or device (default: mac)
  --flutter MODE         Alias for --flutter-mode
  --flutter-device ID    Flutter device id; non-macos ids select device mode
  --flutter-relay-base URL
                         Relay URL passed to Flutter; device mode requires this
  --flutter-target-session ID
                         Local macOS verification: open an existing session on launch
  --fixture-daemon       Add --fixture-adapter to the Daemon command
  --terminal-signing     Enable v0.6 Terminal Ed25519 signing for the Daemon
                         (generate/register local identity key; env:
                         AGENT_SESSIONS_DAEMON_SIGNING=true)
  --relay-addr ADDR      Relay listen address (default: 127.0.0.1:8787)
  --web-port PORT        Web Vite port (default: 5173)
  --admin-port PORT      Admin Vite port (default: 5174)
  --log-dir DIR          Log directory (default: .task/restart/logs/<timestamp>)
  --state-dir DIR        Process state directory (default: .task/restart)
  --clean-ports          Stop listeners on selected service ports before start
  --no-clean-ports       Do not clean ports (default for start; restart cleans)
  --dry-run              Print the selected topology without starting anything
  -h, --help             Show this help

Actions:
  restart-flutter        Reconnect Flutter by replacing its managed process
                         (alias: flutter-restart); Relay/Daemon remain running

Environment:
  AGENT_SESSIONS_RELAY_ADDR, AGENT_SESSIONS_SQLITE_PATH,
  AGENT_SESSIONS_WEB_PORT, AGENT_SESSIONS_ADMIN_PORT,
  AGENT_SESSIONS_DAEMON_TOKEN, AGENT_SESSIONS_DAEMON_STATE_DIR,
  AGENT_SESSIONS_RESTART_STATE_DIR, AGENT_SESSIONS_RESTART_LOG_DIR,
  AGENT_SESSIONS_OPENCODE_HOST, AGENT_SESSIONS_OPENCODE_PORT,
  AGENT_SESSIONS_OPENCODE_URL, AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL, OPENCODE_BIN,
  AGENT_SESSIONS_FLUTTER_MODE, AGENT_SESSIONS_FLUTTER_DEVICE,
  AGENT_SESSIONS_FLUTTER_TIMEOUT_MS, AGENT_SESSIONS_FLUTTER_RELAY_BASE,
  AGENT_SESSIONS_FLUTTER_TARGET_SESSION_ID,
  AGENT_SESSIONS_DAEMON_SIGNING,
  AGENT_SESSIONS_DSH_BIN, AGENT_SESSIONS_DSH_CONFIG,
  AGENT_SESSIONS_DSH_PERSIST_ROOT,
  AGENT_SESSIONS_DSH_PERSIST_COMPRESSION,
  AGENT_SESSIONS_CODEX_ENABLE, AGENT_SESSIONS_CODEX_BIN,
  AGENT_SESSIONS_LOCAL_DEV_PAIRING, FLUTTER_BIN

Logs and local Relay data never go to testbox; testbox remains the Agent session
workspace only.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "restart.sh: required command not found: $1" >&2
    return 1
  fi
}

print_missing_daemon_token_hint() {
  cat >&2 <<'EOF'
daemon: AGENT_SESSIONS_DAEMON_TOKEN is required; refusing to start a partial stack

Next steps:
  - Default local debug stack:
      ./restart.sh restart
  - Full local stack:
      AGENT_SESSIONS_DAEMON_TOKEN=<paired-terminal-token> ./restart.sh restart
  - Flutter + Relay only:
      ./restart.sh restart --no-daemon
  - Flutter macOS only:
      ./restart.sh start --no-relay --no-daemon --flutter-mode mac
  - Physical Android Flutter target:
      AGENT_SESSIONS_FLUTTER_RELAY_BASE=http://<host-lan-ip>:8787 ./restart.sh restart --no-daemon --flutter-mode device
EOF
}

json_get() {
  python3 -c 'import json, sys
data=json.load(sys.stdin)
for key in sys.argv[1].split("."):
    data=data[key]
print(data)' "$1"
}

json_set_tokens() {
  python3 -c 'import json, os, sys
path = sys.argv[1]
doc = json.load(sys.stdin)
tokens = doc.get("tokens") if isinstance(doc.get("tokens"), dict) else doc
if not isinstance(tokens, dict) or "access_token" not in tokens or "refresh_token" not in tokens:
    raise SystemExit("missing tokens")
with open(path, "r", encoding="utf-8") as fh:
    existing = json.load(fh)
existing["tokens"] = tokens
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(existing, fh, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, path)' "$1"
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

redacted_command() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '<redaction unavailable>'
    return 0
  fi
  python3 - "$@" <<'PY'
import re
import shlex
import sys

def redact(value: str) -> str:
    value = re.sub(r"(Authorization:\s*Bearer\s+)[^\"'\s]+", r"\1<redacted>", value)
    value = re.sub(r'("(?:access_token|refresh_token)"\s*:\s*")[^"]+', r'\1<redacted>', value)
    value = re.sub(r"(AGENT_SESSIONS_DAEMON_TOKEN=)[^\"'\s]+", r"\1<redacted>", value)
    value = re.sub(r"(--dart-define=LOCAL_DEV_OWNER_BOOTSTRAP_B64=)[^\"'\s]+", r"\1<redacted>", value)
    value = re.sub(r"(--dart-define=LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64=).*", r"\1<redacted>", value)
    return value

print(" ".join(shlex.quote(redact(arg)) for arg in sys.argv[1:]))
PY
}

redacted_body_excerpt() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf '<empty>'
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    head -c 2000 "$file" | tr '\n' ' '
    return 0
  fi
  python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "rb") as fh:
    text = fh.read(4096).decode("utf-8", "replace")
text = re.sub(r'("(?:access_token|refresh_token)"\s*:\s*")[^"]+', r'\1<redacted>', text)
text = re.sub(r"(Authorization:\s*Bearer\s+)[^\"'\s]+", r"\1<redacted>", text)
text = re.sub(r"(--dart-define=LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64=)[^\"'\s]+", r"\1<redacted>", text)
text = text.replace("\n", "\\n").strip()
if len(text) > 2000:
    text = text[:2000] + "...<truncated>"
print(text or "<empty>")
PY
}

restart_log() {
  [[ -n "${RESTART_LOG:-}" ]] || return 0
  printf '[restart.sh] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$RESTART_LOG"
}

setup_restart_logging() {
  mkdir -p "$LOG_DIR"
  RESTART_LOG="$LOG_DIR/restart.log"
  if [[ "${AGENT_SESSIONS_RESTART_LOGGING_ACTIVE:-}" != "$RESTART_LOG" ]]; then
    export AGENT_SESSIONS_RESTART_LOGGING_ACTIVE="$RESTART_LOG"
    exec 3>&1 4>&2
    exec > >(tee -a "$RESTART_LOG" >&3) 2> >(tee -a "$RESTART_LOG" >&4)
  fi
  restart_log "invocation command=$(redacted_command "$0" "$@") action=$ACTION state_dir=$STATE_DIR log_dir=$LOG_DIR relay=$RELAY_ADDR relay_db=$RELAY_DB_PATH"
}

http_request() {
  local label="$1" body_file status rc excerpt bytes
  shift
  body_file="$(mktemp "${TMPDIR:-/tmp}/agent-sessions-restart-http.XXXXXX")"
  restart_log "http request label=$label command=$(redacted_command curl "$@")"
  set +e
  status="$(curl --silent --show-error --output "$body_file" --write-out '%{http_code}' "$@")"
  rc=$?
  set -e
  if (( rc != 0 )); then
    excerpt="$(redacted_body_excerpt "$body_file")"
    restart_log "http transport_failed label=$label rc=$rc body=$excerpt"
    echo "$label: curl transport failed (rc=$rc)" >&2
    if [[ "$excerpt" != "<empty>" ]]; then
      echo "$label: response $excerpt" >&2
    fi
    rm -f "$body_file"
    return "$rc"
  fi
  if ! [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
    excerpt="$(redacted_body_excerpt "$body_file")"
    restart_log "http failed label=$label status=$status body=$excerpt"
    echo "$label: relay http status $status" >&2
    echo "$label: response $excerpt" >&2
    rm -f "$body_file"
    return 22
  fi
  bytes="$(wc -c < "$body_file" | tr -d '[:space:]')"
  restart_log "http ok label=$label status=$status bytes=$bytes"
  cat "$body_file"
  rm -f "$body_file"
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
  esac
}

pid_file() { printf '%s/%s.pid\n' "$STATE_DIR" "$1"; }

read_pid() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' < "$file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$pid"
}

is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

process_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

component_matches() {
  local component="$1" pid="$2" command
  command="$(process_command "$pid")"
  case "$component" in
    web)
      [[ "$command" == *vite* && "$command" == *"--port $WEB_PORT"* ]]
      ;;
    admin)
      [[ "$command" == *vite* && "$command" == *"--port $ADMIN_PORT"* ]]
      ;;
    daemon)
      [[ "$command" == *"apps/daemon"* || "$command" == *"daemon run"* ]]
      ;;
    opencode)
      [[ "$command" == *"opencode"* && "$command" == *"serve"* ]]
      ;;
    flutter)
      local target="$FLUTTER_TARGET"
      if [[ -z "$target" && -f "$STATE_DIR/flutter-target" ]]; then
        target="$(tr -d '[:space:]' < "$STATE_DIR/flutter-target")"
      fi
      [[ -n "$target" && "$command" == *"--no-pub"* && "$command" == *"-d $target"* ]]
      ;;
    *) return 1 ;;
  esac
}

relay_matches() {
  local pid="$1" command
  command="$(process_command "$pid")"
  [[ "$command" == *"apps/relay"* || "$command" == *".task/relay"* ]]
}

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  # curl is a useful fallback for HTTP services when lsof is unavailable.
  curl --silent --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1
}

relay_port() {
  printf '%s\n' "$RELAY_ADDR" | awk -F: '{print $NF}'
}

validate_tcp_port() {
  local label="$1" value="$2" number
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "restart.sh: $label must be a numeric TCP port: $value" >&2
    return 1
  fi
  number=$((10#$value))
  if (( number < 1 || number > 65535 )); then
    echo "restart.sh: $label must be between 1 and 65535: $value" >&2
    return 1
  fi
}

port_pids() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "restart.sh: invalid TCP port: $port" >&2
    return 2
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    echo "restart.sh: lsof is required for port cleanup" >&2
    return 1
  fi
  lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u
}

cleanup_port() {
  local port="$1" pid command found=false
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    found=true
    command="$(process_command "$pid")"
    echo "port $port: stopping listener pid $pid${command:+ ($command)}"
    kill_tree "$pid"
    if ! wait_dead "$pid"; then
      echo "port $port: listener pid $pid did not stop gracefully; sending SIGKILL" >&2
      kill -KILL "$pid" 2>/dev/null || true
      if ! wait_dead "$pid"; then
        echo "port $port: failed to release listener pid $pid" >&2
        return 1
      fi
    fi
  done < <(port_pids "$port")
  if [[ "$found" == true ]]; then
    for _ in $(seq 1 20); do
      if ! port_in_use "$port"; then
        echo "port $port: released"
        return 0
      fi
      sleep 0.1
    done
    echo "port $port: still occupied after cleanup" >&2
    return 1
  fi
}

cleanup_selected_ports() {
  local port
  if [[ "$WITH_RELAY" != true && "$WITH_WEB" != true && "$WITH_ADMIN" != true ]]; then
    return 0
  fi
  require_command lsof || return 1
  if [[ "$WITH_RELAY" == true ]]; then
    port="$(relay_port)"
    cleanup_port "$port" || return 1
  fi
  if [[ "$WITH_WEB" == true ]]; then
    cleanup_port "$WEB_PORT" || return 1
  fi
  if [[ "$WITH_ADMIN" == true ]]; then
    cleanup_port "$ADMIN_PORT" || return 1
  fi
}

kill_tree() {
  local pid="$1" child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      kill_tree "$child"
    done
  fi
  kill -TERM "$pid" 2>/dev/null || true
}

wait_dead() {
  local pid="$1" i
  for i in $(seq 1 50); do
    if ! is_running "$pid"; then return 0; fi
    sleep 0.1
  done
  return 1
}

stop_process() {
  local component="$1" file pid
  file="$(pid_file "$component")"
  pid="$(read_pid "$file" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! is_running "$pid"; then
    rm -f "$file"
    echo "$component: stopped"
    return 0
  fi
  if ! component_matches "$component" "$pid"; then
    echo "$component: refusing to stop pid $pid (command no longer matches; pid file removed)" >&2
    rm -f "$file"
    return 1
  fi
  kill_tree "$pid"
  if ! wait_dead "$pid"; then
    echo "$component: graceful stop timed out; sending SIGKILL to owned pid $pid" >&2
    kill -KILL "$pid" 2>/dev/null || true
    if ! wait_dead "$pid"; then
      echo "$component: failed to stop pid $pid" >&2
      return 1
    fi
  fi
  rm -f "$file"
  echo "$component: stopped"
}

start_process() {
  local component="$1" file="$2" logfile="$3" cwd="$4" pid command_line
  shift 4
  mkdir -p "$STATE_DIR" "$(dirname "$logfile")"
  if pid="$(read_pid "$file" 2>/dev/null || true)"; then
    if [[ -n "$pid" ]] && is_running "$pid"; then
      if component_matches "$component" "$pid"; then
        echo "$component: already running (pid $pid)"
        return 0
      fi
      echo "$component: refusing to reuse pid file for unrelated process $pid" >&2
      return 1
    fi
    rm -f "$file"
  fi
  command_line="$(redacted_command "$@")"
  printf '[restart.sh] component=%s started=%s\n' "$component" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$logfile"
  printf '[restart.sh] cwd=%s command=%s\n' "$cwd" "$command_line" >> "$logfile"
  restart_log "process starting component=$component cwd=$cwd pid_file=$file log=$logfile command=$command_line"
  pid="$(python3 - "$cwd" "$logfile" "$@" <<'PY'
import os
import subprocess
import sys

cwd = sys.argv[1]
logfile = sys.argv[2]
args = sys.argv[3:]
log = open(logfile, "ab", buffering=0)
proc = subprocess.Popen(
    args,
    cwd=cwd,
    stdin=subprocess.DEVNULL,
    stdout=log,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    close_fds=True,
)
print(proc.pid)
PY
)"
  printf '%s\n' "$pid" > "$file"
  restart_log "process spawned component=$component pid=$pid"
  sleep 0.2
  if ! is_running "$pid"; then
    restart_log "process exited_during_startup component=$component pid=$pid log=$logfile"
    echo "$component: exited during startup; inspect $logfile" >&2
    rm -f "$file"
    return 1
  fi
  echo "$component: started (pid $pid; log $logfile)"
}

run_web() {
  cd "$ROOT_DIR/apps/web"
  exec env VITE_RELAY_URL="http://$RELAY_ADDR" pnpm exec vite --host 127.0.0.1 --port "$WEB_PORT" --strictPort
}

run_admin() {
  cd "$ROOT_DIR/apps/admin-web"
  exec env VITE_RELAY_URL="http://$RELAY_ADDR" pnpm exec vite --host 127.0.0.1 --port "$ADMIN_PORT" --strictPort
}

run_daemon() {
  cd "$ROOT_DIR"
  local args=(run --relay-base "http://$RELAY_ADDR" --state-dir "$DAEMON_STATE_DIR")
  if [[ "$FIXTURE_DAEMON" == true ]]; then
    args+=(--fixture-adapter)
  fi
  exec env AGENT_SESSIONS_DAEMON_TOKEN="$DAEMON_ACCESS_TOKEN" go run ./apps/daemon "${args[@]}"
}

run_flutter() {
  cd "$ROOT_DIR/apps/mobile"
  exec "$FLUTTER_BIN" run -d "$FLUTTER_TARGET" --no-pub "--dart-define=RELAY_BASE_URL=$FLUTTER_RELAY_BASE"
}

wait_for_http() {
  local component="$1" url="$2" pid="$3" i
  for i in $(seq 1 100); do
    if curl --fail --silent --show-error --max-time 1 "$url" >/dev/null 2>&1; then
      echo "$component: ready at $url"
      return 0
    fi
    if ! is_running "$pid"; then
      echo "$component: exited before readiness; inspect $(component_log "$component")" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "$component: readiness timeout at $url" >&2
  return 1
}

local_dev_terminal_last_seen() {
  local body
  [[ -n "$LOCAL_OWNER_ACCESS_TOKEN" && -n "$LOCAL_DEV_TERMINAL_DEVICE_ID" ]] || return 1
  body="$(curl --fail --silent --show-error --max-time 1 \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    "http://$RELAY_ADDR/v1/terminals" 2>/dev/null)" || return 1
  printf '%s' "$body" | LOCAL_DEV_TERMINAL_DEVICE_ID="$LOCAL_DEV_TERMINAL_DEVICE_ID" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
device_id = os.environ["LOCAL_DEV_TERMINAL_DEVICE_ID"]
for item in doc.get("terminals", []):
    if isinstance(item, dict) and item.get("device_id") == device_id:
        print(int(item.get("last_seen_unix_ms") or 0))
        raise SystemExit(0)
raise SystemExit(1)
'
}

# v0.9.1（V091-13）：读取本地配对 Terminal 的脱敏 presence 投影。
# 输出两列："last_seen_unix_ms availability"。availability 是 Relay 以服务端
# 时间即时投影的权威在线态；输出绝不含 Terminal ID、hostname、token 或路径。
local_dev_terminal_presence() {
  local body
  [[ -n "$LOCAL_OWNER_ACCESS_TOKEN" && -n "$LOCAL_DEV_TERMINAL_DEVICE_ID" ]] || return 1
  body="$(curl --fail --silent --show-error --max-time 1 \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    "http://$RELAY_ADDR/v1/terminals" 2>/dev/null)" || return 1
  printf '%s' "$body" | LOCAL_DEV_TERMINAL_DEVICE_ID="$LOCAL_DEV_TERMINAL_DEVICE_ID" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
device_id = os.environ["LOCAL_DEV_TERMINAL_DEVICE_ID"]
for item in doc.get("terminals", []):
    if isinstance(item, dict) and item.get("device_id") == device_id:
        print(int(item.get("last_seen_unix_ms") or 0), item.get("availability") or "unknown")
        raise SystemExit(0)
raise SystemExit(1)
'
}

# status 是独立 shell 进程，不继承 start/restart 期间的内存变量。只从当前
# state dir 的 0600 配对缓存恢复列表查询所需的最小上下文；不输出凭据、不刷新
# token，也不在诊断路径触发 Relay DB 重建。
load_cached_local_presence_credentials() {
  local owner_file daemon_approval_file
  owner_file="$(local_token_file local-owner-bootstrap.json)"
  daemon_approval_file="$(local_token_file local-daemon-approval.json)"
  if [[ -z "$LOCAL_OWNER_ACCESS_TOKEN" && -s "$owner_file" ]]; then
    LOCAL_OWNER_ACCESS_TOKEN="$(json_get tokens.access_token < "$owner_file" 2>/dev/null || true)"
  fi
  if [[ -z "$LOCAL_DEV_TERMINAL_DEVICE_ID" && -s "$daemon_approval_file" ]]; then
    LOCAL_DEV_TERMINAL_DEVICE_ID="$(json_get id < "$daemon_approval_file" 2>/dev/null || true)"
  fi
}

# `go run` can stay alive while compiling even if the resulting Daemon exits
# immediately. For the default local stack, require Relay to observe a newer
# heartbeat before reporting readiness or starting Flutter.
wait_for_daemon() {
  local pid="$1" last_seen i
  if [[ -z "$pid" ]]; then
    echo "daemon: missing pid after start" >&2
    return 1
  fi
  if [[ "$WITH_RELAY" != true ]] || ! truthy "$LOCAL_DEV_PAIRING" ||
    [[ -z "$LOCAL_OWNER_ACCESS_TOKEN" || -z "$LOCAL_DEV_TERMINAL_DEVICE_ID" ]]; then
    for i in $(seq 1 25); do
      if ! is_running "$pid"; then
        echo "daemon: exited before readiness; inspect $(component_log daemon)" >&2
        return 1
      fi
      sleep 0.2
    done
    echo "daemon: process is running (Relay heartbeat not observable with external token)"
    return 0
  fi

  for i in $(seq 1 300); do
    if ! is_running "$pid"; then
      echo "daemon: exited before first heartbeat; inspect $(component_log daemon)" >&2
      return 1
    fi
    # v0.9.1（V091-13）：就绪门升级为「新 heartbeat 落库 + Relay 权威投影 online」。
    # 只进程存活或 last_seen 前进（可能是历史值）都不算 ready。
    presence="$(local_dev_terminal_presence 2>/dev/null || true)"
    last_seen="${presence%% *}"
    availability="${presence#* }"
    if [[ "$last_seen" =~ ^[0-9]+$ ]] && (( last_seen > DAEMON_HEARTBEAT_BASELINE )) &&
      [[ "$availability" == "online" ]]; then
      echo "daemon: ready (first heartbeat confirmed; availability=online)"
      return 0
    fi
    sleep 0.2
  done
  echo "daemon: readiness timeout waiting for first heartbeat; inspect $(component_log daemon)" >&2
  return 1
}

wait_for_flutter() {
  local pid="$1" attempts i logfile ready_seen=false
  logfile="$(component_log flutter)"
  attempts=$(( (FLUTTER_TIMEOUT_MS + 99) / 100 ))
  for i in $(seq 1 "$attempts"); do
    if ! is_running "$pid"; then
      echo "flutter: exited before readiness; inspect $(status_log flutter)" >&2
      return 1
    fi
    if grep -Eq 'Syncing files to device|Dart VM Service|fake flutter run' "$logfile" 2>/dev/null; then
      if [[ "$ready_seen" == true ]]; then
        echo "flutter: ready (target $FLUTTER_TARGET)"
        return 0
      fi
      ready_seen=true
    fi
    sleep 0.1
  done
  echo "flutter: startup timeout after ${FLUTTER_TIMEOUT_MS}ms; inspect $(status_log flutter)" >&2
  return 1
}

component_log() {
  printf '%s/%s.log\n' "$LOG_DIR" "$1"
}

status_log() {
  local saved="$STATE_DIR/log-dir"
  if [[ -f "$saved" ]]; then
    printf '%s/%s.log\n' "$(tr -d '[:space:]' < "$saved")" "$1"
  else
    component_log "$1"
  fi
}

flutter_command() {
  if [[ "$FLUTTER_BIN" == */* ]]; then
    [[ -x "$FLUTTER_BIN" ]] || { echo "flutter: executable not found or not executable: $FLUTTER_BIN" >&2; return 1; }
  else
    require_command "$FLUTTER_BIN" || return 1
  fi
}

flutter_target_exists() {
  local target="$1" output
  output="$("$FLUTTER_BIN" devices --machine 2>&1)" || {
    echo "flutter: unable to list devices with $FLUTTER_BIN" >&2
    printf '%s\n' "$output" >&2
    return 1
  }
  if require_command python3 >/dev/null 2>&1; then
    if printf '%s' "$output" | TARGET="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET"]; devices=json.load(sys.stdin); raise SystemExit(0 if any(isinstance(item, dict) and item.get("id")==target for item in devices) else 1)' 2>/dev/null; then
      return 0
    fi
  fi
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"'"$target"'"' <<< "$output"
}

resolve_flutter_target() {
  case "$FLUTTER_MODE" in
    mac|macos)
      FLUTTER_MODE=mac
      FLUTTER_TARGET="${FLUTTER_DEVICE:-macos}"
      [[ "$FLUTTER_TARGET" == "macos" ]] || { echo "flutter: mac mode only accepts the macos target; use --flutter-mode device for an Android id" >&2; return 1; }
      FLUTTER_RELAY_BASE="${FLUTTER_RELAY_BASE:-http://$RELAY_ADDR}"
      ;;
    device)
      [[ -n "$FLUTTER_RELAY_BASE" ]] || { echo "flutter: device mode requires AGENT_SESSIONS_FLUTTER_RELAY_BASE (a host-reachable Relay URL)" >&2; return 1; }
      [[ -x "$FLUTTER_DEVICE_HELPER" ]] || { echo "flutter: device resolver is not executable: $FLUTTER_DEVICE_HELPER" >&2; return 1; }
      if [[ -n "$FLUTTER_DEVICE" ]]; then
        FLUTTER_TARGET="$("$FLUTTER_DEVICE_HELPER" resolve "$FLUTTER_DEVICE")" || return 1
      else
        FLUTTER_TARGET="$("$FLUTTER_DEVICE_HELPER" resolve)" || return 1
      fi
      ;;
    *) echo "flutter: unsupported mode $FLUTTER_MODE (expected mac or device)" >&2; return 1 ;;
  esac
  flutter_command || return 1
  if ! flutter_target_exists "$FLUTTER_TARGET"; then
    echo "flutter: target does not exist in flutter devices: $FLUTTER_TARGET" >&2
    return 1
  fi
}

preflight_start() {
  if ! [[ "$FLUTTER_TIMEOUT_MS" =~ ^[0-9]+$ ]] || (( FLUTTER_TIMEOUT_MS < 100 )); then
    echo "flutter: AGENT_SESSIONS_FLUTTER_TIMEOUT_MS must be an integer >= 100: $FLUTTER_TIMEOUT_MS" >&2
    return 1
  fi
  if [[ "$WITH_FLUTTER" == true ]]; then
    resolve_flutter_target || return 1
  fi
}

local_token_file() { printf '%s/%s\n' "$STATE_DIR" "$1"; }

stage_local_owner_bootstrap_for_flutter() {
  local source="$1"
  require_command base64 || return 1
  LOCAL_OWNER_BOOTSTRAP_B64="$(base64 < "$source" | tr -d '\n')"
}

ensure_local_dev_workspace() {
  if [[ "$WITH_RELAY" != true ]] || ! truthy "$LOCAL_DEV_PAIRING"; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  ensure_local_owner_bootstrap || return 1
  require_command curl || return 1
  require_command python3 || return 1

  local daemon_approval_file workspaces response payload branch terminal_id daemon_device_id
  daemon_approval_file="$(local_token_file local-daemon-approval.json)"
  daemon_device_id="$LOCAL_DEV_TERMINAL_DEVICE_ID"
  if [[ -z "$daemon_device_id" && -s "$daemon_approval_file" ]]; then
    daemon_device_id="$(json_get id < "$daemon_approval_file" 2>/dev/null || true)"
  fi
  terminal_id=""
  if [[ "$WITH_DAEMON" == true && -n "$daemon_device_id" ]]; then
    local terminals
    for _ in $(seq 1 50); do
      terminals="$(http_request workspace.terminals \
        -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
        "http://$RELAY_ADDR/v1/terminals")" || return 1
      terminal_id="$(printf '%s' "$terminals" | LOCAL_DEV_TERMINAL_DEVICE_ID="$daemon_device_id" python3 -c 'import json, os, sys
doc=json.load(sys.stdin)
device_id=os.environ["LOCAL_DEV_TERMINAL_DEVICE_ID"]
for item in doc.get("terminals", []):
    if isinstance(item, dict) and item.get("device_id") == device_id:
        print(item.get("id", ""))
        raise SystemExit(0)
raise SystemExit(1)' 2>/dev/null || true)"
      if [[ -n "$terminal_id" ]]; then
        break
      fi
      sleep 0.1
    done
    if [[ -z "$terminal_id" ]]; then
      echo "workspace: local dev Terminal has not registered with Relay" >&2
      return 1
    fi
  fi
  workspaces="$(http_request workspace.list \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    "http://$RELAY_ADDR/v1/workspaces")" || return 1
  if printf '%s' "$workspaces" | LOCAL_DEV_WORKSPACE_ID="$LOCAL_DEV_WORKSPACE_ID" python3 -c 'import json, os, sys
doc=json.load(sys.stdin)
target=os.environ["LOCAL_DEV_WORKSPACE_ID"]
raise SystemExit(0 if any(isinstance(item, dict) and item.get("id")==target for item in doc.get("workspaces", [])) else 1)' 2>/dev/null; then
    echo "workspace: using cached local dev Workspace $LOCAL_DEV_WORKSPACE_ID"
    if [[ "$WITH_DAEMON" == true ]]; then
      confirm_local_dev_workspace || return 1
      sync_local_dev_dsh_workspace || return 1
    fi
    return 0
  fi
  branch=""
  if command -v git >/dev/null 2>&1; then
    branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
  fi
  payload="$(python3 -c 'import json, sys
project_id, terminal_id, canonical_root, branch = sys.argv[1:5]
doc = {"project_id": project_id, "canonical_root": canonical_root, "status": "active"}
if terminal_id:
    doc["terminal_id"] = terminal_id
if branch:
    doc["branch"] = branch
print(json.dumps(doc, separators=(",", ":")))' "$LOCAL_DEV_PROJECT_ID" "$terminal_id" "$ROOT_DIR" "$branch")"
  response="$(http_request workspace.create \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    -d "$payload" \
    "http://$RELAY_ADDR/v1/workspaces")" || return 1
  local created_id
  created_id="$(printf '%s' "$response" | json_get id)"
  if [[ "$created_id" != "$LOCAL_DEV_WORKSPACE_ID" ]]; then
    echo "workspace: Relay returned unexpected local dev Workspace id $created_id (expected $LOCAL_DEV_WORKSPACE_ID)" >&2
    return 1
  fi
  echo "workspace: registered local dev Workspace $LOCAL_DEV_WORKSPACE_ID${terminal_id:+ for Terminal $terminal_id}"
  if [[ "$WITH_DAEMON" == true ]]; then
    confirm_local_dev_workspace || return 1
    sync_local_dev_dsh_workspace || return 1
  fi
}

# DSH 工作区不能由 workspace.create 直接伪装登记为 origin=dsh；只有 Daemon
# 扫描并回传受控候选后，Relay 才会创建/升级 DSH 投影。localdev 启动时自动跑一次
# 正式同步，确保 Flutter 不会拿 managed 的 ws_local-dev 作为 DSH 工作区。
sync_local_dev_dsh_workspace() {
  if [[ "$WITH_RELAY" != true || "$WITH_DAEMON" != true ]] || ! truthy "$LOCAL_DEV_PAIRING"; then
    return 0
  fi
  require_command curl || return 1
  require_command python3 || return 1

  local response command_id state status workspaces project_name
  response="$(http_request workspace.sync_dsh \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    -d '{}' \
    "http://$RELAY_ADDR/v1/workspaces/sync-dsh")" || return 1
  command_id="$(printf '%s' "$response" | json_get command_id 2>/dev/null || true)"
  status="$(printf '%s' "$response" | json_get status 2>/dev/null || true)"

  if [[ "$status" == "pending" || "$status" == "accepted" ]]; then
    if [[ -z "$command_id" ]]; then
      echo "workspace: DSH sync response has no command id" >&2
      return 1
    fi
    for _ in $(seq 1 300); do
      state="$(http_request workspace.sync_dsh.status \
        -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
        "http://$RELAY_ADDR/v1/workspaces/sync-dsh/$command_id")" || return 1
      status="$(printf '%s' "$state" | json_get status 2>/dev/null || true)"
      if [[ "$status" != "pending" && "$status" != "accepted" ]]; then
        response="$state"
        break
      fi
      sleep 0.2
    done
  fi

  if [[ "$status" != "succeeded" ]]; then
    local error_code
    error_code="$(printf '%s' "$response" | json_get error_code 2>/dev/null || true)"
    echo "workspace: DSH sync did not succeed (status=${status:-unknown}${error_code:+ error_code=$error_code})" >&2
    return 1
  fi

  # workspace_ids 只提供 opaque ID；用 Daemon 派生的 display_name 绑定当前项目，
  # 不读取或重新推导 canonical root。
  project_name="$(basename "$ROOT_DIR")"
  workspaces="$(http_request workspace.list \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    "http://$RELAY_ADDR/v1/workspaces")" || return 1
  LOCAL_DEV_DSH_WORKSPACE_ID="$(printf '%s' "$workspaces" | PROJECT_NAME="$project_name" SYNC_RESULT="$response" python3 -c 'import json, os, sys
doc = json.load(sys.stdin)
name = os.environ["PROJECT_NAME"]
result = json.loads(os.environ["SYNC_RESULT"])
synced = {item for item in result.get("workspace_ids", []) if isinstance(item, str)}
for item in doc.get("workspaces", []):
    if (isinstance(item, dict) and item.get("id") in synced and
            item.get("origin") == "dsh" and
            item.get("display_name") == name and item.get("id")):
        print(item["id"])
        raise SystemExit(0)
raise SystemExit(1)' 2>/dev/null || true)"
  if [[ -z "$LOCAL_DEV_DSH_WORKSPACE_ID" ]]; then
    echo "workspace: DSH sync succeeded but current project was not returned" >&2
    return 1
  fi
  echo "workspace: DSH sync ready for local project"
}

confirm_local_dev_workspace() {
  if [[ "$LOCAL_DEV_WORKSPACE_CONFIRMED" == true ]]; then
    return 0
  fi
  require_command go || return 1
  go run ./apps/daemon workspace-confirm --state-dir "$DAEMON_STATE_DIR" \
    --workspace-id "$LOCAL_DEV_WORKSPACE_ID" --workspace-root "$ROOT_DIR"
  LOCAL_DEV_WORKSPACE_CONFIRMED=true
}


reset_default_local_relay_db() {
  if [[ -n "${AGENT_SESSIONS_SQLITE_PATH:-}" ]]; then
    return 1
  fi
  # v0.8.9 P2（V089-08）：restart-flutter 等动作禁止静默重建 Relay DB。
  # 拒绝时给出可操作指引，让用户显式执行完整 restart（停止全部组件→重建→重新配对）。
  if [[ "$RELAY_DB_RESET_ALLOWED" != true ]]; then
    echo "restart.sh: 本次动作需要重建 Relay DB（owner 缓存失效/密钥轮换自愈），但当前动作不允许静默 reset" >&2
    echo "restart.sh: 请执行完整 './restart.sh restart'（会先停止 Daemon 再重建并重新配对）" >&2
    return 1
  fi
  echo "owner: resetting default local dev Relay DB"
  # V089-07 生命周期锁：任何重建 Relay DB 的路径都必须先停止受管与孤儿 Daemon，
  # 再执行 reset→重建→（由调用方完成 owner/daemon pairing）→启动，严格串行。
  # 顺序失败必须 fail-closed，不能带着仍在运行的旧 Daemon 继续删除库文件。
  stop_process daemon || true
  if ! stop_orphan_daemons; then
    echo "restart.sh: 孤儿 Daemon 清理失败；拒绝在 Daemon 存活时重建 Relay DB" >&2
    return 1
  fi
  stop_relay || return 1
  rm -f "$RELAY_DB_PATH" "$RELAY_DB_PATH-shm" "$RELAY_DB_PATH-wal"
  rm -f     "$(local_token_file local-owner-token)"     "$(local_token_file local-owner-bootstrap.json)"     "$(local_token_file local-daemon-token)"     "$(local_token_file local-daemon-approval.json)"
  start_relay || return 1
}

reset_local_pairing_cache_if_scope_changed() {
  local scope_file desired_scope existing_scope
  scope_file="$(local_token_file local-pairing-scope)"
  desired_scope="$RELAY_ADDR|$RELAY_DB_PATH"
  existing_scope=""
  [[ -f "$scope_file" ]] && existing_scope="$(cat "$scope_file")"
  if [[ "$existing_scope" != "$desired_scope" ]]; then
    rm -f \
      "$(local_token_file local-owner-token)" \
      "$(local_token_file local-owner-bootstrap.json)" \
      "$(local_token_file local-daemon-token)" \
      "$(local_token_file local-daemon-approval.json)"
    printf '%s\n' "$desired_scope" > "$scope_file"
  fi
}

ensure_local_owner_bootstrap() {
  if [[ "$WITH_RELAY" != true ]] || ! truthy "$LOCAL_DEV_PAIRING"; then
    return 1
  fi
  if [[ "$DRY_RUN" == true ]]; then
    LOCAL_OWNER_ACCESS_TOKEN=local-dev-dry-run-owner-token
    LOCAL_OWNER_BOOTSTRAP_B64=local-dev-dry-run-owner-bootstrap
    return 0
  fi
  require_command curl || return 1
  require_command python3 || return 1
  mkdir -p "$STATE_DIR"
  reset_local_pairing_cache_if_scope_changed

  local owner_file response refresh_token
  owner_file="$(local_token_file local-owner-bootstrap.json)"
  # 供 start_flutter 把缓存文件路径注入 Flutter（刷新后回写，见 local_dev_bootstrap_io.dart）。
  OWNER_BOOTSTRAP_FILE="$owner_file"
  # v0.8.8 P1（迭代计划 §9.2 冻结决策）：owner 设备使用真实 X25519 密钥对 bootstrap。
  # 此前为占位公钥，daemon 会话 DEK wrap 上行必失败（owner 公钥非法），移动端附件
  # 入口因此恒禁用。密钥文件幂等（encryption-keygen 回放公钥）；私钥仅落本机 state
  # 目录（0600），经 dart-define 注入 localdev 调试壳，生产 Android Keystore 路径不变。
  OWNER_ENCRYPTION_SEED_FILE="$STATE_DIR/owner_encryption_seed.b64"
  OWNER_ENCRYPTION_PUBLIC_KEY="$(go run "$ROOT_DIR/apps/daemon" encryption-keygen --out "$OWNER_ENCRYPTION_SEED_FILE")" || return 1
  LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64="$(tr -d '\n' < "$OWNER_ENCRYPTION_SEED_FILE")"
  # 自愈：历史 owner bootstrap 可能登记的是占位公钥（v0.8.8 之前）——daemon 的
  # 会话 DEK wrap 对非法公钥永远失败（附件入口恒禁用）。登记公钥与当前种子公钥
  # 不一致时作废缓存并重置 Relay DB，走全新 bootstrap（一次性代价，幂等收敛）。
  OWNER_KEY_STAMP_FILE="$STATE_DIR/owner_encryption_pub.used"
  if [[ ! -s "$OWNER_KEY_STAMP_FILE" ]] || [[ "$(cat "$OWNER_KEY_STAMP_FILE")" != "$OWNER_ENCRYPTION_PUBLIC_KEY" ]]; then
    rm -f "$owner_file" "$(local_token_file local-owner-token)" "$(local_token_file local-daemon-token)" "$(local_token_file local-daemon-approval.json)"
    reset_default_local_relay_db || true
    echo "owner: encryption key rotated (placeholder -> real X25519); relay db rebuilt"
  fi
  if [[ -s "$owner_file" ]]; then
    refresh_token="$(json_get tokens.refresh_token < "$owner_file")"
    if response="$(http_request owner.refresh \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"refresh_token":sys.argv[1]}))' "$refresh_token")" \
      "http://$RELAY_ADDR/v1/auth/refresh")"; then
      printf '%s' "$response" | json_set_tokens "$owner_file"
      LOCAL_OWNER_ACCESS_TOKEN="$(printf '%s' "$response" | json_get access_token)"
      printf '%s\n' "$LOCAL_OWNER_ACCESS_TOKEN" > "$(local_token_file local-owner-token)"
      chmod 600 "$owner_file" "$(local_token_file local-owner-token)"
      stage_local_owner_bootstrap_for_flutter "$owner_file"
      echo "owner: refreshed cached local dev owner session"
      return 0
    fi
    # v0.9.4 回退（2026-09-21）：桌面调试壳轮换 refresh 后写在用户域缓存
    # （~/.agent-sessions/...；沙箱容器形态下为其 Data/.agent-sessions/...，
    # 见 local_dev_bootstrap_io.dart）。owner 缓存滞留旧值时优先回退读取
    # 桌面壳的最新 refresh，避免走到下面的重置分支。
    local fallback_refresh fallback_file
    for fallback_file in \
      "$HOME/Library/Containers/com.agentsessions.agentSessionsMobile/Data/.agent-sessions/localdev-owner-cache.json" \
      "$HOME/.agent-sessions/localdev-owner-cache.json"; do
      [[ -s "$fallback_file" ]] || continue
      fallback_refresh="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("tokens", {}).get("refresh_token", ""))
except Exception:
    print("")' "$fallback_file" 2>/dev/null || true)"
      [[ -n "$fallback_refresh" ]] && break
    done
    if [[ -n "$fallback_refresh" ]] && response="$(http_request owner.refresh \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"refresh_token":sys.argv[1]}))' "$fallback_refresh")" \
      "http://$RELAY_ADDR/v1/auth/refresh")"; then
      printf '%s' "$response" | json_set_tokens "$owner_file"
      LOCAL_OWNER_ACCESS_TOKEN="$(printf '%s' "$response" | json_get access_token)"
      printf '%s\n' "$LOCAL_OWNER_ACCESS_TOKEN" > "$(local_token_file local-owner-token)"
      chmod 600 "$owner_file" "$(local_token_file local-owner-token)"
      stage_local_owner_bootstrap_for_flutter "$owner_file"
      echo "owner: refreshed from desktop shell cache"
      return 0
    fi
    echo "owner: cached local dev owner expired; rebuilding" >&2
    # v0.9.4 防呆（2026-09-21）：缓存 refresh 失效曾直接重置 Relay DB，导致接入的
    # 手机设备连同令牌一起消失（用户被迫反复恢复码接管）。DB 里存在活跃 Android
    # 设备时拒绝静默重置，明确指引处理路径；无移动设备（纯桌面开发）才维持自愈。
    local active_android
    active_android="$(python3 -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
    print(conn.execute(\"SELECT count(*) FROM devices WHERE status='active' AND platform IN ('android','ios')\").fetchone()[0])
except Exception:
    print(0)
" "$RELAY_DB_PATH" 2>/dev/null || echo 0)"
    if [[ "$active_android" != "0" ]]; then
      echo "owner: refresh failed but $active_android active Android device(s) depend on this Relay DB; refusing silent reset" >&2
      echo "  处理选项：① 在手机 App 用恢复码重新接管后重试；② 确认放弃手机连接时手动删除 $RELAY_DB_PATH 后重试。" >&2
      return 1
    fi
    rm -f "$owner_file" "$(local_token_file local-owner-token)" "$(local_token_file local-daemon-token)" "$(local_token_file local-daemon-approval.json)"
    reset_default_local_relay_db || true
  fi

  if ! response="$(http_request owner.bootstrap \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"display_name":"Local Dev Android Owner","platform":"local","identity_public_key":"local-dev-owner-identity-public-key","encryption_public_key":"%s"}' "$OWNER_ENCRYPTION_PUBLIC_KEY")" \
    "http://$RELAY_ADDR/v1/auth/device-bootstrap")"; then
    if reset_default_local_relay_db; then
      response="$(http_request owner.bootstrap_after_reset \
        -H 'Content-Type: application/json' \
        -d "$(printf '{"display_name":"Local Dev Android Owner","platform":"local","identity_public_key":"local-dev-owner-identity-public-key","encryption_public_key":"%s"}' "$OWNER_ENCRYPTION_PUBLIC_KEY")" \
        "http://$RELAY_ADDR/v1/auth/device-bootstrap")" || {
          echo "owner: local dev owner bootstrap failed after resetting $RELAY_DB_PATH" >&2
          return 1
        }
    else
      echo "owner: local dev owner bootstrap failed; clear $RELAY_DB_PATH or disable local dev pairing" >&2
      return 1
    fi
  fi
  printf '%s\n' "$response" > "$owner_file"
  LOCAL_OWNER_ACCESS_TOKEN="$(printf '%s' "$response" | json_get tokens.access_token)"
  printf '%s\n' "$LOCAL_OWNER_ACCESS_TOKEN" > "$(local_token_file local-owner-token)"
  chmod 600 "$owner_file" "$(local_token_file local-owner-token)"
  stage_local_owner_bootstrap_for_flutter "$owner_file"
  printf '%s\n' "$OWNER_ENCRYPTION_PUBLIC_KEY" > "$OWNER_KEY_STAMP_FILE"
  echo "owner: bootstrapped local dev owner via Relay"
}

# ensure_daemon_signing_key 保证本机 Terminal 身份密钥文件存在并输出对应公钥。
# 幂等：文件已存在时由 daemon keygen 直接回放其公钥，同一状态目录永远同一身份。
# 全局副作用：DAEMON_SIGNING_KEY_FILE（密钥路径）、DAEMON_SIGNING_KEY_REGENERATED
# （本次调用是否新建了密钥文件，用于判定缓存配对是否失效）。
ensure_daemon_signing_key() {
  DAEMON_SIGNING_KEY_FILE="$DAEMON_STATE_DIR/terminal_signing_seed.b64"
  DAEMON_SIGNING_KEY_REGENERATED=""
  local pub
  if [[ ! -s "$DAEMON_SIGNING_KEY_FILE" ]]; then
    mkdir -p "$DAEMON_STATE_DIR"
    DAEMON_SIGNING_KEY_REGENERATED=1
    echo "terminal-signing: generating local identity key at $DAEMON_SIGNING_KEY_FILE" >&2
  fi
  pub="$(go run ./apps/daemon keygen --out "$DAEMON_SIGNING_KEY_FILE")" || return 1
  printf '%s' "$pub"
}

ensure_daemon_token() {
  if [[ "$WITH_DAEMON" != true ]]; then return 0; fi
  if [[ -n "$DAEMON_ACCESS_TOKEN" ]]; then
    DAEMON_TOKEN_SOURCE=env
    # 外部 token + 签名开关但本机无私钥文件时，Daemon 只能保持 bearer；
    # 显式告知操作者，而不是静默忽略签名开关。
    if truthy "$TERMINAL_SIGNING" && [[ ! -s "$DAEMON_STATE_DIR/terminal_signing_seed.b64" ]]; then
      echo "terminal-signing: 外部 token 且 $DAEMON_STATE_DIR/terminal_signing_seed.b64 不存在；Daemon 将保持 bearer 桥接" >&2
    fi
    return 0
  fi
  if [[ "$WITH_RELAY" != true ]] || ! truthy "$LOCAL_DEV_PAIRING"; then
    print_missing_daemon_token_hint
    return 1
  fi
  if [[ "$DRY_RUN" == true ]]; then
    DAEMON_ACCESS_TOKEN=local-dev-dry-run-token
    DAEMON_TOKEN_SOURCE=local-dev-dry-run
    return 0
  fi
  ensure_local_owner_bootstrap || return 1

  local daemon_approval_file daemon_refresh
  daemon_approval_file="$(local_token_file local-daemon-approval.json)"
  # v0.6 残余项收口：签名模式下先确保本机身份密钥就绪。密钥文件新建而缓存配对
  # 仍绑定旧公钥（或旧占位符）时，必须作废缓存重新配对，否则 hello 验签必然
  # fail-closed；这是有意的确定性失败，不能靠重试掩盖。
  local signing_pub=""
  if truthy "$TERMINAL_SIGNING"; then
    signing_pub="$(ensure_daemon_signing_key)" || return 1
    if [[ -n "$DAEMON_SIGNING_KEY_REGENERATED" && -s "$daemon_approval_file" ]]; then
      echo "terminal-signing: 新建了本机身份密钥，缓存 Terminal 配对与新公钥不匹配；重建配对" >&2
      rm -f "$(local_token_file local-daemon-token)" "$daemon_approval_file"
    fi
  fi
  if [[ -s "$daemon_approval_file" ]]; then
    daemon_refresh="$(json_get tokens.refresh_token < "$daemon_approval_file")"
    if response="$(http_request daemon.refresh \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"refresh_token":sys.argv[1]}))' "$daemon_refresh")" \
      "http://$RELAY_ADDR/v1/auth/refresh")"; then
      printf '%s' "$response" | json_set_tokens "$daemon_approval_file"
      DAEMON_ACCESS_TOKEN="$(printf '%s' "$response" | json_get access_token)"
      LOCAL_DEV_TERMINAL_DEVICE_ID="$(json_get id < "$daemon_approval_file" 2>/dev/null || true)"
      printf '%s\n' "$DAEMON_ACCESS_TOKEN" > "$(local_token_file local-daemon-token)"
      chmod 600 "$(local_token_file local-daemon-token)" "$daemon_approval_file"
      DAEMON_TOKEN_SOURCE=local-dev-cache
      echo "daemon: refreshed cached local dev Terminal pairing"
      return 0
    fi
    echo "daemon: cached local dev Terminal expired; rebuilding" >&2
    rm -f "$(local_token_file local-daemon-token)" "$daemon_approval_file"
    if reset_default_local_relay_db; then
      ensure_local_owner_bootstrap || return 1
    fi
  fi

  local response pairing_id
  response="$(http_request daemon.pairing_request \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    -d "{\"role\":\"terminal\",\"display_name\":\"Local Dev Terminal\",\"platform\":\"local\",\"identity_public_key\":\"${signing_pub:-local-dev-terminal-identity-public-key}\",\"encryption_public_key\":\"local-dev-terminal-encryption-public-key\"}" \
    "http://$RELAY_ADDR/v1/pairing/requests")" || return 1
  pairing_id="$(printf '%s' "$response" | json_get id)"
  response="$(http_request daemon.pairing_approve \
    -H "Authorization: Bearer $LOCAL_OWNER_ACCESS_TOKEN" \
    -X POST "http://$RELAY_ADDR/v1/pairing/requests/$pairing_id/approve")" || return 1
  printf '%s\n' "$response" > "$(local_token_file local-daemon-approval.json)"
  LOCAL_DEV_TERMINAL_DEVICE_ID="$(printf '%s' "$response" | json_get id)"
  DAEMON_ACCESS_TOKEN="$(printf '%s' "$response" | json_get tokens.access_token)"
  printf '%s\n' "$DAEMON_ACCESS_TOKEN" > "$(local_token_file local-daemon-token)"
  chmod 600 "$(local_token_file local-daemon-token)" "$(local_token_file local-daemon-approval.json)"
  DAEMON_TOKEN_SOURCE=local-dev-pairing
  echo "daemon: paired local dev Terminal via Relay"
}

start_web() {
  local file pid
  file="$(pid_file web)"
  pid="$(read_pid "$file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && is_running "$pid" && component_matches web "$pid"; then
    echo "web: already running (pid $pid)"
    return 0
  fi
  if port_in_use "$WEB_PORT"; then
    echo "web: port $WEB_PORT is already in use; refusing to stop an unrelated process" >&2
    return 1
  fi
  start_process web "$file" "$(component_log web)" "$ROOT_DIR/apps/web" env VITE_RELAY_URL="http://$RELAY_ADDR" pnpm exec vite --host 127.0.0.1 --port "$WEB_PORT" --strictPort
  STARTED_WEB=true
  pid="$(read_pid "$file")"
  wait_for_http web "http://127.0.0.1:$WEB_PORT" "$pid"
}

start_admin() {
  local file pid
  file="$(pid_file admin)"
  pid="$(read_pid "$file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && is_running "$pid" && component_matches admin "$pid"; then
    echo "admin: already running (pid $pid)"
    return 0
  fi
  if port_in_use "$ADMIN_PORT"; then
    echo "admin: port $ADMIN_PORT is already in use; refusing to stop an unrelated process" >&2
    return 1
  fi
  start_process admin "$file" "$(component_log admin)" "$ROOT_DIR/apps/admin-web" env VITE_RELAY_URL="http://$RELAY_ADDR" pnpm exec vite --host 127.0.0.1 --port "$ADMIN_PORT" --strictPort
  STARTED_ADMIN=true
  pid="$(read_pid "$file")"
  wait_for_http admin "http://127.0.0.1:$ADMIN_PORT" "$pid"
}

# v0.9.7 阶段 0.3：DSH 桥预检（fail-fast）。桥以路径钉扎消费外部检出
# （internal/adapter/dsh/bridge.go 的 defaultBin/defaultConfig + 产品 cordis.yml
# 里的插件绝对路径）；检出被还原或 lib 构建产物被清理时，daemon 仍能启动但
# 新建 DSH 会话必败。这里在 daemon 启动前把两类路径校验掉，缺失即报修复指引。
check_dsh_bridge_preflight() {
  if [[ "$WITH_DAEMON" != true ]]; then return 0; fi
  local -a missing=() candidates=()
  # 桥入口：env 优先；未设时与 bridge.go 的 defaultBin 保持一致（改动需同步）。
  candidates+=("${AGENT_SESSIONS_DSH_BIN:-/Users/yubi/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js}")
  # 组合文件：restart.sh 注入产品根 cordis.yml（1275-1277 行同一优先级）。
  candidates+=("${AGENT_SESSIONS_DSH_CONFIG:-$ROOT_DIR/cordis.yml}")
  # 产品组合引用的全部插件绝对路径（name: '/…/lib/index.js'）。
  local config="${AGENT_SESSIONS_DSH_CONFIG:-$ROOT_DIR/cordis.yml}"
  if [[ -f "$config" ]]; then
    while IFS= read -r plugin; do
      [[ -n "$plugin" ]] && candidates+=("$plugin")
    done < <(sed -n "s/^.*name: '\(\/[^']*\)'.*$/\1/p" "$config")
  fi
  local path
  for path in "${candidates[@]}"; do
    [[ -f "$path" ]] || missing+=("$path")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "dsh bridge preflight: 桥钉扎路径缺失，新建 DSH 会话将失败：" >&2
    local item
    for item in "${missing[@]}"; do echo "  缺失: $item" >&2; done
    echo "  修复指引: tools/dsh-bridge-patches/README.md（重建链 + 冒烟验收）" >&2
    return 1
  fi
}

start_daemon() {
  if ! check_dsh_bridge_preflight; then
    return 1
  fi
  if [[ -z "$DAEMON_ACCESS_TOKEN" ]]; then
    echo "daemon: missing access token after pairing" >&2
    return 1
  fi
  # DSH_* 仅在非空时转发：空字符串会被 Daemon 判定为"显式置空"而 fail-closed，
  # 未设置时 Daemon 才会回退到 internal/adapter/dsh/bridge.go 里的本机 checkout 默认路径。
  local args=(env AGENT_SESSIONS_DAEMON_TOKEN="$DAEMON_ACCESS_TOKEN" AGENT_SESSIONS_OPENCODE_URL="$OPENCODE_URL" OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-}" OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-}" AGENT_SESSIONS_EVENT_LOCAL_DEV_PLAINTEXT=1 )
  if [[ -n "$OPENCODE_DEFAULT_MODEL" ]]; then args+=(AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL="$OPENCODE_DEFAULT_MODEL"); fi
  if [[ -n "${AGENT_SESSIONS_DSH_BIN:-}" ]]; then args+=(AGENT_SESSIONS_DSH_BIN="$AGENT_SESSIONS_DSH_BIN"); fi
  if [[ -n "${AGENT_SESSIONS_DSH_CONFIG:-}" ]]; then args+=(AGENT_SESSIONS_DSH_CONFIG="$AGENT_SESSIONS_DSH_CONFIG"); fi
  # 本地个人 LLM 组合优先：仓库根的 cordis.yml（dsh-happy-init 生成，gitignore，见
  # b139f5e）承载 opencode-go 等第三方端点与凭据挂载；缺省时才回落 daemon 内置示例。
  if [[ -z "${AGENT_SESSIONS_DSH_CONFIG:-}" && -f "$ROOT_DIR/cordis.yml" ]]; then
    args+=(AGENT_SESSIONS_DSH_CONFIG="$ROOT_DIR/cordis.yml")
  fi
  if [[ -n "${AGENT_SESSIONS_DSH_PERSIST_ROOT:-}" ]]; then args+=(AGENT_SESSIONS_DSH_PERSIST_ROOT="$AGENT_SESSIONS_DSH_PERSIST_ROOT"); fi
  if [[ -n "${AGENT_SESSIONS_DSH_PERSIST_COMPRESSION:-}" ]]; then args+=(AGENT_SESSIONS_DSH_PERSIST_COMPRESSION="$AGENT_SESSIONS_DSH_PERSIST_COMPRESSION"); fi
  # Codex 适配器透传（非空才转发）：ENABLE 是 W4 灰度注册开关，BIN 指向被 --version
  # 探测的 codex CLI；任一缺失时 Daemon fail-closed，Codex 能力整体 unsupported。
  if [[ -n "${AGENT_SESSIONS_CODEX_ENABLE:-}" ]]; then args+=(AGENT_SESSIONS_CODEX_ENABLE="$AGENT_SESSIONS_CODEX_ENABLE"); fi
  if [[ -n "${AGENT_SESSIONS_CODEX_BIN:-}" ]]; then args+=(AGENT_SESSIONS_CODEX_BIN="$AGENT_SESSIONS_CODEX_BIN"); fi
  # v0.6：签名模式向 Daemon 注入本机私钥文件路径；未启用/文件缺失时保持 bearer 行为
  if truthy "$TERMINAL_SIGNING" && [[ -n "$DAEMON_SIGNING_KEY_FILE" && -s "$DAEMON_SIGNING_KEY_FILE" ]]; then
    args+=(AGENT_SESSIONS_DAEMON_SIGNING_KEY_FILE="$DAEMON_SIGNING_KEY_FILE")
  fi
  args+=(go run ./apps/daemon run --relay-base "http://$RELAY_ADDR" --state-dir "$DAEMON_STATE_DIR")
  if [[ "$FIXTURE_DAEMON" == true ]]; then
    args+=(--fixture-adapter)
  fi
  DAEMON_HEARTBEAT_BASELINE="$(local_dev_terminal_last_seen 2>/dev/null || printf '0')"
  if ! [[ "$DAEMON_HEARTBEAT_BASELINE" =~ ^[0-9]+$ ]]; then
    DAEMON_HEARTBEAT_BASELINE=0
  fi
  if ! start_process daemon "$(pid_file daemon)" "$(component_log daemon)" "$ROOT_DIR" "${args[@]}"; then
    return 1
  fi
  STARTED_DAEMON=true
  wait_for_daemon "$(read_pid "$(pid_file daemon)")"
}

start_flutter() {
  local file pid
  file="$(pid_file flutter)"
  pid="$(read_pid "$file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && is_running "$pid" && component_matches flutter "$pid"; then
    echo "flutter: already running (pid $pid; target $FLUTTER_TARGET)"
    return 0
  fi
  local args=("$FLUTTER_BIN" run -d "$FLUTTER_TARGET" --no-pub "--dart-define=RELAY_BASE_URL=$FLUTTER_RELAY_BASE")
  if [[ -n "$LOCAL_OWNER_BOOTSTRAP_B64" && "$FLUTTER_MODE" == "mac" ]]; then
    args+=("--dart-define=LOCAL_DEV_OWNER_BOOTSTRAP_B64=$LOCAL_OWNER_BOOTSTRAP_B64")
  fi
  # v0.9.4（2026-09-21）：桌面壳轮换 refresh 后自行回写用户域缓存
  # （~/.agent-sessions/localdev-owner-cache.json，见 local_dev_bootstrap_io.dart）；
  # 不再经 dart-define 传 state 目录路径——provenance 隔离会让 Flutter 打开该文件 EPERM。
  # v0.8.8 P1：localdev owner X25519 私钥播种（迭代计划 §9.2）——仅 localdev 调试壳；
  # 与 owner.bootstrap 的真实公钥配对，使 daemon 会话 DEK wrap 可被本机 unwrap。
  if [[ -n "$LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64" && "$FLUTTER_MODE" == "mac" ]]; then
    args+=("--dart-define=LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64=$LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64")
  fi
  if [[ "$FLUTTER_MODE" == "mac" && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    args+=("--dart-define=LOCAL_DEV_WORKSPACE_ID=${LOCAL_DEV_DSH_WORKSPACE_ID:-$LOCAL_DEV_WORKSPACE_ID}")
  fi
  if [[ -n "$FLUTTER_TARGET_SESSION_ID" && "$FLUTTER_MODE" == "mac" ]]; then
    args+=("--dart-define=LOCAL_DEV_TARGET_SESSION_ID=$FLUTTER_TARGET_SESSION_ID")
  fi
  if [[ -n "${LOCAL_VISUAL_FRAME_DIRECTORY:-}" && "$FLUTTER_MODE" == "mac" ]]; then
    args+=("--dart-define=LOCAL_VISUAL_FRAME_DIRECTORY=$LOCAL_VISUAL_FRAME_DIRECTORY")
    args+=("--dart-define=LOCAL_VISUAL_FRAME_COUNT=${LOCAL_VISUAL_FRAME_COUNT:-0}")
    args+=("--dart-define=LOCAL_VISUAL_FRAME_INTERVAL_MS=${LOCAL_VISUAL_FRAME_INTERVAL_MS:-0}")
  fi
  start_process flutter "$file" "$(component_log flutter)" "$ROOT_DIR/apps/mobile" "${args[@]}"
  STARTED_FLUTTER=true
  pid="$(read_pid "$file")"
  wait_for_flutter "$pid"
}

start_opencode() {
  if [[ "$WITH_OPENCODE" != true ]]; then
    return 0
  fi
  require_command "$OPENCODE_BIN" || return 1
  if port_in_use "$OPENCODE_PORT"; then
    local existing_pid
    existing_pid="$(lsof -nP -t -iTCP:"$OPENCODE_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    if [[ -n "$existing_pid" ]] && component_matches opencode "$existing_pid"; then
      echo "opencode: already running (pid $existing_pid)"
      echo "$OPENCODE_URL" > "$STATE_DIR/opencode-url"
      return 0
    fi
    echo "opencode: port $OPENCODE_PORT is already in use; refusing to stop an unrelated process" >&2
    return 1
  fi
  start_process opencode "$(pid_file opencode)" "$(component_log opencode)" "$ROOT_DIR" \
    "$OPENCODE_BIN" serve --hostname "$OPENCODE_HOST" --port "$OPENCODE_PORT" --print-logs
  echo "$OPENCODE_URL" > "$STATE_DIR/opencode-url"
  local pid
  pid="$(read_pid "$(pid_file opencode)")"
  wait_for_http opencode "$OPENCODE_URL/global/health" "$pid"
  STARTED_OPENCODE=true
}

start_relay() {
  require_command go || return 1
  require_command curl || return 1
  mkdir -p "$STATE_DIR"
  local relay_pid_file="$ROOT_DIR/.task/relay.pid" relay_pid=""
  if [[ -f "$relay_pid_file" ]]; then
    relay_pid="$(read_pid "$relay_pid_file" 2>/dev/null || true)"
  fi
  if [[ -n "$relay_pid" ]] && is_running "$relay_pid"; then
    if relay_matches "$relay_pid"; then
      if curl --fail --silent --show-error --max-time 1 "http://$RELAY_ADDR/readyz" >/dev/null 2>&1; then
        echo "relay: already running (pid $relay_pid; managed by tools/relayctl.sh)"
        return 0
      fi
      echo "relay: owned process is running but not ready at http://$RELAY_ADDR/readyz" >&2
      return 1
    fi
    echo "relay: refusing to reuse pid file for unrelated process $relay_pid" >&2
    return 1
  fi
  echo "relay: delegating start to tools/relayctl.sh"
  # Relay 侧能力矩阵（/v1/capabilities）会实时探测 OpenCode Server；URL 必须与
  # Daemon 一致，否则 Server 明明在跑、App 仍显示 Provider 不可用。凭据非空才透传，
  # 避免把 Basic Auth 凭据扩散到不需要它的部署形态。
  local relay_probe_env=()
  relay_probe_env+=(AGENT_SESSIONS_OPENCODE_URL="$OPENCODE_URL")
  if [[ -n "$OPENCODE_DEFAULT_MODEL" ]]; then relay_probe_env+=(AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL="$OPENCODE_DEFAULT_MODEL"); fi
  if [[ -n "${OPENCODE_SERVER_USERNAME:-}" ]]; then relay_probe_env+=(OPENCODE_SERVER_USERNAME="$OPENCODE_SERVER_USERNAME"); fi
  if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then relay_probe_env+=(OPENCODE_SERVER_PASSWORD="$OPENCODE_SERVER_PASSWORD"); fi
  # DSH 桥配置必须与 Daemon 一致透传：Relay 侧能力矩阵（/v1/capabilities 与
  # session controls）由内嵌 DSH Adapter 的 Detect 握手生成，桥加载的 cordis
  # 决定渠道/模型/推理档位目录。只给 Daemon 传而漏掉 Relay，会让移动端看到
  # 与真实会话执行不一致的模型目录（默认 config 的浅目录）。
  if [[ -n "${AGENT_SESSIONS_DSH_BIN:-}" ]]; then relay_probe_env+=(AGENT_SESSIONS_DSH_BIN="$AGENT_SESSIONS_DSH_BIN"); fi
  if [[ -n "${AGENT_SESSIONS_DSH_CONFIG:-}" ]]; then
    relay_probe_env+=(AGENT_SESSIONS_DSH_CONFIG="$AGENT_SESSIONS_DSH_CONFIG")
  elif [[ -f "$ROOT_DIR/cordis.yml" ]]; then
    relay_probe_env+=(AGENT_SESSIONS_DSH_CONFIG="$ROOT_DIR/cordis.yml")
  fi
  if [[ -n "${AGENT_SESSIONS_DSH_PERSIST_ROOT:-}" ]]; then relay_probe_env+=(AGENT_SESSIONS_DSH_PERSIST_ROOT="$AGENT_SESSIONS_DSH_PERSIST_ROOT"); fi
  if [[ -n "${AGENT_SESSIONS_DSH_PERSIST_COMPRESSION:-}" ]]; then relay_probe_env+=(AGENT_SESSIONS_DSH_PERSIST_COMPRESSION="$AGENT_SESSIONS_DSH_PERSIST_COMPRESSION"); fi
  if ! env "${relay_probe_env[@]}" RELAY_ADDR="$RELAY_ADDR" RELAY_DB_PATH="$RELAY_DB_PATH" "$ROOT_DIR/tools/relayctl.sh" up; then
    return 1
  fi
  printf 'owned\n' > "$STATE_DIR/relay-owned"
  STARTED_RELAY=true
}

stop_relay() {
  if [[ ! -f "$STATE_DIR/relay-owned" ]]; then
    echo "relay: not owned by this restart.sh state; leaving it untouched"
    return 0
  fi
  local relay_pid_file="$ROOT_DIR/.task/relay.pid" relay_pid=""
  if [[ -f "$relay_pid_file" ]]; then relay_pid="$(read_pid "$relay_pid_file" 2>/dev/null || true)"; fi
  if [[ -n "$relay_pid" ]] && is_running "$relay_pid" && ! relay_matches "$relay_pid"; then
    echo "relay: refusing to stop unrelated pid $relay_pid" >&2
    return 1
  fi
  if RELAY_ADDR="$RELAY_ADDR" RELAY_DB_PATH="$RELAY_DB_PATH" "$ROOT_DIR/tools/relayctl.sh" down; then
    rm -f "$STATE_DIR/relay-owned"
    return 0
  fi
  return 1
}

cleanup_start_failure() {
  echo "restart.sh: startup failed; cleaning processes started by this invocation" >&2
  [[ "$STARTED_FLUTTER" == true ]] && stop_process flutter || true
  [[ "$STARTED_DAEMON" == true ]] && stop_process daemon || true
  stop_orphan_daemons || true
  [[ "$STARTED_OPENCODE" == true ]] && stop_process opencode || true
  [[ "$STARTED_ADMIN" == true ]] && stop_process admin || true
  [[ "$STARTED_WEB" == true ]] && stop_process web || true
  [[ "$STARTED_RELAY" == true ]] && stop_relay || true
}

start_action() {
  mkdir -p "$STATE_DIR"
  if ! preflight_start; then
    return 1
  fi
  printf '%s\n' "$LOG_DIR" > "$STATE_DIR/log-dir"
  if [[ "$WITH_FLUTTER" == true ]]; then
    printf '%s\n' "$FLUTTER_TARGET" > "$STATE_DIR/flutter-target"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "restart.sh dry-run"
    echo "  relay: $WITH_RELAY ($RELAY_ADDR; db $RELAY_DB_PATH)"
    ensure_daemon_token || return 1
    if [[ "$WITH_FLUTTER" == true && "$FLUTTER_MODE" == "mac" && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
      ensure_local_owner_bootstrap || return 1
    fi
    echo "  daemon: $WITH_DAEMON (fixture=$FIXTURE_DAEMON token_source=$DAEMON_TOKEN_SOURCE)"
    echo "  opencode: $WITH_OPENCODE ($OPENCODE_URL)"
    # dsh 采用 per-session 子进程拓扑（ADR-013 §3）：无长驻组件，仅透传桥路径/配置给
    # Daemon；未配置或路径缺失时 Daemon 侧 Detect 会 fail-closed 为 unavailable，这里如实提示。
    local dsh_bin="${AGENT_SESSIONS_DSH_BIN:-}"
    if [[ -n "$dsh_bin" && ! -f "$dsh_bin" ]]; then
      echo "  dsh: bridge=$dsh_bin (路径不存在；provider 将以 unavailable 呈现)" >&2
    fi
    echo "  dsh: bridge=${dsh_bin:-<unset>} (config=${AGENT_SESSIONS_DSH_CONFIG:-<unset>}; persist_root=${AGENT_SESSIONS_DSH_PERSIST_ROOT:-<temp-cleanup>}; compression=${AGENT_SESSIONS_DSH_PERSIST_COMPRESSION:-none}; per-session spawn)"
  # codex 透传状态如实呈现：ENABLE 缺失 = 适配器不注册；BIN 缺失/不可执行 = 探测必败。
  local codex_bin="${AGENT_SESSIONS_CODEX_BIN:-}"
  if [[ -n "${AGENT_SESSIONS_CODEX_ENABLE:-}" && -z "$codex_bin" ]]; then
    echo "  codex: ENABLE 已设但 BIN 未设；适配器会注册但探测必失败（unavailable）" >&2
  fi
  if [[ -n "$codex_bin" && ! -x "$codex_bin" ]]; then
    echo "  codex: bin=$codex_bin (不可执行；provider 将以 unavailable 呈现)" >&2
  fi
  echo "  codex: enable=${AGENT_SESSIONS_CODEX_ENABLE:-<unset>} bin=${codex_bin:-<unset>}"
    echo "  relay-opencode-probe: $OPENCODE_URL (透传给 Relay，能力矩阵实时探测用)"
    echo "  opencode-default-model: ${OPENCODE_DEFAULT_MODEL:-<dynamic-free-catalog>}"
    echo "  flutter: $WITH_FLUTTER (mode=$FLUTTER_MODE target=$FLUTTER_TARGET relay=$FLUTTER_RELAY_BASE owner_bootstrap=${LOCAL_OWNER_BOOTSTRAP_B64:+true} workspace=$LOCAL_DEV_WORKSPACE_ID target_session=${FLUTTER_TARGET_SESSION_ID:-<unset>})"
    if truthy "$TERMINAL_SIGNING"; then
      echo "  terminal-signing: on (key=$DAEMON_STATE_DIR/terminal_signing_seed.b64)"
    else
      echo "  terminal-signing: off (bearer bridge, N/N-1 兼容窗口)"
    fi
    echo "  web: $WITH_WEB (127.0.0.1:$WEB_PORT)"
    echo "  admin: $WITH_ADMIN (127.0.0.1:$ADMIN_PORT)"
    return 0
  fi
  if [[ "$CLEAN_PORTS" == true ]] && ! cleanup_selected_ports; then
    echo "restart.sh: port cleanup failed; refusing to start services" >&2
    return 1
  fi
  if [[ "$WITH_RELAY" == true ]] && ! start_relay; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_OPENCODE" == true ]] && ! start_opencode; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_DAEMON" == true ]] && ! ensure_daemon_token; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_FLUTTER" == true && "$FLUTTER_MODE" == "mac" && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    if ! ensure_local_owner_bootstrap; then cleanup_start_failure; return 1; fi
  fi
  # 本机确认会另起一个 daemon CLI 进程并打开同一个 SQLite。必须在常驻
  # Daemon 启动前串行完成，避免两个进程同时执行初始化迁移。
  if [[ "$WITH_DAEMON" == true && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    if ! confirm_local_dev_workspace; then cleanup_start_failure; return 1; fi
  fi
  if [[ "$WITH_DAEMON" == true ]] && ! start_daemon; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    if ! ensure_local_dev_workspace; then cleanup_start_failure; return 1; fi
  fi
  if [[ "$WITH_FLUTTER" == true ]] && ! start_flutter; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_WEB" == true ]] && ! start_web; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_ADMIN" == true ]] && ! start_admin; then cleanup_start_failure; return 1; fi
  echo "restart.sh: selected services are running"
}

restart_action() {
  # Restart is the recovery path: after stopping owned PIDs, release stale
  # listeners left by an older script or a crashed dev server.
  if ! preflight_start; then
    return 1
  fi
  stop_action || true
  if [[ "$CLEAN_PORTS_SET" == false ]]; then CLEAN_PORTS=true; fi
  start_action
}

restart_flutter_action() {
  if [[ "$WITH_FLUTTER" != true ]]; then
    echo "restart.sh: restart-flutter requires Flutter; remove --no-flutter" >&2
    return 2
  fi
  # v0.8.9 P2（V089-08）：restart-flutter 不得静默重建 Relay DB。需要 reset 时
  # ensure_local_owner_bootstrap 会以可操作错误失败（此时尚未触碰 Flutter 进程），
  # 用户按提示执行完整 restart 即可；这消灭了"Daemon 运行中换库"的 generation 窗口。
  RELAY_DB_RESET_ALLOWED=false
  # --no-relay 时会跳过 localdev owner bootstrap 刷新与 dart-define 播种（重连后的
  # App 将停在非 localdev 欢迎页、不发任何请求）。这里显式提示，防止误判为故障。
  if [[ "$WITH_RELAY" != true && "$FLUTTER_MODE" == "mac" ]] && truthy "$LOCAL_DEV_PAIRING"; then
    echo "restart.sh: --no-relay 下 restart-flutter 不刷新/播种 localdev owner bootstrap；App 将停在连接页。如需带账号数据重连请执行 './restart.sh restart-flutter'" >&2
  fi
  mkdir -p "$STATE_DIR"
  if ! preflight_start; then
    return 1
  fi
  printf '%s\n' "$LOG_DIR" > "$STATE_DIR/log-dir"
  printf '%s\n' "$FLUTTER_TARGET" > "$STATE_DIR/flutter-target"
  if [[ "$DRY_RUN" == true ]]; then
    echo "restart.sh dry-run"
    echo "  flutter: reconnect (mode=$FLUTTER_MODE target=$FLUTTER_TARGET relay=$FLUTTER_RELAY_BASE)"
    return 0
  fi
  if [[ "$FLUTTER_MODE" == "mac" && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    ensure_local_owner_bootstrap || return 1
  fi
  stop_process flutter || return 1
  start_flutter
}

# Kill daemon processes that serve this project's state dir but are not
# recorded in the daemon pid file. Historical restarts tracked only the `go
# run` parent pid; when that parent died, the compiled daemon child was
# orphaned, kept holding daemon.db, and never matched by stop_process.
# Matching requires the exact --state-dir so unrelated projects are untouched.
stop_orphan_daemons() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local state_abs known_pid p orphans=0
  state_abs="$(absolute_path "$DAEMON_STATE_DIR")"
  known_pid="$(read_pid "$(pid_file daemon)" 2>/dev/null || true)"
  # macOS pgrep treats the -f pattern as an extended regex: a leading "--"
  # would be parsed as an illegal option, so match loosely and filter below.
  while read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" != "$known_pid" ]] || continue
    if [[ "$(process_command "$p")" == *"daemon run"*"--state-dir $state_abs"* ]]; then
      echo "daemon: stopping orphan daemon pid $p (state dir $state_abs)"
      kill_tree "$p"
      if ! wait_dead "$p"; then
        echo "daemon: orphan pid $p did not stop gracefully; sending SIGKILL" >&2
        kill -KILL "$p" 2>/dev/null || true
        if ! wait_dead "$p"; then
          echo "daemon: failed to stop orphan pid $p" >&2
          return 1
        fi
      fi
      orphans=1
    fi
  done < <(pgrep -f "daemon run .*state-dir" 2>/dev/null || true)
  if [[ "$orphans" == 1 ]]; then
    echo "daemon: orphan cleanup complete"
  fi
  return 0
}

stop_action() {
  # Stop every component owned by this state directory. Selection flags only
  # affect startup, so `stop --no-web` cannot accidentally leave a managed Web
  # process behind.
  local result=0
  if ! stop_process flutter; then result=1; fi
  if ! stop_process daemon; then result=1; fi
  # Belt-and-suspenders: clear any daemon left outside the pid file (e.g.
  # orphaned compiled child of a dead `go run` parent) before proceeding.
  if ! stop_orphan_daemons; then result=1; fi
  if ! stop_process opencode; then result=1; fi
  if ! stop_process admin; then result=1; fi
  if ! stop_process web; then result=1; fi
  if ! stop_relay; then result=1; fi
  return "$result"
}

status_process() {
  local component="$1" file pid
  file="$(pid_file "$component")"
  pid="$(read_pid "$file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && is_running "$pid" && component_matches "$component" "$pid"; then
    echo "$component: running (pid $pid; log $(status_log "$component"))"
  else
    echo "$component: stopped (log $(status_log "$component"))"
  fi
}

status_action() {
  if [[ -z "$FLUTTER_TARGET" && -f "$STATE_DIR/flutter-target" ]]; then
    FLUTTER_TARGET="$(tr -d '[:space:]' < "$STATE_DIR/flutter-target")"
  fi
  echo "restart log: $LOG_DIR/restart.log"
  echo "relay address: $RELAY_ADDR"
  status_relay
  echo "daemon selected: $WITH_DAEMON"
  status_process daemon
  echo "daemon presence: $(daemon_presence_diagnostics)"
  echo "opencode selected: $WITH_OPENCODE ($OPENCODE_URL)"
  status_process opencode
  echo "flutter selected: $WITH_FLUTTER (mode=$FLUTTER_MODE target=${FLUTTER_DEVICE:-${FLUTTER_TARGET:-macos}})"
  status_process flutter
  echo "web selected: $WITH_WEB"
  status_process web
  echo "admin selected: $WITH_ADMIN"
  status_process admin
}

# v0.9.1（V091-13）：daemon presence 脱敏诊断。只输出进程存活（由 status_process
# 单独输出）、heartbeat age bucket、presence result、重连次数与失败行计数；
# 绝不输出 token、Terminal ID、hostname、路径、命令正文或密钥。
daemon_presence_diagnostics() {
  local presence last_seen availability bucket log_file reconnects failures
  availability="unknown"
  bucket="unknown"
  load_cached_local_presence_credentials
  presence="$(local_dev_terminal_presence 2>/dev/null || true)"
  if [[ -n "$presence" ]]; then
    last_seen="${presence%% *}"
    availability="${presence#* }"
    if [[ "$last_seen" =~ ^[0-9]+$ ]] && (( last_seen > 0 )); then
      local age
      age=$(( ($(date +%s) * 1000 - last_seen) / 1000 ))
      (( age < 0 )) && age=0
      if (( age < 15 )); then
        bucket="<15s"
      elif (( age < 40 )); then
        bucket="<40s"
      elif (( age < 60 )); then
        bucket="<60s"
      else
        bucket=">=60s"
      fi
    fi
  fi
  log_file="$(component_log daemon 2>/dev/null || true)"
  reconnects=0
  failures=0
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    reconnects="$(grep -c 'relay reconnect' "$log_file" 2>/dev/null || true)"
    failures="$(grep -c 'level=ERROR' "$log_file" 2>/dev/null || true)"
  fi
  echo "presence=$availability hb_age_bucket=$bucket reconnect_attempts=${reconnects:-0} error_lines=${failures:-0}"
}

status_relay() {
  local file="$ROOT_DIR/.task/relay.pid" pid=""
  if [[ -f "$file" ]]; then pid="$(read_pid "$file" 2>/dev/null || true)"; fi
  if [[ -n "$pid" ]] && is_running "$pid"; then
    echo "relay: running (pid $pid; log $ROOT_DIR/.task/relay.log)"
  else
    echo "relay: stopped (log $ROOT_DIR/.task/relay.log)"
  fi
}

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then
    ACTION="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-relay) WITH_RELAY=false; shift ;;
      --no-web) WITH_WEB=false; shift ;;
      --with-web) WITH_WEB=true; shift ;;
      --no-admin) WITH_ADMIN=false; shift ;;
      --with-admin) WITH_ADMIN=true; shift ;;
      --no-daemon) WITH_DAEMON=false; shift ;;
      --with-daemon|--daemon) WITH_DAEMON=true; shift ;;
      --no-opencode) WITH_OPENCODE=false; shift ;;
      --with-opencode) WITH_OPENCODE=true; shift ;;
      --opencode-port)
        [[ $# -ge 2 ]] || { echo "missing value for --opencode-port" >&2; return 2; }
        OPENCODE_PORT="$2"
        shift 2
        ;;
      --opencode-url)
        [[ $# -ge 2 ]] || { echo "missing value for --opencode-url" >&2; return 2; }
        OPENCODE_URL="$2"
        shift 2
        ;;
      --no-local-dev-pairing) LOCAL_DEV_PAIRING=false; shift ;;
      --local-dev-pairing) LOCAL_DEV_PAIRING=true; shift ;;
      --no-flutter) WITH_FLUTTER=false; shift ;;
      --flutter-mode|--flutter)
        [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; return 2; }
        FLUTTER_MODE="$2"
        shift 2
        ;;
      --flutter-device)
        [[ $# -ge 2 ]] || { echo "missing value for --flutter-device" >&2; return 2; }
        FLUTTER_DEVICE="$2"
        if [[ "$FLUTTER_DEVICE" == "macos" ]]; then FLUTTER_MODE=mac; else FLUTTER_MODE=device; fi
        shift 2
        ;;
      --flutter-relay-base)
        [[ $# -ge 2 ]] || { echo "missing value for --flutter-relay-base" >&2; return 2; }
        FLUTTER_RELAY_BASE="$2"
        shift 2
        ;;
      --flutter-target-session)
        [[ $# -ge 2 ]] || { echo "missing value for --flutter-target-session" >&2; return 2; }
        FLUTTER_TARGET_SESSION_ID="$2"
        shift 2
        ;;
      --fixture-daemon) FIXTURE_DAEMON=true; WITH_DAEMON=true; shift ;;
      --terminal-signing) TERMINAL_SIGNING=true; shift ;;
      --relay-addr) [[ $# -ge 2 ]] || { echo "missing value for --relay-addr" >&2; return 2; }; RELAY_ADDR="$2"; shift 2 ;;
      --web-port) [[ $# -ge 2 ]] || { echo "missing value for --web-port" >&2; return 2; }; WEB_PORT="$2"; shift 2 ;;
      --admin-port) [[ $# -ge 2 ]] || { echo "missing value for --admin-port" >&2; return 2; }; ADMIN_PORT="$2"; shift 2 ;;
      --log-dir) [[ $# -ge 2 ]] || { echo "missing value for --log-dir" >&2; return 2; }; LOG_DIR="$2"; shift 2 ;;
      --state-dir) [[ $# -ge 2 ]] || { echo "missing value for --state-dir" >&2; return 2; }; STATE_DIR="$2"; shift 2 ;;
      --clean-ports) CLEAN_PORTS=true; CLEAN_PORTS_SET=true; shift ;;
      --no-clean-ports) CLEAN_PORTS=false; CLEAN_PORTS_SET=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option or action: $1" >&2; usage >&2; return 2 ;;
    esac
  done
  case "$ACTION" in
    start|stop|restart|restart-flutter|flutter-restart|status) ;;
    *) echo "unknown action: $ACTION" >&2; usage >&2; return 2 ;;
  esac
  if [[ "$ACTION" == "restart" && "$CLEAN_PORTS_SET" == false ]]; then
    CLEAN_PORTS=true
  fi
  validate_tcp_port "Relay port" "$(relay_port)" || return 2
  validate_tcp_port "Web port" "$WEB_PORT" || return 2
  validate_tcp_port "Admin port" "$ADMIN_PORT" || return 2
  validate_tcp_port "OpenCode port" "$OPENCODE_PORT" || return 2
  if ! [[ "$FLUTTER_TIMEOUT_MS" =~ ^[0-9]+$ ]] || (( FLUTTER_TIMEOUT_MS < 100 )); then
    echo "restart.sh: Flutter timeout must be an integer >= 100: $FLUTTER_TIMEOUT_MS" >&2
    return 2
  fi
  STATE_DIR="$(absolute_path "$STATE_DIR")"
  if [[ -z "${AGENT_SESSIONS_SQLITE_PATH:-}" ]]; then
    RELAY_DB_PATH="$STATE_DIR/relay.db"
  else
    RELAY_DB_PATH="$(absolute_path "$RELAY_DB_PATH")"
  fi
  if [[ -z "$LOG_DIR" ]]; then
    if [[ "$ACTION" != "start" && "$ACTION" != "restart" && -f "$STATE_DIR/log-dir" ]]; then
      LOG_DIR="$(absolute_path "$(tr -d '[:space:]' < "$STATE_DIR/log-dir")")"
    elif [[ -n "${AGENT_SESSIONS_RESTART_LOG_DIR:-}" ]]; then
      LOG_DIR="$(absolute_path "$LOG_ROOT")"
    else
      LOG_DIR="$STATE_DIR/logs/$(date -u '+%Y%m%dT%H%M%SZ')"
    fi
  else
    LOG_DIR="$(absolute_path "$LOG_DIR")"
  fi
  if [[ -z "${AGENT_SESSIONS_DAEMON_STATE_DIR:-}" ]]; then
    DAEMON_STATE_DIR="$STATE_DIR/daemon"
  else
    DAEMON_STATE_DIR="$(absolute_path "$DAEMON_STATE_DIR")"
  fi
}

main() {
  parse_args "$@"
  setup_restart_logging "$@"
  case "$ACTION" in
    start) start_action ;;
    stop) stop_action ;;
    restart) restart_action ;;
    restart-flutter|flutter-restart) restart_flutter_action ;;
    status) status_action ;;
  esac
}

# v0.8.9 P2：tools/restart_test.sh 以 LIB_ONLY 模式加载本脚本做函数级回归
#（V089-07/08 生命周期锁行为测试）；显式运行时不进入该分支。
if [[ "${AGENT_SESSIONS_RESTART_LIB_ONLY:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
main "$@"
