# 浏览搜索结果时 app 卡死

| 字段 | 内容 |
|---|---|
| 发现日期 | 2026-11-02 |
| 状态 | 已修复（build 280 部署） |
| 影响 | 在 ⌘K 搜索里点结果、在会话预览里移动鼠标时 app 卡住，一次 23 秒，只能强制退出（当天两次：16:44、20:40）。终端不受影响，tmux 会话都还在 |
| 对应代码版本 | `63d3751`（build 274） |
| 修复 | `Sources/FleetView/Search/SearchModel.swift`（`Preview.texts`/`shown`、`render`、`clip`、`showMore`、`snippets`）、`Sources/FleetView/UI/SearchPanel.swift`（`StepRow`）；commit `5f76c56` |

## 现象

用户的说法是"搜索界面浏览的时候经常崩溃卡死"。

- `/Library/Logs/DiagnosticReports/` 里当天有两份 `FleetView_*.hang`：
  - 16:44:15 – 16:44:39，`Duration: 23.35s`（采样前已经无响应 22 秒）；
  - 20:40:52，采样 1.08 秒。
- 两次之后审计日志里都只有 `fleetview.app.started`（16:44:47、20:40:59），没有 `app.stopped`——是卡住后被强制退出的，不是真的崩溃。`~/Library/Logs/DiagnosticReports/` 里没有 FleetView 的崩溃报告。

## 根因

两份报告的主线程栈里没有一帧 FleetView 自己的代码，全是 SwiftUI 的布局：`LazySubviewPlacements.placeSubviews`、`StackLayout.sizeThatFits`、文本测量，以及 `.textSelection(.enabled)` 带来的 `SelectionOverlay.updateNSView`。能落到这里的只有搜索面板右侧的会话预览。

预览原来是这样画的：

1. 整段会话（最多 4000 条，索引里最长的一段 3747 条）放进一个 `LazyVStack`，打开时 `scrollTo` 到命中的那条（居中），整段加载完再 `scrollTo` 一次。可变高度的行，滚到第几千行，SwiftUI 要把前面的行都量一遍才知道位置。
2. 每条消息在 `body` 里现做：整条正文 `AttributedString(markdown:)`、标高亮，然后 `Text` + `textSelection`。正文不截断——索引里有 1103 条超过 20 KB，最长 254 KB；命中的那条还是 `lineLimit(nil)`，全部排版。
3. 鼠标悬停状态 `hoveredStep` 是整个面板的 `@State`：指针每划过一条消息，整个面板重算，可见的每条消息都重新解析 Markdown、重新排版。
4. 左边列表的每一行也在 `body` 里把整条正文按行拆开再拼起来，只为了显示 240 个字。

## 修复

- 消息的显示文本在打开预览时于后台线程一次做好（`SearchModel.render`）：先截短——普通消息最多 1500 字（屏幕上本来就只显示 12 行），命中的那条最多 8000 字、从第一个匹配前一点开始截——再解析 Markdown、标高亮。行里直接用结果。
- 预览只显示命中前后各 120 条（`Preview.shown`），两端各有"显示更早的 / 之后的 N 条"按钮，每次再加 120 条；往前加时视图停在原来那条上。
- 每条消息是一个独立的 `StepRow`，悬停状态是它自己的，鼠标移动只重画那一行。
- 列表行的摘要随搜索结果在后台算好（`SearchModel.snippets`），超长正文先在匹配附近截 3000 字再展平。

## 验证

`FleetView --snapshot`（`CFFIXED_USER_HOME` 指向临时目录，拷入 4 个真实 transcript，含 3747 条那段），`FV_SNAPSHOT_HISTORY=review`，给 `shoot` 临时加计时，同一份数据分别跑 main（`63d3751`）和修复后的代码。打开 3306 条的那段会话、命中在末尾附近，一次出图（含整个看板）：

| | 深色 | 浅色 |
|---|---|---|
| 修复前 | 20,357 ms | 38,406 ms |
| 修复后 | 1,592 ms | 2,422 ms |
| 不打开预览的同一画面（基线） | 1,114 ms | 1,533 ms |

窗口改成前后各 40 条，时间基本不变（1,507 / 2,231 ms），剩下的开销不在条数上，所以保留 120。

## 没覆盖到的

- 截短之后，超长消息在预览里看不全；要看全文只能在终端里打开那一步。
- 只在 debug 构建、离屏窗口里量过一次布局；真实窗口里的滚动和悬停没有逐帧测。
