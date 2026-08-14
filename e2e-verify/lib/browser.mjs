// 统一管理 headed 真实浏览器启动。
// 依据 web-iterative-workflow：本地验收默认 headed（headless 只用于 CI/快速回归），
// 使用系统 Chrome，避免下载浏览器二进制，同时满足“真实启动浏览器、非 headless”的要求。
import { chromium } from "playwright";

// 系统 Chrome 可执行路径；找不到时回退到 Playwright 自带 Chromium。
const SYSTEM_CHROMES = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
];

// launchHeaded 启动一个可见的真实浏览器窗口。
// options.headless 显式传入 true 时才允许无界面（仅 CI/快速回归）。
export async function launchHeaded(options = {}) {
  const headless = options.headless === true;
  const launchOptions = {
    headless,
    slowMo: headless ? 0 : 300, // 可见模式下放慢操作，便于人工观察
  };

  if (headless) {
    return chromium.launch(launchOptions);
  }

  // 优先使用系统 Chrome，保证是真实浏览器且非 headless。
  for (const path of SYSTEM_CHROMES) {
    try {
      const fs = await import("node:fs");
      if (fs.existsSync(path)) {
        return chromium.launch({ ...launchOptions, executablePath: path });
      }
    } catch {
      /* 继续尝试下一个候选 */
    }
  }
  // 回退到 Playwright 自带的 Chromium（仍需先执行 pnpm exec playwright install chromium）。
  return chromium.launch(launchOptions);
}

// 当前浏览器口径：是否真实可见浏览器（供报告字段复用）。
export function browserLabel(headless = false) {
  return headless ? "chromium-headless" : "system-chrome";
}
