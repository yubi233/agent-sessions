#!/usr/bin/env bash
# Focused regression for restart.sh. It uses temporary ports/state and local
# Flutter/device stubs; it never touches repository data or testbox.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
pick_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
state_dir="$(mktemp -d /tmp/agent-sessions-restart-state.XXXXXX)"
log_dir="$(mktemp -d /tmp/agent-sessions-restart-logs.XXXXXX)"
fake_flutter="$ROOT_DIR/tools/test_fixtures/fake_flutter.sh"
fake_device_helper="$ROOT_DIR/tools/test_fixtures/fake_flutter_device.sh"
fake_opencode="$ROOT_DIR/tools/test_fixtures/fake_opencode.sh"
web_port="$(pick_port)"; admin_port="$(pick_port)"; occupied_port="$(pick_port)"; relay_port="$(pick_port)"; opencode_port="$(pick_port)"; occupied_pid=""
cleanup() { if [[ -n "$occupied_pid" ]]; then kill "$occupied_pid" 2>/dev/null || true; fi; FLUTTER_BIN="$fake_flutter" ./restart.sh stop --no-relay --no-daemon --state-dir "$state_dir" --web-port "$web_port" --admin-port "$admin_port" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
bash -n restart.sh tools/restart_test.sh tools/flutter_device.sh "$fake_flutter" "$fake_device_helper"
python3 -m py_compile "$fake_opencode"
./restart.sh --help >/dev/null
if ./restart.sh start --no-relay --no-web --no-admin --no-daemon --no-flutter --web-port nope --dry-run >/dev/null 2>&1; then echo 'restart.sh accepted an invalid TCP port' >&2; exit 1; fi
dry_run_output="$(FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'token_source=local-dev-dry-run' <<< "$dry_run_output" >/dev/null
grep -F 'fixture=false' <<< "$dry_run_output" >/dev/null
grep -F 'opencode: true' <<< "$dry_run_output" >/dev/null
# v0.5.next P3：dsh 桥路径缺省未配置时 dry-run 摘要如实提示 per-session 拓扑。
grep -F 'dsh: bridge=<unset>' <<< "$dry_run_output" >/dev/null
# v0.6 残余项收口：签名模式默认关闭（bearer 兼容窗口），显式开关后摘要如实展示。
grep -F 'terminal-signing: off' <<< "$dry_run_output" >/dev/null
signing_dry_run="$(FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --terminal-signing --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'terminal-signing: on' <<< "$signing_dry_run" >/dev/null
# keygen 幂等语义：同一密钥文件反复生成得到同一公钥；损坏文件必须拒绝。
sign_key_dir="$(mktemp -d /tmp/agent-sessions-keygen.XXXXXX)"
pub_first="$(go run ./apps/daemon keygen --out "$sign_key_dir/k.b64")"
pub_second="$(go run ./apps/daemon keygen --out "$sign_key_dir/k.b64")"
[[ -n "$pub_first" && "$pub_first" == "$pub_second" ]] || { echo 'daemon keygen is not idempotent' >&2; exit 1; }
printf 'not-a-seed' > "$sign_key_dir/bad.b64"
if go run ./apps/daemon keygen --out "$sign_key_dir/bad.b64" >/dev/null 2>&1; then echo 'daemon keygen accepted a corrupt seed file' >&2; exit 1; fi
rm -rf "$sign_key_dir"
# 显式给出不存在路径时必须出现 fail-closed 预告（stderr）。
dsh_missing_notice="$(AGENT_SESSIONS_DSH_BIN=/nonexistent/dsh-acp-demo.js FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run 2>&1 >/dev/null || true)"
grep -F '路径不存在' <<< "$dsh_missing_notice" >/dev/null
grep -F 'bridge=/nonexistent/dsh-acp-demo.js' <<< "$dsh_missing_notice" >/dev/null
# codex 透传：dry-run 计划行必须如实呈现 ENABLE/BIN；ENABLE 有而 BIN 缺要给 fail-closed 预告。
codex_dry_run="$(AGENT_SESSIONS_CODEX_ENABLE=1 AGENT_SESSIONS_CODEX_BIN=/usr/local/bin/codex FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'codex: enable=1 bin=/usr/local/bin/codex' <<< "$codex_dry_run" >/dev/null
codex_missing_notice="$(AGENT_SESSIONS_CODEX_ENABLE=1 FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run 2>&1 >/dev/null || true)"
grep -F '适配器会注册但探测必失败' <<< "$codex_missing_notice" >/dev/null
codex_unset_line="$(FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'codex: enable=<unset> bin=<unset>' <<< "$codex_unset_line" >/dev/null
# relay 侧 OpenCode 探测契约必须在计划中可见（防止能力矩阵探测环境再次静默丢失）。
grep -F 'relay-opencode-probe: http://127.0.0.1:4096' <<< "$codex_dry_run" >/dev/null
# v0.7 默认模型透传：dry-run 明确展示动态目录或显式 provider/model 配置。
zen_dry_run="$(AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL=opencode/big-pickle FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'opencode-default-model: opencode/big-pickle' <<< "$zen_dry_run" >/dev/null

# P0 回归：默认拓扑必须实际启动 OpenCode（而不是仅在 dry-run 中显示）。
# 使用隔离端口和本地夹具，验证健康检查、URL 落盘、PID 管理与可回收性。
opencode_state_dir="$(mktemp -d /tmp/agent-sessions-opencode-state.XXXXXX)"
opencode_log_dir="$(mktemp -d /tmp/agent-sessions-opencode-logs.XXXXXX)"
OPENCODE_BIN="$fake_opencode" AGENT_SESSIONS_OPENCODE_PORT="$opencode_port" \
  ./restart.sh start --no-relay --no-daemon --no-flutter --no-web --no-admin \
  --state-dir "$opencode_state_dir" --log-dir "$opencode_log_dir"
test -f "$opencode_state_dir/opencode.pid"
test -f "$opencode_state_dir/opencode-url"
grep -F "http://127.0.0.1:$opencode_port" "$opencode_state_dir/opencode-url" >/dev/null
curl --fail --silent --show-error "http://127.0.0.1:$opencode_port/global/health" \
  | grep -F '"healthy": true' >/dev/null
opencode_pid="$(cat "$opencode_state_dir/opencode.pid")"
kill -0 "$opencode_pid"
OPENCODE_BIN="$fake_opencode" AGENT_SESSIONS_OPENCODE_PORT="$opencode_port" \
  ./restart.sh stop --no-relay --no-daemon --no-flutter --no-web --no-admin \
  --state-dir "$opencode_state_dir" --log-dir "$opencode_log_dir"
test ! -e "$opencode_state_dir/opencode.pid"
if kill -0 "$opencode_pid" 2>/dev/null; then
  echo 'restart.sh failed to reclaim the fixture OpenCode process' >&2
  exit 1
fi
dry_run_flutter_output="$(FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'owner_bootstrap=true' <<< "$dry_run_flutter_output" >/dev/null
missing_token_output="$(./restart.sh start --no-relay --no-web --no-admin --no-flutter --no-local-dev-pairing --state-dir "$state_dir" --dry-run 2>&1 >/dev/null || true)"
grep -F 'AGENT_SESSIONS_DAEMON_TOKEN=<paired-terminal-token> ./restart.sh restart' <<< "$missing_token_output" >/dev/null
grep -F './restart.sh restart --no-daemon' <<< "$missing_token_output" >/dev/null
if ./restart.sh start --no-relay --no-web --no-admin --no-flutter --no-local-dev-pairing --state-dir "$state_dir" --dry-run >/dev/null 2>&1; then echo 'restart.sh accepted a missing daemon token with local pairing disabled' >&2; exit 1; fi
test ! -e "$state_dir/relay-owned"
FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-relay --no-daemon --no-web --no-admin --state-dir "$state_dir" --log-dir "$log_dir" --flutter-mode mac
FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-relay --no-daemon --no-web --no-admin --state-dir "$state_dir" --log-dir "$log_dir" --flutter-device macos
status_output="$(FLUTTER_BIN="$fake_flutter" ./restart.sh status --no-relay --no-daemon --state-dir "$state_dir")"
printf '%s\n' "$status_output"
grep -F 'flutter selected: true (mode=mac target=macos)' <<< "$status_output"
grep -F "restart log: $log_dir/restart.log" <<< "$status_output"
grep -F "log $log_dir/flutter.log" <<< "$status_output"
grep -F 'invocation command=' "$log_dir/restart.log"
grep -F 'process starting component=flutter' "$log_dir/restart.log"
grep -F '[restart.sh] cwd=' "$log_dir/flutter.log"
grep -F -- '-d macos --no-pub' "$log_dir/flutter.log"
test -f "$state_dir/flutter.pid"
old_flutter_pid="$(cat "$state_dir/flutter.pid")"
FLUTTER_BIN="$fake_flutter" ./restart.sh restart-flutter --no-relay --no-daemon --state-dir "$state_dir" --log-dir "$log_dir"
new_flutter_pid="$(cat "$state_dir/flutter.pid")"
[[ "$old_flutter_pid" != "$new_flutter_pid" ]] || { echo 'restart-flutter reused the old Flutter process' >&2; exit 1; }
kill -0 "$new_flutter_pid"
FLUTTER_BIN="$fake_flutter" ./restart.sh flutter-restart --no-relay --no-daemon --state-dir "$state_dir" --log-dir "$log_dir"
third_flutter_pid="$(cat "$state_dir/flutter.pid")"
[[ "$new_flutter_pid" != "$third_flutter_pid" ]] || { echo 'flutter-restart alias did not replace Flutter process' >&2; exit 1; }
FLUTTER_BIN="$fake_flutter" ./restart.sh stop --no-relay --no-daemon --state-dir "$state_dir"
test ! -e "$state_dir/flutter.pid"
FAKE_FLUTTER_DEVICES_JSON='[{"id":"physical-123","name":"Test phone"}]' FLUTTER_BIN="$fake_flutter" AGENT_SESSIONS_FLUTTER_DEVICE_HELPER="$fake_device_helper" AGENT_SESSIONS_FLUTTER_RELAY_BASE='http://192.168.1.2:8787' ./restart.sh start --no-relay --no-daemon --no-web --no-admin --flutter-mode device --state-dir "$state_dir" --log-dir "$log_dir"
grep -F -- '-d physical-123 --no-pub' "$log_dir/flutter.log"
FLUTTER_BIN="$fake_flutter" ./restart.sh stop --no-relay --no-daemon --state-dir "$state_dir"
if FAKE_FLUTTER_DEVICES_JSON='[{"id":"physical-123"}]' FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-relay --no-daemon --no-web --no-admin --flutter-mode mac --state-dir "$state_dir" --log-dir "$log_dir" >/dev/null 2>&1; then echo 'restart.sh accepted an unavailable macOS Flutter target' >&2; exit 1; fi
test ! -e "$state_dir/flutter.pid"
python3 -m http.server "$occupied_port" --bind 127.0.0.1 >/dev/null 2>&1 &
occupied_pid=$!
for _ in $(seq 1 30); do if curl --silent --max-time 1 "http://127.0.0.1:$occupied_port/" >/dev/null 2>&1; then break; fi; sleep 0.1; done
kill -0 "$occupied_pid"
if FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-relay --no-daemon --with-web --web-port "$occupied_port" --state-dir "$state_dir" --log-dir "$log_dir" >/dev/null 2>&1; then echo 'restart.sh did not fail on an unrelated Web listener' >&2; exit 1; fi
test ! -e "$state_dir/flutter.pid"
./restart.sh restart --no-relay --no-daemon --no-flutter --no-admin --with-web --web-port "$occupied_port" --state-dir "$state_dir" --log-dir "$log_dir"
test "$(ps -p "$occupied_pid" -o pid= 2>/dev/null | tr -d ' ')" = ""
./restart.sh stop --no-relay --no-daemon --no-flutter --web-port "$occupied_port" --admin-port "$admin_port" --state-dir "$state_dir"
dry_run_flutter_restart="$(FLUTTER_BIN="$fake_flutter" ./restart.sh restart-flutter --no-relay --no-daemon --state-dir "$state_dir" --log-dir "$log_dir" --dry-run 2>&1)"
grep -F 'flutter: reconnect' <<< "$dry_run_flutter_restart" >/dev/null
# v0.8.9 收口回归：--no-relay 的 restart-flutter 必须显式提示 localdev bootstrap 未播种
#（否则 App 停在连接页、零请求，易被误判为 Relay 故障）。
grep -F '不刷新/播种 localdev owner bootstrap' <<< "$dry_run_flutter_restart" >/dev/null
printf 'restart.sh regression passed (ports %s/%s)\n' "$web_port" "$admin_port"

# ---------------------------------------------------------------------------
# v0.8.9 P2（V089-07/08）：Relay DB reset 生命周期锁与 restart-flutter 防护。
# 以 LIB_ONLY 模式加载 restart.sh（不执行 main），把外部依赖 stub 成顺序记录器，
# 行为级断言 reset 的严格串行顺序与禁用口径。
v089_lib_state="$(mktemp -d /tmp/agent-sessions-v089-reset.XXXXXX)"
AGENT_SESSIONS_RESTART_LIB_ONLY=1 bash -c '
  set -euo pipefail
  export AGENT_SESSIONS_SQLITE_PATH=
  source "$1/restart.sh"

  # ---- 场景 1：允许 reset（start/restart 默认口径）——生命周期锁顺序断言。
  STATE_DIR="'"$v089_lib_state"'/state"
  RELAY_DB_PATH="'"$v089_lib_state"'/relay.db"
  mkdir -p "$STATE_DIR"
  printf "seed-db" > "$RELAY_DB_PATH"

  ORDER=()
  stop_process() { ORDER+=("stop:$1"); return 0; }
  stop_orphan_daemons() { ORDER+=("orphan-cleanup"); return 0; }
  stop_relay() { ORDER+=("relay-stop"); return 0; }
  start_relay() { ORDER+=("relay-start"); printf "fresh-db" > "$RELAY_DB_PATH"; return 0; }

  RELAY_DB_RESET_ALLOWED=true
  reset_default_local_relay_db
  expected=("stop:daemon" "orphan-cleanup" "relay-stop" "relay-start")
  [[ "${ORDER[*]}" == "${expected[*]}" ]] || {
    echo "v089: reset lifecycle order mismatch: ${ORDER[*]}" >&2
    exit 1
  }
  grep -q "fresh-db" "$RELAY_DB_PATH" || { echo "v089: relay db not rebuilt" >&2; exit 1; }
  # 生命周期锁的语义顺序：受管 Daemon → 孤儿 Daemon → Relay → 重建 → 启动。
  [[ "${ORDER[0]}" == "stop:daemon" && "${ORDER[1]}" == "orphan-cleanup" && "${ORDER[2]}" == "relay-stop" && "${ORDER[3]}" == "relay-start" ]] || {
    echo "v089: daemon must stop before relay db removal" >&2
    exit 1
  }

  # ---- 场景 2：restart-flutter 口径（RELAY_DB_RESET_ALLOWED=false）——拒绝且不触碰 DB。
  RELAY_DB_RESET_ALLOWED=false
  printf "must-survive" > "$RELAY_DB_PATH"
  guard_output="$(reset_default_local_relay_db 2>&1 >/dev/null || true)"
  grep -F "不允许静默 reset" <<< "$guard_output" >/dev/null
  grep -F "./restart.sh restart" <<< "$guard_output" >/dev/null
  grep -q "must-survive" "$RELAY_DB_PATH" || { echo "v089: guarded reset touched the db" >&2; exit 1; }
  [[ "${#ORDER[@]}" == "4" ]] || { echo "v089: guarded reset must not invoke lifecycle steps" >&2; exit 1; }
' _ "$ROOT_DIR"
rm -rf "$v089_lib_state"
# 结构断言：restart-flutter 动作必须显式关闭 reset（防止回归到静默重建）。
grep -F "RELAY_DB_RESET_ALLOWED=false" restart.sh >/dev/null
grep -F "AGENT_SESSIONS_RESTART_LIB_ONLY" restart.sh >/dev/null
printf 'restart.sh v0.8.9 reset lifecycle regression passed\n'

# ---------------------------------------------------------------------------
# v0.9.1（V091-13）：首 heartbeat 就绪门与脱敏 presence 诊断回归。
# 以 LIB_ONLY 模式加载 restart.sh，stub 掉 curl/is_running/sleep 后断言：
#   1) 新 heartbeat 落库且 Relay 权威投影 online -> ready；
#   2) availability 非 online（如 unknown）-> 不得 ready（只进程存活不算）；
#   3) heartbeat 回退（不高于 baseline）-> 不得 ready，最终 readiness timeout；
#   4) Daemon 进程退出 -> exited before first heartbeat；
#   5) 诊断输出只含 presence bucket/计数，绝不含 device_id/token/hostname。
v091_lib_state="$(mktemp -d /tmp/agent-sessions-v091-presence.XXXXXX)"
AGENT_SESSIONS_RESTART_LIB_ONLY=1 bash -c '
  set -euo pipefail
  source "$1/restart.sh"

  STATE_DIR="'"$v091_lib_state"'/state"
  LOG_DIR="'"$v091_lib_state"'/logs"
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  : > "$(component_log daemon)"
  printf "level=WARN daemon relay reconnect deferred\nlevel=INFO ok\n" >> "$(component_log daemon)"

  LOCAL_OWNER_ACCESS_TOKEN="stub-owner-token"
  LOCAL_DEV_TERMINAL_DEVICE_ID="stub-device-id"
  WITH_RELAY=true
  LOCAL_DEV_PAIRING=true
  RELAY_ADDR="127.0.0.1:1"
  DAEMON_HEARTBEAT_BASELINE=1000

  sleep() { return 0; }
  # 场景 1-3：Daemon 进程视为存活；场景 4 再覆盖为退出。
  is_running() { return 0; }

  # stub curl：按场景返回受控 presence 投影（返回 1 表示 Relay 不可达）。
  CannedBody=""
  curl() {
    if [[ -n "$CannedBody" ]]; then printf '%s' "$CannedBody"; return 0; fi
    return 7
  }

  # --- 场景 1：新 heartbeat + availability=online -> ready。
  NOW_MS="$(($(date +%s) * 1000))"
  CannedBody="{\"terminals\":[{\"device_id\":\"stub-device-id\",\"availability\":\"online\",\"last_seen_unix_ms\":$NOW_MS}]}"
  DAEMON_HEARTBEAT_BASELINE=$((NOW_MS - 60000))
  out="$(wait_for_daemon 12345)"
  grep -F "first heartbeat confirmed" <<< "$out" >/dev/null || { echo "v091: fresh online heartbeat must be ready: $out" >&2; exit 1; }
  grep -F "availability=online" <<< "$out" >/dev/null || { echo "v091: ready line must carry projection: $out" >&2; exit 1; }

  # --- 场景 2：heartbeat 新但投影 unknown（观察窗）-> 不得 ready，超时。
  CannedBody="{\"terminals\":[{\"device_id\":\"stub-device-id\",\"availability\":\"unknown\",\"last_seen_unix_ms\":$NOW_MS}]}"
  out="$(wait_for_daemon 12345 2>&1 || true)"
  grep -F "readiness timeout" <<< "$out" >/dev/null || { echo "v091: unknown projection must not be ready: $out" >&2; exit 1; }

  # --- 场景 3：heartbeat 回退（等于 baseline，视为历史值）-> 不得 ready。
  CannedBody="{\"terminals\":[{\"device_id\":\"stub-device-id\",\"availability\":\"online\",\"last_seen_unix_ms\":1000}]}"
  DAEMON_HEARTBEAT_BASELINE=1000
  out="$(wait_for_daemon 12345 2>&1 || true)"
  grep -F "readiness timeout" <<< "$out" >/dev/null || { echo "v091: regressed heartbeat must not be ready: $out" >&2; exit 1; }

  # --- 场景 4：Daemon 进程退出 -> exited before first heartbeat。
  CannedBody=""
  is_running() { return 1; }
  out="$(wait_for_daemon 12345 2>&1 || true)"
  grep -F "exited before first heartbeat" <<< "$out" >/dev/null || { echo "v091: dead daemon must fail fast: $out" >&2; exit 1; }
  is_running() { return 0; }

  # --- 场景 5：status 诊断脱敏 —— 只输出 bucket/计数；无 device_id/token/hostname。
  NOW_MS="$(($(date +%s) * 1000))"
  CannedBody="{\"terminals\":[{\"device_id\":\"stub-device-id\",\"hostname\":\"secret-host\",\"availability\":\"online\",\"last_seen_unix_ms\":$NOW_MS}]}"
  diag="$(daemon_presence_diagnostics)"
  grep -F "presence=online" <<< "$diag" >/dev/null || { echo "v091: diag must carry presence: $diag" >&2; exit 1; }
  grep -F "hb_age_bucket=<15s" <<< "$diag" >/dev/null || { echo "v091: diag must carry fresh bucket: $diag" >&2; exit 1; }
  grep -F "reconnect_attempts=1" <<< "$diag" >/dev/null || { echo "v091: diag must count reconnects: $diag" >&2; exit 1; }
  grep -F "error_lines=0" <<< "$diag" >/dev/null || { echo "v091: diag must count error lines: $diag" >&2; exit 1; }
  if grep -qE "stub-device-id|stub-owner-token|secret-host" <<< "$diag"; then
    echo "v091: diagnostics leaked identifiers: $diag" >&2
    exit 1
  fi

  # --- 场景 6：Relay 不可达 -> presence=unknown（不伪造在线/离线）。
  CannedBody=""
  diag="$(daemon_presence_diagnostics)"
  grep -F "presence=unknown" <<< "$diag" >/dev/null || { echo "v091: unreachable relay must report unknown: $diag" >&2; exit 1; }

  # --- 场景 7：status 新进程从 state 缓存恢复最小诊断上下文。
  printf "%s" "{\"tokens\":{\"access_token\":\"cached-owner-token\"}}" > "$(local_token_file local-owner-bootstrap.json)"
  printf "%s" "{\"id\":\"cached-device-id\"}" > "$(local_token_file local-daemon-approval.json)"
  LOCAL_OWNER_ACCESS_TOKEN=""
  LOCAL_DEV_TERMINAL_DEVICE_ID=""
  CannedBody="{\"terminals\":[{\"device_id\":\"cached-device-id\",\"availability\":\"online\",\"last_seen_unix_ms\":$NOW_MS}]}"
  diag="$(daemon_presence_diagnostics)"
  grep -F "presence=online" <<< "$diag" >/dev/null || { echo "v091: cached status context must recover presence: $diag" >&2; exit 1; }
  if grep -qE "cached-device-id|cached-owner-token" <<< "$diag"; then
    echo "v091: cached diagnostics leaked identifiers: $diag" >&2
    exit 1
  fi
' _ "$ROOT_DIR"
rm -rf "$v091_lib_state"
printf 'restart.sh v0.9.1 presence gate regression passed\n'

# Flutter localdev bootstrap logs must redact both owner payload and the X25519
# private seed injected through dart-define.
redacted_flutter_command="$(AGENT_SESSIONS_RESTART_LIB_ONLY=1 bash -c '
  source "$1/restart.sh"
  redacted_command flutter run \
    --dart-define=LOCAL_DEV_OWNER_BOOTSTRAP_B64=fixture-owner-secret \
    --dart-define=LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64=fixture-private-secret
' _ "$ROOT_DIR")"
grep -F -- '--dart-define=LOCAL_DEV_OWNER_BOOTSTRAP_B64=<redacted>' <<< "$redacted_flutter_command" >/dev/null
grep -F -- '--dart-define=LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64=<redacted>' <<< "$redacted_flutter_command" >/dev/null
if grep -qE 'fixture-owner-secret|fixture-private-secret' <<< "$redacted_flutter_command"; then
  echo 'restart.sh leaked localdev bootstrap secrets in command logging' >&2
  exit 1
fi

# v0.9.1 localdev DSH bootstrap regression: after the first heartbeat, restart.sh
# must use the real sync-dsh contract and select the DSH projection for this project;
# the legacy managed ws_local-dev id is not an acceptable Flutter workspace id.
v091_sync_state="$(mktemp -d /tmp/agent-sessions-v091-dsh-sync.XXXXXX)"
AGENT_SESSIONS_RESTART_LIB_ONLY=1 bash -c '
  set -euo pipefail
  source "$1/restart.sh"

  STATE_DIR="'"$v091_sync_state"'/state"
  LOG_DIR="'"$v091_sync_state"'/logs"
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  WITH_RELAY=true
  WITH_DAEMON=true
  LOCAL_DEV_PAIRING=true
  RELAY_ADDR="127.0.0.1:1"
  LOCAL_OWNER_ACCESS_TOKEN="owner-token-redacted"
  ROOT_DIR="/Users/example/agent-sessions"
  sync_calls="$STATE_DIR/sync-calls"
  sync_state_calls="$STATE_DIR/sync-state-calls"
  : > "$sync_calls"
  : > "$sync_state_calls"
  http_request() {
    case "$1" in
      workspace.sync_dsh)
        printf x >> "$sync_calls"
        printf "%s" "{\"status\":\"pending\",\"command_id\":\"cmd-sync\"}"
        ;;
      workspace.sync_dsh.status)
        printf x >> "$sync_state_calls"
        printf "%s" "{\"status\":\"succeeded\",\"workspace_ids\":[\"ws-dsh\"]}"
        ;;
      workspace.list)
        printf "%s" "{\"workspaces\":[{\"id\":\"ws-managed\",\"origin\":\"managed\",\"display_name\":\"agent-sessions\"},{\"id\":\"ws-dsh\",\"origin\":\"dsh\",\"display_name\":\"agent-sessions\"}]}"
        ;;
      *) return 1 ;;
    esac
  }
  sleep() { return 0; }
  sync_local_dev_dsh_workspace
  [[ "$LOCAL_DEV_DSH_WORKSPACE_ID" == "ws-dsh" ]]
  [[ "$(wc -c < "$sync_calls" | tr -d "[:space:]")" == 1 ]]
  [[ "$(wc -c < "$sync_state_calls" | tr -d "[:space:]")" == 1 ]]
