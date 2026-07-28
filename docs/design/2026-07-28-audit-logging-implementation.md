# 审计日志实施：分层拦截架构

| | |
|---|---|
| **文档类型** | 设计文档（实施篇） |
| **创建日期** | 2026-07-28 |
| **最后更新** | 2026-07-28 |
| **状态** | 已实现 —— 引擎、状态层、Web 层、管道 tap、Panel 归档全部接入，145 个测试通过 |
| **对应代码版本** | `a96f272`（2026-07-28） |
| **上游规范** | [2026-07-27-audit-logging-spec.md](2026-07-27-audit-logging-spec.md) |

> 目标（用户要求）：**用底层方式实现，后续增加新界面不需要再写打点代码。**

---

## 1. 结论先行：为什么不是"纯状态 diff"

最初的方案是纯 diff：观察 `AppState` 的状态，比较前后快照，自动派生事件。这个方向被两个成熟实现验证：

- **paper_trail (Rails)** —— hook 进 ActiveRecord 生命周期，把字段级 changeset 存成 `object_changes`，actor 由 controller 的 `before_action` 写入 thread-local（RequestStore）
- **django-auditlog** —— Django signals 自动记录每次 create/update/delete，diff 存 JSON；actor 靠 middleware 写 thread-local；文档明说没有该 middleware 时 actor 恒为 null

**但纯 diff 有一个记录在案的硬伤**：不改变状态的操作完全不可见。事件溯源社区的表述是 *"Event Logs should not capture actions that were attempted but did not affect the system's state… you may encounter gaps in the narrative"*；CDC 被批评为 *"row deltas without domain intent"*。

对 FleetView 这不是理论问题。纯 diff 会静默丢掉：

| 操作 | 为什么 diff 看不见 |
|---|---|
| 点击卡片把窗口提到最前（`raiseTerminal`） | 不改任何 `@Published` 状态 |
| `/type`、`/key`（手机端打字/发按键） | 直接进 tmux，不碰 AppState |
| 点击已选中的对象、改名成同名 | 前后状态相同 |
| **失败的操作**：坏 uuid、对已死会话发指令、`409 not open` | 无状态变化 —— 而这正是审计最该记的 |
| 在 Finder 中显示、复制 URL、拖拽中途取消 | 无状态变化 |

Redux/TCA 那一派（`_ReducerPrinter`、redux-logger）反过来只记 action（意图），但同时打印 prevState/nextState。**两派最终都收敛到"意图 + 变更"一起记**，实施采用的就是这个组合。

---

## 2. 架构

```
┌──────────────────────────────────────────────────────────────┐
│  View 层：SwiftUI 视图 / Web 页面 / CLI 脚本                    │
│  ✗ 永远不写日志代码。这是一条硬规则。                             │
└───────────────┬──────────────────────────────────────────────┘
                │ 调用现有 AppState 方法
┌───────────────▼──────────────────────────────────────────────┐
│  AppState（唯一状态所有者）                                     │
│                                                              │
│  ① audited(intent) { … }   声明意图 + 立即 diff                │
│  ② objectWillChange 兜底扫描（250 ms 合并）→ diff              │
└───────────────┬──────────────────────────────────────────────┘
                │            ┌─────────────────────────────────┐
                │            │ ③ AuditContext                  │
                │            │   环境 actor（谁在操作）           │
                │            └─────────────────────────────────┘
┌───────────────▼──────────────────────────────────────────────┐
│  FleetViewAudit（独立 library，零 UI 依赖，可单测）              │
│  SnapshotDiff → AuditPolicy → StateAuditor → Auditor → Sink   │
└──────────────────────────────────────────────────────────────┘
```

### ① 意图（intent）
`AppState.audited(_:_:)` 包住一个模型操作，记录**声明的意图**加上**产生的 diff**；即使没有任何状态变化也会产出一条记录 —— 这就是补上第 1 节那个洞的地方。

包装点在 **AppState（模型层）**，不在视图层。新界面调用同一个方法就自动继承日志。当前需要包装的只有~25 个模型方法，且是一次性的。

### ② 兜底扫描（sweep）
`objectWillChange` 订阅 + 250 ms 合并，扫出一切**没走 intent 包装**的变化：hook 事件驱动的状态迁移、将来新增的方法、直接改 `@Published` 的代码。

两条路径共用**同一个基线快照**（`AppAudit.baseline`），所以一个变化只会被记一次。

### ③ 环境 actor
`AuditContext` 用**线程局部栈**保存"当前是谁在操作"，入口处声明一次（web 请求、hook 分发、CLI），底下多深的调用都继承。默认 `.desktop`。

> **为什么不用 `@TaskLocal`**：它只沿 structured concurrency 的子任务传播。FleetView 的变更来自同步的 SwiftUI 回调，以及 web 服务器里的 `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` —— 两者都不是子任务，`@TaskLocal` 会**静默失效**。线程局部则覆盖两者，因为 push 和变更发生在同一个（主）线程上。这也正是 paper_trail 和 django-auditlog 的做法。

