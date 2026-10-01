# Codex subagent 的 hook 归属与 hook 信任

| | |
|---|---|
| 文档类型 | 事故记录 |
| 创建日期 | 2026-10-01 |
| 最后更新 | 2026-10-01 |
| 状态 | 已修复，已部署（2026-10-01 18:01，build 162） |
| 对应代码版本 | `d5e1d5c` |
| 修复 | `6b1510a` subagent 事件的归属；`d5e1d5c` 重启不再删掉 Codex 的 hook 信任 |
| 异常时段 | 2026-09-24 10:48 到 2026-09-25 18:21，终端 `codex master`（项目 qwen_fancy_web） |
| 待决事项 | 文末「下一步」 |

这份文档记录 audit log 里 2026-09-24 那段 `transcript_bound` 异常的原因、修复它的 commit，以及部署时发现并修掉的第二个问题。

## 日志里的异常

`~/.fleetview/logs/audit-2026-09-24.jsonl` 有 39.6 MB，其他日子在 0.2 MB 到 16 MB 之间。这一天有 17,736 条 `fleetview.terminal.transcript_bound`，其中 16,691 条来自终端 `codex master`。同一秒里这张卡的 `transcriptPath` 在好几个 `~/.codex/sessions/2026/09/24/rollout-*.jsonl` 之间来回换。

9-24 到 9-25 两天，这张卡改绑 20,477 次，目标是 109 个不同的 rollout。1 个是它自己的会话，108 个是 subagent 的 rollout。

`~/.fleetview/fleetview.log` 里这张卡收到的 hook：

| 事件 | 次数 |
|---|---|
| PreToolUse | 22,479 |
| PostToolUse | 20,815 |
| UserPromptSubmit | 147 |
| SessionStart | 21（18 次 compact，3 次 resume） |
| Stop | 34 |

同期有 363 次 `run finished`（261 次 idle，100 次 new prompt，2 次 shell），比 prompt 多出 216 次，卡片在 working 和 idle 之间来回跳。

macOS 在 2026-09-24 14:17 给 FleetView 记了一份磁盘写入报告，`/Library/Logs/DiagnosticReports/FleetView_2026-09-24-141705_*.diag`。06:59 到 14:17 写了 2,147 MB，平均 81.79 KB/s，限额是 24.86 KB/s。204 个采样步里 185 步在 `AppState.saveNow()` 的 `Data.write`，也就是重写 `~/.fleetview/state.json`。

整个 audit 历史（7-28 到 9-30）里，改绑到 subagent rollout 的 `transcript_bound` 一共 24,677 条，8 月 4,500 条，9 月 20,177 条，涉及 18 张 Codex 卡。9-24 这次规模最大。Claude 卡一次都没有。

## codex master 在做什么

它的 rollout `rollout-2026-09-24T10-48-38-01a0d150-a5e0-7782-9296-b4ffd7f7a785.jsonl` 里，工具调用全是 Codex 自带的 multi-agent 工具：

| 工具 | 次数 |
|---|---|
| send_message | 524 |
| wait_agent | 511 |
| list_agents | 169 |
| followup_task | 152 |
| spawn_agent | 74 |
| interrupt_agent | 18 |

`project-manager` 一次都没调用。它管理的不是 FleetView 的终端，是它自己 spawn 出来的 subagent。这些 subagent 是同一个 codex 进程里的线程，每个线程写自己的 rollout，cwd 和 master 相同。

## 原因

subagent 是 master 进程里的线程，继承了终端的 `FLEETVIEW_TERM_ID`，它的 hook 经 `hook.sh` 进来就是这张卡的事件。在 Codex 0.153 里，这种 hook 的 payload 中 `session_id` 是 master 的会话 id，`transcript_path` 是 subagent 自己的 rollout。

`AppState.applyHookEvent` 对每个事件都执行 `terminals[idx].transcriptPath = tp`，最后调用 `save()`。结果有三个：

1. 每个 subagent 的 PreToolUse 和 PostToolUse 都把卡改绑到这个 subagent 的 rollout，记一条 `transcript_bound`，再排一次 state.json 重写。那时 state.json 约 250 KB，现在 462 KB。
2. 卡片的状态、对话、token 数跟着最后一个发事件的 subagent 走。
3. `hook.sh` 每个事件都重写 `~/.fleetview/sessions/<term>.json`，subagent 的事件也写。重新打开卡片（`reopenTerminal`）和 fork 读的是这个指针，会去 `codex resume` 一个 subagent。我查了历史上 6 次 Codex 恢复，都没有碰上，因为 codex master 是直接被删掉的。

subagent 只发 PreToolUse 和 PostToolUse。历史里没有一条 `prompt_submitted` 或 `session_started` 的 transcript 属于 subagent。上表的 34 次 Stop 比 master 自己 rollout 里的 51 次 task_complete 还少，下面的生产测试里 3 个线程也只来了 1 次 Stop。subagent 把卡设成 working 以后，没有哪个 subagent 事件会把它设回去。

