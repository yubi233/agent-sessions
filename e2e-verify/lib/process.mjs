// 子进程仅由启动它的调用方回收；退出等待有界，已退出进程可重复清理。
export async function stopProcess(child, timeoutMs = 5000) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGTERM");
  let timer;
  const stopped = await Promise.race([
    exited.then(() => true),
    new Promise((resolve) => { timer = setTimeout(() => resolve(false), timeoutMs); }),
  ]);
  clearTimeout(timer);
  if (!stopped) {
    child.kill("SIGKILL");
    await exited;
  }
}
