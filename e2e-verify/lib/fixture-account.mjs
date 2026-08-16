// headed 浏览器 suite 共用单租户 fixture owner；避免每个场景各自注册而违反首账号 bootstrap 门禁。
// owner 写 token 只用于套件预置数据（建会话/终端），绝不写入浏览器或报告；
// 浏览器仍走各自可见的密码登录流程。
export function createFixtureAccountFactory(relayBase) {
  let account = null;

  return async function fixtureAccount() {
    if (account) return account;
    const email = `browser-${Date.now()}@test.dev`;
    const password = "e2e-pass-123";
    const response = await fetch(`${relayBase}/v1/auth/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    if (!response.ok) {
      throw new Error(`fixture owner registration failed: ${response.status}`);
    }
    const data = await response.json();
    // 令牌只留在 Node 预置侧（脱敏，不进入报告与浏览器内存）。
    account = {
      email,
      password,
      accessToken: data.access_token,
      deviceId: data.device_id,
    };
    return account;
  };
}
