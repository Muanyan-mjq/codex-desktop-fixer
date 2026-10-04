# Codex Desktop Fixer

中文 | [English](README.en.md)

![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Platform: Windows](https://img.shields.io/badge/platform-Windows-blue)

> 让 OpenAI Codex / ChatGPT 桌面端不再"打不开" —— 自动守护 + 一键修复。
>
> ⚠️ 第三方社区工具，与 OpenAI 无关。

---

## 这是什么？

Codex 桌面应用（MSIX 打包的 Electron 应用，主进程目前叫 `ChatGPT.exe`）会以**四种互不相同的方式**表现为"打不开"。v1 覆盖了其中两类（卡死实例、窗口位置），但判据有偏差；v2 把四类都覆盖了：

| # | 故障态 | 表现 | v2 的处理 |
|---|---|---|---|
| ① | **启动卡死实例** | 进程活着但**一个顶层窗口都没有**，却**占着单实例锁** —— 之后每次点击只是"起个进程又瞬间退出" | 清理"存活超阈值且零窗口"的实例，释放锁 |
| ② | **AppX 容器卡死** | **一个进程都没有**，系统却认定"程序包正在使用"；设置里的「修复」必报 `0x80073D02` | ❌ **守护治不了** —— 只能注销 / 重启系统（脚本不会替你重启） |
| ③ | **窗口不可达** | 窗口**存在**但 `WS_VISIBLE = false`（隐藏），或停在最小化停放位 | **只在用户完全看不到窗口时**把隐藏的救回来；最小化的不碰 |
| ④ | **更新后慢速解包** | 更新后首次启动要解包内置 Node 运行时（2367 文件 / 240 MB），**约 6 分钟没有窗口**，看起来完全像"打不开" | 识别到慢路径就**接管**：自己铺好运行时（约 10 秒）再重启应用 |

**安全边界**：守护从不读写你的聊天记录、登录状态或配置；绝不打扰正常使用的实例（最小化、托盘隐藏、其他虚拟桌面都安全）。每次动作都记到 `%TEMP%\codex-guard.log`。

## 对应症状

- 应用**时好时坏**：有时能打开，有时点了没反应
- 反复点图标也没用（每次点击都被隐形实例吞掉）
- 任务管理器里有 `ChatGPT.exe`，但没有窗口
- 更新之后第一次启动要等好几分钟
- 重启电脑 / 结束进程后"又好了"

---

## v2 相对 v1 的四处变化（都有实测依据）

（第 1、2、4 条是修正 v1 的错判据；第 3 条是设计改动，顺带纠正我自己在排查中得出的一个错误结论。）

### 1. `(-21333,-21333)` 不是"丢到屏幕外"，是**最小化**

```text
showCmd     = 2          (1=正常 2=最小化 3=最大化)
WS_MINIMIZE = True
rect        = (-21333,-21333)  尺寸 158x26
normal      = (214,102)-(1494,918)     ← 恢复正常位置完全健康
同一时刻全桌面 561 个顶层窗口中有 10 个在 (-21333,-21333)
          （Chrome、微信、抖音、Clash Verge、Obsidian、VMware、资源管理器…）
```

十个互不相干的应用停在同一坐标，只可能是系统行为 —— **这是 Windows 停放"已最小化窗口"的固定坐标**。

**影响**：v1 的"屏幕外"检测会在**任何被最小化的窗口**上触发。它"修好过两次"是因为调了 `SW_RESTORE`，不是因为窗口真的在屏幕外。
**v2**：默认**不动最小化窗口**（任务栏有入口，用户自己能恢复）；需要时用 `-RescueMinimized`。

### 2. v1 主动跳过隐藏窗口 —— 恰好漏掉本机最常见的故障

v1 里这一行：

```powershell
if (-not [GuardWin]::IsWindowVisible($hwnd)) { continue }   # 隐藏窗口一律不碰
```

但实测的故障现场是：

```text
pid=131808  可见=False  最小化=False  WS_VISIBLE=False  (214,102) 1280x816  'ChatGPT'
pid=157656  可见=False  最小化=False  WS_VISIBLE=False  (0,0) 1707x1067  'ChatGPT is using your computer. Esc to cancel'
```

**最小化和隐藏，关键差别是"用户能不能自己弄回来"**：

- 最小化 → 任务栏有入口 → 用户能恢复 → **不该碰**
- 隐藏（`WS_VISIBLE=false`）→ **任务栏没有入口 → 用户没有任何正常手段** → **必须救**

**v2 新增**：**仅当应用当前没有任何可用窗口**（可见 + 非最小化 + 主窗口尺寸 + 基本在屏内）时，把隐藏的主窗口 `SW_SHOW` → `SW_RESTORE` → 定位到屏内 → 置前。

为什么要加"仅当"这一层：**实测一个健康运行中的应用，同时拥有一个可见主窗口和一个隐藏的同尺寸次级窗口**。只看"隐藏 + 尺寸够大"就动手，会凭空给用户多弹一个窗口。这一条是被 `-DryRun` 实跑抓出来的假阳性，不是纸面推演：

```text
# 修前（会误弹）
HIDDEN title='ChatGPT' rect=(127,0,1256,1067) -> showing at (127,0)

# 修后（正确跳过）
HIDDEN 1 hidden window(s) left alone - the app already has a usable on-screen window
```

**安全边界**：**永不显示电脑使用覆盖层**（标题含 `is using your computer` 的那个是全屏窗口，显示出来会盖住整个桌面）。

### 3. v1 依赖 WMI 的命令行来分辨主实例；v2 用 `Get-Process` + 整体判据

先说结论：**v1 的清理路径在真实机器上是工作的** —— 它的日志记录了 15:58–16:15 之间 **11 次成功清理**（见"验证状态"）。v2 改动的理由是**设计**，不是修 bug：

| | v1 | v2 |
|---|---|---|
| 找进程 | `Win32_Process`，还要读**命令行** | 只用 `Get-Process` |
| 分辨主实例 | 靠"命令行里没有 `--type=`" | 不需要分辨 |
| 清理判据 | 逐进程：这个 pid 有没有窗口 | **整体**：整个应用有没有窗口 |
| 判据为什么更稳 | —— | Electron 的子进程（renderer / GPU / crashpad）本来就没有窗口，逐进程判会误伤健康实例 |

**这里我犯过一个必须在仓库里记下来的错**：排查过程中我在一个**受限上下文**里反复测到 WMI 对这个进程返回 0 行，于是写成"本机 WMI 看不见这些进程、v1 的清理从不触发"。换到不受限的上下文立刻复测：

```text
Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'"   →  8 行   （受限上下文里同样是 0 行）
Get-Process -Name ChatGPT                                   →  10 个
```

**那是我的测量环境的限制，不是这台机器的属性。** 教训：测量结论必须连同测量环境一起记录 ——"沙箱里看不见"不等于"机器上看不见"。相关细节见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 第 5.3 与第 8 节。

### 4. v1 的 180 秒阈值 vs 6 分钟解包 → 亲手制造死循环

实测故障 ④ 的根因（这也是本机最隐蔽的一个）：

```text
应用包内文件属性   = Archive, Encrypted       (cua_node 里 2367/2367 个文件全都带)
系统版本           = Home 版 → 不支持 EFS
当前用户 EFS 证书  = 无
→ 标准拷贝（保留加密属性）   0 / 2367 成功，耗时 338 秒，报错 "The specified file could not be encrypted."
→ 流式读写（剥离加密属性）   2367 / 2367 成功，耗时 10.6 秒（22.6 MB/s）
```

每个文件先尝试加密再失败，白烧约 0.14 秒 → 2367 个文件 ≈ **6 分钟**，期间没有任何窗口。日志里能看到 9 个 `.staging-<内容哈希>-<随机>` 半成品目录。

**v1 的 180 秒阈值会把这种"正在合法解包、但 6 分钟没有窗口"的实例当成卡死**（6 分钟 > 180 秒）→ 进度清零 → 用户再点 → 循环。
⚠️ 这一条是**从阈值与时间窗推出来的**，没有直接日志证据：守护日志最早只到 15:58，而观测到的解包发生在 15:25–15:30。v2 的接管逻辑不需要这个推断成立 —— 它本身就是更优解（10 秒 vs 6 分钟）。
**v2 新增 ④ 的接管**：

```text
发现 runtimes\cua_node\ 下有 .staging-* 且应用已运行 > 60 秒
  → 判定为慢路径（正常拷贝只要 10 秒）
  → 从目录名读出目标哈希
  → 杀掉应用
  → 流式拷贝包内 resources\cua_node → <哈希>\（约 10 秒，校验文件数 + manifest SHA256）
  → 重启应用 → 秒开
```

因为 ④ 被消灭，① 的阈值就可以安全地设成 **300 秒**。

---

## 安装

无需管理员权限：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

安装脚本会：把 `codex-guard.ps1` / `fix-codex.ps1` / `uninstall.ps1` 复制到 `%LOCALAPPDATA%\CodexGuard` → 生成隐藏启动器 → 注册计划任务 `CodexGuard`（每分钟巡检，仅登录会话内运行）。

### 可选参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-ProcessName` | 应用主进程名（若官方改名） | `ChatGPT.exe` |
| `-IntervalMinutes` | 巡检间隔（分钟） | `1` |
| `-InstallDir` | 脚本安装位置 | `%LOCALAPPDATA%\CodexGuard` |

```powershell
# 进程名不同 / 每 2 分钟巡检 / 自定义安装目录
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ProcessName codex.exe -IntervalMinutes 2 -InstallDir D:\tools\CodexGuard
```

### 运行条件（重要 —— 决定了它什么时候"其实没在守"）

| 条件 | 说明 |
|---|---|
| **只在登录会话内运行** | 任务类型是 `InteractiveToken`。注销后、未登录时不跑（这是刻意的：它要操作窗口，必须在你的交互会话里） |
| **笔记本拔电源后仍然运行** | `install.ps1` 会把 `DisallowStartIfOnBatteries` / `StopIfGoingOnBatteries` 改成 `false`。⚠️ **`schtasks /Create` 的默认值是 `true` 且没有开关可关** —— 不改的话一拔电源守护就静默停工，而那正是你最不容易发现的时候 |
| 不叠加 | `MultipleInstancesPolicy = IgnoreNew`，上一轮没跑完不会起第二轮 |
| 审计入口 | `%TEMP%\codex-guard.log`（超过 1 MB 轮转） |

> **已经装过旧版本？** 重新跑一次 `install.ps1` 即可 —— 它会用 `/F` 覆盖任务并补上电池设置。

## 手动一键修复

不想等下一轮巡检时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexGuard\fix-codex.ps1"
```

`fix-codex.ps1` 是 `codex-guard.ps1` 的**薄封装**（同一次执行的三个职责），所以两者永远不会逻辑漂移。

想看它**会**做什么而不动手：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexGuard\codex-guard.ps1" -DryRun
```

## 参数速查（`codex-guard.ps1`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `-StuckAgeSeconds` | `300` | ① 判"卡死"的存活阈值 |
| `-StagingGraceSeconds` | `60` | ④ 判"慢路径"的宽限秒数 |
| `-RescueMinimized` | 关 | 是否也拉回**最小化**的窗口（默认尊重用户的最小化） |
| `-NoRelaunch` | 关 | ④ 铺好运行时后不自动重启应用 |
| `-MainWinMinSize` | `400` | ③ 隐藏窗口至少要这么大才算主窗口 |
| `-DryRun` | 关 | 只报告，不动作 |

## 工作原理与安全规则

| 规则 | 理由 |
|---|---|
| 进程发现用 `Get-Process`，不依赖 WMI 的命令行 | 少一个外部依赖；命令行解析在受限上下文里也不可靠（见上文第 3 条） |
| ① 只在"**整个应用零顶层窗口** 且存活超阈值"时清理 | Electron 子进程本来就没窗口；逐进程判断会误伤 |
| ③ 只救**隐藏**的主窗口，且**仅当应用没有任何可用窗口时**；**最小化的一律不碰** | 最小化有任务栏入口；而用户已经能看到窗口时，隐藏的同级窗口是有意隐藏的 |
| ③ 永不显示电脑使用覆盖层 | 它是全屏窗口，显示出来会盖住桌面 |
| ④ 只在"`.staging-*` 存在超过 60 秒"时接管 | 正常拷贝 10 秒完成，60 秒还没完就是慢路径 |
| ④ 拷贝后校验文件数 + `manifest.json` SHA256 才就位 | 绝不把自己弄的坏副本塞给应用 |
| ② **不做任何自动处理** | `0x80073D02` 脚本修不了，重启会丢用户正在做的事 —— 留给人工判断 |
| 不读写应用的聊天 / 配置 / 账号数据 | 零数据风险 |
| 有动作就写日志（`%TEMP%\codex-guard.log`，1 MB 轮转） | 每次自动处理都可审计 |

## 为什么不会闪黑窗？

`powershell -WindowStyle Hidden` 在**由计划任务启动时经常失效**（这就是很多守护脚本每分钟闪一下黑窗的原因）。本项目让计划任务运行 `wscript.exe`（GUI 子系统进程，**永远不会创建控制台窗口**），再由它隐藏地启动守护脚本。

---

## 附带的两个工具（不同故障类别）

这两个不是"打不开"，而是 Codex 桌面端的**配置类**故障，所以放进本仓库但独立成脚本。

### `remove-claude-imports.ps1` —— 撤销"外部 agent 导入"

应用里有一个 `external-agent-import-sync`（把 Claude Code 的会话 / 配置 / 技能导入 Codex）。误开之后它会：

| 导入物 | 落点 |
|---|---|
| 对话 | `~/.codex/sessions/<日期>/rollout-*.jsonl` |
| 配置 | `~/.claude/settings.json` 的 `env` 段整段写进 `config.toml` 的 `[shell_environment_policy.set]`（**含 token**） |
| MCP 配置 | 运行时合并，常见副作用就是下面那个 `mcp_servers.github` 报错 |
| 技能 | `~/.agents/skills/` |

用法（**先彻底退出应用，含托盘**）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1 -DryRun   # 预演
powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1
```

它会关掉开关、按账本**直接删除**导入的对话文件、并备份 `config.toml`。细节与三个坑见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

### `fix-github-mcp.ps1` —— 修 `url is not supported for stdio in mcp_servers.github`

同一个 MCP 服务器名 `github` 被**多方用不同传输方式**定义，合并后报错：

| 来源 | 传输方式 |
|---|---|
| `~/.codex/config.toml` | **stdio**（`npx mcp-remote`） |
| `~/.mcp.json` | http（`url`） |
| 商店插件 / 插件缓存 | http（`url`） |

合并结果 = 一个 stdio 服务器上带了 `url` → 校验失败，**config.toml 整体加载失败，应用没法用**。

```powershell
# 推荐：把 config.toml 这边也改成 http，与其它来源一致（与 url 来自哪一方无关）
... -File fix-github-mcp.ps1 -Mode Native -SetToken

# 保守：不动 config.toml 和密钥，只把 ~/.mcp.json 里的键名改掉
... -File fix-github-mcp.ps1 -Mode RenameImport
```

`-SetToken` 会从 `~/.codex/mcp-headers.txt` 提取 token 并写成用户环境变量（**token 不会打印到屏幕**）。若你已有可用的 `GITHUB_PAT` 环境变量，直接把 `bearer_token_env_var` 指向它更省事。

> 环境变量只对**新启动**的进程生效 → 改完要彻底退出应用再打开。

---

## 验证状态（如实说明）

| 项 | 状态 |
|---|---|
| 各脚本语法（Windows PowerShell 5.1 解析器） | ✅ 已通过 |
| `-DryRun` 实跑 | ✅ 三个脚本都实跑过 |
| 计划任务无窗口闪烁 | ✅ 实测（v1 沿用，未改） |
| ① 健康实例零误伤 | ✅ 设计保证；v2 判据改为整体条件后更保守 |
| ① 端到端清理 | ✅ **实测**：v1 在真实机器上 15:58–16:15 成功清理 **11 次**（日志 `STUCK pid=… age=…s no windows -> cleaning up` + `KILLED pid=…`），年龄从 184s 到 854s；v2 沿用同一判据并改为整体条件 |
| 计划任务全链路 | ✅ **v2 实测**：`schtasks → wscript.exe → powershell → codex-guard.ps1` 跑通，日志落在 `%TEMP%\codex-guard.log`：`17:04:03 ---- guard run (dryRun=False) ----` |
| ③ 隐藏窗口救援 | 判据 ✅ **已在真实机器上实跑 `-DryRun` 验证**（能正确区分"应用有可用窗口"与"完全没有窗口"，并抓出过一次假阳性）；`ShowWindow` 的实际生效 ⚠️ 仍未端到端验证（受限沙箱里对别的进程无效） |
| ④ 接管慢速解包 | ⚠️ **推断**。拷贝产物与官方产物的 `manifest.json` SHA256 已实测一致，但"应用接受手工放置的目录"要等下次应用更新才能真实验证 |
| ② AppX 容器卡死 | 只有"重启可解"这一条实测结论；脚本刻意不处理 |
| 不触碰任何数据 | ✅ 设计保证（脚本内不含应用聊天 / 账号路径） |

判定参数都在 `codex-guard.ps1` 顶部或命令行参数里，可自行调整。

**首次上线的建议**：先手动跑 `fix-codex.ps1`（而不是计划任务），在 `%TEMP%\codex-guard.log` 里确认它的判断符合预期，再让计划任务接管。

## 卸载

```powershell
# 只移除计划任务
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

# 同时删除已安装的脚本文件
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
```

应用本身和你的数据从未被改动。

## 排查手记

完整的排查过程、原始日志证据、以及 `-21333` / WMI / EFS 属性的实测数据，见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

## 反馈与贡献

- 遇到问题欢迎开 [Issue](https://github.com/Muanyan-mjq/codex-desktop-fixer/issues)（附上 `%TEMP%\codex-guard.log` 和症状描述）
- 改进请提交 Pull Request

## License

[MIT](LICENSE)
