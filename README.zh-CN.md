# FleetView

[English](README.md) · [简体中文](README.zh-CN.md)

macOS 上的编码 agent 终端舰队指挥台。

同时跑好几个 Claude Code 或 Codex 会话之后，你很快就会失去对它们的掌控：哪个在等你、哪个还在干活、
一小时前启动的那个你到底让它做什么了——而当一段对话分叉过几次之后，你甚至说不清眼前这个是哪一个版本。
FleetView 把每个会话摆上看板，把每段对话背后完整的树交给你，让这些终端彼此协作，并把整个舰队送到你手机上。

<!-- 截图 1 —— 看板全貌：几个项目分区、一张正在跑的卡片（计时器在走）、一张显示 "needs you" 的卡片。
     这是首图，后面几张都是它的局部。 -->

---

## 一、每个会话，都是一棵可以走回去的树

这是官方 CLI 不给你的部分。对话不是一条直线——回退某个 prompt、编辑它、或者 fork 一个会话，都会开出新的
分支，而旧的那条留在磁盘上、没有任何入口回去。`claude --resume` 只能按 id 恢复整个会话，`codex fork`
只能从末端分叉。夹在中间的一切都躺在磁盘上，够不着。

**读完整的历史。** 会话树面板列出一段对话的每个节点，包括你已经放弃的分支，Claude Code 和 Codex 都支持。
Claude 的树来自 `parentUuid` 链，Codex 的来自 `forked_from_id`——两种格式，一个面板。

