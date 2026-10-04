# 排查手记（Troubleshooting notes）

> 本文记录 **2026-10-04 在一台真实 Windows 机器上的一次完整故障排查**：原始日志片段、实测数据、以及每个结论的推导过程。
>
> 机器背景：
> - Windows build `26100`（`ProductName` 注册表值写着 "Windows 10 Home China"，是升级遗留的过期字符串；**Home 版无 EFS** 这一条不依赖版本命名，见第 3 节实测）
> - 应用包 `OpenAI.Codex_26.930.3930.0_x64__2p2nqsd0c76g0`
> - 包实际装在 `D:\WindowsApps\...`；`C:\Program Files\WindowsApps\...` 是它的映射视图（同一次部署里日志中两个路径会同时出现，不是"装了两份"）

凡是标 ⚠️ 的都是**推断**而非实测，正文里会说明理由。

---

## 0. 四类故障的判别与处置

先分诊，再动手。**判错类别会做无用功甚至帮倒忙。**

| # | 类别 | 一句话判别 | 处置 | 守护能做吗 |
|---|---|---|---|---|
| ① | 启动卡死实例 | 任务管理器**有** `ChatGPT.exe`，但**一个窗口都没有**；反复点击每次都是"起个进程又瞬间退出" | 杀掉这些实例，释放单实例锁，再启动一次 | ✅ JOB 2 |
| ② | AppX 容器卡死 | 任务管理器里**一个进程都没有**，但「修复」报 `0x80073D02` | **注销 / 重启**（唯一手段） | ❌ 刻意不做 |
| ③ | 窗口不可达 | 窗口**存在**但看不到：`WS_VISIBLE=false`（隐藏）或停在最小化停放位 | 显示回来 | ✅ JOB 3 |
| ④ | 更新后慢速解包 | 更新后首次启动，几分钟没有窗口、磁盘在响 | 等（或让 JOB 1 接管） | ✅ JOB 1 |

---

## 1. 类别 ① 的根因：`load shell env` 阻塞

在历史日志里挖到的原始记录：

```text
2026-09-25T08:22:49.498Z warning Failed to load shell env caller=startup
    detail="Timed out after 5000ms." durationMs=387160
    path="C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot\bin;D:\VMware\bin\;D:\Scripts\;D:\;C:\Windows\system32;C:\W…"

2026-09-29T08:19:06.308Z warning Failed to load shell env caller=startup
    detail="Timed out after 5000ms." durationMs=5190
```

- `durationMs=387160` = **387 秒 ≈ 6.5 分钟**（同仓库 README 记录过的另一次是 **526 秒**）
- 应用自己设置了 5 秒超时（`detail="Timed out after 5000ms."`），但**它没有生效** —— 真正阻塞了 387 秒才返回
- 阻塞解除后窗口很快出现，所以"重启电脑又好了"

我顺手排除了几个常见嫌疑（均为实测）：

| 嫌疑 | 实测 | 结论 |
|---|---|---|
| WSL 查询慢（应用启动时会查 WSL） | `wsl.exe -l -v` = **0.21 秒** | 排除 |
| PowerShell profile 慢 | `powershell -Command exit` = **0.36 秒** | 排除 |
| PATH 里有网络路径 | PATH 1788 字符 / 44 条，**无 `\\` 开头项** | 排除 |

**触发条件仍未查明** —— 这正是需要守护的原因：定位不了，就兜住它。

---

## 2. 类别 ③ 的真相：`(-21333,-21333)` 是「最小化停放位」

### 2.1 最小化 vs 隐藏，数据对比

```text
# 最小化态
hwnd=0xA12E2 pid=100136 class=Chrome_WidgetWin_1
  title       = 'ChatGPT'
  IsVisible   = True   IsIconic(最小化) = True   IsZoomed = False
  rect        = (-21333,-21333)-(-21175,-21107)   尺寸 158x26
  placement   = showCmd=2 (1=正常 2=最小化 3=最大化)
                normal = (214,102)-(1494,918)     ← 正常位置很健康
  style       = 0x34C70000   WS_MINIMIZE=True  WS_VISIBLE=True

# 隐藏态
pid=131808  可见=False  最小化=False  WS_VISIBLE=False  (214,102) 1280x816  'ChatGPT'
pid=157656  可见=False  最小化=False  WS_VISIBLE=False  (0,0) 1707x1067  'ChatGPT is using your computer. Esc to cancel'
```

