# FleetView 审计日志规范 v1

| | |
|---|---|
| **文档类型** | 设计文档（Design Doc） |
| **创建日期** | 2026-07-27 |
| **最后更新** | 2026-07-28 |
| **状态** | 实现中 —— 引擎与状态层已落地，见[实施文档](2026-07-28-audit-logging-implementation.md) |
| **Schema 版本** | `fleetview.schema = 1` |
| **对应代码版本** | `f54cc8a`（2026-07-27，文中行号以此为准） |
| **待决事项** | 见 §13 |

> **2026-07-28 修订**：实施阶段的调研发现，本规范默认的"观察状态变化"思路单独使用会**静默丢失不改变状态的操作**（点卡片提升窗口、发按键、以及所有失败的请求）。因此实现采用"**声明意图 + 状态 diff**"双层，理由与取舍见实施文档 §1。

> 目标：把 FleetView **控制面上发生的每一件事**（谁、在什么时候、对哪个资源、做了什么、结果如何）完整、结构化、可机读地记下来；
> 同时**绝不重复记录已经有权威存储的数据面内容**（Claude/Codex 对话正文已在 transcript 文件里，日志只存指针）。

---

## 0. 目标与非目标

**要记录（控制面 / control plane）**
- 应用与服务生命周期（启动、Web 服务、ttyd 实例、hook 安装）
- 资源 CRUD：project / terminal / cluster / note，含 **uuid + 名称 + 归属**
- 终端状态迁移（shell → working → needs you → idle …）及其触发源
- **shell 命令**（命令行、cwd、退出码、耗时）
- Agent 会话事件（会话开始/结束、提交 prompt 的事实、权限请求、一轮结束的 token 增量）
- **Dynamic Panel 的每一个历史版本**（UUID 命名、内容永久归档、归因到产生它的会话文件 —— 见 §14）
- **Web 端访问**：客户端会话、IP、UA、**地理位置**、附着到哪个终端、发送了什么控制指令
- CLI（`fleetctl` / `project-manager` / `fleet-monitor`）发起的操作

**不记录（数据面 / data plane，已有权威文件）**
| 内容 | 权威存储 | 日志里只写 |
|---|---|---|
| Claude/Codex 对话正文、工具调用参数与结果 | `~/.claude/projects/<slug>/<session>.jsonl`、`~/.codex/...` | `transcript.path` + `session_id` + 行/字节偏移 + 长度 + sha256 |
| 终端屏幕内容 / 滚动缓冲 | tmux 会话（可选 asciicast 录制） | 录制文件路径 + 时间偏移 |
| ttyd 的 WebSocket 按键流 | 无（瞬时） | 只记录"附着/断开"与聚合统计 |
| token 明细 | transcript 的 `usage` 字段 | 每轮结束的**增量汇总**一条 |
| 调参用的启发式噪声（现 `fleetview.log`） | 保留为独立 debug 日志 | 不进审计日志 |

---

## 1. 参考的业界标准（以及各取其一）

| 标准 | 取用的部分 |
|---|---|
| **Elastic Common Schema (ECS)** | 字段命名与四件套分类 `event.kind` / `event.category` / `event.type` / `event.action`、`event.outcome`、`@timestamp`(ISO 8601)、`source.*` / `client.geo.*` / `user_agent.*`；自定义字段收敛到单一命名空间（ECS 官方推荐），这里是 `fleetview.*` |
| **OpenTelemetry Semantic Conventions（Events / Logs Data Model）** | `event.name` 用点分层级命名（如 `fleetview.terminal.created`）；resource 属性描述"谁产生的日志"（app、host、instance） |
| **AWS CloudTrail** | 控制面审计的记录形状：`eventID` / `eventTime` / `eventName` / `userIdentity` / `sourceIPAddress` / `userAgent` / `requestParameters` / `responseElements` / `readOnly`，读操作与写操作分级 |
| **Kubernetes Audit Policy** | **分级记录** `None / Metadata / Request / RequestResponse` + `omitStages`：高频低价值的读请求只计数不落盘，敏感内容停在 Metadata 级 —— 这正是"不重复记录"的制度化表达 |
| **Teleport Audit Events** | 审计事件与**会话录制分离**：事件里放 `session_id` 指针，正文在录制文件中；事件按 `session.*` 逻辑分组 |
| **asciicast v2** | JSONL（NDJSON）+ 首行 header：可增量追加、崩溃不丢、天然流式友好 —— 作为文件格式选型依据 |
| **MaxMind GeoLite2 / Logstash geoip** | 离线 IP→地理库，输出直接落 ECS `source.geo.*`，无需外呼 |

---

## 2. 文件形态

```
~/.fleetview/
├── fleetview.log              # 保留：非结构化 debug（状态启发式调参），可随时删
├── remote.log                 # 保留：ttyd/tmux 子进程 stdout
└── logs/
    ├── audit-2026-07-27.jsonl # 审计日志（本规范），按天切分
    ├── audit-2026-07-26.jsonl.gz
    └── sessions/              # 可选：asciicast v2 终端录制
        └── <terminal-uuid>/2026-07-27T21-30-02Z.cast
```

- **格式**：JSON Lines（每行一个完整 JSON 对象，UTF-8，无缩进，`\n` 结尾）。
- **首行 header**（每个新文件写一次，`event.name = "fleetview.log.opened"`）：记录 schema 版本、app 版本、主机、实例 id、时区。
- **轮转**：按天 + 单文件 64 MB 上限（`audit-2026-07-27.1.jsonl`）；次日 gzip；默认保留 **90 天**，可配置。
- **权限**：目录 `0700`，文件 `0600`（日志含 IP、命令行、cwd）。
- **并发安全**：单次 `write(2)` 以 `O_APPEND` 写入，单行 **< 4096 字节**（PIPE_BUF）时 POSIX 保证原子追加 —— 这样**同时跑两个 FleetView 实例也不会串行**（你已知的"第二实例抢 hook 事件"场景，靠 `fleetview.instance.id` 区分来源）。超长行必须先截断再写（见 §6 规则 6）。
- 每行只允许一次 `write`，不允许分段写。

---

## 3. 事件信封（Envelope）

所有记录共享同一外壳。ECS 字段用点分名（ECS 允许点分/嵌套等价），FleetView 私有字段统一挂在 `fleetview` 下。

```json
{
  "@timestamp": "2026-07-27T21:47:03.512+02:00",
  "ecs.version": "8.11.0",
  "event.id": "01K3M9F6V2QJ8ZC1A0YB7RTX4N",
  "event.sequence": 10482,
  "event.name": "fleetview.terminal.created",
  "event.kind": "event",
  "event.category": ["process"],
  "event.type": ["creation"],
  "event.action": "terminal-create",
  "event.outcome": "success",
  "event.duration": 12000000,
  "event.dataset": "fleetview.audit",
  "event.module": "fleetview",
  "message": "terminal \"api-refactor\" created in project FleetView",

  "service.name": "FleetView",
  "service.version": "1.4.2 (build 318)",
  "service.node.name": "fv-7f3a",
  "host.name": "puzhen-mbp.local",
  "host.os.version": "15.3.0",
  "process.pid": 4711,

  "fleetview.schema": 1,
  "fleetview.instance.id": "7f3a1c9e",
  "fleetview.actor": { … },      // §4.1
  "fleetview.target": { … },     // §4.2
  "fleetview.trace": { … },      // §9
  "fleetview.data": { … }        // 事件专有字段，见 §5
}
```

