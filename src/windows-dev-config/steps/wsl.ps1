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
        # Match Ubuntu specifically, including versioned registrations such as Ubuntu-24.04. Counting
        # any distro at all let an unrelated one (docker-desktop, Debian) satisfy this step, so a
        # machine that uses Docker would silently never get Ubuntu.
        return @($distros | Where-Object { $_ -like 'Ubuntu*' }).Count -gt 0
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

$Script:DevConfigWslInactiveMessage = @'
WSL's platform components are installed but still inactive after a restart, so restarting
again would not help. This machine most likely has virtualization turned off: enable it in
the BIOS/UEFI, or turn on nested virtualization if this is a virtual machine, then run this
script again.
'@

function Install-DevConfigWslPlatform {
    param(
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )

    Install-DevConfigWslComponents
    if (Test-DevConfigVmComputePresent) {
        return
    }

    # One restart activates the components. If they are still inactive after it, another restart
    # would only repeat the same result, so stop with an explanation instead of rebooting in a loop.
    if ($Script:DevConfigResumed) {
        throw $Script:DevConfigWslInactiveMessage
    }

    # Never returns: registers the resume task, reboots, and exits this process.
    Suspend-DevConfigForReboot -ScriptPath $OrchestratorPath
}

function Invoke-WslPhase {
    param(
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )

    # ArgumentList binds the orchestrator path at call time instead of relying on closure capture.
    $steps = @(
        New-DevConfigStep -Name 'WslComponents' -Description 'Install WSL platform components' `
            -Check { Test-DevConfigVmComputePresent } `
            -Apply { param($OrchestratorPath) Install-DevConfigWslPlatform -OrchestratorPath $OrchestratorPath } `
            -ArgumentList @($OrchestratorPath)
        New-DevConfigStep -Name 'WslUbuntu' -Description 'Install the default Ubuntu distro' `
            -Check { Test-DevConfigUbuntuInstalled } `
            -Apply { Install-DevConfigUbuntu }
    )

    Invoke-DevConfigSteps -Steps $steps
}
