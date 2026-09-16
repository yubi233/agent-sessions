#!/usr/bin/env node
// V092-02 归因矩阵入口（v0.9.2 P0）：把"手机 DSH 发送闭环失败"的四层归因
// 收敛成可重复运行的证据链，供 T2 裁决与后续阶段复验。
//
// 覆盖：
//   L1 能力事实源拓扑 —— 进程内 Detect 事实（Relay 进程 vs 执行侧 Daemon 进程）
//   L2 会话生命周期   —— 有映射无句柄（Daemon 重启）时的 send/resume 语义
//   L3 探测缓存死锁   —— 首次失败永久缓存、环境修复后不可恢复
//   L4 验收口径分层   —— 由文档回填承接（本脚本只提供事实，不做结论性声称）
//
// 口径：local_test=true、fixture_data=true、real_browser=false、headless=false、
// real_model=false；live 部分（--live）用真实桥做握手与生命周期，但**不发送 prompt**，
// 因此仍然 real_model=false、不消耗 token。
//
// 用法：
//   node e2e-verify/real/v092-attribution-matrix.mjs            # 本地 fixture 矩阵
//   node e2e-verify/real/v092-attribution-matrix.mjs --live      # 追加执行侧真实桥复核
//   node e2e-verify/real/v092-attribution-matrix.mjs --out-dir e2e-verify/reports/<ts>/V092-ATTRIB
//
// 安全：只转发 Go 测试输出中的用例名、耗时与脱敏摘要；不采集环境变量值、
// token、路径或 Provider 正文。
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const hasFlag = (flag) => args.includes(flag);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};

const WITH_LIVE = hasFlag("--live");
const TIMESTAMP = new Date().toISOString().replace(/[:.]/g, "-");
const OUT_DIR = argOf("--out-dir") ?? join("e2e-verify/reports", TIMESTAMP, "V092-ATTRIB");
const REPO_ROOT = process.cwd();
// Go 构建缓存默认在工作区外；沙箱受限时可用 GOCACHE 覆盖（见 README）。
const GOCACHE = process.env.GOCACHE ?? "";

// 矩阵用例：每条都绑定结构化测试 ID 与归因层，报告里逐条登记通过/失败。
const MATRIX = [
  {
    layer: "L1",
    case_id: "V092-02",
    package: "./internal/adapter/dsh/",
    run: "TestV092DetectIsPerProcessFact",
    claim: "Detect 的可用性由持有适配器的进程环境决定（云端 Relay scratch 无 node → fail-closed）",
  },
  {
    layer: "L3",
    case_id: "V092-05",
    package: "./internal/adapter/dsh/",
    run: "TestV092ReprobeRecoversAfterTransportFailure",
    claim: "受控重探：冷却窗口内不重探（防 spawn 风暴），到期后自动恢复（无需重启进程）",
  },
  {
    layer: "L3",
    case_id: "V092-05",
    package: "./internal/adapter/dsh/",
    run: "TestV092ReprobeRecoversAfterHandshakeFailure",
    claim: "握手失败形态同样受控自愈；新失败原因实时覆盖旧原因",
  },
  {
    layer: "L3",
    case_id: "V092-05",
    package: "./internal/adapter/dsh/",
    run: "TestV092DetectCacheHitsAreFree",
    claim: "成功握手后缓存命中不重复 spawn（重探测不得退化为每请求重探）",
  },
  {
    layer: "L3",
    case_id: "V092-05",
    package: "./internal/adapter/dsh/",
    run: "TestV092ReprobeCooldownEnv",
    claim: "冷却配置语义：0=不缓存失败（诊断），非法/空值回退缺省 15s",
  },
  {
    layer: "L2",
    case_id: "V092-02",
    package: "./internal/daemon/",
    run: "TestV092AttribNewSessionBaseline",
    claim: "新会话 start→send 基线可用（不需要新增自动创建逻辑）",
  },
  {
    layer: "L2",
    case_id: "V092-06",
    package: "./internal/daemon/",
    run: "TestV092AttribRestartResumePreservesInstance",
    claim: "重启后有映射无句柄：send fail-closed 可见；resume 保留原 instance；start 会断链",
  },
  {
    layer: "L2",
    case_id: "V092-08",
    package: "./internal/daemon/",
    run: "TestV092AttribBridgeExitVisibleFailure",
    claim: "桥异常退出时失败补发为可见终态（不永久生成中）",
  },
  {
    layer: "L1",
    case_id: "V092-02",
    package: "./internal/daemon/",
    run: "TestV092AttribVersionGateRejectionIsExplicit",
    claim: "版本门拒绝是显式错误，不伪造会话建立（与版本门设计不回退一致）",
  },
];

