// 只读 Web 客户端路由：首页（健康/登录/设备/会话摘要）与能力矩阵视图。
// 采用 hash history，静态托管无需服务端 fallback；两页都是只读展示，不注册任何写入口。
import { createRouter, createWebHashHistory } from "vue-router";
import HomeView from "./views/HomeView.vue";
import CapabilitiesView from "./views/CapabilitiesView.vue";

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", name: "home", component: HomeView },
    {
      path: "/capabilities",
      name: "capabilities",
      component: CapabilitiesView,
    },
  ],
});
