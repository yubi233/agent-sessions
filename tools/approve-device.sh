#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# 设备配对批准终端（macOS 终端批准工具）
#
# 手机 app「配对到已有 Relay」发起请求后，本工具：
#   1. 自动检测新设备的配对请求；
#   2. 终端展示 6 位比对码（与手机屏幕一致，供人工核对）；
#   3. 人工确认后批准，手机自动进入已认证主页。
#
# 两种模式（OWN-06 Happy 式架构：本地权威 + 云端中转）：
#   本地模式（缺省）：owner 令牌由本机 relay DB 重签（受控运维路径）；
#   云端模式 --cloud：owner 凭据读 ~/.agent-sessions/cloud-owner-bootstrap.json
#     （tools/cloud-owner-setup.sh 产出），TLS 指纹钉扎防降级，
#     401 时用 refresh_token 自动轮换自愈（30 天窗口）。
#
# 用法：tools/approve-device.sh [--cloud] [--qr] [--relay URL] [--once]
#   --cloud       批准云端 Relay（https://39.106.135.11）上的配对请求
#   --cloud-setup 先执行云端 owner 初始化（等价 tools/cloud-owner-setup.sh）
#   --qr          同时用二维码显示手机端可扫的配对载荷（terminal 扫码路径）
#   --once        只检测一轮后退出（缺省持续等待直到批准完成）
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY="${AGENT_SESSIONS_RELAY:-http://127.0.0.1:8787}"
OWNER_DEVICE="dev_1790606959345_115b2e67b3c96f1e"   # 现役 owner（恢复的 Android 控制端，仅本地模式）
OWNER_DB="$root/.task/restart/relay.db"
QR=0; ONCE=0; ASSUME_YES=0; CLOUD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --qr) QR=1 ;;
    --once) ONCE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --cloud) CLOUD=1 ;;
    --cloud-setup) exec "$root/tools/cloud-owner-setup.sh" "${@:2}" ;;
    --relay) RELAY="$2"; shift ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac; shift
done

cd "$root"

CURL_TLS=()
CREDS="$HOME/.agent-sessions/cloud-owner-bootstrap.json"

if (( CLOUD == 1 )); then
  source "$root/tools/lib/cloud_tls.sh"
  ENDPOINT="${RELAY}"
  FP="${AGENT_SESSIONS_CLOUD_TLS_FINGERPRINT:-}"
  if [[ -z "$FP" || "$ENDPOINT" == "http://127.0.0.1:8787" ]]; then
    ENV_FILE="$root/deploy/acceptance.env"
    [[ -f "$ENV_FILE" ]] || { echo "✗ 缺 $ENV_FILE（无法解析云端地址/指纹）"; exit 1; }
    [[ "$ENDPOINT" == "http://127.0.0.1:8787" ]] && ENDPOINT="https://$(grep -E '^AGENT_SESSIONS_ACC_ECS_HOST=' "$ENV_FILE" | head -1 | cut -d= -f2)"
    [[ -z "$FP" ]] && FP="$(grep -E '^AGENT_SESSIONS_ACC_TLS_FINGERPRINT=' "$ENV_FILE" | head -1 | cut -d= -f2)"
  fi
  RELAY="$ENDPOINT"
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  cloud_tls_pin "$(echo "$ENDPOINT" | sed -E 's#https?://([^/:]+).*#\1#')" "$FP" "$WORKDIR"
  CURL_TLS=(--cacert "$CLOUD_TLS_CACERT")
  [[ -f "$CREDS" ]] || { echo "✗ 尚无云端 owner 凭据；先跑：tools/approve-device.sh --cloud-setup"; exit 1; }
fi

# ── owner 批准令牌 ──
# 本地：为现役 owner 设备重签（与云端 reissue 同源）；
# 云端：读缓存的 bootstrap 凭据（401 自愈见 renew_token）。
issue_owner_token() {
  if (( CLOUD == 1 )); then
    cloud_creds_token "$CREDS" 2>/dev/null
  else
    go run ./e2e-verify/helpers/reissue-terminal-token \
      -db "$OWNER_DB" -device "$OWNER_DEVICE" -role android_owner -ttl 24h 2>/dev/null | tail -1 | tr -d '\n'
  fi
}

