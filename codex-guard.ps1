# codex-guard.ps1  (v2.1)
# ---------------------------------------------------------------------------
# Watchdog for the OpenAI Codex / ChatGPT Windows desktop app.
# Runs once a minute from a scheduled task (see install.ps1).
#
# THREE JOBS, executed in this order, then it exits:
#
#   JOB 1  TAKE OVER a slow runtime staging.
#          On this machine every file inside the app package carries the EFS
#          "Encrypted" attribute, while the OS edition has no EFS. A plain
#          copy therefore fails once per file (~0.14 s each) before falling
#          back, turning a 10-second copy into ~6 minutes with NO window on
#          screen. We detect that state, copy the runtime ourselves using a
#          streaming read/write copy (which drops the attribute), and restart
#          the app: ~10 s instead of ~6 min.
#
#   JOB 2  REAP a stuck app: processes alive longer than $StuckAgeSeconds while
#          the app owns ZERO top-level windows. Such instances hold the
#          single-instance lock, so every later click spawns a process that
#          silently exits. Killing them makes the next click a clean start.
#
#   JOB 3  RESCUE unreachable windows (WS_VISIBLE = false).
#          The window can sit at a perfectly normal position yet be hidden -
#          and a hidden window has NO taskbar entry, so the user has no normal
#          way to bring it back. We show it again.
#
# IMPORTANT - process discovery uses Get-Process, NOT WMI.
#   On the machine this was written for, Win32_Process (Get-CimInstance) does
#   not list these processes at all: the filter returns 0 rows while
#   Get-Process sees 6-10. Any WMI-based lookup silently does nothing there.
#
# DELIBERATELY NOT DONE
#   * Minimized windows are left alone by default: they are reachable from the
#     taskbar, so restoring them would fight the user. Use -RescueMinimized to
#     opt in. (Note: a minimized window reports rect (-21333,-21333) 158x26 on
#     this machine. That is the Windows minimization parking spot, NOT an
#     off-screen window.)
#   * The computer-use overlay ("ChatGPT is using your computer...") is never
#     shown: it is a full-screen overlay and would cover the whole desktop.
#   * No reboot, no AppX repair (0x80073D02 cannot be fixed by a script), and
#     no reading or writing of the app's chat / config / account data.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-guard.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex-guard.ps1 -DryRun
#
# NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 decodes
#       BOM-less UTF-8 as ANSI, which turns non-ASCII comments into mojibake
#       and can break parsing. Keep it ASCII, or save it as UTF-8 *with* BOM.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$ProcessName = 'ChatGPT.exe',
    [string]$PackageName = 'OpenAI.Codex',

    # JOB 2 threshold. Safe at 300 s because JOB 1 removes the one legitimate
    # reason for a long window-less startup (the slow runtime staging).
    # A healthy start shows a window within ~5-10 s.
    [int]$StuckAgeSeconds = 300,

    # JOB 1: a .staging-* directory that is still present this many seconds
    # after the app started means it took the slow path.
    [int]$StagingGraceSeconds = 60,

    # JOB 3 safety rails.
    [int]$MainWinMinSize = 400,      # hidden windows smaller than this are helpers
    [switch]$RescueMinimized,        # off by default: minimized = user-reachable
    [switch]$NoRelaunch,             # JOB 1: do not start the app again afterwards

    [switch]$DryRun                  # report only, change nothing
)

$ErrorActionPreference = 'SilentlyContinue'

# ------------------------------- config ------------------------------------
$OffScreenPx   = 50        # overlap below this with the primary screen => off-screen
$MinWinSize    = 100       # windows smaller than this (px) are auxiliary, never touched
$RestoreSizeW  = 1200      # fallback size when a window reports a broken rect
$RestoreSizeH  = 800
$MaxLogBytes   = 1048576   # rotate the log at 1 MB
$LogFile       = Join-Path $env:TEMP 'codex-guard.log'

# The computer-use overlay is full-screen; showing it would cover the desktop.
$NeverShowTitleRegex = 'is using your computer'

# Where the app copies its bundled Node runtime to.
$RuntimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
# ---------------------------------------------------------------------------

