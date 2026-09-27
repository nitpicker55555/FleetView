# 提交确认 + 分层项目历史（project-manager）

| | |
|---|---|
| **文档类型** | 设计文档 + 实测记录 |
| **创建日期** | 2026-09-26 |
| **最后更新** | 2026-09-26 |
| **状态** | 已实现 |
| **对应代码版本** | `af9b55b` |
| **待决事项** | 见 §3 |

两件事，一起做是因为都落在 `project-manager` 上：

1. Web 端 / `project-manager send` 往 Codex 发消息，有时文字只停在输入框里没发出去。
2. `project-manager` 能回答"我最近在做什么项目、那些对话讲了什么、会话文件在哪"，而且要分层，不能一次把上下文撑爆。

---

## 1. 发送：Enter 被吃掉

### 1.1 根因（实测）

`RemoteServer.sendText` 以前是 `send-keys -l <text>` 紧跟一个 `send-keys Enter`。在隔离的 tmux socket 里对 codex-cli 0.153.4 实测：

| 做法 | 结果 |
|---|---|
| 两次 tmux 调用背靠背（≈0 ms 间隔） | 每次都**停在输入框**，Enter 变成了换行 |
| 中间隔 10 ms / 50 ms / 300 ms（Codex 空闲） | 全部提交 |
| 停住之后再单独按一次 Enter | 提交 |
| Codex 正在跑一轮时背靠背发 | 停在输入框，底部提示 `tab to queue message` |

原因是 Codex 的 paste-burst 判定：文字一次性涌入被当成粘贴，粘贴窗口内到达的 Return 被当成换行（防止粘贴多行文本时第一行就提交）。Claude Code 2.1 空闲时背靠背发短文本没问题，但**长文本**（1,287 字）偶发停住，而且 2 秒后补的一次 Enter 也被吞了，第三次才提交——它还在消化输入。

"有时候"的由来：Swift 里两次 `Process` 启动之间天然有几毫秒间隔，TUI 空闲时够用；TUI 忙（流式输出、重绘）时它会一次读走积压的按键，间隔就塌了。

### 1.2 为什么不能只加延时

窗口是按 TUI **读到**按键的时刻算的，不是按我们发出的时刻。忙的时候多少间隔都可能被压扁。所以做法是：**留间隔 → 按 Enter → 看一眼 → 还在就再按**。

### 1.3 实现：`Remote/Submit.swift`

- 短文本（去空白后 < 3 字符，比如菜单数字 `1`、`y`）照旧直接 Enter，不检查：数字在每个编号菜单里都看得见，没法问"它还在不在"。
- 否则：间隔 `0.12 s + 字数/4000`（上限 0.52 s）→ 确认前台进程是 agent（`#{pane_current_command}` 为 `claude`/`codex`/`node`/版本号形状）→ **先确认文字确实出现在输入框** → Enter → 每 0.5/0.7 s 看一次，还在就再按，最多补 4 次。
- "输入框"= pane 里**最后一个**以 `›`（Codex）/ `❯`（Claude）开头的行及其以下。更早的标记行是历史——两个 agent 都会把已提交的 prompt 留在屏幕上。比对用文字**尾部** 12 个字符，去掉所有空白和 `│` 后比较：长 prompt 在 Claude 输入框里会滚动，开头已经不可见。
- shell 里不补 Enter：在跑命令的 shell 里多一个回车会回答那个命令正在等的东西。
- 结论只在"看到文字进了输入框、又看到它离开"时才报 `submitted`。文字根本没到（TUI 还在画 banner 时会丢键）只报 `sent`，不冒充成功。
- 写队列从全局一个改成**每个终端一个**：一次提交现在可能等几秒，不能拖住发给别的 agent 的 Esc。每次写入在 `WriteLedger` 里计数，检查途中有新写入就停止补 Enter（`superseded`）——调用方已经在做别的事了。

### 1.3a 第二种静默丢失：pane 处于 copy-mode

