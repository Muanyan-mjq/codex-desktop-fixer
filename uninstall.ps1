# uninstall.ps1 - Remove the CodexGuard scheduled task and its files
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge   # also delete installed scripts

param(
    [switch]$Purge,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'CodexGuard')
)

$ErrorActionPreference = 'Continue'
$TaskName = 'CodexGuard'

# ---- 1. delete scheduled task ----
& schtasks.exe /Delete /TN $TaskName /F | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Scheduled task '$TaskName' removed."
} else {
    Write-Host "Scheduled task '$TaskName' not found or already removed."
}

# ---- 2. optionally delete installed scripts ----
if ($Purge -and (Test-Path $InstallDir)) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir"
}

Write-Host "Done. The app itself was never touched - all your Codex/ChatGPT data is intact."