const LIVE_MATRIX = [
  {
    layer: "L1",
    case_id: "V092-02",
    package: "./internal/adapter/dsh/",
    run: "TestV092LiveExecutionSideDetect",
    claim: "执行侧（本机 Daemon 环境）真实桥 Detect 成功且模型目录非空",
    env: { AGENT_SESSIONS_DSH_LIVE: "1" },
  },
  {
    layer: "L2",
    case_id: "V092-02",
    package: "./internal/adapter/dsh/",
    run: "TestLiveBridgeLifecycle",
    claim: "真实桥 Detect/Start/Abort/Dispose 生命周期与能力矩阵成立（不发 prompt）",
    env: { AGENT_SESSIONS_DSH_LIVE: "1" },
  },
];

// runCase 执行一条 Go 测试并返回脱敏结果。只保留用例名/耗时/PASS-FAIL。
function runCase(entry) {
  const env = { ...process.env, ...(entry.env ?? {}) };
  if (GOCACHE) env.GOCACHE = GOCACHE;
  const started = Date.now();
  const result = spawnSync(
    "go",
    ["test", entry.package, "-run", `^${entry.run}$`, "-count=1", "-v", "-timeout", "180s"],
    { cwd: REPO_ROOT, env, encoding: "utf8" },
  );
  const stdout = String(result.stdout ?? "");
  const stderr = String(result.stderr ?? "");
  const combined = `${stdout}\n${stderr}`;
  const passed = result.status === 0 && /--- PASS/.test(stdout);
  const skipped = /--- SKIP/.test(stdout);
  // 抽取 LIVE_SUMMARY 摘要行（真实桥证据的唯一凭据，与 opencode/dsh 既有惯例一致）。
  const summary =
    combined
      .split("\n")
      .find((line) => /LIVE_SUMMARY/.test(line))
      ?.trim() ?? null;
  return {
    layer: entry.layer,
    case_id: entry.case_id,
    claim: entry.claim,
    package: entry.package,
    go_test: entry.run,
    status: passed ? "passed" : skipped ? "skipped" : "failed",
    exit_code: result.status,
    duration_ms: Date.now() - started,
    live_summary: summary,
    // 失败时只保留最后一条断言行（脱敏，不含 token/正文）。
    failure_hint: passed
      ? null
      : (combined.split("\n").filter((l) => /_test\.go:\d+|FAIL|panic/.test(l)).slice(-3).join(" | ") || null),
  };
}

const cases = [...MATRIX, ...(WITH_LIVE ? LIVE_MATRIX : [])];
const results = cases.map(runCase);

const failed = results.filter((r) => r.status === "failed");
const report = {
  suite: "V092-ATTRIB-attribution-matrix",
  plan_id: "V092",
  status: failed.length === 0 ? "passed" : "failed",
  real_browser: false,
  headless: false,
  real_model: false,
  real_upstream: false,
  fixture_data: true,
  local_test: true,
  // live 分支使用真实桥子进程，但不是浏览器/模型/上游真实验证。
  real_bridge_subprocess: WITH_LIVE,
  command: `node e2e-verify/real/v092-attribution-matrix.mjs${WITH_LIVE ? " --live" : ""}`,
  started_at: new Date().toISOString(),
  findings: {
    L1: "能力事实源在进程内：同一 dsh.Adapter 代码在 Relay 进程（scratch 无 node）与执行侧 Daemon 进程得到相反结论；移动端消费的 /v1/capabilities 来自 Relay 进程，故云端误判不可用。",
    L2: "会话生命周期：store 映射与内存句柄分离；重启后有映射无句柄 → send fail-closed 且失败可见；resume（流式）保留原 instance，start 会新建实例造成历史断链。",
    L3: "首次 Detect 结果永久缓存：失败后环境修复不能自愈，只能重启进程。",
    L4: "验收口径：ACC-04/06 由 Daemon 命令调度完成，不经过手机 composer 的能力门控（由 P4 文档回填承接）。",
  },
  cases: results,
  artifacts: [],
  remaining_risk:
    "本矩阵为 fixture/local 归因证据；云端真机闭环（V092-09/10）仍需终端凭据恢复（T6）后单独执行，不得用本报告替代。",
  finished_at: null,
};

mkdirSync(OUT_DIR, { recursive: true });
const outPath = join(OUT_DIR, "attribution-matrix.json");
report.finished_at = new Date().toISOString();
report.artifacts.push(outPath);
writeFileSync(outPath, JSON.stringify(report, null, 2) + "\n");

for (const r of results) {
  console.log(
    `[v092-attrib] ${r.status.toUpperCase().padEnd(6)} ${r.layer} ${r.go_test} (${r.duration_ms}ms)${r.live_summary ? " :: " + r.live_summary : ""}`,
  );
}
console.log(`[v092-attrib] status=${report.status} report=${outPath}`);
process.exit(report.status === "passed" ? 0 : 1);