' _ "$ROOT_DIR"
rm -rf "$v091_sync_state"
printf 'restart.sh v0.9.1 automatic DSH workspace sync regression passed\n'

# v0.9.7 阶段 5：cordis.yml 换机即断收口——prepare_runtime_cordis 必须把任意
# 历史用户家目录下的检出路径重写为当前 $HOME 约定根，其余内容逐字保留。
# （Cordis loader 的 name 字段只接受真实路径字符串，!!js/tilde/env 插值均在
# include 应用阶段失败——2026-09-28 冒烟实证；路径参数化只能由入口侧生成。）
v097_cordis_state="$(mktemp -d)"
bash -c '
  set -e
  root="$1"; state="$2"; fake_home="/Users/v097-newuser"
  mkdir -p "$state"
  sed "s|/Users/yubi/|/Users/v097-olduser/|g" "$root/cordis.yml" > "$state/cordis.source.yml"
  source /dev/stdin <<INNER
ROOT_DIR=$root
STATE_DIR=$state
HOME=$fake_home
$(sed -n "/^prepare_runtime_cordis()/,/^}/p" "$root/restart.sh")
INNER
  # 源组合固定为重写后的产物（prepare_runtime_cordis 读 ROOT_DIR/cordis.yml）
  cp "$state/cordis.source.yml" "$root/cordis.yml.test-src"