---

## 3. "新字段/新界面自动被记录"是怎么做到的

快照的字段不是手写清单，而是**把模型 `Codable` 编码出来**：

```swift
fields: AuditValue.fields(of: terminal, dropping: ["id"])
```

于是：

| 你做了什么 | 日志会怎样 | 需要改审计代码吗 |
|---|---|---|
| 加一个调用现有 AppState 方法的按钮 | 照常记录，actor = desktop | **否** |
| 加一个改状态的 Web 端点 | 照常记录，actor = web（带 IP） | **否** |
| 给 `TerminalSession` 加一个字段 | 产出 `fleetview.terminal.changed`，含 from/to | **否** |
| 加一个全新的实体类型 | 产出 `fleetview.<kind>.changed` | **否** |
| 想让某字段有专属事件名（如 `status_changed`） | 在 `AuditPolicy.fleetView` 加一行**数据** | 加一行 |
| 加一个**不改状态**的操作（raise / 发按键 / 失败路径） | 需要一个 intent | 模型层加一个包装 |

策略是**失败开放（fail open）**：没人分类过的字段仍然产出通用 `…changed` 事件，而不是消失。这条由测试 `an unclassified new field must still produce an event` 和 `a newly added field needs no registration` 守住。

---

## 4. 模块与文件

```
Sources/FleetViewAudit/          ← 独立 library，Foundation only
├── AuditValue.swift             JSON 值类型 + 确定性编码（键排序、绝不含裸换行）
├── AuditValue+JSON.swift        Codable 模型 → 审计字段的桥
├── AuditEvent.swift             事件信封 + actor / target / trace / resource
├── AuditEnvelope.swift          ECS 形态的一行 JSON（键序固定，便于人读）
├── Identifiers.swift            ULID（事件 id）+ UUIDv7（panel 版本 id）
├── AuditContext.swift           环境 actor（线程局部栈）
├── AuditSnapshot.swift          实体 / 快照 / 字段级 diff
├── AuditPolicy.swift            字段 → 事件名的映射（数据，非代码）
├── StateAuditor.swift           变更 + 意图 → 事件
├── Auditor.swift                app 唯一对接的门面
└── AuditSink.swift              文件 sink（轮转 / 缓冲 / 原子行写）+ 内存 sink + 超长行裁剪

Sources/FleetView/State/AppState+Audit.swift   ← app 侧唯一知道日志存在的文件
```

### 关键实现细节

- **一行 = 一次 `write(2)`，且 < 4000 字节**（低于 `PIPE_BUF` 4096）。POSIX 保证 `O_APPEND` 下这样的写是原子的 —— 这正是**两个 FleetView 实例可以共写同一个日志文件而不会互相撕裂**的原因（你的常见场景）。超长事件由 `LineFitter` 裁剪：**牺牲内容，保住身份**（事件名、actor、target、trace 一定完整，长字符串截断并标 `_truncated` + 原长度）。
- **日志文件**：`~/.fleetview/logs/audit-YYYY-MM-DD.jsonl`，目录 `0700` / 文件 `0600`，每个新文件先写一行自描述的 `fleetview.log.opened`。
- **原有的 `~/.fleetview/fleetview.log` 不动**，继续做非结构化 debug 日志。
- **脱敏**在写入前执行（`Redaction`），命中时置 `redacted: true`，这样"没有密钥"和"密钥被抹掉了"可以区分。

---

## 5. 测试

```bash
swift run FleetViewAuditTests     # 145 个测试，430 个断言
```

> ⚠️ **不是 `swift test`**。这台机器只有 Command Line Tools 没有完整 Xcode，SwiftPM 既够不到 XCTest 也够不到 swift-testing，`swift test` 直接失败。所以测试目标是一个普通可执行文件 + 一个 ~100 行的 XCTest 兼容 shim（`Tests/FleetViewAuditTests/TestHarness.swift`）。
> **测试代码本身就是标准 XCTest 写法**。将来装了完整 Xcode，迁移就三步：Package.swift 里改回 `.testTarget`、各文件 `import XCTest`、删掉 `TestHarness.swift` 与 `main.swift`。

覆盖的重点（每条都对应设计里的一个承诺）：

| 承诺 | 测试 |
|---|---|
| 一个事件 = 一行，永不撕裂 | 换行/制表/控制字符转义、超长行裁剪后仍 < 4000 字节 |
| 编码确定性 | 键排序、bool 不塌成 int、非有限 double → null、CJK 往返 |
| 新字段自动被记录 | `an unclassified new field must still produce an event`、`a newly added field needs no registration` |
| 无状态变化的操作仍被记录 | `an operation that changes nothing is still logged`、`a failed operation is logged as an alert` |
| 不重复记录 | transcript + session 两个字段合并为一条 `transcript_bound`；`lastActivity`/`newTokens` 被抑制 |
| actor 不串 | 作用域嵌套/抛错恢复/跨线程不泄漏 |
| 两实例共写一个文件 | `file sink appends rather than overwrites` |
| 密钥不入日志 | 6 类模式 + 幂等 + 不误伤普通命令 |
| ULID/UUIDv7 可排序 | 同毫秒内仍严格有序、UUIDv7 前 48 位即时间戳 |

