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
# MIInJwYJKoZIhvcNAQcCoIInGDCCJxQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnDMIIZvwIBATBuMFcxCzAJBgNVBAYTAlVT
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
# PGFx+aGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2ww
# ghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDFEmdaQaHXnZ7S
# IH8JZoEUW76/OTKRj278bF3v6mt5LwIGaql/GtLcGBIyMDI2MDkyNTIwMzkyMy41
# NlowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBMDAwLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMz
# AAACK7sAUP9NO5qhAAEAAAIrMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5NDAxMVoXDTI3MDUxNzE5NDAxMVow
# gcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsT
# HE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjpBMDAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJfe
# aLo4PezJSpCbhCqCSso9tywr9DHd9hy0vz5UzW45jduiiLkbHBq5OBB/okUchNOj
# FLuCOoqUrw4UvMvpROXSPEQrm3oO45yAld2+62KahOU5LQLeTIhNcEBeiP+CnqFF
# H3PpZGKnUq2SKVvd0lcKNCpP0/YK66Ov5XPyv5n6MOXT2OL+Jz/gbfiveZXCOz/8
# afH0+7fVXytcWJw2IDPGm5trClt3ymp/OVZPa+cbeQX2XoyJERu8ndcctTAdCyHS
# 39OtIXH+z/IKqklZgnqgKUbvS2+wUfRpE/zAHhw/8IVrYgu+TbqLc5wkGX6moqMd
# NIHL2a/BM8QOWfNyjQ23xHqlI9NdmAGyxweGgp8LRZCY7NjaR5dsCZFNxkzJfPm/
# 8AluagjTLTsFrO+3k2Rd10b1MStBbC2wXIgqsSUOBZ8d4KhO7XC7ZyIPd0rvbPdx
# raDOgQPFPaP0FchQpqJPNN1A9GwAxo7d1TTNobAwyXC1InIOHXhgSBmhS7m9Lwy6
# Ayp2s2OmHIvrnIqGOkBZuFiQgc7/S5mO73m0/zNk2pchGHi119Yck8BOf2v5zGTK
# 6HbHRUt1/HWWYr1fc2MfQ22ACzkkH/A6WTK653GYVN9ZXJGsvfuKyk5nxo8AWC/J
# Hpw1OQamQWjfklGNyI2ZmJTipP1S3L5XmC50WTWPAgMBAAGjggFJMIIBRTAdBgNV
# HQ4EFgQUPhaO5BNQlu1t3eOa9mS7QVnZ5TYwHwYDVR0jBBgwFoAUn6cVXQBeYl2D
# 9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUB
# Af8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQAD
# ggIBAM78IqxyIQzySvV+ofhOV9ProQ2hOPFfDzXSnISrQ92uAvB+BPfH7WDPsJAe
# 1R16+oxDmofIMuGbqlP3XUJiQY37qD4xTt8xhOvp3dLGJ4nAEihaR9HiDtKK0bMw
# pTjrkoRh6N912hSCi8L/FxGloAs7mnf8DbjwHKEmIy20FA0O2xP8doIXBEUJRFvL
# 9/xzWSTLwXzGQJcXP78y1nl3WVYWPA4jaB5kdar1eKEM6B57mdLaSijlXqfxcbbb
# RRN69V/6mCakgfvVcoNUhhMYZkmzrI+V8nZperDUwTg1HqiQ2xjc/UzfUfoMxhF8
# kY0E16nn3mRcaHdjMDdwKLKD6OYnnyH99O+OeAim5QV84OkOMXHSJzVigsA3GEIX
# dGFL2pgzsrjQ0SEqyFi5oCQgbZcEpiKDev/T9vSyO+MHCznkBiicybcDypxf/qT1
# V9zSa/122ice5YZ8DZv6oTaqkKeHMZt0MeruI5JkTDTWc26kAx/VzjWT0ihNDbPe
# LDrDhlmgs7KDhMoxunWSulPi2uKn/LfQK/mSHKoIM2ppdCkGQ5g43wuC2hDdqZU5
# fuLHmN2ufH+9TFNRKKBe+tZ0vtSTySmZLTO2jZOjLtpPmgHMJO9+P2In8E38TW+E
# UGSEkK9ns9W+wxKdNOaTHYVqXaVWTO24Ajjh8P+7Isl1oxBLMIIHcTCCBVmgAwIB
# AgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0
# IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1
# WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O
# 1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZn
# hUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t
# 1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxq
# D89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmP
# frVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSW
# rAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv
# 231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zb
# r17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYcten
# IPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQc
# xWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17a
# j54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQAB
# MCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQU
# n6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEw
# QTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9E
# b2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/
# MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJ
# oEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01p
# Y1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYB
# BQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9v
# Q2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3h
# LB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x
# 5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74p
# y27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1A
# oL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbC
# HcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB
# 9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNt
# yo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3
# rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcV
# v7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A24
# 5oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lw
# Y1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA00wggI1AgEBMIH5oYHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAAmsP3TKQemj/QAZvuWbC+wK2pE5
# oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcN
# AQELBQACBQDuYSryMCIYDzIwMjYwOTI1MTcxNjM0WhgPMjAyNjA5MjYxNzE2MzRa
# MHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO5hKvICAQAwBwIBAAICDaowBwIBAAIC
# EzIwCgIFAO5ifHICAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAK
# MAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEATaiteeRu
# Ucj+l05bRphxOQylotSPefG3Ps9m+zu8ODisGvr2C0e+MM7tnBDfrCFyDSCJa53W
# a/6PAaxucogE1GSfTkgINWMvl2VxUa56AuRk6nzgMz7XwThtbNpjIv+SzOXqbjCD
# csPUYI5amjxSnsP0Q7VnoRaajFoHVk/nduG+pm/oqu7qM2S1+ccngm5WVSNwV+14
# 3DcfivG741lUwM+JBCK0ZJRZbhWV90scqLbIXOKhqvO3LOHzmehNABnnXet8Ij24
# xWOpyyhV/8Mm1SB7AtRjpZ70IN3xMUDUlDzyMgcRhQD+et/Sd/GDHo6+VUdrpAUh
# +L54RIFE5IXs4zGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACK7sAUP9NO5qhAAEAAAIrMA0GCWCGSAFlAwQCAQUAoIIBSjAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIHfVEgfN
# hKX15uYHJFhffTBo/jr946A3fDG8KBDkiitQMIH6BgsqhkiG9w0BCRACLzGB6jCB
# 5zCB5DCBvQQgcg4j9D+QV+1gD4zY5j7UHHdqMEPr9YMC09Pa8WS/blIwgZgwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7AFD/TTuaoQAB
# AAACKzAiBCBw6t0NUi2GsCEwaloudRhgxL/O75+UmM21Qz75jxh1jTANBgkqhkiG
# 9w0BAQsFAASCAgAijMVopDZ+J+x0x3LXcJsQO//41Ul7ntYZle5MiZtkCX2nZQDX
# 97XOwjajJRffIizFSc+kloZU9tWhr9F2Gdpmf+8YdheAIdw84iRBrtWZYX/zPGZC
# /0li9bZZQb45A/hti0i6LIrMVyDwdT6AlQ88QJvkKr8Wr5rs+EM828KEsJNXoYBj
# NZsvs8czk3fI7JURyYpAZaL/ZA/Gb47wprfu7CGwvKWKI9m04sE6YtTDRTW+glmk
# KgobL+MbmnBzuZXwTGsEIYn8K6aqMvQ5QODL+AtYGD/Wl2bOkz5yKYBoWwkD7E4l
# SeraO1y8yUEXF0OsOUqhgNTjgiwQmnBVY8iJS829l2YGrltH9azUtSBGo9lmCUuF
# I1BC8Ha+nir5G2qEt3B85ruMz6UPnPtsUHTZrTp1aPDcsrVykFZfoy4iBFkiit2n
# mieO0i3Tx6u0uh9tsMNX00c/LSP0DL/4EA1shsyhUDNXBgFJeB++NMLQwBzQNbVo
# /qeu6a6hKQV28u/PaEBU0R5UVdsIS8MkHuRB9jZCLxvNITW8tbLfu+1B7xtX4rju
# r5H4PMSpB5d+V/Y0WRtSRDSbmKkq9niJTs6ELs9hzljkRRj/mc8oQcRuWZQADo01
# gb1zKam27EKY1bsGPC/He2C65FLSRvQyIeoHJJCHe3nrJn1I9e48N0VGHA==
# SIG # End signature block
