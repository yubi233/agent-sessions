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
web_port="$(pick_port)"; admin_port="$(pick_port)"; occupied_port="$(pick_port)"; relay_port="$(pick_port)"; occupied_pid=""
cleanup() { if [[ -n "$occupied_pid" ]]; then kill "$occupied_pid" 2>/dev/null || true; fi; FLUTTER_BIN="$fake_flutter" ./restart.sh stop --no-relay --no-daemon --state-dir "$state_dir" --web-port "$web_port" --admin-port "$admin_port" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
bash -n restart.sh tools/restart_test.sh tools/flutter_device.sh "$fake_flutter" "$fake_device_helper"
./restart.sh --help >/dev/null
if ./restart.sh start --no-relay --no-web --no-admin --no-daemon --no-flutter --web-port nope --dry-run >/dev/null 2>&1; then echo 'restart.sh accepted an invalid TCP port' >&2; exit 1; fi
dry_run_output="$(FLUTTER_BIN="$fake_flutter" ./restart.sh start --no-web --no-admin --no-flutter --relay-addr "127.0.0.1:$relay_port" --state-dir "$state_dir" --dry-run)"
grep -F 'token_source=local-dev-dry-run' <<< "$dry_run_output" >/dev/null
grep -F 'fixture=true' <<< "$dry_run_output" >/dev/null
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
printf 'restart.sh regression passed (ports %s/%s)\n' "$web_port" "$admin_port"
