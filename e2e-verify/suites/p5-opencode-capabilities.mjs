// P5 OpenCode 能力矩阵 headed 回归（测试 ID：E2E-OPENCODE-01）。
// 用真实 opencode serve + 隔离 Relay 验证：Web 能力矩阵页面展示的 opencode
// available/version/start/resume/abort 与 Detect 真实探测结果一致，且页面无任何写入口。
// 口径见 docs/zh/项目文档.md「8. 统一能力模型」与「Vue Web App」章节；
// 探测失败时如实呈现 fail-closed 状态，不把 fixture 写成真实探测通过。
import { createServer } from "node:net";
import { launchHeaded, browserLabel } from "../lib/browser.mjs";
import { startOpenCodeServe } from "../lib/opencode.mjs";
import { startRelay } from "../lib/relay.mjs";
import { startWeb } from "../lib/web.mjs";
import { createFixtureAccountFactory } from "../lib/fixture-account.mjs";

// 能力矩阵页必须展示的 opencode 能力子集（与 Detect 升级规则对齐）。
const NATIVE_CAPABILITIES = ["start", "resume", "abort", "usage"];
// 页面绝对不允许出现的写入口 testid（无发送、无审批、无撤销、无派发）。
const WRITE_ENTRY_TESTIDS = [
  "session-send",
  "approve-pairing",
  "revoke-device",
  "delegation-approve",
  "command-submit",
];

// freePort 取一个当前空闲的本地端口（仅用于隔离 Relay，serve 用 --port 0 自选）。
function freePort() {
  return new Promise((resolvePort, rejectPort) => {
    const server = createServer();
    server.once("error", rejectPort);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolvePort(port));
    });
  });
}