### 2.2 为什么判定 `-21333` 是最小化停放位

同一时刻枚举全桌面：

```text
全桌面顶层窗口数 = 561，其中 IsIconic=True 的 = 10
这 10 个里有：Chrome、微信、图片和视频、douyin、Clash Verge、Obsidian、VMware、资源管理器…
它们的 rect 全是 (-21333,-21333) 尺寸 158x26
```

**结论**：十个互不相干的应用停在同一坐标、同一尺寸 → 这是 Windows 的行为，不是某个应用的 bug。**`(-21333,-21333) 158x26` = 本机「已最小化窗口」的停放坐标。**

Windows 会更新的"窗口位置"是 `GetWindowPlacement` 里的 `normal` 字段（`(214,102)-(1494,918)`，一个完全正常的屏幕居中尺寸）。`GetWindowRect` 在最小化时返回的是停放坐标，**不该用它判断"窗口跑到屏幕外了"**。

### 2.3 由此得出的安全规则

| 状态 | 能不能自己恢复 | 守护该做什么 |
|---|---|---|
| 最小化（`IsIconic=true`） | 能（任务栏有入口） | **不动**。自动拉出来等于跟用户对着干 |
| 隐藏（`WS_VISIBLE=false`） | **不能**（任务栏没有入口） | **救**：`SW_SHOW` → `SW_RESTORE` → 定位 → 置前 —— **但仅当应用当前没有任何可用窗口时** |

### 2.4 一个必须加的附加条件（假阳性实测）

第一次实跑 `-DryRun` 时抓到：

```text
HIDDEN title='ChatGPT' rect=(127,0,1256,1067) -> showing at (127,0)
```

同一时刻该应用的窗口实况是：

```text
pid=120312 可见=True  最小化=False (214,102) 1280x816  'ChatGPT'   ← 用户正常可见的主窗口
pid=120312 可见=False 最小化=False (127,0)   1129x1067 'ChatGPT'   ← 隐藏的同尺寸次级窗口
```

**健康运行中的应用，本来就可能同时拥有一个可见主窗口和一个隐藏的次级窗口。** 只看"隐藏 + 尺寸够大"就动手，只会凭空给用户多弹一个窗口。

所以判据要再加一层：**先问"用户现在能不能看到并操作这个应用"**（存在 可见 + 非最小化 + 主窗口尺寸 + 基本在屏内的窗口）；能，就完全不碰隐藏窗口。

```text
修后：HIDDEN 1 hidden window(s) left alone - the app already has a usable on-screen window
```

这条判据（"用户能不能自己弄回来"）比"窗口是否在屏幕外"更本质。

**必须排除的特例**：电脑使用覆盖层。它的标题是 `ChatGPT is using your computer. Esc to cancel`，窗口尺寸 `1707x1067`（全屏）—— 如果按"隐藏的主窗口"逻辑把它显示出来，**整个桌面会被它盖住**。所以 v2 显式按标题排除。

---

## 3. 类别 ④ 的根因：EFS 加密属性 + 无 EFS 的系统

### 3.1 现象

更新后首次启动，应用要把包内的 Node 运行时拷到用户目录，日志显示 9 个半成品目录：

```text
.cua_node/
  .staging-45309f9050f7314b-gqyc45    files=165  size=119,896 KB
  .staging-45309f9050f7314b-7PjYNg    files= 99  size=110,854 KB
  .staging-45309f9050f7314b-EvmXOu    files=254  size=120,616 KB
  ...
  .staging-45309f9050f7314b-vXQ4L6    files=2139 size=205,360 KB   ← 最后一次，最终成功
```

同一个内容哈希、9 次尝试、每次都在 110~126 MB 处中断。成功的那个从 15:30:37 跑到 15:36:47 = **6 分 10 秒**。

### 3.2 决定性实验

```powershell
# A) 标准拷贝（Copy-Item / CopyFileW：保留加密属性）
$src = "...\app\resources\cua_node"        # 2367 个文件 / 239.7 MB
# 结果: ok=0  err=2367  elapsed=338.3s
# 错误: The specified file could not be encrypted.

# B) 流式读写（File::OpenRead + File::Create：不保留属性）
# 结果: ok=2367  err=0  elapsed=10.6s  speed=22.6 MB/s
# 产物属性: Archive（加密属性被剥掉）
```

**338 秒（全失败）vs 10.6 秒（全成功）** —— 而且 338 秒与观察到的 6 分 10 秒（370 秒）量级吻合。逐文件约 0.14 秒。

