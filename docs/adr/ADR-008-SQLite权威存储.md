# ADR-008：单租户 SQLite 权威存储

- 状态：Accepted
- 日期：2026-08-14
- 替代：ADR-001 / ADR-006 中的 PostgreSQL + Redis 选型

## 背景

首版是单租户自托管。PostgreSQL + Redis 需要 Docker 或本机服务，提高了本地开发、测试和灾备成本。Daemon 已经选择 `modernc.org/sqlite`。

## 决策

- Relay 与 Daemon 都使用纯 Go 的 `modernc.org/sqlite`，但各自维护独立的本地数据库文件。
- Relay SQLite 是账号、设备、事件、命令、ControlLease 和 Relay outbox 的唯一权威；Daemon SQLite 只保存本机状态和本机 outbox。
- presence、限流和广播提示放在进程内存；丢失后由新连接/heartbeat 和 SQLite `last_seen` 重建。ControlLease epoch 必须保存在 Relay SQLite，不能只依赖内存提示。
- 迁移使用 `internal/store/migrate.go` 中的编号 SQL，部署前复制 `.db` 文件备份。
- WAL、busy_timeout 和外键由 store 层统一配置。

## 取舍

- 放弃跨进程 Redis fanout 和 Postgres 并发写；换来零外部依赖和可复制的本地测试。
- 多实例 Relay 不是首版目标；水平扩展需另开 ADR。

## 后果

- 本地启动不强制 Postgres/Redis；P0 健康检查验证 Relay + SQLite 文件即可。
- 备份改为 SQLite 热备/文件拷贝，不再使用 `pg_dump`。
- 测试用例 `RELAY-REDIS-01` 语义改为“内存 presence 丢失后可由 SQLite 重建”。
