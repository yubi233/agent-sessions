#!/usr/bin/env python3
"""校验测试 ID 唯一性、suite 引用和关键文档回填字段。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "docs" / "test" / "测试套件索引.json"


def fail(msg: str) -> None:
    print(f"docs:verify FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    index = json.loads(INDEX.read_text(encoding="utf-8"))
    owned: dict[str, str] = {}
    for suite in index["suites"]:
        path = ROOT / suite["suite_path"]
        if not path.exists():
            fail(f"missing suite {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        case_ids = [c["id"] for c in data.get("cases", [])]
        for item in suite.get("owned_ids", []):
            if item in owned:
                fail(f"duplicate owned id {item}")
            owned[item] = suite["plan_id"]
        extra = set(case_ids) - set(suite.get("owned_ids", [])) - set(suite.get("consumed_ids", []))
        if extra and data.get("plan_id") != "FOUNDATION-ACCEPTANCE":
            # 基础验收只消费 ID；领域 suite 的 cases 必须登记
            if suite["plan_id"] != "FOUNDATION-ACCEPTANCE":
                fail(f"{suite['plan_id']} cases not registered: {sorted(extra)}")
    project_doc = (ROOT / "docs" / "zh" / "项目文档.md").read_text(encoding="utf-8")
    if "SQLite" not in project_doc:
        fail("项目文档未回填 SQLite 存储决策")
    adr = ROOT / "docs" / "adr" / "ADR-008-SQLite权威存储.md"
    if not adr.exists():
        fail("缺少 ADR-008")
    print("docs:verify PASS")


if __name__ == "__main__":
    main()
