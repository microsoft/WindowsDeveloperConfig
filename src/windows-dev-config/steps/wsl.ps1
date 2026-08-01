<#
.SYNOPSIS
  Installs WSL platform components, reboots once if needed, then installs Ubuntu.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigVmComputePresent {
    # vmcompute (Hyper-V Host Compute Service) only registers once Virtual Machine Platform is active.
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='vmcompute'"
    return [bool]$svc
}

function Install-DevConfigWslComponents {
    Invoke-DevConfigRetry -Name 'wsl --install --no-distribution' -ScriptBlock {
        Write-Host 'Installing WSL platform components (wsl --install --no-distribution)...'
        Write-Host '(A separate WSL window may pop up briefly -- that is normal. This can take a few minutes.)' -ForegroundColor DarkGray
        # No -NoNewWindow / -Redirect*: wsl's install bootstrap needs a real console to run against.
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Wait -PassThru
        if ($p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641) {
            Write-Host 'WSL components installed; a reboot is required to activate them.'
        } elseif ($p.ExitCode -ne 0) {
            throw "wsl --install --no-distribution failed with exit code $($p.ExitCode)"
        }
    }
}

function Test-DevConfigUbuntuInstalled {
    $env:WSL_UTF8 = '1'
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        # Redirect wsl's output here: this is a query, not a bootstrap step, so no console is needed.
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList '--list', '--quiet' `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        if ($p.ExitCode -ne 0) {
            return $false
        }
        $distros = @(Get-Content -LiteralPath $out -Encoding UTF8 |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ })
        return $distros.Count -gt 0
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Install-DevConfigUbuntu {
    # Suppresses the "Welcome to WSL" first-run GUI.
    $lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    New-Item -Path $lxssPath -Force | Out-Null
    Set-ItemProperty -Path $lxssPath -Name 'OOBEComplete' -Value 1 -Type DWord -Force

    Invoke-DevConfigRetry -Name 'wsl --install -d Ubuntu' -ScriptBlock {
        Write-Host 'Downloading and installing Ubuntu (wsl --install -d Ubuntu --no-launch)...'
        Write-Host '(A separate WSL window may pop up briefly -- that is normal. This can take a few minutes.)' -ForegroundColor DarkGray
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '-d', 'Ubuntu', '--no-launch' -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            throw "wsl --install -d Ubuntu --no-launch failed with exit code $($p.ExitCode)"
        }
    }
}

function Invoke-WslPhase {
    param(
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )

    $steps = @(
        New-DevConfigStep -Name 'WslComponents' -Description 'Install WSL platform components' `
            -Check { Test-DevConfigVmComputePresent } `
            -Apply {
                Install-DevConfigWslComponents
                if (-not (Test-DevConfigVmComputePresent)) {
                    # Never returns: registers the resume task, reboots, and exits this process.
                    Suspend-DevConfigForReboot -ScriptPath $OrchestratorPath
                }
            }
        New-DevConfigStep -Name 'WslUbuntu' -Description 'Install the default Ubuntu distro' `
            -Check { Test-DevConfigUbuntuInstalled } `
            -Apply { Install-DevConfigUbuntu }
    )

    Invoke-DevConfigSteps -Steps $steps
}
