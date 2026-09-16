// Web 只读客户端的公共类型：能力矩阵 DTO 与协议常量。
// 字段与 Relay /v1/capabilities 的 providers 数组对齐（docs/zh/项目文档.md「统一能力模型」）。
export type CapabilityStatus = "native" | "emulated" | "unsupported";

export interface CapabilityItem {
  name: string;
  status: CapabilityStatus;
  reason?: string;
}

export interface ProviderCapabilities {
  kind: string;
  version: string;
  available: boolean;
  capabilities: CapabilityItem[];
  /**
   * v0.9.2 G1（additive）：可用性事实来源。
   * - "relay"       ：Relay 进程自身探测成功（它确实能执行该 Provider）；
   * - "terminal"    ：执行侧 Terminal(Daemon) 上报的事实（云端 Relay 自己跑不了 DSH）；
   * - "unavailable" ：两侧都没有可用事实，保持 fail-closed；
   * - 缺省（旧 Relay）：不渲染来源标签，保持既有版式。
   * 该字段只用于展示与诊断，不参与任何可用性判定。
   */
  facts_source?: string;
}

// 事实来源的展示文案（只读渲染；缺省返回空串表示不显示）。
export const FACTS_SOURCE_LABELS: Record<string, string> = {
  relay: "本进程探测",
  terminal: "执行侧上报",
  unavailable: "无可用事实",
};

export function factsSourceLabel(source?: string): string {
  if (!source) return "";
  return FACTS_SOURCE_LABELS[source] ?? source;
}

// 三态的展示文案；只读渲染，不承载任何写入口。
export const CAPABILITY_LABELS: Record<CapabilityStatus, string> = {
  native: "原生支持",
  emulated: "模拟支持",
  unsupported: "不支持",
};
