# fix-github-mcp.ps1
# ---------------------------------------------------------------------------
# Fix:  "config.toml could not be loaded: url is not supported for stdio
#        in `mcp_servers.github`"
#
# Why it happens
#   The same MCP server name "github" is defined twice with two different
#   transports, and the desktop app merges them:
#
#     ~/.codex/config.toml   [mcp_servers.github]   stdio  (npx mcp-remote)
#     ~/.mcp.json            mcpServers.github      http   (url = ...)
#     curated plugin         mcpServers.github      http   (url = ...)
#
#   The merged result is a stdio server that also carries a `url`,
#   which the config validator rejects.
#
# Two ways out - pick with -Mode:
#
#   Native        (default, recommended)
#       Rewrite [mcp_servers.github] in config.toml as a native HTTP server,
#       matching the other two sources. Drops the npx/mcp-remote layer.
#       Needs a GitHub PAT in an environment variable - add -SetToken to have
#       this script lift the token out of ~/.codex/mcp-headers.txt and store it
#       as GITHUB_PAT_TOKEN / GITHUB_PERSONAL_ACCESS_TOKEN (user scope).
#       The token value is never printed.
#
#   RenameImport
#       Leave config.toml alone (your existing stdio setup keeps working) and
#       rename the "github" key in ~/.mcp.json to "github-api" so it no longer
#       collides. No token handling at all. Note: other tools that read
#       ~/.mcp.json will see the new name too.
#
# Always: a timestamped backup of every file it touches.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-github-mcp.ps1 -DryRun
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-github-mcp.ps1 -Mode Native -SetToken
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-github-mcp.ps1 -Mode RenameImport
#
# ASCII-only on purpose (Windows PowerShell 5.1 mis-decodes BOM-less UTF-8).
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [ValidateSet('Native', 'RenameImport')]
    [string]$Mode = 'Native',

    [switch]$SetToken,       # Mode=Native: also set the token env vars
    [switch]$DryRun,

    [string]$ConfigPath    = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$SharedMcpPath = (Join-Path $env:USERPROFILE '.mcp.json'),
    [string]$HeadersPath   = (Join-Path $env:USERPROFILE '.codex\mcp-headers.txt'),
    [string]$Url           = 'https://api.githubcopilot.com/mcp/',
    [string]$TokenEnvVar   = 'GITHUB_PAT_TOKEN'
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say($m)  { Write-Host "[github-mcp] $m" }
function Fail($m) { Write-Host "[github-mcp] $m" -ForegroundColor Red; exit 1 }

