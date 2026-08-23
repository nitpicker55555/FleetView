# macOS TCC 权限：为什么 FleetView 反复索权，以及怎么彻底解决

| | |
|---|---|
| **文档类型** | 排障复盘 + 运维手册 |
| **创建日期** | 2026-08-23 |
| **状态** | 已解决（文件访问、屏幕录制）；辅助功能待处理 |
| **对应代码版本** | `c8fa298` |
| **相关改动** | `c1a6e81`（固定身份签名）、`04846f9`（ATS） |

> 症结一句话：**TCC 记录里存的是"授权时那个 app 的签名要求"。把 app 从 ad-hoc 换成固定证书之后，此前所有授权都对不上号——开关看着是开的，实际全部失效。**

---

## 1. 两个必须先建立的概念

### 1.1 TCC 靠"指定要求"认 app，不是靠路径

每条 TCC 授权里存着一个 `csreq` blob —— 授权那一刻该 app 的**指定要求（designated requirement）**。之后每次访问，系统拿当前 app 去匹配这个要求。两种签名产生的要求完全不同：

```
ad-hoc 签名：   designated => cdhash H"aa3d8a32…"
                              ↑ 就是这个二进制的哈希本身

固定证书签名： designated => identifier "ai.eigent.fleetview"
                              and certificate leaf = H"4904e521…"
                              ↑ 只跟 bundle id + 证书绑定
```

**ad-hoc 的"身份"就是二进制内容。** 每次 `swift build` 产出的二进制都不同 → cdhash 不同 → macOS 认为这是**另一个 app** → 所有授权作废。

FleetView 的开发节奏是一天装好几次，于是表现为"权限老是弹"。

### 1.2 子进程的权限记在"责任进程"头上

FleetView 起的终端是它的子进程。终端里的 agent 读 `~/Desktop`、`~/Downloads` 时，macOS 把请求记在 **FleetView** 头上——弹窗上写的也是 "FleetView"。

这解释了一个反直觉现象：**项目全在 `~/PycharmProjects`（非受保护目录），却照样弹窗**。弹的不是项目扫描，是 agent 在终端里碰到的其它位置。

---

## 2. 完整时间线（含三次错误判断）

| 步骤 | 做了什么 | 结果 |
|---|---|---|
| 1 | 查签名：`Signature=adhoc`，`TeamIdentifier=not set`，钥匙串 0 个可用身份 | 定位根因 |
| 2 | 建自签名证书 → `security import` | ❌ `MAC verification failed` |
| 3 | 试用钥匙串里已有的 `Puzhen Assistant Dev` 签名 | ❌ `errSecInternalComponent`，不可用 |
| 4 | 加 `-legacy -macalg sha1` 重做 p12 | ✅ 导入成功 |
| 5 | 改 `package_app.sh`：有固定身份就用，否则退回 ad-hoc | ✅ |
| 6 | 重装后仍弹窗 → 猜"tmux 脱离成守护进程，责任进程是它自己" | ❌ **判断错误** |
| 7 | 据此让用户杀掉 tmux 服务器 | ❌ **代价：7 个会话被销毁，且无必要** |
| 8 | 用户把 FleetView 的 FDA **删掉重加** | ✅ 文件权限立刻生效 |
| 9 | 截屏仍失败，猜"进程启动时缓存了决定，要重启 tmux" | ❌ **判断错误**，重启后仍失败 |
| 10 | 猜"授权与重启差一秒的竞态" | ❌ **判断错误** |
| 11 | 把 `csreq` blob 挖出来直接比对 | ✅ **真凶：记录没被真正重写** |
| 12 | 屏幕录制**删掉重加** | ✅ 截屏成功 |

**三次猜错的共同点**：都在推理"权限为什么传不到"，而没有去看"权限记录本身长什么样"。终结猜测的是第 11 步——一条 `sqlite3` 查询。

---

## 3. 决定性证据：csreq 比对

