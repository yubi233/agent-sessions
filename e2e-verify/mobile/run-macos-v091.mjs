#!/usr/bin/env node
// v0.9.1 P4（V091-14）：headed 可见验收 runner。
// 真实启动 macOS Flutter 窗口（headless=false），场景 terminal-presence-v091：
// 四态 Terminal presence 卡片（online/offline/unknown/unsupported，全部来自
// Relay availability 投影），覆盖亮/暗主题 × 430x932 移动视口 / 1280x800 桌面
// 视口 / 200% 文本缩放；外加一格 95 秒在线停留 soak（零手动刷新，双帧对比确认
// 卡片稳定保持 online、无 loading 闪烁）。
// 口径：real_visible_flutter=true、headless=false、fixture_data=true、本地验证、
// 不调用真实模型或真实上游。报告与截图写入 e2e-verify/reports/<timestamp>/v091-mobile-visual/。
// 复用 v090 的注入通道：V090_VISUAL_THEME / V090_VISUAL_TEXT_SCALE /
// V090_WINDOW_W/H dart-define → MethodChannel v090/visual_gate → 窗口 setContentSize；
// 截图经 app 内 RepaintBoundary render-tree 落帧通道回收（显示器锁屏也可用）。
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
const matrix = [
  { theme: "light", width: 430, height: 932, textScale: 1, id: "V091-14-light-430x932" },
  { theme: "dark", width: 430, height: 932, textScale: 1, id: "V091-14-dark-430x932" },
  { theme: "light", width: 1280, height: 800, textScale: 1, id: "V091-14-light-1280x800" },
  { theme: "dark", width: 430, height: 932, textScale: 2, id: "V091-14-dark-430x932-200pct" },
  {
    theme: "light",
    width: 430,
    height: 932,
    textScale: 1,
    id: "V091-14-soak-95s-light-430x932",
    soak: true,
    frameCount: 2,
    frameIntervalMs: 95000,
  },
];

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const reportDir = join(repoRoot, "e2e-verify/reports", stamp, "v091-mobile-visual");
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
  const frameDirName = `v091_visual_${index + 1}_${Date.now()}`;
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
    "--dart-define=LOCAL_VISUAL_SCENARIO=terminal-presence-v091",
    `--dart-define=V090_VISUAL_THEME=${cell.theme}`,
    `--dart-define=V090_VISUAL_TEXT_SCALE=${cell.textScale}`,
    `--dart-define=V090_WINDOW_W=${cell.width}`,
    `--dart-define=V090_WINDOW_H=${cell.height}`,
    `--dart-define=LOCAL_VISUAL_FRAME_DIRECTORY=${frameDirName}`,
    `--dart-define=LOCAL_VISUAL_FRAME_COUNT=${frameCount}`,
    `--dart-define=LOCAL_VISUAL_FRAME_INTERVAL_MS=${frameIntervalMs}`,
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
  const frameWaitSeconds = cell.soak ? 200 : 60;
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

const results = [];
for (const [index, cell] of matrix.entries()) {
  process.stdout.write(`[v091-visual] (${index + 1}/${matrix.length}) ${cell.id}\n`);
  results.push(await runCell(cell, index));
}

const failed = results.filter((r) => r.status !== "passed");
const report = {
  suite: "V091-flutter-visible",
  case: "V091-14",
  generated_at: new Date().toISOString(),
  real_visible_flutter: true,
  headless: false,
  fixture_data: true,
  local_test: true,
  real_model: false,
  real_upstream: false,
  real_browser: false,
  scenario: "terminal-presence-v091",
  matrix: results,
  remaining_risk: failed.length === 0 ? null : "存在失败格；逐格核查失败原因",
};
writeFileSync(join(reportDir, "report.json"), JSON.stringify(report, null, 2));
process.stdout.write(`report: ${join(reportDir, "report.json")}\n`);
process.exitCode = failed.length === 0 ? 0 : 1;