function Write-Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    if ($DryRun) { $line = '{0} [DRYRUN] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg }
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogBytes)) {
        Move-Item $LogFile "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ------------------------------- win32 -------------------------------------
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class GuardWin {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern int  GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static List<IntPtr> WinList = new List<IntPtr>();
    public static bool Collect(IntPtr h, IntPtr lp) { WinList.Add(h); return true; }
    public static void Refresh() { WinList.Clear(); EnumWindows(Collect, IntPtr.Zero); }

    // Every top-level window (visible or not, any virtual desktop) owned by any
    // of the given pids.
    public static List<IntPtr> WindowsOf(uint[] pids) {
        Refresh();
        List<IntPtr> res = new List<IntPtr>();
        foreach (IntPtr h in WinList) {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            foreach (uint p in pids) if (p == wpid) { res.Add(h); break; }
        }
        return res;
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

$baseName = $ProcessName -replace '\.exe$', ''

# --- process discovery -----------------------------------------------------
# Get-Process only. WMI (Win32_Process) cannot see these processes here.
function Get-AppProcesses {
    return @(Get-Process -Name $baseName -ErrorAction SilentlyContinue)
}

function Get-AppPids {
    param($Procs)
    return @($Procs | ForEach-Object { [uint32]$_.Id })
}

function Get-OldestProcess {
    param($Procs)
    return ($Procs | Sort-Object StartTime | Select-Object -First 1)
}

function Get-PackageRoot {
    try {
        $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue |
               Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) { return $pkg.InstallLocation }
    } catch { }

    foreach ($proc in (Get-AppProcesses)) {
        try {
            if (-not $proc.Path) { continue }
            $d = Split-Path $proc.Path -Parent
            while ($d -and (Split-Path $d -Leaf) -notlike "$PackageName`_*") {
                $up = Split-Path $d -Parent
                if (-not $up -or $up -eq $d) { $d = $null; break }
                $d = $up
            }
            if ($d) { return $d }
        } catch { }
    }

    try {
        $d = Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "$PackageName`_*" } | Sort-Object Name -Descending | Select-Object -First 1
        if ($d) { return $d.FullName }
    } catch { }
    return $null
}

function Copy-TreeStreaming {
    # Streaming read/write copy. Unlike CopyFileW this does NOT try to preserve
    # the EFS "Encrypted" attribute, which is what makes it succeed here.
    param([string]$Source, [string]$Destination)
    $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)
    foreach ($f in $files) {
        $rel    = $f.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $rel
        $dir    = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $in = [System.IO.File]::OpenRead($f.FullName)
        try {
            $out = [System.IO.File]::Create($target)
            try { $in.CopyTo($out, 1MB) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
    }
    return $files.Count
}

function Get-ManifestHash([string]$dir) {
    $m = Join-Path $dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $m)) { return $null }
    return (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash
}

function Stop-App {
    param([string]$Reason)
    $procs = Get-AppProcesses
    if ($procs.Count -eq 0) { return 0 }
    Write-Log ("KILL   {0} process(es): {1}" -f $procs.Count, $Reason)
    $procs | Stop-Process -Force
    Start-Sleep -Milliseconds 900
    return $procs.Count
}

Write-Log "---- guard run (dryRun=$([bool]$DryRun)) ----"

$procs = Get-AppProcesses

# ===========================================================================
# JOB 1 - take over a slow runtime staging
# ===========================================================================
$staging = @()
if (Test-Path -LiteralPath $RuntimeRoot) {
    $staging = @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like '.staging-*' })
}

if ($staging.Count -gt 0) {
    $oldest = Get-OldestProcess $procs
    $ageSec = if ($oldest) { ((Get-Date) - $oldest.StartTime).TotalSeconds } else { 0 }
    $name   = $staging[0].Name

    if ($ageSec -ge $StagingGraceSeconds -and $name -match '^\.staging-([0-9a-f]+)-') {
        $hash = $Matches[1]
        Write-Log ("STAGING target={0} appAge={1:N0}s -> slow EFS copy detected, taking over" -f $hash, $ageSec)

        $pkgRoot = Get-PackageRoot
        $src = if ($pkgRoot) { Join-Path $pkgRoot 'app\resources\cua_node' } else { $null }

        if (-not $src -or -not (Test-Path -LiteralPath $src)) {
            Write-Log "STAGING cannot locate a runtime source in the package - giving up this round"
        }
        else {
            $srcHash = Get-ManifestHash $src
            $tmp     = Join-Path $RuntimeRoot "$hash.takeover-tmp"
            $final   = Join-Path $RuntimeRoot $hash

            if ($DryRun) {
                Write-Log ("DRYRUN would: kill the app, stream-copy {0} -> {1}, clean {2} .staging dir(s), relaunch" -f $src, $final, $staging.Count)
            }
            else {
                [void](Stop-App "replacing a slow runtime staging")
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }

                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $copied = Copy-TreeStreaming -Source $src -Destination $tmp
                $sw.Stop()

                $okCount = @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Force).Count
                $okHash  = (Get-ManifestHash $tmp)

                if ($copied -eq $okCount -and $okHash -eq $srcHash -and $srcHash) {
                    Write-Log ("STAGING copied {0} files in {1:N1}s - verified" -f $copied, $sw.Elapsed.TotalSeconds)
                    if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
                    Move-Item -LiteralPath $tmp -Destination $final
                    foreach ($s in $staging) { Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                    Write-Log ("STAGING ready: {0}" -f $final)

                    if (-not $NoRelaunch -and $pkgRoot) {
                        Write-Log "START   relaunching the app on the fast path"
                        Start-Process (Join-Path $pkgRoot 'app\ChatGPT.exe')
                    }
                }
                else {
                    Write-Log ("STAGING verification failed (copied={0} onDisk={1} hashOk={2}) - temp dir left at {3}" -f $copied, $okCount, ($okHash -eq $srcHash), $tmp)
                }
            }
        }
        Write-Log "---- guard end ----"
        exit 0
    }
}