### 3.3 为什么

```text
包内文件属性        = Archive, Encrypted     ← cua_node 2367/2367 全是；ChatGPT.exe、app.asar、连目录本身也是
系统版本            = Home 版
当前用户 EFS 证书   = 无（Cert:\CurrentUser\My 里没有任何 EFS 用途的证书）
```

`CopyFileW` 默认**保留加密属性**：源文件带 `Encrypted` 时，它会对目标调用 `EncryptFile`。Home 版没有 EFS → 失败 → `ERROR_ENCRYPTION_FAILED`（"could not be encrypted"）。

因为文件其实并没有被真正加密（应用读它完全正常），所以这是**一个"孤儿加密属性"**，只在拷贝时爆雷。

### 3.4 绕过

v2 的 JOB 1 用流式拷贝（读+写），产物不带该属性，10 秒完成；并且**校验文件数 + `manifest.json` SHA256** 与官方产物一致后才就位：

```text
package manifest.json SHA256 = 4EB290B880C5493D9653176C9856193AAFA31370B74B13FCB797C46DD94F1898
staged  manifest.json SHA256 = 4EB290B880C5493D9653176C9856193AAFA31370B74B13FCB797C46DD94F1898
identical = True
```

⚠️ 注意：**不要**给这个目录加 Defender 排除项 —— 那是最初的误判方向。瓶颈不在杀毒扫描，在 EFS 失败重试。
⚠️ 也**不要**试图改 `WindowsApps` 里文件的属性：要夺取所有权、可能破坏包完整性，而且下次更新就还原。

---

## 4. 类别 ② 的现场：AppX 容器卡死

「修复」两次都失败（16:08:47–51、16:11:00–05）：

```text
错误 0x80073D02：PackagesInUseClosed 状态处理程序失败
程序包未更新，因为受影响的应用仍在运行。
    正在运行的应用数: {OpenAI.Codex_26.930.3930.0_x64__2p2nqsd0c76g0}
```

`0x80073D02` = `ERROR_PACKAGES_IN_USE`。但同一时刻：

```text
Get-Process（按 ProcessName 过滤）  = 10 个 ChatGPT 进程   ← 有进程？不，下面才是真相
WMI Win32_Process 按 OpenAI.Codex 过滤 = 0
窗口枚举                            = 0 个 ChatGPT 窗口
应用日志                            = 15:58:02 后无任何写入
```

而 `AppModel-Runtime` 日志被同一个容器的销毁事件刷屏：

```text
事件 217「已销毁…桌面 AppX 容器」：838 条，全部在同一秒
  其中 500 条挤在 143 毫秒内（16:11:45.238 → 16:11:45.381）
  容器 GUID 去重后 = 1 个：{09388FCD-BFC7-11F1-8BAC-005056C00008}
```

**读法**：AppModel 卡在一个销毁不掉的容器上空转 → 系统因此认为包"正在使用" → 修复被挡住。**重启（或注销重登）是唯一手段**，因为容器跟踪是按会话的。

**触发链条**：应用退出时状态持久化失败（见第 5 节）→ 容器没被干净销毁 → 卡死。此后每次启动都是"进程起来立刻崩"，退出码：

```text
退出码 = -36863 (0xFFFF7001)
Crashpad 源码: kTerminationCodeCrashNoDump = 0xffff7001
              「崩溃处理器无响应，客户端自我终止」
```

即"崩溃了，且崩溃处理器也没响应"，所以既没有 dump 也没有 WER 记录。

---

## 5. 顺带发现的其余三个问题

### 5.1 `EXDEV: cross-device link not permitted`（状态写不进去）

```text
[browser-sidebar-page-store] failed to persist browser sidebar pages errorCode=EXDEV
  rename 'C:\Users\darli\AppData\Roaming\Codex\web\Codex\.browser-sidebar-page-states.json.tmp-…'
      -> 'C:\Users\darli\AppData\Roaming\Codex\web\Codex\browser-sidebar-page-states.json'
```

同一个目录内的 rename 报"跨设备"。配合 `[Statsig]` 也有同样报错。后果：**关闭窗口时窗口状态存不下来**，只会反复重试。⚠️ 具体机制未查清；怀疑与前面那套属性/重定向问题同源。

### 5.2 内置插件同步从 7 月起 100% 失败

