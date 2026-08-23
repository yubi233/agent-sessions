export function classifyTransportResult({ code, stdout }) {
  const lines = String(stdout ?? "").split("\n");
  const summaryLine = lines.find((line) => line.startsWith("LIVE_SUMMARY"));
  const skipped = lines.some(
    (line) =>
      line.startsWith("--- SKIP: TestLiveTransport") ||
      line.includes("live gate 标记 blocked"),
  );

  if (code === 0 && skipped) {
    return {
      status: "blocked",
      failureClass: "credential_or_quota_blocker",
      realModel: false,
      realUpstream: false,
      remainingRisk: "真实 Adapter transport 未执行：运行环境缺少所需凭据。",
      summary: null,
    };
  }

  if (code === 0 && summaryLine) {
    let summary = null;
    try {
      summary = JSON.parse(summaryLine.slice("LIVE_SUMMARY".length).trim());
    } catch {
      return {
        status: "failed",
        failureClass: "environment_or_startup_failure",
        realModel: false,
        realUpstream: false,
        remainingRisk: "live gate 返回了不可解析的脱敏摘要。",
        summary: null,
      };
    }
    return {
      status: "passed",
      failureClass: null,
      realModel: true,
      realUpstream: true,
      remainingRisk:
        "真实 serve 单实例验证通过；断线/重连与多会话并发仍由 fixture 契约覆盖。",
      summary,
    };
  }

  if (code === 0) {
    return {
      status: "failed",
      failureClass: "environment_or_startup_failure",
      realModel: false,
      realUpstream: false,
      remainingRisk: "live gate 零退出但缺少 LIVE_SUMMARY，不能形成通过证据。",
      summary: null,
    };
  }

  return {
    status: "failed",
    failureClass: "product_defect",
    realModel: false,
    realUpstream: false,
    remainingRisk: "live gate 断言失败，见 go test 输出。",
    summary: null,
  };
}
