# 实施记录 36：DSH 历史默认隔离与同源去重

> 状态：`implemented_verified`（2026-09-27 本地全量回归 + 存量修正 + Android 实机验证通过；未提交 Git，是否入库由用户决定）。用户于 2026-09-26 重申“不展示 DSH 历史会话”，随后明确要求按修正方案实施。本记录与旧 v0.9.4/v0.9.5 的“72h 活跃”“显示全部触发导入”行为有冲突时，以本记录的展示边界为准。

## 1. 目标与不变边界

- 日常列表只展示 Agent Sessions 新建、或用户明确选中接续的会话。外部 DSH 历史不因最近活跃、搜索或打开工作区自动加入。
- 会话来源与可见性分别记录：`origin=managed|dsh_import`、`visibility=default|history|duplicate`。来源不是标题、状态、年龄的推断。
- 已管理会话仍可同步、恢复、续聊；只停止未经明确选择的新历史发现，不能把旧会话同步一并关闭。
- 原 DSH 文件、Relay 会话及事件不删除；不按 `last_seq=0` 推断空会话。副本只有在同源且没有独立接续证据时才退出默认列表。
- 不调用真实模型，不重新配对手机，不清空数据库，不修改外部 deepseek-harness 检出。未经用户要求不提交或推送 Git。

## 2. 修正前证据

2026-09-26 对当前本地 Relay/daemon 只读对账：

- `3d_survivors_like_0922` 工作区 24 条未归档 DSH 会话记录，全部处于 72h 窗口内。
- 13 条导入映射与 11 条原生会话；按本机 `workspace_root + instance_id` 对账，24 条对应 13 个底层 DSH 源。
- 11 对同源双投影，每对一条原生、一条导入副本。21 条缺展示标题。
- 原客户端把无标题或不安全标题都命名为“DSH 历史会话”，并未判断历史来源；首页卡片还漏用了工作区详情的活跃筛选。
- 进入详情自动调用批量导入；“显示全部”扩大为 `include_all`。仅导入映射参与幂等，新建原生映射未注册同一反向索引。

## 3. 实施分段

### A. 契约与来源边界

- [x] 增加来源/可见性字段与旧库幂等迁移（`ensureSessionClassificationColumns`：仅成功导入回执确证 `dsh_import`；回执命中且有 start/resume/send 使用证据的保持 default，其余转 history；缺表漂移库安全跳过）。
- [x] 默认会话 API 隔离历史、副本（`ListSessions` 只返回 default；`?history=true` 只返回历史候选）；`POST /v1/sessions/:id/manage` 显式接续（写角色、账户校验；只提升 history，幂等，副本拒绝，不触发模型）。
- [x] 同步默认 `discover=false`：服务端按工作区生成受管 `session_ids` 允许列表下发命令，空集合直接 succeeded 不唤醒 Daemon；独立幂等域 sync/discover/discover_all；`include_all` 仅 discover=true 有效。
- [x] OpenAPI 记录默认列表、历史候选、单条接续与发现参数，并生成 Go/TypeScript/Dart 边界。

### B. 去重与同步安全

- [x] 新建与导入共用原子同源绑定 `BindDSHThread`（写锁先行，检查后写竞态消除；native/imported 来源标记 `dshsource:` 独立于 instance 映射，legacy 按 start 证据 + persistence_root 保守判定；冲突返回 `ErrDSHSourceConflict` 绝不覆盖）。
- [x] 同步只处理允许列表；未知 artifact 不发现不导入；原生源零正文零水位（标题仅取显式 session/title 记录）。
- [x] 回执不再重置会话状态（running 保持）、不回退活动时间（MAX 前推）；`UpdateSessionImportProgress` 把 last_seq 修正为真实事件最大序号。
- [x] 稳定导入事件 ID（`evt_dsh_import_<sha256(Relay 会话 id|源消息 seq|事件类型)>`，不含本机路径）+ `daemon_event_receipts` 跨命令幂等；同一 event_id 绑定其他会话/终端或 live/import 混用一律拒绝。

