<#
.SYNOPSIS
  Fetches the Calm OS developer workstation setup and starts it.

.DESCRIPTION
  Run from the web:

      irm https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1 | iex

  Elevates, verifies Microsoft signatures, and installs the repository-root release
  under %ProgramData%\CalmOS with Administrator/SYSTEM write access.
  Files stay on disk for helper loading and reboot resume.
  Production requests process-scoped RemoteSigned. -AllowUnsigned uses src/ without
  signature checks or execution-policy changes.

  To select a branch or tag:

      & ([scriptblock]::Create((irm <url>))) -Ref 'v1.2.3'
#>

[CmdletBinding()]
param(
    [string] $Ref = 'main',
    [string] $InstallRoot,
    [switch] $AllowUnsigned,
    [switch] $NoLaunch,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
)

function Invoke-CalmOsBootstrap {
    [CmdletBinding()]
    param(
        [string] $Ref = 'main',
        [string] $InstallRoot,
        [switch] $AllowUnsigned,
        [switch] $NoLaunch,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $repo = 'microsoft/WindowsDeveloperConfig'
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

    # Reject refs that could escape the repository path.
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref.Contains('..')) {
        throw "'$Ref' is not a valid branch, tag or commit name. Use letters, digits, and . _ - / only."
    }

    if (-not $InstallRoot) {
        $InstallRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CalmOS'
    }
    $InstallRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallRoot)
    if ($InstallRoot -notmatch '^[A-Za-z]:\\[^:]+$') {
        throw '-InstallRoot must be a local directory, not a drive root or network path.'
    }

    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        $policy = Get-ExecutionPolicy -Scope $scope
        if ($policy -ne 'Undefined') {
            if ($policy -eq 'Restricted') {
                throw "Organization policy ($scope) requires $policy. Script execution is disabled; contact your administrator."
            }
            break
        }
    }

    $shell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $pwsh = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell\7\pwsh.exe'
    if ($Action -ne 'Uninstall' -and (Test-Path -LiteralPath $pwsh)) { $shell = $pwsh }
    $escapedShell = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shell)
    $arguments = @('-NoProfile')
    if (-not $AllowUnsigned) { $arguments += '-ExecutionPolicy', 'RemoteSigned' }

    function Get-CalmOsElevationCommand {
        param(
            [Parameter(Mandatory)] [string] $Ref,
            [Parameter(Mandatory)] [string] $InstallRoot,
            [switch] $AllowUnsigned,
            [switch] $NoLaunch,
            [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
        )

        $launcher = {
            param(
                [string] $Ref,
                [string] $InstallRoot,
                [switch] $AllowUnsigned,
                [switch] $NoLaunch,
                [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
            )

            $ErrorActionPreference = 'Stop'
            Set-StrictMode -Version Latest
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }
            $baseUri = "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$Ref/$flow"
            $securityCode = (Invoke-RestMethod -Uri "$baseUri/steps/_security.ps1" -UseBasicParsing -TimeoutSec 60).TrimStart([char]0xFEFF)
            if (-not $AllowUnsigned) {
                $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
                if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
                    $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
                    throw 'The setup security helper failed Microsoft signature verification. Setup was not started.'
                }
            }
            . ([scriptblock]::Create($securityCode))

            $work = New-DevConfigProtectedDirectory -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("CalmOS-bootstrap-" + [guid]::NewGuid().ToString('N')))
            try {
                $bootstrap = Join-Path $work 'bootstrap.ps1'
                Invoke-WebRequest -Uri "$baseUri/bootstrap.ps1" -OutFile $bootstrap -UseBasicParsing -TimeoutSec 60
                Assert-DevConfigProtectedTree -Directory $work
                if (-not $AllowUnsigned) {
                    Assert-DevConfigMicrosoftSigned -Directory $work
                }
                $InstallRoot = New-DevConfigProtectedDirectory -Path $InstallRoot
                $target = Join-Path $InstallRoot 'bootstrap.ps1'
                Copy-Item -LiteralPath $bootstrap -Destination $target -Force
                Assert-DevConfigProtectedTree -Directory $InstallRoot
                if ((Get-FileHash -LiteralPath $bootstrap).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
                    throw 'The installed bootstrap does not match the verified download. Setup was not started.'
                }
                Unblock-File -LiteralPath $target
            } finally {
                if (Test-Path -LiteralPath $work) {
                    Remove-Item -LiteralPath $work -Recurse -Force
                }
            }

            $shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
            $arguments = @('-NoProfile')
            if (-not $AllowUnsigned) { $arguments += '-ExecutionPolicy', 'RemoteSigned' }
            $arguments += '-File', $target, '-Ref', $Ref, '-InstallRoot', $InstallRoot, '-Action', $Action
            if ($AllowUnsigned) { $arguments += '-AllowUnsigned' }
            if ($NoLaunch) { $arguments += '-NoLaunch' }
            & (Join-Path $PSHOME $shellName) @arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Bootstrap finished with exit code $LASTEXITCODE."
            }
        }

        # PowerShell also recognizes smart quotes as string delimiters.
        $escapedRef = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Ref)
        $escapedRoot = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($InstallRoot)
        $command = "& {`n$launcher`n} -Ref '$escapedRef' -InstallRoot '$escapedRoot' -Action '$Action'"
        if ($AllowUnsigned) { $command += ' -AllowUnsigned' }
        if ($NoLaunch) { $command += ' -NoLaunch' }
        # Start-Process joins arguments; Windows quoting keeps the command intact.
        return '"' + [regex]::Replace($command, '(\\*)"', '$1$1\"') + '"'
    }

    # Windows PowerShell 5.1 still defaults to protocols GitHub no longer accepts.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
    }

    if ($Ref -notmatch '^[a-fA-F0-9]{40}$') {
        $resolvedRef = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$([Uri]::EscapeDataString($Ref))" -UseBasicParsing -TimeoutSec 60).sha
        if ($resolvedRef -isnot [string] -or $resolvedRef -notmatch '^[a-fA-F0-9]{40}$') {
            throw "GitHub did not return a commit SHA for '$Ref'. Setup was not started."
        }
        $Ref = $resolvedRef
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $command = Get-CalmOsElevationCommand -Ref $Ref -InstallRoot $InstallRoot -AllowUnsigned:$AllowUnsigned -NoLaunch:$NoLaunch -Action $Action
        Write-Host 'Setup needs Administrator rights (a UAC prompt will appear)...' -ForegroundColor Yellow
        $proc = Start-Process -FilePath $shell -ArgumentList ($arguments + @('-Command', $command)) -Verb RunAs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "Elevated setup exited with code $($proc.ExitCode). No further setup was started."
        }
        if ($NoLaunch) {
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent((Join-Path $InstallRoot 'dev-config.ps1'))
            Write-Host "Run when ready: & '$escapedShell' $($arguments -join ' ') -File '$escapedTarget' -Action $Action$(if ($AllowUnsigned) { ' -AllowUnsigned' })"
        }
        return
    }

    function Save-CalmOsArchive {
        param(
            [Parameter(Mandatory)] [string] $Destination
        )

        $candidates = @(
            "https://github.com/$repo/archive/refs/heads/$Ref.zip"
            "https://github.com/$repo/archive/$Ref.zip"
        )

        $lastError = $null
        $everyAttemptWas404 = $true
        foreach ($url in $candidates) {
            foreach ($attempt in 1..3) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
                    return
                } catch {
                    $lastError = $_
                    $status = $null
                    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                    if ($status -eq 404) { break }
                    $everyAttemptWas404 = $false
                    if ($attempt -lt 3) {
                        Write-Host "  Download attempt $attempt didn't work -- trying again..." -ForegroundColor DarkGray
                        Start-Sleep -Seconds (5 * $attempt)
                    }
                }
            }
        }

        if ($everyAttemptWas404) {
            throw "$repo has no branch, tag or commit called '$Ref'. Check the name and run this again."
        }
        throw "Could not download '$Ref' from $repo ($($lastError.Exception.Message)). Check your internet connection or proxy settings, then run this again."
    }

    Write-Host ''
    Write-Host 'Calm OS setup' -ForegroundColor Cyan
    Write-Host "  Fetching '$Ref' from $repo..." -ForegroundColor DarkGray

    $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }
    $securityCode = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$repo/$Ref/$flow/steps/_security.ps1" -UseBasicParsing -TimeoutSec 60).TrimStart([char]0xFEFF)
    if (-not $AllowUnsigned) {
        # Windows PowerShell requires UTF-16LE for in-memory signature verification.
        $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -ne $microsoftSignerSubject) {
            throw "The setup security helper failed Microsoft signature verification ($($signature.Status)). Setup was not started."
        }
    }
    . ([scriptblock]::Create($securityCode))

    $work = New-DevConfigProtectedDirectory -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("CalmOS-download-" + [guid]::NewGuid().ToString('N')))
    try {
        $zip = Join-Path $work 'source.zip'
        Save-CalmOsArchive -Destination $zip
        $expanded = Join-Path $work 'expanded'
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force

        $top = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
        if (-not $top) {
            throw "The download from '$Ref' was empty. Check that the branch or tag name is right."
        }

        $signed = Join-Path $top.FullName 'windows-dev-config'
        $source = Join-Path (Join-Path $top.FullName 'src') 'windows-dev-config'
        $setupDir = if ($AllowUnsigned) { $source } else { $signed }
        if (-not ((Test-Path (Join-Path $setupDir 'bootstrap.ps1')) -and (Test-Path (Join-Path $setupDir 'dev-config.ps1')) -and (Test-Path (Join-Path $setupDir 'steps\_security.ps1')))) {
            throw "'$Ref' doesn't contain the requested setup under $flow. Use -AllowUnsigned only for the source copy."
        }
        Assert-DevConfigProtectedTree -Directory $setupDir
        if ($AllowUnsigned) {
            Write-Host '  Using the unsigned source copy because -AllowUnsigned was passed.' -ForegroundColor Yellow
        } else {
            Write-Host '  Using the signed release copy.' -ForegroundColor DarkGray
            Assert-DevConfigMicrosoftSigned -Directory $setupDir
        }

        $InstallRoot = New-DevConfigProtectedDirectory -Path $InstallRoot

        # Keep logs and progress when replacing setup scripts.
        Copy-Item -LiteralPath (Join-Path $setupDir 'bootstrap.ps1'), (Join-Path $setupDir 'dev-config.ps1') -Destination $InstallRoot -Force
        Copy-Item -LiteralPath (Join-Path $setupDir 'steps') -Destination $InstallRoot -Recurse -Force
        Assert-DevConfigProtectedTree -Directory $InstallRoot
        if (-not $AllowUnsigned) {
            Assert-DevConfigMicrosoftSigned -Directory $InstallRoot
        }
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

        # Clean up before setup can reboot.
        Remove-Item -LiteralPath $work -Recurse -Force
        $target = Join-Path $InstallRoot 'dev-config.ps1'
        Write-Host "  Ready in $InstallRoot" -ForegroundColor DarkGray

        if ($NoLaunch) {
            $escapedTarget = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($target)
            $command = "& '$escapedShell' $($arguments -join ' ') -File '$escapedTarget' -Action $Action"
            if ($AllowUnsigned) { $command += ' -AllowUnsigned' }
            Write-Host "Run when ready: $command" -ForegroundColor Cyan
            return
        }

        $arguments += '-File', "`"$target`"", '-Action', $Action
        if ($AllowUnsigned) { $arguments += '-AllowUnsigned' }
        $start = @{ FilePath = $shell; ArgumentList = $arguments; Wait = $true; PassThru = $true }
        if ($Action -ne 'Uninstall') { $start.NoNewWindow = $true }
        $proc = Start-Process @start

        # Throw to avoid closing the caller's console.
        if ($proc.ExitCode -ne 0) {
            throw "Setup finished with exit code $($proc.ExitCode). The log is in $InstallRoot."
        }
    } finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}

Invoke-CalmOsBootstrap @PSBoundParameters

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCATQDfyyJZ4YKMa
# VoQhCdw/NSp/bMqgnjdUlISq1FVpcaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIK6OPgQTRzvSI5j5obttAURqhxSQ
# +qdbNxqwHAF6RH1dMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAfJlyaO6ncNc/pPMOhLnrfVhCyhD7WBACdva80d3oD/WQXWWGXPlx1fHvDcVg
# hsOkgxKOrJLuYkifMOjqE76HpUR3DCgU5kaKXZ43E1Lzajlcuh4dsMKDCkAQef8s
# x07ujtDdfWLAswo2BwMee5aLyVJnU9JQmPYq74ychMD86lzEvWg0pebh8Fv+Mb9m
# fTmE/Cegc7IVXfErV2do6jPv/LyRSL2OuOIalA3G/rkb97UgqB/9SBpEaivVuk2Z
# Bmx11NlLihJpv3h6hyaWZPSR86kjmKcDjrSV8PpkgrV6tm+wXkMSh9t3HZqlsy7z
# 0wXZF6jlyFSvk1DTFQ2BrjxYoaGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCGzyePI0DL+ho8yw6E52qVt9zYVuIyoF6yH42fnkErLwIGaqk2ZOy/GBMy
# MDI2MDkyNTAwMjEyNi44ODRaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAijwpYfX88geQAABAAACKDANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDZa
# Fw0yNzA1MTcxOTQwMDZaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCujvbk/sqcCSReZaJfCuf1NwRcc7XknhE6wkLofkNj1mxE
# Ag35qy2xcFjgjartVvA09W8QHcpyMqVSXOTxNHJsmk0qP2CDLvUAulWg7aS5oBOR
# pEX1oz3n0R2nPqeH0IHK1zJxjxaHW21AbuZ0Z+wM3WYNzkBlcHmVe03ZG7rlk28h
# 72r5P5ME8FGpFmYW5Hl7psKbgLEfrYAitpttsb+sZsBUI+hMKl4uLJYotKyZv1ew
# OIinBfRU8QosivjofaBezUf9NdV+iGrWh321WnSsK3A/Jl6GLtbSWXcJWULgbxuq
# nobPK+YlB3174TMWTgX4YWjG7o0Otz/pjHNCKBbB788dynhLdGY6B08E9+4SGrRp
# sty4iJHOydHCA5M4i5yYRwsdut+gmvxIpT8yNXJcjJCg0vO8mv/nFY9Wytv2qmCt
# CFFivGUWqU20/sUeRooQZGiQOJQn095Cj3isIsvRP8KU7hN/EDI8HVsb/NPzMFLv
# RznrRnj0TOnDiOTUcnYwmk+XfoS1owskcCCCwHnbC00D58z83y7K5ZJB745hcn4C
# E2nR3e6RGsr42y5qtt6Mdz/s7MTnDS2UmVHWX1X/HZe3UlX8gj/t63L50xIPqkRC
# BEdM1ADNUaSfo9OQiKb/bj1diZCGTfEDUBBLop1mhkwIF82faplV2busZ+U4kQID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFKrJpYz48tzouvVkBVthASFpQ93DMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCQ6NfLmrRahgVtgWg383GaS07fHyod6bhcUONt
# 2tet+6BaNuH0r7ABkVHheOpxBdrUrOEYVEaIii9dK3cuZLNmp1iUAx/VbmOZYl7x
# z+tNrjCWqrg1jQmq0oRB8iE4QJpwNhGP67oY5huYIU0D4lhDoahqfgKJn/0Bk+9U
# KDPw5XlUYmreFmJlj9YQzcPPep8MxBXxh/Y5I7vQeRaW5SjtiLQOLRk3ggvraDs5
# Sf49MJV6/BwxXC2rvUfEFX6SUDooqKIE9NgVIRq0RZu7Ot0i0Is+HvPP0hB6KwOx
# Mg1SWKOfTtFpWpdo8MJvgKCHkPpXEzgprP+pyIHuO7gVRlSTsbYBFLh2yId/itM4
# uYL0R+2SSBBTpSSRthrGuEmElI5BCHMxzMg/oqHSPwZAIAkM2C4xxi0St7qMuA+m
# +ZzFYkfoF41QoSJn+HjqhqWYQ0m/SO9/KnJRJJUwMd5TiMnjZ+E/DJiUry5udiWy
# Qpvfj2hQFI0djhahoAXDazeEciLF2uEnTur9UfjcwOun/oMY+ULftnOi2jKLMrre
# V097akzz/JxpnDgYJU/tgU7fQflg7IqiL9+0276+joQHo21mVeY5YD8Kh/kUaY6J
# m/OTM88G7evTz/qnRumxovTjMStvpbAHNRhmSTdIPTV32CyuxDKS/V5a5iwA+f9V
# iBo+wjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIIC
# NQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB1rbmF
# kzS7qAK1Oav08AUnhbNIUqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mA5zzAiGA8yMDI2MDkyNTAwMDc0M1oY
# DzIwMjYwOTI2MDAwNzQzWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuYDnPAgEA
# MAcCAQACAhwNMAcCAQACAhJmMAoCBQDuYYtPAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAAVKLh2cKflH+6JP3W9KjZYjkcl1A1q6fDWmMTV+2qvijRjh/XEG
# FA0v8/CZ8YJdS8qd3DYihaE8ia3PzzvXNlHzSk6/b1EcuFgJBLF0cuOEuUzn3FYS
# k23CziI4b7wM3Md9kuhZThTnR/QJShXraWwH5DL8Gy8nxyEEBiGEUFNuXLQBng72
# sKDDMBa7/pDivLVnmjS3xMDrtS07gIJ2Y3Gw8SXU6Zv6tpvhWOgC9BVjVVigABs8
# zn5YciYX1Hyru0gNjM1liT5pY8p1T5+i/P81VHQT20kUC4G378G2XrYZQO7PxaiE
# DPnzKPrpFb6pwDlW7ZQLnsV9kuMTZJ40pusxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCAOerA19yuHPg9orpT8B9h9LZDpOQaWvpu4Q7gG9GDsgjCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFWxikZRYGNf4oEVZK1eT45H+3GQ3/qx
# V75VwuBt+iLXMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIo8KWH1/PIHkAAAQAAAigwIgQgLZDW27+IFTXfFG2rOGYgn96HrZNNVkJe
# ibYUww8NkswwDQYJKoZIhvcNAQELBQAEggIAoWzMHWcprVYIv/gATWnSW1Xli5gx
# P/3u95T0Gssx0rvROp8J9Rij1cZRIXXPze2+AzM627q1RiWkIMCJtF6jUMh2Wa6j
# aiMK7/8b9voADI0ksLJvMFOQPcXQXMGQINM7ReTDi5jExHEtVV/9HYXcc62KP6LK
# M4GB/iZ/jnLmm9SouCSPzwaxNTZrCDCoWHNRZwgq2xQ5MQrINdUpvUUQyIfZTeGW
# 6ILYPZ3oJAKIoC7G+gkwpjMmtWl+sRSbiMEzuKK6VSqstNyyxw1WaBy9BYq/Dgvr
# nZ+63PPaw2BufaVBYf4GkTc7RucrwTm+ixAGcGriWbml7/wPXAhccUhuE6KYPxYz
# BQUdSPAOrEuMvwo/9i6VAewbSOuPw/bdUOXLtB4J8Po8ODX5oVBRw03wj1Qr6oyf
# 8zqIRNNwQqOSPPwS3qBVztaWsaPBOymVjRmz5HsXmb//y0eLLnD2CE3UjGY59Rri
# aAgESAVrS16FY2D7/PmumVho5WqqcrAvuNwY6EYEhtSBBhuFcbFAKt7X/ULkW3xY
# 44lGyOG/IyvB4O26DVyXHFRefQGJur22WDpk9nBIg/KJN2hxOz62fjJfwok9+OlU
# tI8/JQIrVy71yKl2H1OqmWTcvfq/PBKcjJxwz6/fVekXPpbV84wL+L34+sXR1ASe
# 3T/CyniZppGVX5Q=
# SIG # End signature block
