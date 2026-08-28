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
dry_run_flutter_restart="$(FLUTTER_BIN="$fake_flutter" ./restart.sh restart-flutter --no-relay --no-daemon --state-dir "$state_dir" --log-dir "$log_dir" --dry-run)"
grep -F 'flutter: reconnect' <<< "$dry_run_flutter_restart" >/dev/null
printf 'restart.sh regression passed (ports %s/%s)\n' "$web_port" "$admin_port"
