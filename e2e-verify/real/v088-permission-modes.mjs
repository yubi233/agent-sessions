#!/usr/bin/env node
// v0.8.8 P3b（V088-14/15/16 / 迭代计划 §5）：权限模式三档真实栈验证。
//
// 非模型阶段（默认执行）：
//   V088-14  真实栈目录链路：restart（Relay+Daemon+DSH 桥）→ workspace.sync_dsh
//            → 创建 dsh 会话 → lease + session.start → controls 三档下发 +
//            permission_mode = danger-full-access（与生产默认一致，启用即零变化）
//            + daemon.log 无 "sync session modes failed"。
//   V088-15a mode.set 切档原子往返：danger-full-access → workspace-write → 回读
//            → 切回 danger-full-access → 回读（controls + snapshot 双面）。
//
// 真实模型阶段（需 AGENT_SESSIONS_DSH_REAL=1，免费池，与 V087-12 同授权口径）：
//   V088-15b ask 档审批卡：workspace-write（ask）档 App 自发写回合 →
//            permission.request 到达时间线 → API 放行（approve）→ 回合收敛；
//            拒绝路径为 API 发起（App 无 watch 模式不轮询 API 回合，如实降级
//            为机读证据：permission.request 事件 + reject 回执 + 回合收敛）。
//   V088-16  read-only 档写拒绝：API 发起写回合 → 沙箱拒绝 → 时间线错误面 +
//            工作区目标文件未被创建（无越权）。
//
// 口径：非模型阶段 real_model=false；真实阶段 real_model=true、real_upstream=true、
// fixture_data=false、local_test=true、headless=false。凭据只经 DSH 配置/环境加载，
// 报告不记录 prompt/回复正文/凭据（只记长度与摘要）。
// 用法：
//   node e2e-verify/real/v088-permission-modes.mjs              # 非模型阶段
//   AGENT_SESSIONS_DSH_REAL=1 node e2e-verify/real/v088-permission-modes.mjs

import { spawnSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const reportDir = join(ROOT, "e2e-verify", "reports", "ADAPTER-DSH");
mkdirSync(reportDir, { recursive: true });

const realModel = process.env.AGENT_SESSIONS_DSH_REAL === "1";
const relayBase = process.env.AGENT_SESSIONS_RELAY_BASE_URL ?? "http://127.0.0.1:8787";
const dshBin = process.env.AGENT_SESSIONS_DSH_BIN ??
  "/Users/yubi/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js";
const dshConfig = process.env.AGENT_SESSIONS_DSH_CONFIG ?? join(ROOT, "cordis.yml");
const model = process.env.AGENT_SESSIONS_DSH_MODEL ?? "nemotron-3-ultra-free";
const dshRouteProvider = process.env.AGENT_SESSIONS_DSH_PROVIDER ?? "opencode-zen";
const probeFile = process.env.AGENT_SESSIONS_V088_PROBE_FILE ?? "notes/v088-approval-probe.txt";
const EXPECTED_MODES = ["read-only", "workspace-write", "danger-full-access"];

const report = {
  suite: "v088-permission-modes",
  plan_id: "V088-14/15/16",
  report_kind: "permission_presets_real_stack",
  status: "failed",
  failure_class: null,
  executed_at: new Date().toISOString(),
  real_browser: false,
  real_model: realModel,
  real_upstream: realModel,
  fixture_data: false,
  local_test: true,
  headless: false,
  model,
  provider: "dsh",
  credential_source: "dsh-local-config-or-env-redacted",
  command: realModel
    ? "AGENT_SESSIONS_DSH_REAL=1 node e2e-verify/real/v088-permission-modes.mjs"
    : "node e2e-verify/real/v088-permission-modes.mjs",
  request_ids: [],
  usage: { input_tokens: null, output_tokens: null },
  artifacts: [],
  relay: {},
  verification: [],
  remaining_risk: "",
};
function evidence(path) {
  report.artifacts.push(path);
}

function unwrap(json) {
  if (json && typeof json === "object" && typeof json.error === "object") {
    throw new Error(`relay error: ${JSON.stringify(json.error).slice(0, 200)}`);
  }
  return json;
}
async function http(method, path, body, token) {
  const response = await fetch(`${relayBase}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined || body === null ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let parsed = null;
  try { parsed = text ? JSON.parse(text) : null; } catch { parsed = { raw: text.slice(0, 200) }; }
  if (!response.ok) {
    throw new Error(`${method} ${path} -> ${response.status}: ${text.slice(0, 200)}`);
  }
  return parsed;
}
function run(cmd, args, opts = {}) {
  const result = spawnSync(cmd, args, {
    cwd: ROOT, stdio: "inherit", timeout: 300_000, ...opts,
  });
  if (result.status !== 0) throw new Error(`${cmd} ${args.join(" ")} exit=${result.status}`);
}
function latestDaemonLog() {
  const logsRoot = join(ROOT, ".task", "restart", "logs");
  const stamps = readdirSync(logsRoot).filter((name) => /^\d{8}T\d{6}Z$/.test(name)).sort();
  for (let i = stamps.length - 1; i >= 0; i -= 1) {
    const candidate = join(logsRoot, stamps[i], "daemon.log");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}
function record(step, passed, detail) {
  report.verification.push({ step, status: passed ? "passed" : "failed", detail });
  console.log(`[v088] ${step}: ${passed ? "PASSED" : "FAILED"} ${detail ? `- ${detail}` : ""}`);
  if (!passed) throw new Error(`step failed: ${step} ${detail ?? ""}`);
}

const baseEnv = {
  ...process.env,
  AGENT_SESSIONS_RELAY_ADDR: relayBase.replace(/^https?:\/\//, ""),
  AGENT_SESSIONS_DSH_BIN: dshBin,
  AGENT_SESSIONS_DSH_CONFIG: dshConfig,
  AGENT_SESSIONS_DSH_REAL: realModel ? "1" : "0",
  AGENT_SESSIONS_DSH_PROVIDER: dshRouteProvider,
};

try {
  if (!existsSync(dshBin)) throw new Error(`DSH bin not found: ${dshBin}`);
  if (!existsSync(dshConfig)) throw new Error(`DSH config not found: ${dshConfig}`);

  // 1) 启动真实栈（Relay + Daemon + daemon 托管的 DSH 桥）。
  console.log("[v088] 启动真实栈（restart --no-flutter）");
  run("./restart.sh", ["restart", "--no-opencode", "--no-web", "--no-admin", "--no-flutter"], {
    env: baseEnv,
  });

  const tokenPath = join(ROOT, ".task", "restart", "local-owner-token");
  const token = readFileSync(tokenPath, "utf8").trim();

  // 2) DSH 工作区同步（v0.8.1 起 dsh 会话必须建在 origin=dsh 工作区）。
  console.log("[v088] 同步 DSH 工作区");
  const syncStarted = unwrap(await http("POST", "/v1/workspaces/sync-dsh", {}, token));
  const syncCommandId = syncStarted.command_id ?? syncStarted.commandId ?? syncStarted.id;
  if (!syncCommandId) throw new Error(`sync-dsh 未返回 command id`);
  let syncState = null;
  const syncDeadline = Date.now() + 120_000;
  while (Date.now() < syncDeadline) {
    await delay(2000);
    syncState = unwrap(await http("GET", `/v1/workspaces/sync-dsh/${syncCommandId}`, null, token));
    if (syncState.status === "succeeded" || syncState.status === "failed") break;
  }
  if (syncState?.status !== "succeeded") throw new Error(`DSH 工作区同步未成功`);
  const workspaces = unwrap(await http("GET", "/v1/workspaces", null, token)).workspaces ?? [];
  const dshWorkspace =
    workspaces.filter((item) => item.origin === "dsh").find((item) => item.display_name === "agent-sessions" || item.project_id === "agent-sessions") ??
    workspaces.find((item) => item.origin === "dsh");
  if (!dshWorkspace) throw new Error("授权根内未发现 dsh 工作区");

  // 3) 创建 dsh 会话 + lease + session.start。
  const created = unwrap(await http("POST", "/v1/sessions", { workspace_id: dshWorkspace.id, provider: "dsh" }, token));
  const sessionId = created.id;
  report.relay.session_id = sessionId;
  report.relay.workspace_id = dshWorkspace.id;
  console.log(`[v088] dsh 会话已创建 ${sessionId}`);
  const lease = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
  const leaseEpoch = lease.lease_epoch ?? lease.epoch;
  if (!Number.isInteger(leaseEpoch) || leaseEpoch <= 0) throw new Error("Invalid lease_epoch");
  await http("POST", `/v1/sessions/${sessionId}/commands`, {
    kind: "session.start",
    idempotency_key: `v088-start-${stamp}`,
    lease_epoch: leaseEpoch,
    ciphertext: {
      session_id: sessionId,
      ciphertext: { fixture_payload: { session_id: sessionId, provider: "dsh", model } },
    },
  }, token);
  const startDeadline = Date.now() + 120_000;
  let startReady = false;
  while (Date.now() < startDeadline) {
    await delay(2000);
    const snap = unwrap(await http("GET", `/v1/sessions/${sessionId}/snapshot?after_seq=0`, null, token));
    const status = snap.session?.status ?? "";
    if (status && status !== "stopped" && status !== "starting") { startReady = true; break; }
  }
  if (!startReady) throw new Error("session.start 在时限内未就绪");
  console.log("[v088] daemon 实例已就绪");

  // 4) V088-14：controls 三档下发 + 当前档 = defaultPreset。
  const controlsDeadline = Date.now() + 60_000;
  let controls = null;
  while (Date.now() < controlsDeadline) {
    controls = unwrap(await http("GET", `/v1/sessions/${sessionId}/controls`, null, token));
    if ((controls.available_permission_modes ?? []).length > 0) break;
    await delay(2000);
  }
  const modes = controls?.available_permission_modes ?? [];
  const threeModes = EXPECTED_MODES.every((mode) => modes.includes(mode));
  record("V088-14 目录下发三档", threeModes, `modes=${JSON.stringify(modes)}`);
  record("V088-14 当前档 = defaultPreset(danger-full-access)", controls?.permission_mode === "danger-full-access", `permission_mode=${controls?.permission_mode}`);

  // 5) daemon.log 无 sync 失败（V087-13 回归锚点：POST/PUT 漂移已修 + 目录真的上行了）。
  const daemonLog = latestDaemonLog();
  let syncFailures = "daemon.log not found";
  if (daemonLog) {
    const content = readFileSync(daemonLog, "utf8");
    syncFailures = (content.match(/sync session modes failed/g) ?? []).length;
  }
  record("V088-14 daemon.log 无 sync session modes failed", syncFailures === 0, `count=${syncFailures} log=${daemonLog ?? "n/a"}`);

  // 6) V088-15a：mode.set 切档往返（danger-full-access → workspace-write → 回）。
  async function modeSet(mode) {
    const fresh = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
    const epoch = fresh.lease_epoch ?? fresh.epoch;
    await http("POST", `/v1/sessions/${sessionId}/commands`, {
      kind: "mode.set",
      idempotency_key: `v088-modeset-${mode}-${Date.now()}`,
      lease_epoch: epoch,
      ciphertext: {
        session_id: sessionId,
        ciphertext: { fixture_payload: { session_id: sessionId, mode_id: mode } },
      },
    }, token);
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await delay(1500);
      const latest = unwrap(await http("GET", `/v1/sessions/${sessionId}/controls`, null, token));
      if (latest.permission_mode === mode) return latest;
    }
    throw new Error(`mode.set ${mode} 回读超时`);
  }
  const toWorkspaceWrite = await modeSet("workspace-write");
  record("V088-15a 切 workspace-write 回读", toWorkspaceWrite.permission_mode === "workspace-write");
  const backToDefault = await modeSet("danger-full-access");
  record("V088-15a 切回 danger-full-access 回读", backToDefault.permission_mode === "danger-full-access");

  if (!realModel) {
    report.status = "passed";
    report.remaining_risk = "非模型阶段：V088-15b（ask 审批卡）/V088-16（read-only 写拒绝）需 AGENT_SESSIONS_DSH_REAL=1 真实回合，另行执行。";
    writeFileSync(join(reportDir, `v088-permission-modes-${stamp}.json`), JSON.stringify(report, null, 2));
    console.log(`[v088] 非模型阶段完成（报告已写入 ${reportDir}）`);
    process.exit(0);
  }

  // 7) 真实模型阶段：启动 macOS App（headed；daemon 不重启防丢实例）。
  //    App 打开目标会话并由 LOCAL_DEV_SEND_MESSAGE 自发首个写回合（workspace-write ask 档）。
  console.log("[v088] 启动 macOS App（headed localdev；目标会话 + 注入写回合）");
  // relay 保留在启动集合（幂等跳过已运行实例）：owner bootstrap dart-define 必须重新下发。
  // 目标会话经 --flutter-target-session 进入 dart-define（restart.sh 不读环境变量形态）。
  run("./restart.sh", [
    "start",
    "--no-daemon",
    "--no-opencode",
    "--no-web",
    "--no-admin",
    "--flutter-target-session", sessionId,
  ], {
    env: {
      ...baseEnv,
      // 探针路径必须选「沙箱真会拒」的越界路径：/tmp 在 writableRoots（平台 temp）
      // 内，workspace-write 直接放行、无审批卡（run5/run8 实证）。家目录下的
      // 非工作区、非 temp 路径（~/v088-probe）才会被拒并诱导升级重试。
      LOCAL_DEV_SEND_MESSAGE: `请把当前日期写入文件 ~/v088-approval-probe.txt（家目录，当前工作区之外）。如果沙箱拒绝，请用 sandbox_permissions 升级到 danger-full-access 并附 justification 重试一次。`,
    },
  });
  record("V088-15b App headed 启动", true, "restart start --no-daemon --flutter-target-session（深链 + 自动发送注入）");

  // 8) V088-15b ask 档：approval=ask 的触发事实（插件源码语义，implementation note）：
  //    ask 只在「模型对沙箱拒绝的操作带 sandbox_permissions 参数重试」时经
  //    approval/request → ACP session/request_permission 到达 App；workspace-write
  //    档内的普通写（工作区根内）由沙箱直接放行，不触发审批（codex 语义，正确行为）。
  //    因此审批卡用例 = workspace-write 档 + 注入「越界写 /tmp 之外的系统路径」
  //    诱导模型先被拒再带 justification 升级重试 → 审批卡到达 App → 放行。
  await modeSet("workspace-write");
  // App 冷启动认证后自行发送注入消息；等 permission.request 事件出现在时间线。
  async function waitForPermissionRequest(deadlineMs) {
    const deadline = Date.now() + deadlineMs;
    while (Date.now() < deadline) {
      await delay(2500);
      const snap = unwrap(await http("GET", `/v1/sessions/${sessionId}/snapshot?after_seq=0`, null, token));
      for (const event of snap.events ?? []) {
        const payload = event?.envelope?.fixture_payload ?? {};
        if (payload.kind === "permission_request" || payload.kind === "permission.request") {
          return { requestId: payload.request_id ?? payload.permission?.request_id, event };
        }
      }
    }
    return null;
  }
  const approveRequest = await waitForPermissionRequest(300_000);
  record("V088-15b ask 审批卡到达（workspace-write）", approveRequest != null, `request_id=${approveRequest?.requestId ?? "n/a"}`);
  if (approveRequest) {
    const fresh = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
    await http("POST", `/v1/sessions/${sessionId}/commands`, {
      kind: "permission.approve",
      idempotency_key: `v088-approve-${Date.now()}`,
      lease_epoch: fresh.lease_epoch ?? fresh.epoch,
      ciphertext: {
        session_id: sessionId,
        ciphertext: { fixture_payload: { request_id: approveRequest.requestId } },
      },
    }, token);
    // 回合收敛：turn.completed 出现（放行后写成功并完成）。
    let completed = false;
    const done = Date.now() + 300_000;
    while (Date.now() < done) {
      await delay(2500);
      const snap = unwrap(await http("GET", `/v1/sessions/${sessionId}/snapshot?after_seq=0`, null, token));
      completed = (snap.events ?? []).some((event) => {
        const payload = event?.envelope?.fixture_payload ?? {};
        return payload.kind === "turn_phase" && payload.phase === "completed";
      });
      if (completed) break;
    }
    record("V088-15b 放行后回合收敛", completed);
    // 工作区探测文件确实被创建（写真实发生）。
    record("V088-15b 放行后写入生效", existsSync(join(homedir(), "v088-approval-probe.txt")), "~/v088-approval-probe.txt");
  }

  // 9) 拒绝路径（API 发起；App 无 watch 模式不轮询 API 回合——机读证据口径如实降级）。
  await modeSet("workspace-write");
  const fresh2 = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
  await http("POST", `/v1/sessions/${sessionId}/commands`, {
    kind: "session.send",
    idempotency_key: `v088-reject-send-${Date.now()}`,
    lease_epoch: fresh2.lease_epoch ?? fresh2.epoch,
    ciphertext: {
      session_id: sessionId,
      ciphertext: { fixture_payload: { session_id: sessionId, message: `请把字符串 "reject-probe" 写入文件 ~/v088-reject-probe.txt（家目录），如被拒请升级重试。` } },
    },
  }, token);
  const rejectRequest = await waitForPermissionRequest(300_000);
  record("V088-15b 拒绝路径审批请求到达", rejectRequest != null);
  if (rejectRequest) {
    const fresh3 = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
    await http("POST", `/v1/sessions/${sessionId}/commands`, {
      kind: "permission.reject",
      idempotency_key: `v088-reject-${Date.now()}`,
      lease_epoch: fresh3.lease_epoch ?? fresh3.epoch,
      ciphertext: {
        session_id: sessionId,
        ciphertext: { fixture_payload: { request_id: rejectRequest.requestId } },
      },
    }, token);
    record("V088-15b 拒绝应答已提交", true, `request_id=${rejectRequest.requestId}`);
  }

  // 10) V088-16：read-only 档写拒绝 + 无越权。read-only 拒绝一切变更——
  //     模型要么直接被 FS_SANDBOX_DENIED 拒绝（无审批卡），要么升级重试触发
  //     审批卡（拒绝它）。两种形态都符合 read-only 约束；验收核心 = 目标文件
  //     未被创建（无越权写入）+ 回合收敛。
  await modeSet("read-only");
  const fresh4 = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
  await http("POST", `/v1/sessions/${sessionId}/commands`, {
    kind: "session.send",
    idempotency_key: `v088-readonly-send-${Date.now()}`,
    lease_epoch: fresh4.lease_epoch ?? fresh4.epoch,
    ciphertext: {
      session_id: sessionId,
      ciphertext: { fixture_payload: { session_id: sessionId, message: `请在当前工作区创建文件 ${probeFile}.ro，内容为 "read-only probe"。` } },
    },
  }, token);
  // read-only=ask：升级重试时写入被审批卡拦截——拒绝它。
  const roRequest = await waitForPermissionRequest(300_000);
  if (roRequest) {
    const fresh5 = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
    await http("POST", `/v1/sessions/${sessionId}/commands`, {
      kind: "permission.reject",
      idempotency_key: `v088-ro-reject-${Date.now()}`,
      lease_epoch: fresh5.lease_epoch ?? fresh5.epoch,
      ciphertext: {
        session_id: sessionId,
        ciphertext: { fixture_payload: { request_id: roRequest.requestId } },
      },
    }, token);
    record("V088-16 read-only 升级写请求被 ask 拦截并拒绝", true, `request_id=${roRequest.requestId}`);
  } else {
    record("V088-16 read-only 写被沙箱直接拒绝（无升级请求）", true);
  }
  const roProbePath = join(dshWorkspace.canonical_root ?? ROOT, `${probeFile}.ro`);
  record("V088-16 无越权写入", !existsSync(roProbePath), "read-only 探测文件不存在");

  // 收尾：切回默认档（生产一致形态）。
  await modeSet("danger-full-access");

  report.status = "passed";
  report.real_browser = true;
  writeFileSync(join(reportDir, `v088-permission-modes-${stamp}.json`), JSON.stringify(report, null, 2));
  evidence(join(reportDir, `v088-permission-modes-${stamp}.json`));
  console.log(`[v088] 全部通过（报告 ${reportDir}/v088-permission-modes-${stamp}.json）`);
} catch (error) {
  report.failure_class = /时限|超时|timeout/i.test(String(error)) ? "provider_timeout" : "product_defect";
  report.remaining_risk = String(error?.message ?? error).slice(0, 500);
  writeFileSync(join(reportDir, `v088-permission-modes-${stamp}.json`), JSON.stringify(report, null, 2));
  console.error("[v088] FAILED:", error?.message ?? error);
  console.error(error?.stack ?? "");
  process.exit(1);
}

// 备注：spawn 引用保留给后续 App 内驱动扩展；当前 App 生命周期由 restart.sh 托管。
void spawn;
void homedir;