# ===========================================================================
# JOB 2 - reap a stuck app (processes alive, but ZERO top-level windows)
#
# This is a whole-app condition, not a per-process one: Electron's helper
# processes never own a window, so "this pid has no window" is true for every
# healthy child. The reliable signal is "the app has processes but the app owns
# no window at all, and it has been that way longer than the threshold".
# ===========================================================================
if ($procs.Count -gt 0) {
    $pids = Get-AppPids $procs
    $winCount = ([GuardWin]::WindowsOf($pids)).Count

    if ($winCount -eq 0) {
        $oldest = Get-OldestProcess $procs
        $ageSec = if ($oldest) { ((Get-Date) - $oldest.StartTime).TotalSeconds } else { 0 }
        if ($ageSec -gt $StuckAgeSeconds) {
            Write-Log ("STUCK  {0} process(es), oldest {1:N0}s, ZERO top-level windows -> cleaning up" -f $procs.Count, $ageSec)
            if (-not $DryRun) {
                [void](Stop-App "stuck app holding the single-instance lock")
                Write-Log "STUCK  done - the next launch will be a clean one"
            }
            Write-Log "---- guard end ----"
            exit 0
        }
    }
}

# ===========================================================================
# JOB 3 - rescue unreachable windows
# ===========================================================================
if ($procs.Count -eq 0) {
    Write-Log "idle   app is not running - nothing to do"
    Write-Log "---- guard end ----"
    exit 0
}

$pids = Get-AppPids $procs

# --- pass 1: describe every top-level window the app owns ------------------
$wins = @()
foreach ($hwnd in [GuardWin]::WindowsOf($pids)) {
    $r = New-Object GuardWin+RECT
    [GuardWin]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $tsb = New-Object System.Text.StringBuilder 256
    [GuardWin]::GetWindowText($hwnd, $tsb, 256) | Out-Null
    $wins += [pscustomobject]@{
        Hwnd    = $hwnd
        Title   = $tsb.ToString()
        Rect    = $r
        W       = $r.Right - $r.Left
        H       = $r.Bottom - $r.Top
        Visible = [GuardWin]::IsWindowVisible($hwnd)
        Minimiz = [GuardWin]::IsIconic($hwnd)
    }
}

# Can the user already see and use the app?
# Only when they CANNOT do we go looking for hidden windows. Otherwise a hidden
# sibling window (a helper surface, a leftover, a secondary window) is not a
# problem, and force-showing it would surprise the user with an extra window --
# measured on a live machine, a healthy running app owned one visible main
# window plus one hidden same-sized sibling, which the earlier rule would have
# popped on screen.
$hasUsableWindow = $false
foreach ($x in $wins) {
    if (-not $x.Visible -or $x.Minimiz) { continue }
    if ($x.W -lt $MainWinMinSize -or $x.H -lt $MainWinMinSize) { continue }
    if ($x.Title -match $NeverShowTitleRegex) { continue }
    $ovX = [Math]::Max(0, [Math]::Min($x.Rect.Right,  $screen.Right) - [Math]::Max($x.Rect.Left, $screen.Left))
    $ovY = [Math]::Max(0, [Math]::Min($x.Rect.Bottom, $screen.Bottom) - [Math]::Max($x.Rect.Top,  $screen.Top))
    if ($ovX -ge $OffScreenPx -and $ovY -ge $OffScreenPx) { $hasUsableWindow = $true; break }
}
$hiddenSkipped = 0

