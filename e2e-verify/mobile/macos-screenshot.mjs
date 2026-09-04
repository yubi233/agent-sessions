// macOS Flutter 可见窗口截图：只允许本轮已定位的窗口，产物固定写入测试证据目录。
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
export const FLUTTER_RENDER_BOUNDARY_FALLBACK = "flutter-render-boundary-fallback";
// 所有可见窗口证据固定 5fps/200ms 调度。采集器不接受按秒数截断的短窗口，
// 而是先完成足够长的连续采集，再筛选出可审计的连续证据。
export const WINDOW_EVIDENCE_FPS = 5;
// 这是候选序列的最低完整性门槛，不是 duration 参数或一秒截图窗口。
// 300 帧约覆盖一分钟可见窗口，避免只抓取静态瞬间；采集实现允许未来场景提供更多候选帧。
export const WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT = 300;
// 最终 artifact 必须保留数十至数百张连续截图，不能退化为 1 秒或五张图片。
export const WINDOW_EVIDENCE_SELECTED_FRAME_COUNT = 100;
export const WINDOW_EVIDENCE_FRAME_INTERVAL_MS = 200;
export const WINDOW_EVIDENCE_MAX_START_DRIFT_MS = 100;
const MACOS_WINDOW_CAPTURE = "macos-window";

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