```text
[BundledPluginsMarketplace] plugin_marketplace_folder_write_failed errorCode=UNKNOWN
  UNKNOWN: unknown error, copyfile '<包内>\resources\plugins\...\plugin.json'
      -> 'C:\Users\darli\.codex\.tmp\bundled-marketplaces\openai-bundled.staging-<guid>\...'
```

`.codex\.tmp\bundled-marketplaces` 里堆着 **57 个空的 `.staging-*` 目录**（7/7 起），每个 0 文件。与第 3 节同一个病因：从包内往外拷文件（`CopyFileW` 保留加密属性）失败。**至今没成功过一次。**

### 5.3 一次"确凿"的误判：WMI 到底看不看得见这些进程

排查过程中我在一个**受限制的上下文**里反复测到：

```text
Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'"   ->  0 行
Get-Process -Name ChatGPT                                   ->  10 个
```

同一台机器、同一时刻 —— 看起来铁证如山。我据此写下"本机 WMI 看不见这些进程，依赖它的脚本会静默失效"，并且把这个结论写进了仓库。

**这个结论是错的。** 换到不受限制的上下文复测：

```text
Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'"   ->  8 行
CommandLine : "...\app\ChatGPT.exe"                                  ← 主实例
CommandLine : "C:\Program Files\WindowsApps\OpenAI.Codex_...\app\ChatGPT.exe" --type=crashpad-handler ...   ← 子进程
```

而且 v1 守护自己的日志就是现成的反证 —— 它一直在用这套 WMI 查询工作：

```text
2026-10-04 15:58:03 STUCK pid=2532 age=852s no windows -> cleaning up
2026-10-04 15:58:05 KILLED pid=2532 plus 0 child processes. Next launch will be a clean one.
2026-10-04 16:02:03 STUCK pid=157492 age=240s no windows -> cleaning up
…
2026-10-04 16:15:05 KILLED pid=26364 plus 0 child processes.
```

**15:58–16:15 之间 11 次成功清理**，实例年龄 184s～854s。

**真正的教训**：那是**测量环境的限制**（受限上下文里 WMI 查询被拦），不是被测量对象的属性。**任何结论都必须连同测量环境一起记录** ——"在沙箱里看不见"不等于"在机器上看不见"。

---

## 6. 配置类故障：`external-agent-import-sync` 与 github MCP

这两类不是"打不开"，是**配置加载失败**，所以独立成脚本。

### 6.1 误开「外部 agent 导入」会带进什么

账本文件 `~/.codex/external_agent_session_imports.json` 记录了会话导入；应用侧状态 `.codex-global-state.json` 里的 `external-agent-import-sync-state` 记录了**导入项选择**，它暴露了全部四类：

```json
"external-agent-import-sync-state":{"providerIds":["claude-code"],"selection":{
  "CONFIG:claude-code:home:Migrate C:\\Users\\darli\\.claude\\settings.json into C:\\Users\\darli\\.codex\\config.toml":true,
  "SKILLS:claude-code:home:Migrate skills from C:\\Users\\darli\\.claude\\skills to C:\\Users\\darli\\.agents\\skills":true,
  "MCP_SERVER_CONFIG:claude-code:home:Migra…":true }}
```

实测各类型的结果：

| 类型 | 实际落点 | 数量 |
|---|---|---|
| SESSIONS | `~/.codex/sessions/<日期>/rollout-*.jsonl` | 3 个对话 |
| CONFIG | `config.toml` 的 `[shell_environment_policy.set]` | 17 个键（**含一个 Anthropic token**） |
| SKILLS | **`~/.agents/skills/`**（注意：不是 `.codex/skills`） | 5 个副本 |
| MCP_SERVER_CONFIG | 运行时合并，不落盘 | → 6.2 的报错 |

`CONFIG` 那一项的判断依据：`~/.claude/settings.json` 的 `env` 段有 17 个键，与 `config.toml` 里那 17 个**一字不差**，而一个月前的 `config.toml` 备份里**一个都没有**。

### 6.2 `url is not supported for stdio in mcp_servers.github`

```text
[electron-message-handler] Request failed error={"code":-32603,
  "message":"invalid configuration: url is not supported for stdio\nin `mcp_servers.github`\n"}
  method=config/read
```

同名服务器被多方用不同传输方式定义：

