#!/usr/bin/env node
// v0.9.0 B7（V090-14）：headed 可见验收 runner。
// 真实启动 macOS Flutter 窗口（headless=false），覆盖亮/暗主题 × 360x800 /
// 430x932 移动视口 / 1280x800 桌面视口 + 200% 文本缩放，逐格截图并生成结构化报告。
// 口径：real_visible_flutter=true、headless=false、fixture_data=true、本地验证。
// 报告与截图写入 e2e-verify/reports/<timestamp>/v090-mobile-visual/。
// 场景：dsh-workspace-home（工作区/会话/终端/设置聚合主页，本次样式迁移最密集页面）。
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const mobileRoot = join(repoRoot, "apps/mobile");
const windowInfoSwift = join(here, "macos-window-info.swift");

const matrix = [
  { theme: "light", width: 360, height: 800, textScale: 1, id: "V090-14-light-360x800" },
  { theme: "dark", width: 360, height: 800, textScale: 1, id: "V090-14-dark-360x800" },
  { theme: "light", width: 430, height: 932, textScale: 1, id: "V090-14-light-430x932" },
  { theme: "dark", width: 430, height: 932, textScale: 1, id: "V090-14-dark-430x932" },
  { theme: "light", width: 1280, height: 800, textScale: 1, id: "V090-14-light-1280x800" },
  { theme: "dark", width: 1280, height: 800, textScale: 1, id: "V090-14-dark-1280x800" },
  { theme: "dark", width: 430, height: 932, textScale: 2, id: "V090-14-dark-430x932-200pct" },
];

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const reportDir = join(repoRoot, "e2e-verify/reports", stamp, "v090-mobile-visual");
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

// macOS 26 上 `screencapture -l <id>` 返回 "could not create image from
// window"（ScreenCaptureKit CLI 亦不可用）；改用已授权的全屏截图 + sips 按
// 窗口 bounds × Retina 缩放裁剪，得到真实窗口内容图像。
function looksBlack(pngPath) {
  // 显示器休眠时全屏截图为纯黑：黑图 PNG 压缩后极小（真实内容远大于此）。
  try {
    return statSync(pngPath).size < 20 * 1024;
  } catch {
    return true;
  }
}

function capture(window, outPath) {
  const tmp = `${outPath}.screen.png`;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    // 显示器休眠/锁定时截图为纯黑；caffeinate -u 模拟用户活动唤醒显示器。
    spawnSync("caffeinate", ["-u", "-t", "3"], { timeout: 15000 });
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
    const full = spawnSync("screencapture", ["-x", tmp], { encoding: "utf8", timeout: 30000 });
    if (full.status !== 0 || !existsSync(tmp)) continue;
    const scale = window.scale || 1;
    const cropWidth = Math.round(window.width * scale);
    const cropHeight = Math.round(window.height * scale);
    const cropOffsetY = Math.round(window.y * scale);
    const cropOffsetX = Math.round(window.x * scale);
    const crop = spawnSync(
      "sips",
      [
        "-c",
        String(cropHeight),
        String(cropWidth),
        "--cropOffset",
        String(cropOffsetY),
        String(cropOffsetX),
        tmp,
        "--out",
        outPath,
      ],
      { encoding: "utf8", timeout: 30000 },
    );
    if (crop.status === 0 && existsSync(outPath) && !looksBlack(outPath)) {
      return true;
    }
  }
  return existsSync(outPath) && !looksBlack(outPath);
}