**字段约定**
- `event.id`：ULID（单调、可排序、26 字符）。
- `event.sequence`：进程内单调递增，用于同毫秒排序与丢失检测。
- `@timestamp`：**带时区偏移**的 ISO 8601，毫秒精度（不要用裸 UTC，跨时区排障时本地时间有意义）。
- `event.duration`：纳秒（ECS 规定），仅耗时类事件带。
- `message`：给人看的一句话；机器只读结构化字段。可选但强烈建议（`jq -r .message` 就是一份可读流水账）。
- 未知/不适用字段一律**省略**，不写 `null`。

---

## 4. 主体与资源模型

### 4.1 `fleetview.actor` —— 谁做的

```json
"fleetview.actor": {
  "type": "web",                        // desktop | web | cli | agent | shell | system
  "id": "ws_01K3M8...",                 // web session id / cli pid / agent session id
  "name": "iPhone · Safari",            // 可读别名
  "user.name": "puzhen",                // 本机用户（NSUserName）
  "cli.tool": "project-manager",        // type=cli 时
  "agent.kind": "claude"                // type=agent 时：claude | codex
}
```
- `desktop`：macOS 界面上的直接操作
- `web`：浏览器（携带 §7 的 IP/UA/geo）
- `cli`：`fleetctl` / `scripts/project-manager` / `scripts/fleet-monitor` / `auto-continue-stalled.sh`
- `agent`：Claude/Codex 的 hook 上报
- `shell`：zsh `preexec/precmd` 上报
- `system`：应用自身（定时器、崩溃恢复、自动重连）

### 4.2 `fleetview.target` —— 对谁做的

**同时带 uuid 和名称**：uuid 保证可关联，名称保证日志可读（改名事件本身会记录 from/to，因此不算重复）。

```json
"fleetview.target": {
  "kind": "terminal",                                     // project|terminal|cluster|note|panel|web_session|app
  "terminal.id": "3F2A9C4E-....",
  "terminal.name": "api-refactor",
  "terminal.cwd": "/Users/puzhen/PycharmProjects/FleetView",
  "terminal.status": "working",
  "terminal.agent": "claude",
  "terminal.auto_run_claude": true,
  "terminal.tmux_session": "fv-3f2a9c4e",
  "cluster.id": "9B1D...",       // 无 cluster 时整键省略
  "cluster.name": "refactor-swarm",
  "project.id": "A77C...",
  "project.name": "FleetView",
  "project.path": "/Users/puzhen/PycharmProjects/FleetView",
  "project.is_git": true
}
```
> **cluster 的表达**：`cluster.id` 缺席 = 独立终端；存在 = 属于该 cluster。入/离簇是独立事件（§5.4），不靠对比快照推断。

---

## 5. 事件目录

`event.name` 一律 `fleetview.<域>.<动作>`，全小写点分。下表 **Lv** 列为 Kubernetes 风格的默认记录级别：
`M`=Metadata（只记元数据）、`C`=Content（含内容，受 §6/§8 约束）、`R`=Rollup（聚合后落盘）、`—`=默认关闭。

### 5.1 应用与服务

| event.name | Lv | `fleetview.data` 关键字段 |
|---|---|---|
| `fleetview.log.opened` | M | `schema`, `rotated_from`, `tz` |
| `fleetview.app.started` | M | `version`, `build`, `os`, `instance_id`, `pid`, `state_terminals`, `state_projects`, `launch_source` |
| `fleetview.app.stopped` | M | `reason`(quit/crash/signal), `uptime_ms` |
| `fleetview.webserver.started` | M | `port`, `bind`, `urls[]`（LAN / Tailscale） |
| `fleetview.webserver.stopped` | M | `reason` |
| `fleetview.ttyd.started` | M | `terminal.id`, `port`, `pid`, `writable`, `tmux_session` |
| `fleetview.ttyd.stopped` | M | `terminal.id`, `port`, `exit_code`, `uptime_ms` |
| `fleetview.integration.installed` | M | `target`(claude/codex/zsh), `path`, `events[]` |
| `fleetview.integration.removed` | M | `target`, `path` |
| `fleetview.state.saved` | — | 默认关闭（每次改动都会触发，纯噪声） |
| `fleetview.error` | M | `error.type`, `error.message`, `component`；`event.kind="alert"` |

### 5.2 Project

| event.name | Lv | 字段 |
|---|---|---|
| `fleetview.project.added` | M | target.project.*；`source`(ui/web/cli) |
| `fleetview.project.removed` | M | `cascade.terminals`, `cascade.clusters` |
| `fleetview.project.revealed` | M | Finder 打开 |

### 5.3 Terminal（**用户最关心的一块**）

| event.name | Lv | `fleetview.data` |
|---|---|---|
| `fleetview.terminal.created` | M | `origin`: `ui` \| `web` \| `cli` \| `duplicate` \| `restore`；`duplicate_of`(uuid)；`name_source`: `auto`\|`user`；`cwd`, `auto_run_claude`, `cluster.id`, `tmux_session`, `window.id` |
| `fleetview.terminal.opened` | M | `mode`: `new_window` \| `reopen` \| `reattach`；`tmux_session`, `window.id` |
| `fleetview.terminal.raised` | M | 点击卡片 / Raise 按钮把窗口提到最前；`origin`: `card_tap`\|`raise_button`；`was_open`(bool)。⚠️ 它**不** bump `lastActivity`（保持现有语义），但"什么时候点了哪个终端"是审计事实，必须记 —— 见 §5.10 |
| `fleetview.terminal.renamed` | M | `name.from`, `name.to` |
| `fleetview.terminal.duplicated` | M | `from.id`, `to.id`, `to.name` |
| `fleetview.terminal.removed` | M | `reason`: `user` \| `project_removed` \| `window_closed`；`lifetime_ms`, `tokens_total`, `commands_run` |
| `fleetview.terminal.window_closed` | M | `exit_code`, `tmux_alive`(bool) |
| `fleetview.terminal.status_changed` | M | `status.from`, `status.to`, `trigger`: `hook`\|`shell`\|`interrupt`\|`window`\|`poll`\|`web`；`hook.event` |
| `fleetview.terminal.done_toggled` | M | `done`(bool) |
| `fleetview.terminal.interrupted` | M | Esc 打断（`handleInterrupt`） |
| `fleetview.terminal.transcript_bound` | M | `transcript.path`, `agent.kind`, `session.id`, `resolved_by`: `hook`\|`fallback_scan`（fallback 命中值得审计） |

### 5.4 Cluster

| event.name | Lv | 字段 |
|---|---|---|
| `fleetview.cluster.created` | M | `cluster.id`, `cluster.name`, `seed_terminals[]` |
| `fleetview.cluster.renamed` | M | `name.from`, `name.to` |
| `fleetview.cluster.removed` | M | `reason`: `user`\|`empty_pruned`，`members_at_removal` |
| `fleetview.cluster.member_added` | M | `terminal.id`, `member_count` |
| `fleetview.cluster.member_removed` | M | `terminal.id`, `member_count` |