pane 往回滚动过就处在 tmux copy-mode，它的按键表既不绑定字符也不绑定 Enter——打进去的东西全部无声丢弃，连输入框都进不去。Codex 不上报鼠标，所以 Web 的滚动按钮（`RemoteServer.scroll` 对 `mouse_any_flag=0` 的 pane 走 copy-mode）和桌面窗口里的滚轮都会让它进入 copy-mode：往上翻着看完再回复，回复就没了。`auto-recover.sh` 2026-09-24 因此连丢过 6 个"继续"。

`Submit.run` 开头先查 `#{pane_in_mode}`，是 1 就 `send-keys -X cancel`。实测：进入 copy-mode 后，修复前文字消失、结论为 `sent`；修复后 `submitted`。

### 1.4 接口

`/type?...&wait=1` 在检查结束后才回答：`{"ok":true,"submit":"submitted|stuck|sent|typed|superseded"}`。不带 `wait` 的行为不变（立即回答，后台照样检查、补 Enter）。旧版 FleetView 忽略 `wait`，回答里没有 `submit`，调用方据此回退。

- Web 发送用 `wait=1`，`stuck` 时提示"文字还停在输入框里，点 ⏎ 再发一次"。
- `project-manager send` 报告结果；`stuck` 时非零退出并给出补救命令。对不认识 `wait` 的旧实例（其他 Mac 上的 peer 常常落后一个版本），CLI 自己做同样的检查——仅限 `agent` 非空的终端。

### 1.5 验证

把真实的 `Submit.swift` 编进一个小 harness，对隔离 socket（`tmux -L fvtest`）里的真实 Codex / Claude 跑：

| 场景 | 结果 |
|---|---|
| Codex 空闲，正常发 | `submitted`，1 次 Enter |
| Codex 空闲，第一次 Enter 被吃（把 Enter 和文字粘在同一个 tmux 调用里复现） | `submitted`，补 1 次 |
| Codex 正在跑一轮，Enter 被吃 | `submitted`，补 1 次，消息进入 "submitted after next tool call" |
| Claude 长文本，Enter 被吃 | `submitted`，补 2 次（第一次补的也被吞，与 §1.1 一致） |
| 文字根本没到 | `sent`（不报成功） |
| 普通 shell 里跑着 `cat` | `sent`，0 次补发 |
| 菜单数字 `1` | `sent`，不检查 |
| pane 处于 copy-mode | 修复前文字丢失（`sent`）；修复后 `submitted` |

CLI 用一个桩服务器验证：模拟旧服务器（文字 + Enter 零间隔，不认 `wait`）时，CLI 自己的检查把消息补发成功；模拟新服务器时，直接转述服务器结论。

---

## 2. 分层项目历史

### 2.1 数据现状（实测，2026-09-26）

- `~/.fleetview/search.db`：6,542 个 transcript、20.3 万条 prompt/回复全文，`file.project` 是会话 cwd。全量按文件聚合 0.39 s。只在 App 启动和打开搜索面板时刷新——所以本次同时加了每 5 分钟一次的增量刷新（空刷新约 0.1 s）。
- 磁盘上 3,835 个 transcript，stat 全扫 0.02 s；索引落后的部分当时只有 3.7 MB。索引里有约 2,700 个文件已被删除（Claude 按期清理），内容仍可读，只是不能 resume。
- **FleetView 的项目列表不能当项目历史**：这台机器上只有 4 个项目，而最近最活跃的 `qwen_fancy_web` 有 445 个 transcript，它已经从看板上移除了。所以"项目"要从会话 cwd 推出来。
- `state.json` 的 `terminalArchive` 保留了 254 张被移除卡片的 `transcriptPath`、`name`、`projectPath`——卡片名（如 "DES-T8-015 difficulty repair"）是最好的会话标题。
- 噪声：5,812 个文件是 subagent 线程（Codex 2,145 个，`source.subagent.thread_spawn.parent_thread_id`；Claude 3,667 个，`<sid>/subagents/`），65 个是非交互会话（Claude `entrypoint=sdk-cli`，Codex `source=exec`）。prompt 里 `<task-notification>` 就有 6,183 条，还有 `<subagent_notification>`、`<recommended_plugins>`、"This session is being continued…" 等注入内容。

