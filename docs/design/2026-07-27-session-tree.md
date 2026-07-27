# FleetView 会话树（Session Tree）设计稿 v1

| | |
|---|---|
| **文档类型** | 设计文档（Design Doc） |
| **创建日期** | 2026-07-27 |
| **最后更新** | 2026-07-27 |
| **状态** | 草案（Draft）—— 待评审，未实现 |
| **范围** | 仅 Swift 桌面版（不做 web 端） |
| **对应代码版本** | `f54cc8a`（2026-07-27） |
| **上游机制来源** | `~/PycharmProjects/read_paper/cli/treeflow`（树构建 + fork 算法照它移植） |
| **待决事项** | 见 §10 |

> 目标：把一个终端背后的 Claude 会话以**树**的形式可视化——包括被放弃的分支——每个节点可看上下文；
> **拖拽任意节点到 fleet 面板**即以该节点为起点开一个新终端；现有 **Duplicate 升级为 fork**（复制出带完整上下文的新会话，原会话不受影响）。

---

## 1. 为什么是树，以及树长什么样（机制事实）

这些是从 treeflow 源码确认的事实，设计必须建立在其上：

- Claude 的一个 `.jsonl` 会话文件是**树**：每条记录有 `uuid` / `parentUuid`；回退（Esc-Esc）、编辑重发都会留下被放弃的旧分支。
- **树的节点 = 用户 prompt**。assistant 回复/工具调用挂在所属 prompt 名下（treeflow `build_nodes`：把非用户消息沿 `parentUuid` 上溯归属到最近的用户 prompt，聚合成该节点的 `answer_text`）。
- **fork 任意节点**（treeflow `write_synthetic_session`）：
  1. 回链：目标节点 → 根，收集原始 jsonl 行；
  2. 前链：目标节点的回复链（BFS 后代，**遇到下一个用户 prompt 即停**，按时间戳排序）——没有这步，resume 后看不到该 prompt 的回答；
  3. 写入新 `<new-uuid>.jsonl`（同一 project 目录），末尾追加 `last-prompt` 记录钉住 `leafUuid`；
  4. `claude --resume <new-uuid>` 打开。**原会话文件零改动** —— 这就是 fork 语义。
- **native 捷径**：若目标节点恰好是某个现存会话的 leaf 所在 prompt，直接 `claude --resume <那个会话>` 即可，**不用写任何文件**（treeflow `native_reachable`）。
- 当前 leaf 的 fork 还有更简单的官方路径：`claude --resume <sid> --fork-session`（同上下文、新会话 id、原会话不动）—— **Duplicate 升级用它，零文件手术**。
- Codex 是另一套（线性 rollout + `forked_from_id` 跨文件成树）→ **v1 只做 Claude，Codex 列入 v2**。

## 2. 设计参考与取舍

