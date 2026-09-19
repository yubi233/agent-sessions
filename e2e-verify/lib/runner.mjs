// 每个套件、每次尝试独占服务与账号；尝试记录和最终判定分开，首轮失败不被覆盖。
export function mayRetry(result) {
  return result.status === "failed" && result.retryable === true &&
    result.failure_class === "environment_or_startup_failure";
}

export function summarizeAttempts(attempts) {
  const last = attempts.at(-1);
  const passed = last?.status === "passed";
  return {
    status: passed ? "passed" : last?.status || "failed",
    retried: attempts.length > 1,
    flaky: passed && attempts.length > 1,
    attempts,
  };
}

export async function runSuites({ suites, openEnvironment, saveAttempt, log = () => {}, headless = false, retryLimit = 0 }) {
  const results = [];
  for (const suite of suites) {
    const attempts = [];
    for (let index = 0; index <= retryLimit; index += 1) {
      const started = Date.now();
      const startedAt = new Date(started).toISOString();
      log(`[run] ${suite.id} attempt=${index + 1}`);
      let environment;
      let result;
      let reported;
      try {
        environment = await openEnvironment(suite);
        result = await suite.run({
          ...environment,
          headless,
          report(payload) {
            if (reported) throw new Error("一个套件尝试只能提交一次结果");
            reported = payload;
            return payload;
          },
        });
        if (!result || result !== reported || !["passed", "failed", "blocked", "incomplete"].includes(result.status)) {
          throw new Error("套件未返回有效的结构化报告");
        }
      } catch (error) {
        result = {
          suite: suite.id,
          status: "failed",
          real_browser: false,
          headless,
          failure_class: "test_harness_defect",
          remaining_risk: error instanceof Error ? error.message : String(error),
          retryable: false,
        };
      } finally {
        if (environment) {
          // 首次失败就留存服务日志，不等复验覆盖现场；仅保存调用方拥有的服务。
          if (result?.status !== "passed") {
            result.service_logs = environment.logs?.() || {};
          }
          try {
            await environment.stop();
          } catch (error) {
            result = {
              ...result,
              status: "failed",
              retryable: false,
              failure_class: result?.status === "passed" ? "test_harness_defect" : result?.failure_class,
              cleanup_error: String(error),
            };
          }
        }
      }
      const attempt = {
        ...result,
        suite: suite.id,
        planId: suite.planId,
        attempt: index + 1,
        started_at: startedAt,
        finished_at: new Date().toISOString(),
        duration_ms: Date.now() - started,
        relay_base: result.relay_base || environment?.relay?.base,
      };
      await saveAttempt(attempt);
      attempts.push(attempt);
      log(`[run] ${suite.id} -> ${attempt.status} (${attempt.duration_ms}ms)`);
      if (!mayRetry(attempt)) break;
    }
    results.push({ id: suite.id, ...summarizeAttempts(attempts) });
  }
  return {
    status: results.every((result) => result.status === "passed") ? "passed" : "failed",
    total: results.length,
    passed: results.filter((result) => result.status === "passed").length,
    flaky: results.filter((result) => result.flaky).length,
    results,
  };
}
