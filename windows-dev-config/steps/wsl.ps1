<#
.SYNOPSIS
  Installs WSL and Ubuntu with reboot support, or removes them during cleanup.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigWslDistributionName = 'Ubuntu'
$Script:DevConfigWslFirstRunSetting = @{
    Name      = 'WslFirstRun'
    KeyPath   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss'
    ValueName = 'OOBEComplete'
    Value     = 1
}

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
        return @($distros | Where-Object { $_ -like "$($Script:DevConfigWslDistributionName)*" }).Count -gt 0
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
    $setting = $Script:DevConfigWslFirstRunSetting
    Set-DevConfigRegistryValue -KeyPath $setting.KeyPath -ValueName $setting.ValueName -Value $setting.Value

    if (Install-DevConfigUbuntuVia -Arguments @('--install', '-d', $Script:DevConfigWslDistributionName, '--no-launch') -MaxAttempts 2) {
        return
    }

    # The web-download path does not depend on Store access or Store registration timing.
    Write-Host '  The Store copy of Ubuntu did not take. Downloading Ubuntu from the web instead.' -ForegroundColor Yellow
    if (Install-DevConfigUbuntuVia -Arguments @('--install', '-d', $Script:DevConfigWslDistributionName, '--no-launch', '--web-download')) {
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

function Test-DevConfigWslDistributionRegistered {
    $root = Convert-DevConfigRegistryPath -KeyPath $Script:DevConfigWslFirstRunSetting.KeyPath
    if (-not (Test-Path -LiteralPath $root)) {
        return $false
    }
    foreach ($key in Get-ChildItem -LiteralPath $root) {
        $properties = Get-ItemProperty -LiteralPath $key.PSPath
        $name = $properties.PSObject.Properties['DistributionName']
        if ($name -and $name.Value -eq $Script:DevConfigWslDistributionName) {
            return $true
        }
    }
    return $false
}

function Test-DevConfigWslPackageInstalled {
    $executable = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    return (Test-Path -LiteralPath $executable) -or
        @(Get-AppxPackage -AllUsers -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction Stop).Count -gt 0
}

function Remove-DevConfigWsl {
    if (Test-DevConfigWslDistributionRegistered) {
        Invoke-DevConfigCleanupCommand -FilePath 'wsl.exe' -Arguments @('--unregister', $Script:DevConfigWslDistributionName) | Out-Null
    }
    if (Test-DevConfigWslPackageInstalled) {
        # WSL can terminate itself during removal; the step still verifies that the package is gone.
        Invoke-DevConfigCleanupCommand -FilePath 'wsl.exe' -Arguments @('--uninstall') -SuccessCodes @(0, 1, 3010) | Out-Null
        for ($attempt = 0; $attempt -lt 15; $attempt++) {
            if (-not (Test-DevConfigWslPackageInstalled)) {
                return
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Invoke-WslPhase {
    param(
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )

    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @(
            New-DevConfigRegistryStep -Setting $Script:DevConfigWslFirstRunSetting -Reset
            New-DevConfigStep -Name 'WslCleanup' -Description "Delete $Script:DevConfigWslDistributionName and its data, then uninstall WSL" -BestEffort `
                -Check { -not (Test-DevConfigWslDistributionRegistered) -and -not (Test-DevConfigWslPackageInstalled) } `
                -Apply { Remove-DevConfigWsl }
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAJqionUs3hdeTB
# eOeZRRAqROquDc8iNV9QydDaFsAJUKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIORQmheeJZo5/JestyfPoRNlKpeomncapG2Xl9ZRhI+RMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAmngnInSN95EjhYtK
# iGHu4t9PLgq8qi67/M3q6fuHy4nCiG29bkatwpdFDJu3Zn/tg7RnH2cEGFYQlnFF
# WoXdX/ZTIzC0xgFhaXwb/IhPLze70jVNJ+bHbB74ND4gDNrC6zAHL4EXhu+ldW4Y
# gqJqX1FUv0sDKEGP/C84HpH7mT1zorOnDbHl2vqrGq++vp5n0RUK1lN4r2/Sowoc
# 4OT+WMVrbIiInHUQ/DAhnIBkF5zSezh6I6Qk5TQXccZuKK3VbbxTE9Yv7QX63SBd
# 5X0c3wz+DndO6Aufn2RwQOf8ddzS61tqag0hQosg2SUUmqSrUruaF18hT56QJ5ic
# PGFx+aGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDFEmdaQaHXnZ7S
# IH8JZoEUW76/OTKRj278bF3v6mt5LwIGaqk3i6sgGBMyMDI2MTAwMjAwMTQwOC4z
# NDhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAijwpYfX88geQAABAAACKDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDZaFw0yNzA1MTcxOTQwMDZa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# jvbk/sqcCSReZaJfCuf1NwRcc7XknhE6wkLofkNj1mxEAg35qy2xcFjgjartVvA0
# 9W8QHcpyMqVSXOTxNHJsmk0qP2CDLvUAulWg7aS5oBORpEX1oz3n0R2nPqeH0IHK
# 1zJxjxaHW21AbuZ0Z+wM3WYNzkBlcHmVe03ZG7rlk28h72r5P5ME8FGpFmYW5Hl7
# psKbgLEfrYAitpttsb+sZsBUI+hMKl4uLJYotKyZv1ewOIinBfRU8QosivjofaBe
# zUf9NdV+iGrWh321WnSsK3A/Jl6GLtbSWXcJWULgbxuqnobPK+YlB3174TMWTgX4
# YWjG7o0Otz/pjHNCKBbB788dynhLdGY6B08E9+4SGrRpsty4iJHOydHCA5M4i5yY
# Rwsdut+gmvxIpT8yNXJcjJCg0vO8mv/nFY9Wytv2qmCtCFFivGUWqU20/sUeRooQ
# ZGiQOJQn095Cj3isIsvRP8KU7hN/EDI8HVsb/NPzMFLvRznrRnj0TOnDiOTUcnYw
# mk+XfoS1owskcCCCwHnbC00D58z83y7K5ZJB745hcn4CE2nR3e6RGsr42y5qtt6M
# dz/s7MTnDS2UmVHWX1X/HZe3UlX8gj/t63L50xIPqkRCBEdM1ADNUaSfo9OQiKb/
# bj1diZCGTfEDUBBLop1mhkwIF82faplV2busZ+U4kQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFKrJpYz48tzouvVkBVthASFpQ93DMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCQ6NfLmrRahgVtgWg383GaS07fHyod6bhcUONt2tet+6BaNuH0r7ABkVHh
# eOpxBdrUrOEYVEaIii9dK3cuZLNmp1iUAx/VbmOZYl7xz+tNrjCWqrg1jQmq0oRB
# 8iE4QJpwNhGP67oY5huYIU0D4lhDoahqfgKJn/0Bk+9UKDPw5XlUYmreFmJlj9YQ
# zcPPep8MxBXxh/Y5I7vQeRaW5SjtiLQOLRk3ggvraDs5Sf49MJV6/BwxXC2rvUfE
# FX6SUDooqKIE9NgVIRq0RZu7Ot0i0Is+HvPP0hB6KwOxMg1SWKOfTtFpWpdo8MJv
# gKCHkPpXEzgprP+pyIHuO7gVRlSTsbYBFLh2yId/itM4uYL0R+2SSBBTpSSRthrG
# uEmElI5BCHMxzMg/oqHSPwZAIAkM2C4xxi0St7qMuA+m+ZzFYkfoF41QoSJn+Hjq
# hqWYQ0m/SO9/KnJRJJUwMd5TiMnjZ+E/DJiUry5udiWyQpvfj2hQFI0djhahoAXD
# azeEciLF2uEnTur9UfjcwOun/oMY+ULftnOi2jKLMrreV097akzz/JxpnDgYJU/t
# gU7fQflg7IqiL9+0276+joQHo21mVeY5YD8Kh/kUaY6Jm/OTM88G7evTz/qnRumx
# ovTjMStvpbAHNRhmSTdIPTV32CyuxDKS/V5a5iwA+f9ViBo+wjCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB1rbmFkzS7qAK1Oav08AUnhbNI
# UqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7ml0TzAiGA8yMDI2MTAwMjAwMDc0M1oYDzIwMjYxMDAzMDAwNzQz
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuaXRPAgEAMAcCAQACAgvzMAcCAQAC
# AhibMAoCBQDuasXPAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAIg/vK9q
# QneRWkIlvvs6QRTSoPSLng6Umpe9CH/79LLEzy8gTPBOjNThlKf6SlxtwfVch9Ua
# 1rT4FuW9h697O0QkKARMTTx1BF3xM3bk0iP7wNIMhKlKUGtQ1dRS7ha/LvTEah13
# e0TF7RVz/po2yRMrYFcAo1og9PNoheHsOWCfFsXiswQ/DFHPwYGlnkHPtWJMtKRt
# edEBGOvryj+rwqq9wux8sq19peo/mqLOgDsrLgfuLs/lNL7zUtD/I1QrTuyVfnw6
# cVbbuM0rj565232BWzYuX8kw9AD61ipKzXJa2WxUE00AMdXb3Ub14brmpyJumTIY
# fE2KckucI7W9bTAxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBYGXFc
# KdWnbACjmRU5TWYWZI5fHXNidkV++9dJTqVC2DCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIFWxikZRYGNf4oEVZK1eT45H+3GQ3/qxV75VwuBt+iLXMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIo8KWH1/PIHkAA
# AQAAAigwIgQgET+kU5v7ipJWDU7Y3MFhHqxcq6/5+VlUbARBDqhFfZowDQYJKoZI
# hvcNAQELBQAEggIAYpFInWuUvg0wIgQnuhT0yPWJsJ2tH4YVUf61yop6RfDUfUCh
# v6u97ejJDYJDgzXMiQ5muMqCgMYwLgGWltT9URCaUWm2MuaRpZyNdeL3u20p0bfH
# YSRk/Z63avW4+d2yTsRFzYTudcY9NJPh1w6MnngskvYWnXcz7GwWYR3ayxTDp7TV
# X9kBAIzEZJIn+j4cA/sIgo+hEwgjQxT+Cmu5vvJqq+JwN88dAjAAyARs2XU+DiGI
# wjBjYvWMiHOK1mqx40drAA7h0q7Jdryo09CwI8WRAN3NQufgDqHeMLb5xlV3EjuB
# b0J90Ltx/pCKafNkXmhrN5jasduCDWpbexwA6SbF7CLs5T1d4AdagjjDpx9WeaSh
# ky4DWJpAA2jHrCs/pb5gnS1KTa/Zwj5mi1DwFppdm8ihVPvM6OQ6gDbI5u9bbvYf
# ZWGOHHFxhPHjWSAWkv4RlwiUOlKEHJuPf0tVm5h5ucttYdaPqmh7xQfqJ0J67+fK
# /+P/ZB0TR/vOho+u238B9wZV2dR0CJpVK18Qz57hcXviDr7gmr8uLlw/+D+n6My9
# fe+VnxtUCyXfdjkQH7OzMT5iF5ns0VKeSwatBSyLTK7TDQgVWoojqGnWnaR9pDzz
# Ba1u07o0raHhoVpDDTMLz+asjX33A94mL6XiqyMCdRdthIxGQU4FsMnCtKw=
# SIG # End signature block
