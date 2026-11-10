# 从卡片里启动的 FleetView，把那张卡的身份传给了它启动的进程

| 字段 | 说明 |
|---|---|
| 发现日期 | 2026-11-11 |
| 状态 | 已修复 |
| 影响 | 一张卡片显示了别处的提示：PM 旁问的开场白出现在构建 FleetView 的那张卡上，状态也被旁问的 hook 改动过 |
| 对应代码版本 | 16d2cd8 |
| 修复 | `Support/InheritedEnvironment.swift`、`main.swift` |

## 现象

用户在 PM 栏里对 jelly-island 发起旁问。之后，正在开发 FleetView 的那张卡（`b8bc…`）的提示行显示成了旁问的开场白「【旁问 · jelly-island】这是用户从你的主线分出来的旁问线程……」。

## 根因

当天的三次部署都是在这张卡的 shell 里用 `open` 启动 FleetView 的，FleetView 继承了那个 shell 的环境（`ps eww` 可以看到），其中包括：

- 这张卡的 `FLEETVIEW_TERM_ID`，以及 shell 集成的 `FLEETVIEW_SHELL_DIR`、`FLEETVIEW_REAL_ZDOTDIR`；
- 这张卡上 Claude Code 会话的 `CLAUDECODE=1` 和全部 `CLAUDE_CODE_*`（会话 id、消息 socket、`CHILD_SESSION`）。

FleetView 启动的进程又继承了这些变量。旁问用的 `claude -p` 运行时，它的 hook 带着这个 `FLEETVIEW_TERM_ID` 上报，于是它的 SessionStart（`src=fork`）、UserPromptSubmit、Stop 都记到了这张卡上。`/ask` 走的是同一条路，问题也一样。fleet trigger 早就自己去掉了 `FLEETVIEW_TERM_ID`，是个别的修补，没有从根上解决。

## 修复

`InheritedEnvironment.scrub()`：FleetView 启动后第一件事（在 `main.swift` 里，任何进程启动之前）就 `unsetenv` 卡片和 Claude 会话相关的变量。`TMUX`/`TMUX_PANE` 保留：headless 在 tmux 里启动时，更新后要靠它们在原处重启。

## 验证

- 单独的 swift 程序验证：`unsetenv` 之后，`ProcessInfo.environment` 和子进程都看不到这些变量。
- debug 版在这张卡的 shell 里跑 `--snapshot`：stderr 打出了去掉的变量名。
- 部署后，用 `ps eww` 确认运行中的 FleetView 里没有这些变量。

## 没覆盖到的

- tmux server 是 FleetView 第一次建会话时启动的，它的全局环境可能也带着当时继承来的变量。卡片的会话是用显式的 `env` 起的，不受影响；ttyd 的 `tmux attach` 进程会带上，但它不跑 hook。
