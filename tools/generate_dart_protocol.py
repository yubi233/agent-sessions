#!/usr/bin/env python3
"""从实时 envelope schema 生成 Flutter 使用的协议常量。"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "packages/protocol/schema/envelope.json"
OUTPUT = ROOT / "apps/mobile/lib/protocol/generated.dart"


def main() -> None:
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    properties = schema["properties"]
    required = schema["required"]
    message_types = properties["message_type"]["enum"]
    output = """// GENERATED CODE - DO NOT MODIFY BY HAND.\n// Source: packages/protocol/schema/envelope.json\n\nconst protocolVersion = 1;\n\nconst protocolMessageTypes = <String>{\n"""
    output += "".join(f"  '{item}',\n" for item in message_types)
    output += "};\n\nconst protocolEnvelopeRequiredFields = <String>{\n"
    output += "".join(f"  '{item}',\n" for item in required)
    output += "};\n"
    OUTPUT.write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()
