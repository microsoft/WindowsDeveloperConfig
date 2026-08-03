<#
.SYNOPSIS
  Getting a run started safely: the admin check, the one-time elevation relaunch so the whole flow
  needs only a single UAC prompt, and the guard that stops two copies running over each other.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigRunMutex = $null

# Two copies at once (an impatient double-click, or a manual start while the post-reboot resume is
# already going) collide inside WinGet and the registry, and the errors that come back explain
# nothing. Machine-wide scope, because the changes themselves are machine-wide.
# Held until the process exits: Windows releases a mutex automatically when its owner dies, so a
# crashed run can never leave the next one locked out.
function Enter-DevConfigSingleInstance {
    $mutex = [System.Threading.Mutex]::new($false, 'Global\WindowsDevConfigSetup')
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # The previous owner exited without releasing it, which means ownership passed to us.
        $acquired = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        return $false
    }

    $Script:DevConfigRunMutex = $mutex
    return $true
}

# The lock is only there to stop two runs doing work at the same time. Once the summary is printed
# the run is over and the window is merely waiting to be dismissed, so holding the lock through that
# pause would tell the next run "already running in another window" for up to fifteen minutes after
# this one finished -- with no log written, because the guard sits before logging starts.
function Exit-DevConfigSingleInstance {
    if (-not $Script:DevConfigRunMutex) {
        return
    }
    try {
        $Script:DevConfigRunMutex.ReleaseMutex()
    } catch {
        Write-Verbose "The run lock was already released: $($_.Exception.Message)"
    }
    $Script:DevConfigRunMutex.Dispose()
    $Script:DevConfigRunMutex = $null
}

function Test-DevConfigIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DevConfigShellExe {
    # Prefer pwsh if it's already on PATH; Windows PowerShell 5.1 is always present as a fallback.
    if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
}

# Start-Process joins -ArgumentList with spaces and quotes nothing itself, so an unquoted script path
# under C:\Users\First Last\Desktop is read as two arguments and the relaunch dies before it starts.
# Every relaunch (elevation, the PowerShell 7 switchover, the post-reboot resume) goes through here.
function Get-DevConfigRelaunchArguments {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $Resumed
    )
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"", '-NoElevate')
    if ($Resumed) {
        $arguments += '-Resumed'
    }
    return $arguments
}

function Invoke-DevConfigElevate {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $NoElevate,
        [switch] $Resumed
    )

    if (Test-DevConfigIsAdmin) {
        return
    }

    if ($NoElevate) {
        throw 'Not running as Administrator and -NoElevate was passed; re-launch from an elevated shell.'
    }

    Write-Host 'This needs to run elevated once (a UAC prompt will appear)...' -ForegroundColor Yellow

    $shell = Get-DevConfigShellExe
    # Carrying -Resumed across matters: without it the relaunched run believes it is a first run and
    # asks for the WSL reboot all over again, which is a reboot loop rather than a finished setup.
    $relaunchArgs = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed:$Resumed
    try {
        $proc = Start-Process -FilePath $shell -ArgumentList $relaunchArgs -Verb RunAs -Wait -PassThru
    } catch {
        # Declining the UAC prompt lands here; it's a choice, not a crash, so say so plainly. The
        # pause matters as much as the words: launched from Explorer this is the only window there
        # is, and exiting straight away would take the explanation off screen with it.
        Write-Host ''
        Write-Host 'Setup needs Administrator rights to continue, so nothing was changed.' -ForegroundColor Yellow
        Write-Host 'Run it again and accept the prompt, or start it from an elevated terminal.' -ForegroundColor Yellow
        Wait-DevConfigKeyPress
        exit 1
    }

    # The elevated relaunch did the work, so this process reports whatever that one concluded.
    exit $proc.ExitCode
}
