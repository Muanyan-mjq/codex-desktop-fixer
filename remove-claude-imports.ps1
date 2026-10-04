# remove-claude-imports.ps1
# ---------------------------------------------------------------------------
# Undo the Codex desktop app's "external agent import" (Claude Code -> Codex).
#
# What the feature did on this machine:
#   1. copied 3 Claude Code conversations into ~/.codex/sessions/2026/10/04/
#      (tracked in ~/.codex/external_agent_session_imports.json)
#   2. merged MCP server definitions from ~/.mcp.json at runtime, which is what
#      produced:  "url is not supported for stdio in `mcp_servers.github`"
#
# What this script does:
#   * sets  [desktop] external-agent-import-sync-enabled = false  in config.toml
#   * DELETES the imported session files outright (no quarantine copy kept)
#   * optionally resets the import ledger with -ResetLedger
#   * backs up config.toml before touching it
#
# IMPORTANT: close the app first (including the tray icon). The app rewrites
# config.toml while running and holds the session files open, so a run against
# a live app will partly fail and the change to config.toml may be overwritten.
# The script refuses to run while the app is up unless you pass -Force.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1 -DryRun
#   powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File remove-claude-imports.ps1 -ResetLedger
#
# ASCII-only on purpose (Windows PowerShell 5.1 mis-decodes BOM-less UTF-8).
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,           # run even if the app is still open
    [switch]$ResetLedger,     # also clear the import ledger
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ProcessName = 'ChatGPT'
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say($m)  { Write-Host "[unimport] $m" }
function Warn($m) { Write-Host "[unimport] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[unimport] $m" -ForegroundColor Red; exit 1 }

function Read-Text([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-TextNoBom([string]$p, [string]$t) {
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}
function Backup-File([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    $bak = "$p.bak-unimport-$stamp"
    if ($DryRun) { Say "DRYRUN would back up: $p -> $bak"; return }
    Copy-Item -LiteralPath $p -Destination $bak -Force
    Say "backed up: $bak"
}

# --- preflight --------------------------------------------------------------
if (-not (Test-Path -LiteralPath $CodexHome)) { Fail "Codex home not found: $CodexHome" }

$running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if (-not $Force) {
        Warn "the app is still running ($($running.Count) process(es)):"
        $running | ForEach-Object { Warn ("    pid {0}  started {1}" -f $_.Id, $_.StartTime) }
        Warn "fully quit it first - including the tray icon - then run this script again."
        Warn "(pass -Force only if you know the app is not writing anything.)"
        exit 1
    }
    Warn "app is running but -Force was given - continuing anyway"
}

$configPath = Join-Path $CodexHome 'config.toml'
$ledgerPath = Join-Path $CodexHome 'external_agent_session_imports.json'

# --- 1. switch the feature off ---------------------------------------------
if (Test-Path -LiteralPath $configPath) {
    $cfg = Read-Text $configPath
    $pattern = '(?m)^([ \t]*)external-agent-import-sync-enabled[ \t]*=[ \t]*true[ \t]*$'
    $m = [regex]::Matches($cfg, $pattern)
    if ($m.Count -eq 0) {
        if ($cfg -match 'external-agent-import-sync-enabled') { Say "external-agent-import-sync-enabled is already false - nothing to change" }
        else { Warn "no 'external-agent-import-sync-enabled' key found in config.toml - skipping" }
    }
    else {
        Say "setting external-agent-import-sync-enabled = false ($($m.Count) occurrence(s))"
        $new = [regex]::Replace($cfg, $pattern, '$1external-agent-import-sync-enabled = false')
        Backup-File $configPath
        if ($DryRun) { Say "DRYRUN would write $configPath" }
        else { Write-TextNoBom $configPath $new; Say "written: $configPath" }
    }
}
else { Warn "no config.toml at $configPath" }

# --- 2. delete the imported session files -----------------------------------
$importedIds = @()
if (Test-Path -LiteralPath $ledgerPath) {
    try {
        $ledger = (Read-Text $ledgerPath) | ConvertFrom-Json
        $importedIds = @($ledger.records | Where-Object { $_.imported_thread_id } | ForEach-Object { $_.imported_thread_id })
    } catch { Fail "cannot parse $ledgerPath : $($_.Exception.Message)" }
    Say "ledger lists $($importedIds.Count) imported conversation(s)"
}
else { Warn "no import ledger at $ledgerPath - nothing to look up by id" }

$sessionsRoot = Join-Path $CodexHome 'sessions'
$toDelete = @()
if (Test-Path -LiteralPath $sessionsRoot) {
    foreach ($id in $importedIds) {
        $hits = @(Get-ChildItem $sessionsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*$id*.jsonl" })
        if ($hits.Count -eq 0) { Warn "no session file found for thread $id" }
        $toDelete += $hits
    }
}

$toDelete = @($toDelete | Sort-Object FullName -Unique)
if ($toDelete.Count -eq 0) { Say "nothing to delete" }
else {
    Say "imported conversation files to delete: $($toDelete.Count)"
    $toDelete | ForEach-Object { Say ("    {0}  ({1} bytes)" -f $_.FullName, $_.Length) }
    if ($DryRun) { Say "DRYRUN would DELETE the files listed above" }
    else {
        $failed = 0
        foreach ($f in $toDelete) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            catch { $failed++; Warn ("could not delete {0} : {1}" -f $f.FullName, $_.Exception.Message) }
        }
        $done = $toDelete.Count - $failed
        Say "deleted $done of $($toDelete.Count) file(s)"
        if ($failed -gt 0) { Warn "the rest are locked by the app - fully quit it and run this script again" }
    }
}

# --- 3. optional: reset the ledger -----------------------------------------
if ($ResetLedger) {
    if (Test-Path -LiteralPath $ledgerPath) {
        Backup-File $ledgerPath
        $empty = '{ "records": [], "detected_connector_records": [] }'
        if ($DryRun) { Say "DRYRUN would reset $ledgerPath" }
        else { Write-TextNoBom $ledgerPath $empty; Say "ledger reset: $ledgerPath" }
        Warn "with the ledger cleared, re-enabling the import feature would import those conversations again."
    }
}
else { Say "ledger kept as-is (it only records history; keeping it stops a re-import)" }

# --- 4. what about the MCP merge? ------------------------------------------
Say ""
Say "Next: the MCP merge only happened because the feature was on. With it off,"
Say "the 'url is not supported for stdio in mcp_servers.github' error should stop."
Say "If it still appears, run fix-github-mcp.ps1 (see TROUBLESHOOTING.md)."

Say ""
Say "done."
