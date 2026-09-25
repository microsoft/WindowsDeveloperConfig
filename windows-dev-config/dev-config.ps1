<#
.SYNOPSIS
  Configures or cleans up a Windows developer workstation.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed,
    [switch] $AllowUnsigned,
    [switch] $ApplyTerminalFont,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepsDir = Join-Path $PSScriptRoot 'steps'
$securityCode = [IO.File]::ReadAllText((Join-Path $stepsDir '_security.ps1'))
if (-not $AllowUnsigned) {
    # Verify and execute the same text to avoid a file-swap race.
    $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
        throw 'The setup security helper failed Microsoft signature verification. Run bootstrap.ps1 to reinstall; use -AllowUnsigned only for development.'
    }
}
. ([scriptblock]::Create($securityCode))
if (-not $AllowUnsigned) {
    Assert-DevConfigProtectedTree -Directory $PSScriptRoot
    Assert-DevConfigMicrosoftSigned -Directory $PSScriptRoot
}

# Windows PowerShell 5.1 defaults to ANSI; force UTF-8 for console symbols.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

. (Join-Path $stepsDir '_console.ps1')
. (Join-Path $stepsDir '_step-runner.ps1')
. (Join-Path $stepsDir '_elevation.ps1')
. (Join-Path $stepsDir '_reboot-resume.ps1')
. (Join-Path $stepsDir '_registry.ps1')
. (Join-Path $stepsDir '_environment.ps1')
. (Join-Path $stepsDir '_retry.ps1')
. (Join-Path $stepsDir '_terminal.ps1')
. (Join-Path $stepsDir '_winget.ps1')
. (Join-Path $stepsDir '_pwsh-bootstrap.ps1')

$Script:DevConfigAllowUnsigned = [bool]$AllowUnsigned
if ($ApplyTerminalFont) {
    . (Join-Path $stepsDir 'fonts.ps1')
    $pendingPath = Get-DevConfigPendingTerminalFontPath
    if (-not (Test-Path -LiteralPath $pendingPath)) {
        Write-Host 'No Terminal font update is pending.'
        exit 0
    }
    $logPath = [IO.Path]::ChangeExtension($pendingPath, '.log')
    Start-DevConfigLog -Path $logPath
    $failure = $null
    try {
        Invoke-DevConfigPendingTerminalFont
    } catch {
        $failure = $_
        Write-Host "The Terminal font update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Full log: $logPath" -ForegroundColor DarkGray
    } finally {
        Stop-DevConfigLog
    }
    if ($failure) {
        Wait-DevConfigKeyPress -TimeoutSeconds 60
        exit 1
    }
    exit 0
}

# TLS is configured before any download step runs.
Enable-DevConfigModernTls

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action

if ($Action -eq 'Uninstall') {
    Invoke-DevConfigEnsureCleanupShell -ScriptPath $PSCommandPath -AllowUnsigned:$AllowUnsigned
} else {
    # WinGet module behavior is more consistent in PowerShell 7 than in Windows PowerShell 5.1.
    Invoke-DevConfigEnsurePwsh -ScriptPath $PSCommandPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action
}

# The lock starts after relaunches so the worker process owns the log file.
if (-not (Enter-DevConfigSingleInstance)) {
    Write-Host ''
    Write-Host 'Calm OS is already running in another window.' -ForegroundColor Yellow
    Write-Host 'Switch to it rather than starting a second copy -- they would fight over the same installs.' -ForegroundColor DarkGray
    Wait-DevConfigKeyPress
    exit 1
}

Start-DevConfigLog -Path (Join-Path $PSScriptRoot 'devconfig-log.txt') -Append:$Resumed

# Any prior resume task is stale once this run starts.
Clear-DevConfigResume

