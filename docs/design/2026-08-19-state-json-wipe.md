# state.json 被清空事故：一个新字段如何抹掉整块看板

| | |
|---|---|
| **文档类型** | 事故复盘 + 规则 |
| **发生日期** | 2026-08-19 |
| **状态** | 已修复（`0f3576e`），已恢复 |
| **触发改动** | `7595f26` —— 给 `TerminalArchive` 加 `projectPath` |
| **影响** | `~/.fleetview/state.json` 被写成 259 字节：0 项目、0 终端、0 notes |

> 一句话：**给一个已经上盘的结构体加了一个非可选字段，代价是整个看板。**

---

## 1. 事故经过

给终端存档加"项目路径"字段，让存档能跨"关闭项目再打开"存活：

```swift
struct TerminalArchive: Codable {
    var id: UUID
    var projectId: UUID
    var projectPath: String = ""     // ← 新增
    ...
}
```

看起来无害：有默认值，旧数据缺这个键应该走默认值。

**实际不是。** 链条如下：

| 环节 | 发生了什么 |
|---|---|
| 1 | Swift 合成的 `Codable` **把缺失的键一律当错误**，即使属性有默认值 |
| 2 | 磁盘上每一条旧 `TerminalArchive` 都变得无法解码 |
| 3 | `Persisted` 是**全有或全无**地解码，一个子字段炸 → 整个结构体解码失败 |
| 4 | `load()` 里 `guard let p = try? JSONDecoder().decode(...) else { seedFirstProject(); return }` —— 解不动就当"全新安装" |
| 5 | 内存状态是空的；`save()` 是防抖的，几百毫秒后把这份空**原子覆盖**了 state.json |

全程**没有任何报错**。`try?` 把错误吞了，`seedFirstProject()` 让空状态看起来像一次合法的首次启动。

### 为什么没在编译或测试时发现

- **编译期查不出**：`Codable` 的合成发生在编译期，但"旧数据缺键"是运行期事实。
- **本机测试查不出**：开发时如果 `terminalArchive` 是空数组，`[TerminalArchive]?` 解码空列表不会碰到缺键，一切正常。**只有已经有存档数据的机器才会炸**——也就是真实用户。

---

## 2. 两条规则

### 规则一：加到已上盘结构体里的字段必须是 Optional

```swift
var projectPath: String?          // ✅ 合成解码器用 decodeIfPresent，容忍缺失
var projectPath: String = ""      // ❌ 有默认值也没用，缺键即报错
```

带默认值的属性，**只在 memberwise 初始化时用得上默认值，解码时用不上**。这是 Swift `Codable` 最常被误解的一点。

替代方案（本次没采用，但同样正确）：给该类型写显式 `init(from:)`，用 `decodeIfPresent(...) ?? 默认值`。字段多时比全改 Optional 更清晰。

### 规则二：`state.json` 不该是全有或全无

规则一只堵住了这一次的触发器。真正让代价变成"整块看板"的是**解码的爆炸半径**。

`Persisted` 现在逐字段解码，读不动的丢掉：

```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func get<T: Decodable>(_ k: CodingKeys, _ t: T.Type) -> T? {
        (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil
    }
    projects  = get(.projects,  [Project].self) ?? []
    terminals = get(.terminals, [TerminalSession].self) ?? []
    ...
}
```

**schema 出问题，只该赔上出问题的那个字段，不该赔上整个文件。**

`projects` / `terminals` / `clusters` 也从"必填"改成了空默认值——半截写入的文件仍然能打开，而不是被当成完全不可读。

---

## 3. 还没做的：保存前留一份副本

`saveNow()` 用 `.atomic` 写入，这挡得住"写到一半崩溃"，**挡不住"把错误的内容完整地写进去"**——本次正是后者。

建议（尚未实现）：每次 `saveNow()` 前把上一份 `state.json` 复制为 `state.json.prev`。代价是一次小文件拷贝，收益是这类事故可以一键回退。

---

## 4. 恢复：审计日志救了大部分

没有 state.json 备份，最后是靠 `~/.fleetview/logs/audit-YYYY-MM-DD.jsonl` 重放恢复的——这是 [审计日志](2026-07-28-audit-logging-implementation.md) 意料之外的一次兑现。

| 恢复项 | 来源 |
|---|---|
| 5 个项目 | `fleetview.project.added` / `.removed` |
| 13 张终端卡片（名字、项目、cwd、agent） | `fleetview.terminal.created` / `.renamed` / `.removed` |
| 9 条 notes（**完整原文**） | `fleetview.note.added` 的 `fleetview.data.text` |
| 4 个存活会话重新挂上 | tmux 的 `fv_<uuid>` 会话名 + 终端 uuid |

两个恢复时踩到的坑，值得记：

- **`message` 里的文本是截断的**，完整原文在 `fleetview.data`。第一次重建我读了 `message`，notes 全是半截。
- **身份要取"最后一次"审计记录**，不是创建时那条。第一次重建我用了 `terminal.created` 的名字，重命名过的终端全部对不上——表现就是"卡片和终端内容对不上号"。

确实丢失的：clusters 分组、每张卡片的 token 累计 / 最后一句 prompt / 活动时间、9 条终端存档、早于日志保留窗口的 notes（17 条恢复了 9 条）。

---

## 5. 检查清单

改动 `state.json` 里任何一个持久化结构时：

- [ ] 新字段是 Optional，或该类型有显式 `init(from:)` 用 `decodeIfPresent`
- [ ] 拿一份**真实的、有数据的** `state.json` 副本试过解码，而不是只在空状态下跑
- [ ] 想清楚解码失败时会发生什么——在 FleetView 里，失败等于"当作全新安装"，然后覆盖
- [ ] 改动上线前先备份一份 `state.json`
