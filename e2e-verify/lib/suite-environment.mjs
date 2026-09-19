import { startRelay } from "./relay.mjs";
import { startWeb, startAdmin } from "./web.mjs";
import { createFixtureAccountFactory } from "./fixture-account.mjs";

// 普通 UI fixture 不探测宿主机 Provider；需要真实能力探测的套件必须显式覆盖。
export const fixtureProviderEnv = {
  AGENT_SESSIONS_DSH_BIN: "",
  AGENT_SESSIONS_CLAUDE_BIN: "",
  AGENT_SESSIONS_CODEX_BIN: "",
  AGENT_SESSIONS_OPENCODE_URL: "",
  AGENT_SESSIONS_OPENCLAW_URL: "",
};

export async function openSuiteEnvironment(suite, binary, services = { startRelay, startWeb, startAdmin }) {
  const owned = [];
  async function stop() {
    const failures = [];
    for (const service of [...owned].reverse()) {
      try { await service.stop(); } catch (error) { failures.push(error); }
    }
    if (failures.length) throw new AggregateError(failures, "测试服务回收失败");
  }
  try {
    const relay = await services.startRelay({ binary, env: { ...fixtureProviderEnv, ...suite.relayEnv } });
    owned.push(relay);
    const web = await services.startWeb({ relayBase: relay.base });
    owned.push(web);
    const admin = await services.startAdmin({ relayBase: relay.base });
    owned.push(admin);
    return {
      relay, web, admin,
      fixtureAccount: createFixtureAccountFactory(relay.base),
      logs: () => ({ relay: relay.logs?.() || "", web: web.logs?.() || "", admin: admin.logs?.() || "" }),
      stop,
    };
  } catch (error) {
    await stop();
    throw error;
  }
}
