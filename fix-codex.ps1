# fix-codex.ps1 - Manual one-shot fix: restore an invisible Codex/ChatGPT desktop window
# Run this when the app seems "not to open" although a ChatGPT.exe process is running.
# It restores visible main windows that are minimized off-screen and moves them back
# to the primary monitor. Healthy windows are never touched.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File fix-codex.ps1 [-ProcessName ChatGPT.exe]

param(
    [string]$ProcessName = 'ChatGPT.exe'
)

$ErrorActionPreference = 'SilentlyContinue'

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class CodexFixWin {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern int  GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static List<IntPtr> All = new List<IntPtr>();
    public static bool Collect(IntPtr h, IntPtr lp) { All.Add(h); return true; }
}
"@

Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

$baseName = $ProcessName -replace '\.exe$', ''
$procs = @(Get-Process -Name $baseName -ErrorAction SilentlyContinue)

if ($procs.Count -eq 0) {
    Write-Host "[$ProcessName is not running]" -ForegroundColor Yellow
    Write-Host "If double-clicking the icon does nothing, the app itself may have failed to start -"
    Write-Host "try again after 10s, or restart Windows. This script only helps when the process"
    Write-Host "is alive but its window is invisible."
    exit 0
}

Write-Host ("[{0} process(es) found, scanning windows...]" -f $procs.Count) -ForegroundColor Cyan
$fixed = 0

foreach ($p in $procs) {
    [CodexFixWin]::All.Clear()
    [CodexFixWin]::EnumWindows([CodexFixWin+EnumProc]{ param($h,$l) [CodexFixWin]::Collect($h,$l) }, [IntPtr]::Zero) | Out-Null

    foreach ($hwnd in @([CodexFixWin]::All)) {
        $wpid = 0
        [CodexFixWin]::GetWindowThreadProcessId($hwnd, [ref]$wpid) | Out-Null
        if ($wpid -ne $p.Id) { continue }
        if (-not [CodexFixWin]::IsWindowVisible($hwnd)) { continue }

        $sb = New-Object System.Text.StringBuilder 256
        [CodexFixWin]::GetWindowText($hwnd, $sb, 256) | Out-Null
        $r = New-Object CodexFixWin+RECT
        [CodexFixWin]::GetWindowRect($hwnd, [ref]$r) | Out-Null
        $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
        if ($w -lt 100 -or $h -lt 100) { continue }   # auxiliary windows

        $ovX = [Math]::Max(0, [Math]::Min($r.Right, $screen.Right) - [Math]::Max($r.Left, $screen.Left))
        $ovY = [Math]::Max(0, [Math]::Min($r.Bottom, $screen.Bottom) - [Math]::Max($r.Top, $screen.Top))

        if ($ovX -lt 50 -or $ovY -lt 50) {   # off-screen or effectively invisible
            Write-Host ("  fixing window pid={0} title='{1}' rect=({2},{3},{4},{5})" -f $p.Id, $sb.ToString(), $r.Left, $r.Top, $r.Right, $r.Bottom) -ForegroundColor Green
            [CodexFixWin]::ShowWindowAsync($hwnd, 9) | Out-Null   # SW_RESTORE
            Start-Sleep -Milliseconds 500
            if ($w -lt 100 -or $h -lt 100) { $w = 1200; $h = 800 }
            $x = [Math]::Max(0, [int](($screen.Width  - $w) / 2))
            $y = [Math]::Max(0, [int](($screen.Height - $h) / 2))
            [CodexFixWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, 0x0040) | Out-Null
            Write-Host ("  moved to screen center ({0},{1})" -f $x, $y) -ForegroundColor Green
            $fixed++
        }
    }
}

if ($fixed -eq 0) {
    Write-Host "[No invisible window found]" -ForegroundColor Yellow
    Write-Host "If the app looks closed but its process is running, check the taskbar / tray first."
    Write-Host "Still stuck? End all $ProcessName processes (task manager) and start the app again."
} else {
    Write-Host "[Done] Restored $fixed window(s). It should be visible on screen now." -ForegroundColor Cyan
}
