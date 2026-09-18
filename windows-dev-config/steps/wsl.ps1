<#
.SYNOPSIS
  Installs WSL platform components, reboots once if needed, then installs Ubuntu.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This CBS key signals component servicing pending restart; app installer restart flags are ignored.
function Test-DevConfigServicingRebootPending {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

# WSL output is redirected and bounded; exit codes are used because message text is localized.
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

# The current WSL package supports --version; the inbox WSL returns a nonzero exit code.
function Test-DevConfigWslRuntimeCurrent {
    return ((Get-DevConfigWslExitCode -Arguments @('--version')) -eq 0)
}

function Test-DevConfigWslFeaturesActive {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='vmcompute'"
    return ($null -ne $service)
}

function Test-DevConfigWslComponentsReady {
    return (Test-DevConfigWslFeaturesActive) -and (Test-DevConfigWslRuntimeCurrent)
}

# The Store update is tried first; --web-download provides the same package when Store access is unavailable.
function Update-DevConfigWslRuntime {
    Write-Host '  This machine has the older WSL that ships inside Windows; a distro needs the current one.' -ForegroundColor DarkGray
    Write-Host '  Updating WSL (wsl --update)...' -ForegroundColor DarkCyan

    foreach ($arguments in @(@('--update'), @('--update', '--web-download'))) {
        $exitCode = Get-DevConfigWslExitCode -Arguments $arguments -TimeoutSeconds 900
        if ($exitCode -eq 0 -and (Test-DevConfigWslRuntimeCurrent)) {
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
        # Direct feature enablement can still prepare WSL when wsl --install is unavailable.
        Write-Host "  WSL's own installer could not run here ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host '  Turning on the WSL Windows features directly instead.' -ForegroundColor Yellow
        Enable-DevConfigWslFeatures
    }

    # Enabling features may leave only the inbox WSL; updating ensures the current WSL package is present.
    if (-not (Test-DevConfigWslRuntimeCurrent)) {
        Update-DevConfigWslRuntime | Out-Null
    }
}

# dism.exe provides stable exit codes and avoids the Windows PowerShell compatibility layer.
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
    # Without wsl.exe, Ubuntu is treated as not installed rather than as an error.
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    $env:WSL_UTF8 = '1'
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        # This query is bounded and redirected so a nonresponsive listing is treated as not installed.
        $exitCode = Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments @('--list', '--quiet') `
            -NoNewWindow -TimeoutSeconds 120 -RedirectStandardOutput $out -RedirectStandardError $err
        if ($exitCode -ne 0) {
            return $false
        }
        $distros = @(Get-Content -LiteralPath $out -Encoding UTF8 |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ })
        # Match Ubuntu specifically, including versioned registrations such as Ubuntu-24.04.
        return @($distros | Where-Object { $_ -like 'Ubuntu*' }).Count -gt 0
    } catch {
        Write-Verbose "Could not list WSL distros: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

# A --no-launch install can complete before wsl --list shows the distro, so the listing is retried.
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

# Success requires both a zero exit code and Ubuntu appearing in wsl --list afterward.
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
    # A distro install requires active platform components, so fail early when they are not active.
    if (-not (Test-DevConfigWslComponentsReady)) {
        throw "WSL isn't active on this machine, so Ubuntu can't be installed yet (see the note above)."
    }

    # Suppresses the "Welcome to WSL" first-run GUI.
    $lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    New-Item -Path $lxssPath -Force | Out-Null
    Set-ItemProperty -Path $lxssPath -Name 'OOBEComplete' -Value 1 -Type DWord -Force

    if (Install-DevConfigUbuntuVia -Arguments @('--install', '-d', 'Ubuntu', '--no-launch') -MaxAttempts 2) {
        return
    }

    # The web-download path does not depend on Store access or Store registration timing.
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

    # Skip restart only when no servicing restart is pending and the WSL platform is active.
    if (-not $Script:DevConfigWslRestartSignalled -and
        -not (Test-DevConfigServicingRebootPending) -and
        (Test-DevConfigWslComponentsReady)) {
        return
    }

    # After one resume, stop instead of repeating restarts if the platform is still inactive.
    if ($Script:DevConfigResumed) {
        throw $Script:DevConfigWslInactiveMessage
    }

    Suspend-DevConfigForReboot -ScriptPath $OrchestratorPath
}

function Invoke-WslPhase {
    param(
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )

    # ArgumentList binds the path at call time; BestEffort preserves prior phases if WSL cannot start.
    $steps = @(
        New-DevConfigStep -Name 'WslComponents' -Description 'Install WSL platform components' -BestEffort `
            -Check { Test-DevConfigWslComponentsReady } `
            -Apply { param($OrchestratorPath) Install-DevConfigWslPlatform -OrchestratorPath $OrchestratorPath } `
            -ArgumentList @($OrchestratorPath)
        New-DevConfigStep -Name 'WslUbuntu' -Description 'Install the default Ubuntu distro' -BestEffort `
            -Check { Test-DevConfigUbuntuInstalled } `
            -Apply { Install-DevConfigUbuntu }
    )

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAEOyixwBe6Bt0A
# 78+ForrRoie+E181sJSPBIF/qxQRWqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIOMX0bUTBNJd59IIGS/WMmCXoE1y
# 6k6odoEKiPlTsihiMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAWzwQVscDIUlJ3IQUJA9xcv40N5Fk4XXauzquUWuDnC04aXWs2kkOrYp9N2L5
# /tmqT5QBfTE6PR+bj9ykSDUKAo+9TJDs/8PHZ37cNsazitDjX/40j5dK8e9ubTWy
# rfHg/HTa73COBYGx4KkPFm97OOOIFe1b/XTEXUrkvhoYELcZqYSW9vCZoZqFUohc
# 8wK+sV5GIQBAbIW7V3IwsnrBihDy9emNztsfM6B46wPRbvnMHXBQ5CbrQDVlAjp3
# pZwyhIQ08mEnk2a/oQL0peL2y7Spn1XXFyQcY3Itg8wHvlSlO3hLD0J+W5GAGt46
# iMq6KXbYW/J71u50sDX8MPaEjKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAtw+mzMiIIZxY+09E4Nt30PpM5I+84cCKoimP69vP+lAIGaolSvvosGBMy
# MDI2MDkxODE2MTEzOC45NjZaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyM1oXDTI2MTExMzE4NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNh
# RM+BzF2AYiq5dUpZpJFPRjCcipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU
# /W6fecujjILkPqn9pngtWRkfQgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY
# /Qk/jtjsHdFXVBe+tshlIkSJ3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQM
# JP7tO8/BJ7ITs4/AV3D2bv8eHk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf
# 5x1lXxAwEw5a7dpS+CKTanhtv+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1
# S9e8h1TszXFzjLLvE9EmjnNfIewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J
# 60fGOl7A1UoUyAkhpb2Bja+SwSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6
# FZlPO8iuNyk680Di8VnbSNpIdJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asN
# t/Ng6o4m2dnooWOdM3yKsJaWjyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+
# XSvI2m1yN4iibqjm5HPaAO3OJ+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C
# /+n1KFBpDGdDMw9gmu8CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5
# ZQqnF5x8S1bJQzAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg
# 5I/5S+gx67aR6RiW8ZAwtE3mz8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyv
# h3e2q/BV8rjHE3ud9PyYyq32euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZ
# sSypbXDBbQkWkNl6g82yTy3AbBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dM
# SkSZweCNDXqd9r/9W2VdRZsDJKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69
# /N5CP/Tq3YgI1ub4b9+3MJFKWhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2
# NFXJFQHef6AdRe1ERvYQeqtyrBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67
# oNwR4pEEJyAIEREvkdhjjfWcgsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D
# 59r7/qebNSyQPTfwI9++jEY0Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HE
# ovbA69qGlZ3OpUE3H1RBGDVp/FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IE
# XO2SeD1aD3IqvAOdHFKHg1vpbPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7
# zw64aO5hmJ7eQwoMfTu0Vay6r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDVjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5XZsswIhgPMjAyNjA5MTgwNzI5MTVaGA8yMDI2MDkxOTA3MjkxNVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7ldmywIBADAHAgEAAgIIjTAHAgEAAgISPzAKAgUA
# 7li4SwIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQAU09eWswWbWRonoMQ5
# SoZN4cUFoYvi/R+o7ss7qTglM2yBze7JtSgi2wYBahsaEuyzBr6Y7br94PeG9LIf
# 9ot9OgyLzEdtTu42pMwENcFQ7aNIHpOMipNkBR2wuR8O3m/vsamPR/o1Fh8yb7lu
# A1W7bDE/MAvg2ZR7ILOpNoZ3rey7H0TWGWDInRUadS9k/AIO/qEl8rWesRjynyzF
# Kc0VpNWsx/sChn5xfhk40ohiIV8jqQwV69VaUYMFj7zfiNXnj+ueI5H/tX6p0TlP
# bU0GeTNK7wiSrtGaI9bc253/DL6cfNqWyyu+JNSKrYPOfK7v5fU2swybTGnaOecR
# IgI8MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIXcfsupa8BHeoAAQAAAhcwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgeC8PACBQOm+ROaV7
# 4RNpfKcwT6YVFKc9k7QZZxDe8DwwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCDQ8lBgPl23yZ0SzUSt5phOIegHPywrkNwevxe2k+RaWzCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACF3H7LqWvAR3qAAEAAAIXMCIE
# IHD4+cu7eUPrzt6w5QhlUTUdrPaQ978NMTJCu1bgXsWaMA0GCSqGSIb3DQEBCwUA
# BIICAFFHA6ZfvVZWZln9lrrtVh5VWMx+PcbOglCVErnwwLsl6tT+CJ6EdzB7eSY9
# 3LSDuMrlMc+/mgEuh6Zux8qGyw/PKwWgab2LrPtr3xcxVz4oEXPbXmw7AY1oJyg5
# Iv6MM57Ft00UKjVJxr/qmiXNSe61sDB0DE1WuUNFHYnYv2KxI0bxQzg5dZ/KSHLv
# ahxURD8knVWTPzNOiMUR1yOcCHTka+XXvsKLjds2V6RzCKl9vq+XEWR5vz+nH3fr
# hKV0m5oPmAsxnvLY9ALq1pimxaqarRMg+PIZHtuEoD2KRoIOp1Jr/s1nlT833/7C
# olxnNK8MEXlOEzch47RSXTQRD0nf8JHgKbAmnNTzNtHREnwpi8ArnoNGfsHCHHHv
# cPC8/MNPvZrRHfWzmt75d/DGKfjUFwjr9eiaU6q3c2M4+F0wXzyHWkVCSKgWI/+3
# MK++NiTl48ng6zsboJC+OsER0/QNYS2aG+AHCUBkO4s165zka8+QA97OGeMnhgrj
# NjJGPYOknHifqwB66genaXKYVaOOECCWZpM3xWdb7pOW/BWI1wsm2awUPNUIjavy
# pt43DH26PPKTv/+Z6Lc+Ddn03RwxVTeLZ8vHAFjEDJfDpBAuIMGEAHZualHY/4aN
# TfMbpu5ICJteN5tQZRslSUJtD64QdTEHG7RU/DioaYxwNaiA
# SIG # End signature block