拿到 FDA 之后就能读 TCC 库了（这本身是个先有鸡还是先有蛋：**没有 FDA 就读不了 TCC 库**）。三条记录一比，结论立刻清楚：

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, hex(csreq) from access where client='ai.eigent.fleetview';"
```

| 记录 | `auth_value` | csreq 里含 bundle id + 证书哈希 | 实际能用吗 |
|---|---|---|---|
| `kTCCServiceSystemPolicyAllFiles` | 2 | ✅ | ✅ |
| `kTCCServiceScreenCapture` | 2 | ✅（删掉重加之后） | ✅ |
| `kTCCServiceAccessibility` | 2 | ❌（仍是 7 月的旧 csreq） | ❌ |

**三条都写着"允许"，但只有 csreq 被重写过的那两条真正管用。**

---

## 4. 关键操作：**删掉重加**，不是切换开关

这是整件事里最容易踩空的一步。

| 操作 | `auth_value` | `last_modified` | **csreq** | 生效？ |
|---|---|---|---|---|
| 开关关掉再打开 | 更新 | 更新 | **不变** | ❌ |
| `−` 删除，再 `+` 添加 | 更新 | 更新 | **按当前签名重写** | ✅ |

屏幕录制那条实测过：20:17:27 切换开关 → 时间戳变了、`CGPreflightScreenCaptureAccess()` 仍是 `false`；20:24:28 删掉重加 → csreq 里出现证书哈希、preflight 变 `true`、截屏成功。

> 系统设置里 **`−` 删除 → `+` 重新添加 `/Applications/FleetView.app`**。只切开关是无效的。

### 为什么失败时是"静默"的

记录存在（tccd 认为已经决定过），只是匹配失败。所以它**既不放行也不询问**：

- `screencapture` 报 `could not create image from display`
- `CGPreflightScreenCaptureAccess()` 返回 `false`
- 但**不弹窗**——弹窗只在"从未决定过"时出现

---

## 5. 两次被推翻的直觉

### 5.1 「tmux 脱离成守护进程，所以责任进程是它自己」—— 错

tmux 服务器确实 `parent = launchd`，但 `CGRequestScreenCaptureAccess()` 弹出的对话框写的是 **"FleetView" 想要录制此电脑的屏幕**。责任进程自始至终是 FleetView。

代价：我据此建议把 `/opt/homebrew/.../tmux` 加进 FDA。用户没照做，直接重给了 FleetView，反而解决了。事后查 TCC 库，**里面根本没有 tmux 的记录**。

### 5.2 「权限在进程启动时锁定，所以要重启 tmux」—— 错

时间戳可以证伪：

```
20:11:42  tmux 服务器启动
20:14:09  FDA 授权写入            ← 晚于 tmux 启动
          → 该 tmux 下的 shell 立刻能读 ~/Library/Mail
20:19:09  tmux 服务器再次启动
20:24:28  屏幕录制授权重写        ← 又晚于 tmux 启动
          → 同一个 tmux 下立刻能截屏
