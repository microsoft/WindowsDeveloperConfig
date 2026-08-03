<#
.SYNOPSIS
  Makes sure PowerShell 7 is installed and in use before any real work starts -- the WinGet
  module the rest of this script relies on is documented as unreliable on Windows PowerShell.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigHasPwsh {
    [bool](Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue)
}

# Verified via Get-Command (PATH) afterward, not a WinGet read cmdlet -- that's the part that's unreliable here.
function Install-DevConfigPwshBootstrap {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            winget install --id Microsoft.PowerShell --source winget --silent `
                --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        } catch {
            Write-Verbose "winget install Microsoft.PowerShell attempt ${attempt}: $($_.Exception.Message)"
        }
        Update-DevConfigSessionPath
        if (Test-DevConfigHasPwsh) {
            return
        }
        Start-Sleep -Seconds 5
    }
}

function Invoke-DevConfigEnsurePwsh {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $Resumed
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return
    }

    if (-not (Test-DevConfigHasPwsh)) {
        Write-Host ''
        Write-Host 'Installing PowerShell 7 first -- WinGet is more reliable on it than on Windows PowerShell.' -ForegroundColor Yellow
        Write-Host '(One-time. Takes about a minute.)' -ForegroundColor DarkGray
        Install-DevConfigPwshBootstrap
    }

    if (-not (Test-DevConfigHasPwsh)) {
        Write-Warning 'Could not install PowerShell 7 -- continuing on Windows PowerShell.'
        return
    }

    Write-Host 'Switching this setup over to PowerShell 7...' -ForegroundColor DarkCyan
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-NoElevate')
    if ($Resumed) { $relaunchArgs += '-Resumed' }
    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList $relaunchArgs -Wait -NoNewWindow -PassThru

    # The relaunch already did the work; nothing left for this (Windows PowerShell) process to do.
    exit $proc.ExitCode
}
