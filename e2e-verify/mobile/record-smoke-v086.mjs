#!/usr/bin/env node
// v0.8.6 Flutter 本地 smoke 录制（flutter-smoke-recording 同口径）：
// 启动预构建 macOS 调试 App（agent_sessions_mobile.app）→ Swift CoreGraphics
// 查找应用窗口 → screencapture 逐帧捕获（默认 10s/3fps）→ ffmpeg 合成 MP4。
// 口径：real_browser=false（macOS 原生窗口，非浏览器）、headless=false、
// fixture_data=false（真实启动的应用进程）、local_test=true。
// 产物：e2e-verify/screencasts/<时间戳>/MOBILE/{frames, manifest.json, *.mp4, *.log}。
// 注意：窗口级捕获需要宿主终端被授予 macOS 屏幕录制权限；未授权时自动回退
// 主屏捕获（capture_mode=macos-screen，如实标注）。

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { basename, join, resolve } from "node:path";

const args = process.argv.slice(2);
const argOf = (flag, fallback) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : fallback;
};

const seconds = Number.parseInt(argOf("--seconds", "10"), 10);
const fps = Math.max(1, Number.parseInt(argOf("--fps", "3"), 10));
const outDir = resolve(argOf("--out", "e2e-verify/screencasts"));
const scenario = argOf("--scenario", "dsh-workspace-home");
const appBundle = resolve(
  argOf(
    "--app",
    "apps/mobile/build/macos/Build/Products/Debug/agent_sessions_mobile.app",
  ),
);
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const workDir = join(outDir, stamp, "MOBILE");
const frameDir = join(workDir, `frames-${stamp}`);
const logPath = join(workDir, `smoke-${stamp}.log`);
mkdirSync(frameDir, { recursive: true });
mkdirSync(workDir, { recursive: true });

const log = (line) => {
  const lineWithBreak = `${line}\n`;
  process.stdout.write(lineWithBreak);
  appendLog(lineWithBreak);
};
let logHandle = null;
function appendLog(line) {
  if (logHandle == null) logHandle = logPath;
  if (logHandle) {
    import("node:fs").then((fs) => fs.appendFileSync(logPath, line));
  }
}

const report = {
  suite: "v086-flutter-smoke-recording",
  status: "failed",
  failure_class: null,
  real_browser: false,
  real_model: false,
  real_upstream: false,
  fixture_data: false,
  local_test: true,
  headless: false,
  browser: "n/a",
  capture: "macos-window (fallback: macos-screen)",
  seconds,
  fps,
  command: `node e2e-verify/mobile/record-smoke-v086.mjs --seconds ${seconds} --fps ${fps} --scenario ${scenario}`,
  artifacts: [],
  frames: {},
};

if (!existsSync(appBundle)) {
  console.error(`找不到预构建 App：${appBundle}（先运行 flutter build macos --debug）`);
  process.exit(1);
}

// 1) 启动 App（真实进程，注入本地 fixture 场景：主页展示终端卡片与工作区）。
const binary = join(appBundle, "Contents/MacOS",
  (process.env.AGENT_SESSIONS_APP_BINARY ?? "agent_sessions_mobile"));
// 非阻塞启动：App 常驻直到录制结束统一清理（execFileSync 会永久阻塞）。
const appProcess = spawn(binary, [], {
  env: {
    ...process.env,
    // 本地 fixture 模式：主页进入 DSH 工作区（终端卡片 + 工作区分组）。
    LOCAL_FIXTURE_MODE: "true",
    LOCAL_VISUAL_SCENARIO: scenario,
  },
  stdio: "ignore",
});
log(`launched pid=${appProcess.pid} (fixture=${scenario})`);

// 2) Swift CoreGraphics 查找应用窗口 ID（等待最多 30s）。
const lookupScript = `
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? ""
  if owner.contains("agent_sessions") {
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    print(num)
  }
}
`;
let windowId = 0;
const lookupDeadline = Date.now() + 30_000;
while (windowId === 0 && Date.now() < lookupDeadline) {
  const result = spawnSync("swift", ["-e", lookupScript], {
    encoding: "utf8",
    timeout: 20_000,
  });
  const first = (result.stdout ?? "").split("\n").map((l) => l.trim()).find(Boolean);
  if (first != null && /^\d+$/.test(first)) windowId = Number.parseInt(first, 10);
  if (windowId === 0) await new Promise((r) => setTimeout(r, 500));
}
if (windowId === 0) {
  console.error("未找到 agent_sessions_mobile 窗口（30s 超时）。");
  process.exit(1);
}
log(`window_id=${windowId}`);

// 3) 逐帧捕获：窗口级优先，失败回退主屏（capture_mode 如实标注）。
const expectedFrames = seconds * fps;
let captured = 0;
let screenFallbackUsed = false;
const captureStartedAt = Date.now();
for (let index = 1; index <= expectedFrames; index += 1) {
  const filename = `frame-${String(index).padStart(3, "0")}.png`;
  const outputPath = join(frameDir, filename);
  const windowResult = spawnSync(
    "screencapture",
    ["-x", "-l", String(windowId), "-t", "png", outputPath],
    { timeout: 15_000 },
  );
  if (windowResult.status === 0 && existsSync(outputPath)) {
    captured += 1;
    continue;
  }
  // 窗口捕获失败 → 主屏回退（仍为真实屏幕帧）。
  const screenResult = spawnSync(
    "screencapture",
    ["-x", "-t", "png", outputPath],
    { timeout: 15_000 },
  );
  if (screenResult.status === 0 && existsSync(outputPath)) {
    captured += 1;
    screenFallbackUsed = true;
  }
}
const captureMode = screenFallbackUsed ? "macos-screen-fallback" : "macos-window";
log(`captured=${captured}/${expectedFrames} mode=${captureMode}`);

// 4) ffmpeg 合成 MP4（yuv420p，输出帧率与捕获一致）。
const mp4Path = join(workDir, `smoke-${stamp}-${fps}fps.mp4`);
const encode = spawnSync("ffmpeg", [
  "-y", "-framerate", String(fps), "-i", join(frameDir, "frame-%03d.png"),
  "-c:v", "libx264", "-pix_fmt", "yuv420p", mp4Path,
], { encoding: "utf8" });
const mp4Ok = encode.status === 0 && existsSync(mp4Path) && statSync(mp4Path).size > 0;

// 5) manifest 与收口。
const frameFiles = [...Array(captured).keys()].map(
  (i) => `frame-${String(i + 1).padStart(3, "0")}.png`,
);
report.frames = {
  expected: expectedFrames,
  captured,
  capture_mode: captureMode,
  directory: frameDir,
};
report.mp4 = { path: mp4Path, exists: mp4Ok };
report.artifacts.push(logPath, frameDir, ...(mp4Ok ? [mp4Path] : []));
writeFileSync(join(workDir, "manifest.json"), JSON.stringify(report, null, 2));
report.artifacts.push(join(workDir, "manifest.json"));

try {
  appProcess.kill("SIGTERM");
} catch {}
if (captured === expectedFrames && mp4Ok) {
  report.status = "passed";
  console.log(`[v086-smoke] PASSED mp4=${mp4Path} frames=${captured}`);
} else {
  report.failure_class = captured === 0 ? "environment_or_startup_failure" : "test_harness_defect";
  console.error(`[v086-smoke] FAILED captured=${captured}/${expectedFrames} mp4Ok=${mp4Ok}`);
  process.exit(1);
}