### 2.2 分层

每层默认有条数和字数上限，末尾给出进入下一层的命令。上下文按需逐层展开，不一次倒出来。

| 层 | 命令 | 默认量 | 回答的问题 |
|---|---|---|---|
| L0 | `project-manager projects` | 12 个项目 × 2 行 | 最近在做哪些项目 |
| L1 | `project-manager history <项目>` | 10 个会话 × ≤4 行 | 这个项目有哪些对话、各自讲什么、文件在哪 |
| L2 | `project-manager session <会话>` | 前 3 + 后 12 个回合，每条一行 | 这个对话的来龙去脉 |
| L3 | `project-manager session <会话> -t N` | prompt ≤1500 字 + 最终回复 ≤2500 字 | 某一回合具体说了什么 |
| 横切 | `project-manager search <词> [-p 项目]` | 8 个会话 × ≤2 段摘录 | 哪次对话提到过 X |

### 2.3 规则

- **会话** = 一个主 transcript。subagent 线程并入父会话（只计数）；非交互会话和 `/tmp` 下的会话默认隐藏，`-a` 显示。
- **项目归属**：cwd 落在 FleetView 项目（含 archive 里已移除项目的 `projectPath`）之内 → 该项目，取最长前缀；否则 → git 根（不含 `$HOME` 本身）；否则 → 已见过的最近祖先 cwd（不越过 `$HOME` 下两层，避免把整个 `~/PycharmProjects` 并成一个）；否则 → cwd 本身。
- **回合编号**：去掉注入噪声后的真实 prompt，按文件顺序从 1 编号。L2、L3、search 共用同一套编号，所以 search 里的 `t12` 可以直接 `session <id> -t 12`。
- **标题**：有意义的卡片名优先——默认名 `<项目>-<n>` 和从注入内容派生的名字（`⌕ <task-notifi ⑂`）不算；否则第一个去掉噪声、长度 ≥ 8、不是"继续 / Continue from where you left off"的 prompt。同一批 subagent 共用同一段开场说明时，重复的开场只显示一次。
- **最近活动时间**：文件长过了索引（大小 > `file.done`）才用 mtime，否则用最后一条消息自己的时间戳。实测 mtime 不可靠：一批几天没动的会话文件被同一个小时"摸"过，按 mtime 排序会把它们顶到最前面。
- **新鲜度**：展示到的会话若索引落后，CLI 只把没索引的尾部按和索引器相同的规则解析一遍。
- **选择器**：项目按名字精确 → 归一化（去掉 `_ - 空格`）→ 子串 → 模糊匹配（会说明匹配到了谁）。会话按 session id 前缀、FleetView 卡片 id 前缀（含已移除卡片）、transcript 文件名或路径。
- 只读：`search.db` 以 `mode=ro` 打开；只写一个缓存 `~/.fleetview/cache/history-heads.json`（每个 transcript 头部的分类，头部不会变）。
- 只看本机文件，所以带 `-u` 指向别的机器时直接拒绝——否则会拿本机的历史冒充那台机器的；要看另一台 Mac 的历史就在那台机器上跑。
- 实测每层输出：L0 约 2.4k 字符、L1 约 3.7k、L2 约 1.6k、L3 约 0.6k、search 约 2.6k；对比其中一个会话的 transcript 本身 40 MB。冷启动（无缓存）0.9 s，之后 0.2 s。

---

## 3. 待决事项

- Web 仪表盘是否也要一个"项目历史"视图？目前只做了 CLI（给 agent 用）。
- `--json` 输出暂未提供；若有脚本需要，可以在 L1/L2 上加。
