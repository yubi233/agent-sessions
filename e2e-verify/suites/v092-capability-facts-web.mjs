// V092-03 / V092-04（P3 可见验收）：执行侧 Provider 能力事实源的 headed Chrome 验收。
//
// 断言的用户可见行为：DSH 的可用性与模型目录不由 Relay 进程"自己拍板"，而是
// 由**执行该会话的机器**（Daemon/Terminal）上报；能力页必须如实展示"谁在声明
// 可用"，让云端（执行侧上报）与本机（Relay 自探测）两种来源在页面上可区分。
//
// 旅程：登录 → 能力页（基线）→ 注入 fixture Terminal 并上报 dsh 可用事实 →
//       刷新能力页（Dsh 可用 + 来源"执行侧上报" + 模型目录所在 provider 行）→
//       Terminal 上报不可用 → 刷新（回到不可用 + 原因可见）→ 非法事实被拒绝。
//
// 口径：real_browser=true（headless=false，系统 Chrome）、fixture_data=true、
// local_test=true、real_model=false、real_upstream=false。不读取真实 DSH 根、
// 不调用模型、不消耗 token。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const v092CapabilityFactsWeb = {
  id: "v092-capability-facts-web",
  title: "V092 执行侧能力事实源 headed 验收",
  planId: "V092",
  // 复现云端形态：Relay 进程内没有可用的 DSH 桥（等价 scratch 单二进制镜像里
  // 没有 node / 没有 DSH 检出）。本机开发环境默认存在真实桥，若不打断，Relay
  // 会按"自己能跑就以自己为准"采用本进程事实，本场景就测不到执行侧事实源链路。
  relayEnv: { AGENT_SESSIONS_DSH_BIN: "/nonexistent/v092-relay-bridge.js" },
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    try {
      const account = await fixtureAccount();
      const fixture = await seedFixtureTerminal(relay.base, account);
      const browser = await launchHeaded({ headless });
      let page;
      try {
        page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
        await page.goto(web.base, { waitUntil: "networkidle" });
        await page.getByTestId("relay-ready").waitFor({ state: "visible" });
        await page.getByTestId("login-email").fill(account.email);
        await page.getByTestId("login-password").fill(account.password);
        await page.getByTestId("login-submit").click();
        await page.getByTestId("auth-ok").waitFor({ state: "visible" });

        // ---- 基线：尚未上报执行侧事实，能力页必须 fail-closed ----
        await openCapabilities(page);
        const baselineAvailable = await page
          .getByTestId("matrix-available-dsh")
          .innerText();
        notes.push("基线 dsh 可用性: " + baselineAvailable.trim());
        if (!baselineAvailable.includes("不可用")) {
          errors.push("上报执行侧事实前 dsh 必须为不可用，实际: " + baselineAvailable);
        }
        // 事实来源标签必须如实标注（没有可用事实 → 无可用事实）。
        const baselineSource = await textOf(page, "matrix-facts-source-dsh");
        if (baselineSource === null) {
          errors.push("能力页缺少事实来源标签矩阵 matrix-facts-source-dsh");
        } else if (!baselineSource.includes("无可用事实")) {
          errors.push("未上报时来源应为「无可用事实」，实际: " + baselineSource);
        }

        // ---- 上报执行侧可用事实（等价云端 Daemon 的 hello）----
        await fixture.reportFacts(availableFacts());

        await reloadCapabilities(page);
        const adoptedAvailable = await page
          .getByTestId("matrix-available-dsh")
          .innerText();
        if (!adoptedAvailable.includes("可用")) {
          errors.push("上报执行侧事实后 dsh 必须可用，实际: " + adoptedAvailable);
        }
        const version = await page.getByTestId("matrix-version-dsh").innerText();
        if (!version.includes("0.0.1")) {
          errors.push("版本必须来自执行侧上报，实际: " + version);
        }
        const adoptedSource = await textOf(page, "matrix-facts-source-dsh");
        if (adoptedSource === null || !adoptedSource.includes("执行侧上报")) {
          errors.push("可用性必须标注来源为「执行侧上报」，实际: " + adoptedSource);
        }
        // data 属性用于精确断言 wire 值（文案可能本地化）。
        const sourceAttr = await page
          .getByTestId("matrix-facts-source-dsh")
          .getAttribute("data-facts-source");
        if (sourceAttr !== "terminal") {
          errors.push("facts_source wire 值应为 terminal，实际: " + sourceAttr);
        }
        // 版本对应的能力行必须恢复为可用（发送入口不被误禁用）。
        const startStatus = await page
          .getByTestId("matrix-cap-dsh-start")
          .innerText();
        if (!startStatus.includes("原生支持")) {
          errors.push("执行侧可用时 start 必须原生支持，实际: " + startStatus);
        }

        // ---- 执行侧退化：随心跳上报不可用事实与原因 ----
        await fixture.reportFacts(unavailableFacts());
        await reloadCapabilities(page);
        const degraded = await page
          .getByTestId("matrix-available-dsh")
          .innerText();
        if (!degraded.includes("不可用")) {
          errors.push("执行侧声明不可用后必须回到不可用，实际: " + degraded);
        }
        const degradedSource = await textOf(page, "matrix-facts-source-dsh");
        if (degradedSource === null || !degradedSource.includes("无可用事实")) {
          errors.push("两侧都不可用时来源应为「无可用事实」，实际: " + degradedSource);
        }
        // 失败原因必须可追溯（title 属性承载 Relay 转达的执行侧原因）。
        const startTitle = await page
          .getByTestId("matrix-cap-dsh-start")
          .getAttribute("title");
        if (!startTitle || !startTitle.includes("node")) {
          errors.push("不可用原因必须转达执行侧事实，实际 title: " + startTitle);
        }

        await page.close();
      } catch (error) {
        // 失败时把当前 URL 与可见 testid 摘要写进错误串，便于定位（脱敏：不采集输入内容）。
        if (page) {
          try {
            const hash = await page.evaluate(() => window.location.hash);
            const testIds = await page.evaluate(() =>
              Array.from(document.querySelectorAll("[data-testid]"))
                .map((el) => el.getAttribute("data-testid"))
                .slice(0, 20)
                .join(","),
            );
            errors.push("诊断: hash=" + hash + " testids=" + testIds);
          } catch {
            /* 诊断失败不影响结论 */
          }
        }
        throw error;
      } finally {
        await browser.close();
      }

      // ---- 边界：非法事实被拒绝（fail-closed，不静默截断）----
      const rejected = await fixture.reportFactsExpectFailure([
        { kind: "dsh", available: true, version: "0.0.1", default_model: "ghost" },
      ]);
      if (!rejected) {
        errors.push("默认模型不在目录内的非法事实必须被拒绝");
      }
    } catch (error) {
      errors.push("浏览器旅程异常: " + safeError(error));
    }

    return report({
      suite: "v092-capability-facts-web",
      planId: "V092",
      status: errors.length === 0 ? "passed" : "failed",
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite v092-capability-facts-web",
      test_ids: ["V092-03", "V092-04"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk:
        "基于隔离 Relay 与受控 fixture Terminal；不读取真实 DSH 根、不调用模型。" +
        "云端真实拓扑（执行侧 Daemon 在用户机器）的复测仍以 V092-09/10 真机为准。",
      notes,
      errors,
    });
  },
};