foreach ($x in $wins) {
    $hwnd      = $x.Hwnd
    $r         = $x.Rect
    $w         = $x.W
    $h         = $x.H
    $title     = $x.Title
    $minimized = $x.Minimiz
    $visible   = $x.Visible

    # --- never touch small helper windows -------------------------------
    if (-not $minimized -and $visible -and ($w -lt $MinWinSize -or $h -lt $MinWinSize)) { continue }

    # --- never show the full-screen computer-use overlay -----------------
    if ($title -match $NeverShowTitleRegex) { continue }

    # --- minimized: reachable from the taskbar -> leave alone ------------
    if ($minimized) {
        if (-not $RescueMinimized) { continue }
        Write-Log ("MINIMIZED title='{0}' rect=({1},{2},{3},{4}) -> restoring (-RescueMinimized)" -f $title, $r.Left, $r.Top, $r.Right, $r.Bottom)
        if (-not $DryRun) {
            [GuardWin]::ShowWindowAsync($hwnd, 9) | Out-Null          # SW_RESTORE
            Start-Sleep -Milliseconds 400
            $w2 = if ($w -ge $MinWinSize) { $w } else { $RestoreSizeW }
            $h2 = if ($h -ge $MinWinSize) { $h } else { $RestoreSizeH }
            $x2 = [Math]::Max(0, [int](($screen.Width  - $w2) / 2))
            $y2 = [Math]::Max(0, [int](($screen.Height - $h2) / 2))
            [GuardWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $x2, $y2, $w2, $h2, 0x0040) | Out-Null
            [GuardWin]::SetForegroundWindow($hwnd) | Out-Null
        }
        continue
    }

    if ($visible) {
        # --- existing check: visible but parked off-screen ----------------
        $ovX = [Math]::Max(0, [Math]::Min($r.Right, $screen.Right) - [Math]::Max($r.Left, $screen.Left))
        $ovY = [Math]::Max(0, [Math]::Min($r.Bottom, $screen.Bottom) - [Math]::Max($r.Top, $screen.Top))
        if ($ovX -ge $OffScreenPx -and $ovY -ge $OffScreenPx) { continue }   # fine where it is

        Write-Log ("OFFSCREEN title='{0}' rect=({1},{2},{3},{4}) -> restoring" -f $title, $r.Left, $r.Top, $r.Right, $r.Bottom)
        if (-not $DryRun) {
            [GuardWin]::ShowWindowAsync($hwnd, 9) | Out-Null
            Start-Sleep -Milliseconds 400
            $w2 = if ($w -ge $MinWinSize) { $w } else { $RestoreSizeW }
            $h2 = if ($h -ge $MinWinSize) { $h } else { $RestoreSizeH }
            $x2 = [Math]::Max(0, [int](($screen.Width  - $w2) / 2))
            $y2 = [Math]::Max(0, [int](($screen.Height - $h2) / 2))
            [GuardWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $x2, $y2, $w2, $h2, 0x0040) | Out-Null
        }
        continue
    }

    # --- the real fix: WS_VISIBLE = false --------------------------------
    # No taskbar entry exists for a hidden window, so the user has no way to
    # bring it back. Only main-window-sized, titled windows are rescued, and
    # only when the app has no usable on-screen window at all.
    if ($w -lt $MainWinMinSize -or $h -lt $MainWinMinSize) { continue }
    if ([string]::IsNullOrWhiteSpace($title)) { continue }

    if ($hasUsableWindow) {
        $hiddenSkipped++
        continue
    }

    $onScreen = ($r.Left -ge 0 -and $r.Top -ge 0 -and $r.Right -le $screen.Right -and $r.Bottom -le $screen.Bottom)
    $tx = if ($onScreen) { $r.Left } else { [Math]::Max(0, [int](($screen.Width  - $w) / 2)) }
    $ty = if ($onScreen) { $r.Top  } else { [Math]::Max(0, [int](($screen.Height - $h) / 2)) }

    Write-Log ("HIDDEN title='{0}' rect=({1},{2},{3},{4}) -> showing at ({5},{6})" -f $title, $r.Left, $r.Top, $r.Right, $r.Bottom, $tx, $ty)
    if (-not $DryRun) {
        [GuardWin]::ShowWindowAsync($hwnd, 5) | Out-Null              # SW_SHOW
        Start-Sleep -Milliseconds 300
        [GuardWin]::ShowWindowAsync($hwnd, 9) | Out-Null              # SW_RESTORE
        Start-Sleep -Milliseconds 300
        [GuardWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $tx, $ty, $w, $h, 0x0040) | Out-Null
        [GuardWin]::SetForegroundWindow($hwnd) | Out-Null
    }
}

if ($hiddenSkipped -gt 0) {
    Write-Log ("HIDDEN {0} hidden window(s) left alone - the app already has a usable on-screen window" -f $hiddenSkipped)
}

Write-Log "---- guard end ----"
