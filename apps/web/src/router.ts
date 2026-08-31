// Web 客户端路由：首页（健康/登录/设备/会话摘要）、只读会话/终端视图，以及 LLM 对话视图。
// 采用 hash history，静态托管无需服务端 fallback；对话页是 web 主动发起 LLM 会话的写入口。
import { createRouter, createWebHashHistory } from "vue-router";
import HomeView from "./views/HomeView.vue";
import CapabilitiesView from "./views/CapabilitiesView.vue";
import ChatView from "./views/ChatView.vue";
import SessionsView from "./views/SessionsView.vue";
import SessionDetailView from "./views/SessionDetailView.vue";
import SessionFilesView from "./views/SessionFilesView.vue";
import SessionGitView from "./views/SessionGitView.vue";
import TerminalsView from "./views/TerminalsView.vue";

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", name: "home", component: HomeView },
    {
      path: "/capabilities",
      name: "capabilities",
      component: CapabilitiesView,
    },
    { path: "/chat", name: "chat", component: ChatView },
    { path: "/sessions", name: "sessions", component: SessionsView },
    {
      path: "/sessions/:id",
      name: "session-detail",
      component: SessionDetailView,
    },
    {
      path: "/sessions/:id/files",
      name: "session-files",
      component: SessionFilesView,
    },
    {
      path: "/sessions/:id/git",
      name: "session-git",
      component: SessionGitView,
    },
    { path: "/terminals", name: "terminals", component: TerminalsView },
  ],
});