$Script:DevConfigResumed = [bool]$Resumed -and $Action -ne 'Uninstall'
$Script:DevConfigAction = $Action
if ($Script:DevConfigResumed) {
    # Restore the pre-reboot tally so the final summary covers the whole run.
    Restore-DevConfigTally -Path (Join-Path $PSScriptRoot 'devconfig-tally.json')
}
# WSL stays last so its required reboot happens after other phases.
$phases = @(
    @{
        File     = 'prerequisites.ps1'
        Function = 'Invoke-PrerequisitesPhase'
        Title    = 'Getting ready'
    }
    @{
        File      = 'packages.ps1'
        Function  = 'Invoke-PackagesPhase'
        Title     = 'Packages'
        Uninstall = $true
    }
    @{
        File      = 'registry-system.ps1'
        Function  = 'Invoke-RegistrySystemPhase'
        Title     = 'System settings'
        Uninstall = $true
    }
    @{
        File      = 'registry-explorer.ps1'
        Function  = 'Invoke-RegistryExplorerPhase'
        Title     = 'File Explorer tweaks'
        Uninstall = $true
    }
    @{
        File      = 'registry-taskbar-search.ps1'
        Function  = 'Invoke-RegistryTaskbarSearchPhase'
        Title     = 'Taskbar, search & start tweaks'
        Uninstall = $true
    }
    @{
        File      = 'edge.ps1'
        Function  = 'Invoke-EdgePhase'
        Title     = 'Microsoft Edge tweaks'
        Uninstall = $true
    }
    @{
        File     = 'fonts.ps1'
        Function = 'Invoke-FontsPhase'
        Title    = 'Fonts'
    }
    @{
        File      = 'terminal.ps1'
        Function  = 'Invoke-TerminalPhase'
        Title     = 'Windows Terminal'
        Uninstall = $true
    }
    @{
        File      = 'powershell-profile.ps1'
        Function  = 'Invoke-PowerShellProfilePhase'
        Title     = 'PowerShell profile'
        Uninstall = $true
    }
    @{
        File      = 'copilot.ps1'
        Function  = 'Invoke-CopilotPhase'
        Title     = 'GitHub Copilot'
        Uninstall = $true
    }
    @{
        File      = 'wsl.ps1'
        Function  = 'Invoke-WslPhase'
        Title     = 'WSL + Ubuntu'
        Uninstall = $true
    }
)
if ($Action -eq 'Partial') {
    $phases = @($phases | Where-Object { $_.File -ne 'edge.ps1' })
    ($phases | Where-Object { $_.File -eq 'registry-taskbar-search.ps1' }).Title = 'Taskbar & Start tweaks'
} elseif ($Action -eq 'Uninstall') {
    $phases = @($phases | Where-Object { $_['Uninstall'] })
    # Remove tools after the cleanup steps that need them.
    $phases = @($phases | Where-Object { $_.File -ne 'packages.ps1' }) +
        @($phases | Where-Object { $_.File -eq 'packages.ps1' })
}

$operation = if ($Action -eq 'Uninstall') { 'cleanup' } else { 'setup' }
Write-Host ''
if ($Action -eq 'Uninstall') {
    Write-Host 'Calm OS cleanup -- resetting settings and removing developer tools' -ForegroundColor Cyan
    Write-Host 'Ubuntu and its files will be deleted. Targeted tools are removed even if they predate setup.' -ForegroundColor Yellow
    Write-Host 'Some uninstallers may request Administrator approval.' -ForegroundColor DarkGray
} elseif ($Script:DevConfigResumed) {
    Write-Host "Welcome back. Resuming Calm OS setup ($Action) after the reboot..." -ForegroundColor Cyan
} else {
    Write-Host "Calm OS setup ($Action) -- $($phases.Count) phases, one reboot along the way (expected, not an error)" -ForegroundColor Cyan
}