### C. 客户端

- [x] 首页卡片、工作区详情、搜索、计数统一 `isVisible` 边界；provider=dsh 过滤不再遗漏（首页卡片原缺陷修复）。
- [x] 「显示全部」只解除 72h 时间筛选，不再隐式触发 include_all 导入；自动刷新固定 `discover:false` 且空受管工作区不发起。
- [x] 历史接续改为显式次级入口「选择历史会话接续」：确认 → 发现候选 → 单选 → manage → 进入会话；取消不改变日常列表，不做批量接续。
- [x] 无标题 DSH 会话显示「未命名 DSH 会话」（移动端与 Web 一致）；Web 只读视图补 `sessionVisible` 兜底过滤。

### D. 存量修正与验证

- [x] 新增 `tools/repair_dsh_projections.py`：默认只读；仅确证同源、唯一原生主记录且副本没有独立用户动作时允许修正；输出脱敏源指纹而非本机路径。
- [x] 修正工具测试：只读预检、备份、保留所有事件、幂等、回滚、跨作用域/独立接续/运行中/未迁移拒绝。
- [x] 生产只读预检：识别 11 对可修正记录，无冲突。
- [x] Go 全量（`go test ./...`）、Flutter 全量（623 项）、Web 单元（31 项）、`task check`（gofmt/docs_verify/生成物漂移/typecheck）全部通过；修正工具自身 8 项 unittest 通过。
- [x] 停服核对 0 在途命令、0 running 会话 → 仅启动 Relay 触发迁移（13 条导入投影 → dsh_import/history，11 条原生 → managed/default）→ 停服执行修正（备份 `.task/dsh-repair-20260927/`：两库快照 + 0600 修正日志）→ 幂等复查 0 组。
- [x] 重启同一数据库与同一配对的完整栈（Relay + 真实 Daemon）；手机 USB reverse 保持。API 实测：`GET /v1/sessions` 11 条（全 managed/default），`GET /v1/sessions?history=true` 2 条（named 独立导入会话，可在显式入口接续找回）。
- [x] Android 实机验证（d723617，release 覆盖安装，应用数据与配对保留，2026-09-27 00:47–00:55）：见 §6。

## 6. Android 实机验证（d723617 vermeer，截图在 `.task/diagnostics/v096-*.png`）

前置：重启后的本机栈（Relay + 真实 Daemon，同一数据库同一配对）；手机 USB reverse 保持；release APK 覆盖安装（不清数据，令牌与工作区投影保留）。

| 步骤 | 操作 | 结果 |
| --- | --- | --- |
| 1 首页 | 冷启动进入 DSH 首页 | `3d_survivors_like_0922` 显示 **11 个 DSH 会话**（修复前 24 条重复投影）；其余工作区保持空态（v096-01） |
| 2 详情 | 进入工作区详情 | 会话列表只含受管会话；无标题行显示**「未命名 DSH 会话」**；进入自动刷新为 discover:false 同步（v096-02/03） |
| 3 重进 | 返回后再次进入 | 计数与列表不增长；DB 复核 default=11、history=2、duplicate=11，事件总数不变；新增命令仅为复用型同步，无新投影 |
| 4 打开会话 | 点开列表首个会话 | 「可发送 / 执行服务可用 / 可控制」，模型路由 DeepSeek V4.1 Flash 正常（v096-04） |
| 5 历史入口 | 详情 ⋮ → 「选择历史会话接续」 | 确认弹窗如实说明「未选中的历史不会进入日常列表」（v096-06/07）；候选列表准确列出 2 条有真实标题的独立导入会话（v096-08）；取消后 default/history/duplicate 计数均不变 |
| 6 新建（顺带验证） | 验证过程中误触「新建 DSH 会话」 | 新会话以 managed/default 正常进入默认列表并可直接发送——新建链路与来源标记在实机闭环 |

