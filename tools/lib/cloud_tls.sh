# ═══════════════════════════════════════════════════════════════
# 云端 TLS 指纹钉扎 + owner 凭据共享库
# （被 cloud-owner-setup.sh / approve-device.sh source）
#
# 自签证书 + 客户端放行口径（deploy/acceptance.env TLS 决策）：每次连接前
# 动态拉取服务端证书 DER，SHA-256 与登记指纹比对，一致才把该证书当作
# 唯一受信锚（--cacert）。绝不使用 -k / insecure 裸放行——中间人替换证书
# 会立即指纹失配而失败，这就是防降级的全部意义。
#
# 用法：
#   source tools/lib/cloud_tls.sh
#   cloud_tls_pin <host> <登记指纹> <工作目录>
# 成功后设置：CLOUD_TLS_CACERT（pem 路径）、CLOUD_TLS_FINGERPRINT（实测指纹）。
# 失败直接 exit 1（指纹不一致 = 可能被劫持，绝不继续）。
# ═══════════════════════════════════════════════════════════════

cloud_tls_pin() {
  local host="$1" expected="$2" workdir="$3"
  expected="$(printf '%s' "$expected" | tr 'A-Z' 'a-z' | tr -d ':')"
  local der="$workdir/relay.der"
  echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null \
    | openssl x509 -outform der 2>/dev/null > "$der"
  if [[ ! -s "$der" ]]; then
    echo "✗ 无法获取 $host:443 服务端证书（网络不通？）" >&2
    exit 1
  fi
  CLOUD_TLS_FINGERPRINT="$(shasum -a 256 < "$der" | awk '{print $1}')"
  if [[ "$CLOUD_TLS_FINGERPRINT" != "$expected" ]]; then
    echo "✗ TLS 指纹不一致：server=$CLOUD_TLS_FINGERPRINT expected=$expected" >&2
    echo "  拒绝继续（防降级）。如确为服务器换证，更新 deploy/acceptance.env 的" \
         "AGENT_SESSIONS_ACC_TLS_FINGERPRINT 后重试。" >&2
    exit 1
  fi
  CLOUD_TLS_CACERT="$workdir/relay.pem"
  openssl x509 -inform der -in "$der" -out "$CLOUD_TLS_CACERT"
}

# cloud_creds_token <creds.json> → stdout 输出当前 access_token
cloud_creds_token() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tokens"]["access_token"])' "$1"
}

# cloud_refresh_creds <creds.json> <endpoint> <cacert>
# 401 自愈：用 refresh_token 轮换新令牌对并立刻写回（服务端轮换后旧 refresh 即失效，
# 不写回等于把 30 天窗口烧成一次性的）。成功 return 0，失败 return 1（不 exit，
# 由调用方决定降级路径）。
cloud_refresh_creds() {
  python3 - "$1" "$2" "$3" <<'PY' || return 1
import json, sys, urllib.request, ssl, os, datetime

creds_path, endpoint, cacert = sys.argv[1], sys.argv[2], sys.argv[3]
creds = json.load(open(creds_path))
rt = creds["tokens"]["refresh_token"]
ctx = ssl.create_default_context(cafile=cacert)
req = urllib.request.Request(
    endpoint + "/v1/auth/refresh",
    data=json.dumps({"refresh_token": rt}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
        tokens = json.load(r)
except Exception as e:
    print(f"  refresh 失败：{e}", file=sys.stderr)
    sys.exit(1)
creds["tokens"] = tokens
creds["refreshed_at"] = datetime.datetime.now().isoformat(timespec="seconds")
fd = os.open(creds_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(creds, f, ensure_ascii=False, indent=2)
print("  refresh 轮换成功，凭据已写回")
PY
}