function Backup-File([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    $bak = "$p.bak-githubfix-$stamp"
    if ($DryRun) { Say "DRYRUN would back up: $p -> $bak"; return }
    Copy-Item -LiteralPath $p -Destination $bak -Force
    Say "backed up: $bak"
}

# config.toml must stay BOM-less: TOML readers may choke on a BOM.
function Write-TextNoBom([string]$p, [string]$text) {
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-Text([string]$p) {
    [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
}

# --- locate the [mcp_servers.github] block ---------------------------------
function Get-Block {
    param([string]$Text, [string]$Header)
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $Header) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $lines.Count - 1
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*\[') { $end = $j - 1; break }
    }
    return [pscustomobject]@{ Start = $start; End = $end; Lines = $lines }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { Fail "config.toml not found: $ConfigPath" }
$cfg = Read-Text $ConfigPath
$blk = Get-Block -Text $cfg -Header '[mcp_servers.github]'
if (-not $blk) { Fail "no [mcp_servers.github] section found in $ConfigPath" }

Say "current [mcp_servers.github] block:"
$blk.Lines[$blk.Start..$blk.End] | ForEach-Object { Write-Host "    $_" }

switch ($Mode) {

    'Native' {
        $new = @(
            '[mcp_servers.github]',
            "url = `"$Url`"",
            "bearer_token_env_var = `"$TokenEnvVar`"",
            'startup_timeout_sec = 120'
        )

        $out = @()
        $out += $blk.Lines[0..($blk.Start - 1)]
        $out += $new
        if ($blk.End + 1 -le $blk.Lines.Count - 1) { $out += $blk.Lines[($blk.End + 1)..($blk.Lines.Count - 1)] }
        $newText = ($out -join "`r`n")

        Say "new [mcp_servers.github] block:"
        $new | ForEach-Object { Write-Host "    $_" }

        Backup-File $ConfigPath
        if ($DryRun) { Say "DRYRUN would write $ConfigPath" }
        else { Write-TextNoBom $ConfigPath $newText; Say "written: $ConfigPath" }

        if ($SetToken) {
            if (-not (Test-Path -LiteralPath $HeadersPath)) { Say "no headers file at $HeadersPath - skipping token step" }
            else {
                $line = (Get-Content -LiteralPath $HeadersPath -Encoding UTF8 -ErrorAction SilentlyContinue |
                         Where-Object { $_ -match '^\s*Authorization\s*:' } | Select-Object -First 1)
                if (-not $line) { Say "no 'Authorization:' line in $HeadersPath - skipping token step" }
                else {
                    $tok = ($line -split ':', 2)[1].Trim()
                    $tok = $tok -replace '^(?i)Bearer\s+', ''
                    if ($tok.Length -lt 10) { Say "extracted token looks too short - skipping token step" }
                    else {
                        Say ("token found in the headers file (length {0}) - storing it as user environment variables" -f $tok.Length)
                        if ($DryRun) {
                            Say "DRYRUN would set $TokenEnvVar and GITHUB_PERSONAL_ACCESS_TOKEN (User scope)"
                        }
                        else {
                            [Environment]::SetEnvironmentVariable($TokenEnvVar, $tok, 'User')
                            [Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', $tok, 'User')
                            Say "set $TokenEnvVar and GITHUB_PERSONAL_ACCESS_TOKEN (User scope)"
                            Say "NOTE: already-running processes keep the old environment - restart the app."
                        }
                    }
                }
            }
        }
        else {
            Say "reminder: without -SetToken you must provide the token yourself, e.g."
            Say "    [Environment]::SetEnvironmentVariable('$TokenEnvVar','<your PAT>','User')"
        }
    }

    'RenameImport' {
        if (-not (Test-Path -LiteralPath $SharedMcpPath)) { Fail "not found: $SharedMcpPath" }
        $raw = Read-Text $SharedMcpPath
        try { $json = $raw | ConvertFrom-Json } catch { Fail "cannot parse $SharedMcpPath as JSON: $($_.Exception.Message)" }

        if (-not $json.mcpServers) { Fail "$SharedMcpPath has no 'mcpServers' object" }
        $names = @($json.mcpServers.PSObject.Properties.Name)
        if ($names -notcontains 'github') { Fail "no 'github' key inside mcpServers (found: $($names -join ', '))" }
        if ($names -contains 'github-api') { Fail "'github-api' already exists - rename it by hand to avoid a clash" }

        $json.mcpServers | Add-Member -NotePropertyName 'github-api' -NotePropertyValue $json.mcpServers.github -Force
        $json.mcpServers.PSObject.Properties.Remove('github')

        $newJson = $json | ConvertTo-Json -Depth 20
        Say "renamed mcpServers.github -> mcpServers.github-api in $SharedMcpPath"

        Backup-File $SharedMcpPath
        if ($DryRun) { Say "DRYRUN would write $SharedMcpPath" }
        else { Write-TextNoBom $SharedMcpPath $newJson; Say "written: $SharedMcpPath" }
        Say "config.toml was NOT touched - your stdio github server keeps working."
    }
}

Say "done. Reopen the conversation in the app to pick up the new config."
if ($Mode -eq 'Native' -and $SetToken -and -not $DryRun) {
    Say "the token only reaches newly started processes - fully quit the app first (including the tray icon), then open it again."
}
