// Admin 运维只读控制台路由：overview/terminals/sessions/audit 四个分区。
// 采用 hash history；所有分区只读，不注册任何写入口。
import { createRouter, createWebHashHistory } from "vue-router";
import OverviewView from "./views/OverviewView.vue";
import TerminalsView from "./views/TerminalsView.vue";
import SessionsView from "./views/SessionsView.vue";
import AuditView from "./views/AuditView.vue";

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", name: "overview", component: OverviewView },
    { path: "/terminals", name: "terminals", component: TerminalsView },
    { path: "/sessions", name: "sessions", component: SessionsView },
    { path: "/audit", name: "audit", component: AuditView },
  ],
});
