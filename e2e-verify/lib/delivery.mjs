// 共享回归助手：从 Terminal 自己的命令流读取真实投递序号。
//
// 背景（2026-09-16 实测）：Relay 的投递序号按 (terminal, MAX+1) 单调分配，
// 硬编码 delivery_seq 在共享隔离 Relay 上会随其它命令/重试漂移；序号不符时
// daemon 回执端点返回 409，而多数 suite 的 req() 不检查状态码——seed 会"看起来
// 成功"却产出空结果，最终以难以定位的断言失败收场。
//
// 用法：
//   import { waitForDeliverySeq } from "../lib/delivery.mjs";
//   const seq = await waitForDeliverySeq(relayBase, terminalHeaders, commandId);
export async function waitForDeliverySeq(relayBase, terminalHeaders, commandId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(
      relayBase + "/v1/daemon/commands/stream?after_delivery_seq=0",
      {
        headers: { ...terminalHeaders, Accept: "text/event-stream" },
        signal: controller.signal,
      },
    );
    if (!response.ok) {
      throw new Error("命令流不可用: " + response.status);
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let boundary = buffer.indexOf("\n\n");
      while (boundary >= 0) {
        const frame = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const dataLine = frame.split("\n").find((line) => line.startsWith("data:"));
        if (dataLine && frame.includes("event: command")) {
          try {
            const wire = JSON.parse(dataLine.slice(5).trim());
            if (wire.command && wire.command.id === commandId) {
              return wire.delivery_seq;
            }
          } catch {
            /* 非法帧跳过，继续读流 */
          }
        }
        boundary = buffer.indexOf("\n\n");
      }
    }
    throw new Error("命令流结束但未见到目标命令: " + commandId);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}