// startWebWithFallback 依次尝试 CORS 白名单内的开发端口，找到第一个可用的。
async function startWebWithFallback(relayBase) {
  const candidates = [5173, 5174];
  let lastError = null;
  for (const port of candidates) {
    try {
      return await startWeb({ port, relayBase });
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error("无可用 Web 开发端口");
}

// loginAndFetchCapabilities 在 Node 侧登录并读取 /v1/capabilities，作为浏览器断言的 API 对照。
async function loginAndFetchCapabilities(base, email, password) {
  const loginResponse = await fetch(`${base}/v1/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (!loginResponse.ok) {
    throw new Error(`fixture login failed: ${loginResponse.status}`);
  }
  const { access_token: accessToken } = await loginResponse.json();
  const capsResponse = await fetch(`${base}/v1/capabilities`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!capsResponse.ok) {
    throw new Error(`capabilities fetch failed: ${capsResponse.status}`);
  }
  const body = await capsResponse.json();
  return body.providers;
}

// opencodeProvider 从能力矩阵 providers 中取 opencode 项。
function opencodeProvider(providers) {
  return (providers || []).find((provider) => provider.kind === "opencode");
}

// capabilityStatus 取某 provider 下指定能力的状态。
function capabilityStatus(provider, name) {
  return (provider.capabilities || []).find((capability) => capability.name === name)?.status;
}

// 缺少真实服务凭据时必须保留 fail-closed 验证，但不能把外部授权缺失误报为产品失败。
export function classifyOpenCodeCapabilityFailure(error) {
  const message = error instanceof Error ? error.message : String(error);
  if (/OPENCODE_SERVER_PASSWORD 未配置/.test(message)) {
    return {
      status: "blocked",
      failureClass: "credential_or_quota_blocker",
      remainingRisk: "缺少 OPENCODE_SERVER_PASSWORD，无法启动带鉴权的真实 opencode serve；native 能力矩阵保持 blocked。",
    };
  }
  return {
    status: "failed",
    failureClass: "environment_or_startup_failure",
    remainingRisk: "真实 opencode serve 未能进入健康状态，无法验收 native 矩阵。",
  };
}

// 专用 Relay/Web 只有同时可用时才能配对使用；否则回退到 runner 的共享实例，
// 并复用其唯一 fixture owner，避免再次注册触发 owner bootstrap 边界。
export function selectFailClosedFallback({ suiteRelay, suiteWeb, ctx }) {
  if (suiteRelay && suiteWeb) {
    return {
      accountFactory: createFixtureAccountFactory(suiteRelay.base),
      relay: suiteRelay,
      web: suiteWeb,
    };
  }
  return {
    accountFactory: ctx.fixtureAccount,
    relay: ctx.relay,
    web: ctx.web,
  };
}

export const p5OpencodeCapabilities = {
  id: "p5-opencode-capabilities",
  title: "P5 OpenCode 能力矩阵 headed 回归",
  planId: "ADAPTER-OPENCODE",
  async run(ctx) {
    const { report, headless = false } = ctx;
    const label = browserLabel(headless);
    const browser = await launchHeaded({ headless });
    let serve = null;
    let suiteRelay = null;
    let suiteWeb = null;

    try {
      // 1. 启动真实 opencode serve（随机端口，健康等待最长 60s）。
      serve = await startOpenCodeServe();

      // 2. 启动专用隔离 Relay，让 opencode adapter 探测到真实 serve。
      const relayPort = await freePort();
      suiteRelay = await startRelay({
        port: relayPort,
        env: { AGENT_SESSIONS_OPENCODE_URL: serve.base },
      });

      // 3. 启动专用 Web（5173/5174 都在 Relay CORS 白名单内），指向该 Relay。
      //    本机开发端口可能被其他服务占用，逐候选尝试，全部失败才视为启动失败。
      suiteWeb = await startWebWithFallback(suiteRelay.base);
      const fixtureAccount = createFixtureAccountFactory(suiteRelay.base);
      const account = await fixtureAccount();

      // 4. API 对照：Relay 返回的能力矩阵应直接反映 opencode Detect 的真实结果。
      const apiProviders = await loginAndFetchCapabilities(
        suiteRelay.base,
        account.email,
        account.password,
      );
      const apiOpencode = opencodeProvider(apiProviders);
      if (!apiOpencode) {
        return report({
          suite: "p5-opencode-capabilities",
          planId: "ADAPTER-OPENCODE",
          status: "failed",
          real_browser: !headless,
          headless,
          browser: label,
          command: `node e2e-verify/run.mjs --suite p5-opencode-capabilities`,
          relay_base: suiteRelay.base,
          artifacts: [],
          failure_class: "product_defect",
          remaining_risk: "能力矩阵缺少 opencode provider，Detect 结果未进入 /v1/capabilities",
        });
      }

      // 5. headed 浏览器：登录后打开能力矩阵，逐项断言与 API（即 Detect）一致。
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await page.goto(suiteWeb.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });
      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
      await page.getByTestId("capabilities-link").click();
      await page.getByTestId("capability-matrix").waitFor({ state: "visible" });

      const versionText = (await page.getByTestId("matrix-version-opencode").textContent())?.trim() || "";
      const availableText = (await page.getByTestId("matrix-available-opencode").textContent())?.trim() || "";
      const pageStatuses = {};
      for (const name of NATIVE_CAPABILITIES) {
        pageStatuses[name] = await page
          .getByTestId(`matrix-cap-opencode-${name}`)
          .getAttribute("data-status");
      }

      // 页面仍无写入口：无发送按钮、无审批按钮、无撤销/派发按钮。
      let writeEntryFound = false;
      for (const testId of WRITE_ENTRY_TESTIDS) {
        if ((await page.getByTestId(testId).count()) > 0) writeEntryFound = true;
      }

      // 断言：页面渲染与 API（真实 Detect 结果）完全一致。
      const apiStatuses = {};
      for (const name of NATIVE_CAPABILITIES) {
        apiStatuses[name] = capabilityStatus(apiOpencode, name);
      }
      const pageMatchesApi =
        versionText === apiOpencode.version &&
        availableText === (apiOpencode.available ? "可用" : "不可用") &&
        NATIVE_CAPABILITIES.every((name) => pageStatuses[name] === apiStatuses[name]);

      const expectedHealthy =
        apiOpencode.available === true &&
        apiOpencode.version !== "" &&
        NATIVE_CAPABILITIES.every((name) => apiStatuses[name] === "native");

      const passed = pageMatchesApi && expectedHealthy && !writeEntryFound;

      return report({
        suite: "p5-opencode-capabilities",
        planId: "ADAPTER-OPENCODE",
        status: passed ? "passed" : "failed",
        real_browser: !headless,
        headless,
        browser: label,
        command: `node e2e-verify/run.mjs --suite p5-opencode-capabilities`,
        relay_base: suiteRelay.base,
        artifacts: [],
        failure_class: passed ? null : "product_defect",
        remaining_risk: passed
          ? ""
          : "能力矩阵页面与 Detect 探测结果不一致，或页面出现写入口",
        opencode_observed: {
          available: apiOpencode.available,
          version: apiOpencode.version,
          page_version: versionText,
          page_available: availableText,
          api_statuses: apiStatuses,
          page_statuses: pageStatuses,
          page_matches_api: pageMatchesApi,
          write_entry_found: writeEntryFound,
        },
      });
    } catch (error) {
      // serve 未健康或基础设施失败：fallback 验证 fail-closed 状态被如实展示。
      // 专用 Relay 不可用时，用共享 Relay（未配置 OPENCODE URL）验证 fail-closed 渲染。
      process.stderr.write(`[p5-opencode-capabilities] catch: ${error instanceof Error ? error.message : String(error)}\n`);
      const outcome = classifyOpenCodeCapabilityFailure(error);
      let failClosedObserved = false;
      const fallback = selectFailClosedFallback({ suiteRelay, suiteWeb, ctx });
      const fallbackRelay = fallback.relay;
      const fallbackWeb = fallback.web;
      if (fallbackRelay && fallbackWeb) {
        try {
          const account = await fallback.accountFactory();
          const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
          await page.goto(fallbackWeb.base, { waitUntil: "networkidle" });
          await page.getByTestId("relay-ready").waitFor({ state: "visible" });
          await page.getByTestId("login-email").fill(account.email);
          await page.getByTestId("login-password").fill(account.password);
          await page.getByTestId("login-submit").click();
          await page.getByTestId("auth-ok").waitFor({ state: "visible" });
          await page.getByTestId("capabilities-link").click();
          await page.getByTestId("capability-matrix").waitFor({ state: "visible" });
          const availableText =
            (await page.getByTestId("matrix-available-opencode").textContent())?.trim() || "";
          const startStatus = await page
            .getByTestId("matrix-cap-opencode-start")
            .getAttribute("data-status");
          const versionText =
            (await page.getByTestId("matrix-version-opencode").textContent())?.trim() || "";
          // fail-closed：不可用、unsupported、无版本。
          failClosedObserved =
            availableText === "不可用" && startStatus === "unsupported" && versionText === "未探测到";
        } catch {
          failClosedObserved = false;
        }
      }
      return report({
        suite: "p5-opencode-capabilities",
        planId: "ADAPTER-OPENCODE",
        status: outcome.status,
        real_browser: !headless,
        headless,
        browser: label,
        command: `node e2e-verify/run.mjs --suite p5-opencode-capabilities`,
        relay_base: suiteRelay ? suiteRelay.base : ctx.relay.base,
        artifacts: [],
        failure_class: outcome.failureClass,
        remaining_risk: `${outcome.remainingRisk} fail_closed_rendering_verified=${failClosedObserved}`,
      });
    } finally {
      await suiteWeb?.stop();
      await suiteRelay?.stop();
      await serve?.stop();
      await browser.close();
    }
  },
};