### 实测（不只是单测）

**zsh 集成在真实 zsh 里跑过**：把生成的 `.zshrc` 抽出来，用隔离的 `HOME`/`ZDOTDIR` 起一个交互式 zsh 执行命令，检查落盘的事件文件。这一步抓到了两个单测抓不到的 bug：

| bug | 后果 |
|---|---|
| `local status=$?` | `status` 在 zsh 里是**只读变量**，赋值直接中止 hook —— 每条命令的退出码都会静默丢失 |
| 测试脚本里 real/FleetView 的 ZDOTDIR 指向同一目录 | 自递归（这个是测试脚本的问题，不是产品的） |

修复后实测输出：

```
ShellCommand      | {"command":"echo hello >/dev/null","cmd_id":"c72175-14313188","cwd":"/tmp/fvzsh",…}
ShellCommandDone  | {"cmd_id":"c72175-14313188","exit_code":0,"duration_ms":5}
ShellCommand      | {"command":"sh -c 'exit 7'","cmd_id":"c72175-203702916",…}
ShellCommandDone  | {"cmd_id":"c72175-203702916","exit_code":7,"duration_ms":4}
ShellCommand      | {"command":"claude --version",…,"quiet":"1"}
```

**集成测试也抓到一个真 bug**：日志首行 `fleetview.log.opened` 拿到的序号是 13 却物理写在第一行 —— 因为事件在进缓冲区时就编好了号，而文件头要到首次 flush 才生成。这会让"序号有断层 = 丢行"这个性质失效。改成**先备好文件再编码**。

**未做端到端 GUI 运行验证**：FleetView 是 GUI 应用，且你有一个长期运行的生产实例 —— 起第二个实例会抢走 hook 事件。所以桌面 UI 路径验证到"编译通过 + 模型层单测 + 真实 zsh 实测"为止。

---

## 6. 已完成

| 层 | 内容 |
|---|---|
| **引擎** | 独立 library，145 个测试；ECS 信封、确定性编码、原子行写、日轮转、超长行裁剪、脱敏、ULID/UUIDv7 |
| **环境 actor** | 线程局部栈；入口处声明一次，全链路继承 |
| **状态层** | `AppAudit.shared.start(state)`（AppDelegate 一行）+ 兜底扫描 → 所有状态变更自动记录，**包括点击选中终端**（选中被建模成状态） |
| **意图包装** | `raiseTerminal`、`openInFinder`、`newTerminal`（含失败路径）、`removeTerminal`、`renameTerminal`、`webAction` |
| **Web 层** | 解析完整请求头、取 `NWConnection` 远端地址、`fv_ws` cookie 会话、`AuditContext` 包住每个请求、轮询端点只计数不落行、5 分钟聚合、空闲过期、4xx 记 alert |
| **地理位置** | IP 分域（loopback/lan/tailscale/public）→ Tailscale 节点名+登录用户+DERP 区域 → `Accept-Language` → 公网 IP 城市级（默认关闭，需显式开启） |
| **管道 tap** | `EventWatcher` 增 `tool_name`/`writesPanel`/`cmd_id`/`exit_code`/`duration_ms`；zsh 加 `precmd`；agent 会话/prompt/权限/turn 结束；shell 命令 start/finish |
| **Panel 归档** | UUIDv7 命名、sha256 去重、稳定性等待防截断、`index.jsonl`、三级归因、`/panel?v=`、`/panel-versions`、桌面 History 菜单、按 uuid 重载 |
| **CLI 归因** | `project-manager` / `fleet-monitor` 带 `fleetctl/*` UA，不再被记成匿名浏览器 |

### 仍可继续的（都不影响覆盖率）

1. 其余 AppState 方法的 intent 标注 —— 兜底扫描已经在记，只是少一个操作名
2. 离线 GeoLite2（mmdb）读取器，取代可选的在线查询
3. `tailscale serve` + HTTPS 后启用浏览器精确定位（当前 http:// 下浏览器一定拒绝）
4. asciicast 终端录制（默认关）

---

## 7. 给后来者的规则

1. **视图里永远不写日志代码。** 要记的东西，一定能在模型层或管道层找到落点。
2. **不改状态的操作要声明 intent。** 判断标准很简单：这个操作会改 `@Published` 吗？不会 → 需要 `audited(AuditIntent(...))`。
3. **失败路径要显式记。** 用 `audit.failure(...)`；失败不改状态，diff 永远看不见它。
4. **新增字段专属事件名 = 改 `AuditPolicy.fleetView`（数据），不是改代码。**
5. **抑制一个字段前先问：这个事实是不是已经有别的写入者了？**（`§6 规则 4：一个事实，一个写入者`）
6. **每加一个承诺，加一个测试。** 上面那张表就是这么长出来的。