| 参考 | 取什么 | 弃什么 |
|---|---|---|
| [Loom / Exoloom](https://generative.ink/posts/loom-interface-to-the-multiverse/)（LLM 多宇宙树） | 「树 + 阅读窗格」双栏；被放弃分支是一等公民，可回去看 | 自由画布式发散布局——对话 95% 是线性的，画布浪费空间 |
| [GitUp](https://github.com/git-up/GitUp) / [Fork](https://www.terminal.guide/tools/git-tool/fork/)（macOS 提交图） | **竖直 lane 图**：左侧窄轨道画分支线，右侧信息行；千行秒开；行内徽章 | 提交图的复杂操作（rebase 等） |
| treeflow TUI 本身 | 节点=prompt；**折叠长直线段**；搜索同时搜 prompt+回复；tree/list/leaves 三视图 | 终端字符画 |

**核心判断**：对话是「基本线性 + 偶发分叉」——正确形态是 **GitUp 式竖直时间线 + 左侧分支轨道**，不是 mind-map 式节点画布。审美来自克制：窄轨道、圆角曲线、少色、动效轻。

## 3. 放在哪里：右侧滑入分栏（不是独立窗口、不是遮罩）

```
┌────────────┬──────────────────────────────┬───────────────────────────┐
│  Sidebar   │        Fleet 面板             │   ⑂ 会话树面板 (slide-in)  │
│  (原样)     │   （拖拽落点，保持可见）        │   （可拖宽，默认 460pt）    │
└────────────┴──────────────────────────────┴───────────────────────────┘
```

- **为什么**：核心交互是「拖节点 → 落到 fleet 面板」，落点必须始终可见 ⇒ 排除全屏遮罩/sheet；拖拽要跨区域命中 ⇒ 同窗口最稳（复用现有 `"fleet"` 坐标空间的自绘拖拽机制，和卡片拖 dock 同一套，交互语言一致）。
- 打开入口：卡片上新增 **⑂ 按钮**（tooltip「会话树」）+ 卡片右键菜单「Show Session Tree」。
- 面板与**会话**绑定（不是与终端绑定）：头部显示 session 短 id + 当前挂在此会话上的终端 chips（共享会话场景一目了然）。
- 左缘可拖拽调宽（复用 SidebarDivider），380–720pt。

## 4. 面板结构（自上而下）

```
┌─ ⑂ 会话树 ─────────────────────────────── ✕ ─┐
│ 22c96826 ⧉   ⌗ datagen_vision2web            │  ← session 短id(点击复制) · 项目
│ ● fix images ● fix images 20   ⑂3 · 47节点    │  ← 挂载终端chips · 分支/节点统计
├───────────────────────────────────────────────┤
│ 🔍 搜索 prompt 与回复…                          │
├───────────────────────────────────────────────┤
│  │                                            │
│  ●  修复 L2 渲染的 cookie bar 问题        2d   │  ← 普通节点（active 路径=实心蓝点）
│  │     ↳ 找到了 render_prototypes_l2.js…      │  ← 回复摘要一行（dim）
│  │                                            │
│  ├─⋯ 12 turns ────────────────────────────    │  ← 折叠的线性段（点击展开）
│  │                                            │
│  ●  ⑂2  把 20 个没过的任务重新跑一遍       8h   │  ← 分支点（⑂徽章=2个子分支）
│  │╲                                           │
│  │ ○  先试小批量验证 prompt…            8h    │  ← 被放弃分支（空心灰点、dim、灰lane）
│  │ ○  换 kimi 跑一次对比…               7h    │
│  │                                            │
│  ◉  把 v2w_l3_render.py 落库到 pipeline  3m   │  ← 当前leaf（大点+脉冲环，自动滚到此）
│  │      [● fix images 20]                     │  ← 终端chip：该终端此刻停在这里
├───────────────────────────────────────────────┤
│ ▾ 节点详情（选中/悬停即显，点击钉住）             │
│  「把 20 个没过的任务重新跑一遍…」(完整prompt,md) │
│  ─ 回复节选（前~20行，等宽渲染）────────────     │
│  深度 31 · 分支 2/3 · 2026-07-27 14:02        │
│  [⑂ 以此节点开新终端]  [复制 prompt]           │
└───────────────────────────────────────────────┘
```

要点：

- **方向**：最新在底（聊天惯例），打开即自动滚到当前 leaf；`⌘↓` 回到 leaf。
- **轨道（rail）**：宽度 = 14pt × 当前深度处的 lane 数，正常只有 1 条。active 路径恒用 accent 蓝 `#7a9eff`；被放弃分支从静音色板轮转（灰/青/橙/紫/绿 @ 55% 透明度）。边线 1.5pt 圆角二次曲线（GitUp 风格），不画直角。
- **节点点**：active=8pt 实心蓝；放弃=7pt 空心灰；当前 leaf=10pt + 脉冲环（复用 `StatusDot` 的 pulse）；分支点行首加 `⑂N` 徽章。
- **行**：两行 prompt（13px）+ 相对时间；下挂一行回复摘要（`answer_text` 首行，dim 60%）。行高约 52pt。选中=左缘 2pt accent 条 + card 底色；悬停=cardHover。
- **折叠**：连续无分叉 > 5 节点 → 折叠成 `⋯ N turns` 胶囊行（首尾节点保留可见），点击展开，动效 `.easeOut(0.18)`。分支点永不折叠。
- **搜索**：同时命中 prompt 与 `answer_text`（treeflow 同款）；命中行高亮、非命中 dim（不隐藏——保持树形上下文）；`⌘F` 聚焦。
- **详情窗格**（面板底部 1/3，可折叠）：悬停 = 瞬时预览（Xcode Quick Help 式），点击 = 钉住。完整 prompt（沿用现有 markdown 渲染思路的 AttributedString 版）、回复节选、绝对时间、深度/第几分支;按钮 `⑂ 以此节点开新终端`（= 拖拽的等价键盘路径）、`复制 prompt`。
- **键盘**：`↑↓` 移动、`←→` 在兄弟分支间跳、`⏎` fork 打开、`Space` 钉住详情、`Esc` 关面板。

## 5. 拖拽交互（核心）

复用现有卡片拖拽的全套机制（`"fleet"` coordinate space + 自绘 chip + 命中测试），交互语言与「卡片拖到 dock」完全一致：

1. **按住节点行拖动 ≥6pt** → 行浮起为 chip：`⑂ 把 20 个没过的任务重…`（复用 `DragPreviewChip` 样式）；
2. 拖动中：fleet 面板整体出现 2pt accent 内描边 + 中央提示「松开：以此节点开新终端」；**源终端的卡片**同时高亮为第二落点（提示「加入该 cluster」）；
3. **落点语义**：
   | 落点 | 结果 |
   |---|---|
   | fleet 面板空白处 | 新终端（独立），归属**会话自己的项目**（cwd = 源终端 cwd —— slug 必须一致，fork 文件写在同一 project 目录） |
   | 任意同项目终端卡片上 | 新终端并加入该卡片的 cluster |
   | 其他区域 / Esc | 取消（chip 飞回，`.easeOut(0.2)`） |
4. **落下后的动作链**（后台，卡片先出现、状态先置 `shell`）：
   - 节点是 native-reachable → 直接 `--resume <原sid>`（零写文件）；
   - 否则 Swift 移植 `write_synthetic_session`：回链 + 回复前链 + `last-prompt` 钉 leaf → 新 `<uuid>.jsonl`；
   - 新终端 auto-type：`claude --resume <sid>`，**并继承源终端的启动 flags**（从其 pane 进程 cmdline 读到的 `--dangerously-skip-permissions` 等原样带上）；
   - 新卡片默认名：`⑂ <prompt 前 12 字>`（可改名）；hook 指针机制（`f54cc8a`）随后自动完成 terminal↔session 绑定。
5. **不做**跨项目落点（cwd/slug 不匹配，resume 不到）。拖到其他项目区域时显示禁止光标 + 该区域 dim。

## 6. Duplicate 升级为 fork

- 现状：`duplicateTerminal` = 同 cluster 开一个空白终端。
- 新行为：源终端**有活跃 agent 会话**（hook 指针存在）时，复制出来的终端 auto-type：
  `claude --resume <sid> --fork-session`（+ 继承 flags）——同上下文、新会话、原会话零改动、零文件手术；
  无会话（纯 shell）→ 维持旧行为。
- 入口不变（卡片 ⧉ 按钮 / 拖到 dock 的 Duplicate 区 / 右键菜单），菜单文案改为「**Duplicate (fork session)**」；右键菜单**加一项**「Duplicate blank」保留旧行为。
- 与 §5 的关系：Duplicate = 「fork 当前 leaf」的快捷方式；树面板 = fork 任意历史节点的完整能力。

## 7. 数据与性能

- 新文件 `Sources/FleetView/Tree/SessionTree.swift`（模型+构建器）与 `Sources/FleetView/Tree/SessionForge.swift`（fork 写文件 + resume 命令拼装）。**独立于** `Remote/Conversation.swift`（那边是 web 端活跃分支渲染，且另一会话正在改它——不碰，避免冲突）。
- 树构建**必须全量读文件**（分支可能在任何位置；web 端的 1.5MB tail 策略不适用）。42MB/1768 节点实测量级：后台队列构建，目标冷加载 < 1.5s；以 `(path, size, mtime)` 做缓存键，面板开着时每 2s `stat` 一次，变化才重建（增量 append 解析列入 v2）。
- 行虚拟化：SwiftUI `List`/`LazyVStack` 天然惰性；轨道曲线用 `Canvas` 按可见行段绘制。
- 共享会话的「各终端停在哪个分支」：来源于每终端 hook 指针 + 另一会话正在做的 ownPrompt 分支匹配（数据依赖，展示为终端 chip；该数据缺失时只是不显示 chip，不阻塞本功能）。

## 8. 视觉规格（对齐现有 Theme）

| 元素 | 规格 |
|---|---|
| 面板底色 | `Theme.panel`，左缘 1pt `Theme.stroke`，滑入 `.easeOut(0.22)` |
| active 路径 | 点/线 `Theme.accent`；leaf 脉冲环复用 StatusDot 动画参数 |
| 放弃分支 | 空心点 + 行文字 60% 透明度；lane 色板 `[#8c93a3,#66ccd9,#e69459,#b58ee6,#5cd18c]` @55% |
| 边线 | 1.5pt，二次贝塞尔转弯（半径 7pt），lane 间距 14pt |
| 折叠胶囊 | `Theme.card` 底、`⋯ N turns` 11px、悬停 cardHover |
| 徽章 | `⑂N`＝accent 12% 底胶囊（与 CLUSTER 徽章同款语法）；终端 chip＝status 色点 + 名字，同侧栏 TaskRow 语法 |
| 拖拽 chip | 复用 DragPreviewChip（加 ⑂ 前缀），阴影/字重不变 |
| 详情窗格 | `Theme.bg` 内嵌卡片,与终端卡片同圆角(12) |

一句话原则：**不引入任何新的颜色语义**——蓝=活跃/accent、灰=放弃、脉冲=当前,全部沿用既有语言。

## 9. 实施计划（分五步，可独立验收）

| 步骤 | 内容 | 验收 |
|---|---|---|
| P1 | `SessionTree.swift`：全量解析 + build_nodes 移植（含 answer_text、native_reachable、折叠段计算）+ 缓存 | harness 对真实 42MB 文件：节点数/分支数与 treeflow 输出一致，冷加载 <1.5s |
| P2 | `SessionForge.swift`：write_synthetic_session 移植 + native 捷径 + flags 继承 | fork 出的文件用 `claude --resume` 打开，上下文正确、原文件字节不变 |
| P3 | 面板 UI 只读版：树 + 轨道 + 搜索 + 详情 + 键盘 | 打开你现有的多分支会话肉眼验收 |
| P4 | 拖拽落点 + Duplicate-as-fork 改线 | 拖节点 → 新终端带上下文；Duplicate → fork 版复制 |
| P5 | 打磨：动效、空态（无分支时的简化视图）、live 刷新 | — |

## 10. 待决事项（评审时定）

1. **方向**：最新在底（推荐，聊天惯例）还是最新在顶（git 客户端惯例）？
2. **Duplicate blank 的入口**：右键菜单项（推荐）还是 ⌥+点击修饰键？
3. fork 新卡片的**默认命名**：`⑂ <prompt 前12字>`（推荐）还是 `<源终端名>-fork`？
4. 详情窗格里的回复节选是否需要「查看完整回复」的展开态（v1 先节选 + 复制,推荐）？
5. Codex 树（v2）的优先级。

---

*参考：[Loom: interface to the multiverse](https://generative.ink/posts/loom-interface-to-the-multiverse/) · [Exoloom](https://exoloom.io/) · [GitUp](https://github.com/git-up/GitUp) · [Fork](https://www.terminal.guide/tools/git-tool/fork/) · treeflow（本机 `read_paper/cli`）*
