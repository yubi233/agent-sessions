#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# ECS 中继标准化部署（mac 侧执行）：交叉编译产物 → 服务器组装镜像 → 切 compose → 探针
#
# 背景（OWN-06 阶段 4 教训）：v0100b/v0100c 两次都是临时拼命令部署，
# 且 v0100b tag 与内容不符（缺 claim 读侧回填）拖出两起事故。本脚本把
# 部署收敛为单一入口，tag 强制携带 commit 短哈希，readyz 之外追加
# 版本指纹校验（镜像内二进制与本地产物 sha256 一致才算部署成功）。
#
# 用法：
#   deploy/ecs/deploy-staged-relay.sh <commit-短哈希>
# 前置：本仓库工作树即待部署源（先 commit）；SSH 窗口开放。
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT="${1:?用法: deploy-staged-relay.sh <commit-短哈希>}"
HOST="$(grep -E '^AGENT_SESSIONS_ACC_ECS_HOST=' "$root/deploy/acceptance.env" | head -1 | cut -d= -f2)"
TAG="v$(date +%m%d%H%M)-${COMMIT}"
BIN="/tmp/relay-linux-amd64-${TAG}"

echo "═══ [1/5] 交叉编译（CGO_ENABLED=0 linux/amd64）═══"
cd "$root"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$BIN" ./apps/relay
LOCAL_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "binary=$BIN sha256=${LOCAL_SHA:0:16}…"

echo "═══ [2/5] 上传 + 组装镜像 ${TAG} ═══"
ssh -o BatchMode=yes "root@${HOST}" 'mkdir -p /opt/agent-sessions/stage'
scp -o BatchMode=yes -q "$BIN" "root@${HOST}:/opt/agent-sessions/stage/relay-linux-amd64-${TAG}"
ssh -o BatchMode=yes "root@${HOST}" "set -e
cd /opt/agent-sessions/stage
printf 'FROM scratch\nCOPY relay-linux-amd64-${TAG} /relay\nEXPOSE 8787\nENTRYPOINT [\"/relay\"]\n' > Dockerfile.${TAG}
docker build -q -f Dockerfile.${TAG} -t agent-sessions/relay:${TAG} . >/dev/null
echo image_built"

echo "═══ [3/5] 切 compose + 重建容器 ═══"
ssh -o BatchMode=yes "root@${HOST}" "set -e
sed -i 's#image: agent-sessions/relay:.*#image: agent-sessions/relay:${TAG}#' /opt/agent-sessions/deploy/docker-compose.yml
cd /opt/agent-sessions/deploy && docker compose up -d relay
for i in \$(seq 1 30); do
  code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8787/readyz || true)
  [ \"\$code\" = '200' ] && break
  sleep 1
done
[ \"\$code\" = '200' ] || { echo '✗ readyz 未通过'; exit 1; }
echo readyz=200"

echo "═══ [4/5] 版本指纹校验（防 tag 与内容不符）═══"
REMOTE_SHA="$(ssh -o BatchMode=yes "root@${HOST}" "cid=\$(docker create agent-sessions/relay:${TAG}); docker cp \${cid}:/relay /tmp/.deploy-check.bin >/dev/null; docker rm \${cid} >/dev/null; shasum -a 256 /tmp/.deploy-check.bin | awk '{print \$1}'; rm -f /tmp/.deploy-check.bin")"
if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
  echo "✗ 指纹不一致 local=${LOCAL_SHA:0:16}… remote=${REMOTE_SHA:0:16}…（镜像内容与产物不符，禁止收尾）"
  exit 1
fi
echo "✓ sha256 一致：${LOCAL_SHA:0:16}…"

echo "═══ [5/5] 完成 ═══"
echo "DEPLOY_OK tag=${TAG} image=agent-sessions/relay:${TAG}"
echo "回滚：ssh root@${HOST} \"cd /opt/agent-sessions/deploy && sed -i 's#image: agent-sessions/relay:.*#image: agent-sessions/relay:<旧tag>#' docker-compose.yml && docker compose up -d relay\""
