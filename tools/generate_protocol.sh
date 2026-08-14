#!/usr/bin/env bash
# 从唯一协议 schema 生成 Go、TypeScript 与 Dart 边界；生成物不得手工编辑。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.0 \
  -generate types,gin \
  -package protocol \
  -o packages/protocol/generated/openapi.gen.go \
  packages/protocol/schema/openapi.yaml
pnpm --filter @agent-sessions/protocol exec openapi-typescript \
  "$root/packages/protocol/schema/openapi.yaml" \
  -o "$root/packages/protocol-ts/src/openapi.ts"
python3 tools/generate_dart_protocol.py
gofmt -w packages/protocol/generated/openapi.gen.go