**从任意节点重新开始。** 在新终端里打开任何一个节点。原会话永远不会被改动：如果某个会话本来就能解析到这个
节点，就走原生 resume；否则合成一个只包含该节点祖先链的会话文件，让 Claude 正好从那里接上。这是
[treeflow](https://github.com/nitpicker55555/Agent-Treeflow) 的算法，Claude 侧移植成了 Swift，
Codex 侧调用它。

**复制一个正在跑的会话。** 把一个活着的终端 fork 成第二个，继承上下文再各走各的——CLI 支持的地方走原生
`--fork-session`，不支持的地方走合成分支。

**搜索你说过的一切。** ⌘K 搜索本机所有 Claude Code 和 Codex 的对话记录——这台机器上有 12.9 GB，
索引后 249 MB，查询在个位数毫秒返回。Tab 分三级放大范围：看板上的终端 → 当前打开的对话 → 全部历史。
把结果拖到看板上，那段对话就**从那个位置**打开，可以直接续上。

索引还比文件本身活得久。Claude Code 默认 30 天后删除对话记录；这台机器的索引里仍存着 5,857 个文件的对话，
而磁盘上只剩 3,153 个。一段已经被 CLI 清理掉的对话，依然搜得到、读得到，也依然能被重建成一个可以 resume
的会话。

<!-- 截图 2 —— 会话树面板贴着卡片打开，能看到一个分叉点；最好再来一张 ⌘K 搜索浮层。 -->

---

## 二、会协作的终端

**是看板，不是标签栏。** 一个终端一张卡片，按项目分组，每张显示它在干活、空闲、还是在等你，以及最后一条
prompt 和 token 消耗。把一张卡拖到另一张上就把它们聚成 cluster——一组终端在做同一件事时，cluster 是让
它们作为一个整体待在一起的方式。把卡片拖进另一个项目，它的对话会跟着走。

**agent 之间可以互相驱动。** `project-manager` 通过 HTTP 和运行中的 FleetView 对话，所以一个终端里的
agent 可以列出整个舰队、读另一个终端的输出、替它回答权限询问、或者给它下一条新指令——按终端、按项目、或者
按它最后在做什么来定位。它以 skill 的形式放在 `.claude/skills/` 里，agent 不用被教就能找到。

```bash
project-manager ls                  # 所有终端、状态、token、最后的 prompt
project-manager ls -p FleetView     # 只看一个项目
project-manager show <sel> -l 60    # 某个终端此刻在做什么
project-manager send <sel> "继续"    # 给它一条指令
project-manager whoami              # 我自己跑在哪张卡上？
project-manager check               # 找出以报错结束的会话
```

**跨机器。** 每个 FleetView 都在所有网卡上提供 API，所以同一个 CLI 也能驱动另一台 Mac 上的实例。
`project-manager peers` 扫描局域网并给出 URL，`-u <url>` 让任何命令指向它。对面什么都不用装——笔记本上的
舰队可以从台式机读取和驱动，反过来也一样。

<!-- 截图 3 —— 看板上的一个 cluster（两三张卡框在一起），或者 `project-manager peers` 的输出
     配上另一台机器的终端列表。 -->

---

## 三、在手机上看整个舰队

**局域网上的仪表盘**（也走 Tailscale），由 app 自己提供服务——不需要账号，没有云，什么都不出这台机器。

**对话渲染成聊天**，原生滚动，而不是镜像一个终端画面。这才是它在小屏幕上能读的原因：你可以跟上 agent 做了
什么、用真正的按钮回答权限询问、并且打字回复。

**原始终端界面也在。** 当你要的就是真正的 TUI——全屏选择器、diff、进度条——卡片可以直接打开那个活着的终端，
在手机上滚动和输入。

**文件双向流动。** 从手机把照片或文件直接附进 prompt；在 Mac 上 `fleetview-send report.pdf` 会把文件
放进仪表盘的托盘里，在手机上一点即开。正好解决那件最别扭的事：agent 产出了一张图、一个 CSV 或一个构建产物，
而你不在电脑前。

**一块给 agent 画画的面板。** agent 可以把一个自包含的网页发布到仪表盘顶部——进度板、实时图表、倒计时——
桌面看板和手机上都会显示。

<!-- 截图 4 —— 手机视图：渲染成聊天的对话；最好再来一张文件托盘或原始终端界面。竖屏，
     有设备外框更好。 -->

---

## 环境要求

- macOS 14+
- 远程访问需要 `tmux` 和 `ttyd`（`brew install tmux ttyd`）——没有它们终端照常运行，只是无法提供给其他设备
- Claude Code 和／或 Codex CLI
- 在过去的节点上打开 Codex 会话需要 [treeflow](https://github.com/nitpicker55555/Agent-Treeflow)
  （`pip install`，安装脚本会询问）。Claude 那一侧是内置的。

## 安装

从 [Releases](../../releases) 下载最新的 `FleetView.app`，或者自己构建：

```bash
git clone https://github.com/nitpicker55555/FleetView.git
cd FleetView
./scripts/package_app.sh --install     # 构建并复制到 /Applications
```

## 磁盘上的东西

运行时产物一概不进这个仓库。FleetView 把自己的状态放在 `~/.fleetview/`：`state.json`、搜索索引、日志、
上传的文件、以及 agent 发布的面板。你的对话仍然留在 agent 原本写入的地方（`~/.claude/projects/`、
`~/.codex/sessions/`）——FleetView 只读不改，fork 的时候也不改。

退出 FleetView 不会停掉你的 agent：tmux 会话继续运行，下次打开时重新接上。只有关闭终端才会真正结束一个会话。

状态来自 FleetView 装进 Claude Code 和 Codex 的 hook，用哨兵注释围起来，卸载时会干净移除
（**FleetView → Uninstall Status Hooks**）。

## 关于网络

仪表盘走的是没有认证的明文 HTTP，所以任何能访问到这个端口的东西，都能读你的对话、并向你的 agent 输入。
在家庭网络或 Tailscale tailnet 上这没问题，在咖啡馆 Wi-Fi 上就不行。跨机器的 CLI 同理：没有 token，
能连上的实例就是能驱动的实例。

只有一个对外请求——针对 GitHub releases 端点的更新检查，最多每六小时一次——可以用
`~/.fleetview/logging.json` 里的 `"updates": false` 关掉。

## 状态

0.4，每天用它管理一个真实的舰队。Codex 相关的部分比 Claude 相关的部分更新：两边的树都能用，但 Codex 的分支
是通过 treeflow 读取而非原生支持，打开 Codex 节点也需要装上它。
