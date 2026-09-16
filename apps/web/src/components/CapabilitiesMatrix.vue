<script setup lang="ts">
// 能力矩阵只读表格：每个 provider 一个分组头行（名称/版本/可用性），
// 组内每行一项 capability 三态。数据来自 Relay /v1/capabilities 的真实探测
// 结果（docs/zh/项目文档.md「统一能力模型」），本组件只渲染，
// 不包含任何发送/审批/写入口。
// 布局说明（2026-08-26 UI 审计）：旧结构为 5 列表格，能力行左侧 colspan=3
// 空占位造成大面积空白；现改为 2 列结构，provider 信息收进跨列分组头行。
import type { CapabilityStatus, ProviderCapabilities } from "../types";
import { CAPABILITY_LABELS, factsSourceLabel } from "../types";

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
    <caption class="sr-only">
      Provider 能力矩阵
    </caption>
    <thead>
      <tr>
        <th scope="col" class="matrix-col-capability">能力</th>
        <th scope="col" class="matrix-col-status">状态</th>
      </tr>
    </thead>
    <tbody>
      <template v-for="provider in providers" :key="provider.kind">
        <tr
          class="matrix-provider"
          :data-testid="`matrix-provider-row-${provider.kind}`"
        >
          <th colspan="2" scope="rowgroup">
            <span
              class="matrix-provider-name"
              :data-testid="`matrix-provider-${provider.kind}`"
            >
              {{ provider.kind }}
            </span>
            <span
              class="matrix-provider-meta"
              data-label="Version"
              :data-testid="`matrix-version-${provider.kind}`"
            >
              {{ provider.version || "未探测到" }}
            </span>
            <span
              class="matrix-provider-meta"
              data-label="Available"
              :data-testid="`matrix-available-${provider.kind}`"
              :class="provider.available ? 'is-available' : 'is-unavailable'"
            >
              {{ provider.available ? "可用" : "不可用" }}
            </span>
            <!-- v0.9.2 G1：回答"谁在声明这份可用性"，让云端（执行侧上报）与
                 本机（Relay 自己探测）两种事实来源在页面上可区分；
                 旧 Relay 不返回该字段时不渲染（保持既有版式）。 -->
            <span
              v-if="factsSourceLabel(provider.facts_source)"
              class="matrix-provider-meta"
              data-label="FactsSource"
              :data-testid="`matrix-facts-source-${provider.kind}`"
              :data-facts-source="provider.facts_source"
            >
              {{ factsSourceLabel(provider.facts_source) }}
            </span>
          </th>
        </tr>
        <tr
          v-for="cap in provider.capabilities"
          :key="`${provider.kind}-${cap.name}`"
          class="matrix-capability"
        >
          <td data-label="能力" class="matrix-cap-name">{{ cap.name }}</td>
          <td
            data-label="状态"
            :data-testid="statusTestId(provider.kind, cap.name)"
            :data-status="cap.status"
            :class="statusClass(cap.status)"
            :title="cap.reason || CAPABILITY_LABELS[cap.status]"
          >
            <span class="status-dot" aria-hidden="true"></span>
            <span>{{ CAPABILITY_LABELS[cap.status] }}</span>
          </td>
        </tr>
      </template>
    </tbody>
  </table>
</template>
