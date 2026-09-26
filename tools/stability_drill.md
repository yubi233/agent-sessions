# v0.9.7 阶段 4.1：本地栈月度稳定性演练清单

> 每月执行一次，全部本地（不触云、不调真实模型）。执行人勾选并附证据路径；
> 结果回填 `docs/zh/实施记录/37-v0.9.7-长期稳定运行硬化.md` 或当月实施记录。
> 前置：`launchctl print gui/$(id -u)/com.agentsessions.localstack` 显示 running。

## 演练 1：每日备份有效性（每月 1 次 + 抽 1 份恢复对账）

```bash
task local:backup                       # 或 launchctl kickstart gui/$(id -u)/com.agentsessions.localbackup
ls -1dt .task/backups/*/ | head -1      # 取最新份
```

- [ ] 最新备份目录含 `relay.db`、`daemon.db`，且脚本输出两行 `backup OK`
- [ ] 恢复对账（把下面的 SRC 换成备份路径后计数应与线上库一致）：

```bash
SRC=.task/backups/<最新份>/relay.db
python3 - "$SRC" <<'PY'
import sqlite3,sys
a=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro",uri=True)
b=sqlite3.connect("file:.task/restart/relay.db?mode=ro",uri=True)
q="SELECT count(*) FROM sessions"
print("sessions:",a.execute(q).fetchone()[0],"==",b.execute(q).fetchone()[0])
q="SELECT count(*) FROM session_events"
print("events:",a.execute(q).fetchone()[0],"==",b.execute(q).fetchone()[0])
PY
```

## 演练 2：Relay 崩溃自愈（每月 1 次）

```bash
RELAY_DB_PATH=$PWD/.task/restart/relay.db tools/relayctl.sh down
```

- [ ] 60–70s 内 `curl -fsS http://127.0.0.1:8787/readyz` 恢复 200（监督循环拉起）
- [ ] `.task/supervisor.log` 出现 `readyz 不健康，执行 start` 记录
- [ ] 手机 App 下拉刷新可用（USB 连接时；reverse 由监督自动补挂）

## 演练 3：Daemon 崩溃自愈（每月 1 次）

```bash
kill -9 "$(pgrep -f 'daemon.bin run' | head -1)"
```

- [ ] 60–70s 内 `./restart.sh status --no-flutter --no-opencode` 显示 daemon running（新 pid）
- [ ] 重启后 `daemon.log` 无 `local_state_missing` 级别的连环错误；手机端会话列表可打开

## 演练 4：整机重启恢复（每季度或大版本升级后 1 次）

```bash
sudo shutdown -r now    # 重启后登录即开始观察
```

- [ ] 登录后 2 分钟内 `/readyz` 200（launchd RunAtLoad 拉起监督）
- [ ] 手机 App 冷启动直接进入工作区列表（reverse 已补挂）
- [ ] `launchctl print gui/$(id -u)/com.agentsessions.localstack | grep state` 为 running

## 演练 5：恢复码接管全流程（每季度 1 次，仅在愿意重置手机配对时执行）

- 参照 `docs/zh/项目文档.md` 本地开发拓扑一节：删除 `.task/restart/relay.db` 前必须先完成演练 1 的备份，且确认 `.task/restart/supervisor.paused` 已放置。
- [ ] owner 重建 → 手机恢复码接管 → 新 android_owner active → 会话列表可用
- [ ] 演练后从备份恢复数据或确认接受空库重新同步

## 证据归档

- 命令输出与截图放 `.task/diagnostics/stability-<日期>/`；结论与残余风险写入当月实施记录。
