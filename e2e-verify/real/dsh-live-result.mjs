// 只用错误文本的形状做分类，不把原始上游文本写入报告。
// Zen 免费模型的额度耗尽可能由不同网关映射为 429 或 403；只要错误类型明确
// 是 FreeUsageLimitError/免费额度耗尽即可按约定接受，普通鉴权错误仍保持 blocked。
const zenQuotaPattern = /FreeUsageLimitError|(?:free\s*(?:model\s*)?(?:usage|quota)\s*(?:limit|exhausted|exceeded|reached|depleted))|(?:(?:usage|quota)\s*(?:limit|exhausted|exceeded|reached|depleted))|免费(?:模型)?\s*(?:额度|用量)[^\n]{0,80}(?:上限|耗尽|超限|用尽)/i;
export const dshZenTestModels = new Set([
  "deepseek-v4-flash-free",
  "mimo-v2.5-free",
  "big-pickle",
  "ling-3.0-flash-fin-free",
]);

function result(status, failureClass, passReason, quotaAccepted, diagnosticCode, remainingRisk) {
  return {
    status,
    failureClass,
    passReason,
    quotaAccepted,
    diagnosticCode,
    remainingRisk,
  };
}

export function classifyDshLiveFailure({ model, provider, message, stderr }) {
  const combined = `${message ?? ""}\n${stderr ?? ""}`;
  const isZenTestModel = provider === "opencode-zen" && dshZenTestModels.has(model);
  if (isZenTestModel && zenQuotaPattern.test(combined)) {
    return result(
      "passed",
      null,
      "zen_quota_accepted",
      true,
      "zen_quota_429",
      `已确认 DSH 接受 ${model} 并走 opencode-zen；按 v0.8 DSH 测试约定，429 FreeUsageLimitError 计为通过。该结果不证明模型回复、历史回放或恢复后 send。`,
    );
  }

  const credential = /no API key|MISSING_CREDENTIAL|INVALID_CREDENTIAL|unauthorized|forbidden|\b401\b|\b403\b/i.test(combined);
  if (credential) {
    return result(
      "blocked",
      "credential_or_quota_blocker",
      null,
      false,
      "credential_rejected",
      "真实 DSH 凭据或权限不可用；原始上游错误仅保留在本地标准错误，不写入报告。",
    );
  }

  if (/超时|timed?\s*out|timeout|ETIMEDOUT|ECONNRESET|断开连接/i.test(combined)) {
    return result(
      "failed",
      "provider_timeout",
      null,
      false,
      "provider_timeout",
      "真实 DSH 上游或桥请求超时/断开；允许在限定次数内重试，原始错误不写入报告。",
    );
  }

  if (/\b(?:408|425|429|500|502|503|504)\b|HTTP\s+5\d\d|状态码\s*5\d\d/i.test(combined)) {
    return result(
      "failed",
      "provider_http_error",
      null,
      false,
      "provider_http_retryable",
      "真实 DSH 上游返回可重试 HTTP 状态；允许在限定次数内重试，原始错误不写入报告。",
    );
  }

  if (/session\/new|initialize|桥|spawn|ENOENT|找不到|不存在/i.test(combined)) {
    return result(
      "failed",
      "environment_or_startup_failure",
      null,
      false,
      "bridge_startup_failure",
      "DSH 桥启动或 ACP 握手失败；请先修复本地环境，原始错误不写入报告。",
    );
  }

  if (/model\s+is\s+unavailable|模型(?:当前)?不可用/i.test(combined)) {
    return result(
      "failed",
      "model_contract_failure",
      null,
      false,
      "model_unavailable",
      "Zen 目录已列出该模型，但上游当前返回 Model is unavailable；不按额度命中放行，待上游恢复后重跑。",
    );
  }

  return result(
    "failed",
    "model_contract_failure",
    null,
    false,
    /未包含|未包含 OK|回复未|oracle|OK/i.test(combined) ? "response_oracle_mismatch" : "model_route_or_protocol_failure",
    "真实 DSH 模型调用未满足本次测试约定；原始上游错误仅保留在本地标准错误，不写入报告。",
  );
}
