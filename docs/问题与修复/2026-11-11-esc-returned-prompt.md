# 网页上按 Esc 后，被打断的消息留在 agent 的输入框里，下一条接在它后面

| 字段 | 说明 |
|---|---|
| 发现日期 | 2026-11-11 |
| 状态 | 已修复 |
| 影响 | 网页（和 PM 栏）上打断一轮之后发的下一条消息，会和被打断的那条拼成一条发出去 |
| 对应代码版本 | c35e843 |
| 修复 | `Remote/Submit.swift`（`composerText` / `isReturned` / `clearComposer`）、`Remote/RemoteServer.swift`（`reclaimComposer`、`sendText` 的 `clearingReturned`）、`State/AppState.swift`（`/key` Escape、`webType`、`returnedPrompts`）、`Remote/WebDashboardPage.swift`（`#cutbar`） |

## 现象

用户在 PM 栏里发了「帮我用threejs的ultra」，随即按了 Esc。过了一会儿又发「water」，PM 收到的是「帮我用threejs的ultrawater」，又被 Esc 打断。用户的描述：“chat 页面对于 esc 的支持不好，有时候点 esc 后就会 restore 到文本框里”。

## 根因

Claude Code 有一个设计：一轮还没开始回答就被 Esc 打断时，会把这条提示原样放回自己的输入框，方便你改了再发。在终端里这很好用，因为你看得见输入框。在网页上看不见：chat 里这条消息显示成已发出，输入框里却还留着它。下一条从网页发出的消息由 `send-keys` 打进同一个输入框，接在它后面，两条拼成一条提交。

PM 的记录（`~/.claude/projects/-Users-puzhen--fleetview-pm/f38f75e4….jsonl`）里能看到两次：00:31:59 的「帮我用threejs的ultra」只有 `api-request` 没有回答；00:49:06 的「帮我用threejs的ultrawater」是前一条加上新打的字。

在隔离的 tmux 里（Claude Code 2.1.319）复现：提交后 1.2 秒按 Esc，提示原样回到输入框。

## 修复

- **网页或 CLI 按 Esc 之后**（`/key?k=Escape`）：在这张卡的写入队列上，等 1 秒，看输入框；如果里面是这张卡最后一条提示（去掉空白后比较，屏幕折行不影响），就把它清掉，记进 `returnedPrompts`。
- **从网页发消息之前**（`webType`）：同样检查一次输入框。这一步覆盖在桌面窗口或终端镜像里按的 Esc，那些按键 FleetView 收不到。
- **清空的方法**：`Ctrl-U`（清当前行）和退格（并到上一行）交替几次。不用 Esc（输入框空了以后再按两次会打开 rewind），也不用 `Ctrl-C`（会出现“再按一次退出”）。三行草稿实测清干净。
- **取出来的文字不丢**：`/state` 里这张卡带上 `cut`，保留十分钟。网页在输入框上方显示一行「已打断，这条没发出去：…  [放回输入框] [×]」，每条只提示一次。如果输入框里已经接了新打的字，就把整框内容给回来，并把折行接好。
- PM 的收件箱消息在 PM 输入框里有字（不是 Claude 的灰色建议）时先不发，30 秒后再试。

## 验证

- 编译 `Submit.swift` 单独测试，用真实 Claude 跑：提交后按 Esc，提示回到输入框，被识别出来并清空；另一段不相干的草稿不会被当成退回的提示；空输入框里的 `Try "…"` 建议也不会被当成。
- PM 的真实屏幕上，`composerText` 读出了「帮我用threejs的ultrawater」。
- 网页部分在无头 Chrome 里对着桩服务测试：提示条出现；放回后填进输入框；同一条不会再提示第二次。

## 没覆盖到的

- Codex 打断时是否也会把提示放回输入框，没有测。识别逻辑对 Codex 同样适用（`›` 提示符）。
- 判断的依据是这张卡最后一条提示。如果你在终端里按上箭头调出上一条想改，然后又从网页发了别的，那一条会被清掉。不过它会出现在提示条里，可以放回来。
