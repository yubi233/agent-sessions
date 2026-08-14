# protocol

跨端唯一契约仓。REST 以 OpenAPI 3.1 为事实源，事件/命令以 JSON Schema Draft 2020-12 为事实源。

- `schema/openapi.yaml`：REST inventory。
- `schema/envelope.json`：WebSocket/SSE 统一信封。
- `schema/errors.json`：稳定错误码。
- `schema/events.json`：canonical 事件。
- `schema/commands.json`：异步命令。
- `generated/`：生成物，禁止手改。

消费方只能映射本仓类型，不得复制 DTO。
