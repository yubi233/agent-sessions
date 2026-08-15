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
}

// 三态的展示文案；只读渲染，不承载任何写入口。
export const CAPABILITY_LABELS: Record<CapabilityStatus, string> = {
  native: "原生支持",
  emulated: "模拟支持",
  unsupported: "不支持",
};
