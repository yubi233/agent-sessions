#!/usr/bin/env python3
"""校验测试 ID 唯一性、suite 引用和关键文档回填字段。"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "docs" / "test" / "测试套件索引.json"
REQUIRED_CASE_FIELDS = (
    "id",
    "title",
    "status",
    "phase",
    "category",
    "priority",
    "test_layer",
    "precondition",
    "steps",
    "expected",
    "cleanup",
    "evidence",
)


def fail(msg: str) -> None:
    print(f"docs:verify FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    index = json.loads(INDEX.read_text(encoding="utf-8"))
    owned: dict[str, str] = {}
    consumed: list[tuple[str, str]] = []
    for suite in index["suites"]:
        path = ROOT / suite["suite_path"]
        if not path.exists():
            fail(f"missing suite {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        # v0.4 新增/改造用例必须能直接转为自动化或人工验收；历史 suite 分批补齐字段。
        for case in data.get("cases", []):
            is_v04_case = str(case.get("phase", "")).startswith("v0.4")
            if is_v04_case:
                missing_fields = [field for field in REQUIRED_CASE_FIELDS if field not in case]
                if missing_fields:
                    fail(f"{suite['plan_id']} case {case.get('id', '<missing>')} missing fields: {missing_fields}")
                if not isinstance(case["steps"], list) or not case["steps"]:
                    fail(f"{suite['plan_id']} case {case['id']} has empty steps")
                if not isinstance(case["cleanup"], list):
                    fail(f"{suite['plan_id']} case {case['id']} cleanup must be a list")
                if not isinstance(case["evidence"], list) or not case["evidence"]:
                    fail(f"{suite['plan_id']} case {case['id']} has empty evidence")
            placeholder = " ".join([*(case.get("steps", [])), str(case.get("expected", ""))])
            if "按 v0.4 计划步骤执行" in placeholder or "见 v0.4 计划" in placeholder:
                fail(f"{suite['plan_id']} case {case['id']} still contains a v0.4 placeholder")
        case_ids = [c["id"] for c in data.get("cases", [])]
        case_id_set = set(case_ids)
        for item in suite.get("owned_ids", []):
            if item in owned:
                fail(f"duplicate owned id {item}")
            owned[item] = suite["plan_id"]
        for item in suite.get("consumed_ids", []):
            consumed.append((suite["plan_id"], item))
        extra = set(case_ids) - set(suite.get("owned_ids", [])) - set(suite.get("consumed_ids", []))
        if extra and data.get("plan_id") != "FOUNDATION-ACCEPTANCE":
            # 基础验收只消费 ID；领域 suite 的 cases 必须登记
            if suite["plan_id"] != "FOUNDATION-ACCEPTANCE":
                fail(f"{suite['plan_id']} cases not registered: {sorted(extra)}")
        # 注册表与 suite 必须双向一致：避免“已登记却没有可执行验收定义”的假覆盖。
        missing_cases = set(suite.get("owned_ids", [])) - case_id_set
        if missing_cases:
            fail(f"{suite['plan_id']} owned ids missing cases: {sorted(missing_cases)}")
    # 被消费的精确 ID 必须存在明确 owner，防止计划引用拼写错误或孤立的测试编号。
    for plan_id, item in consumed:
        if item not in owned:
            fail(f"{plan_id} consumes unowned id {item}")
    project_doc = (ROOT / "docs" / "zh" / "项目文档.md").read_text(encoding="utf-8")
    if "SQLite" not in project_doc:
        fail("项目文档未回填 SQLite 存储决策")
    adr = ROOT / "docs" / "adr" / "ADR-008-SQLite权威存储.md"
    if not adr.exists():
        fail("缺少 ADR-008")
    # v0.4 的命令流与用量都依赖明确的安全边界，避免计划倒退为无契约 UI。
    for name in ("ADR-009-Daemon-Relay命令流与版本协商.md", "ADR-010-用量聚合与隐私边界.md"):
        if not (ROOT / "docs" / "adr" / name).exists():
            fail(f"缺少 {name}")
    if "当前实现的实时传输：REST + 账号级 SSE；未实现 WebSocket" not in project_doc:
        fail("项目文档未回填当前 REST + SSE 传输事实")
    print("docs:verify PASS")


if __name__ == "__main__":
    main()