// openCapabilities 导航到能力页并等待矩阵渲染。
async function openCapabilities(page) {
  await page.locator('a[href="#/capabilities"]').first().click();
  await page.waitForFunction(
    () => window.location.hash.startsWith("#/capabilities"),
    null,
    { timeout: 15000 },
  );
  await page.getByTestId("capability-matrix-view").waitFor({ state: "visible" });
  await page.getByTestId("capability-matrix").waitFor({ state: "visible" });
}

// reloadCapabilities 重新拉取能力矩阵。
// 矩阵只在能力视图挂载时拉取一次，页内没有"重新探测"入口（retry 按钮只在
// 加载失败态出现），且会话令牌不跨整页刷新持久化。因此用应用内路由往返
// （首页 → 能力页）触发组件重新挂载，这既是真实用户路径，也避免了整页刷新。
async function reloadCapabilities(page) {
  // 先切到会话页（已由其它 suite 验证过的导航路径），确认能力视图被卸载，
  // 再回到能力页触发重新挂载与重新拉取。用 hash 断言导航确实发生，
  // 避免在错误的页面上继续等待而得到难以诊断的超时。
  await page.locator('a[href="#/sessions"]').first().click();
  await page.waitForFunction(() => window.location.hash.startsWith("#/sessions"), null, {
    timeout: 15000,
  });
  await openCapabilities(page);
}

