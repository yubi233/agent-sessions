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
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
FLUTTER_MODE="${AGENT_SESSIONS_FLUTTER_MODE:-mac}"
FLUTTER_DEVICE="${AGENT_SESSIONS_FLUTTER_DEVICE:-}"
FLUTTER_TIMEOUT_MS="${AGENT_SESSIONS_FLUTTER_TIMEOUT_MS:-30000}"
FLUTTER_RELAY_BASE="${AGENT_SESSIONS_FLUTTER_RELAY_BASE:-}"
FLUTTER_DEVICE_HELPER="${AGENT_SESSIONS_FLUTTER_DEVICE_HELPER:-$ROOT_DIR/tools/flutter_device.sh}"
LOCAL_DEV_PAIRING="${AGENT_SESSIONS_LOCAL_DEV_PAIRING:-true}"
LOCAL_DEV_PROJECT_ID="${AGENT_SESSIONS_LOCAL_DEV_PROJECT_ID:-local-dev}"
LOCAL_DEV_WORKSPACE_ID="ws_${LOCAL_DEV_PROJECT_ID}"
FLUTTER_TARGET=""
if [[ -n "$FLUTTER_DEVICE" && "$FLUTTER_DEVICE" != "macos" && "$FLUTTER_MODE" == "mac" ]]; then
  FLUTTER_MODE=device
fi

ACTION="restart"
WITH_RELAY=true
WITH_WEB=false
WITH_ADMIN=false
WITH_DAEMON=true
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

STARTED_RELAY=false
STARTED_WEB=false
STARTED_ADMIN=false
STARTED_DAEMON=false
STARTED_FLUTTER=false

usage() {
  cat <<'EOF'
Usage: ./restart.sh [start|stop|restart|status] [options]

Default action is restart. The default local stack is Relay + local dev-paired
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
  --fixture-daemon       Add --fixture-adapter to the Daemon command
  --relay-addr ADDR      Relay listen address (default: 127.0.0.1:8787)
  --web-port PORT        Web Vite port (default: 5173)
  --admin-port PORT      Admin Vite port (default: 5174)
  --log-dir DIR          Log directory (default: .task/restart/logs/<timestamp>)
  --state-dir DIR        Process state directory (default: .task/restart)
  --clean-ports          Stop listeners on selected service ports before start
  --no-clean-ports       Do not clean ports (default for start; restart cleans)
  --dry-run              Print the selected topology without starting anything
  -h, --help             Show this help

Environment:
  AGENT_SESSIONS_RELAY_ADDR, AGENT_SESSIONS_SQLITE_PATH,
  AGENT_SESSIONS_WEB_PORT, AGENT_SESSIONS_ADMIN_PORT,
  AGENT_SESSIONS_DAEMON_TOKEN, AGENT_SESSIONS_DAEMON_STATE_DIR,
  AGENT_SESSIONS_RESTART_STATE_DIR, AGENT_SESSIONS_RESTART_LOG_DIR,
  AGENT_SESSIONS_FLUTTER_MODE, AGENT_SESSIONS_FLUTTER_DEVICE,
  AGENT_SESSIONS_FLUTTER_TIMEOUT_MS, AGENT_SESSIONS_FLUTTER_RELAY_BASE,
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
    value = re.sub(r"(--dart-define=LOCAL_DEV_OWNER_BOOTSTRAP_B64=).*", r"\1<redacted>", value)
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
}


reset_default_local_relay_db() {
  if [[ -n "${AGENT_SESSIONS_SQLITE_PATH:-}" ]]; then
    return 1
  fi
  echo "owner: resetting default local dev Relay DB"
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
    echo "owner: cached local dev owner expired; rebuilding" >&2
    rm -f "$owner_file" "$(local_token_file local-owner-token)" "$(local_token_file local-daemon-token)" "$(local_token_file local-daemon-approval.json)"
    reset_default_local_relay_db || true
  fi

  if ! response="$(http_request owner.bootstrap \
    -H 'Content-Type: application/json' \
    -d '{"display_name":"Local Dev Android Owner","platform":"local","identity_public_key":"local-dev-owner-identity-public-key","encryption_public_key":"local-dev-owner-encryption-public-key"}' \
    "http://$RELAY_ADDR/v1/auth/device-bootstrap")"; then
    if reset_default_local_relay_db; then
      response="$(http_request owner.bootstrap_after_reset \
        -H 'Content-Type: application/json' \
        -d '{"display_name":"Local Dev Android Owner","platform":"local","identity_public_key":"local-dev-owner-identity-public-key","encryption_public_key":"local-dev-owner-encryption-public-key"}' \
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
  echo "owner: bootstrapped local dev owner via Relay"
}