```

**两项权限都在授权之后立刻对已存在的进程生效，不需要重启。** 我为此让用户杀过两次 tmux 服务器，第一次销毁了 7 个会话——**完全没有必要**。

> 教训：`tmux -L fleetview kill-server` 会销毁全部终端会话（`AppState.reopenTerminal` 能靠 `--resume` 接回，但正在 working 的会被打断）。在有实证之前不要动它。

---

## 6. 建立固定签名身份

### 6.1 生成证书（命令行）

`security import` 读不了 OpenSSL 3 默认产出的 p12 —— 它默认用 SHA-256 做 MAC，macOS Security 框架不认，报的却是 `MAC verification failed (wrong password?)`，把人往口令方向带。**必须降到 SHA-1 + 3DES**：

```bash
openssl req -x509 -newkey rsa:2048 -keyout fvkey.pem -out fvcert.pem -days 3650 -nodes \
  -config <(printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=FleetView Local Signing\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')

openssl pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey fvkey.pem -in fvcert.pem -out fv.p12 -name "FleetView Local Signing" -passout pass:fvlocal

security import fv.p12 -k ~/Library/Keychains/login.keychain-db -P fvlocal -T /usr/bin/codesign
```

GUI 等价做法：**钥匙串访问 → 证书助理 → 创建证书 → 类型「代码签名」、自签名**。

证书显示 `CSSMERR_TP_NOT_TRUSTED` 是正常的（自签名未被信任），**不影响用它签名**。

### 6.2 打包脚本

`scripts/package_app.sh` 已改为：

```bash
FV_SIGN_ID="${FV_SIGN_ID:-FleetView Local Signing}"
if security find-identity -p codesigning | grep -qF "$FV_SIGN_ID"; then
    echo "▸ Signing with \"$FV_SIGN_ID\" (permissions will survive this install)"
    codesign --force --deep --sign "$FV_SIGN_ID" "$APP" || <退回 ad-hoc>
else
    echo "▸ No \"$FV_SIGN_ID\" identity — signing ad-hoc; macOS will re-ask for permissions"
    codesign --force --deep --sign - "$APP"
fi
```

**两条分支都会明确打印走了哪条**——差别在下一次弹窗之前是看不见的，所以必须说出来。

被替换掉的旧注释写的是"ad-hoc 签名让 TCC 权限跨重建保持稳定"，**说反了**。

### 6.3 证书不进仓库

私钥进 git 等于公开签名身份。所以**每台机器各建一份**，指定要求里的 `certificate leaf` 哈希本来就该一人一份。别人 clone 后不建证书，脚本会走 ad-hoc 分支并打印提示。

---

## 7. 顺带解决的 ATS（不是 TCC，但同一轮排查）

app 内嵌 peer 看板时，`100.64.0.0/10`（Tailscale CGNAT 网段）的明文 HTTP 被 ATS 拒绝，报 `NSURLErrorDomain -1022`，而 `curl` 一切正常——**命令行不受 ATS 管**。

`NSAllowsLocalNetworking` 只放行 RFC1918（`10/8`、`172.16/12`、`192.168/16`）和 `.local`，**CGNAT 不在其中**，而 tailnet 地址是运行时才知道的，无法预先列成例外。

**一个只能靠实测发现的坑**：`NSAllowsLocalNetworking` 与 `NSAllowsArbitraryLoads` **同时存在时，新系统会忽略后者**。两个都写等于前者白写，删掉前者才通。

最终配置（`package_app.sh` 生成的 Info.plist）：ATS 整体关闭，再把唯一的公网主机 `github.com` 单独收回严格模式（TLS 1.2 + 前向保密）。FleetView 自己的流量本来就是私有网络上的明文 HTTP，它的服务端根本没有 TLS——ATS 那套模型描述的不是它。

---

## 8. 排障手册

### 8.1 先看这三条

```bash
# 1) 现在是什么签名？ad-hoc 就是根因
codesign -d -r- /Applications/FleetView.app | tail -1

# 2) TCC 里有哪些记录、什么时候写的（需要 FDA）
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, auth_value, datetime(last_modified,'unixepoch','localtime')
   from access where client='ai.eigent.fleetview';"

# 3) 记录绑的是不是当前证书 —— 开关状态不能说明问题
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, hex(csreq) from access where client='ai.eigent.fleetview';" \
  | grep -i 4904e521      # 换成你自己证书的哈希
```

**判据**：`auth_value=2` 但 csreq 里没有你的证书哈希 → 这条记录是死的，**删掉重加**。

### 8.2 各服务的验证手段

| 服务 | 验证方法 |
|---|---|
| 完全磁盘访问 | `ls ~/Library/Mail`、`sqlite3 <TCC.db> "select 1"` |
| 屏幕录制 | `CGPreflightScreenCaptureAccess()`（比 `screencapture` 的报错准）；`screencapture -x out.png` 后看**文件大小**——黑屏只有几 KB |
| 辅助功能 | `AXIsProcessTrusted()` |

### 8.3 查不到的东西（别浪费时间）

- **TCC 日志默认被隐藏**：`log show --predicate 'process == "tccd"'` 什么也拿不到
- **`launchctl procinfo <pid>` 要 root**，拿不到"责任进程"
- **`screencapture` 需要真 TTY**：命令行里报 `stdin is not a terminal`，`script` 在这个环境也分配不了 pty ——**可行的办法是在 FleetView 自己的终端里跑**，那是真 pty

### 8.4 复现 ATS 条件的办法

造一个最小 `.app` bundle（只要 `Contents/MacOS/<bin>` + `Info.plist`），把 `NSAppTransportSecurity` 抄进去，用 `swiftc` 编一个发请求的小程序放进去跑。`Bundle.main` 按可执行文件位置解析，ATS 会按那份 Info.plist 生效——**这比在真 app 里试改一次装一次快得多**。

---

## 9. 当前状态与遗留

| 项 | 状态 |
|---|---|
| 签名身份 | `FleetView Local Signing`（`4904e521…`），已在 `package_app.sh` 中自动使用 |
| 完全磁盘访问 | ✅ csreq 已绑当前证书 |
| 屏幕录制 | ✅ csreq 已绑当前证书 |
| **辅助功能** | ⚠️ **csreq 仍是 7 月的旧记录，实际失效**。若有功能依赖它，需**删掉重加** |
| **另一台机器 `100.71.60.45`** | ⚠️ 无签名证书，仍走 ad-hoc，会重演整个问题 |

---

## 10. 检查清单

改动签名方式之后：

- [ ] `codesign -d -r-` 确认指定要求含 `certificate leaf`，不是 `cdhash`
- [ ] **每一项**已授予的权限都要 `−` 删除 + `+` 重新添加（切开关无效）
- [ ] 用 API 验证，不要只看设置面板里的开关（`CGPreflightScreenCaptureAccess()` / `AXIsProcessTrusted()`）
- [ ] 别急着重启 tmux 服务器——先证明有必要，它会销毁全部终端会话
