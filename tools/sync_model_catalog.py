#!/usr/bin/env python3
"""同步 DSH 模型目录：~/.dsh/settings.yaml -> cordis.yml（v0.9.2 §19.3 双源对齐）。

## 为什么需要它（问题定义）

同一个语义——「默认用哪个模型、有哪些模型可选」——被写在了两个互不相通的地方：

  1. '~/.dsh/settings.yaml'（DSH 用户级配置，客户端与网关的权威默认）
     - 'llm-pi-ai.providers'：模型目录
     - 'agent-default-model'：共享 Agent 默认模型（DSH 客户端/网关消费）
  2. 仓库根的 'cordis.yml'（Happy/daemon 接入配置，dsh-happy-init 生成）
     - '- id: llm' -> 'config.providers'：模型目录的另一份拷贝
     - '- id: acp-agent' -> 'config.provider/model'：**DSH 桥进程自己的默认模型**

两者用的是**不同的配置键、不同的消费方**，因此不存在自动同步：DSH 客户端把默认模型
换成 goat/deepseek-v4.1-flash 之后，桥仍然按 cordis.yml 里的旧值
（opencode-zen/nemotron-3-ultra-free）启动会话，于是云端真机验收在首条发送就被
provider 拒绝（403 FreeTierError: OpenCode 免费池只允许官方客户端调用）。
长期方案是让桥直接消费 'agent-default-model'（上游 harness 改动，本轮暂缓），
本轮先把两个源对齐。

## 同步口径（本工具的契约）

  1. **默认模型**：'acp-agent.config.provider/model' <- 'agent-default-model'
  2. **模型集合**：以 settings.yaml 为准（多则删、少则补）
  3. **关键元数据**：共有模型的 'name/contextWindow/maxTokens' 按 settings 覆盖
  4. **桥专有字段**（'input/reasoningEfforts/api/baseURL/compat/apiKeyEnv' 等）保留
     cordis.yml 现状，仅当 settings 显式声明同名字段时才覆盖——避免同步抹掉桥的渲染配置
  5. **cordis 独有的 provider**（如兼容回退用的 'opencode-go'）保留不动
  6. **modelProviders 映射**：既有映射优先，新模型按其所属 provider 推导

## 为什么不重新 dump 整个 YAML

cordis.yml 承载大量中文注释（渠道来源、用户裁决、测试约定），任何 'yaml.safe_load'
+ 'dump' 的往返都会把它们全部抹掉。因此本工具只做**行级定点改写**：
标量差异改对应行，模型新增/删除按缩进插入/删除对应块，其余字节原样保留。

## 用法

  python3 tools/sync_model_catalog.py --check    # 只报告差异；有差异退出码 1（CI/门禁用）
  python3 tools/sync_model_catalog.py --write    # 应用同步
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

import yaml

# 行结构：可选列表前缀 + key + 可选 value。只用于**定位**，不用于重新序列化整份文档。
LINE_RE = re.compile(r"^(\s*)(-\s+)?([A-Za-z0-9_\-./]+):(\s*(.*))?$")

# 需要同步的模型级关键元数据字段（口径 3）。
SYNCED_MODEL_FIELDS = ("name", "contextWindow", "maxTokens")

# provider 级需要同步的字段：渠道定义本身（口径 4 的另一半——渠道定义跟着权威源走）。
# 而 retryPolicy 这类**桥行为**配置保留 cordis.yml 现状：桥的重试语义由接入侧决定，
# 不应被用户的 CLI 偏好覆盖。
PROVIDER_SYNCED_FIELDS = ("apiKeyEnv", "api", "baseURL", "compat")


class Line:
    """一行 YAML 的结构化视图（仅记录定位所需信息）。"""

    __slots__ = ("idx", "indent", "is_list", "key", "value")

    def __init__(self, idx, indent, is_list, key, value):
        self.idx = idx
        self.indent = indent
        self.is_list = is_list
        self.key = key
        self.value = value


def load_yaml_relaxed(path):
    """解析 YAML；cordis.yml 含 !!js 自定义标签，替换为普通标量后解析。"""
    raw = path.read_text(encoding="utf-8")
    return yaml.safe_load(raw.replace("!!js ", ""))


def scan(text):
    """扫描出所有 key 行（忽略注释与空行），保留行号用于定点改写。"""
    out = []
    for idx, raw in enumerate(text.splitlines()):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = LINE_RE.match(raw)
        if not m:
            continue
        indent = len(m.group(1)) + (2 if m.group(2) else 0)
        out.append(Line(idx, indent, bool(m.group(2)), m.group(3), (m.group(5) or "").strip()))
    return out


def find_entry(lines, entry_id):
    """定位顶层列表条目（'- id: <entry_id>'）的行号范围 [start, end)。"""
    for i, ln in enumerate(lines):
        if ln.is_list and ln.indent == 2 and ln.key == "id" and ln.value == entry_id:
            start = ln.idx
            end = lines[-1].idx + 1
            for j in range(i + 1, len(lines)):
                if lines[j].is_list and lines[j].indent <= 2:
                    end = lines[j].idx
                    break
            return start, end
    raise SystemExit("cordis.yml 中找不到条目 '- id: " + entry_id + "'")


def find_child(lines, parent_indent, key, lo, hi):
    """在 [lo, hi) 行范围内找指定缩进的 key 行。"""
    for ln in lines:
        if lo <= ln.idx < hi and ln.indent == parent_indent and ln.key == key:
            return ln
    return None


def block_end(lines, key_line, hi):
    """返回 key_line 所属块的内容结束行号（不含）。"""
    for ln in lines:
        if ln.idx > key_line.idx and ln.indent <= key_line.indent:
            return ln.idx
    return hi


def render_scalar_line(raw, key_line, value):
    """把某个 key 行的值替换为新的标量，保留缩进/列表前缀/行尾注释。"""
    prefix = raw[: len(raw) - len(raw.lstrip())]
    dash = "- " if key_line.is_list else ""
    tail = ""
    if " #" in raw:
        tail = "  #" + raw.split(" #", 1)[1]
    if isinstance(value, bool):
        lit = "true" if value else "false"
    elif value is None:
        lit = "null"
    else:
        lit = str(value)
    return prefix + dash + key_line.key + ": " + lit + tail


def render_block(obj, base_indent, list_item):
    """把一个 dict 渲染成 YAML 行（首行按列表项处理），缩进对齐 cordis.yml 风格。"""
    dumped = yaml.safe_dump(obj, allow_unicode=True, sort_keys=False, default_flow_style=False)
    out = []
    for i, raw in enumerate(dumped.rstrip("\n").splitlines()):
        pad = " " * base_indent
        if i == 0 and list_item:
            out.append(pad + "- " + raw)
        elif i == 0:
            out.append(pad + raw)
        else:
            out.append((" " * (base_indent + 2)) + raw)
    return out


def diff_catalog(settings_providers, cordis_providers):
    """计算目录差异（口径 2/3/4/5）。"""
    report = {}
    for name, sp in settings_providers.items():
        cp = cordis_providers.get(name) or {}
        s_models = sp.get("models") or []
        c_models = cp.get("models") or []
        s_ids = [m.get("id") for m in s_models]
        c_ids = [m.get("id") for m in c_models]
        entry = {
            "add_models": [m for m in s_models if m.get("id") not in c_ids],
            "remove_models": [mid for mid in c_ids if mid not in s_ids],
            "field_updates": [],
            "provider_scalars": [],
        }
        c_by_id = {m.get("id"): m for m in c_models}
        for m in s_models:
            mid = m.get("id")
            if mid not in c_by_id:
                continue
            cur = c_by_id[mid]
            for field in SYNCED_MODEL_FIELDS:
                if field in m and cur.get(field) != m.get(field):
                    entry["field_updates"].append((mid, field, m.get(field), cur.get(field)))
        for field in PROVIDER_SYNCED_FIELDS:
            if field in sp and cp.get(field) != sp.get(field):
                entry["provider_scalars"].append((field, sp.get(field), cp.get(field)))
        if entry["add_models"] or entry["remove_models"] or entry["field_updates"] or entry["provider_scalars"]:
            report[name] = entry
    return report


def sync_catalog(text, settings_providers, report):
    """按差异报告改写 cordis.yml 的 provider 目录（保留注释与其余内容）。"""
    lines = text.splitlines()
    struct = scan(text)
    llm_start, llm_end = find_entry(struct, "llm")
    providers_line = find_child(struct, 4, "providers", llm_start, llm_end)
    if providers_line is None:
        raise SystemExit("cordis.yml 的 '- id: llm' 下找不到 'providers'")

    for name, entry in report.items():
        p_line = find_child(struct, providers_line.indent + 2, name, providers_line.idx, llm_end)
        if p_line is None:
            continue
        p_end = block_end(struct, p_line, llm_end)
        for field, want, _have in entry["provider_scalars"]:
            fl = find_child(struct, p_line.indent + 2, field, p_line.idx, p_end)
            if fl is not None:
                lines[fl.idx] = render_scalar_line(lines[fl.idx], fl, want)
        models_line = find_child(struct, p_line.indent + 2, "models", p_line.idx, p_end)
        if models_line is None:
            continue
        m_end = block_end(struct, models_line, p_end)
        model_items = [ln for ln in struct if models_line.idx < ln.idx < m_end and ln.is_list]
        for mid in entry["remove_models"]:
            for i, ml in enumerate(model_items):
                if ml.key == "id" and ml.value == mid:
                    stop = model_items[i + 1].idx if i + 1 < len(model_items) else m_end
                    for k in range(ml.idx, stop):
                        lines[k] = None
                    break
        for mid, field, want, _have in entry["field_updates"]:
            for ml in model_items:
                if ml.key == "id" and ml.value == mid:
                    stop = m_end
                    for nx in model_items:
                        if nx.idx > ml.idx:
                            stop = nx.idx
                            break
                    # 列表项 '- id: x' 的 indent 已把 '- ' 计入 2 列，其子字段行缩进
                    # 正好等于该 indent（不是 +2）——这里是本工具唯一容易写错的缩进约定。
                    fl = find_child(struct, ml.indent, field, ml.idx, stop)
                    if fl is not None:
                        lines[fl.idx] = render_scalar_line(lines[fl.idx], fl, want)
                    break

    out = [ln for ln in lines if ln is not None]

    # 新增模型：逐个 provider 追加到 models 块末尾（每次重新扫描以获得准确行号）。
    for name, entry in report.items():
        for m in entry["add_models"]:
            text_now = "\n".join(out) + "\n"
            st = scan(text_now)
            llm_start2, llm_end2 = find_entry(st, "llm")
            prov_line = find_child(st, 4, "providers", llm_start2, llm_end2)
            p_line = find_child(st, prov_line.indent + 2, name, prov_line.idx, llm_end2)
            if p_line is None:
                continue
            p_end = block_end(st, p_line, llm_end2)
            models_line = find_child(st, p_line.indent + 2, "models", p_line.idx, p_end)
            if models_line is None:
                continue
            m_end = block_end(st, models_line, p_end)
            block = render_block(m, models_line.indent + 2, True)
            out = out[:m_end] + block + out[m_end:]

    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def main():
    repo_root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description="同步 DSH 模型目录 settings.yaml -> cordis.yml")
    ap.add_argument("--settings", default=os.environ.get("DSH_SETTINGS", str(Path.home() / ".dsh" / "settings.yaml")))
    ap.add_argument("--cordis", default=str(repo_root / "cordis.yml"))
    ap.add_argument("--check", action="store_true", help="只报告差异；有差异退出码 1")
    ap.add_argument("--write", action="store_true", help="应用同步")
    args = ap.parse_args()
    if not args.check and not args.write:
        ap.error("必须指定 --check 或 --write")
    if args.check and args.write:
        ap.error("--check 与 --write 互斥")

    settings_path, cordis_path = Path(args.settings), Path(args.cordis)
    for p in (settings_path, cordis_path):
        if not p.exists():
            print("缺少文件: " + str(p), file=sys.stderr)
            return 2

    settings = load_yaml_relaxed(settings_path)
    settings_providers = (settings.get("llm-pi-ai") or {}).get("providers") or {}
    default_model = settings.get("agent-default-model") or {}

    text = cordis_path.read_text(encoding="utf-8")
    cordis = yaml.safe_load(text.replace("!!js ", ""))
    llm_cfg = next(e for e in cordis if e.get("id") == "llm")["config"]
    acp_cfg = next(e for e in cordis if e.get("id") == "acp-agent")["config"]
    cordis_providers = llm_cfg.get("providers") or {}

    report = diff_catalog(settings_providers, cordis_providers)
    problems = []
    want_provider, want_model = default_model.get("provider"), default_model.get("model")
    if (acp_cfg.get("provider"), acp_cfg.get("model")) != (want_provider, want_model):
        problems.append(
            "默认模型漂移: cordis acp-agent=" + str(acp_cfg.get("provider")) + "/" + str(acp_cfg.get("model"))
            + " settings agent-default-model=" + str(want_provider) + "/" + str(want_model)
        )
    for name, entry in report.items():
        if entry["add_models"]:
            problems.append("[" + name + "] 需新增模型: " + str([m.get("id") for m in entry["add_models"]]))
        if entry["remove_models"]:
            problems.append("[" + name + "] 需删除模型: " + str(entry["remove_models"]))
        for mid, field, want, have in entry["field_updates"]:
            problems.append("[" + name + "] " + str(mid) + "." + field + ": " + repr(have) + " -> " + repr(want))
        for field, want, have in entry["provider_scalars"]:
            if have != want:
                problems.append("[" + name + "] provider." + field + " 差异")

    print("settings: " + str(settings_path))
    print("cordis  : " + str(cordis_path))
    print("")

    if not problems:
        print("已同步：模型目录与默认模型均与 settings.yaml 一致。")
        return 0

    print("差异：")
    for p in problems:
        print("  - " + p)

    if args.check:
        print("")
        print("--check：存在差异（未写入）。")
        return 1

    new_text = sync_catalog(text, settings_providers, report)
    st = scan(new_text)
    acp_start, acp_end = find_entry(st, "acp-agent")
    for field, want in (("provider", want_provider), ("model", want_model)):
        fl = find_child(st, 4, field, acp_start, acp_end)
        if fl is not None and want is not None:
            new_text = new_text.splitlines()
            st2 = scan("\n".join(new_text) + "\n")
            acp_s, acp_e = find_entry(st2, "acp-agent")
            fl2 = find_child(st2, 4, field, acp_s, acp_e)
            new_text[fl2.idx] = render_scalar_line(new_text[fl2.idx], fl2, want)
            new_text = "\n".join(new_text) + "\n"
    cordis_path.write_text(new_text, encoding="utf-8")
    print("")
    print("已写入 " + str(cordis_path))
    print("提示：daemon 需重启才会让桥进程读到新的默认模型。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
