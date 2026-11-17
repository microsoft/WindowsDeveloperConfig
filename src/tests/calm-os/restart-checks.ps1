# Checks restart handling without changing the machine: WSL, the task scheduler, shutdown.exe,
# and the console are replaced by recording fakes. Run in a VM or sandbox, never on a workstation.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\windows-dev-config')).Path
$stepsDir = Join-Path $sourceRoot 'steps'
foreach ($helper in @('_console', '_step-runner', '_elevation', '_reboot-resume', '_registry', '_environment', '_retry', '_pwsh-bootstrap')) {
    . (Join-Path $stepsDir "$helper.ps1")
}
. (Join-Path $stepsDir 'wsl.ps1')

$script:passed = 0
$script:failed = 0
function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Check([string] $Name, [scriptblock] $Action) {
    try {
        & $Action
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "FAIL  ${Name}: $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}
function Expect-Failure([scriptblock] $Action) {
    try { & $Action } catch { return $_ }
    throw 'Expected an error, but the operation succeeded.'
}

# ---- Fakes: nothing below reaches WSL, the registry, the task scheduler, or shutdown.exe.
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Ready = $false
$script:CbsPending = $false
$script:InstallSignalsRestart = $true
$script:ConsoleInput = $true
$script:CountdownResult = $true
$script:ShutdownExit = 0
$script:BootTime = [DateTime]::UtcNow.AddHours(-1)

function Test-DevConfigWslComponentsReady { return $script:Ready }
function Test-DevConfigServicingRebootPending { return $script:CbsPending }
function Install-DevConfigWslComponents {
    $script:Calls.Add('wsl --install --no-distribution')
    if ($script:InstallSignalsRestart) { $Script:DevConfigWslRestartSignalled = $true }
}
function Test-DevConfigUbuntuInstalled { return $false }
function Install-DevConfigUbuntuVia {
    param([string[]] $Arguments, [int] $MaxAttempts)
    $script:Calls.Add("wsl $($Arguments -join ' ')")
    return $true
}
function Set-DevConfigRegistryValue {
    param([string] $KeyPath, [string] $ValueName, $Value, [string] $Type = 'DWord')
    $script:Calls.Add("set $KeyPath\$ValueName=$Value")
}
function Get-DevConfigBootTimeUtc { return $script:BootTime }
function Get-DevConfigTaskShellExe { return 'C:\Program Files\PowerShell\7\pwsh.exe' }
function New-ScheduledTaskAction {
    param($Execute, $Argument)
    $script:Calls.Add("task action $Argument")
    [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
}
function New-ScheduledTaskTrigger { param([switch] $AtLogOn, $User) [pscustomobject]@{ Delay = $null } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) $script:Calls.Add("task principal $LogonType $RunLevel"); [pscustomobject]@{} }
function Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, [switch] $Force) $script:Calls.Add("register $TaskName") }
function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $script:Calls.Add("unregister $TaskName") }
function Save-DevConfigTally { param($Path, $TerminalBackedUp) $script:Calls.Add('save tally') }
function Test-DevConfigConsoleInput { return $script:ConsoleInput }
function Wait-DevConfigRestartCountdown { param([int] $Seconds) $script:Calls.Add("countdown $Seconds"); return $script:CountdownResult }
# Keys typed before the question come first, then $null (nothing waiting), then the keys typed after it.
$script:Keys = [Collections.Generic.Queue[object]]::new()
function Read-DevConfigKey {
    if ($script:Keys.Count -eq 0) { return $null }
    return $script:Keys.Dequeue()
}
function Set-Keys([object[]] $Keys) {
    $script:Keys.Clear()
    foreach ($key in $Keys) { $script:Keys.Enqueue($key) }
}
function Invoke-DevConfigNativeCommand {
    param([string] $FilePath, [string[]] $Arguments, [int] $TimeoutSeconds)
    $script:Calls.Add("run $([IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ')")
    [pscustomobject]@{ ExitCode = $script:ShutdownExit; Output = '' }
}
function Restart-Computer { throw 'Checks must not restart Windows.' }

function Reset-Fakes {
    $script:Calls.Clear()
    $script:Ready = $false
    $script:CbsPending = $false
    $script:InstallSignalsRestart = $true
    $script:ConsoleInput = $true
    $script:CountdownResult = $true
    $script:ShutdownExit = 0
    $script:Keys.Clear()
    $Script:DevConfigRestartQuestionAsked = $false
    $Script:DevConfigAction = 'Full'
    $Script:DevConfigWorkload = 'devconfig'
    $Script:DevConfigSkip = @()
    $Script:DevConfigAllowUnsigned = $false
    $Script:DevConfigResumed = $false
    $Script:DevConfigAfterRestart = $false
    $Script:DevConfigRestartRequestPending = $false
    $Script:DevConfigRestartRequired = $false
    $Script:DevConfigRestartPendingSteps = @()
    $Script:DevConfigTally = @{ Done = 0; AlreadyOk = 0; Warned = 0 }
    $Script:DevConfigTalliedSteps = @{}
    $Script:DevConfigWarnedSteps = @()
    $Script:DevConfigTerminalBackedUp = @()
    $Script:DevConfigPhaseName = 'wsl'
    $Script:DevConfigPhaseTitle = 'WSL + Ubuntu'
    $Script:DevConfigPhaseHeaderShown = $false
}
function Invoke-Wsl {
    return @(Invoke-WslPhase 6>&1 | ForEach-Object { "$_" })
}