| 来源 | 传输方式 |
|---|---|
| `~/.codex/config.toml` | **stdio**（`npx mcp-remote … --header-file`） |
| `~/.mcp.json` | http（`url`） |
| `~/.codex/plugins/cache/openai-api-curated/github/*/.mcp.json` | http（`url` + `bearer_token_env_var`） |
| `~/.codex/.tmp/plugins/plugins/github/.mcp.json` | http（`url` + `oauth`） |

合并后变成一个 stdio 服务器上带着 `url` → 校验失败 → **整个 config.toml 加载失败，应用无法使用**。

**踩过的坑**：一开始以为是"外部 agent 导入"干的，关掉导入后**报错依旧** —— 说明 url 来自别的来源（上面四个里我至今无法确定是哪一个）。

**有效的修法是让冲突在结构上不可能发生**：把我们这边（config.toml）也改成 http，那么"stdio 服务器上出现 url"这个矛盾无论 url 从哪来都不成立：

```toml
[mcp_servers.github]
url = "https://api.githubcopilot.com/mcp/"
bearer_token_env_var = "GITHUB_PAT"
startup_timeout_sec = 120
```

验证（改完 12 秒后读日志）：

```text
invalid configuration 错误   = 0 条
error 行                     = 0 条
mcp_extension_server_tools_empty authStatus=bearerToken … server=github    ← 认证方式被正确识别
mcp_server_startup_status_updated error=null server=github status=ready
其余服务器 aihot/arxiv/filesystem/node_repl/obsidian/playwright/tavily 全部 ready
```

### 6.3 token 的两个坑

1. **失效的 token 会伪装成"配置正确"**：`~/.codex/mcp-headers.txt` 里那个 `ghp_…` 直接请求端点返回 **401**；而环境变量 `GITHUB_PAT` 里那个返回 **200**。判断 token 是否可用，**别靠"配置看起来对"，直接打端点**：

   ```powershell
   $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
   Invoke-WebRequest -Uri 'https://api.githubcopilot.com/mcp/' -Method Post `
     -Headers @{ Authorization = "Bearer $env:GITHUB_PAT"; 'Content-Type'='application/json'; 'Accept'='application/json, text/event-stream' } `
     -Body $body -Proxy 'http://127.0.0.1:7897'      # 端点必须走代理
   ```
   `initialize` 是 MCP 的握手方法，不需要额外参数就能验证凭据。

2. **优先指向环境里已有的变量**：如果 `bearer_token_env_var` 指向的变量在**运行中的应用进程里本来就有**，改配置后**不需要重启应用**（应用会按需重读 config.toml）。反之，新设的环境变量只对**新启动**的进程生效，必须彻底退出再打开。

### 6.4 `~/.agents/skills` 是多工具共享池（删之前必读）

实测：删掉 5 个技能副本后，**DSH 的技能清单立刻少了一项** —— 证明 DSH 也在读这个池子。

而且**时间戳无法区分"新建"还是"覆盖重写"**：导入会先删同名再写入，于是 `CreationTime` 全部变成导入时刻。当时 5 个目录的时间戳都是 `16:23:55`，但其中至少一个在导入前就已经在池子里（否则 DSH 在导入之前的那次会话里不会列出它）。

**安全做法**：拿池子里每项与 `.dsh/skills`（或其它工具自己的技能目录）对比，**只存在于池子里的那些，删掉就等于从那个工具里删掉**。

### 6.5 完整清理清单（实际执行）

| # | 对象 | 处理 |
|---|---|---|
| 1 | 3 个导入的对话文件 | 删除（按账本逐条定位） |
| 2 | `config.toml` → `external-agent-import-sync-enabled` | 改为 `false` |
| 3 | `config.toml` 的 `[shell_environment_policy.set]` | 删 14 个 Anthropic/Claude 键；**保留** `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` |
| 4 | 导入账本 | 删除（留 `.bak`） |
| 5 | `.codex-global-state.json` 的 `external-agent-import-sync-state` | 移除（`claude-code` 引用 4 → 0） |
| 6 | `~/.agents/skills` 的 5 个副本 | 删 4 个（其它工具有独立副本）+ 恢复 1 个（否则某工具永久失去它） |

**第 3 项为什么保留代理键**：Codex 用 `npx` 拉起 MCP 服务器（`mcp-remote` / `tavily` / `filesystem`），那些子进程靠这段环境走代理出网；而 Anthropic 那批对 Codex 毫无用处，还把 token 泄进了 Codex 的执行环境。**迁移来的配置不能整段照单全收。**

---

## 7. 排查工具箱（本次实际用过的命令）