## 不在跑的 Codex 卡显示 running

这是另一条路径。`CodexSession.currentRollout(cwd:excluding:)` 每秒给每张 Codex 卡找这个 cwd 里最新的、没被别的卡认领的 rollout，再用它最后一个 task_started 或 task_complete 判断 working 还是 idle。subagent 和 master 同 cwd，一直在写，又没有卡认领，所以同目录里一张空闲的 Codex 卡会拿到一个正在忙的 subagent，显示 running，直到整轮跑完。

我先排除了 subagent 停在半截的可能。9-24 到 9-29 的 165 个 subagent rollout，最后一个回合边界是 152 个 task_complete 和 13 个 turn_aborted，没有一个停在 task_started。

## 怎么认出 subagent

只能看 rollout 第一行的 `session_meta`。我统计了本机全部 2,415 个 Codex rollout：

| 版本 | subagent 的标记 |
|---|---|
| 0.153 | `thread_source: "subagent"`、顶层 `parent_thread_id`、`source.subagent.thread_spawn`；`session_id` 是根会话 |
| 0.141 | `thread_source`、顶层 `parent_thread_id`、`source.subagent`；`session_id` 等于自己的 id |
| 0.136 | `thread_source`、`source.subagent.thread_spawn.parent_thread_id`；没有顶层 `parent_thread_id` |

`session_id` 判断不了。1,829 个 subagent 的 `session_id` 不等于自己的 id，另外 322 个（0.136 和 0.141）等于；还有 7 个用户自己打字的线程 `session_id` 不等于 id。原来的 `CodexTree.Meta.isMainLine` 只看顶层 `parent_thread_id`，把 139 个 0.136 的 subagent 当成了独立会话。

## 6b1510a

- `CodexTree.Meta.isWorker` 按上表三种标记判断，`parentThread` 两处都读。
- `CodexTree.meta` 不再缓存还没写完的第一行。hook 可能在 Codex 写完 session_meta 之前就报出这个 rollout。
- `handleHookEvent` 先看 transcript 是不是 subagent 的。是的话走 `applyWorkerEvent`，只记活动时间，不改绑，不改状态，不存盘。例外是 PermissionRequest：卡片显示 needs you，只有那个 subagent 的下一次工具调用能清掉它。
- `auditHookEvent` 不再把 subagent 的 SessionStart、UserPromptSubmit、Stop 记成这张卡的回合。
- `currentRollout` 跳过 subagent 的 rollout。
- `hookSessionPath` 读到 subagent 的 rollout 时，沿 `parent_thread_id` 走回会话的 rollout（`CodexTree.mainLineRollout`）。
- `load()` 把旧版本存进 state.json 的 subagent 路径换回会话路径。本机有 1 张归档卡是这种情况（015 media audit）。

## 验证 6b1510a

离线：把 `CodexTree` 的 rollout 索引部分和 `CodexSession` 编进一个测试程序，跑本机全部 2,415 个 rollout。新代码的分类和我用 Python 独立读 session_meta 的结果完全一致，264 个会话、2,151 个 subagent，2,151 个 subagent 都走回到正确的会话。改之前的代码错 139 个。

合成目录：一个 master 在等两个 subagent，另一张卡已经空闲。改之前空闲卡被判成 working，拿到的是 subagent 的 rollout；改之后判成 idle。

生产：在 FleetView 项目里开两张临时 Codex 卡。A 让两个 subagent 各跑 `sleep 30`，B 先回一句 ok 然后空闲。每秒读一次 `/state`：

| | build 159，修复前 | build 161，修复后 | build 162，最终 |
|---|---|---|---|
| A 的 transcript 改绑次数 | 5，其中 3 次到 subagent | 1 | 1 |
| B 显示 running 的采样 | 31 / 58，约 32 秒 | 3 / 126 | 1 / 105 |
| A 收到的 subagent 事件 | 当成 A 自己的 | 6 次，全部记为 worker | 4 次，全部记为 worker |

修复后 B 剩下的 1 到 3 个 running 采样都在 A 刚开始的一两秒里。那时 A 的第一个 hook 还没到，A 的新 rollout 没被认领，按 cwd 猜会落到它上面。这和 subagent 无关，放在最后一节。

## 部署时发现的第二个问题

17:45 第一次部署 build 161 重启之后，新开的 Codex 会话一个 hook 都不来了，测试卡只收到 shell 命令事件。用 `codex app-server` 的 `hooks/list` 问 Codex，FleetView 的 6 个 hook 全是 `untrusted`。重启前的测试里，同样的会话 hook 都到了。

