#!/usr/bin/env bash
# P0-DEPLOY-01 云端部署 smoke（CLOUD-ANDROID-ACCEPTANCE 阶段 2/3）。
# 用法：在测试 PC 上执行
#   deploy/ecs/smoke.sh <https-endpoint> <cert-sha256-fingerprint> [--restart-check]
# 检查项（计划 §4.2）：
#   1. TLS 证书指纹与登记一致（不做 -k 裸放行，防止误报通过）
#   2. healthz / readyz 经 HTTPS 返回 200
#   3. 8787 未对公网开放（从测试 PC 直连应失败）
#   4. [--restart-check] 在服务器上重启 relay 容器后 healthz 仍 200 且 SQLite 数据卷文件仍在
# 输出：逐项 PASS/FAIL + 末尾 JSON 单行摘要（供 e2e-verify 报告引用）。
set -u

ENDPOINT="${1:?用法: smoke.sh <https-endpoint> <cert-sha256-fingerprint> [--restart-check]}"
FINGERPRINT="${2:?缺少证书 SHA-256 指纹}"
RESTART_CHECK="${3:-}"
HOST="$(echo "$ENDPOINT" | sed -E 's#https?://([^/:]+).*#\1#')"

fail=0

echo "== 1. TLS 证书指纹校验（$HOST）=="
SERVER_FP="$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null \
  | openssl x509 -outform der 2>/dev/null | shasum -a 256 | awk '{print $1}')"
if [ "$SERVER_FP" = "$(echo "$FINGERPRINT" | tr 'A-Z' 'a-z' | tr -d ':')" ]; then
  echo "PASS: 服务端证书指纹一致 $SERVER_FP"
else
  echo "FAIL: 指纹不一致 server=$SERVER_FP expected=$FINGERPRINT"; fail=1
fi

echo "== 2. healthz / readyz =="
for path in healthz readyz; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$HOST/$path")"
  if [ "$code" = "200" ]; then echo "PASS: /$path -> 200"; else echo "FAIL: /$path -> $code"; fail=1; fi
done

echo "== 3. 8787 不对公网开放 =="
if nc -z -G 5 "$HOST" 8787 2>/dev/null; then
  echo "FAIL: 8787 从公网可达，违反计划 §2 安全边界"; fail=1
else
  echo "PASS: 8787 从公网不可达"
fi

echo "== 4. 容器重启持久化（可选，--restart-check）=="
if [ "$RESTART_CHECK" = "--restart-check" ]; then
  # 在服务器本地重启 relay 容器，随后检查回环 healthz 与数据卷内 SQLite 文件仍在。
  result="$(ssh -o BatchMode=yes root@"$HOST" '
    docker restart agent-sessions-relay >/dev/null 2>&1 && sleep 5
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8787/healthz)
    if docker exec agent-sessions-relay ls /data/relay.db >/dev/null 2>&1; then db=1; else db=0; fi
    echo "restart healthz=$code db_file_present=$db"
  ' 2>/dev/null)"
  echo "$result"
  if echo "$result" | grep -q "restart healthz=200 db_file_present=1"; then
    echo "PASS: 重启后健康且 SQLite 数据卷保留"
  else
    echo "FAIL: 重启后健康检查或数据卷校验未通过"; fail=1
  fi
fi

echo "== 摘要 =="
echo "{\"suite\":\"P0-DEPLOY-01\",\"endpoint\":\"$ENDPOINT\",\"cert_fingerprint\":\"$SERVER_FP\",\"fail\":$fail}"
exit $fail
