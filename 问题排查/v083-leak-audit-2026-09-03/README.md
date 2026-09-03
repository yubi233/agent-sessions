# v0.8.3 P5-D4 泄漏审计归档（2026-09-03）

本目录归档 v0.8.3 P5-D4 泄漏审计中从 `e2e-verify/reports/ADAPTER-DSH/` 移出的中间调试产物。
这些文件未被任何文档登记为证据（唯一登记的 P4 overlay 证据 `v083-overlay-2026-09-02T18-44-53-598Z.json` 保留在 reports 并已就地脱敏），仅作审计追溯留存。

## 处置

| 文件 | 处置 |
| --- | --- |
| `v083-overlay-transcript-2026-09-02T18-43-20-316Z.jsonl` 等 3 份 | P4 阶段旧版脚本（无脱敏）产物，含绝对执行机路径；2026-09-03 就地脱敏后归档 |
| `v083-overlay-transcript-2026-09-03T01-08-48-563Z.jsonl` 等 5 份 | P5 前中间尝试（旧版脚本）产物，含绝对路径；就地脱敏后归档 |
| `v083-overlay-2026-09-03T01-08-48-563Z.json` 等 5 份 | 中间 overlay 运行报告（未被文档引用），就地脱敏（附 `audit_redaction` 注记）后归档 |

## 清理（未归档，直接删除）

- `cache-2026-08-24T*`（6 个目录）：P6 调试缓存，含真实 prompt 正文的 DSH `session.jsonl` 与 SQLite——审计中直接删除（git 未跟踪、gitignore 已覆盖、无文档引用）。
- `p0-smoke-*-stderr.txt`（15 份）：历史调试 stderr，含绝对路径——直接删除。

## 保留（就地脱敏，未移动）

- `e2e-verify/reports/ADAPTER-DSH/v083-overlay-2026-09-02T18-43-20-316Z.json`、`18-43-48-626Z.json`、`18-44-53-598Z.json`（P4 证据，文档登记 18-44-53）：command/artifacts/cwd 绝对路径就地替换为相对路径与 `[WORKDIR REDACTED]`，附 `audit_redaction` 注记，断言真值未改变。
- `e2e-verify/reports/ADAPTER-DSH/p0-smoke-2026-09-02T17-16-17-191Z.json`、`18-01-54-383Z.json`（P1 证据）与 `p0-smoke-2026-08-*`（13 份）：`--dsh-root`/artifacts 绝对路径就地脱敏，附注记。
- 本轮（2026-09-03）新产物（v083-overlay 02-33、p4-dsh-live-prompt 02-44、p4-dsh-v08-resume 02-45、gate/录屏报告、manifest）：脚本脱敏增强后生成，无明文路径。

## 结论

`e2e-verify/reports/ADAPTER-DSH/` 正式目录与本归档目录均无 DSH 用户路径、凭据、task envelope、skill 私有文件或未授权正文；含真实正文的调试缓存已删除。`internal/adapter/dsh/bridge.go` 的本机开发默认桥路径（`defaultBin`/`defaultConfig`）为 v0.8 冻结的既有设计（env 可覆盖），非产物泄露。
