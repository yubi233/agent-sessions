// macOS Flutter 可见窗口截图：只允许本轮已定位的窗口，产物固定写入测试证据目录。
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function execFileResult(file, args, options = {}) {
  return new Promise((resolveResult) => {
    execFile(file, args, options, (error, stdout, stderr) => {
      resolveResult({
        code: typeof error?.code === "number" ? error.code : error ? null : 0,
        error,
        stderr: String(stderr || ""),
        stdout: String(stdout || ""),
      });
    });
  });
}

function wait(milliseconds) {
  return new Promise((resolveResult) => setTimeout(resolveResult, milliseconds));
}

/// 读取 PNG IHDR 尺寸，避免以截图文件存在替代实际可用的视觉证据。
export function parsePngDimensions(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 24 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) {
    throw new Error("截图不是有效 PNG。");
  }
  if (bytes.toString("ascii", 12, 16) !== "IHDR") {
    throw new Error("截图缺少 PNG IHDR。 ");
  }
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  if (width < 2 || height < 2) {
    throw new Error("截图尺寸无效。");
  }
  return { height, width };
}

/// 将窗口截图限制为明确的 CoreGraphics 窗口 ID，避免截取整个桌面或其他应用。
export async function captureMacosWindowScreenshot({
  windowId,
  outputPath,
  captureBinary = "screencapture",
}) {
  if (!Number.isInteger(windowId) || windowId <= 0) {
    throw new Error("截图窗口 ID 无效。");
  }
  mkdirSync(dirname(outputPath), { recursive: true });
  const result = await execFileResult(
    captureBinary,
    ["-x", "-l", String(windowId), "-t", "png", outputPath],
    { timeout: 15_000, windowsHide: true, maxBuffer: 32_000 },
  );
  if (result.code !== 0) {
    throw new Error("macOS screencapture 未能保存窗口截图。请检查 Screen Recording 权限。");
  }
  const bytes = readFileSync(outputPath);
  const dimensions = parsePngDimensions(bytes);
  const sizeBytes = statSync(outputPath).size;
  if (sizeBytes <= 0) {
    throw new Error("macOS 窗口截图为空。 ");
  }
  return {
    filename: basename(outputPath),
    ...dimensions,
    path: outputPath,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    size_bytes: sizeBytes,
  };
}

/// 在稳定的本地 fixture 场景内按固定帧率抓取窗口，避免把视觉证据绑定到单一测试回调时刻。
export async function captureMacosWindowFrameSeries({
  windowId,
  outputDirectory,
  scenarioId,
  fps = 5,
  durationMs = 3_000,
  capture = captureMacosWindowScreenshot,
  waitForNextFrame = wait,
  now = Date.now,
}) {
  if (!Number.isInteger(fps) || fps <= 0) {
    throw new Error("截图帧率必须是正整数。 ");
  }
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    throw new Error("截图持续时间必须为正数。 ");
  }
  if (typeof scenarioId !== "string" || scenarioId.trim().length === 0) {
    throw new Error("截图场景标识无效。 ");
  }
  const frameCount = Math.max(1, Math.round((durationMs / 1_000) * fps));
  const frameIntervalMs = Math.round(1_000 / fps);
  const startedAt = now();
  const frames = [];
  for (let index = 0; index < frameCount; index += 1) {
    const targetElapsedMs = index * frameIntervalMs;
    const remainingMs = targetElapsedMs - (now() - startedAt);
    if (remainingMs > 0) await waitForNextFrame(remainingMs);
    const artifact = await capture({
      windowId,
      outputPath: join(
        outputDirectory,
        `frame-${String(index + 1).padStart(4, "0")}.png`,
      ),
    });
    frames.push({
      ...artifact,
      scenarioId,
      frameIndex: index + 1,
      capturedOffsetMs: now() - startedAt,
    });
  }
  return frames;
}

/// 截图 manifest 只保存 fixture 场景、帧序列、窗口尺寸与哈希，不保存窗口文字或应用日志。
export function buildMacosScreenshotManifest({
  timestamp,
  declaredScenarioIds,
  artifacts,
  targetMobileContentSize,
  windowFrame,
  windowMode,
  frameRateFps = null,
}) {
  if (!Array.isArray(artifacts) || artifacts.length === 0) {
    throw new Error("截图 manifest 至少需要一张 PNG。 ");
  }
  const scenarioFrames = new Map();
  for (const artifact of artifacts) {
    const scenarioId = artifact.scenarioId;
    if (typeof scenarioId !== "string" || scenarioId.length === 0) continue;
    const entries = scenarioFrames.get(scenarioId) || [];
    entries.push(artifact);
    scenarioFrames.set(scenarioId, entries);
  }
  const frameSets = [...scenarioFrames.entries()].map(([scenarioId, frames]) => {
    const selectedFrame = frames.at(-1);
    return {
      scenario_id: scenarioId,
      frame_count: frames.length,
      selected_frame: selectedFrame.filename,
      selected_frame_index: selectedFrame.frameIndex ?? frames.length,
      frames: frames.map((artifact) => ({
        filename: artifact.filename,
        frame_index: artifact.frameIndex ?? null,
        captured_offset_ms: artifact.capturedOffsetMs ?? null,
        width: artifact.width,
        height: artifact.height,
        size_bytes: artifact.size_bytes,
        sha256: artifact.sha256,
      })),
    };
  });
  return {
    schema_version: 2,
    timestamp,
    suite: "mobile-macos-local-gate",
    capture_mode: "macos-window",
    fixture_data: true,
    declared_scenarios: declaredScenarioIds,
    frame_rate_fps: frameRateFps,
    captured_scenarios: frameSets.map((frameSet) => frameSet.scenario_id),
    target_mobile_content_size: targetMobileContentSize,
    observed_window_frame: windowFrame,
    observed_window_mode: windowMode,
    screenshots: frameSets.map((frameSet) => {
      const selectedFrame = frameSet.frames.at(-1);
      return {
        scenario_id: frameSet.scenario_id,
        filename: frameSet.selected_frame,
        frame_index: frameSet.selected_frame_index,
        width: selectedFrame.width,
        height: selectedFrame.height,
        size_bytes: selectedFrame.size_bytes,
        sha256: selectedFrame.sha256,
      };
    }),
    frame_sets: frameSets,
  };
}

export function writeMacosScreenshotManifest({ outputDirectory, ...manifestInput }) {
  mkdirSync(outputDirectory, { recursive: true });
  const outputPath = join(outputDirectory, "manifest.json");
  writeFileSync(
    outputPath,
    `${JSON.stringify(buildMacosScreenshotManifest(manifestInput), null, 2)}\n`,
    "utf-8",
  );
  return outputPath;
}
