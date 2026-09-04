# install.ps1 - Install the Codex desktop guard as a scheduled task
#
# What it does:
#   1. Copies codex-guard.ps1 / fix-codex.ps1 to the install directory (default %LOCALAPPDATA%\CodexGuard)
#   2. Generates a VBS launcher - the scheduled task runs wscript.exe (GUI subsystem),
#      so NO console window ever flashes
#   3. Registers scheduled task "CodexGuard" to run every minute while you are logged on
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ProcessName codex.exe   # other app
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -IntervalMinutes 2       # less frequent
#
# Uninstall:  powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

param(
    [string]$ProcessName     = 'ChatGPT.exe',
    [int]   $IntervalMinutes = 1,
    [string]$InstallDir      = (Join-Path $env:LOCALAPPDATA 'CodexGuard')
)

$ErrorActionPreference = 'Stop'
$TaskName = 'CodexGuard'

# ---- 1. copy scripts ----
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$src = $PSScriptRoot
if (-not $src) { $src = Split-Path -Parent $MyInvocation.MyCommand.Path }
Copy-Item (Join-Path $src 'codex-guard.ps1')   (Join-Path $InstallDir 'codex-guard.ps1')   -Force
Copy-Item (Join-Path $src 'fix-codex.ps1')     (Join-Path $InstallDir 'fix-codex.ps1')     -Force
Copy-Item (Join-Path $src 'uninstall.ps1')     (Join-Path $InstallDir 'uninstall.ps1')     -Force

# ---- 2. generate VBS launcher (hidden, no console window) ----
$guardPath = Join-Path $InstallDir 'codex-guard.ps1'
$vbsPath   = Join-Path $InstallDir 'codex-guard-launcher.vbs'
$psCmd     = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -ProcessName "{1}"' -f $guardPath, $ProcessName
$vbs       = 'CreateObject("WScript.Shell").Run "{0}", 0, False' -f ($psCmd -replace '"', '""')
[System.IO.File]::WriteAllText($vbsPath, $vbs, (New-Object System.Text.ASCIIEncoding))

# ---- 3. register / refresh scheduled task ----
$taskCmd = 'wscript.exe "{0}"' -f $vbsPath
& schtasks.exe /Create /TN $TaskName /TR $taskCmd /SC MINUTE /MO $IntervalMinutes /F
if ($LASTEXITCODE -ne 0) { throw "Failed to register scheduled task '$TaskName'" }

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " CodexGuard installed" -ForegroundColor Cyan
Write-Host "   app process : $ProcessName"
Write-Host "   check every : $IntervalMinutes min"
Write-Host "   scripts     : $InstallDir"
Write-Host "   task        : $TaskName (runs via wscript, no console flash)"
Write-Host "   log         : %TEMP%\codex-guard.log"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Manual one-shot fix (run any time):"
Write-Host "   powershell -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\fix-codex.ps1`""
Write-Host ""
Write-Host "To uninstall later (either location works):"
Write-Host "   powershell -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
