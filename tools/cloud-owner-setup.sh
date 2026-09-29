#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OWN-06 云端收口·阶段 2：mac 获得云端权威 owner 身份
#
# 前置：deploy/ecs/reset-cloud-owner.sh 已在服务器跑过（孤儿 owner 撤销，
# bootstrap 重开放）。本脚本幂等可重跑：
#   - 已有有效凭据 → 直接校验通过退出（不重复 bootstrap）；
#   - 凭据存在但 401 → 用 refresh_token 轮换自愈（30 天窗口内）；
#   - 无凭据 → TLS 钉扎 + 生成 X25519 密钥对 + device-bootstrap 201。
#
# 用法：tools/cloud-owner-setup.sh [--endpoint URL]
#   缺省 endpoint / 指纹取自 deploy/acceptance.env。
# 产物：
#   ~/.agent-sessions/cloud-owner-enc-seed.b64     X25519 私钥种子（0600）
#   ~/.agent-sessions/cloud-owner-bootstrap.json   凭据（0600，approve-device.sh --cloud 消费）
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/tools/lib/cloud_tls.sh"

ENDPOINT="${AGENT_SESSIONS_CLOUD_RELAY:-}"
FP="${AGENT_SESSIONS_CLOUD_TLS_FINGERPRINT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac; shift
done

# ── 读取部署登记（只取地址与指纹两类非密事实）──
if [[ -z "$ENDPOINT" || -z "$FP" ]]; then
  ENV_FILE="$root/deploy/acceptance.env"
  [[ -f "$ENV_FILE" ]] || { echo "✗ 缺 $ENV_FILE（无法解析云端地址/指纹）"; exit 1; }
  [[ -z "$ENDPOINT" ]] && ENDPOINT="https://$(grep -E '^AGENT_SESSIONS_ACC_ECS_HOST=' "$ENV_FILE" | head -1 | cut -d= -f2)"
  [[ -z "$FP" ]] && FP="$(grep -E '^AGENT_SESSIONS_ACC_TLS_FINGERPRINT=' "$ENV_FILE" | head -1 | cut -d= -f2)"
fi
HOST="$(echo "$ENDPOINT" | sed -E 's#https?://([^/:]+).*#\1#')"

AGENT_DIR="$HOME/.agent-sessions"
mkdir -p "$AGENT_DIR"
chmod 700 "$AGENT_DIR"
CREDS="$AGENT_DIR/cloud-owner-bootstrap.json"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "═══ mac 云端 owner 初始化 ═══"
echo "Endpoint: $ENDPOINT"

# ── 幂等快速路径：凭据仍有效就直接通过 ──
creds_ok() {
  [[ -f "$CREDS" ]] || return 1
  local tok code
  tok="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tokens"]["access_token"])' "$CREDS" 2>/dev/null)" || return 1
  code="$(curl -s -o "$WORKDIR/devices.json" -w '%{http_code}' --max-time 15 \
    --cacert "$CLOUD_TLS_CACERT" -H "Authorization: Bearer $tok" "$ENDPOINT/v1/devices")"
  [[ "$code" == "200" ]]
}

# ── 401 自愈：refresh 轮换（共享库实现，服务端签发新 refresh_token 后立刻写回）──
try_refresh() {
  [[ -f "$CREDS" ]] || return 1
  cloud_refresh_creds "$CREDS" "$ENDPOINT" "$CLOUD_TLS_CACERT"
}

if cloud_tls_pin "$HOST" "$FP" "$WORKDIR"; then
  echo "✓ TLS 指纹一致：$CLOUD_TLS_FINGERPRINT"
fi
if creds_ok; then
  echo "✓ 已有云端 owner 凭据且有效（幂等通过）：$CREDS"
  exit 0
fi
echo "缓存凭据缺失或失效，尝试 refresh 自愈…"
if try_refresh && creds_ok; then
  echo "✓ refresh 自愈成功，凭据已更新：$CREDS"
  exit 0
fi

# ── 全新 bootstrap：真实 X25519 公钥（v0.8.8 决策：保证 daemon DEK wrap 附件链路可用）──
echo "生成/复用 X25519 加密密钥对（go run ./apps/daemon encryption-keygen）…"
ENC_PUB="$(go run ./apps/daemon encryption-keygen --out "$AGENT_DIR/cloud-owner-enc-seed.b64" 2>/dev/null | tail -1)"
if [[ -z "$ENC_PUB" ]]; then echo "✗ encryption-keygen 失败"; exit 1; fi
echo "encryption 公钥：$ENC_PUB"

echo "发起 device-bootstrap（identity 沿用 localdev 占位串先例，桥接期 Relay 不验签）…"
BODY="$(printf '{"display_name":"mac-cloud-owner","platform":"mac","identity_public_key":"mac-cloud-owner-identity-v0100","encryption_public_key":"%s"}' "$ENC_PUB")"
HTTP_OUT="$(curl -s -o "$WORKDIR/resp.json" -w '%{http_code}' --max-time 20 \
  --cacert "$CLOUD_TLS_CACERT" -H 'Content-Type: application/json' \
  -X POST "$ENDPOINT/v1/auth/device-bootstrap" -d "$BODY")"

case "$HTTP_OUT" in
  201)
    python3 - "$WORKDIR/resp.json" "$CREDS" "$ENDPOINT" "$CLOUD_TLS_FINGERPRINT" <<'PY'
import json, sys, os, datetime

resp, creds_path, endpoint, fp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(resp))
out = {
    "endpoint": endpoint,
    "fingerprint": fp,
    "device": data["device"],
    "tokens": data["tokens"],
    "saved_at": datetime.datetime.now().isoformat(timespec="seconds"),
}
fd = os.open(creds_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(f"device_id={out['device']['id']} account_id={out['tokens'].get('account_id','?')}")
PY
    ;;
  409)
    echo "✗ 409：bootstrap 仍被拒绝（$(cat "$WORKDIR/resp.json")）"
    echo "  → 云端还有 active owner？先跑阶段 1："
    echo "    scp deploy/ecs/reset-cloud-owner.sh root@<ecs>:/tmp/ && ssh root@<ecs> bash /tmp/reset-cloud-owner.sh"
    exit 1
    ;;
  *)
    echo "✗ bootstrap 失败（HTTP ${HTTP_OUT}）：$(cat "$WORKDIR/resp.json")"; exit 1 ;;
esac

if ! creds_ok; then echo "✗ bootstrap 后自校验未通过"; exit 1; fi
echo "✓ mac 已成为云端权威 owner（唯一 active android_owner）"
echo "  凭据：${CREDS}（refresh 30 天窗口，401 时 approve-device.sh --cloud 自动轮换）"
echo "  下一步：手机发起配对后运行 tools/approve-device.sh --cloud"
