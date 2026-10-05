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
        [int] $TimeoutSeconds = 120,
        [switch] $NoInput
    )
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $null
    }

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $stdin = $null
    try {
        if ($NoInput) { $stdin = [System.IO.Path]::GetTempFileName() }
        return Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds `
            -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr -RedirectStandardInput $stdin
    } catch {
        Write-Verbose "wsl $($Arguments -join ' ') could not run: $($_.Exception.Message)"
        return $null
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        if ($stdin) { Remove-Item -LiteralPath $stdin -Force -ErrorAction SilentlyContinue }
    }
}

# The current WSL package supports --version; the inbox WSL returns a nonzero exit code.
function Test-DevConfigWslRuntimeCurrent {
    return ((Get-DevConfigWslExitCode -Arguments @('--version') -NoInput) -eq 0)
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
    $stdin = $null
    try {
        # Closed stdin prevents a missing WSL runtime from waiting at its installation prompt.
        $stdin = [System.IO.Path]::GetTempFileName()
        # This query is bounded and redirected so a nonresponsive listing is treated as not installed.
        $exitCode = Invoke-DevConfigProcess -FilePath 'wsl.exe' -Arguments @('--list', '--quiet') `
            -NoNewWindow -TimeoutSeconds 120 -RedirectStandardOutput $out -RedirectStandardError $err -RedirectStandardInput $stdin
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
        if ($stdin) { Remove-Item -LiteralPath $stdin -Force -ErrorAction SilentlyContinue }
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
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDGiKVayo6Vo5bZ
# UqwFptqrKvTVDSYWVdVl6Vu7BJL/vqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIJ03p+Osc1BnFvwSSQgGJWELpFu/Hrxblo/DC4lu2usrMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAMmaYbX3BqPJ+Swaa
# ImsXykBivbNEt7MpZzG8qQqlYE31qwQGjJi78z2S75g/dJA0KYZS5/l6uZxrZbWU
# ojJGyWrICPx29Wbv1UNPZX/yB3LjzvV5+NT4PNbkcC+NcWhHECNM72OmeRhWE2D/
# WNx0FbEEWA9i31/YB9KUvD3a6quQQASkqOex8cddCqK9Ezi2fLak/HPtVLXsBHnZ
# KA4PUqnQIRw2OwbB3WAhNklu9cgNzqFH1ha/Zy923VavjLkIaL6Xnw+SZLr/IHt1
# In6D3fBxyfwBuCJGvusg6xGsHnO/ybe2dBx/523wHSS48+FAtmXbCTcTlJBnKNMs
# YPQ6vaGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kw
# gheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAGFw5LMYRd0Jpu
# VBlmm+nGn+QhNuEJSuKCzms5YXF81wIGaq9UoosgGBMyMDI2MTAwNDIzMDc0NS4w
# OTFaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIF
# EKADAgECAhMzAAACFRgD04EHJnxTAAEAAAIVMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyMFoXDTI2MTEx
# MzE4NDgyMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjY1MUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAw3HV3hVxL0lEYPV03XeNKZ517VIbgexhlDPdpXwDS0BY
# txPwi4XYpZR1ld0u6cr2Xjuugdg50DUx5WHL0QhY2d9vkJSk02rE/75hcKt91m2I
# h287QRxRMmFu3BF6466k8qp5uXtfe6uciq49YaS8p+dzv3uTarD4hQ8UT7La95pO
# JiRqxxd0qOGLECvHLEXPXioNSx9pyhzhm6lt7ezLxJeFVYtxShkavPoZN0dOCiYe
# h4KgoKoyagzMuSiLCiMUW4Ue4Qsm658FJNGTNh7V5qXYVA6k5xjw5WeWdKOz0i9A
# 5jBcbY9fVOo/cA8i1bytzcDTxb3nctcly8/OYeNstkab/Isq3Cxe1vq96fIHE1+Z
# GmJjka1sodwqPycVp/2tb+BjulPL5D6rgUXTPF84U82RLKHV57bB8fHRpgnjcWBQ
# uXPgVeSXpERWimt0NF2lCOLzqgrvS/vYqde5Ln9YlKKhAZ/xDE0TLIIr6+I/2JTt
# XP34nfjTENVqMBISWcakIxAwGb3RB5yHCxynIFNVLcfKAsEdC5U2em0fAvmVv0so
# nqnv17cuaYi2eCLWhoK1Ic85Dw7s/lhcXrBpY4n/Rl5l3wHzs4vOIhu87DIy5QUa
# EupEsyY0NWqgI4BWl6v1wgse+l8DWFeUXofhUuCgVTuTHN3K8idoMbn8Q3edUIEC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBSJIXfxcqAwFqGj9jdwQtdSqadj1zAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAd42HtV+kGbvxzLBTC5O7vkCIBPy/BwpjCzeL
# 53hAiEOebp+VdNnwm9GVCfYq3KMfrj4UvKQTUAaS5Zkwe1gvZ3ljSSnCOyS5OwNu
# 9dpg3ww+QW2eOcSLkyVAWFrLn6Iig3TC/zWMvVhqXtdFhG2KJ1lSbN222csY3E3/
# BrGluAlvET9gmxVyyxNy59/7JF5zIGcJibydxs94JL1BtPgXJOfZzQ+/3iTc6eDt
# maWT6DKdnJocp8wkXKWPIsBEfkD6k1Qitwvt0mHrORah75SjecOKt4oWayVLkPTh
# o12e0ongEg1cje5fxSZGthrMrWKvI4R7HEC7k8maH9ePA3ViH0CVSSOefaPTGMzI
# hHCo5p3jG5SMcyO3eA9uEaYQJITJlLG3BwwGmypY7C/8/nj1SOhgx1HgJ0ywOJL9
# xfP4AOcWmCfbsqgGbCaC7WH5sINdzfMar8V7YNFqkbCGUKhc8GpIyE+MKnyVn33j
# suaGAlNRg7dVRUSoYLJxvUsw9GOwyBpBwbE9sqOLm+HsO00oF23PMio7WFXcFTZA
# jp3ujihBAfLrXICgGOHPdkZ042u1LZqOcnlr3XzvgMe+mPPyasW8f0rtzJj3V5E/
# EKiyQlPxj9Mfq2x9himnlXWGZCVPeEBROrNbDYBfazTyLNCOTsRtksOSV3FBtPnp
# QtLN754wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCC
# AkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAj6eTejbuYE1Ifjbfrt6tXevCUSCggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5s70UwIhgPMjAyNjEw
# MDQxNTI5MDlaGA8yMDI2MTAwNTE1MjkwOVowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7mzvRQIBADAKAgEAAgIIXwIB/zAHAgEAAgISdjAKAgUA7m5AxQIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQAxFlrOUc16KWyJCEgEKvQH9X+063IJxml8
# JCVGAc4g5rt5DfKjuvRMNOTUPJjQ8NW6+PBRGm+igYC3DpY02BDRS/jk8YH0yvcY
# 2Hr6LF8WqRIvMYSy8BQ8j+VWrAKW4yjMl49dJ92k9TBsJFTG/fDk8u74JYtZSrRZ
# WSmuA0JXH6/Tlb8xXbtMElo7D/PPBIBOw+vU8WYsGk75IAhwx0Jk6EsEy4FT04JU
# rjQqk2j9oMDcqDsYRcuZgDwKwQBE6s6dQD2eqFxCkzHvKBqaMGwqv1uUQVEKQYaf
# K01ORTfvYhH8LVfaGAi8ztJ41dgQq6yJCA0W95eplTD34PMl3ZzHMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIVGAPTgQcm
# fFMAAQAAAhUwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg/wBp4md1NDhb2mywDMr+hPmXOtRJ79Uv
# tyH3BdF9L5swgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBwEPR2PDrTFLcr
# tQsKrUi7oz5JNRCF/KRHMihSNe7sijCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACFRgD04EHJnxTAAEAAAIVMCIEIGmjVCBnT2oQz986
# VFTHmonEuEnAYnr5HHeSjVrc8tHlMA0GCSqGSIb3DQEBCwUABIICAErqRUIKDfeJ
# g91JA3PLh+Ea2WJp7cAbxzQFl+ekTwCGMHud7VcAvdtGn3SB9djD1XHkbns0t4lF
# Izaz21YwWGq3jzMx6+wlGcCxvRujqDBAmGkH4AhxOvbe72mOWijgDG9D+yCGajJ2
# AgcjsSBM8tCm9Bb5mYCaz8MT+UBmIloCv0Pal6gJ71VpmpFMF62NzkM1R0GvVNUp
# wDLJQ9pttkymB2oysB1CLDmIuDJpaQ7+kaKxjKBJP6xG85zUX19PXKTPiPN/Qkhs
# VZwDe9wLEuzxmZrUkAg+q8J186fOLUrFC8zZ4rIuNkWvz0SiJx5LEX4cNxGeqoJe
# kjrq8vmbeUlarqVP+Q9+9UCcS//DHiEe72d+g0jruMKbnMKk2W6cPNZcQI2TlnrR
# G2R5wJMQT+KOm8RePd9ZSMi2ZZuxDkyBje2/Ha3iHPEH1mrqcP43olIfxw3DQnyS
# GNxu5HzRW4v347Gu7i18qHhR4ukRTNmigoRHxG0/tjGiotTokHFUnMNyLteZ+aSn
# GsY12W52kg/HFuUjOkH+yRujITuaddo2dTGqxx7EIEu644goi9TYPMgCST80H7e2
# TbMOLVZB+57ML7h857u6dn88kR03vMA/i4aEqynHCGl5iC6WfO61msJI3sAMf+ie
# hSHTUoEpD4iO8UmMcSJvyqbaVuRjaG9Y
# SIG # End signature block
