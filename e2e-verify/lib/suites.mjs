// 回归场景统一注册表：新增回归测试只在此追加，不散落临时脚本。
// 每个场景导出 { id, title, planId, run(ctx) }；run 返回 { status, ... } 报告。
import { p0Health } from "../suites/p0-health.mjs";
import { p1WebReadonly } from "../suites/p1-web-readonly.mjs";
import { p4AdminReadonly } from "../suites/p4-admin-readonly.mjs";
import { p5OpencodeCapabilities } from "../suites/p5-opencode-capabilities.mjs";

// registry 是本仓库 headed 浏览器回归的唯一事实源。
export const registry = [
  p0Health,
  p1WebReadonly,
  p4AdminReadonly,
  p5OpencodeCapabilities,
];
