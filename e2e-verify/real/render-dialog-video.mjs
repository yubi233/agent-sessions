#!/usr/bin/env node
// 将一次真实 OpenCode JSON 事件流渲染为脱敏的中文对话录屏。
// 真实 Agent 的 workspace 是 testbox；事件流和视频是测试产物，必须在其外部。
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const REPORT_ROOT = join(ROOT, "e2e-verify", "reports");
const SCREENCAST_ROOT = join(ROOT, "e2e-verify", "screencasts");
const FONT = "/System/Library/Fonts/STHeiti Medium.ttc";
const FPS = 5;

function run(file, args) {
  return new Promise((resolveResult, reject) => {
    execFile(file, args, { maxBuffer: 64_000, timeout: 60_000 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`${file} failed: ${String(stderr).slice(-500)}`));
      else resolveResult({ stdout, stderr });
    });
  });
}

function safeText(value) {
  return String(value)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}\"']+/gi, "$1[REDACTED]")
    .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]")
    .replace(/\s+/g, " " )
    .trim()
    .slice(0, 520);
}

function readAssistantText(inputPath) {
  const lines = readFileSync(inputPath, "utf8").trim().split(/\r?\n/);
  const text = [];
  for (const line of lines) {
    try {
      const value = JSON.parse(line);
      for (const candidate of [value.text, value.part?.text, value.message?.content]) {
        if (typeof candidate === "string" && candidate.trim()) text.push(candidate.trim());
      }
    } catch {
      // 非 JSON 日志行不进入演示画面。
    }
  }
  const result = safeText(text.join(" "));
  if (!result) throw new Error("真实 Agent 事件流没有可展示的 assistant 文本。");
  return result;
}

function writeDisplayFiles(outputDir, assistantText) {
  const files = {
    title: join(outputDir, "title.txt"),
    user: join(outputDir, "user.txt"),
    assistant: join(outputDir, "assistant.txt"),
  };
  writeFileSync(files.title, "真实 Agent 对话\nOpenCode Go / deepseek-v4-flash", "utf8");
  writeFileSync(files.user, "用户\n请说明移动端如何创建会话、发送任务、处理权限请求并结束会话。", "utf8");
  writeFileSync(files.assistant, `真实 Agent\n${assistantText}`, "utf8");
  return files;
}

async function main() {
  const inputPath = resolve(process.argv[2] || join(REPORT_ROOT, "REAL", "real-agent-events.jsonl"));
  const outputDir = resolve(process.argv[3] || join(SCREENCAST_ROOT, "REAL", "real-agent-dialog"));
  if (!inputPath.startsWith(`${REPORT_ROOT}/`) || !outputDir.startsWith(`${SCREENCAST_ROOT}/`)) {
    throw new Error("真实对话事件流必须在 e2e-verify/reports，视频必须在 e2e-verify/screencasts。");
  }
  mkdirSync(outputDir, { recursive: true });
  const assistantText = readAssistantText(inputPath);
  // CI/macOS 上的系统 ffmpeg 可能没有 libfreetype/drawtext，回退到 Pillow 渲染，
  // 保持同一输入、输出和 5fps 证据口径。
  const filters = await run("ffmpeg", ["-filters"]);
  if (!filters.stdout.includes("drawtext")) {
    const sourceText = join(outputDir, "assistant-source.txt");
    writeFileSync(sourceText, assistantText, "utf8");
    await run("python3", [
      join(ROOT, "e2e-verify", "real", "render-dialog-video.py"),
      sourceText,
      outputDir,
    ]);
    return;
  }
  const files = writeDisplayFiles(outputDir, assistantText);
  const outputPath = join(outputDir, "real-agent-dialog.mp4");
  const filter = [
    `drawtext=fontfile='${FONT}':textfile='${files.title}':fontcolor=white:fontsize=46:line_spacing=18:x=70:y=220`,
    `drawtext=fontfile='${FONT}':textfile='${files.user}':fontcolor=0xCBD5E1:fontsize=34:line_spacing=14:x=70:y=560:enable='between(t,4,20)'`,
    `drawtext=fontfile='${FONT}':textfile='${files.assistant}':fontcolor=0x93C5FD:fontsize=34:line_spacing=14:x=70:y=980:enable='between(t,8,20)'`,
    `drawtext=fontfile='${FONT}':text='真实 Provider 输出；未混入 Flutter fixture':fontcolor=0x94A3B8:fontsize=24:x=70:y=1770`,
  ].join(",");
  await run("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-f", "lavfi",
    "-i", "color=c=0x0F172A:s=1080x1920:r=5:d=20",
    "-vf", filter, "-c:v", "libx264", "-pix_fmt", "yuv420p",
    "-movflags", "+faststart", "-y", outputPath,
  ]);
  console.log(JSON.stringify({ output: outputPath, fps: FPS, duration_seconds: 20, source: "real_model" }));
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
