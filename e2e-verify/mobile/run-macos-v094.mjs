#!/usr/bin/env node
// v0.9.4 P4（V094-20）：headed 可见验收矩阵 runner。
// 真实启动 macOS Flutter 窗口（headless=false），覆盖 V094 三个登记 fixture 场景
// （v094-session-ui-baseline / v094-session-ui-recovery / v094-session-ui-config）
// × 360x800 / 430x932 / 1280x800 视口 × 亮/暗主题，外加 320dp 窄屏与 200% 文本缩放。
// 口径：real_visible_flutter=true、headless=false、fixture_data=true、本地验证、
// 不调用真实模型或真实上游。截图以 app 内 RepaintBoundary render-tree 落帧为主，
// 取不到帧时回退窗口裁剪（显示器解锁场景）。
// 报告与截图写入 e2e-verify/reports/<timestamp>/v094-mobile-visual/。
// 复用 v090/v091 注入通道：V090_VISUAL_THEME / V090_VISUAL_TEXT_SCALE /
// V090_WINDOW_W/H dart-define → MethodChannel v090/visual_gate → 窗口 setContentSize。
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const mobileRoot = join(repoRoot, "apps/mobile");
const windowInfoSwift = join(here, "macos-window-info.swift");

// soak 格：FRAME_COUNT=2 + FRAME_INTERVAL_MS=95000，app 在 t0 与 t0+95s 各落
// 一帧；runner 等待第二帧落盘（覆盖 ≥90 秒前台停留与 45-60s safety reconcile 周期）。
const BASELINE = "v094-session-ui-baseline";
const RECOVERY = "v094-session-ui-recovery";
const CONFIG = "v094-session-ui-config";

// V094-20 矩阵：普通字号覆盖 360/430/1280 亮暗；补 320dp 窄屏与 200% 字号。
// 三个登记场景分别承载 长代码/表格/dock、恢复与结构化错误、配置徽标与长模型名。
const matrix = [
  { scenario: BASELINE, id: "V094-20-baseline-light-360x800", theme: "light", width: 360, height: 800, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-dark-360x800", theme: "dark", width: 360, height: 800, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-light-430x932", theme: "light", width: 430, height: 932, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-dark-430x932", theme: "dark", width: 430, height: 932, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-light-1280x800", theme: "light", width: 1280, height: 800, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-dark-1280x800", theme: "dark", width: 1280, height: 800, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-light-320x800-narrow", theme: "light", width: 320, height: 800, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-dark-430x932-200pct", theme: "dark", width: 430, height: 932, textScale: 2 },
  { scenario: RECOVERY, id: "V094-20-recovery-light-360x800", theme: "light", width: 360, height: 800, textScale: 1 },
  { scenario: RECOVERY, id: "V094-20-recovery-dark-430x932", theme: "dark", width: 430, height: 932, textScale: 1 },
  { scenario: RECOVERY, id: "V094-20-recovery-dark-430x932-200pct", theme: "dark", width: 430, height: 932, textScale: 2 },
  { scenario: CONFIG, id: "V094-20-config-light-430x932", theme: "light", width: 430, height: 932, textScale: 1 },
  { scenario: CONFIG, id: "V094-20-config-dark-430x932", theme: "dark", width: 430, height: 932, textScale: 1 },
  { scenario: BASELINE, id: "V094-20-baseline-light-800x360-landscape", theme: "light", width: 800, height: 360, textScale: 1 },
];

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const reportDir = join(repoRoot, "e2e-verify/reports", stamp, "v094-mobile-visual");
mkdirSync(reportDir, { recursive: true });

// flutter run 的 PID 是 flutter 工具进程，不是应用进程；窗口按进程名
// agent_sessions_mobile 匹配（runner 逐格串行，同屏只有一个应用窗口）。
function probeWindow(_pid) {
  const compile = spawnSync("swift", [windowInfoSwift, "--process-name", "agent_sessions_mobile"], {
    encoding: "utf8",
    timeout: 60000,
  });
  if (compile.status !== 0) return null;
  try {
    const payload = JSON.parse(compile.stdout);
    const windows = [...payload.windows].sort((a, b) => b.id - a.id);
    return windows.length > 0 ? windows[0] : null;
  } catch {
    return null;
  }
}

// 渲染帧不可得时回退窗口裁剪（显示器解锁场景）。
function capture(window, outPath) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    spawnSync("caffeinate", ["-u", "-t", "3"], { timeout: 15000 });
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
    const tmp = `${outPath}.screen.png`;
    const full = spawnSync("screencapture", ["-x", tmp], { encoding: "utf8", timeout: 30000 });
    if (full.status !== 0 || !existsSync(tmp)) continue;
    const scale = window.scale || 1;
    const crop = spawnSync(
      "sips",
      [
        "-c",
        String(Math.round(window.height * scale)),
        String(Math.round(window.width * scale)),
        "--cropOffset",
        String(Math.round(window.y * scale)),
        String(Math.round(window.x * scale)),
        tmp,
        "--out",
        outPath,
      ],
      { encoding: "utf8", timeout: 30000 },
    );
    if (crop.status === 0 && existsSync(outPath) && statSync(outPath).size > 20 * 1024) {
      return true;
    }
  }
  return existsSync(outPath) && statSync(outPath).size > 20 * 1024;
}

