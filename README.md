# bili-audio —— B 站直播间「只听声音 + 看弹幕」工具（Windows）

一套工具，两个模块：

| 模块 | 入口 | 作用 |
|---|---|---|
| **音频模块**（命令行） | `bili-audio.cmd` | 只播放直播间**声音**：不建窗口、不解码视频，自动选最省带宽的推流方式 |
| **弹幕模块**（图形窗口） | `bili-gui.cmd` | 窗口**上方是实时弹幕、下方输入框可直接发弹幕**，窗口内还能一键开关声音 |

适合：想听直播（解说、电台、聊天、会议）但不想让浏览器或播放器占满 CPU / 内存 / GPU 的场景。


## 1. 系统要求

| 需要 | 说明 |
|---|---|
| Windows 10 / 11 | 使用了 Job Object 等 Windows 特性 |
| **streamlink** | 必须。负责全部 HTTPS、鉴权与分片下载 |
| **FFmpeg（ffplay）** | 必须。只做本地音频解码与播放 |
| **Python 3.8+（含 tkinter）** | 仅弹幕窗口需要。Windows 官方安装包自带 tkinter |
| Node.js | **不需要** |
| 额外 Python 包 | **不需要**（只用标准库，无需 pip install） |

## 2. 安装依赖

用 winget（推荐）：

```bat
winget install Streamlink.Streamlink
winget install Gyan.FFmpeg
winget install Python.Python.3.12
```

若不确定包 ID，可先 `winget search streamlink` / `winget search ffmpeg` 查一下。也可以手动安装：
streamlink <https://streamlink.github.io/>、FFmpeg <https://ffmpeg.org/download.html>（把 `bin` 目录加入 PATH）、
Python <https://www.python.org/downloads/windows/>（安装时勾选 *Add python.exe to PATH*）。

安装后开一个命令行验证三件事都不报错：

```bat
streamlink --version
ffplay -version
py -3 -c "import tkinter"
```

> 找不到依赖时：本工具会依次在 **PATH → Streamlink 常见安装目录 → winget 包目录** 里查找 `streamlink.exe` / `ffplay.exe`，
> 找不到会给出明确提示；也可以用 `-StreamlinkPath` / `-FfplayPath` 参数手动指定绝对路径。

## 3. 配置（config.json）

本工具只有一个配置文件 `config.json`，用记事本或任何编辑器改完保存即可（不影响系统设置）。

| 字段 | 必填 | 说明 |
|---|---|---|
| `bilibili.sessdata` | 看弹幕需要 | 登录 cookie 值。留空时会尝试复用本机 streamlink 的登录配置 |
| `bilibili.bili_jct` | **发弹幕需要** | 发弹幕的 csrf 令牌。不填就只能看、不能发 |
| `bilibili.buvid3` | 否 | 可选，一般不用管 |
| `defaults.room` | 否 | 默认直播间（房间号 / 完整地址 / `rooms` 里的别名）。示例配置指向 `example` |
| `defaults.volume` | 否 | 默认音量 0–100 |
| `defaults.stream` | 否 | `auto`（默认，有 FLV 就用 FLV 低码档）/ `flv` / `hls` |
| `defaults.max_age` | 否 | 只显示多少秒内的弹幕，默认 120 |
| `defaults.interval` | 否 | 弹幕轮询间隔秒，默认 2 |
| `rooms.<别名>.url` | — | 直播间地址或房间号，可写多个别名 |
| `rooms.<别名>.note` | 否 | 备注（只用于显示） |
| `rooms.<别名>.volume` / `.stream` | 否 | 单独给这个房间指定音量 / 推流方式 |

别名示例（可加任意多个）：

```json
"rooms": {
  "mylive": { "url": "https://live.bilibili.com/123456", "note": "常听的房间", "volume": 40 }
}
```

之后即可 `bili-audio.cmd mylive` 或 `bili-gui.cmd mylive`。

### 怎么获取 cookie

1. 浏览器登录 B 站；
2. 按 `F12` 打开开发者工具 → **Application / 应用** → **Cookies** → `https://www.bilibili.com`；
3. 复制 **`SESSDATA`** 的值填到 `bilibili.sessdata`；若要发弹幕，再复制 **`bili_jct`** 的值填到 `bilibili.bili_jct`。

> **安全提醒**：`config.json` 里存的是你账号的凭证，**请不要外发、不要提交到任何仓库、不要截图分享**。
> 工具只在你自己机器上用它向 B 站发起请求，不向任何第三方服务器发送数据。

## 4. 用法：音频模块（只听声音）

```bat
bili-audio.cmd                       :: 用 config.json 的 defaults.room
bili-audio.cmd 6                     :: 房间号
bili-audio.cmd https://live.bilibili.com/6
bili-audio.cmd mylive -Volume 40     :: 用 config.json 里的别名
bili-audio.cmd -List                 :: 列出所有别名
bili-audio.cmd 6 -Stream hls         :: 强制走 HLS（默认 auto：有 FLV 走 FLV 低码档）
bili-audio.cmd 6 -LowLatency         :: 追直播边缘（延迟更低，但更容易卡）
bili-audio.cmd 6 -RunForSeconds 600  :: 听 600 秒后自动退出
```

