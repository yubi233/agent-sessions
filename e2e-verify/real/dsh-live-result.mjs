const zenQuotaPattern = /(?:\b429\b[\s\S]{0,160}(?:FreeUsageLimitError|free\s*usage|rate\s*limit)|(?:FreeUsageLimitError|free\s*usage|rate\s*limit)[\s\S]{0,160}\b429\b)/i;
export const dshZenTestModels = new Set([
  "mimo-v2.5-free",
  "big-pickle",
  "ling-3.0-flash-fin-free",
]);

export function classifyDshLiveFailure({ model, provider, message, stderr }) {
  const combined = `${message ?? ""}\n${stderr ?? ""}`;
  const isZenTestModel = provider === "opencode-zen" && dshZenTestModels.has(model);
  if (isZenTestModel && zenQuotaPattern.test(combined)) {
    return {
      status: "passed",
      failureClass: null,
      passReason: "zen_quota_accepted",
      quotaAccepted: true,
      remainingRisk: `已确认 DSH 接受 ${model} 并走 opencode-zen；按 v0.8 DSH 测试约定，429 FreeUsageLimitError 计为通过。该结果不证明模型回复、历史回放或恢复后 send。`,
    };
  }

  const credential = /no API key|MISSING_CREDENTIAL|INVALID_CREDENTIAL/i.test(combined);
  return {
    status: credential ? "blocked" : "failed",
    failureClass: credential ? "credential_or_quota_blocker" : "model_contract_failure",
    passReason: null,
    quotaAccepted: false,
    remainingRisk: "真实 DSH 模型调用未满足本次测试约定；原始上游错误仅保留在本地标准错误，不写入报告。",
  };
}