$failure = $null
try {
    # Every phase file is loaded before any of them runs, so the elevated process is not still reading new code off disk minutes in.
    $loadedPhases = @()
    foreach ($phase in $phases) {
        $path = Join-Path $stepsDir $phase.File
        if (-not (Test-Path -LiteralPath $path)) {
            if ($Action -eq 'Uninstall') {
                throw "The cleanup script is missing: $path. Run bootstrap.ps1 -Action Uninstall to reinstall it."
            }
            Write-Host "-- $($phase.File) not written yet, skipping" -ForegroundColor DarkGray
            continue
        }
        . $path
        $loadedPhases += $phase
    }

    $phaseIndex = 0
    foreach ($phase in $loadedPhases) {
        $phaseIndex++

        # Script-scoped phase metadata avoids passing header state through every phase file.
        $Script:DevConfigPhaseIndex       = $phaseIndex
        $Script:DevConfigPhaseTotal       = $loadedPhases.Count
        $Script:DevConfigPhaseTitle       = $phase.Title
        $Script:DevConfigPhaseHeaderShown = $false

        if ($phase.File -eq 'wsl.ps1') {
            # The WSL phase registers resume using this orchestrator path.
            Invoke-WslPhase -OrchestratorPath $PSCommandPath
        } else {
            & $phase.Function
        }

        if ($phase.File -eq 'packages.ps1') {
            # New package locations are visible in this process only after PATH is refreshed.
            Update-DevConfigSessionPath
        }
    }

    Show-DevConfigSilentSkipSummary
    Write-Host ''
    Write-Host "Calm OS $operation complete." -ForegroundColor Green
    $tally = $Script:DevConfigTally
    $summaryParts = @("$($tally.Done) changed", "$($tally.AlreadyOk) already up to date")
    if ($tally.Warned -gt 0) {
        $summaryParts += "$($tally.Warned) flagged"
    }
    Write-Host "  $($summaryParts -join ', ')" -ForegroundColor DarkGray
    # Names are shown because the detailed flags may have scrolled off screen.
    if ($tally.Warned -gt 0) {
        Write-Host "  Flagged: $($Script:DevConfigWarnedSteps -join ', ')" -ForegroundColor Yellow
        Write-Host '  These were skipped or could not be confirmed. Running this again retries just those.' -ForegroundColor DarkGray
    }
    if ($Action -ne 'Uninstall' -and (Get-DevConfigTerminalFontRunOnceCommand)) {
        Write-Host '  The Terminal font will change at your next sign-in; no setup rerun is needed.' -ForegroundColor DarkGray
    }
    Write-Host '  A few Explorer and taskbar changes appear once you sign out and back in.' -ForegroundColor DarkGray
} catch {
    $failure = $_
}

if ($failure) {
    Write-Host ''
    Write-Host "Calm OS $operation stopped early." -ForegroundColor Red
    Write-Host "  $($failure.Exception.Message)" -ForegroundColor Red
    $origin = $failure.InvocationInfo
    if ($origin -and $origin.ScriptName) {
        Write-Host "  ($(Split-Path -Leaf $origin.ScriptName) line $($origin.ScriptLineNumber))" -ForegroundColor DarkGray
    }
    Write-Host '  Nothing already applied was undone -- running this again picks up where it left off.' -ForegroundColor DarkGray
}

$logPath = Get-DevConfigLogPath
if ($logPath) {
    Write-Host "  Full log: $logPath" -ForegroundColor DarkGray
}

# Close the log before releasing the lock so another run can start while this window waits.
Stop-DevConfigLog
Exit-DevConfigSingleInstance

# The elevated window owns the final pause on both the initial and resumed runs.
Wait-DevConfigKeyPress