Check 'By default a WSL install that needs a restart waits for it, and Ubuntu waits too' {
    Reset-Fakes
    $output = Invoke-Wsl
    Assert $Script:DevConfigRestartRequired 'The run must report that a restart is required.'
    Assert (($Script:DevConfigRestartPendingSteps -join ',') -eq 'WslComponents,WslUbuntu') "Unexpected waiting steps: $($Script:DevConfigRestartPendingSteps -join ',')"
    Assert (@($script:Calls | Where-Object { $_ -like 'wsl --install -d*' -or $_ -like 'set *Lxss*' }).Count -eq 0) 'Ubuntu must wait for the restart.'
    Assert (@($script:Calls | Where-Object { $_ -like 'register *' -or $_ -like 'run shutdown.exe*' -or $_ -like 'task *' }).Count -eq 0) "Setup restarted or scheduled a resume by default: $($script:Calls -join '; ')"
    Assert ($Script:DevConfigTally.Done -eq 0 -and $Script:DevConfigTally.Warned -eq 0) 'Waiting steps are neither done nor flagged.'
    Assert (@($output | Where-Object { $_ -match '^\s+~ WslComponents\s+waiting for a restart$' }).Count -eq 1) 'The waiting step must be reported.'
}

Check 'A pending servicing restart alone also makes WSL wait' {
    Reset-Fakes
    $script:InstallSignalsRestart = $false
    $script:CbsPending = $true
    $null = Invoke-Wsl
    Assert $Script:DevConfigRestartRequired 'A pending Windows servicing restart must be reported.'
}

Check 'An active WSL needs no restart and Ubuntu installs' {
    Reset-Fakes
    $script:Ready = $true
    $null = Invoke-Wsl
    Assert (-not $Script:DevConfigRestartRequired) 'No restart is needed when WSL is active.'
    Assert (@($script:Calls | Where-Object { $_ -like 'wsl --install -d Ubuntu --no-launch' }).Count -eq 1) 'Ubuntu must install.'
}

Check 'Running again before the restart does not reinstall WSL' {
    Reset-Fakes
    $Script:DevConfigRestartRequestPending = $true
    $script:CbsPending = $true
    $null = Invoke-Wsl
    Assert (@($script:Calls | Where-Object { $_ -eq 'wsl --install --no-distribution' }).Count -eq 0) 'WSL was installed again while its restart was still pending.'
    Assert $Script:DevConfigRestartRequired 'The run must still report that a restart is required.'
}

Check 'After a restart, a WSL that still is not active stops instead of asking for another restart' {
    Reset-Fakes
    $Script:DevConfigAfterRestart = $true
    $null = Invoke-Wsl
    Assert (-not $Script:DevConfigRestartRequired) 'Another restart would not help, so none may be requested.'
    Assert ($Script:DevConfigWarnedSteps -contains 'WslComponents') 'The inactive platform must be flagged.'
}

Check 'After a restart, a still-pending servicing restart does not make Ubuntu ask for another one' {
    Reset-Fakes
    $Script:DevConfigAfterRestart = $true
    $script:CbsPending = $true
    $null = Invoke-Wsl
    Assert (-not $Script:DevConfigRestartRequired) 'A restart loop must not be possible.'
    Assert ($Script:DevConfigRestartPendingSteps.Count -eq 0) "Steps waited again: $($Script:DevConfigRestartPendingSteps -join ',')"
    Assert ($Script:DevConfigWarnedSteps -contains 'WslUbuntu') 'Ubuntu must be flagged instead.'
}

function New-TestDirectory {
    $directory = Join-Path ([IO.Path]::GetTempPath()) "DevConfig-RestartChecks-$([guid]::NewGuid().ToString('N'))"
    (New-Item -ItemType Directory -Path $directory).FullName
}
# A setup folder holding a saved, still-pending request, as a run that needs a restart leaves behind.
function New-PendingSetupPath {
    $directory = New-TestDirectory
    $script:BootTime = [DateTime]::UtcNow.AddHours(-1)
    $Script:DevConfigRestartPendingSteps = @('WslComponents', 'WslUbuntu')
    if (-not (Save-DevConfigRestartRequest -Directory $directory 6>$null)) { throw 'The test request could not be saved.' }
    return (Join-Path $directory 'dev-config.ps1')
}
function Remove-TestSetupPath([string] $ScriptPath) {
    Remove-Item -LiteralPath (Split-Path -Parent $ScriptPath) -Recurse -Force
}