// textOf 读取 testid 的可见文本；不存在时返回 null。
async function textOf(page, testId) {
  const locator = page.getByTestId(testId);
  if ((await locator.count()) === 0) return null;
  return (await locator.first().innerText()).trim();
}

// availableFacts 构造"执行侧可用"的 dsh 事实（含模型目录）。
function availableFacts() {
  return [
    {
      kind: "dsh",
      available: true,
      version: "0.0.1",
      observed_at_unix_ms: Date.now(),
      default_model: "deepseek-v4",
      model_groups: [
        {
          id: "openai",
          name: "OpenAI",
          models: [
            {
              provider: "openai",
              value: "deepseek-v4",
              id: "deepseek-v4",
              name: "DeepSeek V4",
            },
          ],
        },
      ],
    },
  ];
}

// unavailableFacts 构造"执行侧不可用"的 dsh 事实（带可诊断原因）。
function unavailableFacts() {
  return [
    {
      kind: "dsh",
      available: false,
      observed_at_unix_ms: Date.now(),
      reason: "执行侧未找到 node 运行时",
    },
  ];
}

// seedFixtureTerminal 配对 fixture Terminal 并返回可重复上报事实的句柄。
async function seedFixtureTerminal(relayBase, account) {
  const ownerHeaders = {
    "Content-Type": "application/json",
    Authorization: "Bearer " + account.accessToken,
  };
  async function req(path, opts) {
    const method = (opts && opts.method) || "GET";
    const headers = (opts && opts.headers) || ownerHeaders;
    const body = opts && opts.body;
    const response = await fetch(relayBase + path, {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(
        method + " " + path + " failed: " + response.status + " " + text.slice(0, 200),
      );
    }
    return text ? JSON.parse(text) : {};
  }

  const pairing = await req("/v1/pairing/requests", {
    method: "POST",
    body: {
      role: "terminal",
      display_name: "v092-facts-terminal",
      platform: "test",
      identity_public_key: "v092-facts-identity",
      encryption_public_key: "v092-facts-encryption",
    },
  });
  const approved = await req(
    "/v1/pairing/requests/" + encodeURIComponent(pairing.id) + "/approve",
    { method: "POST" },
  );
  const terminalToken = approved.tokens && approved.tokens.access_token;
  if (!terminalToken) throw new Error("fixture terminal token missing");
  const terminalHeaders = {
    "Content-Type": "application/json",
    Authorization: "Bearer " + terminalToken,
  };

  // hello 携带执行侧事实（与生产 Daemon 同形状）。
  await req("/v1/daemon/hello", {
    method: "POST",
    headers: terminalHeaders,
    body: {
      protocol_version: 1,
      daemon_version: "v092-fixture",
      hostname: "v092-facts",
      platform: "test",
      capabilities: ["start", "send", "resume"],
      provider_facts: [],
    },
  });

  async function post(path, body) {
    return req(path, { method: "POST", headers: terminalHeaders, body });
  }

  return {
    // 心跳随行刷新事实（生产 Daemon 的心跳周期行为）。
    async reportFacts(facts) {
      await post("/v1/daemon/heartbeat", {
        protocol_version: 1,
        provider_facts: facts,
      });
    },
    // 期望被拒绝时返回 true（fail-closed 边界）。
    async reportFactsExpectFailure(facts) {
      const response = await fetch(relayBase + "/v1/daemon/heartbeat", {
        method: "POST",
        headers: terminalHeaders,
        body: JSON.stringify({ protocol_version: 1, provider_facts: facts }),
      });
      return !response.ok;
    },
  };
}

function safeError(error) {
  return String((error && error.message) || error).slice(0, 300);
}