if ($failure) {
    exit 1
}

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDPZ/O9lzMGYGnE
# s1A1d44xQ4zTaeDoIdtb4MqOXbx6tqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIKAj+pHmZ4qC63WgVaR24VnFbP9PwTI4mLn0MTnXQ85WMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAIFfdBo01WJID+f44
# WpRgch1/wZQCtDl5vr7YcEx+Y/b96ECjYzXDdP+6IzBchLBdqNlPHxFoBcZoe5dA
# Z17ufjF4kHZif6P3QcV7djQpCWWF4+FOuVF5KJsmKa3Vs6io/GOFmgRp/Ats3i6k
# frex/S7PMA4f7Gz7ksvjmkLM6fFRBUvbcg60oeJTpp7qUksSEv5OlQJ4q0fI67pr
# i33zHeXTKAzBNUxm1bqsCJB++obqUkn8heGuOJxmHBV7H3zTQdj5DwOOHteB9IPX
# zDeuoGhHROEFb5x3xZGh2IXY0Lu1S7PCUmiF42pciRi6/DKKtyy4gIGmQKyXIiyZ
# lYopd6GCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCVr1DQhpWV8lNB
# XU/E2+xEC+M8D8Dq9sewlPz8EIttxgIGaqnPC8XiGBMyMDI2MDkyNTAwMjIyNy4y
# MTRaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAiQ7hCGwLKxkIgABAAACJDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTla
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj
# 6W3UaQ2Zr4hNvSy7j7UMPFVys7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrL
# QCOZcgLvz6FkqmghzQxzmkgKtLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcV
# iBX4LcHk38RusZiF7wxSa5t/Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9
# pU9uriGdDxfJXn/lc49CxbXqA3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfd
# rA29sWTSNKig9CtBC5tzQj0flbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjl
# yUP9ZO38839NwSuiHtvsFCNkTNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PD
# ERyrAs0pvfUWOLapVQajHPoCnuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8W
# wBtk3Yxyhjj0GXw909i0EkTkVyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1Y
# GnYwCjIwa5/lMW0pFn/HpJdB6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v
# 3E9kwN9VBC+wJESBECC1gZMCS5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3
# SNt0a0Q5Nc2Ul+rMlQxXoP9isXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFHMfkX1u/zJLCMe0gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA+wHSbmhIpM8CRVZ4tk624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko
# 6diEDHXPNWvAagxastCewPzm5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/
# Fwps1sbNUEu7Bzg004qULIVJ963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQT
# HZgwuNB6QhcEEsgogLVwNRj37VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi
# 6jlcfqfo619uDH9r8k2qAOHCeEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilU
# Son07wjHu0e0ssBmtBafPb4Gd+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oc
# zxC/4JT3Hf45JEtszToXwNskV3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGE
# lPl5GRoPtJiDEvRIbv5MFKIw2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOk
# X4ug0/0mN2CSarhuSi9NmHIOpUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1o
# bjAGKdWMPCrlSyNAs0jZYzkha535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbU
# VqMU1OrQbHfdyzJpbhJC1PbAZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMC
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+
# 46CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7mApojAiGA8yMDI2MDkyNDIyNTg0MloYDzIwMjYwOTI1MjI1ODQy
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuYCmiAgEAMAoCAQACAiUnAgH/MAcC
# AQACAhMlMAoCBQDuYXsiAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAFR+
# M3qx2CXV/BIqf0cMtlD2Y7SMYwFNN06VT6GJlCpusFiZX56Ic57PUu+7JwMrybMP
# o9/TCxzm3CRfI2UVDN4wZyUmPTj+ZxbYlsGP7jw+Yg6cYFycdHx3T3EBKlt0ZIhS
# DaeH3ywvKYChSGDXyaYMirxhzVCkYqM4aV8hukNG700XtZI0BTleGH3kiBGEME01
# Q9o6eWz8z+2xgTGA8j6XwyNzGHQNLPYetzboiviaj13gjY8gHpzEUE4nob0dWTig
# BVIBtVTbs6K3qxb8m29Kvy8jNb1vXH/2GiMZ1ByJoU3J6DyOhePT5BxFTu2S+vPG
# qHN6REiBds3GOkoNch4xggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiQ7hCGwLKxkIgABAAACJDANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDo
# ydw3R9xJrOBLY1TDq3/CLDXkSHdSAF5he6WukKMvFzCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIEghPTdqm/dRyZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCys
# ZCIAAQAAAiQwIgQg/Dp0wDpjwNRab3fEQGIIPHhGsut2Te1OTh7Y6BJvUdUwDQYJ
# KoZIhvcNAQELBQAEggIAMg/G+t/nU0ncVaV9RmJ1Tc6yLxzJmRJ1hnjPSn8JvSEM
# ESPIdA+q/ek8G+7rhhMFvUuE+ynvr1Zp/kVLrj/AXIXWCQSmbHWUF+SPiGVzh0ji
# ISZQ7cgZOU5a3bTCmD6AW1KN/v+zeZ4vaLOR8e/C3zS2WB43enuGRlDfsIPibefd
# Dd2ASUrCdiAQsUuS7ZxIQqKICp8zV1QF5nurfqwiDu4I/bh4UL3YaN+R+haGLHVw
# qnjxEAhvn8sKcTgikOl+JYdQJs2qJeV/0c4WNKweBIeLwP4UJSmry8hCoYDKN56n
# umgr0QDUEYHrB7m/LYGEYrQqE40/O7tmXZIQm9fzx6bNH3naavymkOE26JZK2WlK
# xT3TzEb5XiaoglAEBFqKCMtgLpc2TR4gykYXY9+tcLsmqfy9p7vlRIZKOlRE26z8
# lvsDV0THkY1E8nwHs0k3qPRPBH7nC2DrRy2vTpG9vSItPw6BrojbAiZikkHgHlsT
# 4FEUaCQVLWrg0zulfqNQnIGkF1N6SnSUliUtquikXIQURevZviEyi6VFbjX9CJSK
# oZBNO3UgzpMHH/bH6vpYdxsTaRUm8c4gZFcxbGAfJp8un4umkXsMtPWRWbQQxvWd
# v73J5kYJ0ZjJiGsWNd/Q53MDrievgnK6JYjKCZ/JrnwK28PHwiYNcCN1TAXPYjg=
# SIG # End signature block
