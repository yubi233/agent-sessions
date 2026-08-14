#!/usr/bin/env bash
# 管理本仓库本轮 Relay：使用 .task PID 文件，绝不匹配或终止用户已有进程。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="$root/.task"
pid_file="$state_dir/relay.pid"
log_file="$state_dir/relay.log"
bin="$state_dir/relay"
address="${RELAY_ADDR:-127.0.0.1:8787}"
database_path="${RELAY_DB_PATH:-$root/data/relay.db}"

is_running() {
  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

start() {
  if is_running; then
    echo "Relay 已运行：pid $(cat "$pid_file")"
    return 0
  fi
  mkdir -p "$state_dir" "$(dirname "$database_path")"
  go build -o "$bin" ./apps/relay
  "$bin" --addr "$address" --db "$database_path" >"$log_file" 2>&1 &
  echo "$!" >"$pid_file"

  for _ in $(seq 1 100); do
    if curl --fail --silent --show-error "http://$address/readyz" >/dev/null; then
      echo "Relay 已就绪：http://$address"
      return 0
    fi
    if ! is_running; then
      cat "$log_file" >&2 || true
      rm -f "$pid_file"
      echo "Relay 启动失败" >&2
      return 1
    fi
    sleep 0.1
  done
  stop || true
  echo "Relay readiness 超时" >&2
  return 1
}

stop() {
  if ! is_running; then
    rm -f "$pid_file"
    echo "没有由本仓库启动的 Relay"
    return 0
  fi
  local pid
  pid="$(cat "$pid_file")"
  kill "$pid"
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file"
      echo "Relay 已停止"
      return 0
    fi
    sleep 0.1
  done
  echo "Relay 未在安全超时内停止：pid $pid" >&2
  return 1
}

case "${1:-}" in
  up) start ;;
  down) stop ;;
  status)
    if is_running; then echo "Relay 运行中：pid $(cat "$pid_file")"; else echo "Relay 未运行"; fi
    ;;
  *) echo "用法：$0 {up|down|status}" >&2; exit 2 ;;
esac