/// 严格窗口证据不能只有名义 5fps：每帧必须连续落在 200ms 调度点。
/// OS 调度只能允许有限启动偏差；超过 100ms 时拒绝报告，不能把慢采样标成 5fps。
export function validateStrictWindowFrameSeries({
  frames,
  fps = WINDOW_EVIDENCE_FPS,
  expectedFrameCount = null,
  minimumFrameCount = null,
}) {
  if (fps !== WINDOW_EVIDENCE_FPS) {
    throw new Error(`窗口证据必须固定为 ${WINDOW_EVIDENCE_FPS}fps。`);
  }
  if (!Array.isArray(frames) || frames.length === 0) {
    throw new Error("窗口证据至少需要一张连续帧。 ");
  }
  if (expectedFrameCount != null && frames.length !== expectedFrameCount) {
    throw new Error(
      `窗口证据必须采集恰好 ${expectedFrameCount} 个连续帧。`,
    );
  }
  if (minimumFrameCount != null && frames.length < minimumFrameCount) {
    throw new Error(
      `窗口证据至少需要 ${minimumFrameCount} 个连续候选帧。`,
    );
  }
  for (let index = 0; index < frames.length; index += 1) {
    const frame = frames[index];
    const scheduledOffsetMs = index * WINDOW_EVIDENCE_FRAME_INTERVAL_MS;
    if (frame?.frameIndex !== index + 1 || frame?.scheduledOffsetMs !== scheduledOffsetMs) {
      throw new Error("窗口证据帧序或 200ms 调度点不连续。 ");
    }
    const startedOffsetMs = frame.captureStartedOffsetMs;
    const completedOffsetMs = frame.capturedOffsetMs;
    if (
      !Number.isFinite(startedOffsetMs)
      || startedOffsetMs < scheduledOffsetMs
      || startedOffsetMs - scheduledOffsetMs > WINDOW_EVIDENCE_MAX_START_DRIFT_MS
      || !Number.isFinite(completedOffsetMs)
      || completedOffsetMs < startedOffsetMs
    ) {
      throw new Error("窗口证据未按每秒 5 帧的连续节拍完成采集。 ");
    }
  }
  return frames;
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

/// 无论帧来自 CoreGraphics 还是 Flutter render tree，都统一校验 PNG、尺寸、文件大小与 SHA-256。
export function inspectMacosScreenshotFile({ outputPath, captureMode = MACOS_WINDOW_CAPTURE }) {
  const bytes = readFileSync(outputPath);
  const dimensions = parsePngDimensions(bytes);
  const sizeBytes = statSync(outputPath).size;
  if (sizeBytes <= 0) {
    throw new Error("macOS 窗口截图为空。 ");
  }
  return {
    captureMode,
    filename: basename(outputPath),
    ...dimensions,
    path: outputPath,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    size_bytes: sizeBytes,
  };
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
  return inspectMacosScreenshotFile({ outputPath });
}

/// 在稳定的本地 fixture 场景内按固定帧率抓取窗口，避免把视觉证据绑定到单一测试回调时刻。
/// v0.8.6：主屏级回退捕获（`screencapture -m`）。窗口级 `-l <windowId>` 在
/// 部分 Space/Stage Manager 组合下会失败，即使屏幕录制权限已授予；回退到
/// 主屏帧仍是真实屏幕证据，capture_mode 标注 macos-screen 以便审计区分。
export async function captureMacosScreenScreenshot({
  outputPath,
  captureBinary = "screencapture",
}) {
  mkdirSync(dirname(outputPath), { recursive: true });
  const result = await execFileResult(
    captureBinary,
    ["-x", "-m", "-t", "png", outputPath],
    { timeout: 15_000, windowsHide: true, maxBuffer: 32_000 },
  );
  if (result.code !== 0) {
    throw new Error("macOS screencapture 主屏截图失败。");
  }
  return inspectMacosScreenshotFile({
    outputPath,
    captureMode: "macos-screen",
  });
}

/// 窗口捕获优先、主屏回退的帧序列捕获器（v0.8.6）：逐帧回退，单帧失败不
/// 影响其余帧；全部失败时抛出原始窗口错误，保持既有失败语义。
export async function captureMacosWindowOrScreenFrameSeries(options) {
  const { windowId } = options;
  const withFallback = async (frameOptions) => {
    try {
      return await captureMacosWindowScreenshot(frameOptions);
    } catch (windowError) {
      if (!(windowId > 0)) throw windowError;
      return captureMacosScreenScreenshot(frameOptions);
    }
  };
  return captureMacosWindowFrameSeries({ ...options, capture: withFallback });
}

export async function captureMacosWindowFrameSeries({
  windowId,
  outputDirectory,
  scenarioId,
  fps = WINDOW_EVIDENCE_FPS,
  frameCount = WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  capture = captureMacosWindowScreenshot,
  waitForNextFrame = wait,
  now = Date.now,
}) {
  if (!Number.isInteger(fps) || fps <= 0) {
    throw new Error("截图帧率必须是正整数。 ");
  }
  if (!Number.isInteger(frameCount) || frameCount <= 0) {
    throw new Error("截图候选帧数量必须为正整数。 ");
  }
  if (typeof scenarioId !== "string" || scenarioId.trim().length === 0) {
    throw new Error("截图场景标识无效。 ");
  }
  const frameIntervalMs = Math.round(1_000 / fps);
  const startedAt = now();
  const frames = [];
  for (let index = 0; index < frameCount; index += 1) {
    const targetElapsedMs = index * frameIntervalMs;
    const remainingMs = targetElapsedMs - (now() - startedAt);
    if (remainingMs > 0) await waitForNextFrame(remainingMs);
    const captureStartedOffsetMs = now() - startedAt;
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
      scheduledOffsetMs: targetElapsedMs,
      captureStartedOffsetMs,
      capturedOffsetMs: now() - startedAt,
    });
  }
  return validateStrictWindowFrameSeries({ frames, fps, expectedFrameCount: frameCount });
}

/// 候选帧全部通过 5fps 校验后，保留末尾连续 100 帧作为可审计最终截图。
/// 选择连续片段可保持每一秒 5 帧；不以单帧或稀疏抽样冒充连续窗口证据。
export function selectStrictWindowEvidenceFrames({
  frames,
  selectedFrameCount = WINDOW_EVIDENCE_SELECTED_FRAME_COUNT,
}) {
  validateStrictWindowFrameSeries({
    frames,
    minimumFrameCount: WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  });
  if (!Number.isInteger(selectedFrameCount) || selectedFrameCount <= 0 || selectedFrameCount > frames.length) {
    throw new Error("窗口证据筛选数量无效。 ");
  }
  const selected = frames.slice(-selectedFrameCount);
  const baseScheduledOffsetMs = selected[0].scheduledOffsetMs;
  return validateStrictWindowFrameSeries({
    frames: selected.map((frame, index) => ({
      ...frame,
      sourceFrameIndex: frame.frameIndex,
      frameIndex: index + 1,
      scheduledOffsetMs: index * WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
      captureStartedOffsetMs: frame.captureStartedOffsetMs - baseScheduledOffsetMs,
      capturedOffsetMs: frame.capturedOffsetMs - baseScheduledOffsetMs,
    })),
    expectedFrameCount: selectedFrameCount,
  });
}