# ── 401 自愈：本地重签 / 云端 refresh 轮换（新 refresh_token 立刻写回凭据文件）──
renew_token() {
  if (( CLOUD == 1 )); then
    echo "access token 失效，refresh 轮换自愈…"
    cloud_refresh_creds "$CREDS" "$RELAY" "$CLOUD_TLS_CACERT" || return 1
  fi
  TOKEN=$(issue_owner_token)
  [[ -n "$TOKEN" ]]
}

echo "═══ Agent Sessions 设备配对批准 ═══"
echo "Relay: $RELAY$( (( CLOUD == 1 )) && printf ' （云端模式，TLS 指纹 %s）' "$CLOUD_TLS_FINGERPRINT" )"
TOKEN=$(issue_owner_token)
if [[ -z "$TOKEN" ]]; then
  if (( CLOUD == 1 )); then
    echo "✗ 云端 owner 凭据不可读（$CREDS 损坏？重跑 --cloud-setup）"; exit 1
  fi
  echo "✗ owner 令牌重签失败（relay DB 不可达？）"; exit 1
fi

qr_text() {
  # 零依赖终端二维码（python3 qrcode 库可选）；无库时退化为文本载荷
  python3 - "$1" << 'PY' 2>/dev/null || echo "  [二维码不可用：请手机手动输入下方配对请求 ID]"
import sys
try:
    import qrcode
except ImportError:
    print("[二维码不可用：pip3 install qrcode 后重试]")
    sys.exit(1)
qr = qrcode.QRCode(border=1)
qr.add_data(sys.argv[1])
qr.print_ascii(invert=True)
PY
}

# ── 批准后的服务端交叉断言（云端模式）：确认双 owner active 且未被撤销 ──
cross_assert_two_owners() {
  local res code
  res=$(curl -s ${CURL_TLS[@]+"${CURL_TLS[@]}"} -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" \
    "$RELAY/v1/devices" --max-time 10)
  code="${res##*$'\n'}"
  if [[ "$code" != "200" ]]; then
    echo "⚠ 交叉断言失败：GET /v1/devices -> HTTP $code"; return 1
  fi
  printf '%s' "${res%$'\n'*}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = [x for x in d.get("devices", [])
        if x.get("role") == "android_owner" and x.get("status") == "active"]
for x in rows:
    print("  active owner: %s (%s)" % (x["id"], x.get("display_name", "?")))
print("交叉断言：active android_owner x%d（期望 >=2：mac + 手机）" % len(rows))
sys.exit(0 if len(rows) >= 2 else 1)'
}

approve_one() {
  local id="$1" name="$2" code="$3"
  echo
  echo "┌─────────────────────────────────────────────"
  echo "│ 新设备配对请求"
  echo "│  设备名称：$name"
  echo "│  比对码　：$code   ← 请与手机屏幕核对一致"
  echo "│  请求 ID ：$id"
  echo "└─────────────────────────────────────────────"
  if [[ "$QR" == 1 ]]; then
    echo "── 配对载荷二维码 ──"
    qr_text "agent-sessions://pairing/$id"
  fi
  if (( ASSUME_YES == 1 )); then
    ans=y
    echo "自动批准（--yes）"
  else
    # 从交互终端读取（脚本可能经管道调用，stdin 已被上游消费）
    read -r -p "批准该设备？(y=批准 / n=拒绝 / s=跳过) " ans < /dev/tty 2>/dev/null || read -r -p "批准该设备？(y=批准 / n=拒绝 / s=跳过) " ans
  fi
  case "$ans" in
    y|Y)
      local res
      # approve 前令牌可能恰好在「轮询 200 → 人工核对比对码」的几十秒里过期
      # （access TTL 短）：401 时自愈重签/轮换一次再重试，不把失败甩给用户。
      try_approve() {
        curl -s ${CURL_TLS[@]+"${CURL_TLS[@]}"} -X POST -H "Authorization: Bearer $TOKEN" \
          "$RELAY/v1/pairing/requests/$id/approve" -w $'\n%{http_code}' --max-time 10
      }
      res=$(try_approve)
      if [[ "${res##*$'\n'}" == "401" ]] && renew_token; then
        echo "（令牌已过期，自愈后重试批准…）"
        res=$(try_approve)
      fi
      local code="${res##*$'\n'}"
      if [[ "$code" == "200" ]]; then
        echo "✓ 已批准：$name 现在是第二台 owner 设备（手机将自动进入主页）"
        if (( CLOUD == 1 )); then cross_assert_two_owners || true; fi
        return 0
      fi
      echo "✗ 批准失败（HTTP ${code}）：${res%$'\n'*}"
      return 1
      ;;
    n|N)
      curl -s ${CURL_TLS[@]+"${CURL_TLS[@]}"} -X POST -H "Authorization: Bearer $TOKEN" \
        "$RELAY/v1/pairing/requests/$id/cancel" -o /dev/null --max-time 10
      echo "已拒绝并取消该请求。"
      return 1
      ;;
    *) echo "已跳过。"; return 1 ;;
  esac
}