Check 'A restart request reads as pending until Windows restarts' {
    Reset-Fakes
    $directory = New-TestDirectory
    try {
        Assert ((Get-DevConfigRestartRequest -Directory $directory).State -eq 'None') 'No request was saved yet.'
        $script:BootTime = [DateTime]::UtcNow.AddHours(-1)
        $Script:DevConfigRestartPendingSteps = @('WslComponents', 'WslUbuntu')
        Assert (Save-DevConfigRestartRequest -Directory $directory) 'Saving a request must report success.'
        Assert (Save-DevConfigRestartRequest -Directory $directory) 'Saving over an earlier request must report success.'
        Assert (-not (Test-Path -LiteralPath "$(Get-DevConfigRestartRequestPath -Directory $directory).new")) 'The temporary file must not be left behind.'
        $request = Get-DevConfigRestartRequest -Directory $directory
        Assert ($request.State -eq 'Pending') 'Windows has not restarted since the request.'
        Assert (($request.Waiting -join ',') -eq 'WslComponents,WslUbuntu') "The waiting steps were not kept: $($request.Waiting -join ',')"
        $script:BootTime = [DateTime]::UtcNow.AddMinutes(1)
        Assert ((Get-DevConfigRestartRequest -Directory $directory).State -eq 'Restarted') 'Windows restarted after the request.'
        Clear-DevConfigRestartRequest -Directory $directory
        Assert ((Get-DevConfigRestartRequest -Directory $directory).State -eq 'None') 'A finished run clears the request.'
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

Check 'A malformed request reads as Unknown with the reason, never as no request' {
    Reset-Fakes
    $directory = New-TestDirectory
    try {
        $path = Get-DevConfigRestartRequestPath -Directory $directory
        $now = [DateTime]::UtcNow.Ticks
        foreach ($content in @('not json', '', '42', '[1]', '{"Waiting":["WslUbuntu"]}', '{"RequestedAtUtcTicks":-5,"Waiting":[]}',
                '{"RequestedAtUtcTicks":true,"Waiting":[]}', '{"RequestedAtUtcTicks":1,"Waiting":[]}', '{"RequestedAtUtcTicks":"123","Waiting":[]}',
                "{`"RequestedAtUtcTicks`":$([DateTime]::UtcNow.AddDays(3).Ticks),`"Waiting`":[]}", "{`"RequestedAtUtcTicks`":$now}",
                "{`"RequestedAtUtcTicks`":$now,`"Waiting`":[1]}", "{`"RequestedAtUtcTicks`":$now,`"Waiting`":null}")) {
            [IO.File]::WriteAllText($path, $content)
            $request = Get-DevConfigRestartRequest -Directory $directory
            Assert ($request.State -eq 'Unknown') "'$content' read as $($request.State)."
            Assert ($request.Reason -like "*could not be read*") "Unclear reason for '$content': $($request.Reason)"
            Assert ([IO.File]::ReadAllText($path) -eq $content) 'Reading must leave the file as it is.'
        }
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

Check 'A request that cannot be opened reads as Unknown' {
    Reset-Fakes
    $setupPath = New-PendingSetupPath
    $path = Get-DevConfigRestartRequestPath -Directory (Split-Path -Parent $setupPath)
    $lock = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
    try {
        $request = Get-DevConfigRestartRequest -Directory (Split-Path -Parent $setupPath)
        Assert ($request.State -eq 'Unknown' -and $request.Reason -like '*could not be read*') "A locked request read as $($request.State): $($request.Reason)"
    } finally {
        $lock.Dispose()
        Remove-TestSetupPath $setupPath
    }
}

Check 'An unavailable boot time reads as Unknown, never as a restart' {
    Reset-Fakes
    $setupPath = New-PendingSetupPath
    function Get-DevConfigBootTimeUtc { throw 'Invalid class' }
    try {
        $request = Get-DevConfigRestartRequest -Directory (Split-Path -Parent $setupPath)
        Assert ($request.State -eq 'Unknown' -and $request.Reason -like "*boot time could not be read*Invalid class*") "Unexpected state $($request.State): $($request.Reason)"
    } finally {
        Remove-TestSetupPath $setupPath
    }
}

Check 'A request that cannot be saved or confirmed reports failure' {
    Reset-Fakes
    $missing = Join-Path ([IO.Path]::GetTempPath()) "DevConfig-RestartChecks-missing-$([guid]::NewGuid().ToString('N'))"
    Assert (-not (Save-DevConfigRestartRequest -Directory $missing 6>$null)) 'Saving into a missing folder must fail.'
    Assert (-not (Test-Path -LiteralPath $missing)) 'Nothing may be created for a failed save.'
    $directory = New-TestDirectory
    function Get-DevConfigBootTimeUtc { throw 'Invalid class' }
    try {
        Assert (-not (Save-DevConfigRestartRequest -Directory $directory 6>$null)) 'A request that cannot be read back must not count as saved.'
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

Check 'Without a readable pending request, -RestartWhenNeeded registers nothing and restarts nothing' {
    Reset-Fakes
    $directory = New-TestDirectory
    try {
        $setupPath = Join-Path $directory 'dev-config.ps1'
        $path = Get-DevConfigRestartRequestPath -Directory $directory
        foreach ($case in @('none', 'malformed', 'restarted', 'boot time unavailable')) {
            $script:Calls.Clear()
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $script:BootTime = [DateTime]::UtcNow.AddHours(-1)
            switch ($case) {
                'malformed' { [IO.File]::WriteAllText($path, 'not json') }
                'restarted' { $null = Save-DevConfigRestartRequest -Directory $directory 6>$null; $script:BootTime = [DateTime]::UtcNow.AddMinutes(1) }
                'boot time unavailable' { $null = Save-DevConfigRestartRequest -Directory $directory 6>$null; $script:BootTime = $null }
            }
            if ($case -eq 'boot time unavailable') {
                function Get-DevConfigBootTimeUtc { throw 'Invalid class' }
            }
            $restarting = Suspend-DevConfigForReboot -ScriptPath $setupPath 6>$null
            Assert (-not $restarting) "A restart was reported with a $case request."
            $acted = @($script:Calls | Where-Object { $_ -like 'register *' -or $_ -like 'unregister *' -or $_ -eq 'save tally' -or
                $_ -like 'countdown *' -or $_ -like 'run shutdown.exe*' })
            Assert ($acted.Count -eq 0) "With a $case request, setup still acted: $($acted -join '; ')"
        }
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

Check '-RestartWhenNeeded registers a limited resume task and restarts after the countdown without /f' {
    Reset-Fakes
    $Script:DevConfigSkip = @('registry-system/Sudo')
    $setupPath = New-PendingSetupPath
    try {
        $restarting = Suspend-DevConfigForReboot -ScriptPath $setupPath 6>$null
        Assert $restarting 'The restart must be reported as under way.'
        Assert (@($script:Calls | Where-Object { $_ -like 'task action *-Action Full -Skip registry-system/Sudo -Resumed -RestartWhenNeeded' }).Count -eq 1) "Unexpected resume arguments: $($script:Calls -join '; ')"
        Assert ($script:Calls -contains 'task principal Interactive Limited') 'The resume task must run limited and ask for UAC again.'
        Assert ($script:Calls -contains 'register WindowsDevConfigResume') 'The resume task must be registered.'
        Assert ($script:Calls -contains 'countdown 60') 'The restart must wait for the countdown.'
        Assert ($script:Calls -contains 'run shutdown.exe /r /t 0') "Unexpected restart command: $($script:Calls -join '; ')"
    } finally {
        Remove-TestSetupPath $setupPath
    }
}

Check 'A cancelled countdown restarts nothing and keeps the resume task' {
    Reset-Fakes
    $script:CountdownResult = $false
    $setupPath = New-PendingSetupPath
    try {
        $restarting = Suspend-DevConfigForReboot -ScriptPath $setupPath 6>$null
        Assert (-not $restarting) 'A cancelled restart must be reported.'
        Assert (@($script:Calls | Where-Object { $_ -like 'run shutdown.exe*' }).Count -eq 0) 'Windows must not restart after the countdown is cancelled.'
        Assert ($script:Calls -contains 'register WindowsDevConfigResume') 'The resume task stays registered for the next restart.'
    } finally {
        Remove-TestSetupPath $setupPath
    }
}

Check 'With -RestartWhenNeeded and no console, as in a VM or lab, setup restarts right away without /f' {
    Reset-Fakes
    $script:ConsoleInput = $false
    $setupPath = New-PendingSetupPath
    try {
        $restarting = Suspend-DevConfigForReboot -ScriptPath $setupPath 6>$null
        Assert $restarting 'The restart must be reported as under way.'
        Assert ($script:Calls -contains 'register WindowsDevConfigResume') 'The resume task must be registered before the restart.'
        Assert (@($script:Calls | Where-Object { $_ -like 'countdown *' }).Count -eq 0) 'Without a console there is no countdown to show.'
        Assert ((@($script:Calls | Where-Object { $_ -like 'run shutdown.exe*' }) -join ';') -eq 'run shutdown.exe /r /t 0') "Unexpected restart command: $($script:Calls -join '; ')"
    } finally {
        Remove-TestSetupPath $setupPath
    }
}

Check 'A refused restart is reported, not hidden' {
    Reset-Fakes
    $script:ShutdownExit = 5
    $setupPath = New-PendingSetupPath
    try {
        Assert (-not (Suspend-DevConfigForReboot -ScriptPath $setupPath 6>$null)) 'A refused restart must be reported.'
    } finally {
        Remove-TestSetupPath $setupPath
    }
}

Check 'Restart now? [Y/n]: Enter and Y mean yes, N and Esc mean no, other keys are ignored' {
    foreach ($case in @(
            @{ Typed = @($null, 'Enter'); Answer = 'Yes' }
            @{ Typed = @($null, 'Y'); Answer = 'Yes' }
            @{ Typed = @($null, 'N'); Answer = 'No' }
            @{ Typed = @($null, 'Escape'); Answer = 'No' }
            @{ Typed = @($null, 'Spacebar', 'D7', 'N'); Answer = 'No' })) {
        Reset-Fakes
        Set-Keys $case.Typed
        $answer = Read-DevConfigRestartAnswer -TimeoutSeconds 5 6>$null
        Assert ($answer -eq $case.Answer) "Keys $($case.Typed -join ',') answered $answer, not $($case.Answer)."
    }
}

Check 'A key pressed before the question, such as Enter during the run, does not answer it' {
    Reset-Fakes
    Set-Keys @('Enter', 'Y', $null, 'N')
    $answer = Read-DevConfigRestartAnswer -TimeoutSeconds 5 6>$null
    Assert ($answer -eq 'No') "Earlier keys answered the question: $answer"
    $body = (Get-Command Read-DevConfigRestartAnswer).ScriptBlock.Ast.Extent.Text
    Assert ($body.IndexOf('while ($null -ne (Read-DevConfigKey))') -lt $body.IndexOf('Restart now? [Y/n]')) 'Earlier keys must be dropped before the question appears, so a quick answer to it is kept.'
}

Check 'No answer means no restart' {
    Reset-Fakes
    Set-Keys @($null, 'Spacebar')
    $started = [DateTime]::UtcNow
    $answer = Read-DevConfigRestartAnswer -TimeoutSeconds 1 6>$null
    Assert ($answer -eq 'NoAnswer') "Unexpected answer: $answer"
    Assert (([DateTime]::UtcNow - $started).TotalSeconds -lt 10) 'The question must give up at its timeout.'
}

Check 'By default someone at the console is asked first; yes restarts at once without /f and schedules nothing' {
    Reset-Fakes
    Set-Keys @($null, 'Y')
    $restarting = Request-DevConfigRestart -TimeoutSeconds 5 6>$null
    Assert $restarting 'Yes must restart Windows.'
    Assert ((@($script:Calls | Where-Object { $_ -like 'run shutdown.exe*' }) -join ';') -eq 'run shutdown.exe /r /t 0') "Unexpected restart command: $($script:Calls -join '; ')"
    Assert (@($script:Calls | Where-Object { $_ -like 'register *' -or $_ -like 'task *' -or $_ -like 'countdown *' }).Count -eq 0) "Asking must not schedule a resume or count down: $($script:Calls -join '; ')"
}

Check 'No, no answer, no console, or a refused restart leaves Windows running' {
    foreach ($case in @('no', 'no answer', 'no console', 'refused')) {
        Reset-Fakes
        switch ($case) {
            'no' { Set-Keys @($null, 'N') }
            'no answer' { Set-Keys @($null) }
            'no console' { $script:ConsoleInput = $false; Set-Keys @($null, 'Y') }
            'refused' { Set-Keys @($null, 'Y'); $script:ShutdownExit = 5 }
        }
        $output = @(Request-DevConfigRestart -TimeoutSeconds 1 6>&1 | ForEach-Object { "$_" })
        Assert ($output[-1] -eq 'False') "With $case, a restart was reported: $($output -join ' | ')"
        Assert ($Script:DevConfigRestartQuestionAsked -eq ($case -ne 'no console')) "With $case, the question replaces the final pause only when it was asked."
        $restarted = @($script:Calls | Where-Object { $_ -like 'run shutdown.exe*' })
        Assert ($restarted.Count -eq [int]($case -eq 'refused')) "With $case, shutdown.exe ran $($restarted.Count) times."
        Assert (@($script:Calls | Where-Object { $_ -like 'register *' }).Count -eq 0) "With $case, a resume task was registered."
        if ($case -eq 'no console') {
            Assert (@($output | Where-Object { $_ -like '*Restart now?*' }).Count -eq 0) 'Without a console nobody can be asked.'
        } else {
            Assert (@($output | Where-Object { $_ -like '*run the same command again*' }).Count -ge 1) "With $case, the rerun guidance is missing: $($output -join ' | ')"
        }
    }
}

Check 'Relaunches carry -RestartWhenNeeded and -NoRestart only when they were passed' {
    $plain = Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -Action Full
    Assert (($plain -join ' ') -eq '-NoProfile -ExecutionPolicy RemoteSigned -File "C:\Setup\dev-config.ps1" -Action Full -NoElevate') "Default arguments changed: $plain"
    $optIn = Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -Action Full -RestartWhenNeeded
    Assert (($optIn -join ' ') -eq '-NoProfile -ExecutionPolicy RemoteSigned -File "C:\Setup\dev-config.ps1" -Action Full -NoElevate -RestartWhenNeeded') "Opt-in arguments: $optIn"
    $never = Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -Action Full -NoRestart
    Assert (($never -join ' ') -eq '-NoProfile -ExecutionPolicy RemoteSigned -File "C:\Setup\dev-config.ps1" -Action Full -NoElevate -NoRestart') "-NoRestart arguments: $never"
    foreach ($function in @('Invoke-DevConfigElevate', 'Invoke-DevConfigEnsurePwsh', 'Invoke-DevConfigEnsureCleanupShell')) {
        $calls = @((Get-Command $function).ScriptBlock.Ast.FindAll({
            param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-DevConfigRelaunchArguments'
        }, $true))
        Assert ($calls.Count -eq 1 -and $calls[0].Extent.Text -like '*-RestartWhenNeeded:$RestartWhenNeeded -NoRestart:$NoRestart*') "$function must forward -RestartWhenNeeded and -NoRestart."
    }
}

# A restart can't help anything that runs after it in the same run, so phases that can wait for one come last.
# Uninstall never waits for a restart, so its phase order is free.
Check 'In every workload, phases that can wait for a restart run last' {
    $restartPhases = 0
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'workloads') -Filter '*.ps1') {
        foreach ($action in @((& $file.FullName -Action Full)['Actions'] | Where-Object { $_ -ne 'Uninstall' })) {
            $definition = & $file.FullName -Action $action
            $seenRestartPhase = $false
            foreach ($phase in @($definition['Phases'])) {
                $waits = [IO.File]::ReadAllText((Join-Path $stepsDir $phase['File'])) -match 'Set-DevConfigStepRestartPending'
                if ($waits) {
                    $seenRestartPhase = $true
                    $restartPhases++
                } else {
                    Assert (-not $seenRestartPhase) "$($file.BaseName) -Action ${action}: '$($phase['Title'])' runs after a phase that can wait for a restart."
                }
            }
        }
    }
    Assert ($restartPhases -gt 0) 'No workload has a phase that waits for a restart, so this check proves nothing.'
}

# ---- dev-config.ps1 and bootstrap.ps1 wiring
function Get-ScriptAst([string] $Path) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors -join [Environment]::NewLine) }
    return $ast
}
$devConfigAst = Get-ScriptAst (Join-Path $sourceRoot 'dev-config.ps1')
$bootstrapAst = Get-ScriptAst (Join-Path $sourceRoot 'bootstrap.ps1')

Check 'Only dev-config.ps1 restarts Windows: by itself only with -RestartWhenNeeded, otherwise after asking, never with -NoRestart' {
    foreach ($file in Get-ChildItem -LiteralPath $stepsDir -Filter '*.ps1') {
        $ast = Get-ScriptAst $file.FullName
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -in @('Suspend-DevConfigForReboot', 'Request-DevConfigRestart', 'Restart-Computer') }, $true))
        Assert ($calls.Count -eq 0) "$($file.Name) must not restart Windows."
        $restarts = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Restart-DevConfigWindows' }, $true))
        foreach ($call in $restarts) {
            $owner = $call.Parent
            while ($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            Assert ($file.Name -eq '_reboot-resume.ps1' -and $owner.Name -in @('Suspend-DevConfigForReboot', 'Request-DevConfigRestart')) "$($file.Name) restarts Windows outside the two restart paths."
        }
    }
    $suspend = @($devConfigAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Suspend-DevConfigForReboot' }, $true))
    $ask = @($devConfigAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Request-DevConfigRestart' }, $true))
    Assert ($suspend.Count -eq 1 -and $ask.Count -eq 1) 'dev-config.ps1 must restart in one place for each mode.'
    $guard = $suspend[0].Parent
    while ($guard -and -not ($guard -is [Management.Automation.Language.IfStatementAst] -and
            $guard.Clauses[0].Item1.Extent.Text -eq '$restartRequired -and $restartRecorded -and -not $NoRestart')) {
        $guard = $guard.Parent
    }
    Assert ($null -ne $guard) 'A restart must need a saved restart request, and -NoRestart must rule it out.'
    $mode = $guard.Clauses[0].Item2.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] }, $true)
    Assert ($mode.Clauses[0].Item1.Extent.Text -eq '$RestartWhenNeeded' -and $mode.Clauses[0].Item2.Extent.Text -like '*Suspend-DevConfigForReboot*' -and
        $mode.ElseClause.Extent.Text -like '*Request-DevConfigRestart*') 'Only -RestartWhenNeeded may restart without asking.'
    $save = $devConfigAst.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$restartRecorded' -and $n.Right.Extent.Text -like 'Save-DevConfigRestartRequest*' }, $true)
    Assert ($null -ne $save) 'Only the result of saving the request may allow the restart.'
    $exits = @($devConfigAst.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] -and
        $n.Pipeline.Extent.Text -eq '$Script:DevConfigRestartExitCode' }, $true))
    Assert ($exits.Count -ge 2) 'dev-config.ps1 must exit with the restart code instead of failing.'
    Assert ($Script:DevConfigRestartExitCode -eq 3010) 'The restart code must be 3010.'
    $afterRestart = $devConfigAst.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$Script:DevConfigAfterRestart' }, $true)
    Assert ($afterRestart.Right.Extent.Text -eq "`$restartRequest.State -eq 'Restarted'") '-Resumed alone must not count as proof of a restart.'
    $unlock = $devConfigAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Exit-DevConfigSingleInstance' }, $true)
    Assert ($unlock.Extent.StartOffset -gt $suspend[0].Extent.EndOffset -and $unlock.Extent.StartOffset -gt $ask[0].Extent.EndOffset) 'The lock must be held through the question and countdown, so no second run starts while Windows restarts.'
    $finalPause = @($devConfigAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '-not $Script:DevConfigRestartQuestionAsked' -and $_.Clauses[0].Item2.Extent.Text -like '*Wait-DevConfigKeyPress*' })
    Assert ($finalPause.Count -eq 1) 'After the restart question, the window must not wait a second time.'
    $clear = $devConfigAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Clear-DevConfigRestartRequest' }, $true)
    $clearGuard = $clear.Parent
    while ($clearGuard -and $clearGuard -isnot [Management.Automation.Language.IfStatementAst]) { $clearGuard = $clearGuard.Parent }
    Assert ($clearGuard.Extent.Text -like '*-not $Script:DevConfigTalliedSteps.ContainsKey($_)*') 'The request may be cleared only once every step that waited for the restart verified.'
}

Check 'The resume check runs before any UAC prompt and never pauses' {
    $early = $devConfigAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq "`$Resumed -and `$Action -ne 'Uninstall'"
    }
    Assert (@($early).Count -eq 1) 'The resume check was not found.'
    $body = $early.Clauses[0].Item2
    Assert ($body.Extent.Text -like '*exit $Script:DevConfigRestartExitCode*' -and $body.Extent.Text -like '*exit 1*') 'It must exit with 3010 while pending and 1 without evidence.'
    $pauses = @($body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Wait-DevConfigKeyPress' }, $true))
    Assert ($pauses.Count -eq 0) 'An unattended resume must not wait for a key.'
    $elevate = $devConfigAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Invoke-DevConfigElevate' }, $true)
    Assert ($early.Extent.EndOffset -lt $elevate.Extent.StartOffset) 'It must run before elevation.'
}

# Runs the real dev-config.ps1 -Resumed in a child process, from a copy whose only workload does nothing, so a
# broken check changes nothing. A pause either hangs it past the timeout or prints its prompt.
Check 'A resumed run without evidence of a restart exits by itself at once, without UAC; contradictory switches stop first' {
    $copy = New-TestDirectory
    try {
        Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $copy -Recurse
        Set-Content -LiteralPath (Join-Path $copy 'workloads\gatetest.ps1') -Value @'
param([string] $Action = 'Full')
@{ Name = 'Gate test'; Actions = @('Full'); Phases = @(@{ File = 'noop.ps1'; Function = 'Invoke-NoopPhase'; Title = 'No-op' }) }
'@
        Set-Content -LiteralPath (Join-Path $copy 'steps\noop.ps1') -Value 'function Invoke-NoopPhase { }'
        # _workload.ps1 loads last, so these replace the real commands that follow the check. If the check regresses,
        # the child stops here instead of elevating, installing PowerShell 7, or starting setup.
        Add-Content -LiteralPath (Join-Path $copy 'steps\_workload.ps1') -Value @'
function Enable-DevConfigModernTls { Write-Host 'GATE-TEST: went past the resume check'; exit 99 }
function Invoke-DevConfigElevate { Write-Host 'GATE-TEST: went past the resume check'; exit 99 }
function Invoke-DevConfigEnsurePwsh { Write-Host 'GATE-TEST: went past the resume check'; exit 99 }
'@
        $marker = Join-Path $copy 'gatetest-restart.json'
        $shell = (Get-Process -Id $PID).Path
        foreach ($case in @(
                @{ Name = 'pending'; Content = "{`"RequestedAtUtcTicks`":$([DateTime]::UtcNow.Ticks),`"Waiting`":[`"WslComponents`"]}"; Exit = 3010; Text = "*hasn't restarted yet*" }
                @{ Name = 'unreadable'; Content = 'not json'; Exit = 1; Text = '*could not confirm*could not be read*' }
                @{ Name = 'missing'; Content = $null; Exit = 1; Text = '*could not confirm*no restart request was saved*' }
                # Not a resume: contradictory switches stop the run before anything else, and the error pauses to stay readable.
                @{ Name = 'contradictory switches'; Content = $null; Exit = 1; Text = '*-NoRestart and -RestartWhenNeeded contradict*'; Switches = '-NoRestart -RestartWhenNeeded'; Pauses = $true })) {
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            if ($null -ne $case.Content) { [IO.File]::WriteAllText($marker, $case.Content) }
            $switches = if ($case['Switches']) { $case['Switches'] } else { '-Resumed' }
            $start = [Diagnostics.ProcessStartInfo]::new($shell)
            $start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$copy\dev-config.ps1`" -Workload gatetest -Action Full $switches -AllowUnsigned -NoElevate"
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $output = $process.StandardOutput.ReadToEndAsync()
                $exited = $process.WaitForExit(60000)
                if (-not $exited) { $process.Kill() }
                Assert $exited "The $($case.Name) case did not exit by itself within 60 seconds."
                Assert ($process.ExitCode -eq $case.Exit) "The $($case.Name) case exited with $($process.ExitCode), not $($case.Exit). Output: $($output.Result)"
                Assert ($output.Result -like $case.Text) "Unexpected message for the $($case.Name) case: $($output.Result)"
                # Without console input a pause returns at once, so its prompt is the reliable sign of one.
                if (-not $case['Pauses']) {
                    Assert ($output.Result -notlike '*Press any key*') "The $($case.Name) case paused: $($output.Result)"
                }
            } finally {
                $process.Dispose()
            }
            Assert (-not (Test-Path -LiteralPath (Join-Path $copy 'gatetest-log.txt'))) "The $($case.Name) case got as far as starting setup."
            if ($null -ne $case.Content) {
                Assert ([IO.File]::ReadAllText($marker) -eq $case.Content) "The $($case.Name) case changed the saved request."
            }
        }
    } finally {
        Remove-Item -LiteralPath $copy -Recurse -Force
    }
}

$bootstrapFunction = $bootstrapAst.Find({
    param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CalmOsBootstrap'
}, $true)

Check 'bootstrap.ps1 declares -RestartWhenNeeded and -NoRestart and rejects bad combinations before downloading' {
    foreach ($name in @('RestartWhenNeeded', 'NoRestart')) {
        $parameter = @($bootstrapAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name })
        Assert ($parameter.Count -eq 1 -and $parameter[0].StaticType -eq [switch]) "bootstrap.ps1 must declare [switch] `$$name."
    }
    . ([scriptblock]::Create($bootstrapFunction.Extent.Text))
    foreach ($flags in @(@{ RestartWhenNeeded = $true }, @{ NoRestart = $true })) {
        $failure = Expect-Failure { Invoke-CalmOsBootstrap -Ref '..' -Scenario cuda @flags }
        Assert ($failure.Exception.Message -like '*cannot be combined with -Scenario*') "Unexpected error: $($failure.Exception.Message)"
    }
    $failure = Expect-Failure { Invoke-CalmOsBootstrap -Ref '..' -NoRestart -RestartWhenNeeded }
    Assert ($failure.Exception.Message -like '*-NoRestart and -RestartWhenNeeded contradict*') "Unexpected error: $($failure.Exception.Message)"
}

Check 'DEVCONFIG_RESTART_WHEN_NEEDED opts short links in, but never AI scenarios or -NoRestart' {
    $optIn = $bootstrapFunction.Body.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -like '*DEVCONFIG_RESTART_WHEN_NEEDED*' }, $true)
    Assert ($null -ne $optIn) 'The variable opt-in was not found.'
    $apply = [scriptblock]::Create('param($Scenario, $Value, [switch] $NoRestart) $RestartWhenNeeded = [switch]$false; $env:DEVCONFIG_RESTART_WHEN_NEEDED = $Value' +
        [Environment]::NewLine + $optIn.Extent.Text + [Environment]::NewLine + '[bool]$RestartWhenNeeded')
    $saved = $env:DEVCONFIG_RESTART_WHEN_NEEDED
    try {
        Assert (& $apply '' '1') '1 must opt in.'
        Assert (& $apply '' 'TRUE') 'true must opt in.'
        Assert (-not (& $apply '' '0')) '0 must not opt in.'
        Assert (-not (& $apply '' $null)) 'An unset variable must not opt in.'
        Assert (-not (& $apply 'cuda' '1')) 'AI scenarios must ignore the variable.'
        Assert (-not (& $apply '' '1' -NoRestart)) 'An explicit -NoRestart must win over the variable.'
    } finally {
        $env:DEVCONFIG_RESTART_WHEN_NEEDED = $saved
    }
}

Check 'bootstrap.ps1 forwards -RestartWhenNeeded and -NoRestart and passes 3010 back instead of failing' {
    $elevation = $bootstrapAst.Find({
        param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CalmOsElevationCommand'
    }, $true)
    function Invoke-DevConfigWebRequest { }
    . ([scriptblock]::Create($elevation.Extent.Text))
    $optIn = Get-CalmOsElevationCommand -Ref ('a' * 40) -InstallRoot 'C:\ProgramData\CalmOS' -Action Full -RestartWhenNeeded
    Assert ($optIn -like "*-Action 'Full' -RestartWhenNeeded*") 'The elevated command must carry -RestartWhenNeeded.'
    $never = Get-CalmOsElevationCommand -Ref ('a' * 40) -InstallRoot 'C:\ProgramData\CalmOS' -Action Full -NoRestart
    Assert ($never -like "*-Action 'Full' -NoRestart*") 'The elevated command must carry -NoRestart.'
    $plain = Get-CalmOsElevationCommand -Ref ('a' * 40) -InstallRoot 'C:\ProgramData\CalmOS' -Action Full
    # The command embeds the launcher's source, which names both switches, so only its invocation counts.
    $invocation = $plain.Substring($plain.LastIndexOf("} -Ref '"))
    Assert ($invocation -notlike "*-RestartWhenNeeded*" -and $invocation -notlike "*-NoRestart*") "Neither switch must leave the elevated command unchanged: $invocation"
    Assert ($elevation.Extent.Text -like '*if ($LASTEXITCODE -eq 3010 -and -not $Scenario) {*exit 3010*') 'The elevated launcher must pass 3010 back.'
    Assert ($elevation.Extent.Text -like "*if (`$NoRestart) { `$arguments += '-NoRestart' }*") 'The elevated launcher must pass -NoRestart to its bootstrap.'
    Assert ($bootstrapFunction.Extent.Text -like "*if (`$RestartWhenNeeded) { `$arguments += '-RestartWhenNeeded' }*if (`$NoRestart) { `$arguments += '-NoRestart' }*if (`$AllowUnsigned)*") 'Bootstrap must pass -RestartWhenNeeded and -NoRestart to dev-config.ps1.'
    $fileExit = $bootstrapAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] }
    Assert (@($fileExit | Where-Object { $_.Clauses[0].Item1.Extent.Text -like '${function:Invoke-CalmOsBootstrap}.File*3010*' }).Count -eq 1) 'Only a .ps1 file run may exit with 3010.'
}

Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