### 5.5 Agent 会话（**只记事实与指针，正文不进日志**）

| event.name | Lv | 字段 |
|---|---|---|
| `fleetview.agent.session_started` | M | `agent.kind`, `session.id`, `source`: startup\|resume\|compact\|clear；`transcript.path`, `transcript.size_at_start`, `transcript.inode` |
| `fleetview.agent.prompt_submitted` | C | `prompt.chars`, `prompt.lines`, `prompt.sha256`, `prompt.preview`(≤120 字符，可关)，`transcript.line`（正文所在行号，`—` 表示未知） |
| `fleetview.agent.permission_requested` | M | `message`（hook 原文，≤200 字符）、`source`: notification\|permission_request |
| `fleetview.agent.tool_requested` | — | 默认关闭（transcript 已全量记录）；开启后仅记 `tool.name`，不记参数 |
| `fleetview.agent.turn_finished` | M | `turn.duration_ms`, `tokens.delta.{input,output,cache_write}`, `tokens.new_total`, `context.used`, `model` |
| `fleetview.agent.session_ended` | M | `reason`, `turns`, `tokens.new_total`, `duration_ms` |

> **为什么 prompt 还要留一条**：日志需要"某时刻有人向该终端下达了指令"这一**审计事实**（谁下的、从哪个入口下的），transcript 只知道"有这句话"，不知道是桌面端还是手机 Web 下的、来自哪个 IP。因此记录**事实 + 元数据 + 指针**，正文留在 transcript。`prompt.preview` 是可读性妥协，默认可关（§8）。

### 5.6 Shell 命令（**要完整记录**）

两条一组，共享 `cmd.id`，由 zsh `preexec` / `precmd` 上报：

| event.name | Lv | 字段 |
|---|---|---|
| `fleetview.shell.command_started` | C | `cmd.id`, `cmd.line`(脱敏后), `cmd.argv0`, `cmd.cwd`, `cmd.shell`, `cmd.pid`, `cmd.tty`, `cmd.redacted`(bool), `cmd.truncated`(bool) |
| `fleetview.shell.command_finished` | M | `cmd.id`, `cmd.exit_code`, `cmd.duration_ms`, `cmd.signal` |

`event.category=["process"]`，`event.type=["start"]/["end"]`，`event.outcome` 由 exit_code 推导。
ECS 兼容可另填 `process.command_line` / `process.working_directory` / `process.exit_code`。

**现状差距**：`ShellIntegration.swift:62` 的 `fleetview_preexec` 目前只上报命令行、且过滤掉 `claude`。需补：`precmd` 钩子取 `$?` 与耗时、cwd、`$$`、tty；`codex`/`claude` 命令**仍应记录一条 `command_started`**（它是"启动 agent"这一操作本身，与 agent 对话内容不重复）。

### 5.7 Web / 远程访问（**含地理位置**）

| event.name | Lv | 字段 |
|---|---|---|
| `fleetview.web.session_started` | M | `web.session.id`, `source.ip`, `source.port`, `source.scope`(§7), `user_agent.*`, `client.geo.*`, `http.request.referrer`, `first_path` |
| `fleetview.web.session_geo` | M | 浏览器授权后的精确定位（§7c）：`client.geo.location.{lat,lon}`, `accuracy_m`, `consent`:`granted` |
| `fleetview.web.session_activity` | R | 每 5 min 或会话结束时汇总：`window_s`, `requests.total`, `requests.by_path{}`, `bytes_out`, `errors` |
| `fleetview.web.session_ended` | M | `duration_ms`, `requests.total`, `end_reason`: `idle_timeout`\|`server_stop` |
| `fleetview.web.terminal_attached` | M | `terminal.id`, `ttyd.port`, `ttyd.url`, `web.session.id` |
| `fleetview.web.input_sent` | C | `/type`：`text.chars`, `text.sha256`, `enter`(bool), `text.preview`(可关) |
| `fleetview.web.key_sent` | R | `/key`：10 s 窗口聚合 `{"Enter":1,"Up":6,"Escape":1}`；`Escape`/`Ctrl-C` 等控制键**单独立即记录** |
| `fleetview.web.action` | M | `/action`：`action`(done/duplicate/remove/leaveCluster/rename) + 参数；同时会触发对应 §5.3 事件（用 `trace.id` 串起来，不重复记内容） |
| `fleetview.web.ask` | C | `/ask`：`question.chars/sha256/preview`, `answer.chars`, `duration_ms`, `agent.kind`（旁路提问不入 transcript，**必须**记录，否则无处可查） |
| `fleetview.web.note_changed` | C | `/note`：`op`(add/del), `note.id`, `note.text`(短，直接记) |
| `fleetview.web.request_denied` | M | `event.kind="alert"`：401/403/坏参数/未知路径；`http.response.status_code`, `path` |

**明确不逐条记录的读端点**（只进 `session_activity` 计数）：`/state`（1.5 s 轮询）、`/panel-meta`（1.5 s）、`/panel-data`、`/conversation`（3 s）、`/capture`、`/`、`/panel`。
> 依据 Kubernetes audit 的 "ignore high-frequency, low-value read requests"。一个挂机 30 分钟的手机页面 = 约 2400 次 `/state`，逐条记录会把日志淹掉且零信息量。

### 5.8 Dynamic Panel（版本归档，完整设计见 §14）

| event.name | Lv | `fleetview.data` 关键字段 |
|---|---|---|
| `fleetview.panel.version_created` | M | `panel.uuid`(UUIDv7)、`panel.sha256`、`panel.bytes`、`panel.title`、`panel.prev_uuid`、`panel.derived_from`（回滚时指向被恢复的版本）、`capture.method`、`attribution.*`（§14.4：`agent.session.id` + `transcript.path` + `tool.name`） |
| `fleetview.panel.activated` | M | `panel.uuid`、`mode`: `latest`\|`pinned`\|`rollback`、`prev_uuid`、`actor`（谁切的） |
| `fleetview.panel.removed` | M | 被删的当前 `panel.uuid`、`versions_retained`（历史**不删**） |
| `fleetview.panel.unchanged` | — | 内容 sha256 相同的重写；默认关闭，只更新 index 的 `last_seen`（§6 规则 1） |
| `fleetview.panel.data_written` | R | `panel.json` 高频写，按 5 min 聚合计数，**不逐次记录** |
| `fleetview.panel.viewed` | R | `/panel?v=<uuid>` 查看历史版本，按 web 会话聚合 |
| `fleetview.panel.capture_failed` | M | `event.kind="alert"`：截断/空文件/写入竞争（§14.3） |
| `fleetview.panel.pruned` | M | 仅当显式配置了归档上限时才可能发生 |

`event.category=["configuration"]`，`fleetview.target.kind="panel"`，`fleetview.target.panel.uuid=<版本 uuid>`。

### 5.9 CLI 操作
`scripts/project-manager`、`scripts/fleet-monitor`、`auto-continue-stalled.sh` 走的是同一套 HTTP 端点，因此**自动落在 5.7**，只是 `actor.type="cli"`（靠 `User-Agent: fleetctl/<tool>/<version>` 与 `X-FleetView-Actor` 头识别）。建议给这三个脚本统一加上该 UA —— 否则它们会被记成匿名 web 客户端。

