# Keeper for the chatgpt-style-cursor-overlay skill.
# Runs at sign-in: installs into every existing agent, then blocks on a
# FileSystemWatcher and installs the moment a new agent folder appears.
# Event-driven - it uses a blocking wait, so there is no timer and no CPU use
# while idle. Started by install.ps1 -Hook.
# Usage: powershell -ExecutionPolicy Bypass -File keeper.ps1 [-Once] [-Log <path>] [-OpenBotRoot <path>]
param(
    [switch]$Once,
    [string]$OpenBotRoot = '',
    [string]$Log = ''
)
function Log([string]$m) {
    if ($Log) { try { Add-Content -Path $Log -Value ((Get-Date -Format 's') + ' ' + $m) -ErrorAction SilentlyContinue } catch {} }
}

$here = $PSScriptRoot
$install = @((Join-Path $here 'install.ps1'), (Join-Path (Split-Path $here -Parent) 'install.ps1')) |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $install) { Write-Warning "install.ps1 not found next to keeper.ps1 or in its parent"; exit 1 }
if (-not $OpenBotRoot) { $OpenBotRoot = Join-Path $env:USERPROFILE 'OpenBot' }
$agentsRoot = Join-Path $OpenBotRoot 'Agents'
if (-not (Test-Path $agentsRoot)) { exit 1 }

# Catch-up pass for agents created while this machine (or the keeper) was down.
Log "catch-up pass start"
& $install -All -Quiet -OpenBotRoot $OpenBotRoot
Log "catch-up pass done"

if ($Once) { exit 0 }

# One keeper per session.
$mutex = New-Object System.Threading.Mutex($false, 'OpenBotSkillCursorOverlayKeeper')
if (-not $mutex.WaitOne(0)) { exit 0 }
Log "watching $agentsRoot"

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $agentsRoot
$watcher.Filter = '*'
$watcher.IncludeSubdirectories = $false
$null = Register-ObjectEvent $watcher 'Created' -SourceIdentifier 'OpenBotSkillKeeperCreated'
try {
    $watcher.EnableRaisingEvents = $true
    while ($true) {
        # Blocks (no CPU) until a new folder appears or 60s pass.
        $evt = Wait-Event -SourceIdentifier 'OpenBotSkillKeeperCreated' -Timeout 60 -ErrorAction SilentlyContinue
        if (-not $evt) { continue }
        $name = $evt.SourceEventArgs.Name
        if ($name -notmatch '^agent-[0-9a-fA-F-]{36}$') { continue }
        Log "new agent folder: $name"
        Start-Sleep -Milliseconds 500
        for ($i = 0; $i -lt 5; $i++) {
            try {
                & $install -Agent $name -Quiet -OpenBotRoot $OpenBotRoot | Out-Null
                Log "installed skill for $name"
                break
            } catch {
                Log "retry $i for ${name}: $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }
    }
} finally {
    Unregister-Event 'OpenBotSkillKeeperCreated' -ErrorAction SilentlyContinue
    $watcher.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
