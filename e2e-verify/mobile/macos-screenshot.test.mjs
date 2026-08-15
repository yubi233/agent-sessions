import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildMacosScreenshotManifest,
  captureMacosWindowFrameSeries,
  FLUTTER_RENDER_BOUNDARY_FALLBACK,
  parsePngDimensions,
  waitForFlutterRenderFrameSeries,
} from "./macos-screenshot.mjs";

function pngHeader(width, height) {
  const header = Buffer.alloc(24);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(header, 0);
  header.writeUInt32BE(13, 8);
  header.write("IHDR", 12, "ascii");
  header.writeUInt32BE(width, 16);
  header.writeUInt32BE(height, 20);
  return header;
}

test("macOS 截图只接受有效 PNG 并读取实际尺寸", () => {
  assert.deepEqual(parsePngDimensions(pngHeader(480, 997)), { height: 997, width: 480 });
  assert.throws(() => parsePngDimensions(Buffer.from("not-a-png")), /有效 PNG/);
});

test("截图 manifest 只保留 fixture 元数据、哈希和窗口尺寸", () => {
  const manifest = buildMacosScreenshotManifest({
    timestamp: "2026-08-14T15-00-00-000Z",
    declaredScenarioIds: [
      "VISUAL-MOBILE-01",
      "VISUAL-MOBILE-02",
      "VISUAL-PAIR-01",
      "VISUAL-MOBILE-03",
      "VISUAL-MOBILE-04",
      "VISUAL-MOBILE-05",
      "VISUAL-MOBILE-06",
      "VISUAL-MOBILE-07",
      "VISUAL-MOBILE-08",
      "VISUAL-MOBILE-09",
      "VISUAL-MOBILE-10",
      "VISUAL-MOBILE-11",
      "VISUAL-MOBILE-12",
      "VISUAL-MOBILE-13",
      "VISUAL-MOBILE-14",
      "VISUAL-MOBILE-15",
      "VISUAL-MOBILE-16",
      "VISUAL-MOBILE-17",
    ],
    artifacts: [{
      captureMode: FLUTTER_RENDER_BOUNDARY_FALLBACK,
      filename: "visual-mobile-01-login.png",
      height: 997,
      path: "/private/tmp/ignored-from-manifest.png",
      scenarioId: "VISUAL-MOBILE-01",
      sha256: "a".repeat(64),
      size_bytes: 1024,
      width: 480,
    }],
    targetMobileContentSize: { height: 960, width: 480 },
    windowFrame: { height: 997, width: 480 },
    windowMode: "native",
  });

  assert.deepEqual(manifest.captured_scenarios, ["VISUAL-MOBILE-01"]);
  assert.equal(manifest.screenshots[0].filename, "visual-mobile-01-login.png");
  assert.equal("path" in manifest.screenshots[0], false);
  assert.equal(JSON.stringify(manifest).includes("ignored-from-manifest"), false);
  assert.equal(manifest.screenshots[0].scenario_id, "VISUAL-MOBILE-01");
  assert.equal(manifest.capture_mode, FLUTTER_RENDER_BOUNDARY_FALLBACK);
  assert.equal(manifest.screenshots[0].capture_mode, FLUTTER_RENDER_BOUNDARY_FALLBACK);
});

test("5fps 连续截图按场景写入稳定帧序列", async () => {
  const captures = [];
  const waits = [];
  let clock = 0;
  const frames = await captureMacosWindowFrameSeries({
    windowId: 41,
    outputDirectory: "/fixture/screenshots/visual-owner",
    scenarioId: "VISUAL-MOBILE-02",
    fps: 5,
    durationMs: 1_000,
    now: () => clock,
    waitForNextFrame: async (milliseconds) => {
      waits.push(milliseconds);
      clock += milliseconds;
    },
    capture: async (input) => {
    captures.push(input);
    return {
      filename: input.outputPath.split("/").at(-1),
      height: 997,
      path: input.outputPath,
      sha256: "b".repeat(64),
      size_bytes: 2048,
      width: 480,
    };
    },
  });

  assert.equal(frames.length, 5);
  assert.equal(frames.at(-1).scenarioId, "VISUAL-MOBILE-02");
  assert.equal(frames.at(-1).frameIndex, 5);
  assert.equal(captures.length, 5);
  assert.match(captures[0].outputPath, /visual-owner\/frame-0001\.png$/);
  assert.match(captures.at(-1).outputPath, /visual-owner\/frame-0005\.png$/);
  assert.deepEqual(waits, [200, 200, 200, 200]);
});

test("Flutter render boundary fallback 只接受完整的预登记 PNG 帧序列", async () => {
  const root = mkdtempSync(join(tmpdir(), "flutter-render-boundary-"));
  const sourceDirectory = join(root, "sandbox-source");
  const outputDirectory = join(root, "e2e-evidence");
  mkdirSync(sourceDirectory, { recursive: true });
  for (let index = 0; index < 5; index += 1) {
    writeFileSync(
      join(sourceDirectory, `frame-${String(index + 1).padStart(4, "0")}.png`),
      pngHeader(480, 960),
    );
  }

  const frames = await waitForFlutterRenderFrameSeries({
    outputDirectory,
    sourceDirectory,
    scenarioId: "VISUAL-MOBILE-08",
    frameCount: 5,
    timeoutMs: 100,
    pollIntervalMs: 1,
  });

  assert.equal(frames.length, 5);
  assert.equal(frames.at(-1).captureMode, FLUTTER_RENDER_BOUNDARY_FALLBACK);
  assert.equal(frames.at(-1).width, 480);
  assert.equal(frames.at(-1).height, 960);
  assert.equal(frames.every((frame) => frame.sha256.length === 64), true);
  assert.equal(existsSync(join(outputDirectory, "frame-0005.png")), true);
});
