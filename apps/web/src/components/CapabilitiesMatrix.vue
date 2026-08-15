<script setup lang="ts">
// 能力矩阵只读表格：provider/version/available + 每项 capability 三态。
// 数据来自 Relay /v1/capabilities 的真实探测结果（docs/zh/项目文档.md「统一能力模型」），
// 本组件只渲染，不包含任何发送/审批/写入口。
import type { CapabilityStatus, ProviderCapabilities } from "../types";
import { CAPABILITY_LABELS } from "../types";

defineProps<{ providers: ProviderCapabilities[] }>();

// data-testid 辅助：稳定且可被 headed 回归按 provider/capability 精确断言。
function statusTestId(kind: string, name: string): string {
  return `matrix-cap-${kind}-${name}`;
}

function statusClass(status: CapabilityStatus): string {
  return `capability-status status-${status}`;
}
</script>

<template>
  <table class="matrix" data-testid="capability-matrix">
    <thead>
      <tr>
        <th scope="col">Provider</th>
        <th scope="col">Version</th>
        <th scope="col">Available</th>
        <th scope="col">Capability</th>
        <th scope="col">Status</th>
      </tr>
    </thead>
    <tbody>
      <template v-for="provider in providers" :key="provider.kind">
        <tr
          class="matrix-provider"
          :data-testid="`matrix-provider-row-${provider.kind}`"
        >
          <th
            scope="rowgroup"
            :data-testid="`matrix-provider-${provider.kind}`"
          >
            {{ provider.kind }}
          </th>
          <td :data-testid="`matrix-version-${provider.kind}`">
            {{ provider.version || "未探测到" }}
          </td>
          <td :data-testid="`matrix-available-${provider.kind}`">
            {{ provider.available ? "可用" : "不可用" }}
          </td>
          <td colspan="2"></td>
        </tr>
        <tr
          v-for="cap in provider.capabilities"
          :key="`${provider.kind}-${cap.name}`"
          class="matrix-capability"
        >
          <td colspan="3"></td>
          <td>{{ cap.name }}</td>
          <td
            :data-testid="statusTestId(provider.kind, cap.name)"
            :data-status="cap.status"
            :class="statusClass(cap.status)"
            :title="cap.reason || CAPABILITY_LABELS[cap.status]"
          >
            {{ CAPABILITY_LABELS[cap.status] }}
          </td>
        </tr>
      </template>
    </tbody>
  </table>
</template>

<style scoped>
.matrix {
  border-collapse: collapse;
  font-size: 0.9rem;
  margin-top: 12px;
  text-align: left;
  width: 100%;
}

.matrix th,
.matrix td {
  border: 1px solid #33435f;
  padding: 6px 10px;
}

.matrix .matrix-provider th {
  background: #22304a;
}

.capability-status {
  font-weight: 700;
}

.status-native {
  color: #7be0a6;
}

.status-emulated {
  color: #ffd479;
}

.status-unsupported {
  color: #ff8f8f;
}
</style>