说明：步骤 6 产生的 1 条空白会话（`sess_1790441381633…`）来自验证操作本身，保留在列表中未清理（归档与否由用户决定）。「未发现可导入会话。」这一状态文案继承自旧导入 UI，在受管同步语义下略不精确（实际含义是“同步完成，无增量”），已列为小改进项，不影响行为正确性。

诚实边界：历史候选接续（选择→manage→进入原会话）的完整续聊旅程、发送新消息、`显示全部已管理会话` 切换未在本轮逐一点击验证（候选列表与取消路径已验证；manage 语义由 MOBILE-HIST-3 与 relay 合同测试覆盖）；真实模型调用不在本轮授权范围。

## 4. 存量操作与回滚

预检：

```bash
python3 tools/repair_dsh_projections.py \
  --relay-db .task/restart/relay.db \
  --daemon-db .task/restart/daemon/daemon.db
```

写入前必须完成新 Relay schema 迁移、停止目标 Relay/daemon 且确认无在途命令。带 `--apply --services-stopped --backup-dir <新目录>` 才可写入。工具先通过 SQLite backup 生成两库快照与权限为 0600 的私有修正日志，再比较状态未变化，最后只写副本来源/可见性与同源反向映射。

回滚使用 `--restore-journal <备份目录>/repair-journal.json --services-stopped`，仅在副本及绑定未被后续操作修改时恢复上述字段。两库 WAL 不能提供跨库崩溃原子性；工具顺序为先隐藏副本、再改反向映射，保留全部数据与前置快照，发生异常不覆盖新产生的事件。

## 5. 实测结果（2026-09-27）

代码验证（全部本地 fixture/隔离库，无真实模型、无外部上传）：

| 门 | 命令 | 结果 |
| --- | --- | --- |
| Go 全量 | `go test ./... -count=1` | 全部 ok（含 9 个新增回归：store 分类迁移/存储语义、domain 接续授权、daemon 受管同步×4、relay 合同×2） |
| Flutter 全量 | `flutter test` | 623 项 passed（含 MOBILE-HIST-1..3 新增） |
| Web 单元 | `pnpm --filter @agent-sessions/web test` | 4 文件 31 项 passed |
| 静态/生成物 | `task check`、`gofmt -l`、`python3 -m unittest tools/tests/test_repair_dsh_projections.py` | PASS / 无 diff / 8 项 ok |
| 既有回归更新 | V08 导入（发现→历史隔离断言）、V094 标题/上下文（history 列表断言）、V081-P2 导入弹窗、MOBILE-01 请求体 | 全部按新契约改写后通过 |

存量修正（生产本地库，先备份后写入）：

1. 停服核对：0 在途命令、0 running 会话。
2. 仅启动 Relay 触发迁移：`sessions` 获得 `origin`/`visibility` 列；分类结果 13 条 `dsh_import/history` + 11 条 `managed/default`——与"导入回执确证来源、start 证据保留默认"的设计一致（11 个原生会话各持有用户 start 证据）。
3. 停服执行 `--apply`：备份两库快照与 `repair-journal.json`（权限 0600）至 `.task/dsh-repair-20260927/`；11 条重复副本置 `dsh_import/duplicate`，`dshthread` 反向映射全部改指原生主记录。复查预检 0 组、0 冲突（幂等收敛）。
4. 重启完整栈（同一库、同一手机配对）：`GET /v1/sessions` 返回 11 条受管会话，`GET /v1/sessions?history=true` 返回 2 条独立导入的历史候选。会话与事件总数不变（24 行、6808 事件），无任何删除。
5. 回滚路径：`tools/repair_dsh_projections.py --restore-journal .task/dsh-repair-20260927/repair-journal.json --services-stopped`（仅在副本与绑定未被后续操作修改时执行）。

诚实边界：Android 实机 UI 走查见 §6；桥侧 deepseek-harness 未提交改动不受本轮影响；`TestP2RelayDaemonRestartReplaysCommittedEventOutbox` 既有观察项维持原状（未触及该路径）。