while true; do
  # 带状态码取列表：401 不能被当成「暂无请求」（云端 access token 短 TTL，必须显式自愈）
  LIST=$(curl -s ${CURL_TLS[@]+"${CURL_TLS[@]}"} -H "Authorization: Bearer $TOKEN" "$RELAY/v1/pairing/requests" \
    -w "\n%{http_code}" --max-time 8 2>/dev/null)
  CODE="${LIST##*$'\n'}"; BODY="${LIST%$'\n'*}"
  if [[ "$CODE" != "200" || -z "$BODY" ]]; then
    renew_token || { (( CLOUD == 1 )) && echo "✗ 令牌自愈失败（refresh 过期？重跑 --cloud-setup）"; }
    LIST=$(curl -s ${CURL_TLS[@]+"${CURL_TLS[@]}"} -H "Authorization: Bearer $TOKEN" "$RELAY/v1/pairing/requests" \
      -w "\n%{http_code}" --max-time 8 2>/dev/null)
    CODE="${LIST##*$'\n'}"; BODY="${LIST%$'\n'*}"
  fi
  PENDING=$(printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
rows = [p for p in d.get("pairings", [])
        if p.get("status") == "pending" and p.get("role") == "android_owner"]
print(json.dumps(rows))' 2>/dev/null)

  if [[ -n "$PENDING" && "$PENDING" != "[]" ]]; then
    COUNT=$(printf '%s' "$PENDING" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
    echo "检测到 $COUNT 条待批准的设备配对请求："
    # 逐条展示与批准（比对码在 pending 列表里由服务端回填）
    DONE=0
    while IFS=$'\t' read -r id name code; do
      [[ -n "$id" ]] || continue
      if approve_one "$id" "$name" "$code"; then
        DONE=$((DONE+1))
      fi
    done < <(printf '%s' "$PENDING" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    print("\t".join([p.get("id",""), p.get("display_name",""), p.get("compare_code","-")]))')
    if (( DONE > 0 )); then
      echo "═══ 完成：$DONE 台设备已加入 ═══"
      exit 0
    fi
  else
    echo "$(date '+%T') 暂无待批准的设备请求，等待手机发起…（Ctrl-C 退出）"
  fi
  (( ONCE == 1 )) && exit 0
  sleep 3
done
# ═════════════════════════════════════════════
# 验收记录（2026-09-30 00:4x，主 soak 栈实测）：
#   模拟手机创建 201 → 工具检出比对码 194660 → --yes 批准 200 →
#   领取端点 approved + device_id/token 回填 ✓ → 撤销 204 revoked ✓
# 云端验收（2026-09-30 OWN-06 云端收口，阶段 4）见 e2e-verify 报告归档。
# 用法补充：
#   tools/approve-device.sh            # 交互等待手机发起（比对码核对 + y 批准）
#   tools/approve-device.sh --yes      # 自动批准第一个待批设备
#   tools/approve-device.sh --qr       # 附二维码显示（需 pip3 install qrcode）
#   tools/approve-device.sh --cloud    # 云端模式：TLS 钉扎 + 缓存凭据 + 401 自愈
#   tools/approve-device.sh --cloud-setup  # 先初始化云端 owner（bootstrap 201）
#   AGENT_SESSIONS_RELAY=https://39.106.135.11 tools/approve-device.sh  # 显式覆盖云端地址
# 注意：主 relay 二进制需含 v0.10.0 路由（go build -o .task/relay ./apps/relay 后重启），
#       且配对开关 AGENT_SESSIONS_OWNER_PAIRING=on（supervisor 已带；云端 compose env 已 on）。
