# Daemon Git 只读服务实施计划

## 计划元数据

| 字段 | 内容 |
| --- | --- |
| plan_id | `DAEMON-GIT` |
| owner | PC Daemon / Git |
| status | `planned` |
| next_work_package | W1 状态与文件列表 |
| blocked_by | `DAEMON-CORE` 的 confirmed workspace 与 safe path API |
| target | M3 / P2 |
| protocol_revision | `PROTO-CRYPTO@v1-draft` |
| adr | ADR-005、ADR-006 |

## 1. 目标与明确排除项

在已确认 Workspace 内提供 Git `status`、`listChanges`、`diffFile`、`diffAll`。响应经端到端加密封装，通过 Relay 代理给客户端；Daemon 是唯一执行 Git、校验路径和生成 `snapshot_token` 的位置。

不提供 stage、unstage、discard、commit、push、任意 Git 配置写入、服务端 diff 缓存或 shell。

## 2. 进入条件、输入和依赖

- 输入：`DAEMON-CORE` 的 confirmed workspace registry 和 safe path API。
- 输入：Relay 的加密 Git RPC envelope、附件/消息大小限制和 error contract。
- 依赖：系统 Git；使用 `porcelain v2 -z` 或同等结构化输出来避免按人类可读文本解析。

## 3. 工作包

| 工作包 | 前置输出 | 实现步骤 | 交接输出 | 测试 ID | 最低层级 | 证据 | 回滚/开关 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1 状态与文件列表 | confirmed workspace | 参数化 `git status --porcelain=v2 -z`，解析 staged/unstaged/untracked/rename/submodule/LFS/binary | typed status/listChanges model | `GIT-01`、`GIT-03` | 单元 + 集成 | temp repo fixtures | 关闭 Git capability；不修改工作区 |
| W2 diff 与快照 | W1 | file/all diff、hunk、rename、二进制提示、分页/压缩/字节上限；生成并校验 snapshot token | typed diff model、snapshot service | `GIT-02`、`GIT-04..06` | 单元 + 集成 | drift/big diff reports | 返回 `SNAPSHOT_STALE`；客户端重新请求 |
| W3 RPC 保护 | W1/W2、Relay proxy | repo-relative path、realpath、NUL/控制字符、deadline、并发和输出限制；加密响应 | Git RPC handler、error mapping | `GIT-03` | 安全 + fuzz | path fuzz report | capability flag，拒绝而非降级到 shell |
| W4 客户端合同 | W2 | 固定 unified/split 所需字段、行号、语法 hint、分页、binary/submodule/LFS 状态 | protocol fixture 与 renderer contract | `GIT-01..06` | contract | fixtures revision | 仅新增字段；旧客户端回退 unified summary |

## 4. 数据、权限、错误和事件边界

- snapshot token 绑定 Workspace、Git HEAD/index/worktree fingerprint、请求范围与到期时间；分页时不混用不同快照。
- 所有输出都在 Daemon 加密后离开本机；Relay 不解析或缓存 diff，Web/Admin/Android 都不拥有直接文件路径。
- 超大、二进制、LFS、submodule 和不可解码文件必须明确返回可渲染的受限状态，不读取仓库外文件。

## 5. 命令、smoke、targeted diagnostic、full gate 和 recording

使用临时 Git 仓库，覆盖空仓库、staged/unstaged、rename、binary、submodule、LFS 标记、特殊文件名、snapshot drift 和超大 diff。清理临时目录；不依赖开发者个人 repo。

## 6. 退出条件、阻塞和残余风险

退出：每类状态有稳定结构化结果，越界路径不泄露文件，snapshot 漂移可检测，所有 Git 调用参数化，客户端可渲染 unified/split 或安全降级。

阻塞：系统 Git 行为与 fixtures 未覆盖的关键边界、无法证明路径不逃逸、或协议要求 Relay 看明文。残余风险：不同 Git 版本/LFS 安装差异需进入发布版本矩阵。

## 7. 文档回填清单

回填 RPC 路由、token 定义、输出限制、Git 版本假设、fixture 目录和 Android/Web 消费契约。
