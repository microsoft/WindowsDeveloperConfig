<#
.SYNOPSIS
  Selects the PowerShell host for setup or cleanup.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DevConfigPwshExe {
    if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) {
        $candidate = Join-Path $PSHOME 'pwsh.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    foreach ($command in @(Get-Command 'pwsh.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        # App execution aliases have no executable version; resolve their package below.
        if ($command.Version -and $command.Version.Major -ge 7 -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return $command.Source
        }
    }

    if (Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue) {
        foreach ($package in @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction Stop |
            Sort-Object { [version]$_.Version } -Descending)) {
            if (-not $package.InstallLocation -or ([version]$package.Version).Major -lt 7) { continue }
            $candidate = Join-Path $package.InstallLocation 'pwsh.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    return $null
}

function Test-DevConfigHasPwsh {
    [bool](Get-DevConfigPwshExe)
}

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
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
    )

    if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) {
        return
    }

    $pwsh = Get-DevConfigPwshExe
    if (-not $pwsh) {
        Write-Host ''
        Write-Host 'Installing PowerShell 7 first -- WinGet is more reliable on it than on Windows PowerShell.' -ForegroundColor Yellow
        Write-Host '(One-time. Takes about a minute.)' -ForegroundColor DarkGray
        Install-DevConfigPwshBootstrap
        $pwsh = Get-DevConfigPwshExe
    }

    if (-not $pwsh) {
        Write-Host 'Could not install PowerShell 7 -- carrying on with Windows PowerShell.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Switching this setup over to PowerShell 7...' -ForegroundColor DarkCyan
    $relaunchArgs = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload
    $proc = Start-Process -FilePath $pwsh -ArgumentList $relaunchArgs -Wait -NoNewWindow -PassThru

    # The relaunch performs the setup work, so this Windows PowerShell process exits with its code.
    exit $proc.ExitCode
}

function Invoke-DevConfigEnsureCleanupShell {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $AllowUnsigned,
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
    )
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return
    }

    # Cleanup needs the Appx cmdlets and removes PowerShell 7 itself.
    Write-Host 'Switching cleanup to Windows PowerShell...' -ForegroundColor DarkCyan
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -AllowUnsigned:$AllowUnsigned -Action Uninstall -Workload $Workload
    $proc = Start-Process -FilePath $shell -ArgumentList $arguments -Wait -PassThru
    exit $proc.ExitCode
}