### 5.10 UI 交互（点击 / 选中 / 拖拽）

> 回答"**什么时候点了哪个终端**"。全部遵循 §6 规则 2（只记跃迁）：点击**已经选中**的对象不产生新行；同一对象 2 s 内的重复点击折叠为一条（`repeat_count`）。

| event.name | Lv | 触发点（当前行号） | `fleetview.data` |
|---|---|---|---|
| `fleetview.ui.task_selected` | M | 侧栏任务行点击 `Dashboard.swift:252` → `focusTask` | `target.kind`: `terminal`\|`cluster`；`selection.from`(上一个选中的 uuid)；`dwell_ms`(上一项停留时长)；`surface`:`sidebar` |
| `fleetview.terminal.raised` | M | 卡片点击 `TerminalCardView.swift:40`、Raise 按钮 `:149` | 见 §5.3 |
| `fleetview.terminal.opened` | M | Reopen 按钮 `TerminalCardView.swift:151` | `mode`:`reopen` |
| `fleetview.ui.project_selected` | M | 项目切换（`selectedProjectId`，`AppState.swift:11`） | `project.id/name`、`from`（`null` = All Projects） |
| `fleetview.ui.terminal_dragged` | M | 拖拽到动作区 `AppState.swift:420 dragEnded` / `:434 perform` | `zone`、`dropped`(bool，中途取消也记)、`duration_ms` |
| `fleetview.ui.remote_revealed` | M | 卡片上点地球图标要 web 地址 `TerminalCardView.swift:154` | `ttyd.url`、`ttyd.port` |
| `fleetview.web.terminal_selected` | M | Web 点开终端卡片 `WebDashboardPage.swift:289 openTerm` | `view`:`chat`\|`term`、`selection.from`、`web.session.id` |
| `fleetview.web.terminal_deselected` | M | Web 返回列表 `WebDashboardPage.swift:300 closeTerm` | `dwell_ms` |
| `fleetview.ui.view_switched` | R | Chat/Terminal 标签切换 `setView` | 按 web 会话聚合计数 |
| `fleetview.ui.app_focus` | — | 应用前后台切换；默认关（噪声大、价值低） |

**桌面端与 Web 端语义不同，必须分成两个事件**：
- 桌面**侧栏**点击 = 只高亮+滚动定位，不动窗口（代码注释写得很清楚："highlight + scroll, do not raise the window"）→ `ui.task_selected`
- 桌面**卡片**点击 = 把真实终端窗口提到最前 → `terminal.raised`
- Web**卡片**点击 = 开始观看该终端的 chat/terminal 视图 → `web.terminal_selected`，与配对的 `deselected.dwell_ms` 一起，能直接回答"我今天的注意力花在哪个终端上"

**Web 端需要加一个显式信标**：卡片点击目前纯前端切视图（`openTerm`），服务端完全看不到。新增 `GET /select?id=<uuid>&view=chat`（空 id = 取消选择），在 `openTerm` / `closeTerm` / `setView` 各调一次。
**不要**用"`/conversation` 首次出现"去反推选中 —— 那是 3 s 轮询端点，语义会随轮询策略漂移，且违反 §6 规则 4（单一写入点）。

---

## 6. 去重与降噪规则（"全记录但不重复"的硬约束）

1. **引用而非拷贝（Reference, don't copy）**
   任何已存在于 transcript / 录制文件 / 状态文件中的正文，日志只写 `{path, session_id, line/offset, bytes, sha256}`。这是 Teleport 审计事件与会话录制分离的做法。
2. **只记跃迁，不记状态**
   `status_changed` 只在 `from != to` 时写；轮询发现的"仍然是 working"永不落盘。
3. **高频动作先聚合再落盘**
   Web 轮询、按键流按窗口聚合（`session_activity` / `key_sent`）。聚合窗口内没有事件就不写行。
4. **单一写入点（Single writer per fact）**
   每个事实只在**一个**代码位置发出：
   - 终端增删改 → 只在 `AppState` 的 mutation 函数里发（不要在 UI 回调和 Web 路由里各发一次）
   - shell 命令 → 只信 zsh hook（**不要**再从 tmux capture 里解析一遍）
   - token → 只在 `turn_finished` 由 `TokenUsage` 发一次增量
   - Web 请求触发的资源变更 → `web.action` 记"入口"，资源事件记"结果"，两者用 `trace.id` 关联，字段不互相复制
5. **幂等键**
   每行带 `event.id`（ULID）；对可能重放的来源（events 目录扫描、崩溃恢复）额外带 `fleetview.dedupe_key = sha256(event.name + target.id + 触发源时间戳)`，消费端可去重。
6. **大小上限**
   单个字符串字段 ≤ 2 KB，单行 ≤ 4 KB。超出则截断并置 `*.truncated=true` + `*.sha256`（原文可在 transcript 找到）。
7. **不记录可派生量**
   如 "idle 秒数"、"working 数量"、"是否 done 的聚合" —— 这些能从事件流重放出来，写进日志只是冗余。

---

## 7. 地理位置采集方案

FleetView 的 Web 端主要跑在 **LAN / Tailscale**，直接对 `192.168.x.x` 做 GeoIP 是无意义的。分四路，按可得性降级：

**a) 先给 IP 分类（永远可得）**
```json
"source.ip": "100.101.7.23",
"source.port": 51544,
"fleetview.web.scope": "tailscale",   // loopback | lan | tailscale | public | unknown
"network.type": "ipv4"
```
判定：`127.0.0.0/8`→loopback；`10/8 172.16/12 192.168/16 fe80::/10`→lan；`100.64.0.0/10`(CGNAT) 且 tailscaled 在跑→tailscale；其余→public。

**b) Tailscale 身份（比 GeoIP 准得多）**
`tailscale status --json` 可把对端 IP 映射到节点名、登录用户、OS、DERP 中继区域（`region: fra` ≈ 法兰克福）。落：
```json
"fleetview.web.peer": { "tailnet_node": "iphone-puzhen", "user": "puzhen@github", "os": "iOS", "derp_region": "fra" }
```
缓存 60 s，避免每次请求 fork 子进程。

**c) 公网 IP → GeoIP（离线优先）**
- 优先内置 **MaxMind GeoLite2-City** `.mmdb`（本地查表，零外呼、零隐私外泄，Logstash geoip 同款数据源）。
- 无 mmdb 时可选在线 API（`ipinfo.io` / `ip-api.com`），**必须**：结果按 IP 缓存 24 h、失败静默、可配置关闭（默认关闭，因为这会把访问者 IP 发给第三方）。
- 对 LAN 客户端另记一次**本机出口公网 IP** 的 geo（每小时一次，作为 `fleetview.host.geo`），用于"这台 Mac 当时在哪个城市"。
- 落 ECS：
```json
"client.geo.country_iso_code": "DE",
"client.geo.region_name": "Bavaria",
"client.geo.city_name": "Munich",
"client.geo.location": { "lat": 48.14, "lon": 11.58 },
"client.geo.timezone": "Europe/Berlin",
"client.as.number": 553, "client.as.organization": "Leibniz-Rechenzentrum"
```

