# DSH 桥（deepseek-harness 检出）补丁与重建指引

产品以**路径钉扎**方式消费 `~/code/deepseek-harness` 检出。bin 缺省按
`$HOME` 公式回退（`internal/adapter/dsh/bridge.go` 的
`bridgeHomeFallbackBin`，可用 `AGENT_SESSIONS_DSH_BIN` 覆盖）；**组合文件没有
任何内置缺省**，必须由启动入口注入（`restart.sh` 默认注入产品根 `cordis.yml`，
可用 `AGENT_SESSIONS_DSH_CONFIG` 覆盖；新机器可从仓库根 `cordis.yml.example`
复制生成）。检出内容不在产品仓库依赖图内，历史上曾因"改动未提交 + 构建产物
被清理"导致桥整体不可用（v0.9.7 阶段 0 核查结论）。本目录把跨仓库差异固化为
补丁，并记录最小重建链。

## 当前补丁

| 补丁 | 作用 |
| --- | --- |
| `0001-examples-cordis-persistence-compression-override.patch` | examples 组合的 `persistenceCompression` 尊重显式 `DSH_SNAPSHOT_COMPRESSION`——record 模式固化 none 会让 zstd 全局会话整根拒载（实施记录 35 §1.1）。运行时组合是产品根 `cordis.yml`（已含该语义），本补丁保持 demo 配置同语义。 |

## 已随上游合并、无需补丁的项（2026-09-27 核对）

- `packages/examples/acp-demo/src/bin.ts` 的 stdin-EOF 竞态修复
  （end 监听先挂 Promise 再消费——`< /dev/null` 或父进程早亡时 record 桥
  永不退出）已存在于上游 HEAD（47f9438）。
- examples 组合的 credentials-local / settings-file / llm-pi-ai /
  agent-presets 挂载已存在于上游 HEAD。

## 检出缺失或换机后的最小重建链

```bash
cd /Users/yubi/code/deepseek-harness
git checkout 47f9438-DETACHED-OR-MAIN   # 任何包含上游 EOF 修复的版本
git apply /Users/yubi/code/agentProject/agent-sessions/tools/dsh-bridge-patches/*.patch
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890  # 视网络环境
pnpm install --frozen-lockfile
pnpm run build:lib:host     # tsc -b host 工程 + 根 tsdown（产出各插件 lib/index.js）
pnpm run build:lib:client   # client 面（bridge spawn 不依赖，保持仓库完整）
(cd packages/examples/acp-demo && npx tsdown)   # 产出 lib/bin.js（ACP 桥入口）
```

## 冒烟验收（无模型）

```bash
( printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readFile":true,"writeFile":true},"terminal":false}}}'; sleep 40 ) \
  | node packages/examples/acp-demo/lib/bin.js \
      -c /Users/yubi/code/agentProject/agent-sessions/cordis.yml \
  > /tmp/dsh-smoke.out 2>/tmp/dsh-smoke.err &
# 10 秒内 /tmp/dsh-smoke.out 出现 "id":1 即通过；模型目录应含用户白名单路由。
```

2026-09-27 实测：initialize 2 秒响应，模型目录 current=goat/deepseek-v4.1-flash，
stderr 干净（证据：实施记录 37）。

## 换机路径映射

检出根变化时（例如 `/Users/旧用户名/code/deepseek-harness` → 新根），bin 的
`$HOME` 公式会自动跟随新家目录；如检出不在 `~/code/deepseek-harness`，用
`AGENT_SESSIONS_DSH_BIN` 指向实际入口，并更新产品 `cordis.yml` 内的插件绝对路径：

```bash
new_root=/Users/<新用户>/code/deepseek-harness
sed -i '' "s|/Users/yubi/code/deepseek-harness|$new_root|g" \
  /Users/yubi/code/agentProject/agent-sessions/cordis.yml
```

随后按上文「最小重建链」重建产物，并跑 `restart.sh restart` 验证桥预检通过。
