<#
.SYNOPSIS
  Installs WSL platform components, reboots once if needed, then installs Ubuntu.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows sets this key while a component change waits on a restart, and clears it once the restart
# happens. It is the signal that matters straight after wsl --install: wsl.exe answers --version and
# --status perfectly well at that point, while the platform underneath it is not live yet -- which is
# how an Ubuntu install could report success and put nothing on the machine at all. Component
# servicing only, deliberately: PendingFileRenameOperations is set by ordinary app installers too
# (the fifteen packages in phase 1 among them) and would force a restart on almost every run.
function Test-DevConfigServicingRebootPending {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

# Runs a short wsl query with its output redirected and the wait bounded, and hands back the exit
# code -- or $null when wsl.exe cannot be launched at all, which is what the App Execution Alias stub
# does on a machine that has never had WSL. Exit codes only, deliberately: wsl's text is localised.
function Get-DevConfigWslExitCode {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $TimeoutSeconds = 120
    )
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $null
    }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        return Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds `
            -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    } catch {
        Write-Verbose "wsl $($Arguments -join ' ') could not run: $($_.Exception.Message)"
        return $null
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

# Windows ships an old WSL inside the image, and the modern WSL that can actually install and host a
# distro comes separately. Only the modern one understands --version; the inbox one answers -1. That
# single exit code is the difference that matters, and nothing else reports it honestly: on a 22H2
# machine with the inbox WSL and no kernel at all, "wsl --status" still exits 0 and cheerfully says
# the default version is 2 -- after which every distro install fails with exit -1.
function Test-DevConfigWslPlatformActive {
    return ((Get-DevConfigWslExitCode -Arguments @('--version')) -eq 0)
}

# wsl --update fetches the modern WSL and its kernel. The Store route is tried first because it is
# the one Microsoft keeps current; --web-download is the same package without the Store, for machines
# where policy has removed it. Nothing here is fatal on its own: the caller decides what happens next.
function Update-DevConfigWslRuntime {
    Write-Host '  This machine has the older WSL that ships inside Windows; a distro needs the current one.' -ForegroundColor DarkGray
    Write-Host '  Updating WSL (wsl --update)...' -ForegroundColor DarkCyan

    foreach ($arguments in @(@('--update'), @('--update', '--web-download'))) {
        $exitCode = Get-DevConfigWslExitCode -Arguments $arguments -TimeoutSeconds 900
        if ($exitCode -eq 0 -and (Test-DevConfigWslPlatformActive)) {
            return $true
        }
        Write-Verbose "wsl $($arguments -join ' ') returned $exitCode"
    }

    Write-Host '  WSL could not be updated here.' -ForegroundColor Yellow
    return $false
}


function Install-DevConfigWslComponents {
    try {
        Invoke-DevConfigRetry -Name 'wsl --install --no-distribution' -MaxAttempts 2 -ScriptBlock {
            Write-Host 'Installing WSL platform components (wsl --install --no-distribution)...'
            Write-Host '(A separate WSL window may pop up briefly -- that is normal. This can take a few minutes.)' -ForegroundColor DarkGray
            # No -NoNewWindow: wsl's install bootstrap needs a real console to run against.
            $exitCode = Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments @('--install', '--no-distribution') -TimeoutSeconds 900
            if ($exitCode -eq 3010 -or $exitCode -eq 1641) {
                Write-Host 'WSL components installed; a reboot is required to activate them.'
                $Script:DevConfigWslRestartSignalled = $true
            } elseif ($exitCode -ne 0) {
                throw "wsl --install --no-distribution failed with exit code $exitCode"
            }
        }
    } catch {
        # Older builds, machines where the Microsoft Store is blocked by policy, and machines where
        # wsl's own bootstrap simply never returns. The underlying Windows features still get us a
        # working WSL, so that path is worth taking rather than failing the phase.
        Write-Host "  WSL's own installer could not run here ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host '  Turning on the WSL Windows features directly instead.' -ForegroundColor Yellow
        Enable-DevConfigWslFeatures
    }

    # Turning the Windows features on is only half the job. A 22H2 machine that took the dism path is
    # left with both features enabled, the inbox WSL, and no WSL2 kernel at all -- a state in which
    # every distro install fails with exit -1. Fetching the current WSL is what closes that gap, and
    # it is a quick no-op on any machine that already has it.
    if (-not (Test-DevConfigWslPlatformActive)) {
        Update-DevConfigWslRuntime | Out-Null
    }
}

# dism.exe rather than Enable-WindowsOptionalFeature: its exit codes are stable and locale-independent,
# and it avoids pulling the DISM module through PowerShell 7's Windows PowerShell compatibility layer.
# Re-enabling an already-enabled feature is a fast no-op, so no state query is needed first.
function Enable-DevConfigWslFeatures {
    foreach ($feature in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
        Write-Host "  Turning on the $feature Windows feature..." -ForegroundColor DarkCyan
        $exitCode = Invoke-DevConfigProcess -FilePath 'dism.exe' -NoNewWindow -TimeoutSeconds 1200 -Arguments @(
            '/online', '/enable-feature', "/featurename:$feature", '/all', '/norestart', '/quiet'
        )
        # 3010 is "enabled, restart required", which is the expected outcome here.
        if ($exitCode -eq 3010) {
            $Script:DevConfigWslRestartSignalled = $true
        } elseif ($exitCode -ne 0) {
            throw "Could not turn on the $feature Windows feature (dism exit code $exitCode)."
        }
    }
}

function Test-DevConfigUbuntuInstalled {
    # Windows 10 builds without the WSL feature have no wsl.exe at all; that is a clean "not installed",
    # not an error worth surfacing.
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    $env:WSL_UTF8 = '1'
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        # Redirect wsl's output here: this is a query, not a bootstrap step, so no console is needed.
        # A wedged LxssManager can make even this listing hang, and a check that never returns would
        # strand the run before the phase has printed anything, so treat "no answer" as "not there".
        $exitCode = Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments @('--list', '--quiet') `
            -NoNewWindow -TimeoutSeconds 120 -RedirectStandardOutput $out -RedirectStandardError $err
        if ($exitCode -ne 0) {
            return $false
        }
        $distros = @(Get-Content -LiteralPath $out -Encoding UTF8 |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ })
        # Match Ubuntu specifically, including versioned registrations such as Ubuntu-24.04. Counting
        # any distro at all let an unrelated one (docker-desktop, Debian) satisfy this step, so a
        # machine that uses Docker would silently never get Ubuntu.
        return @($distros | Where-Object { $_ -like 'Ubuntu*' }).Count -gt 0
    } catch {
        Write-Verbose "Could not list WSL distros: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

# A distro installed with --no-launch is not always listed by wsl --list the instant the install
# exits. Observed on both 22621 and 26663, so give the listing a moment to catch up before deciding
# the install did nothing -- the same shape as the WinGet catalog lag.
function Wait-DevConfigUbuntuVisible {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (Test-DevConfigUbuntuInstalled) {
            return $true
        }
        if ($attempt -eq 1) {
            Write-Host '  (Waiting for WSL to list the new distro...)' -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

# Runs one install route and reports whether Ubuntu actually arrived. Both halves matter: wsl can
# fail loudly (non-zero exit) and it can also exit 0 having installed nothing at all, and only the
# listing afterwards tells those apart from a real success.
function Install-DevConfigUbuntuVia {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $MaxAttempts = 3
    )
    try {
        Invoke-DevConfigWslUbuntuInstall -Arguments $Arguments -MaxAttempts $MaxAttempts
    } catch {
        Write-Host "  That route did not work ($($_.Exception.Message))." -ForegroundColor Yellow
        return $false
    }
    return (Wait-DevConfigUbuntuVisible)
}

function Install-DevConfigUbuntu {
    # Without the platform components there is nothing for a distro to run on, and every install
    # attempt would fail slowly. Say so once instead.
    if (-not (Test-DevConfigWslPlatformActive)) {
        throw "WSL isn't active on this machine, so Ubuntu can't be installed yet (see the note above)."
    }

    # Suppresses the "Welcome to WSL" first-run GUI.
    $lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    New-Item -Path $lxssPath -Force | Out-Null
    Set-ItemProperty -Path $lxssPath -Name 'OOBEComplete' -Value 1 -Type DWord -Force

    if (Install-DevConfigUbuntuVia -Arguments @('--install', '-d', 'Ubuntu', '--no-launch') -MaxAttempts 2) {
        return
    }

    # Reached both when the Store is unreachable and when it accepted the request and quietly did
    # nothing; the web download does not depend on the Store either way.
    Write-Host '  The Store copy of Ubuntu did not take. Downloading Ubuntu from the web instead.' -ForegroundColor Yellow
    if (Install-DevConfigUbuntuVia -Arguments @('--install', '-d', 'Ubuntu', '--no-launch', '--web-download')) {
        return
    }

    Set-DevConfigStepUnverified -Reason "Ubuntu did not finish installing. Everything else is set up -- run this again, or install Ubuntu from the Start menu."
}

function Invoke-DevConfigWslUbuntuInstall {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $MaxAttempts = 3
    )
    Invoke-DevConfigRetry -Name "wsl $($Arguments -join ' ')" -MaxAttempts $MaxAttempts -ScriptBlock {
        Write-Host "Downloading and installing Ubuntu (wsl $($Arguments -join ' '))..."
        Write-Host '(A separate WSL window may pop up briefly -- that is normal. This can take a few minutes.)' -ForegroundColor DarkGray
        $exitCode = Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments $Arguments -TimeoutSeconds 1200
        if ($exitCode -ne 0) {
            throw "wsl $($Arguments -join ' ') failed with exit code $exitCode"
        }
    }
}

$Script:DevConfigWslInactiveMessage = @'
WSL's platform components are installed but still not usable after a restart, so restarting
again would not help. The usual cause is virtualization being turned off: enable it in the
BIOS/UEFI, or turn on nested virtualization if this is a virtual machine. If virtualization is
already on, this machine could not reach the WSL download. Either way, run this script again
once that is sorted.
'@

function Install-DevConfigWslPlatform {
    param(
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )

    $Script:DevConfigWslRestartSignalled = $false
    Install-DevConfigWslComponents

    # Skip the restart only when nothing was actually staged. Asking WSL again is not enough on its
    # own: a component change Windows is holding until reboot leaves wsl.exe answering --status
    # normally while the platform beneath it is dead, and Ubuntu then "installs" into nothing.
    if (-not $Script:DevConfigWslRestartSignalled -and
        -not (Test-DevConfigServicingRebootPending) -and
        (Test-DevConfigWslPlatformActive)) {
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
    # BestEffort: a machine with virtualization switched off in firmware genuinely cannot run WSL, and
    # that is no reason to throw away the nine phases that already succeeded -- say so and finish.
    $steps = @(
        New-DevConfigStep -Name 'WslComponents' -Description 'Install WSL platform components' -BestEffort `
            -Check { Test-DevConfigWslPlatformActive } `
            -Apply { param($OrchestratorPath) Install-DevConfigWslPlatform -OrchestratorPath $OrchestratorPath } `
            -ArgumentList @($OrchestratorPath)
        New-DevConfigStep -Name 'WslUbuntu' -Description 'Install the default Ubuntu distro' -BestEffort `
            -Check { Test-DevConfigUbuntuInstalled } `
            -Apply { Install-DevConfigUbuntu }
    )

    Invoke-DevConfigSteps -Steps $steps
}