**d) 浏览器精确定位（可选，需用户授权）**
⚠️ **关键约束**：`navigator.geolocation` 只在 **secure context** 下可用。现在 Web 端是 `http://<LAN-IP>:8080`，Chrome/Safari 会**直接拒绝**。要用必须满足其一：
- `tailscale serve` / `tailscale funnel` 提供的真实 HTTPS 证书（推荐，零配置 TLS）；
- 自签证书 + 手动信任；
- 从 `localhost` 访问。

满足后，页面在**首次访问且用户点了"允许"**时 `POST /geo`，服务端落一条 `web.session_geo`，坐标默认**截断到 2 位小数（≈1 km）**，`accuracy_m` 一并记录。未授权则不写该事件（不记 `denied` 也可，避免噪声——建议记一条 `consent: "denied"` 便于解释日志里为何没有精确坐标）。

**兜底可读字段**：`Accept-Language`（如 `zh-CN,de-DE`）与 `Intl.DateTimeFormat().resolvedOptions().timeZone`（如 `Europe/Berlin`）—— 在纯 LAN 场景下，时区往往比 GeoIP 更能说明"人在哪"。

---

## 8. 隐私、脱敏与保留

**配置项**（建议放 `~/.fleetview/logging.json`，热加载）：
```json
{
  "enabled": true,
  "level": "standard",          // minimal | standard | verbose
  "content": {
    "prompt_preview": true,     // 关掉则只留 sha256 + 长度
    "prompt_preview_chars": 120,
    "shell_command": "full",    // full | argv0_only | off
    "web_input_preview": false
  },
  "geo": { "mode": "city", "provider": "geolite2", "precision_decimals": 2 },
  "privacy": { "hash_ip_after_days": 7, "ip_salt": "<random>" },
  "retention": { "days": 90, "max_total_mb": 512 },
  "redact": ["(?i)(api[_-]?key|token|secret|password|passwd|authorization)\\s*[=:]\\s*\\S+"]
}
```

**shell 命令脱敏（必做）**：命令行里常有密钥。默认规则替换为 `***`：
- `KEY=value` 形式：`(API_KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL)\w*=\S+`
- `--password X` / `-p X` / `--token X`
- `curl -H "Authorization: ..."`、`-u user:pass`
- `echo '...' | base64` 类不处理（无法判定），靠 `level: argv0_only` 兜底
命中时置 `cmd.redacted: true`，便于事后知道"这条被改过"。

**IP**：ECS 的 `source.ip` 在 GDPR 下属个人数据。提供 `hash_ip_after_days` —— 到期后轮转任务把历史文件中的 IP 换成 `sha256(salt+ip)[0:16]` 写入 `source.ip_hash`，保留可关联性、去除可识别性。城市级 geo 通常不构成个人数据，可长期保留。

**永不记录**：文件内容、diff 正文、环境变量全集、`.env` 内容、Claude/Codex 的 API key、transcript 正文。

---

## 9. 关联 id 与追踪链

| 字段 | 含义 |
|---|---|
| `fleetview.trace.id` | 一次用户意图的全链路 id：Web 点击 → HTTP 请求 → AppState 变更 → tmux 注入 → hook 回报，全部同一个 |
| `fleetview.trace.parent` | 上游 `event.id` |
| `fleetview.trace.request_id` | 单次 HTTP 请求 |
| `fleetview.web.session.id` | 浏览器会话（cookie `fv_ws`，SameSite=Lax，30 min idle 过期） |
| `fleetview.target.terminal.id` | 终端 uuid（贯穿一切） |
| `fleetview.agent.session.id` | Claude/Codex 会话 id（= transcript 文件名） |
| `fleetview.cmd.id` | 一条 shell 命令的 start/finish 配对 |

有了这套，`jq 'select(.fleetview.trace.id=="…")'` 就能还原"手机上点了个按钮 → 终端里跑了什么 → agent 花了多少 token"的完整因果链。

---

## 10. 示例流（真实场景，10 行）