ensure_daemon_token() {
  if [[ "$WITH_DAEMON" != true ]]; then return 0; fi
  if [[ -n "$DAEMON_ACCESS_TOKEN" ]]; then
    DAEMON_TOKEN_SOURCE=env
    return 0
  fi
  if [[ "$WITH_RELAY" != true ]] || ! truthy "$LOCAL_DEV_PAIRING"; then
    print_missing_daemon_token_hint
    return 1
  fi
  if [[ "$DRY_RUN" == true ]]; then
    DAEMON_ACCESS_TOKEN=local-dev-dry-run-token
    DAEMON_TOKEN_SOURCE=local-dev-dry-run
    FIXTURE_DAEMON=true
    return 0
  fi
  ensure_local_owner_bootstrap || return 1

  local daemon_approval_file daemon_refresh
  daemon_approval_file="$(local_token_file local-daemon-approval.json)"
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
      FIXTURE_DAEMON=true
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
    -d '{"role":"terminal","display_name":"Local Dev Terminal","platform":"local","identity_public_key":"local-dev-terminal-identity-public-key","encryption_public_key":"local-dev-terminal-encryption-public-key"}' \
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
  FIXTURE_DAEMON=true
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

start_daemon() {
  if [[ -z "$DAEMON_ACCESS_TOKEN" ]]; then
    echo "daemon: missing access token after pairing" >&2
    return 1
  fi
  local args=(env AGENT_SESSIONS_DAEMON_TOKEN="$DAEMON_ACCESS_TOKEN" go run ./apps/daemon run --relay-base "http://$RELAY_ADDR" --state-dir "$DAEMON_STATE_DIR")
  if [[ "$FIXTURE_DAEMON" == true ]]; then
    args+=(--fixture-adapter)
  fi
  start_process daemon "$(pid_file daemon)" "$(component_log daemon)" "$ROOT_DIR" "${args[@]}"
  STARTED_DAEMON=true
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
  if [[ "$FLUTTER_MODE" == "mac" && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    args+=("--dart-define=LOCAL_DEV_WORKSPACE_ID=$LOCAL_DEV_WORKSPACE_ID")
  fi
  start_process flutter "$file" "$(component_log flutter)" "$ROOT_DIR/apps/mobile" "${args[@]}"
  STARTED_FLUTTER=true
  pid="$(read_pid "$file")"
  wait_for_flutter "$pid"
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
  if ! RELAY_ADDR="$RELAY_ADDR" RELAY_DB_PATH="$RELAY_DB_PATH" "$ROOT_DIR/tools/relayctl.sh" up; then
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
    echo "  flutter: $WITH_FLUTTER (mode=$FLUTTER_MODE target=$FLUTTER_TARGET relay=$FLUTTER_RELAY_BASE owner_bootstrap=${LOCAL_OWNER_BOOTSTRAP_B64:+true} workspace=$LOCAL_DEV_WORKSPACE_ID)"
    echo "  web: $WITH_WEB (127.0.0.1:$WEB_PORT)"
    echo "  admin: $WITH_ADMIN (127.0.0.1:$ADMIN_PORT)"
    return 0
  fi
  if [[ "$CLEAN_PORTS" == true ]] && ! cleanup_selected_ports; then
    echo "restart.sh: port cleanup failed; refusing to start services" >&2
    return 1
  fi
  if [[ "$WITH_RELAY" == true ]] && ! start_relay; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_DAEMON" == true ]] && ! ensure_daemon_token; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_FLUTTER" == true && "$FLUTTER_MODE" == "mac" && "$WITH_RELAY" == true ]] && truthy "$LOCAL_DEV_PAIRING"; then
    if ! ensure_local_owner_bootstrap; then cleanup_start_failure; return 1; fi
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

stop_action() {
  # Stop every component owned by this state directory. Selection flags only
  # affect startup, so `stop --no-web` cannot accidentally leave a managed Web
  # process behind.
  local result=0
  if ! stop_process flutter; then result=1; fi
  if ! stop_process daemon; then result=1; fi
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
  echo "flutter selected: $WITH_FLUTTER (mode=$FLUTTER_MODE target=${FLUTTER_DEVICE:-${FLUTTER_TARGET:-macos}})"
  status_process flutter
  echo "web selected: $WITH_WEB"
  status_process web
  echo "admin selected: $WITH_ADMIN"
  status_process admin
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
      --fixture-daemon) FIXTURE_DAEMON=true; WITH_DAEMON=true; shift ;;
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
    start|stop|restart|status) ;;
    *) echo "unknown action: $ACTION" >&2; usage >&2; return 2 ;;
  esac
  if [[ "$ACTION" == "restart" && "$CLEAN_PORTS_SET" == false ]]; then
    CLEAN_PORTS=true
  fi
  validate_tcp_port "Relay port" "$(relay_port)" || return 2
  validate_tcp_port "Web port" "$WEB_PORT" || return 2
  validate_tcp_port "Admin port" "$ADMIN_PORT" || return 2
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
    status) status_action ;;
  esac
}

main "$@"
