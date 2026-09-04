# Codex Desktop Fixer

中文 | [English](README.en.md)

![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Platform: Windows](https://img.shields.io/badge/platform-Windows-blue)

> 让 OpenAI Codex / ChatGPT 桌面端不再"打不开" —— 自动守护 + 一键修复。
>
> ⚠️ 第三方社区工具，与 OpenAI 无关。

---

## 这是什么？

Codex 桌面应用（MSIX 打包的 Electron 应用，主进程目前叫 `ChatGPT.exe`）有时会出现**"怎么点都打不开"**的情况——重启电脑又好了，过几天又犯。

这个项目提供一个**每分钟自动巡检的守护**（注册为计划任务，无窗口静默运行），自动处理两类真实故障：

| 故障 | 表现 | 守护的处理 |
|---|---|---|
| **启动卡死实例** | 应用启动早期偶发阻塞（实测 `load shell env` 一步卡 **526 秒**），期间没有任何窗口，却**占着单实例锁**——之后你每次点击都会启动新进程又瞬间静默退出 | 清理"存活超 3 分钟却没有任何窗口"的实例，释放单实例锁，下次点击即是干净启动 |
| **窗口被丢到屏幕外** | 实例恢复后主窗口被最小化到离谱坐标（实测 `-21333,-21333`），进程健康、窗口存在，但你看不到，且所有点击都被转发给这个隐形窗口 | 检测到屏幕外主窗口自动拉回主屏 |

**安全边界**：守护从不碰你的数据（聊天记录、登录状态、配置一律不读写），绝不打扰正常使用的实例（最小化、托盘隐藏、其他虚拟桌面都安全）。每次动作记录在 `%TEMP%\codex-guard.log`。

## 对应症状

- 应用**时好时坏**：有时能打开，有时点了没反应
- 反复点击图标也没用（每次点击都被隐形实例吞掉）
- 任务管理器里有 `ChatGPT.exe` 进程，但就是没有窗口
- 重启电脑 / 结束进程后"又好了"

## 为什么会这样（诊断背景）

2026 年在一台真实机器上完整排查后确认：**启动并没有失败，而是卡住了，而卡住的实例锁死了后续所有启动**。这种不对称正是"时好时坏"的来源：

- 每次点击其实都启动了进程（Windows AppModel-Runtime 事件 201），但应用日志显示会话只写了 3 行就结束——典型的**单实例让位**，不是崩溃（Windows 错误报告里一条记录都没有）
- 唯一活下来的实例，主窗口位于 `(-21333, -21333)`、最小化、尺寸 158×26——窗口存在且"可见"，只是被停在了屏幕外
- 该实例退出时冲刷的完整日志暴露了根因：`Failed to load shell env ... durationMs=526778`——启动路径阻塞了约 **9 分钟**，而应用设置的 5 秒超时根本没有生效；阻塞解除后窗口 2.5 秒内就出现了

## 安装

无需管理员权限，打开 PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

安装脚本会：把守护脚本复制到 `%LOCALAPPDATA%\CodexGuard` → 生成隐藏启动器 → 注册计划任务 `CodexGuard`（每分钟巡检一次，仅登录会话内运行）。

### 可选参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-ProcessName` | 应用主进程名（若官方改了名字） | `ChatGPT.exe` |
| `-IntervalMinutes` | 巡检间隔（分钟） | `1` |
| `-InstallDir` | 脚本安装位置 | `%LOCALAPPDATA%\CodexGuard` |

```powershell
# 例子：进程名不同的应用 / 每 2 分钟巡检 / 自定义安装目录
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ProcessName codex.exe -IntervalMinutes 2 -InstallDir D:\tools\CodexGuard
```

## 手动一键修复

应用正卡着、不想等下一轮巡检时，随时手动执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexGuard\fix-codex.ps1"
```

## 工作原理与安全规则

| 规则 | 理由 |
|---|---|
| 只处理主实例（命令行不带 `--type=` 的进程） | GPU / 渲染 / 工具子进程绝不能单独被杀 |
| 只在"存活 **>3 分钟** 且 **没有任何顶层窗口**"时清理 | 正常启动约 10 秒内出窗口；3 分钟阈值杜绝误杀 |
| 只要有窗口（哪怕隐藏 / 最小化）就一律不碰 | 用户最小化、托盘隐藏是主动行为 |
| 正常在屏内的窗口从不打扰 | 没有需要修的东西 |
| 不读写应用的任何配置文件 | 零数据风险 |
| 有动作就写日志（`%TEMP%\codex-guard.log`） | 每次自动处理都可审计 |

## 为什么不会闪黑窗？

`powershell -WindowStyle Hidden` 在**由计划任务启动时经常失效**（这就是很多守护脚本每分钟闪一下黑窗的原因）。本项目让计划任务运行 `wscript.exe`（GUI 子系统进程，**永远不会创建控制台窗口**），再由它隐藏地启动守护脚本——已实测全程无窗口闪烁。

## 验证状态（如实说明）

| 路径 | 状态 |
|---|---|
| 健康实例零误伤 | ✅ 实测 |
| 屏幕外窗口拉回（真实 `-21333` 现场） | ✅ 实测 2 次 |
| 卡死实例自动清理（无窗口超 3 分钟） | ⚠️ 判定逻辑来自真实 526 秒卡死记录，端到端清理尚待真实卡死场景验证 |
| 计划任务无窗口闪烁 | ✅ 实测 |
| 不触碰任何数据 | ✅ 设计保证（脚本内不含应用数据路径） |

判定参数（3 分钟、50 像素重叠等）可在 `codex-guard.ps1` 顶部调整。

## 卸载

```powershell
# 只移除计划任务
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

# 同时删除已安装的脚本文件
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
```

应用本身和你的数据从未被改动。

## 反馈与贡献

- 遇到问题欢迎开 [Issue](https://github.com/Muanyan-mjq/codex-desktop-fixer/issues)（附上 `%TEMP%\codex-guard.log` 和症状描述）
- 改进请提交 Pull Request

## License

[MIT](LICENSE)