' _ "$ROOT_DIR" "$v097_cordis_state"
# 直接以旧用户组合验证重写（把 prepare 的输入指向临时源）
v097_old=$(rg -c "v097-olduser" "$v097_cordis_state/cordis.source.yml")
[[ "$v097_old" -gt 0 ]]
bash -c '
  set -e
  root="$1"; state="$2"
  mkdir -p "$root"
  cp "$state/cordis.source.yml" "$state/root-cordis.yml"
  source /dev/stdin <<INNER
ROOT_DIR=$state
STATE_DIR=$state
HOME=/Users/v097-newuser
$(sed -n "/^prepare_runtime_cordis()/,/^}/p" "$root/restart.sh")
INNER
  # prepare 读 ROOT_DIR/cordis.yml：临时 root 放旧用户组合
  mkdir -p "$state/fakeroot" && cp "$state/cordis.source.yml" "$state/fakeroot/cordis.yml"
  ROOT_DIR="$state/fakeroot"
  prepare_runtime_cordis
  [[ "$(grep -c "v097-olduser" "$RUNTIME_DSH_CONFIG" || true)" == 0 ]]
  [[ "$(grep -c "/Users/v097-newuser/code/deepseek-harness" "$RUNTIME_DSH_CONFIG")" -gt 0 ]]
  # 渠道/凭据内容逐字保留
  [[ "$(grep -c "opencode.ai/zen" "$RUNTIME_DSH_CONFIG")" -ge 1 ]]
' _ "$ROOT_DIR" "$v097_cordis_state"
rm -rf "$v097_cordis_state"
printf 'restart.sh v0.9.7 cordis runtime rewrite regression passed\n'