```jsonl
{"@timestamp":"2026-07-27T09:12:00.104+02:00","event.name":"fleetview.app.started","event.kind":"event","event.category":["configuration"],"event.action":"app-start","event.outcome":"success","service.name":"FleetView","service.version":"1.4.2","host.name":"puzhen-mbp.local","process.pid":4711,"fleetview.schema":1,"fleetview.instance.id":"7f3a1c9e","fleetview.actor":{"type":"system","user.name":"puzhen"},"fleetview.data":{"state_projects":3,"state_terminals":7,"launch_source":"login_item"},"message":"FleetView 1.4.2 started (7 terminals restored)"}
{"@timestamp":"2026-07-27T09:12:00.331+02:00","event.name":"fleetview.webserver.started","event.kind":"event","event.category":["network"],"event.action":"listen","event.outcome":"success","fleetview.instance.id":"7f3a1c9e","fleetview.actor":{"type":"system"},"fleetview.data":{"port":8080,"bind":"0.0.0.0","urls":["http://192.168.1.24:8080/","http://100.101.7.11:8080/"]},"message":"web dashboard on :8080"}
{"@timestamp":"2026-07-27T09:13:41.882+02:00","event.name":"fleetview.terminal.created","event.kind":"event","event.category":["process"],"event.type":["creation"],"event.action":"terminal-create","event.outcome":"success","event.id":"01K3M9F6V2QJ8ZC1A0YB7RTX4N","fleetview.actor":{"type":"desktop","user.name":"puzhen"},"fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-1B77-4E0A-9C21-5D9A2C7E0B11","terminal.name":"api-refactor","terminal.cwd":"/Users/puzhen/PycharmProjects/FleetView","cluster.id":"9B1D2A55-...","cluster.name":"refactor-swarm","project.id":"A77C...","project.name":"FleetView"},"fleetview.data":{"origin":"ui","name_source":"user","auto_run_claude":true,"tmux_session":"fv-3f2a9c4e"},"message":"terminal \"api-refactor\" created in cluster refactor-swarm"}
{"@timestamp":"2026-07-27T09:13:44.019+02:00","event.name":"fleetview.agent.session_started","event.kind":"event","event.category":["session"],"event.action":"agent-session-start","fleetview.actor":{"type":"agent","agent.kind":"claude","id":"24fc7a41-be45-4f4e-87a4-42ef79186e51"},"fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-...","terminal.name":"api-refactor"},"fleetview.data":{"source":"startup","transcript.path":"/Users/puzhen/.claude/projects/-Users-puzhen-PycharmProjects-FleetView/24fc7a41-....jsonl","transcript.size_at_start":0},"message":"claude session started (transcript bound)"}
{"@timestamp":"2026-07-27T09:14:02.556+02:00","event.name":"fleetview.agent.prompt_submitted","event.kind":"event","event.category":["session"],"event.action":"prompt-submit","fleetview.actor":{"type":"desktop"},"fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-...","terminal.name":"api-refactor"},"fleetview.data":{"agent.session.id":"24fc7a41-...","prompt.chars":142,"prompt.lines":3,"prompt.sha256":"9f2c…","prompt.preview":"把 WebServer 的路由拆成独立文件，并补上 client IP 提取","transcript.line":1},"message":"prompt submitted (142 chars) — body in transcript"}
{"@timestamp":"2026-07-27T09:16:31.204+02:00","event.name":"fleetview.agent.turn_finished","event.kind":"event","event.category":["session"],"event.action":"turn-end","event.duration":148648000000,"fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-...","terminal.name":"api-refactor"},"fleetview.data":{"tokens.delta":{"input":3120,"output":1844,"cache_write":9021},"tokens.new_total":214883,"model":"claude-opus-5","context.used":38211},"message":"turn finished in 2m28s (+13,985 new tokens)"}
{"@timestamp":"2026-07-27T09:17:05.771+02:00","event.name":"fleetview.shell.command_started","event.kind":"event","event.category":["process"],"event.type":["start"],"event.action":"shell-exec","fleetview.actor":{"type":"shell","user.name":"puzhen"},"fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-...","terminal.name":"api-refactor"},"fleetview.data":{"cmd.id":"c_01K3MA2","cmd.line":"swift build -c release","cmd.argv0":"swift","cmd.cwd":"/Users/puzhen/PycharmProjects/FleetView","cmd.shell":"zsh","cmd.pid":50122,"cmd.tty":"/dev/ttys014","cmd.redacted":false},"message":"$ swift build -c release"}
{"@timestamp":"2026-07-27T09:17:49.113+02:00","event.name":"fleetview.shell.command_finished","event.kind":"event","event.category":["process"],"event.type":["end"],"event.outcome":"success","event.duration":43342000000,"fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-..."},"fleetview.data":{"cmd.id":"c_01K3MA2","cmd.exit_code":0,"cmd.duration_ms":43342},"message":"swift build exited 0 in 43.3s"}
{"@timestamp":"2026-07-27T14:02:11.443+02:00","event.name":"fleetview.web.session_started","event.kind":"event","event.category":["authentication","web"],"event.action":"web-session-start","fleetview.actor":{"type":"web","id":"ws_01K3MC7X","name":"iPhone · Safari"},"source.ip":"100.101.7.23","source.port":51544,"user_agent.original":"Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) …","user_agent.os.name":"iOS","user_agent.name":"Mobile Safari","client.geo.country_iso_code":"DE","client.geo.city_name":"Munich","client.geo.timezone":"Europe/Berlin","client.geo.location":{"lat":48.14,"lon":11.58},"fleetview.web":{"scope":"tailscale","peer":{"tailnet_node":"iphone-puzhen","user":"puzhen@github","os":"iOS","derp_region":"fra"},"accept_language":"zh-CN,de-DE","geo_source":"tailscale_derp+headers"},"fleetview.data":{"first_path":"/"},"message":"web session from iphone-puzhen (Munich, DE) via tailscale"}
{"@timestamp":"2026-07-27T14:02:19.907+02:00","event.name":"fleetview.web.terminal_attached","event.kind":"event","event.category":["session"],"event.action":"terminal-attach","fleetview.actor":{"type":"web","id":"ws_01K3MC7X"},"source.ip":"100.101.7.23","fleetview.target":{"kind":"terminal","terminal.id":"3F2A9C4E-...","terminal.name":"api-refactor"},"fleetview.trace":{"id":"tr_01K3MC81","request_id":"rq_9f21"},"fleetview.data":{"ttyd.port":7681,"tmux_session":"fv-3f2a9c4e"},"message":"iPhone attached to \"api-refactor\""}
```

`jq -r '"\(.["@timestamp"][11:19])  \(.["fleetview.actor"].type|.[0:7]|. + "       "|.[0:7])  \(.message)"'` 即可得到一份可读流水账。

---

## 11. 在本代码库的落地点

**新增** `Sources/FleetView/Log/AuditLog.swift`：

```swift
enum AuditLog {
    /// 线程安全的追加写；单行 <4KB，O_APPEND 原子写，多实例共享同一文件也不串行。
    static func emit(_ name: String,
                     actor: Actor,
                     target: Target? = nil,
                     outcome: Outcome = .success,
                     trace: Trace? = nil,
                     data: [String: Any] = [:])
}
```
- 内部串行 `DispatchQueue`（`qos: .utility`）+ 小缓冲（≤50 ms 或 8 KB flush），失败静默（日志永远不能拖垮 UI）。
- `Target` 从 `TerminalSession` 一次性投影出 uuid/name/cwd/cluster/project，避免每个调用点手拼。

**插桩位置**（当前行号）：

| 位置 | 发出的事件 |
|---|---|
| `AppState.swift:122 addProject` / `:137 removeProject` | `project.added` / `project.removed` |
| `:147 newTerminal` | `terminal.created` |
| `:160 reopenTerminal` / `:172 reconnectLiveTerminals` / `:856 openWindow` | `terminal.opened` (`mode`) |
| `:190 duplicateTerminal` | `terminal.duplicated` + `terminal.created` |
| `:208 removeTerminal` | `terminal.removed` |
| `:220 renameTerminal` / `:235 renameCluster` | `*.renamed` |
| `:227 toggleSubtaskDone` | `terminal.done_toggled` |
| `:242 removeFromCluster` / `:250 addToCluster` / `:889 pruneClusters` | `cluster.member_*` / `cluster.removed` |
| `:322/:330/:337 note*` | `web.note_changed`（actor 区分 ui/web） |
| `:444 setStatus` | `terminal.status_changed`（**只在 from≠to 时**；这是唯一的状态事件出口） |
| `:451 handleInterrupt` | `terminal.interrupted` |
| `:460 handleHookEvent` | `agent.*` 系列；替换掉现有 `FV.log("evt=…")` |
| `:809 webAction` / `:642 webResponse` | `web.action` / `web.input_sent` / `web.ask` |
| `:848 webOpenTerminal` | `web.terminal_attached` |
| `:877 handleWindowClosed` | `terminal.window_closed` |
| `RemoteServer.swift:106 endpoint` / `:251 stop` | `ttyd.started` / `ttyd.stopped` |
| `WebServer.swift:81 route` | web 会话跟踪 + `web.request_denied` |
| `HookInstaller` / `CodexHookInstaller` / `ShellIntegration.install` | `integration.installed/removed` |
| `Dashboard.swift:252`（侧栏行点击）→ `AppState.swift:307 focusTask` | `ui.task_selected` |
| `TerminalCardView.swift:40`（卡片点击）/ `:149` / `:151` / `:154` | `terminal.raised` / `terminal.opened` / `ui.remote_revealed` |
| `AppState.swift:414 dragChanged` / `:420 dragEnded` / `:434 perform` | `ui.terminal_dragged` |
| `AppState.swift:61 refreshPanel` → 新 `PanelVersions.capture` | `panel.version_created` / `panel.activated` / `panel.removed`（§14） |
| `WebDashboardPage.swift:289 openTerm` / `:300 closeTerm` → 新 `/select` | `web.terminal_selected` / `web.terminal_deselected` |

