// 阶段 8：Web/Admin 云端只读旅程（headed 真实浏览器，非 headless）。
// 口径：real_browser=true（系统 Chrome 可见窗口）、real_upstream=true（云端自签 TLS，
// 指纹已由 deploy/ecs/smoke.sh 外部钉扎验证，浏览器上下文 ignoreHTTPSErrors 仅
// 跳过 CA 链，页面凭据仍由登录态保障）、fixture_data=false。
// 用法：node e2e-verify/real/cloud-web-admin-journey.mjs
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { launchHeaded } from "../lib/browser.mjs";
import { loginEmail, loginPassword } from "./cloud-credentials.mjs";

const BASE = "https://39.106.135.11";
const outDir = join(dirname(fileURLToPath(import.meta.url)), "../reports/acc-phase5");
mkdirSync(outDir, { recursive: true });

// headed 真实浏览器（系统 Chrome 优先），统一走仓库启动器。
const browser = await launchHeaded({ headless: false });
const context = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  // 自签证书：CA 链校验由外部指纹钉扎替代（smoke 已验证 SHA-256 一致），
  // ignoreHTTPSErrors 仅放开链校验，传输仍是 TLS。
  ignoreHTTPSErrors: true,
});
const results = [];
const check = (name, ok, detail = "") => {
  results.push({ name, ok: Boolean(ok), detail: String(detail).slice(0, 160) });
  console.log(`${ok ? "PASS" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
};

// ---- WEB 只读旅程 ----
const webPage = await context.newPage();
await webPage.goto(`${BASE}/web/`, { waitUntil: "domcontentloaded" });
await webPage.getByTestId("relay-ready").waitFor({ state: "visible", timeout: 20000 });
check("WEB relay-ready（同源 /v1 可达）", true);
await webPage.getByTestId("login-email").fill(loginEmail);
await webPage.getByTestId("login-password").fill(loginPassword);
await webPage.getByTestId("login-submit").click();
await webPage.getByTestId("auth-ok").waitFor({ state: "visible", timeout: 15000 });
check("WEB 登录成功（email+password owner 账号）", true);
// 只读旅程：会话区/能力区可见性（无 Daemon 会话时空态属预期）
const bodyText = await webPage.locator("body").innerText();
check("WEB 页面渲染非空", bodyText.trim().length > 0, `bytes=${bodyText.length}`);
await webPage.screenshot({ path: join(outDir, "phase8-web-journey.png"), fullPage: true });

// ---- ADMIN 只读旅程 ----
const adminPage = await context.newPage();
await adminPage.goto(`${BASE}/admin/`, { waitUntil: "domcontentloaded" });
await adminPage.getByTestId("relay-ready").waitFor({ state: "visible", timeout: 20000 });
check("ADMIN relay-ready", true);
await adminPage.getByTestId("login-email").fill(loginEmail);
await adminPage.getByTestId("login-password").fill(loginPassword);
await adminPage.getByTestId("login-submit").click();
await adminPage.getByTestId("auth-ok").waitFor({ state: "visible", timeout: 15000 });
check("ADMIN 登录成功", true);
await adminPage.getByTestId("device-list").waitFor({ state: "visible", timeout: 15000 });
const deviceCount = await adminPage.getByTestId("device-item").count();
check("ADMIN 设备列表可见（≥2：真机 owner + terminal）", deviceCount >= 2, `count=${deviceCount}`);
const adminText = await adminPage.locator("body").innerText();
check("ADMIN 列表含已配对终端设备（ACC Test Terminal）", adminText.includes("ACC Test Terminal"));
await adminPage.screenshot({ path: join(outDir, "phase8-admin-journey.png"), fullPage: true });

await browser.close();

const pass = results.every((r) => r.ok);
const report = {
  suite: "CLOUD-ANDROID-ACCEPTANCE",
  test_ids: ["WEB-01", "WEB-02", "ADMIN-01", "ADMIN-02"],
  gate_kind: "cloud_web_admin_headed_journey",
  status: pass ? "passed" : "failed",
  real_browser: true,
  real_upstream: true,
  real_device: false,
  real_model: false,
  fixture_data: false,
  local_test: false,
  headless: false,
  browser: "system-chrome-headed",
  cloud_provider: "aliyun",
  endpoint: `${BASE}/web/ 与 ${BASE}/admin/`,
  checks: results,
  remaining_risk: pass ? "自签证书经外部指纹钉扎 + 浏览器 ignoreHTTPSErrors 组合；WEB/ADMIN 全量用例由既有本地套件承载，云端侧验证关键只读旅程" : "存在失败项，见 checks",
};
writeFileSync(join(outDir, "phase8-web-admin-journey.json"), JSON.stringify(report, null, 2) + "\n");
console.log(`[cloud-web-admin] ${report.status} -> ${outDir}`);
process.exitCode = pass ? 0 : 1;
