[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $PayloadRoot,
    [string] $OriginalUserSid,
    [string] $OriginalUserName,
    [switch] $AllowUnsigned,
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'resume.ps1')
. (Join-Path $PSScriptRoot 'platform.ps1')
. (Join-Path $PSScriptRoot 'configure.ps1')
. (Join-Path $PSScriptRoot 'verify.ps1')

$phases = @(
    'Preflight',
    'RepairPlatform',
    'ClearRequiredPendingReboot',
    'EnableWslPlatform',
    'InstallWslDistro',
    'ApplyDesiredState',
    'Verify'
)

function New-SlipstreamState {
    if ([string]::IsNullOrWhiteSpace($OriginalUserSid) -or
        [string]::IsNullOrWhiteSpace($OriginalUserName)) {
        throw 'Original user identity is required when creating a Slipstream run.'
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        productVersion = $script:SlipstreamPayloadVersion
        runId = $RunId
        payloadRoot = $PayloadRoot
        originalUserSid = $OriginalUserSid
        originalUserName = $OriginalUserName
        status = 'Running'
        phaseIndex = 0
        phase = $phases[0]
        completedPhases = @()
        rebootCount = 0
        rebootBootId = $null
        rebootReason = $null
        rebootHistory = @()
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        lastError = $null
    }
}

function Move-SlipstreamToNextPhase {
    param([Parameter(Mandatory)] [object] $State)

    $State.completedPhases = @($State.completedPhases) + $State.phase
    $State.phaseIndex = [int]$State.phaseIndex + 1
    if ([int]$State.phaseIndex -lt $phases.Count) {
        $State.phase = $phases[$State.phaseIndex]
    }
    else {
        $State.phase = 'Complete'
    }
    Save-SlipstreamState -State $State
}

function Invoke-SlipstreamPhase {
    param([Parameter(Mandatory)] [object] $State)

    Write-SlipstreamLog -RunId $State.runId -Message "Starting phase: $($State.phase)"
    $result = switch ($State.phase) {
        'Preflight' {
            Invoke-SlipstreamPreflight -State $State -AllowUnsigned:$AllowUnsigned
        }
        'RepairPlatform' {
            Invoke-SlipstreamPlatformRepair -State $State
        }
        'ClearRequiredPendingReboot' {
            Invoke-SlipstreamPendingRebootGate -State $State
        }
        'EnableWslPlatform' {
            Invoke-SlipstreamWslPlatform -State $State
        }
        'InstallWslDistro' {
            Invoke-SlipstreamWslDistro -State $State
        }
        'ApplyDesiredState' {
            Invoke-SlipstreamDesiredState `
                -State $State `
                -AllowUnsigned:$AllowUnsigned
        }
        'Verify' {
            Invoke-SlipstreamVerification `
                -State $State `
                -AllowUnsigned:$AllowUnsigned
        }
        default {
            throw "Unknown Slipstream phase: $($State.phase)"
        }
    }

    if (-not $result) {
        throw "Phase $($State.phase) returned no result."
    }
    return $result
}

$mutex = [System.Threading.Mutex]::new(
    $false,
    'Global\Microsoft.WindowsDeveloperConfig.Slipstream'
)
$ownsMutex = $false
$state = $null

try {
    try {
        $ownsMutex = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        throw 'Another Windows Developer Config run is already active.'
    }

    $statePath = Get-SlipstreamStatePath -RunId $RunId
    if (Test-Path -LiteralPath $statePath) {
        $state = Read-SlipstreamState -RunId $RunId
        if ($state.payloadRoot -ne $PayloadRoot) {
            throw "Payload path mismatch. State pins '$($state.payloadRoot)', caller supplied '$PayloadRoot'."
        }
    }
    else {
        $state = New-SlipstreamState
        Save-SlipstreamState -State $state
    }

    if ($state.status -eq 'Complete') {
        Write-SlipstreamLog -RunId $RunId -Message 'This Slipstream run is already complete.'
        return 0
    }

    if ($state.status -eq 'WaitingForReboot') {
        $currentBootId = Get-SlipstreamBootId
        if ($currentBootId -eq $state.rebootBootId) {
            Write-SlipstreamLog `
                -RunId $RunId `
                -Level WARN `
                -Message "A restart is still required: $($state.rebootReason)"
            if (-not $NoRestart) {
                $restart = Invoke-SlipstreamNative `
                    -RunId $RunId `
                    -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') `
                    -ArgumentList @('/r', '/t', '15', '/d', 'p:4:1', '/c', 'Windows Developer Config will resume after sign-in.') `
                    -Name 'Reschedule Windows restart' `
                    -AllowAnyExitCode
                if ($restart.ExitCode -ne 0) {
                    throw "Unable to reschedule restart: $($restart.ExitCodeHex)"
                }
            }
            return 3010
        }

        $state.status = 'Running'
        $state.rebootBootId = $null
        $state.rebootReason = $null
        Save-SlipstreamState -State $state
        Write-SlipstreamLog -RunId $RunId -Message 'Restart confirmed; resuming setup.'
    }

    Register-SlipstreamResumeTask `
        -State $state `
        -AllowUnsigned:$AllowUnsigned `
        -NoRestart:$NoRestart

    while ([int]$state.phaseIndex -lt $phases.Count) {
        $result = Invoke-SlipstreamPhase -State $state
        if ($result.RebootRequired) {
            if ($result.AdvancePhase) {
                Move-SlipstreamToNextPhase -State $state
            }
            else {
                Save-SlipstreamState -State $state
            }

            Request-SlipstreamRestart `
                -State $state `
                -Reason $result.Reason `
                -NoRestart:$NoRestart
            return 3010
        }

        Write-SlipstreamLog -RunId $RunId -Message "Completed phase: $($state.phase)"
        Move-SlipstreamToNextPhase -State $state
    }

    $state.status = 'Complete'
    $state.lastError = $null
    Save-SlipstreamState -State $state
    Unregister-SlipstreamResumeTask -RunId $RunId
    Write-SlipstreamLog -RunId $RunId -Message 'Windows Developer Config completed successfully.'
    Write-Host ''
    Write-Host 'Windows Developer Config is complete.' -ForegroundColor Green
    Write-Host "Log: $(Get-SlipstreamLogPath -RunId $RunId)" -ForegroundColor DarkGray
    return 0
}
catch {
    if ($ownsMutex -and $state) {
        $state.status = 'Failed'
        $state.lastError = [pscustomobject]@{
            phase = $state.phase
            message = $_.Exception.Message
            atUtc = [DateTime]::UtcNow.ToString('o')
        }
        Save-SlipstreamState -State $state
        Write-SlipstreamLog `
            -RunId $RunId `
            -Level ERROR `
            -Message "Setup failed in phase $($state.phase): $($_.Exception.Message)"
        Unregister-SlipstreamResumeTask -RunId $RunId
    }
    elseif ($ownsMutex) {
        Unregister-SlipstreamResumeTask -RunId $RunId
    }
    throw
}
finally {
    if ($ownsMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