async function runCell(cell, index) {
  // 清理历史残留的应用实例，避免窗口匹配到僵尸进程的窗口。
  spawnSync("pkill", ["-f", "agent_sessions_mobile.app"]);
  spawnSync("pkill", ["-f", "dart development-service.*agent_sessions_mobile"]);
  await new Promise((r) => setTimeout(r, 1500));
  const env = { ...process.env };
  // 帧目录名固定可预测（app 侧只接受 [A-Za-z0-9_-]）。app 是沙箱化的：
  // Directory.systemTemp 解析到容器 Data/tmp，runner 从容器路径回收帧。
  const frameDirName = `v090_visual_${index + 1}_${Date.now()}`;
  const appFrameDir = join(
    homedir(),
    "Library/Containers/com.agentsessions.agentSessionsMobile/Data/tmp",
    frameDirName,
  );
  mkdirSync(appFrameDir, { recursive: true });
  const args = [
    "run",
    "-d",
    "macos",
    "--debug",
    "--dart-define=LOCAL_FIXTURE_MODE=true",
    "--dart-define=LOCAL_VISUAL_SCENARIO=dsh-workspace-home",
    `--dart-define=V090_VISUAL_THEME=${cell.theme}`,
    `--dart-define=V090_VISUAL_TEXT_SCALE=${cell.textScale}`,
    // 视口经 dart-define→Dart→MethodChannel 注入（flutter run 不透传 env）。
    `--dart-define=V090_WINDOW_W=${cell.width}`,
    `--dart-define=V090_WINDOW_H=${cell.height}`,
    // 显示器锁屏/休眠时全屏截图不可用：改由 app 内 RepaintBoundary 从
    // render tree 落一帧真实内容 PNG（harness 既有通道）。
    `--dart-define=LOCAL_VISUAL_FRAME_DIRECTORY=${frameDirName}`,
    "--dart-define=LOCAL_VISUAL_FRAME_COUNT=1",
    "--dart-define=LOCAL_VISUAL_FRAME_INTERVAL_MS=2000",
  ];
  const logPath = join(reportDir, `${cell.id}.flutter.log`);
  const logStream = [];
  const child = spawn("flutter", args, { cwd: mobileRoot, env });
  const logFile = join(reportDir, `${cell.id}.flutter.log`);
  const logHandle = logPath;
  child.stdout.on("data", (d) => logStream.push(d.toString()));
  child.stderr.on("data", (d) => logStream.push(d.toString()));
  void logFile;

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
    return { ...cell, status: "failed", reason: "flutter run 未在 240s 内就绪", screenshot: null };
  }

  // 等待窗口出现并拿到窗口元数据（id + bounds + 缩放）。
  let window = null;
  for (let attempt = 0; attempt < 30 && !window; attempt += 1) {
    await new Promise((r) => setTimeout(r, 1000));
    window = probeWindow(child.pid);
  }
  if (!window) {
    child.kill("SIGKILL");
    return { ...cell, status: "failed", reason: "未定位到 Flutter 窗口", screenshot: null };
  }
  await new Promise((r) => setTimeout(r, 4000)); // 等首帧与 fixture 数据落定

  // render-tree 帧：app 在场景落定后写入 frame-0001.png（内容即当前视口布局）。
  const framePng = join(appFrameDir, "frame-0001.png");
  let frameCaptured = false;
  for (let attempt = 0; attempt < 45 && !frameCaptured; attempt += 1) {
    await new Promise((r) => setTimeout(r, 1000));
    frameCaptured = existsSync(framePng);
  }
  const screenshot = join(reportDir, `${cell.id}.png`);
  let captured = false;
  if (frameCaptured) {
    copyFileSync(framePng, screenshot);
    captured = true;
  } else {
    // 渲染帧不可得时回退窗口裁剪（显示器解锁场景）。
    captured = capture(window, screenshot);
  }
  const logText = logStream.join("");
  const overflow = /RenderFlex overflow|OVERFLOWED BY/.test(logText);
  const exceptions = /EXCEPTION CAUGHT BY (WIDGETS|RENDERING) LIBRARY/.test(logText);

  child.kill("SIGKILL");
  writeFileSync(logPath, logStream.join(""));
  await new Promise((r) => setTimeout(r, 2000));

  return {
    ...cell,
    status: captured && !overflow && !exceptions ? "passed" : "failed",
    reason: overflow ? "检测到 RenderFlex overflow" : exceptions ? "检测到渲染异常" : captured ? null : "截图失败",
    screenshot: captured ? screenshot : null,
    windowId: window.id,
  };
}

const results = [];
for (const [index, cell] of matrix.entries()) {
  process.stdout.write(`[v090-visual] (${index + 1}/${matrix.length}) ${cell.id}\n`);
  results.push(await runCell(cell, index));
}

const failed = results.filter((r) => r.status !== "passed");
const report = {
  suite: "V090-flutter-visible",
  case: "V090-14",
  generated_at: new Date().toISOString(),
  real_visible_flutter: true,
  headless: false,
  fixture_data: true,
  local_test: true,
  real_model: false,
  real_upstream: false,
  scenario: "dsh-workspace-home",
  matrix: results,
  remaining_risk: failed.length === 0 ? null : "存在失败格；逐格核查失败原因",
};
writeFileSync(join(reportDir, "report.json"), JSON.stringify(report, null, 2));
process.stdout.write(`report: ${join(reportDir, "report.json")}\n`);
process.exitCode = failed.length === 0 ? 0 : 1;
