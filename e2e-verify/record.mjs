#!/usr/bin/env node
// 录屏演示入口：用 headed 真实浏览器 + CDP Page.startScreencast 抓帧，
// 合成 mp4 保存到 e2e-verify/screencasts/<timestamp>/。
// 依据 web-iterative-workflow：核心 gate 通过后才录屏；默认 6fps / jpeg q65。
// 用法：node e2e-verify/record.mjs [--fps 6] [--quality 65]
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { startRelay } from "./lib/relay.mjs";
import { launchHeaded } from "./lib/browser.mjs";
import { startWeb } from "./lib/web.mjs";
import { baseReport, writeReport } from "./lib/report.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCREENCAST_DIR = join(dirname(fileURLToPath(import.meta.url)), "screencasts");

// demoScript 描述本次录屏要展示的用户可见流程（步骤 + 停留）。
// 先展示 Relay 就绪，再展示 P1 只读登录与设备列表。
const demoScript = [
  { name: "打开 Relay 状态页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 500 },
  { name: "等待 Relay 就绪", action: async (page) => page.getByTestId("relay-ready").waitFor({ state: "visible" }), dwell: 800 },
  { name: "点击重新检查", action: async (page) => page.getByTestId("refresh-health").click(), dwell: 800 },
  { name: "填写只读登录邮箱", action: async (page) => page.getByTestId("login-email").fill("demo@example.dev"), dwell: 400 },
  { name: "填写密码", action: async (page) => page.getByTestId("login-password").fill("demo-pass-123"), dwell: 400 },
  { name: "点击登录并查看只读设备", action: async (page) => {
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "展示只读设备列表", action: async (page) => page.getByTestId("device-list").waitFor({ state: "visible" }), dwell: 900 },
];

function parseArgs(argv) {
  const args = { fps: 6, quality: 65 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--fps") args.fps = parseInt(argv[++i], 10);
    else if (argv[i] === "--quality") args.quality = parseInt(argv[++i], 10);
  }
  return args;
}

async function main() {
  const { fps, quality } = parseArgs(process.argv.slice(2));
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const outDir = join(SCREENCAST_DIR, ts);
  const frameDir = join(outDir, "frames");
  mkdirSync(frameDir, { recursive: true });

  const relay = await startRelay({ port: 8787 });
  const web = await startWeb({ relayBase: relay.base });
  const browser = await launchHeaded({ headless: false });
  const frames = [];

  try {
    // 预置录屏演示账号（bootstrap owner），保证登录流程可重复演示。
    const reg = await fetch(`${relay.base}/v1/auth/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "demo@example.dev", password: "demo-pass-123" }),
    });
    if (!reg.ok) {
      throw new Error(`seed demo account failed: ${reg.status} ${await reg.text()}`);
    }

    const page = await browser.newPage();
    const cdp = await page.context().newCDPSession(page);

    await cdp.send("Page.startScreencast", {
      format: "jpeg",
      quality,
      everyNthFrame: 1,
    });

    let seq = 0;
    cdp.on("Page.screencastFrame", ({ data, sessionId }) => {
      const file = join(frameDir, `frame-${String(seq++).padStart(5, "0")}.jpg`);
      writeFileSync(file, Buffer.from(data, "base64"));
      frames.push(file);
      cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
    });

    // 逐步骤执行用户可见流程，每个状态保留停留时间以便录屏审阅。
    for (const step of demoScript) {
      await step.action(page, web.base);
      await new Promise((r) => setTimeout(r, step.dwell));
    }

    await cdp.send("Page.stopScreencast");

    const manifest = {
      timestamp: ts,
      fps,
      quality,
      steps: demoScript.map((s) => s.name),
      frame_count: frames.length,
      relay_base: relay.base,
      web_base: web.base,
    };
    writeFileSync(join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

    // 用 ffmpeg 合成 mp4；缺少 ffmpeg 时仅保留帧与 manifest。
    const mp4 = join(outDir, "demo.mp4");
    if (existsSync("/opt/homebrew/bin/ffmpeg") || existsSync("/usr/local/bin/ffmpeg")) {
      await synthMp4(frameDir, mp4, fps);
      manifest.mp4 = mp4;
      writeFileSync(join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
    } else {
      process.stdout.write("[record] ffmpeg 不可用，仅保留帧与 manifest\n");
    }

    process.stdout.write(`[record] 完成：${outDir}（${frames.length} 帧）\n`);
    writeReport({
      planId: "PROTO-CRYPTO",
      name: "p0-web-relay-recording",
      report: baseReport({
        suite: "p0-web-relay-recording",
        status: "passed",
        real_browser: true,
        fixture_data: true,
        local_test: true,
        headless: false,
        browser: "system-chrome",
        command: "node e2e-verify/record.mjs",
        artifacts: [join(outDir, "manifest.json"), mp4],
        remaining_risk: "录屏复用已通过的 P0 Web 状态回归；不覆盖 P1 账户和会话功能。",
      }),
    });
  } finally {
    await browser.close();
    await web.stop();
    await relay.stop();
  }
}

function synthMp4(dir, out, fps) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "ffmpeg",
      [
        "-framerate",
        String(fps),
        "-i",
        join(dir, "frame-%05d.jpg"),
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-y",
        out,
      ],
      { stdio: "inherit" },
    );
    child.on("error", reject);
    child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`))));
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
