# 打开很大的 commit 只显示"git 没读出来"

| 字段 | 内容 |
|---|---|
| 发现日期 | 2026-10-30 |
| 状态 | 已修复（未部署） |
| 影响 | 卡片 code_sense-19 的提交列表里只有一个 commit，点开只显示"git 没读出来"。凡是一次加入一整个目录树的 commit 都会这样 |
| 对应代码版本 | `9b0453e` |
| 修复 | `Sources/FleetViewFiles/GitHistory.swift`（`changes`、`commit`）；`Sources/FleetView/Files/FileBrowserModel+History.swift`；`Editor/src/editor.js`（重新打包了 `Editor/dist`） |

## 现象

用户问"313428ff…为啥 git 读不出来"。这张卡的对话里只有一次 `git commit`，账本已经把它对上了 `code_sense/work/producer-rest-47-xhigh/tasks` 里的 `2154aa5`，提交列表也列出来了，并且标着"↗ tasks"。但点开这个 commit 只显示"git 没读出来"。用快照模式复现出了同样的结果。

## 根因

`2154aa5` 是那个仓库的第一个 commit，一次加入了 190,793 个文件。

- `GitReader.changes` 先用 `diff-tree --name-status` 读文件列表，输出有 17.3MB，超过 16MB 的读取上限。进程被结束，返回码不是 0，整个函数返回 nil。
- 就算列表读到了，后面的 `--numstat` 也要 18.8 秒，超过 15 秒的超时。
- 页面头部的文件数和增删行数是把每个文件的统计加起来得到的。没有统计时会显示"+0 −0"。

## 修复

- 文件列表被截断，或者超过 1MB（约一万五千个文件）时，就用读到的部分。被截断的最后一条只读了一半，丢掉它。这种情况下不统计增删行数。页面本来最多也只显示前 3000 个文件。
- `GitReader.commit` 带 `--shortstat` 读头信息失败时，再不带统计读一次，这样提交说明、作者和日期还能显示。
- 页面头部优先用 commit 自己的统计（git 的 shortstat）；没有统计时不显示增删行数。

## 验证

- 手动对这个 commit 跑：`--name-status` 0.1 秒、17.3MB；`--numstat` 18.8 秒；`log --shortstat` 4.6 秒。
- 用快照模式复现：修复前显示"git 没读出来"；修复后显示提交说明和"190793 个文件 · +41004650 −0"，文件可以逐个展开看内容。
- `swift run FleetViewAuditTests`：189 个测试全部通过。