async function runCell(cell, index) {
  spawnSync("pkill", ["-f", "agent_sessions_mobile.app"]);
  spawnSync("pkill", ["-f", "dart development-service.*agent_sessions_mobile"]);
  await new Promise((r) => setTimeout(r, 1500));
  const env = { ...process.env };
  const frameDirName = `v094_visual_${index + 1}_${Date.now()}`;
  const appFrameDir = join(
    homedir(),
    "Library/Containers/com.agentsessions.agentSessionsMobile/Data/tmp",
    frameDirName,
  );
  mkdirSync(appFrameDir, { recursive: true });
  const frameCount = cell.frameCount ?? 1;
  const frameIntervalMs = cell.frameIntervalMs ?? 2000;
  const args = [
    "run",
    "-d",
    "macos",
    "--debug",
    "--dart-define=LOCAL_FIXTURE_MODE=true",
    // 反引号模板：双引号不插值，场景名会以字面 ${cell.scenario} 传入（首轮冒烟拍到引导页的根因）。
    `--dart-define=LOCAL_VISUAL_SCENARIO=${cell.scenario}`,
    `--dart-define=V090_VISUAL_THEME=${cell.theme}`,
    `--dart-define=V090_VISUAL_TEXT_SCALE=${cell.textScale}`,
    `--dart-define=V090_WINDOW_W=${cell.width}`,
    `--dart-define=V090_WINDOW_H=${cell.height}`,
    `--dart-define=LOCAL_VISUAL_FRAME_DIRECTORY=${frameDirName}`,
    `--dart-define=LOCAL_VISUAL_FRAME_COUNT=${frameCount}`,
    `--dart-define=LOCAL_VISUAL_FRAME_INTERVAL_MS=${frameIntervalMs}`,
    // V094 场景 seeding 较重：12s 场景落定等待（app 默认 3s 不够）。
    `--dart-define=LOCAL_VISUAL_FRAME_SETTLE_MS=${cell.settleMs ?? 12000}`,
  ];
  const logFile = join(reportDir, `${cell.id}.flutter.log`);
  const logStream = [];
  const child = spawn("flutter", args, { cwd: mobileRoot, env });
  child.stdout.on("data", (d) => logStream.push(d.toString()));
  child.stderr.on("data", (d) => logStream.push(d.toString()));

  // 等待应用就绪（VM Service 输出）。
  const ready = await new Promise((resolveReady) => {
    const timer = setTimeout(() => resolveReady(false), 240000);
    const onData = (d) => {
      if (/Dart VM Service|Flutter run key commands/.test(d.toString())) {
        clearTimeout(timer);
        resolveReady(true);
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
  });
  if (!ready) {
    child.kill("SIGKILL");
    return { ...cell, status: "failed", reason: "flutter run 未在 240s 内就绪", screenshot: null, frames: [] };
  }

  let window = null;
  for (let attempt = 0; attempt < 30 && !window; attempt += 1) {
    await new Promise((r) => setTimeout(r, 1000));
    window = probeWindow(child.pid);
  }
  if (!window) {
    child.kill("SIGKILL");
    return { ...cell, status: "failed", reason: "未定位到 Flutter 窗口", screenshot: null, frames: [] };
  }
  await new Promise((r) => setTimeout(r, 4000)); // 等首帧与 fixture 数据落定

  // render-tree 帧：app 按 frameCount × interval 依次写入 frame-000N.png。
  // soak 格的第二帧在 ~95s 落盘（覆盖 90 秒前台停留 + ≥1 个 safety reconcile 周期）。
  const frameWaitSeconds = cell.soak ? 200 : 120;
  const frames = [];
  for (let frameIndex = 1; frameIndex <= frameCount; frameIndex += 1) {
    const name = `frame-${String(frameIndex).padStart(4, "0")}.png`;
    const framePath = join(appFrameDir, name);
    let capturedFrame = false;
    for (let attempt = 0; attempt < frameWaitSeconds && !capturedFrame; attempt += 1) {
      await new Promise((r) => setTimeout(r, 1000));
      capturedFrame = existsSync(framePath);
    }
    if (capturedFrame) {
      const out = join(reportDir, `${cell.id}-frame-${frameIndex}.png`);
      copyFileSync(framePath, out);
      frames.push({ frame: frameIndex, path: out, bytes: statSync(out).size });
    }
  }
  const screenshot = join(reportDir, `${cell.id}.png`);
  let captured = false;
  if (frames.length > 0) {
    copyFileSync(frames[0].path, screenshot);
    captured = true;
  } else {
    captured = capture(window, screenshot);
  }
  const logText = logStream.join("");
  const overflow = /RenderFlex overflow|OVERFLOWED BY/.test(logText);
  const exceptions = /EXCEPTION CAUGHT BY (WIDGETS|RENDERING) LIBRARY/.test(logText);
  const frameOk = frames.length === frameCount;

  child.kill("SIGKILL");
  writeFileSync(logFile, logStream.join(""));
  await new Promise((r) => setTimeout(r, 2000));

  return {
    ...cell,
    status: captured && frameOk && !overflow && !exceptions ? "passed" : "failed",
    reason: !frameOk
      ? `render-tree 帧缺失（${frames.length}/${frameCount}）`
      : overflow
        ? "检测到 RenderFlex overflow"
        : exceptions
          ? "检测到渲染异常"
          : captured
            ? null
            : "截图失败",
    screenshot: captured ? screenshot : null,
    frames,
    windowId: window.id,
  };
}

// --only <substring>：只跑匹配的格，便于单格冒烟与失败复跑。
const onlyIndex = process.argv.indexOf("--only");
const only = onlyIndex >= 0 ? process.argv[onlyIndex + 1] ?? "" : "";
const cells = only ? matrix.filter((cell) => cell.id.includes(only)) : matrix;
if (cells.length === 0) {
  process.stderr.write(`--only ${only} 未匹配任何矩阵格\n`);
  process.exit(2);
}

const results = [];
for (const [index, cell] of cells.entries()) {
  process.stdout.write(`[v094-visual] (${index + 1}/${cells.length}) ${cell.id}\n`);
  results.push(await runCell(cell, index));
}

const failed = results.filter((r) => r.status !== "passed");
const report = {
  suite: "V094-flutter-visible",
  case: "V094-20",
  generated_at: new Date().toISOString(),
  real_visible_flutter: true,
  headless: false,
  fixture_data: true,
  local_test: true,
  real_model: false,
  real_upstream: false,
  real_browser: false,
  real_device: false,
  scenarios: [BASELINE, RECOVERY, CONFIG],
  matrix: results,
  summary: {
    total: results.length,
    passed: results.filter((r) => r.status === "passed").length,
    failed: failed.length,
  },
  remaining_risk: failed.length === 0
    ? "键盘避让、横屏软键盘与物理 Android 矩阵不在本报告范围（分别属 V094-20 真机项与 V094-21 完整旅程）。"
    : "存在失败格；逐格核查失败原因。",
};
writeFileSync(join(reportDir, "report.json"), JSON.stringify(report, null, 2));
process.stdout.write(`report: ${join(reportDir, "report.json")}\n`);
process.exitCode = failed.length === 0 ? 0 : 1;
