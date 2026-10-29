# One-click installer for the chatgpt-style-cursor-overlay skill.
# Copies SKILL.md + scripts\ into one or more OpenBot agents' local skill folders.
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Agent <name|id>] [-All] [-Repo <path>] [-OpenBotRoot <path>]
# New agents added later are picked up automatically with:
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Hook      # sign-in keeper, event-driven (no polling)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Hook -Poll # hourly check instead of a resident watcher
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Unhook    # remove that keeper + its task
param(
    [string]$Agent = '',
    [switch]$All,
    [string]$Repo = '',
    [string]$OpenBotRoot = '',
    [switch]$Hook,
    [switch]$Poll,
    [switch]$Unhook,
    [switch]$Quiet
)

$skillName = 'chatgpt-style-cursor-overlay'
$taskName = 'OpenBotSkill-chatgpt-style-cursor-overlay'
$taskDesc = 'Keeps the chatgpt-style-cursor-overlay skill installed in every OpenBot agent on this machine, including agents created later.'
function Say([string]$msg) { if (-not $Quiet) { Write-Output $msg } }

function Get-TaskRoot { Join-Path $env:LOCALAPPDATA 'OpenBotSkills' }
function Get-Stage { Join-Path (Get-TaskRoot) $skillName }
function Get-StartupLink { Join-Path ([Environment]::GetFolderPath('Startup')) "$taskName.lnk" }

function Remove-KeeperProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '-File\s+".*keeper\.ps1"' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Unhook) {
    Remove-KeeperProcesses
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Say "Removed scheduled task $taskName"
    } else {
        & schtasks /Delete /F /TN $taskName 2>&1 | Out-Null
    }
    foreach ($f in @((Get-StartupLink), (Join-Path (Get-Stage) 'keeper.vbs'))) {
        if (Test-Path $f) { Remove-Item $f -Force; Say "Removed $f" }
    }
    Say 'Done. Existing agent installs are left in place; new agents will not get the skill.'
    return
}

# -Hook without a target means: every agent on this machine.
if ($Hook -and -not $Agent -and -not $All) { $All = $true }

$Repo = if ($Repo) { $Repo } else { $PSScriptRoot }
if (-not (Test-Path (Join-Path $Repo 'SKILL.md'))) { throw "SKILL.md not found in '$Repo' - run from the repo root or pass -Repo." }

if (-not $OpenBotRoot) { $OpenBotRoot = Join-Path $env:USERPROFILE 'OpenBot' }
$agentsRoot = Join-Path $OpenBotRoot 'Agents'
if (-not (Test-Path $agentsRoot)) { throw "No OpenBot Agents folder at '$agentsRoot' - pass -OpenBotRoot." }