**需要先补的能力**：
1. **`WebServer` 目前拿不到客户端 IP 和请求头** —— `route(_:header:)` 只解析了请求行（`WebServer.swift:81`）。需要：
   - 从 `NWConnection.currentPath?.remoteEndpoint`（或 `conn.endpoint`）取 `host:port`；
   - 把已经读到的 header 块解析成字典，取 `User-Agent` / `Cookie` / `Accept-Language` / `X-Forwarded-For`；
   - 无 `fv_ws` cookie 时下发一个（`Set-Cookie: fv_ws=…; Path=/; Max-Age=2592000; SameSite=Lax`），这是 web 会话聚合的基础。
2. **zsh 集成补 `precmd`**（`ShellIntegration.swift:62`）：记录退出码、耗时、cwd、tty，并给 `claude`/`codex` 也发 `command_started`。
3. **`EventWatcher.Event` 增字段**（`EventWatcher.swift:8`）：`cmd_id`、`exit_code`、`duration_ms`、`cwd`、**`tool_name` / `tool_input`**（后两个是 panel 归因的关键，见 §14.4；hook 脚本无需改动）。
4. `FV.log`（`Paths.swift:24`）保持不动，作为 debug 日志；审计日志走新模块。
5. **Web 端新增 `GET /select`**（§5.10）——否则"在手机上点开了哪个终端"服务端不可见。
6. **Panel 版本化模块**（§14）：`Paths.swift` 加 `panelVersionsDir` / `panelIndex` / `panelCurrent`；新增 `Sources/FleetView/UI/PanelVersions.swift`。

---

## 12. ECS 映射与外部接入

本 schema 本身即 ECS 子集，可直接被 Filebeat / Vector / Fluent Bit / Loki 采集，无需转换：

| 本规范 | ECS | 备注 |
|---|---|---|
| `@timestamp`, `event.*`, `message` | 同名 | 原生 |
| `source.ip` / `client.geo.*` / `user_agent.*` | 同名 | GeoIP processor 也可在采集端补 |
| `fleetview.data.cmd.line` | `process.command_line` | 建议双写（ECS 侧用于通用检索） |
| `fleetview.target.terminal.id` | `related.hosts` 之外的自定义 | 归入 `fleetview.*` 命名空间，符合 ECS 自定义字段规范 |

可选：`fleetview.audit.jsonl` 之外再暴露 `GET /audit?since=…&limit=…`（**必须带 token 鉴权**），让 Web 端也能查审计流水。

---

## 13. 待定选项（需要你拍板）

1. **`prompt.preview` / `web_input_preview` 默认开还是关**：开了日志可读性大增，但与 transcript 有轻微重叠（120 字符）。建议 prompt 开、web input 关。
2. **地理位置精度**：默认 `city`（离线 GeoLite2，零外呼）；要精确坐标必须先给 Web 端上 HTTPS（`tailscale serve` 最省事）。
3. **保留期**：默认 90 天 / 512 MB 上限。
4. **是否要 asciicast 录制**：能完整回放终端画面，但体积大且与 transcript 重叠，建议默认关、按终端手动开。
5. **Web 端是否加 token 鉴权**：目前 `/action`、`/type`、`/new`、`/ask` 全部无鉴权，只要在同一 LAN/tailnet 就能操作。有了审计日志会更明显地暴露这一点 —— 建议同期加一个共享 token。
6. **Panel 归档保留**：默认**永久**（按需求）。是否要开 `max_versions` / `max_mb` 上限（默认关）？
7. **是否顺手把 skill 的写法改成原子写**（`mv -f` 而非 `cat >`）：不改也能工作（靠 §14.3 的稳定性等待），改了更干净。

---

# §14 附录 A：Dynamic Panel 版本归档

> 需求：agent 每产出一版 panel HTML 都要**永久保留**，以 UUID 命名；FleetView 渲染**最新**的那个；日志要写清**何时、由哪个会话文件**产生。

## 14.1 目录布局

```
~/.fleetview/ui/
├── panel.html                                  # 当前版本 —— 契约不变，agent 仍然只写这里
├── panel.json                                  # 当前数据（高频写，不版本化）
├── current.json                                # {"uuid":…,"since":…,"sha256":…,"mode":"latest"}
└── versions/
    ├── index.jsonl                             # 每版一行，归档自带的目录
    ├── 019820e9-4f11-7a03-9c55-8d2e1f0a7b31.html
    ├── 019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e.html
    ├── 019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e.data.json   # 可选：捕获瞬间的 panel.json 快照
    └── latest.html -> 019820f1-….html          # 可选软链，方便 shell 侧直接访问
```

**关键设计：`panel.html` 原地不动，版本是"复制出去"的。** 这样渲染路径、`/panel` 端点、skill 契约、已有的 agent 写法全部零改动，版本化是纯增量能力。

## 14.2 为什么用 UUIDv7

满足"每个 html 命名为一个 uuid"，同时 **RFC 9562 的 UUIDv7 前 48 bit 就是 Unix 毫秒时间戳**，所以：

- `ls versions/` 输出天然按时间排序；
- **"最新的 uuid" = 字典序最大的那个**，不读 index、不看 mtime 也能定位当前版本（灾难恢复友好）；
- 依然是标准 36 字符 UUID，任何工具都认。

（对比：UUIDv4 随机无序，要靠 index 才知道谁最新；ULID 有序但不是 UUID 格式。UUIDv7 两头都占。）

## 14.3 捕获流程

由 `AppState.refreshPanel()`（`AppState.swift:61`，1 s 定时）驱动：

1. 发现 `panel.html` 的 **(mtime, size) 二元组**变化；
2. **稳定性等待**：再等一拍，(mtime, size) 连续两次相同才认为写完。
   ⚠️ 必需 —— skill 教的是 `cat > ~/.fleetview/ui/panel.html <<'HTML'`，**这不是原子写**，直接读会读到半截文件，归档里就多一个坏版本；
3. **完整性快检**：非空、UTF-8 可解码、含 `</html>` 或 `</body>`（缺失只记警告不拒绝，允许 HTML 片段）。失败 → `panel.capture_failed`（`event.kind="alert"`），不产生版本；
4. **sha256 去重**：与 `current.json` 相同 → 只更新 index 的 `last_seen`，发 `panel.unchanged`（默认不落审计日志）。这一步很重要，skill 明确鼓励"简单起见就重写 panel.html"，不去重会造出一堆内容相同的版本，直接违反 §6；
5. 不同 → 生成 UUIDv7，把内容**复制**到 `versions/<uuid>.html`（可选同时快照 `panel.json`）；
6. 追加 `index.jsonl` 一行 + 重写 `current.json`（先写 `.tmp` 再 `mv -f`，原子）；
7. 发 `panel.version_created` + `panel.activated{mode:"latest"}`；
8. 全部 I/O 在后台队列（`qos: .utility`），只把 `uuid` 发回主线程驱动 WebView 重载。

## 14.4 归因：这一版是谁写的（三级降级，**全部无需 agent 配合**）

