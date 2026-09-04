# codex-guard.ps1 - Auto-guard for the OpenAI Codex / ChatGPT desktop app
# Scheduled to run every minute (see install.ps1). It:
#   1. Detects "stuck" main instances: process alive > $StuckAgeSeconds with ZERO top-level windows
#      -> kills the process tree (releases the app's single-instance lock)
#   2. Detects main windows parked off-screen (e.g. at -21333,-21333) and moves them back
#   3. NEVER touches healthy instances: minimized, tray-hidden or on other virtual desktops are safe
# It reads/writes no app data. Actions are logged to $env:TEMP\codex-guard.log
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File codex-guard.ps1 [-ProcessName ChatGPT.exe]

param(
    [string]$ProcessName = 'ChatGPT.exe'   # exe name of the app. Codex desktop currently ships as ChatGPT.exe
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------------- config ----------------
$StuckAgeSeconds  = 180     # a main instance older than this with no window at all is considered stuck
$OffScreenPx      = 50      # overlap below this with the primary screen => treat as off-screen
$MinWinSize       = 100     # windows smaller than this (px) are auxiliary, never touched
$RestoreSizeW     = 1200    # fallback size when an off-screen window reports a broken rect
$RestoreSizeH     = 800
$LogFile          = Join-Path $env:TEMP 'codex-guard.log'
# ----------------------------------------

function Write-Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# win32 helpers
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
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static List<IntPtr> WinList = new List<IntPtr>();
    public static bool Collect(IntPtr h, IntPtr lp) { WinList.Add(h); return true; }
    // Does this pid own ANY top-level window (visible or not, any virtual desktop)?
    public static bool HasAnyWindow(uint pid) {
        WinList.Clear();
        EnumWindows(Collect, IntPtr.Zero);
        foreach (IntPtr h in WinList) {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (wpid == pid) return true;
        }
        return false;
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

$baseName = $ProcessName -replace '\.exe$', ''

# ---- 1. find main instances (processes whose command line has no --type= child marker) ----
$filter = "Name='$($ProcessName.Replace("'","''"))'"
$mains = @()
foreach ($p in Get-CimInstance Win32_Process -Filter $filter) {
    if ($p.CommandLine -notmatch '--type=') { $mains += $p }
}
if ($mains.Count -eq 0) { exit 0 }   # app not running - nothing to do

# ---- 2. kill stuck instances (no windows at all for longer than StuckAgeSeconds) ----
foreach ($m in $mains) {
    $ageSec = ((Get-Date) - $m.CreationDate).TotalSeconds
    if ($ageSec -gt $StuckAgeSeconds -and -not [GuardWin]::HasAnyWindow([uint32]$m.ProcessId)) {
        Write-Log ("STUCK pid={0} age={1:N0}s no windows -> cleaning up" -f $m.ProcessId, $ageSec)
        # collect descendants, kill children first then the root
        $queue = New-Object System.Collections.Queue
        foreach ($c in (Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $m.ProcessId })) { $queue.Enqueue($c) }
        $toKill = New-Object System.Collections.Generic.List[int]
        while ($queue.Count -gt 0) {
            $c = $queue.Dequeue()
            $toKill.Add([int]$c.ProcessId)
            foreach ($g in (Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $c.ProcessId })) { $queue.Enqueue($g) }
        }
        foreach ($id in $toKill) { Stop-Process -Id $id -Force }
        Stop-Process -Id $m.ProcessId -Force
        Write-Log ("KILLED pid={0} plus {1} child processes. Next launch will be a clean one." -f $m.ProcessId, $toKill.Count)
    }
}

# ---- 3. pull visible main windows back from off-screen ----
$esb = New-Object System.Text.StringBuilder 256
foreach ($m in $mains) {
    if (-not (Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue)) { continue }  # already killed
    [GuardWin]::WinList.Clear()
    [GuardWin]::EnumWindows([GuardWin+EnumProc]{ param($h,$l) [GuardWin]::Collect($h,$l) }, [IntPtr]::Zero) | Out-Null
    foreach ($hwnd in @([GuardWin]::WinList)) {
        $wpid = 0
        [GuardWin]::GetWindowThreadProcessId($hwnd, [ref]$wpid) | Out-Null
        if ($wpid -ne $m.ProcessId) { continue }
        if (-not [GuardWin]::IsWindowVisible($hwnd)) { continue }   # tray-hidden windows are intentional

        $r = New-Object GuardWin+RECT
        [GuardWin]::GetWindowRect($hwnd, [ref]$r) | Out-Null
        $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
        if ($w -lt $MinWinSize -or $h -lt $MinWinSize) { continue }  # auxiliary/splash windows

        $ovX = [Math]::Max(0, [Math]::Min($r.Right, $screen.Right) - [Math]::Max($r.Left, $screen.Left))
        $ovY = [Math]::Max(0, [Math]::Min($r.Bottom, $screen.Bottom) - [Math]::Max($r.Top, $screen.Top))
        if ($ovX -ge $OffScreenPx -and $ovY -ge $OffScreenPx) { continue }  # window is fine on screen

        [GuardWin]::GetWindowText($hwnd, $esb, 256) | Out-Null
        Write-Log ("OFFSCREEN pid={0} title='{1}' rect=({2},{3},{4},{5}) -> restoring" -f $m.ProcessId, $esb.ToString(), $r.Left, $r.Top, $r.Right, $r.Bottom)
        [GuardWin]::ShowWindowAsync($hwnd, 9) | Out-Null   # SW_RESTORE
        Start-Sleep -Milliseconds 400
        $w = if ($w -ge $MinWinSize) { $w } else { $RestoreSizeW }
        $h = if ($h -ge $MinWinSize) { $h } else { $RestoreSizeH }
        $x = [Math]::Max(0, [int](($screen.Width  - $w) / 2))
        $y = [Math]::Max(0, [int](($screen.Height - $h) / 2))
        [GuardWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, 0x0040) | Out-Null  # SWP_NOZORDER
    }
}