```powershell
# —— 看到底有没有进程（两法并用；受限上下文里 WMI 可能返回空，但机器上是正常的，见 5.3）——
Get-Process -Name ChatGPT -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'"

# —— 看窗口真实状态（含隐藏/屏幕外，带类名与 placement）——
#    关键 API: EnumWindows / IsWindowVisible / IsIconic / GetWindowPlacement / GetWindowLong(GWL_STYLE)
#    WS_VISIBLE = 0x10000000   WS_MINIMIZE = 0x20000000
#    showCmd: 1=正常 2=最小化 3=最大化

# —— 抓启动退出码（判断崩溃还是"让位"）——
$p = Start-Process "<包路径>\app\ChatGPT.exe" -PassThru
if ($p.WaitForExit(8000)) { "exit = 0x{0:X8}" -f $p.ExitCode }

# —— MSIX 激活与容器事件 ——
Get-WinEvent -LogName 'Microsoft-Windows-TWinUI/Operational' -MaxEvents 20 |
  Where-Object { $_.Message -match 'OpenAI' } |
  Select-Object TimeCreated, @{n='r';e={ if ($_.Message -match 'Access is denied') {'DENIED'} else {'OK'} }}
Get-WinEvent -LogName 'Microsoft-Windows-AppModel-Runtime/Admin' -MaxEvents 200 |
  Where-Object { $_.Message -match 'OpenAI' } | Group-Object Id | Select-Object Name, Count

# —— 修复/部署失败原因 ——
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 60 |
  Where-Object { $_.Message -match 'OpenAI' }

# —— 应用自己的日志 ——
#    <包数据>\LocalCache\Local\Codex\Logs\<年>\<月>\<日>\codex-desktop-*.log
#    会话目录名里的第一个 GUID = appSessionId，末尾数字 = 主进程 PID
#    0 字节不代表没在跑：这个应用是缓冲写，曾观察到 40 秒后才一次性落盘 300+ KB

# —— EFS 属性体检 ——
Get-Item <文件> | Select-Object Attributes      # 看有没有 Encrypted
[System.IO.File]::ReadAllBytes / OpenRead       # 流式读，可绕过属性保留
```

**读日志的一个小技巧**：`WER` 的崩溃报告在 `C:\ProgramData\Microsoft\Windows\WER\Report\...`，普通用户常常读不到（`Access is denied`）。改查 **Application 事件日志的 1000 / 1001** 更省事，`Faulting 应用程序名称` 与 `出错模块名称` 都在里面。

---

## 8. 本次排查里我犯过的错（留给后来者）

| 我一开始的判断 | 实际 | 教训 |
|---|---|---|
| "磁盘慢 / 杀软扫描 2367 个文件所以启动慢" | 是 EFS 加密属性导致的**拷贝失败重试**，与杀软无关 | 别停在"看起来合理"的解释上，**做对照实验**（338 秒 vs 10.6 秒） |
| "`-21333,-21333` 是窗口丢到屏幕外" | 是**最小化**停放位 | 判断前先看 `showcmd`/`WS_MINIMIZE`，别只看 rect |
| "9 次 staging 是用户重复点击造成的" | 部分对，但**主因**是每次尝试都要 6 分钟；且 v1 的守护还会中途杀掉它 | 结论要能同时解释"耗时"和"次数"两个数字 |
| "config.toml 的 url 是外部 agent 导入带来的" | 关掉导入后**报错依旧** | 关掉一个开关 ≠ 消除所有来源；**改成结构上不可能冲突**才可靠 |
| "应用在一个无窗口状态，说明是卡死实例" | 需要先分清是**没有窗口**还是**窗口存在但不可达** | 先把状态枚举清楚，再决定处置 |
| "隐藏的主窗口一律该救回来" | 实测健康运行的应用同时有**可见主窗口**和**隐藏的同尺寸次级窗口** —— 一刀切会凭空多弹一个窗口 | 判据要加"用户当前能不能看到"这一层；这个假阳性是**实跑 `-DryRun`** 抓出来的，不是推演出来的 |
| "WMI 在本机看不见 ChatGPT 进程，所以 v1 的清理从不触发" | 换到不受限上下文复测，**同样查询返回 8 行**；而且 v1 自己的日志显示它成功清理了 **11 次** | **在受限上下文里测出的"不可能"，不等于机器上的"不可能"**。下结论前先确认测量环境，并且**优先去找现成的反证**（这里 v1 的日志就是反证，它一直躺在那儿） |
