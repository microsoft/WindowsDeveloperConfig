<#
.SYNOPSIS
  Selects the PowerShell host for setup or cleanup.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigHasPwsh {
    [bool](Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue)
}

# PATH is checked directly because WinGet read cmdlets are not used during bootstrap.
function Install-DevConfigPwshBootstrap {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            # The timeout keeps early bootstrap visible if winget waits without producing output.
            Invoke-DevConfigProcess -FilePath 'winget.exe' -NoNewWindow -TimeoutSeconds 600 -Arguments @(
                'install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            ) | Out-Null
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
        [switch] $Resumed,
        [switch] $AllowUnsigned,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
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
        Write-Host 'Could not install PowerShell 7 -- carrying on with Windows PowerShell.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Switching this setup over to PowerShell 7...' -ForegroundColor DarkCyan
    $relaunchArgs = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action
    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList $relaunchArgs -Wait -NoNewWindow -PassThru

    # The relaunch performs the setup work, so this Windows PowerShell process exits with its code.
    exit $proc.ExitCode
}

function Invoke-DevConfigEnsureCleanupShell {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $AllowUnsigned
    )
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return
    }

    # Cleanup needs the Appx cmdlets and removes PowerShell 7 itself.
    Write-Host 'Switching cleanup to Windows PowerShell...' -ForegroundColor DarkCyan
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -AllowUnsigned:$AllowUnsigned -Action Uninstall
    $proc = Start-Process -FilePath $shell -ArgumentList $arguments -Wait -PassThru
    exit $proc.ExitCode
}