| 级别 | 方法 | `attribution.method` |
|---|---|---|
| **1 精确** | `PreToolUse` hook 的原始 payload 里**已经带着** `tool_name` + `tool_input`（`HookInstaller.swift:24` 是 `payload=$(cat)` 整体透传）。只要 `Write`/`Edit` 的 `file_path` 或 `Bash` 的 `command` 命中 `ui/panel.html`，作者就确定了 —— 而 `session_id` / `transcript_path` 就在同一个 payload 里 | `hook_tool_match` |
| **2 推断** | 捕获时刻前 10 s 内**只有一个**终端处于 `working` / 有工具活动 → 归给它 | `inferred_single_active` |
| **3 兜底** | 读 `~/.fleetview/sessions/<term>.json` —— hook 常驻写入的 term→session 绑定（`HookInstaller.swift:33`），列出全部候选 | `ambiguous`（带 `candidates[]`）/ `unknown` |

> **级别 1 需要的唯一改动**：`EventWatcher.Event`（`EventWatcher.swift:8`）多解析 `tool_name` / `tool_input` 两个字段。hook 脚本、skill、agent 写法都不用动 —— 数据本来就在管道里流着，只是现在被丢弃了。

**可选增强（把归因升级为 `declared`）**：在 skill 里加一句"写完后声明一下"，复用现成的 events 队列：

```bash
printf '{"event":"PanelUpdate","term":"%s","payload":{"title":"CI 构建监控","note":"跟踪 swift build"}}' "$FLEETVIEW_TERM_ID" \
  > ~/.fleetview/events/panel-$$.tmp && mv -f ~/.fleetview/events/panel-$$.tmp ~/.fleetview/events/panel-$$.json
```

`FLEETVIEW_TERM_ID` 在 FleetView 启动的终端里本来就有（hook 和 zsh preexec 都在用），`EventWatcher` 直接就能收。好处是还能拿到 agent 自己写的**标题和用途**，历史列表可读性大增。**子 agent 写的 panel** 会归到父终端/父会话上 —— 这是对的，因为它们共享同一个 transcript 文件。

## 14.5 渲染与历史访问

- **桌面**（`DynamicPanel.swift:34`）：`reloadToken` 从 `panelMtime` 换成 **`panel.uuid`** —— 内容没变就不再无谓重载（现在 `touch` 一下就会刷屏）。头部加一个 `History ▾` 菜单，列出「时间 · 终端名 · 标题」，选中即进入 `mode:"pinned"`，点 `Live` 回到最新。
- `GET /panel` → 当前版本（不变）；`GET /panel?v=<uuid>` → **历史版本只读回放**。
- 新增 `GET /panel-versions?limit=50` →
  ```json
  [{"uuid":"…","ts":"…","title":"CI 构建监控","bytes":7412,
    "terminal":{"id":"…","name":"api-refactor"},
    "agent":{"kind":"claude","session_id":"24fc7a41-…","transcript":"…jsonl"}}]
  ```
- `GET /panel-meta`（`AppState.swift:704`）增加 `uuid` 字段，Web 端据此判断重载 —— 比 mtime 可靠。

## 14.6 回滚

把 `versions/<老 uuid>.html` 复制回 `panel.html` → 走正常捕获流程，生成**一个新 uuid**，带 `derived_from: <老 uuid>`，并记 `panel.activated{mode:"rollback"}`。
**历史是线性、不可变、只追加的** —— 任何版本都不会被覆盖或改写。

## 14.7 保留策略

默认**永久保留**。典型 panel 5–50 KB，一天出 20 版也只有约 1 MB/天。
可选上限 `max_versions` / `max_mb`（默认关闭）。真要清理时**只删 html 正文、保留 index.jsonl 里的那一行**（记 `panel.pruned` + `body_pruned: true`），这样日志里的历史链条永远不断。

## 14.8 index.jsonl 行格式 + 对应的审计日志行

```json
{"uuid":"019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e","ts":"2026-07-27T16:41:09.220+02:00","sha256":"3b1f…","bytes":7412,"title":"CI 构建监控","prev":"019820e9-4f11-7a03-9c55-8d2e1f0a7b31","derived_from":null,"terminal":{"id":"3F2A9C4E-…","name":"api-refactor","cluster":"refactor-swarm","project":"FleetView"},"agent":{"kind":"claude","session_id":"24fc7a41-be45-4f4e-87a4-42ef79186e51","transcript":"/Users/puzhen/.claude/projects/-Users-puzhen-PycharmProjects-FleetView/24fc7a41-….jsonl"},"attribution":{"method":"hook_tool_match","tool":"Write"},"data_snapshot":"019820f1-….data.json"}
```

对应审计日志：

```json
{"@timestamp":"2026-07-27T16:41:09.220+02:00","event.name":"fleetview.panel.version_created","event.kind":"event","event.category":["configuration"],"event.type":["creation"],"event.action":"panel-version-create","event.outcome":"success","event.id":"01K3MDX7…","fleetview.actor":{"type":"agent","agent.kind":"claude","id":"24fc7a41-be45-4f4e-87a4-42ef79186e51"},"fleetview.target":{"kind":"panel","panel.uuid":"019820f1-7c3a-7c21-b8e4-1f2a3b4c5d6e","terminal.id":"3F2A9C4E-…","terminal.name":"api-refactor","cluster.name":"refactor-swarm","project.name":"FleetView"},"fleetview.data":{"panel.sha256":"3b1f…","panel.bytes":7412,"panel.title":"CI 构建监控","panel.prev_uuid":"019820e9-…","panel.path":"~/.fleetview/ui/versions/019820f1-….html","agent.session.id":"24fc7a41-be45-4f4e-87a4-42ef79186e51","transcript.path":"/Users/puzhen/.claude/projects/-Users-puzhen-PycharmProjects-FleetView/24fc7a41-….jsonl","attribution.method":"hook_tool_match","attribution.tool":"Write","capture.method":"mtime_watch"},"message":"panel v019820f1 (7.2 KB, \"CI 构建监控\") written by claude session 24fc7a41 in terminal \"api-refactor\""}
```

**关于 index.jsonl 与审计日志的重叠**：不违反 §6 —— 二者职责不同（index 是**归档自带的目录**，让归档目录自解释、UI 秒开列表；审计日志是**事件流**）。约定：**审计日志是权威**，index.jsonl 可从日志完全重建（提供 `--rebuild-index`）；index 只存版本自身的元数据，不存 actor/trace 等动作上下文。

## 14.9 落地改动清单

| 文件 | 改动 |
|---|---|
| `Support/Paths.swift` | 加 `panelVersionsDir` / `panelIndex` / `panelCurrent` |
| **新增** `UI/PanelVersions.swift` | 捕获、去重、UUIDv7、索引、归因 |
| `State/AppState.swift:61 refreshPanel` | 稳定性等待 + sha256 去重 + 后台 I/O + 发事件 |
| `State/AppState.swift:696 /panel` | 支持 `?v=<uuid>`；新增 `/panel-versions`；`:704 /panel-meta` 增 `uuid` |
| `Status/EventWatcher.swift:8` | 加 `tool_name` / `tool_input`（归因级别 1）+ 可选 `PanelUpdate` 事件 |
| `UI/DynamicPanel.swift:34` | `reloadToken` 改用 uuid；加 `History ▾` 菜单 |
| `Remote/WebDashboardPage.swift` | panel iframe 按 uuid 重载；历史版本入口 |
| `.claude/skills/fleetview-panel/SKILL.md` | （可选）改原子写 `mv -f`；（可选）加 `PanelUpdate` 声明一行 |
