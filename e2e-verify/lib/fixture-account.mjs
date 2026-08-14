// headed 浏览器 suite 共用单租户 fixture owner；避免每个场景各自注册而违反首账号 bootstrap 门禁。
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
    // 令牌不进入浏览器报告；Web/Admin 仍须走各自可见的密码登录流程。
    account = { email, password };
    return account;
  };
}
