# Codex Desktop Fixer

[中文](README.md) | English

![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Platform: Windows](https://img.shields.io/badge/platform-Windows-blue)

> Stop the OpenAI Codex / ChatGPT desktop app from "not opening" — auto-guard plus one-shot repair.
>
> ⚠️ Community tool, not affiliated with OpenAI.

---

## What is this?

The Codex desktop app (an MSIX-packaged Electron app; its main process is currently `ChatGPT.exe`) can present as "it just won't open" in **four distinct ways**. v1 covered two of them (stuck instances, window placement) but with wrong criteria; v2 covers all four:

| # | Failure mode | What you see | What v2 does |
|---|---|---|---|
| ① | **Stuck instance** | Processes are alive but the app owns **zero top-level windows**, and it holds the **single-instance lock** — so every later click just spawns a process that exits instantly | Reaps app instances that have been alive past the threshold with zero windows, releasing the lock |
| ② | **Wedged AppX container** | **Not a single process exists**, yet Windows insists the package is in use; "Repair" in Settings always fails with `0x80073D02` | ❌ **Cannot be fixed by a script** — only sign-out / reboot clears it (this tool never reboots your machine) |
| ③ | **Unreachable window** | The window **exists** but has `WS_VISIBLE = false` (hidden), or sits at the minimization parking spot | Hidden ones are shown again **only when the user cannot see any window at all**; minimized ones are left alone |
| ④ | **Slow runtime staging after an update** | First launch after an update unpacks a bundled Node runtime (2,367 files / 240 MB) — about **6 minutes with no window at all**, which looks exactly like "won't open" | Detects the slow path and **takes over**: lays down the runtime itself (~10 s), then restarts the app |

**Safety boundary**: the guard never reads or writes your chats, sign-in state, or config; it never disturbs a healthy instance (minimized, tray-hidden, other virtual desktops are all safe). Every action is logged to `%TEMP%\codex-guard.log`.

## Symptoms this covers

- The app is **intermittent**: sometimes it opens, sometimes clicking does nothing
- Clicking the icon repeatedly does not help (each click is swallowed by an invisible instance)
- `ChatGPT.exe` shows up in Task Manager, but there is no window
- The first launch after an update takes several minutes
- Rebooting / killing the processes "fixes it again"

---

## Four changes v2 makes to v1 (all backed by measurements)

(Items 1, 2 and 4 correct wrong criteria in v1; item 3 is a design change that also corrects a wrong conclusion I reached while investigating.)

### 1. `(-21333,-21333)` is **minimized**, not "off-screen"

```text
showCmd     = 2          (1=normal 2=minimized 3=maximized)
WS_MINIMIZE = True
rect        = (-21333,-21333)  size 158x26
normal      = (214,102)-(1494,918)     <- the restore position is perfectly healthy
At the same moment, 10 of the 561 top-level windows on the desktop sit at (-21333,-21333)
          (Chrome, WeChat, Douyin, Clash Verge, Obsidian, VMware, Explorer, ...)
```

Ten unrelated applications parked at the exact same coordinate can only be a system behavior — **that is the fixed coordinate Windows uses for minimized windows**.

**Impact**: v1's "off-screen" check fired on **any minimized window**. It "worked twice" because it called `SW_RESTORE`, not because the window was actually off-screen.
**v2**: leaves minimized windows alone by default (they are reachable from the taskbar); pass `-RescueMinimized` if you want them pulled forward.

### 2. v1 skipped hidden windows — which happens to be the most common failure here

The line in v1:

```powershell
if (-not [GuardWin]::IsWindowVisible($hwnd)) { continue }   # never touch hidden windows
```

But the actual failure state measured on this machine was:

```text
pid=131808  visible=False  minimized=False  WS_VISIBLE=False  (214,102) 1280x816  'ChatGPT'
pid=157656  visible=False  minimized=False  WS_VISIBLE=False  (0,0) 1707x1067  'ChatGPT is using your computer. Esc to cancel'
```

**Minimized vs hidden — the decisive difference is whether the user can recover it themselves**:

- Minimized → there is a taskbar entry → the user can restore it → **leave it alone**
- Hidden (`WS_VISIBLE=false`) → **no taskbar entry → the user has no normal way back** → **must be rescued**

**v2 adds**: hidden + main-window sized (≥400×400) + has a title → `SW_SHOW` → `SW_RESTORE` → move on-screen → foreground, **and only when the app currently has no usable window** (visible, not minimized, main-window sized, mostly on-screen).

Why that extra condition: a **healthy running app was measured owning one visible main window *and* one hidden same-sized sibling window**. Acting on "hidden + big enough" alone would have popped an extra window at the user out of nowhere. This false positive was caught by an actual `-DryRun` on a live machine, not by reasoning on paper:

```text
# before the fix (would have popped it)
HIDDEN title='ChatGPT' rect=(127,0,1256,1067) -> showing at (127,0)

# after the fix (correctly skipped)
HIDDEN 1 hidden window(s) left alone - the app already has a usable on-screen window
```

**Safety boundary**: **never show the computer-use overlay** (the one titled `is using your computer` is a full-screen window; showing it would cover the entire desktop).

### 3. v1 depended on WMI's command line to tell main instances apart; v2 uses `Get-Process` plus a whole-app criterion

First, the conclusion: **v1's reap path did work on the real machine** — its log records **11 successful reaps** between 15:58 and 16:15 (see "Verification status"). v2 changed this for **design** reasons, not to fix a bug:

| | v1 | v2 |
|---|---|---|
| Finding processes | `Win32_Process`, and reading the **command line** | `Get-Process` only |
| Telling main instances apart | by "no `--type=` in the command line" | not needed at all |
| Reap criterion | per process: does this pid own a window? | **whole app**: does the app own any window? |
| Why that is steadier | — | Electron's helpers (renderer / GPU / crashpad) never own a window, so a per-process test would misfire on healthy instances |

**A mistake I made during the investigation, and why it belongs in this repo**: while measuring from a **restricted context** I repeatedly saw WMI return 0 rows for these processes, and I wrote it up as "WMI cannot see them on this machine, so v1's reap can never fire". Re-testing from an unrestricted context:

```text
Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'"   ->  8 rows   (same query: 0 rows from the restricted context)
Get-Process -Name ChatGPT                                   ->  10 processes
```

**That was a limitation of my measuring environment, not a property of the machine.** The lesson: a measurement must always be recorded together with the environment it was taken in — "invisible from inside a sandbox" is not "invisible on the machine". Details in [TROUBLESHOOTING.md](TROUBLESHOOTING.md) sections 5.3 and 8.

### 4. v1's 180-second threshold vs a 6-minute unpack → v1 created the loop itself

Measured root cause of ④ (the most subtle one on this machine):

```text
Attribute of files inside the app package = Archive, Encrypted   (2,367 / 2,367 files in cua_node)
OS edition                                = Home -> no EFS support
EFS certificate for the current user      = none
-> plain copy (preserves the encryption attribute)  0 / 2,367 succeeded, 338 s, "The specified file could not be encrypted."
-> streaming read/write (drops the attribute)       2,367 / 2,367 succeeded, 10.6 s (22.6 MB/s)
```

Each file first tries to re-encrypt the destination, fails, and wastes ~0.14 s → 2,367 files ≈ **6 minutes**, with no window on screen. The logs contain 9 half-finished `.staging-<content hash>-<random>` directories.

**v1's 180-second threshold would classify a legitimately-staging instance (6 minutes, no window) as stuck** (6 min > 180 s) → progress reset → the user clicks again → loop.
⚠️ That is **derived from the threshold and the timing**, not from a direct log: the guard log only starts at 15:58, while the staging observed here happened at 15:25–15:30. v2's takeover does not depend on that inference being right — it is simply the better answer (10 s instead of 6 min).
**v2 takes over ④**:

```text
Sees a .staging-* directory under runtimes\cua_node\ while the app has been up > 60 s
  -> declares the slow path (a clean copy needs 10 s)
  -> reads the target hash from the directory name
  -> kills the app
  -> stream-copies the package's resources\cua_node to <hash>\ (~10 s; verifies file count + manifest SHA256)
  -> restarts the app -> instant
```

Because ④ no longer exists as a legitimate reason for a long window-less startup, ①'s threshold is safe at **300 seconds**.

---

## Install

No administrator rights needed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

The installer copies `codex-guard.ps1` / `fix-codex.ps1` / `uninstall.ps1` to `%LOCALAPPDATA%\CodexGuard`, generates a hidden launcher, and registers the scheduled task `CodexGuard` (every minute, only while you are logged on).

### Options

| Option | Meaning | Default |
|---|---|---|
| `-ProcessName` | Main process name (if upstream renames it) | `ChatGPT.exe` |
| `-IntervalMinutes` | Check interval in minutes | `1` |
| `-InstallDir` | Install location | `%LOCALAPPDATA%\CodexGuard` |

```powershell
# different process name / every 2 minutes / custom install dir
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ProcessName codex.exe -IntervalMinutes 2 -InstallDir D:\tools\CodexGuard
```

### Runtime conditions (important - they decide when it is *not* actually guarding)

| Condition | Detail |
|---|---|
| **Only inside your logon session** | The task is `InteractiveToken`. It does not run while you are signed out (deliberately: it manipulates windows, so it needs your interactive session) |
| **Keeps running on battery** | `install.ps1` rewrites `DisallowStartIfOnBatteries` / `StopIfGoingOnBatteries` to `false`. ⚠️ **`schtasks /Create` defaults both to `true` and offers no switch for them** - leave that alone and the guard silently stops the moment you unplug, which is exactly when you are least likely to notice |
| No stacking | `MultipleInstancesPolicy = IgnoreNew`, so a slow pass never overlaps the next one |
| Audit trail | `%TEMP%\codex-guard.log` (rotated at 1 MB) |

> **Installed an older version before?** Just run `install.ps1` again - it overwrites the task with `/F` and applies the battery settings.

## One-shot manual repair

When the app is stuck right now and you do not want to wait for the next scheduled pass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexGuard\fix-codex.ps1"
```

`fix-codex.ps1` is a **thin wrapper** around `codex-guard.ps1` (the same three jobs, one pass), so the two can never drift apart.

To see what it *would* do without touching anything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexGuard\codex-guard.ps1" -DryRun
```

## Parameter reference (`codex-guard.ps1`)

| Option | Default | Meaning |
|---|---|---|
| `-StuckAgeSeconds` | `300` | ① age threshold for declaring an instance stuck |
| `-StagingGraceSeconds` | `60` | ④ grace period before declaring the slow path |
| `-RescueMinimized` | off | Also pull **minimized** windows forward (off by default to respect the user) |
| `-NoRelaunch` | off | ④ do not restart the app after the runtime is laid down |
| `-MainWinMinSize` | `400` | ③ minimum size for a hidden window to count as the main window |
| `-DryRun` | off | Report only, change nothing |

## How it works and its safety rules

| Rule | Why |
|---|---|
| Process discovery uses `Get-Process`, not WMI's command line | One less external dependency, and command-line parsing is unreliable in restricted contexts too (see correction 3) |
| ① only reaps when the **whole app has zero top-level windows** and is past the threshold | Electron helpers never own a window; a per-process test would misfire |
| ③ rescues **hidden** main windows only, and **only when the app has no usable window at all**; **minimized windows are never touched** | Minimized windows have a taskbar entry, and when the user can already see a window a hidden sibling is intentional |
| ③ never shows the computer-use overlay | It is a full-screen window and would cover the desktop |
| ④ only takes over when a `.staging-*` dir is still present after 60 s | A clean copy completes in 10 s; still going after 60 s means the slow path |
| ④ verifies file count + `manifest.json` SHA256 before publishing | Never hands the app a broken copy of our own making |
| ② **is deliberately not automated** | `0x80073D02` cannot be fixed by a script, and rebooting would drop whatever the user is doing — that stays a human decision |
| Never reads or writes app chat / config / account data | Zero data risk |
| Logs every action (`%TEMP%\codex-guard.log`, rotated at 1 MB) | Every automatic action is auditable |

## No flashing console window

`powershell -WindowStyle Hidden` frequently has **no effect when launched from a scheduled task** (that is why many watchdog scripts flash a black window every minute). This project has the task run `wscript.exe` (a GUI-subsystem process that **never creates a console window**), which then starts the guard hidden.

---

## The two bundled tools (different failure class)

These are not "won't open"; they are **configuration** failures of the Codex desktop app, so they ship as separate scripts.

### `remove-claude-imports.ps1` — undo the "external agent import"

The app has an `external-agent-import-sync` feature (it imports Claude Code sessions / config / skills into Codex). Accidentally enabling it brings over:

| Imported | Lands in |
|---|---|
| Conversations | `~/.codex/sessions/<date>/rollout-*.jsonl` |
| Config | the whole `env` block of `~/.claude/settings.json` written into `config.toml`'s `[shell_environment_policy.set]` (**including a token**) |
| MCP config | merged at runtime — the usual side effect is the `mcp_servers.github` error below |
| Skills | `~/.agents/skills/` |

Usage (**fully quit the app first, tray icon included**):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1 -DryRun   # preview
powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1
```

It flips the switch off, **deletes** the imported conversation files using the import ledger, and backs up `config.toml`. Details and the three gotchas are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### `fix-github-mcp.ps1` — fix `url is not supported for stdio in mcp_servers.github`

The same MCP server name `github` is defined by **several sources with different transports**, and the merge fails:

| Source | Transport |
|---|---|
| `~/.codex/config.toml` | **stdio** (`npx mcp-remote`) |
| `~/.mcp.json` | http (`url`) |
| Store plugin / plugin caches | http (`url`) |

Merged result = a stdio server carrying a `url` → validation fails → **config.toml fails to load entirely and the app is unusable**.

```powershell
# recommended: make config.toml http too, matching the other sources (works regardless of which source supplies the url)
... -File fix-github-mcp.ps1 -Mode Native -SetToken

# conservative: leave config.toml and secrets alone; just rename the key in ~/.mcp.json
... -File fix-github-mcp.ps1 -Mode RenameImport
```

`-SetToken` lifts the token out of `~/.codex/mcp-headers.txt` into user environment variables (**the token value is never printed**). If you already have a working `GITHUB_PAT` environment variable, pointing `bearer_token_env_var` at it is simpler still.

> Environment variables only reach **newly started** processes → fully quit and reopen the app afterwards.

---

## Verification status (stated honestly)

| Item | Status |
|---|---|
| Script syntax (Windows PowerShell 5.1 parser) | ✅ passes |
| `-DryRun` executed for real | ✅ all three scripts |
| Scheduled task, full chain | ✅ **measured with v2**: `schtasks -> wscript.exe -> powershell -> codex-guard.ps1` works, writing to `%TEMP%\codex-guard.log`: `17:04:03 ---- guard run (dryRun=False) ----` |
| Scheduled task creates no console flash | ✅ measured (carried over from v1, unchanged) |
| ① no false positives on healthy instances | ✅ by design; v2's whole-app condition is strictly more conservative |
| ① end-to-end reap | ✅ **measured**: v1 reaped **11 times** on the real machine between 15:58 and 16:15 (log: `STUCK pid=… age=…s no windows -> cleaning up` + `KILLED pid=…`), instance ages 184 s to 854 s; v2 keeps the same criterion as a whole-app condition |
| ③ hidden-window rescue | criteria ✅ **verified by running `-DryRun` on the live machine** (correctly distinguishes "the app has a usable window" from "the user can see nothing", and caught one false positive); whether `ShowWindow` actually takes effect ⚠️ still not verified end to end (no effect on another process from inside a restricted sandbox) |
| ④ taking over the slow staging | ⚠️ **inferred**. The copied output's `manifest.json` SHA256 matches the official one exactly, but "the app accepts a hand-placed directory" can only be verified on the next app update |
| ② wedged AppX container | Only "a reboot clears it" is measured; the script deliberately does nothing here |
| Never touches your data | ✅ by design (no app chat / account paths appear in the scripts) |

Every threshold is adjustable at the top of `codex-guard.ps1` or via command-line parameters.

**Recommended first run**: execute `fix-codex.ps1` by hand (not the scheduled task), confirm its decisions in `%TEMP%\codex-guard.log`, and only then let the scheduled task take over.

## Uninstall

```powershell
# remove the scheduled task only
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

# also delete the installed script files
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
```

The app itself and your data were never touched.

## Investigation notes

The full investigation, the raw log evidence, and the measured data behind `-21333`, the WMI blind spot, and the EFS attribute issue are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md) (Chinese).

## Feedback and contributions

- Open an [Issue](https://github.com/Muanyan-mjq/codex-desktop-fixer/issues) (attach `%TEMP%\codex-guard.log` and describe the symptom)
- Improvements: send a Pull Request

## License

[MIT](LICENSE)