function Find-AgentIds([string]$name) {
    # openbot.db is locked while OpenBot runs; copy it and regex the JSON text (no SQLite needed).
    $db = Join-Path $env:APPDATA 'OpenBot\openbot.db'
    if (-not (Test-Path $db)) { return @() }
    $tmp = Join-Path $env:TEMP ('ob_inst_' + [guid]::NewGuid().ToString('N') + '.db')
    try {
        Copy-Item $db $tmp -Force
        $s = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::GetEncoding('ISO-8859-1'))
        $esc = [regex]::Escape($name)
        $m = [regex]::Matches($s, ('"id":"(agent-[0-9a-fA-F-]{36})","name":"' + $esc + '"'))
        , ($m | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    } catch { , @() } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

$targets = @()
if ($All) {
    $targets = Get-ChildItem $agentsRoot -Directory -Filter 'agent-*' | ForEach-Object { $_.FullName }
} elseif ($Agent -match '^agent-[0-9a-fA-F-]{36}$') {
    $targets = , (Join-Path $agentsRoot $Agent)
} elseif ($Agent) {
    $ids = Find-AgentIds $Agent
    if (-not $ids) { throw "No agent named '$Agent'. Use -All or an agent id." }
    $targets = $ids | ForEach-Object { Join-Path $agentsRoot $_ }
} else {
    $m = [regex]::Match((Get-Location).Path, 'agent-[0-9a-fA-F-]{36}')
    if ($m.Success) {
        $targets = , (Join-Path $agentsRoot $m.Value)
    } else {
        Say 'Available agents:'
        Get-ChildItem $agentsRoot -Directory -Filter 'agent-*' | ForEach-Object { Say ('  ' + $_.Name) }
        throw 'Specify -Agent <name|id> or -All (or use -Hook to install for all agents and keep new ones up to date).'
    }
}

function Same-File([string]$a, [string]$b) {
    if (-not (Test-Path $b)) { return $false }
    (Get-FileHash $a -Algorithm SHA256).Hash -eq (Get-FileHash $b -Algorithm SHA256).Hash
}

$payload = @('SKILL.md', 'scripts\cursor_overlay.ps1', 'scripts\cursor_overlay.py') |
    Where-Object { Test-Path (Join-Path $Repo $_) }

$installed = 0
foreach ($dir in $targets) {
    if (-not (Test-Path $dir)) { Write-Warning "Missing agent dir: $dir"; continue }
    $copied = $false
    foreach ($skillsDir in @('.agents\skills', '.claude\skills')) {
        $dst = Join-Path (Join-Path $dir $skillsDir) $skillName
        if ($payload | Where-Object { -not (Same-File (Join-Path $Repo $_) (Join-Path $dst $_)) }) {
            foreach ($f in $payload) {
                $target = Join-Path $dst $f
                New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
                Copy-Item (Join-Path $Repo $f) $target -Force
            }
            $copied = $true
        }
    }
    if ($copied) { $installed++; Say "Installed $skillName -> $dir" }
}
if ($installed -eq 0) { Say "$skillName is already up to date in all target agents." }

if (-not $Hook) {
    Say 'Done. If a running OpenBot does not show the skill, restart it or have the agent register the folder with its skill tool.'
    Say 'Tip: add -Hook to keep agents created later up to date automatically.'
    return
}

# --- Keep NEW agents up to date: stage a copy outside the repo + a keeper that runs at sign-in. ---
$stage = Get-Stage
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'scripts') | Out-Null
foreach ($f in @('SKILL.md', 'README.md', 'install.ps1', 'install.sh', 'scripts\cursor_overlay.ps1', 'scripts\cursor_overlay.py', 'scripts\keeper.ps1')) {
    $src = Join-Path $Repo $f
    if (-not (Test-Path $src)) { continue }
    $target = Join-Path $stage $f
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item $src $target -Force
}
Say "Staged a copy of the skill at $stage"

$keeper = Join-Path $stage 'scripts\keeper.ps1'
$keeperArg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"{1} -Log "{2}"' -f $keeper,
    $(if ($Poll) { ' -Once' } else { '' }), (Join-Path $stage 'keeper.log')
Remove-KeeperProcesses

$hooked = $null
$vbs = Join-Path $stage 'keeper.vbs'
@(
    'Set sh = CreateObject("WScript.Shell")'
    'sh.Run "powershell.exe {0}", 0, false' -f ($keeperArg -replace '"', '""')
) | Set-Content -Path $vbs -Encoding ASCII

# 1) Task Scheduler, sign-in trigger (event-driven; no periodic work unless -Poll).
try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"' + $vbs + '"'
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if ($Poll) {
        $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    }
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Description $taskDesc -Force -ErrorAction Stop | Out-Null
    $hooked = if ($Poll) { "scheduled task '$taskName' (sign-in + hourly check)" } else { "scheduled task '$taskName' (sign-in only)" }
} catch {
    Say 'Task Scheduler registration is not available without elevated rights - using a sign-in startup entry instead.'
}
# 2) Fallback that needs no admin rights: a Startup shortcut.
if (-not $hooked) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut((Get-StartupLink))
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + $vbs + '"'
    $lnk.Description = $taskDesc
    $lnk.Save()
    $hooked = "startup shortcut '$(Get-StartupLink)'"
}
Say "Auto-update for new agents enabled via $hooked."

if ($Poll) {
    Say 'Poll mode: one short check per hour (hash-compares files, copies only what changed).'
} else {
    Say 'Watch mode: a sign-in keeper waits for new agent folders - no timer, it installs within a second of creation.'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $keeperArg -WindowStyle Hidden
    Say 'Keeper started for this session.'
}
