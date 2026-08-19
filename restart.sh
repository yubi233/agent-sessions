#!/usr/bin/env bash
# Local development entrypoint: Relay -> Daemon -> Flutter, with optional
# Web/Admin inspection surfaces. It owns only processes recorded under the
# selected state directory and delegates Relay ownership to relayctl.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AGENT_SESSIONS_RESTART_STATE_DIR:-$ROOT_DIR/.task/restart}"
LOG_ROOT="${AGENT_SESSIONS_RESTART_LOG_DIR:-$STATE_DIR/logs}"
RELAY_ADDR="${AGENT_SESSIONS_RELAY_ADDR:-127.0.0.1:8787}"
RELAY_DB_PATH="${AGENT_SESSIONS_SQLITE_PATH:-$ROOT_DIR/data/relay.db}"
WEB_PORT="${AGENT_SESSIONS_WEB_PORT:-5173}"
ADMIN_PORT="${AGENT_SESSIONS_ADMIN_PORT:-5174}"
DAEMON_STATE_DIR="${AGENT_SESSIONS_DAEMON_STATE_DIR:-$STATE_DIR/daemon}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
FLUTTER_MODE="${AGENT_SESSIONS_FLUTTER_MODE:-mac}"
FLUTTER_DEVICE="${AGENT_SESSIONS_FLUTTER_DEVICE:-}"
FLUTTER_TIMEOUT_MS="${AGENT_SESSIONS_FLUTTER_TIMEOUT_MS:-30000}"
FLUTTER_RELAY_BASE="${AGENT_SESSIONS_FLUTTER_RELAY_BASE:-}"
FLUTTER_DEVICE_HELPER="${AGENT_SESSIONS_FLUTTER_DEVICE_HELPER:-$ROOT_DIR/tools/flutter_device.sh}"
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

STARTED_RELAY=false
STARTED_WEB=false
STARTED_ADMIN=false
STARTED_DAEMON=false
STARTED_FLUTTER=false

usage() {
  cat <<'EOF'
Usage: ./restart.sh [start|stop|restart|status] [options]

Default action is restart. The default local stack is Relay + Daemon + Flutter.
Web/Admin are optional inspection surfaces and require explicit flags.

Options:
  --no-relay             Do not manage the local Relay
  --no-web               Do not start apps/web (compatibility flag)
  --with-web             Start apps/web
  --no-admin             Do not start apps/admin-web (compatibility flag)
  --with-admin           Start apps/admin-web
  --no-daemon            Do not start apps/daemon
  --with-daemon          Start apps/daemon run (default; requires AGENT_SESSIONS_DAEMON_TOKEN)
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
  FLUTTER_BIN

Logs never go to testbox; testbox remains the Agent session workspace only.
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
  local component="$1" file="$2" logfile="$3" pid
  shift 3
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
  printf '[restart.sh] component=%s started=%s\n' "$component" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$logfile"
  "$@" >> "$logfile" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$file"
  sleep 0.2
  if ! is_running "$pid"; then
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
  exec go run ./apps/daemon "${args[@]}"
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
  if [[ "$WITH_DAEMON" == true && -z "${AGENT_SESSIONS_DAEMON_TOKEN:-}" ]]; then
    print_missing_daemon_token_hint
    return 1
  fi
  if ! [[ "$FLUTTER_TIMEOUT_MS" =~ ^[0-9]+$ ]] || (( FLUTTER_TIMEOUT_MS < 100 )); then
    echo "flutter: AGENT_SESSIONS_FLUTTER_TIMEOUT_MS must be an integer >= 100: $FLUTTER_TIMEOUT_MS" >&2
    return 1
  fi
  if [[ "$WITH_FLUTTER" == true ]]; then
    resolve_flutter_target || return 1
  fi
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
  start_process web "$file" "$(component_log web)" run_web "$WEB_PORT" "$RELAY_ADDR"
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
  start_process admin "$file" "$(component_log admin)" run_admin "$ADMIN_PORT" "$RELAY_ADDR"
  STARTED_ADMIN=true
  pid="$(read_pid "$file")"
  wait_for_http admin "http://127.0.0.1:$ADMIN_PORT" "$pid"
}

start_daemon() {
  local token=${AGENT_SESSIONS_DAEMON_TOKEN:-}
  if [[ -z "$token" ]]; then
    print_missing_daemon_token_hint
    return 1
  fi
  start_process daemon "$(pid_file daemon)" "$(component_log daemon)" run_daemon
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
  start_process flutter "$file" "$(component_log flutter)" run_flutter
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
    echo "  daemon: $WITH_DAEMON (fixture=$FIXTURE_DAEMON)"
    echo "  flutter: $WITH_FLUTTER (mode=$FLUTTER_MODE target=$FLUTTER_TARGET relay=$FLUTTER_RELAY_BASE)"
    echo "  web: $WITH_WEB (127.0.0.1:$WEB_PORT)"
    echo "  admin: $WITH_ADMIN (127.0.0.1:$ADMIN_PORT)"
    return 0
  fi
  if [[ "$CLEAN_PORTS" == true ]] && ! cleanup_selected_ports; then
    echo "restart.sh: port cleanup failed; refusing to start services" >&2
    return 1
  fi
  if [[ "$WITH_RELAY" == true ]] && ! start_relay; then cleanup_start_failure; return 1; fi
  if [[ "$WITH_DAEMON" == true ]] && ! start_daemon; then cleanup_start_failure; return 1; fi
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
  RELAY_DB_PATH="$(absolute_path "$RELAY_DB_PATH")"
  if [[ -z "$LOG_DIR" ]]; then
    if [[ -n "${AGENT_SESSIONS_RESTART_LOG_DIR:-}" ]]; then
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
  case "$ACTION" in
    start) start_action ;;
    stop) stop_action ;;
    restart) restart_action ;;
    status) status_action ;;
  esac
}

main "$@"
