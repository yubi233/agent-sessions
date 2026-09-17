#!/usr/bin/env python3
"""tools/sync_model_catalog.py 的回归测试（v0.9.2 §19.3）。

用 fixture 驱动，不读本机 ~/.dsh/settings.yaml，因此可以在任何环境（含 CI）运行。
覆盖的口径全部来自工具头部契约：
  1. 默认模型同步（acp-agent.config.provider/model <- agent-default-model）
  2. 模型集合以 settings 为准（多则删、少则补）
  3. 关键元数据（name/contextWindow/maxTokens）覆盖
  4. 桥专有配置（retryPolicy）与 provider 级渠道定义之外的字段保留 cordis 现状
  5. cordis 独有的 provider 保留
  6. --check 幂等：同步后再 check 必须为 0
  7. 中文注释在改写后必须原样保留（这是不用 YAML round-trip 的理由）
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "sync_model_catalog.py"

CORDIS_FIXTURE = """# 顶部注释：必须保留
- id: credentials
  name: './credentials.js'

- id: llm
  name: './llm.js'
  config:
    providers:
      alpha:
        apiKeyEnv: ALPHA_KEY
        api: openai-completions
        baseURL: https://alpha.example/v1
        retryPolicy:
          mode: normal
        models:
          - id: m1
            name: M1
            contextWindow: 1000
          - id: legacy-only
            name: Legacy Only
      bridge-only:
        apiKeyEnv: BRIDGE_KEY
        models:
          - id: b1
            name: B1

- id: acp-agent
  name: './acp.js'
  config:
    provider: alpha
    # 默认模型注释：必须保留
    model: m1
    modelProviders:
      m1: alpha
      legacy-only: alpha
      b1: bridge-only
"""

SETTINGS_FIXTURE = """llm-pi-ai:
  providers:
    alpha:
      apiKeyEnv: ALPHA_KEY
      api: openai-completions
      baseURL: https://alpha.example/v1
      retryPolicy:
        mode: always
      models:
        - id: m1
          name: M1
          contextWindow: 2000
        - id: m2
          name: M2
          contextWindow: 3000
agent-default-model:
  provider: alpha
  model: m2
  reasoningEffort: max
"""


class SyncModelCatalogTest(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        root = Path(self._dir.name)
        self.cordis = root / "cordis.yml"
        self.settings = root / "settings.yaml"
        self.cordis.write_text(CORDIS_FIXTURE, encoding="utf-8")
        self.settings.write_text(SETTINGS_FIXTURE, encoding="utf-8")

    def tearDown(self):
        self._dir.cleanup()

    def run_tool(self, *flags):
        proc = subprocess.run(
            [sys.executable, str(TOOL), "--settings", str(self.settings), "--cordis", str(self.cordis), *flags],
            capture_output=True, text=True,
        )
        return proc.returncode, proc.stdout + proc.stderr

    def test_check_reports_drift_before_sync(self):
        code, out = self.run_tool("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("默认模型漂移", out)
        self.assertIn("m2", out)
        self.assertIn("contextWindow", out)

    def test_write_then_check_is_idempotent(self):
        code, out = self.run_tool("--write")
        self.assertEqual(code, 0, out)
        code, out = self.run_tool("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("已同步", out)

    def test_default_model_follows_settings(self):
        self.run_tool("--write")
        text = self.cordis.read_text(encoding="utf-8")
        self.assertIn("    provider: alpha", text)
        self.assertIn("    model: m2", text)
        self.assertNotIn("    model: m1", text)

    def test_model_set_is_reconciled_both_ways(self):
        self.run_tool("--write")
        text = self.cordis.read_text(encoding="utf-8")
        self.assertIn("id: m2", text, "settings 有而 cordis 无的模型必须补上")
        self.assertNotIn("id: legacy-only", text, "cordis 有而 settings 无的模型必须删除")

    def test_key_metadata_is_overwritten(self):
        self.run_tool("--write")
        text = self.cordis.read_text(encoding="utf-8")
        self.assertIn("contextWindow: 2000", text)
        self.assertNotIn("contextWindow: 1000", text)

    def test_bridge_owned_config_is_preserved(self):
        # 口径 4：retryPolicy 是桥行为配置，不能被 settings 的同名字段覆盖。
        self.run_tool("--write")
        text = self.cordis.read_text(encoding="utf-8")
        self.assertIn("mode: normal", text)
        self.assertNotIn("mode: always", text)

    def test_cordis_only_provider_is_kept(self):
        self.run_tool("--write")
        text = self.cordis.read_text(encoding="utf-8")
        self.assertIn("bridge-only:", text)
        self.assertIn("id: b1", text)

    def test_comments_are_preserved(self):
        self.run_tool("--write")
        text = self.cordis.read_text(encoding="utf-8")
        for comment in (
            "# 顶部注释：必须保留",
            "# 默认模型注释：必须保留",
        ):
            self.assertIn(comment, text, "行级定点改写不得抹掉注释")

    def test_check_does_not_write(self):
        before = self.cordis.read_text(encoding="utf-8")
        self.run_tool("--check")
        self.assertEqual(before, self.cordis.read_text(encoding="utf-8"))

    def test_mutually_exclusive_flags(self):
        code, _ = self.run_tool("--check", "--write")
        self.assertEqual(code, 2, "同时给出 --check/--write 必须拒绝")

    def test_missing_file_is_reported(self):
        self.settings.unlink()
        code, out = self.run_tool("--check")
        self.assertEqual(code, 2, out)
        self.assertIn("缺少文件", out)


if __name__ == "__main__":
    unittest.main()