Codex 只执行信任过的 hook，信任记在同一个 `~/.codex/config.toml` 里，每个 hook 一张 `[hooks.state."<key>"]` 表，表里一个 `trusted_hash`。Codex 用 toml_edit 写这些表，新表放在同类表后面，也就是 FleetView 的 `[[hooks.*]]` 后面、`# <<< FleetView status hooks <<<` 前面，落在 FleetView 的围栏里。文件因此和 `CodexHookInstaller.install()` 生成的内容不一致，下次启动时 `install()` 去掉整个围栏再追加，信任表一起被删。之后 Codex 不提示地跳过这些 hook，FleetView 收不到任何新 Codex 会话的事件，直到有人在 Codex 里重新审核 hook。

我在隔离的 CODEX_HOME 里复现了这件事。用 `config/batchWrite` 写信任，这是 Codex 自己的 hook 审核界面发的请求，6 张表落在围栏内。旧的 `install()` 跑一遍后 Codex 报 6 个 untrusted，新的跑完是 6 个 trusted，再跑一遍文件不变。

audit log 里每次 FleetView 启动之后收到的 Codex prompt 和 session 事件：

| 启动 | build | 到下次启动前的事件数 | 第一条 |
|---|---|---|---|
| 09-26 19:27 | 150 | 0 | |
| 09-26 23:13 | 152 | 0 | |
| 09-26 23:18 | 152 | 16 | 09-27 13:40 |
| 09-27 16:39 | 159 | 39 | 09-29 10:25 |
| 10-01 17:45 | 161 | 0 | |

`aa4f7d6` 当时把 Codex 的状态改成从 rollout 读，绕开了不再触发的 hook。hook 不触发的原因就是这个。

## d5e1d5c

`CodexHookInstaller.stripFence` 在围栏里只删 FleetView 自己的 `[[hooks.*]]` 表，别的表和它下面的行都保留，放回围栏前面。

我用和 Codex 审核界面相同的 `config/batchWrite` 恢复了这 6 个 hook 的信任。hook 定义没有变，hash 和之前一致。然后部署 build 162。18:01 启动时 `install()` 把 6 张信任表移到围栏前面，其余行一行不少，`hooks/list` 报 6 个 trusted。之后新开的 Codex 会话 hook 正常到达，上面生产表的最后一列就是这时测的。

## 部署记录

- 17:53 那次部署没有生效。worktree 里的增量 release build 打印了编译步骤，但目标文件全是 17:42 的，只重新链接了一次，部署出去的还是旧的 installer，重启又删掉了我刚恢复的信任。删掉 `.build` 重新编译后正常。
- 同一次，替换完 `/Applications/FleetView.app` 立刻 `open`，LaunchServices 按文件引用启动了刚被删掉的旧 bundle。pid 30585 的可执行文件 inode 是 156214480，磁盘上的是 156219049，`Bundle.main` 读到的版本是 161。所以 audit log 里 17:53:44 到 18:01 这段的 `service.version` 是 `0.4.0 (161)`。最后一次部署先 `lsregister -f` 再 `open`，并核对了运行中的 inode 和 audit 里的版本号。
- build 162 就是 `d5e1d5c`，从干净的 worktree 打包。工作区里未提交的 `Sources/FleetView/Remote/RemoteServer.swift` 改动（9-29）不在里面。
- 2026-10-01 17:43 到 18:04，audit log 里名为 `fvtest-A …` 和 `fvtest-B …` 的 8 张卡是这次测试建的，已删除。它们的 13 个 rollout 用 Codex 的 `thread/delete` 删掉了，搜索索引里的 19 行、6 个 session 指针、`~/.codex/history.jsonl` 里的 7 行也清掉了。

## 下一步

- Mac mini 上的 headless FleetView 没有这两个 commit，每次重启同样会删掉那边的 Codex hook 信任，那边的 Codex 用 subagent 时也会被改绑。需要把 `d5e1d5c` 部署过去。
- `package_app.sh --install` 在 ditto 之后加 `lsregister -f`，避免启动到旧 bundle。
- 状态轮询在 hook 认领 rollout 之前仍按 cwd 猜。hook 指针比候选 rollout 新时，应该优先用指针。
- 由终端里的 agent 启动的 `codex exec` 也继承 `FLEETVIEW_TERM_ID`，历史里有 10 次改绑到 exec 的 rollout。可以用 session_meta 的 `source: "exec"` 同样处理。
- Codex 卡的 token 数现在只算会话本身，不含 subagent，Claude 卡含 subagent。要一致需要把子 rollout 的 token 加进来。
- 没有 subagent 时 state.json 的写入也接近限额。9-27 到 9-28 的报告是 27.25 KB/s，238 步里 216 步在 `saveNow()`。state.json 463 KB 里 448 KB 是 `terminalArchive`（339 行，每行带最后一条 prompt），每次 hook 事件之后都整份重写。（这里原先写的"约 60%"是按带空格的 JSON 估的，不对。）后来的处理见 `AppState.persist`：归档移到 `~/.fleetview/archive.json`，只在变化时写；状态字段不再存；内容没变不写；只有活跃时间和 token 数变化时最多 2 分钟写一次。