/// 候选目录或 Flutter sandbox 中的原始帧不作为最终 artifact；只复制筛选后的连续证据。
export function materializeStrictWindowEvidenceFrames({ frames, outputDirectory }) {
  mkdirSync(outputDirectory, { recursive: true });
  return frames.map((frame, index) => {
    const outputPath = join(
      outputDirectory,
      `frame-${String(index + 1).padStart(4, "0")}.png`,
    );
    copyFileSync(frame.path, outputPath);
    return {
      ...frame,
      ...inspectMacosScreenshotFile({
        outputPath,
        captureMode: frame.captureMode ?? MACOS_WINDOW_CAPTURE,
      }),
    };
  });
}

/// Screen Recording 被系统拒绝时，等待已观测的可见 Flutter 窗口主动写出的 RepaintBoundary 帧。
/// 该 fallback 只接受 runner 预先声明的目录、稳定文件名和完整帧数，不能用半成品或桌面截图通过 gate。
export async function waitForFlutterRenderFrameSeries({
  outputDirectory,
  sourceDirectory = outputDirectory,
  scenarioId,
  frameCount = WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  fps = WINDOW_EVIDENCE_FPS,
  timeoutMs = 15_000,
  pollIntervalMs = 50,
  copyFrames = true,
  waitForNextPoll = wait,
  now = Date.now,
}) {
  if (typeof outputDirectory !== "string" || outputDirectory.length === 0) {
    throw new Error("Flutter 渲染帧目录无效。 ");
  }
  if (typeof sourceDirectory !== "string" || sourceDirectory.length === 0) {
    throw new Error("Flutter sandbox 渲染帧目录无效。 ");
  }
  if (typeof scenarioId !== "string" || scenarioId.trim().length === 0) {
    throw new Error("截图场景标识无效。 ");
  }
  if (!Number.isInteger(frameCount) || frameCount <= 0) {
    throw new Error("Flutter 渲染帧数量必须是正整数。 ");
  }
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isFinite(pollIntervalMs) || pollIntervalMs <= 0) {
    throw new Error("Flutter 渲染帧等待参数无效。 ");
  }

  const startedAt = now();
  let lastError = null;
  while (now() - startedAt <= timeoutMs) {
    try {
      const timingPath = join(sourceDirectory, "frame-timing.json");
      if (!existsSync(timingPath)) {
        throw new Error("Flutter 渲染帧时间表尚未写完。 ");
      }
      const timing = JSON.parse(readFileSync(timingPath, "utf-8"));
      if (
        timing?.frame_rate_fps !== fps
        || timing?.frame_count !== frameCount
        || timing?.frame_interval_ms !== WINDOW_EVIDENCE_FRAME_INTERVAL_MS
        || !Array.isArray(timing.frames)
      ) {
        throw new Error("Flutter 渲染帧时间表不符合严格 5fps 契约。 ");
      }
      const timingsByIndex = new Map(
        timing.frames.map((frame) => [frame?.frame_index, frame]),
      );
      const frames = [];
      for (let index = 0; index < frameCount; index += 1) {
        const filename = `frame-${String(index + 1).padStart(4, "0")}.png`;
        const sourcePath = join(
          sourceDirectory,
          filename,
        );
        const outputPath = join(
          outputDirectory,
          filename,
        );
        if (!existsSync(sourcePath)) {
          throw new Error("Flutter 渲染帧尚未写完。 ");
        }
        const sourceArtifact = inspectMacosScreenshotFile({
          outputPath: sourcePath,
          captureMode: FLUTTER_RENDER_BOUNDARY_FALLBACK,
        });
        let artifact = sourceArtifact;
        // App Sandbox 内的临时文件不是可交付证据；只在完整校验后复制到本轮 e2e 目录。
        if (copyFrames && sourcePath !== outputPath) {
          mkdirSync(outputDirectory, { recursive: true });
          copyFileSync(sourcePath, outputPath);
          artifact = inspectMacosScreenshotFile({
            outputPath,
            captureMode: FLUTTER_RENDER_BOUNDARY_FALLBACK,
          });
          if (artifact.sha256 !== sourceArtifact.sha256) {
            throw new Error("Flutter 渲染帧复制校验失败。 ");
          }
        }
        const frameTiming = timingsByIndex.get(index + 1);
        frames.push({
          ...artifact,
          scenarioId,
          frameIndex: index + 1,
          scheduledOffsetMs: frameTiming?.scheduled_offset_ms,
          captureStartedOffsetMs: frameTiming?.capture_started_offset_ms,
          capturedOffsetMs: frameTiming?.capture_completed_offset_ms,
        });
      }
      return validateStrictWindowFrameSeries({
        frames,
        fps,
        expectedFrameCount: frameCount,
      });
    } catch (error) {
      lastError = error;
      await waitForNextPoll(pollIntervalMs);
    }
  }
  const detail = lastError instanceof Error ? lastError.message : "未知写帧错误。";
  throw new Error(`Flutter 渲染帧未在限定时间内完成：${detail}`);
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
  candidateFrameCount = null,
  selectedFrameCount = null,
  candidateCollectionMode = null,
  collectionDurationLimited = false,
  strictFrameRate = false,
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
    if (strictFrameRate) {
      validateStrictWindowFrameSeries({
        frames,
        fps: frameRateFps,
        expectedFrameCount: selectedFrameCount,
      });
    }
    const selectedFrame = frames.at(-1);
    return {
      scenario_id: scenarioId,
      frame_count: frames.length,
      frame_rate_fps: frameRateFps,
      candidate_frame_count: candidateFrameCount,
      selected_frame_count: selectedFrameCount,
      candidate_collection_mode: candidateCollectionMode,
      collection_duration_limited: collectionDurationLimited,
      frame_interval_ms: strictFrameRate ? WINDOW_EVIDENCE_FRAME_INTERVAL_MS : null,
      strict_frame_rate: strictFrameRate,
      selected_frame: selectedFrame.filename,
      selected_frame_index: selectedFrame.frameIndex ?? frames.length,
      frames: frames.map((artifact) => ({
        capture_mode: artifact.captureMode ?? MACOS_WINDOW_CAPTURE,
        filename: artifact.filename,
        frame_index: artifact.frameIndex ?? null,
        source_frame_index: artifact.sourceFrameIndex ?? artifact.frameIndex ?? null,
        scheduled_offset_ms: artifact.scheduledOffsetMs ?? null,
        capture_started_offset_ms: artifact.captureStartedOffsetMs ?? null,
        captured_offset_ms: artifact.capturedOffsetMs ?? null,
        width: artifact.width,
        height: artifact.height,
        size_bytes: artifact.size_bytes,
        sha256: artifact.sha256,
      })),
    };
  });
  const captureModes = [
    ...new Set(
      artifacts.map((artifact) => artifact.captureMode ?? MACOS_WINDOW_CAPTURE),
    ),
  ];
  return {
    schema_version: 3,
    timestamp,
    suite: "mobile-macos-local-gate",
    capture_mode: captureModes.length === 1 ? captureModes[0] : "mixed",
    capture_modes: captureModes,
    fixture_data: true,
    declared_scenarios: declaredScenarioIds,
    frame_rate_fps: frameRateFps,
    candidate_frame_count: candidateFrameCount,
    selected_frame_count: selectedFrameCount,
    candidate_collection_mode: candidateCollectionMode,
    collection_duration_limited: collectionDurationLimited,
    frame_interval_ms: strictFrameRate ? WINDOW_EVIDENCE_FRAME_INTERVAL_MS : null,
    strict_frame_rate: strictFrameRate,
    captured_scenarios: frameSets.map((frameSet) => frameSet.scenario_id),
    target_mobile_content_size: targetMobileContentSize,
    observed_window_frame: windowFrame,
    observed_window_mode: windowMode,
    screenshots: frameSets.map((frameSet) => {
      const selectedFrame = frameSet.frames.at(-1);
      return {
        capture_mode: selectedFrame.capture_mode ?? MACOS_WINDOW_CAPTURE,
        scenario_id: frameSet.scenario_id,
        filename: frameSet.selected_frame,
        frame_index: frameSet.selected_frame_index,
        source_frame_index: selectedFrame.sourceFrameIndex ?? selectedFrame.frameIndex ?? null,
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
