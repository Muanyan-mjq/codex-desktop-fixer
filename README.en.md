# Codex Desktop Fixer

[中文](README.md) | English

**Stop the OpenAI Codex / ChatGPT desktop app from "not opening" — automatically.**

> The core component is a scheduled-task **guard** (`codex-guard.ps1`) that runs
> every minute and heals problems on its own; `fix-codex.ps1` is a manual
> one-shot variant for when you want to fix it right now.

A tiny scheduled-task guard for Windows that watches the Codex desktop app
(an MSIX/Electron app whose main process is currently named `ChatGPT.exe`)
and heals the two failure modes that make it look like it "won't open":

1. **Stuck instance on startup** — the app sometimes blocks very early in its
   startup sequence (we observed a `load shell env` step blocking for **526
   seconds**; the app's 5-second timeout never fired). The instance has **no
   window**, yet it holds the app's **single-instance lock** — so every further
   click spawns a process that instantly and silently exits. Result: the app
   "never opens" until the stuck instance dies (or you reboot).
2. **Window parked off-screen** — after a stuck instance finally recovers, its
   main window can be minimized to an absurd off-screen coordinate
   (e.g. `-21333,-21333`). The process is healthy, the window exists, but you
   can't see it — and single-instance forwarding keeps sending every new click
   to that invisible window.

The guard runs every minute (invisibly — no console window ever flashes) and:

- **kills** a main instance that has been alive > 3 minutes with **zero
  top-level windows** (frees the single-instance lock, so your next click is a
  clean launch);
- **restores** visible main windows that sit off-screen;
- **never touches** healthy instances — minimized, tray-hidden, or on another
  virtual desktop are all safe;
- **never reads or writes any app data** — your chat history, login state and
  configs are untouched. Every action is logged to `%TEMP%\codex-guard.log`.

> ⚠️ Third-party community tool, not affiliated with OpenAI. The stuck-startup
> behavior is a bug inside the app itself; this guard makes it self-healing,
> it cannot prevent the bug from firing.

---

## Symptoms this addresses

- The Codex / ChatGPT desktop app *sometimes* opens and *sometimes* doesn't.
- Clicking the icon repeatedly does nothing (each click is swallowed).
- A `ChatGPT.exe` process is running in Task Manager, but no window appears.
- It "magically works again" after a reboot or after killing processes.

## Install

```powershell
# from a PowerShell (no admin rights needed):
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

This copies the scripts to `%LOCALAPPDATA%\CodexGuard`, generates a hidden VBS
launcher, and registers scheduled task `CodexGuard` (every minute, interactive
session only).

### Options

```powershell
# target a differently-named main process:
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ProcessName codex.exe

# check every 2 minutes instead of 1:
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -IntervalMinutes 2

# custom install location:
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -InstallDir D:\tools\CodexGuard
```

## Manual one-shot fix

When the app seems stuck right now (no need to wait for the next guard tick):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexGuard\fix-codex.ps1"
```

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1        # remove task only
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge # also delete installed files
```

## How it works / safety rules

| Rule | Rationale |
|---|---|
| Only processes named `ChatGPT.exe` *without* `--type=` (i.e. main instances) are considered | child processes (GPU/renderer/utility) must never be killed independently |
| Kill only when the instance is **> 3 min old** AND has **zero top-level windows** | a normal launch shows its window within ~10 s; the 3-min age makes false kills impossible |
| A window being *present* (even hidden/minimized) always means "leave it alone" | user-minimized or tray-hidden sessions are intentional |
| Visible windows with normal on-screen rects are never touched | nothing to fix |
| No config/data file of the app is read or written | zero data risk |

## Why a VBS launcher (no console flash)?

`powershell -WindowStyle Hidden` is famously **ignored** when PowerShell is
started by Task Scheduler, which makes a black console flash every minute.
`wscript.exe` is a GUI-subsystem process — it can never create a console
window. The scheduled task therefore runs `wscript.exe <launcher.vbs>`, which
in turn runs the guard script hidden.

## Verification status (honest)

| Path | Status |
|---|---|
| Healthy instance left untouched (no false positive) | ✅ tested |
| Off-screen window pulled back (real `-21333` case) | ✅ tested twice in the field |
| Stuck instance (no window > 3 min) auto-killed | ⚠️ logic built from a real 526 s stuck trace; end-to-end kill still awaits a real occurrence |
| No console window flashes from the scheduled task | ✅ tested |
| Data untouched | ✅ by design (scripts contain no app-data paths) |

The stuck-detection parameters (`180 s`, off-screen overlap `50 px`) are
tunable at the top of `codex-guard.ps1`.

## Background evidence

Diagnosed 2026-09 on a real machine that "sometimes opened, sometimes didn't":

- Every click *did* start a process (AppModel-Runtime event 201), yet app logs
  showed sessions ending after 3 lines — classic **single-instance hand-off**,
  not crashes (no Windows Error Reporting entries at all).
- The one instance that *did* survive startup had a main window at
  `(-21333, -21333)`, minimized, size 158×26 — the window existed and was
  "visible", just parked off-screen.
- Its buffered full-session log (flushed on exit) showed the root blocker:
  `Failed to load shell env ... durationMs=526778` — the startup path blocked
  for ~9 minutes while a 5-second timeout silently failed to fire. The window
  then appeared 2.5 s after the block cleared.
- Conclusion: **launch didn't fail, it froze — and the frozen instance
  locked out every subsequent launch.** That asymmetry is exactly the
  "sometimes it opens, sometimes it doesn't" behavior.

## License

MIT License — see [LICENSE](LICENSE). Community project, not affiliated with OpenAI.
