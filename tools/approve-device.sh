#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# 设备配对批准终端（macOS 终端批准工具）
#
# 手机 app「配对到已有 Relay」发起请求后，本工具：
#   1. 自动检测新设备的配对请求；
#   2. 终端展示 6 位比对码（与手机屏幕一致，供人工核对）；
#   3. 人工确认后批准，手机自动进入已认证主页。
#
# 用法：tools/approve-device.sh [--qr] [--relay URL] [--once]
#   --qr      同时用二维码显示手机端可扫的配对载荷（terminal 扫码路径）
#   --once    只检测一轮后退出（缺省持续等待直到批准完成）
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY="${AGENT_SESSIONS_RELAY:-http://127.0.0.1:8787}"
OWNER_DEVICE="dev_1790606959345_115b2e67b3c96f1e"   # 现役 owner（恢复的 Android 控制端）
OWNER_DB="$root/.task/restart/relay.db"
QR=0; ONCE=0; ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --qr) QR=1 ;;
    --once) ONCE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --relay) RELAY="$2"; shift ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac; shift
done

cd "$root"

# ── owner 批准令牌：为现役 owner 设备重签（受控运维路径，与云端 reissue 同源）──
issue_owner_token() {
  go run ./e2e-verify/helpers/reissue-terminal-token \
    -db "$OWNER_DB" -device "$OWNER_DEVICE" -role android_owner -ttl 24h 2>/dev/null | tail -1 | tr -d '\n'
}

echo "═══ Agent Sessions 设备配对批准 ═══"
echo "Relay: $RELAY"
TOKEN=$(issue_owner_token)
if [[ -z "$TOKEN" ]]; then echo "✗ owner 令牌重签失败（relay DB 不可达？）"; exit 1; fi

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
      res=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$RELAY/v1/pairing/requests/$id/approve" -w "\n%{http_code}" --max-time 10)
      local code="${res##*$'\n'}"
      if [[ "$code" == "200" ]]; then
        echo "✓ 已批准：$name 现在是第二台 owner 设备（手机将自动进入主页）"
        return 0
      fi
      echo "✗ 批准失败（HTTP $code）：${res%$'\n'*}"
      return 1
      ;;
    n|N)
      curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$RELAY/v1/pairing/requests/$id/cancel" -o /dev/null --max-time 10
      echo "已拒绝并取消该请求。"
      return 1
      ;;
    *) echo "已跳过。"; return 1 ;;
  esac
}

while true; do
  LIST=$(curl -s -H "Authorization: Bearer $TOKEN" "$RELAY/v1/pairing/requests" --max-time 8 2>/dev/null)
  if [[ -z "$LIST" ]]; then
    # 令牌可能过期，重签一次
    TOKEN=$(issue_owner_token)
    LIST=$(curl -s -H "Authorization: Bearer $TOKEN" "$RELAY/v1/pairing/requests" --max-time 8 2>/dev/null)
  fi
  PENDING=$(printf '%s' "$LIST" | python3 -c '
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
# 用法补充：
#   tools/approve-device.sh            # 交互等待手机发起（比对码核对 + y 批准）
#   tools/approve-device.sh --yes      # 自动批准第一个待批设备
#   tools/approve-device.sh --qr       # 附二维码显示（需 pip3 install qrcode）
#   AGENT_SESSIONS_RELAY=https://39.106.135.11 tools/approve-device.sh  # 云端
# 注意：主 relay 二进制需含 v0.10.0 路由（go build -o .task/relay ./apps/relay 后重启），
#       且配对开关 AGENT_SESSIONS_OWNER_PAIRING=on（supervisor 已带）。
