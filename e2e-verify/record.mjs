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
import { startWeb, startAdmin } from "./lib/web.mjs";
import { baseReport, writeReport } from "./lib/report.mjs";

// seedDemoSession 为 p4-web 录屏预置一条只读会话（白名单元数据，无正文）。
// 使用注册响应的 owner 写 token；浏览器仍走可见密码登录。
async function seedDemoSession(relayBase, ownerToken) {
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${ownerToken}`,
  };
  const ws = await fetch(`${relayBase}/v1/workspaces`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      project_id: "demo-project",
      terminal_id: "",
      canonical_root: "/demo",
      status: "active",
    }),
  });
  if (!ws.ok) throw new Error(`demo workspace failed: ${ws.status}`);
  const workspace = await ws.json();
  const session = await fetch(`${relayBase}/v1/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify({ workspace_id: workspace.id, provider: "codex" }),
  });
  if (!session.ok) throw new Error(`demo session failed: ${session.status}`);
}

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
  const args = { fps: 6, quality: 65, suite: "p1" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--fps") args.fps = parseInt(argv[++i], 10);
    else if (argv[i] === "--quality") args.quality = parseInt(argv[++i], 10);
    else if (argv[i] === "--suite") args.suite = argv[++i] || "p1";
  }
  return args;
}

// v0.2/P5：能力矩阵录屏 demo：登录只读 Web 后打开能力矩阵页，
// 展示 opencode 真实探测结果（version/start/resume/abort native）且页面无写入口。
const capabilityMatrixDemoScript = [
  { name: "打开 Web 只读首页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "登录演示账号", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "打开能力矩阵", action: async (page) => {
      await page.getByTestId("capabilities-link").click();
      await page.getByTestId("capability-matrix-view").waitFor({ state: "visible" });
    }, dwell: 1000 },
  { name: "展示 opencode 真实探测结果", action: async (page) => {
      await page.getByTestId("matrix-provider-opencode").waitFor({ state: "visible" });
      await page.getByTestId("matrix-version-opencode").waitFor({ state: "visible" });
    }, dwell: 1400 },
];

// P4 Web 只读闭环录屏：登录 -> 会话列表 -> 详情 -> 文件/Git 降级 -> 终端。
const p4WebReadOnlyDemoScript = [
  { name: "打开 Web 只读首页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "登录只读账号", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "打开会话列表", action: async (page) => {
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "进入会话详情", action: async (page) => {
      const link = page.locator('[data-testid^="session-link-"]').first();
      await link.click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
    }, dwell: 1000 },
  { name: "文件页 unavailable 降级", action: async (page) => {
      await page.getByTestId("session-files-link").click();
      await page.getByTestId("files-error").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "Git Diff unavailable 降级", action: async (page) => {
      await page.goBack();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page.getByTestId("session-git-link").click();
      await page.getByTestId("git-error").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "终端状态", action: async (page) => {
      await page.goBack();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page.click('a[href="#/terminals"]');
      await page.getByTestId("terminals-list").waitFor({ state: "visible" });
    }, dwell: 1000 },
];

// P4 Admin 四分区录屏：登录 -> 概览 -> 终端 -> 会话 -> 审计。
const p4AdminDemoScript = [
  { name: "打开 Admin 概览", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "管理员登录", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "概览脱敏摘要", action: async (page) => page.getByTestId("device-list").waitFor({ state: "visible" }), dwell: 900 },
  { name: "终端分区", action: async (page) => {
      await page.click('a[href="#/terminals"]');
      await page.getByTestId("terminals-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "会话分区", action: async (page) => {
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "审计分区", action: async (page) => {
      await page.click('a[href="#/audit"]');
      await page.getByTestId("audit-list").waitFor({ state: "visible" });
    }, dwell: 1000 },
];

async function main() {
  const { fps, quality, suite } = parseArgs(process.argv.slice(2));
  // 先登记回归内容：suite=p4-web 录 Web 只读闭环，suite=p4-admin 录 Admin 四分区，
  // suite=p5 录能力矩阵，其余保留既有 P1 只读 demo。
  const activeDemo = suite === "p5"
    ? capabilityMatrixDemoScript
    : suite === "p4-web"
      ? p4WebReadOnlyDemoScript
      : suite === "p4-admin"
        ? p4AdminDemoScript
        : demoScript;
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const outDir = join(SCREENCAST_DIR, ts);
  const frameDir = join(outDir, "frames");
  mkdirSync(frameDir, { recursive: true });

  // 录屏也必须使用隔离动态端口，不能碰用户已有 Relay 数据库。
  const relay = await startRelay();
  const app = suite === "p4-admin" ? await startAdmin({ relayBase: relay.base }) : await startWeb({ relayBase: relay.base });
  const browser = await launchHeaded({ headless: false });
  const frames = [];

  try {
    // 预置录屏演示账号（bootstrap owner），保证登录流程可重复演示。
    // 注册响应携带 owner 写 token（仅用于预置会话，不进入录屏或报告）。
    const reg = await fetch(`${relay.base}/v1/auth/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "demo@example.dev", password: "demo-pass-123" }),
    });
    if (!reg.ok) {
      throw new Error(`seed demo account failed: ${reg.status} ${await reg.text()}`);
    }
    const demoOwner = await reg.json();
    // p4-web 录屏需要一条 fixture 会话供列表/详情展示。
    if (suite === "p4-web") {
      await seedDemoSession(relay.base, demoOwner.access_token);
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
    for (const step of activeDemo) {
      await step.action(page, app.base);
      await new Promise((r) => setTimeout(r, step.dwell));
    }

    await cdp.send("Page.stopScreencast");

    const manifest = {
      timestamp: ts,
      fps,
      quality,
      suite,
      steps: activeDemo.map((s) => s.name),
      frame_count: frames.length,
      relay_base: relay.base,
      web_base: app.base,
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
        suite: suite === "p5" ? "p5-opencode-capabilities-recording" : "p0-web-relay-recording",
        status: "passed",
        real_browser: true,
        fixture_data: true,
        local_test: true,
        headless: false,
        browser: "system-chrome",
        command: `node e2e-verify/record.mjs --suite ${suite}`,
        artifacts: [join(outDir, "manifest.json"), mp4],
        remaining_risk: suite === "p5"
          ? "录屏展示能力矩阵真实探测结果；探测失败路径由 p5-opencode-capabilities headed 回归覆盖。"
          : "录屏复用已通过的 P0 Web 状态回归；不覆盖 P1 账户和会话功能。",
      }),
    });
  } finally {
    await browser.close();
    await app.stop();
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
