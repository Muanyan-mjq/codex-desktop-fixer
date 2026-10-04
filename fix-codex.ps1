# fix-codex.ps1  (v2)
# ---------------------------------------------------------------------------
# One-shot manual fix: run the guard's three jobs right now, one pass.
#
# The logic lives in codex-guard.ps1 so the scheduled watchdog and this manual
# script can never drift apart. This file is only a thin wrapper.
#
# Use it when the app "will not open" and you do not want to wait for the next
# scheduled guard run (the task fires once a minute).
#
# What it can fix:
#   * a slow runtime staging  -> copied properly in ~10 s instead of ~6 min
#   * a stuck instance        -> killed, so the next launch is a clean one
#   * a hidden window         -> shown again (hidden windows have no taskbar
#                                entry, so there is no other way back)
#
# What it cannot fix:
#   * a wedged AppX container ("the package is in use", repair fails with
#     0x80073D02). Only a reboot / sign-out clears that.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-codex.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-codex.ps1 -DryRun
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-codex.ps1 -RescueMinimized
#
# ASCII-only on purpose (Windows PowerShell 5.1 mis-decodes BOM-less UTF-8).
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    # Also restore windows you minimized on purpose. Off by default: a
    # minimized window is reachable from the taskbar, so the guard leaves it be.
    [switch]$RescueMinimized,

    # Report what would happen and change nothing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$guard = Join-Path $PSScriptRoot 'codex-guard.ps1'
if (-not (Test-Path -LiteralPath $guard)) {
    throw "codex-guard.ps1 was not found next to this script ($PSScriptRoot)."
}

& $guard -RescueMinimized:$RescueMinimized -DryRun:$DryRun