* 停止：`Ctrl+C`（会连带清理 ffplay / 取流进程，不留后台残留）
* 运行中调音量：任务栏音量图标右键 → **音量合成器** → 单独拖 `ffplay.exe`（无断音）
* 运行日志：`logs\bili-audio-YYYYMMDD.log`（记录选流理由、重连、错误）

## 5. 用法：弹幕模块（图形窗口）

```bat
bili-gui.cmd                          :: 用 config.json 的 defaults.room
bili-gui.cmd 6
bili-gui.cmd mylive --volume 40
```

窗口结构：

```
┌──────────────────────────────────────────────────────────┐
│ 直播间 [ mylive    ] [连接]  ☑自动滚动 [清屏]     [开声音] │
├──────────────────────────────────────────────────────────┤
│ 18:24:16 [舰长/粉丝牌18] 某某: 弹幕内容…                  │  ← 上方：实时弹幕
│ …                                                        │
├──────────────────────────────────────────────────────────┤
│ [ 输入弹幕，回车或点右侧「发送」…            ] [ 发送 ]    │  ← 下方：输入并发送
├──────────────────────────────────────────────────────────┤
│ 房间 123456（直播中） | 轮询 2.0s | 收到 60 条 / 显示 8 条 │  ← 状态栏
└──────────────────────────────────────────────────────────┘
```

* 弹幕行格式：`时间 [房管/总督·提督·舰长/粉丝牌名+等级] 昵称: 内容`；`~` 表示启动时补显的最近几条，`+` 表示新弹幕
* 「开声音」会调用与音频模块相同的播放逻辑；**关闭窗口时声音一并停止**
* 参数：`--interval N`（轮询间隔秒）、`--max-age N`（只显示 N 秒内的弹幕，0 = 不过滤）、`--volume N`
* 自检/排障：`py -3 bili-gui.py 6 --selftest 8`（打印窗口真实内容与控件坐标后退出）；
  窗口打不开时也用它，能保留控制台看到报错


## 7. 已知局限

| 局限 | 说明 |
|---|---|
| 弹幕有 1–2 秒延迟 | 长连接被风控，改用轮询的必然代价 |
| 部分直播间拿不到弹幕 | 实测官方赛事类房间（如房间 6）的轮询接口恒返回 0 条，普通房间正常 |
| 只有 HLS 的房间省不了带宽 | 自动选择只在房间提供 FLV 时生效；纯 HLS 房间仍是 2.3–3.1 Mbps |
| 音频没有键盘快捷键 | 没有窗口就没有焦点，请用 Windows 音量合成器调音量 |
| HLS 首次起播约 9 秒缓冲 | 与直播间的实时性差约 9 秒；`-LowLatency` 可压到约 3 秒但更易卡顿 |
| 不能暂停 / 拖动进度 | 直播流是实时的 |

## 8. 常见问题

| 现象 | 处理 |
|---|---|
| 提示找不到 streamlink / ffplay | 按第 2 节安装；或确认它们已在 PATH；或用 `-StreamlinkPath` / `-FfplayPath` 指定路径 |
| 完全没有声音，日志里有 `Access Denied`/403/无法取流 | 在 `config.json` 填入 `sessdata`（部分房间需要登录态） |
| 弹幕一条都没有 | 先确认房间是否在直播（状态栏会显示「直播中/未开播」）；再确认不是第 7 节提到的"官方赛事房" |
| 弹幕窗口刚打开是空的 | 正常：只显示 120 秒内的弹幕。若房间当时没人发言就会是空的，状态栏会说明跳过了多少条旧消息 |
| 发送弹幕失败，提示 `-111` | `bili_jct` 填错或已过期，重新获取一次 |
| 发送弹幕失败，提示 `-403` | 被禁言或该房间限制发言 |
| 发送弹幕失败，提示 `-352` | 撞上 B 站风控，换网络环境或稍后再试 |
| 关闭窗口后声音还在响 | 正常版本不会发生（子进程放在 Job Object 里，随窗口一起清理）；若出现请反馈 |
| 命令行报一堆语法错误且带乱码字 | `.ps1` 文件被存成了 UTF-8 **无** BOM。双击运行 `bili-audio.cmd` 会自动修复；也可手动跑 `ensure-utf8bom.ps1` |

## 9. 文件清单

| 文件 | 说明 |
|---|---|
| `README.md` | 本文档 |
| `config.json` | **唯一配置文件**（cookie、默认值、房间别名） |
| `bili-audio.cmd` | 音频模块入口（双击或命令行运行） |
| `bili-audio.ps1` | 音频模块实现 |
| `bili-gui.cmd` | 弹幕窗口入口 |
| `bili-gui.py` | 弹幕窗口实现（Python + tkinter） |
| `ensure-utf8bom.ps1` | 启动前自动修正 .ps1 的 BOM（Windows PowerShell 5.1 的编码要求） |
| `logs\` | 运行日志目录（首次运行自动创建） |

## 10. 隐私与使用须知

* 本工具**不收集、不上传任何数据**；cookie 只在你自己机器上用于向 B 站发起请求。
* `config.json` 含账号凭证，**请勿分享**；如需分享本工具，请把 `config.json` 里的 cookie 清空后再打包。
* 请遵守 B 站用户协议与直播间规则，不要用于刷屏、自动化骚扰或其他违规用途。
