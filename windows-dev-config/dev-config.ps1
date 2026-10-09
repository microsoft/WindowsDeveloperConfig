<#
.SYNOPSIS
  Configures or cleans up a Windows developer workstation, or applies one developer workload.

.DESCRIPTION
  -Workload picks a definition from workloads\. The default, devconfig, is the complete
  Windows Dev Config setup; other workloads, such as winui, reuse the same phases, helpers,
  elevation, logging, and summary.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed,
    [switch] $AllowUnsigned,
    [switch] $ApplyTerminalFont,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A child shell can inherit incompatible built-in modules from another PowerShell edition.
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

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
. (Join-Path $stepsDir '_workload.ps1')

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

# The workload decides which phases run; everything else in this script is shared by every workload.
$Workload = $Workload.ToLowerInvariant()
$Script:DevConfigWorkload = $Workload
try {
    $definition = Get-DevConfigWorkload -Directory (Join-Path $PSScriptRoot 'workloads') -Workload $Workload -Action $Action
} catch {
    # Pause so the reason stays readable when this runs in a window that closes on exit.
    Write-Host $_.Exception.Message -ForegroundColor Red
    Wait-DevConfigKeyPress
    exit 1
}
$workloadName = $definition['Name']

# TLS is configured before any download step runs.
Enable-DevConfigModernTls

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload

if ($Action -eq 'Uninstall') {
    Invoke-DevConfigEnsureCleanupShell -ScriptPath $PSCommandPath -AllowUnsigned:$AllowUnsigned -Workload $Workload
} else {
    # WinGet module behavior is more consistent in PowerShell 7 than in Windows PowerShell 5.1.
    Invoke-DevConfigEnsurePwsh -ScriptPath $PSCommandPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload
}

# The lock starts after relaunches so the worker process owns the log file.
# Workloads share one lock because they install through the same WinGet and registry paths.
if (-not (Enter-DevConfigSingleInstance)) {
    Write-Host ''
    Write-Host 'Setup is already running in another window.' -ForegroundColor Yellow
    Write-Host 'Switch to it rather than starting a second copy -- they would fight over the same installs.' -ForegroundColor DarkGray
    Wait-DevConfigKeyPress
    exit 1
}

Start-DevConfigLog -Path (Join-Path $PSScriptRoot "$Workload-log.txt") -Append:$Resumed

# Any prior resume task for this workload is stale once this run starts.
Clear-DevConfigResume

$Script:DevConfigResumed = [bool]$Resumed -and $Action -ne 'Uninstall'
$Script:DevConfigAction = $Action
if ($Script:DevConfigResumed) {
    # Restore the pre-reboot tally so the final summary covers the whole run.
    Restore-DevConfigTally -Path (Get-DevConfigTallyPath -Directory $PSScriptRoot)
}
$phases = @($definition['Phases'])

$operation = if ($Action -eq 'Uninstall') { 'cleanup' } else { 'setup' }
Write-Host ''
if ($Action -eq 'Uninstall') {
    Write-Host "$workloadName cleanup -- resetting settings and removing developer tools" -ForegroundColor Cyan
    if ($definition['UninstallWarning']) {
        Write-Host $definition['UninstallWarning'] -ForegroundColor Yellow
    }
    Write-Host 'Some uninstallers may request Administrator approval.' -ForegroundColor DarkGray
} elseif ($Script:DevConfigResumed) {
    Write-Host "Welcome back. Resuming $workloadName setup ($Action) after the reboot..." -ForegroundColor Cyan
} else {
    $setupNote = if ($definition['SetupNote']) { ", $($definition['SetupNote'])" } else { '' }
    Write-Host "$workloadName setup ($Action) -- $($phases.Count) phases$setupNote" -ForegroundColor Cyan
}

$failure = $null
try {
    # Load phase files and check function and parameter names before running any phase.
    foreach ($phase in $phases) {
        $path = Join-Path $stepsDir $phase.File
        if (-not (Test-Path -LiteralPath $path)) {
            $rerun = "bootstrap.ps1 -Action $Action"
            if ($Workload -ne 'devconfig') { $rerun += " -Workload $Workload" }
            throw "The $operation script is missing: $path. Run $rerun to reinstall it."
        }
        . $path
        $null = Resolve-DevConfigWorkloadPhase -Phase $phase -OrchestratorPath $PSCommandPath
    }

    $phaseIndex = 0
    foreach ($phase in $phases) {
        $phaseIndex++

        # Script-scoped phase metadata avoids passing header state through every phase file.
        $Script:DevConfigPhaseIndex       = $phaseIndex
        $Script:DevConfigPhaseTotal       = $phases.Count
        $Script:DevConfigPhaseTitle       = $phase.Title
        $Script:DevConfigPhaseHeaderShown = $false

        Invoke-DevConfigWorkloadPhase -Phase $phase -OrchestratorPath $PSCommandPath

        # New tool locations are visible in this process only after PATH is refreshed.
        Update-DevConfigSessionPath
    }

    Show-DevConfigSilentSkipSummary
    Write-Host ''
    Write-Host "$workloadName $operation complete." -ForegroundColor Green
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
    # Notes raised by steps come before the workload's standing notes.
    foreach ($note in $Script:DevConfigNotes) {
        $color = if ($note.Warning) { 'Yellow' } else { 'DarkGray' }
        Write-Host "  $($note.Message)" -ForegroundColor $color
    }
    foreach ($note in @($definition['Notes'] | Where-Object { $_ })) {
        Write-Host "  $note" -ForegroundColor DarkGray
    }
} catch {
    $failure = $_
}

if ($failure) {
    Write-Host ''
    Write-Host "$workloadName $operation stopped early." -ForegroundColor Red
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
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCX91eeDvw7kLr+
# gCjsjvvXvWpBaa/IJiA56JwA65YTQKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIHJskenK3bEIP1B6SY+gqkSgiW/TqJcgZRej/9662vH7MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAg/LPQ6RGqdBnnqHN
# NPNpM16ggEIWf053Q+ntnyzLMJf9iNrtKd+CydCJfejVzc/Uf1kkOxHtbiYTxNPx
# v9h35RkUivWIDPIACTINoKoVHXFxC49xvjVAuDzd8bPu8wTJxEATAzTGVOCo9I6C
# CAZXUNP5xIvp+md+03pHMT3odf88w7kcDHS8QlR53B1hcIy6mF35Y6UH2O4g5Rh5
# t+0Rf7HUVfOTtf480SBS+2JXm+DzgGLCrKqHTcQ0IPfDyBWCbkkaqeHqPkBF05Ik
# BS3wVU5hRjABZZCuGgRQVbo3lqQKFaNQJJx0gE3F7yZDiZ3dVCW7dHmf2T4Fbae3
# Ur23sqGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCwsZX7NXiUM5CX
# jqZ3uSrPX2p+dWE87yZiNyNtSt09JAIGasTlBPu0GBMyMDI2MTAwOTAwMTc0Mi40
# NDZaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACGqmgHQagD0OqAAEAAAIaMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyOFoXDTI2MTEx
# MzE4NDgyOFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjMyMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAmYEAwSTz79q2V3ZWzQ5Ev7RKgadQtMBy7+V3XQ8R0NL8
# R9mupxcqJQ/KPeZGJTER+9Qq/t7HOQfBbDy6e0TepvBFV/RY3w+LOPMKn0Uoh2/8
# IvdSbJ8qAWRVoz2S9VrJzZpB8/f5rQcRETgX/t8N66D2JlEXv4fZQB7XzcJMXr1p
# uhuXbOt9RYEyN1Q3Z7YjRkhfBsRc+SD/C9F4iwZqfQgo82GG4wguIhjJU7+XMfrv
# 4vxAFNVg3mn1PoMWGZWio+e14+PGYPVLKlad+0IhdHK5AgPyXKkqAhEZpYhYYVEI
# tHOOvqrwukxVAJXMvWA3GatWkRZn33WDJVtghCW6XPLi1cDKiGE5UcXZSV4OjQIU
# B8vp2LUMRXud5I49FIBcE9nT00z8A+EekrPM+OAk07aDfwZbdmZ56j7ub5fNDLf8
# yIb8QxZ8Mr4RwWy/czBuV5rkWQQ+msjJ5AKtYZxJdnaZehUgUNArU/u36SH1eXKM
# QGRXr/xeKFGI8vvv5Jl1knZ8UqEQr9PxDbis7OXp2WSMK5lLGdYVH8VownYF3sbO
# iRkx5Q5GaEyTehOQp2SfdbsJZlg0SXmHphGnoW1/gQ/5P6BgSq4PAWIZaDJj6AvL
# LCdbURgR5apNQQed2zYUgUbjACA/TomA8Ll7Arrv2oZGiUO5Vdi4xxtA3BRTQTUC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBTwqyIJ3QMoPasDcGdGovbaY8IlNjAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEA1a72WFq7B6bJT3VOJ21nnToPJ9O/q51bw1bh
# PfQy67uy+f8x8akipzNL2k5b6mtxuPbZGpBqpBKguDwQmxVpX8cGmafeo3wGr4a8
# Yk6Sy09tEh/Nwwlsyq7BRrJNn6bGOB8iG4OTy+pmMUh7FejNPRgvgeo/OPytm4NN
# rMMg98UVlrZxGNOYsifpRJFg5jE/Yu6lqFa1lTm9cHuPYxWa2oEwC0sEAsTFb69i
# KpN0sO19xBZCr0h5ClU9Pgo6ekiJb7QJoDzrDoPQHwbNA87Cto7TLuphj0m9l/I7
# 0gLjEq53SHjuURzwpmNxdm18Qg+rlkaMC6Y2KukOfJ7oCSu9vcNGQM+inl9gsNgi
# rZ6yJk9VsXEsoTtoR7fMNU6Py6ufJQGMTmq6ZCq2eIGOXWMBb79ZF6tiKTa4qami
# 3US0mTY41J129XmAglVy+ujSZkHu2lHJDRHs7FjnIXZVUE5pl6yUIl23jG50fRTL
# QcStdwY/LvJUgEHCIzjvlLTqLt6JVR5bcs5aN4Dh0YPG95B9iDMZrq4rli5SnGNW
# ev5LLsDY1fbrK6uVpD+psvSLsNpht27QcHRsYdAMALXM+HNsz2LZ8xiOfwt6rOsV
# WXoiHV86/TeMy5TZFUl7qB59INoMSJgDRladVXeT9fwOuirFIoqgjKGk3vO2bELr
# YMN0QVwwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUA8YrutmKpSrubCaAYsU4pt1Ft8DaggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5yrvEwIhgPMjAyNjEw
# MDkwMDA4MTdaGA8yMDI2MTAxMDAwMDgxN1owdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7nKu8QIBADAHAgEAAgI15zAHAgEAAgIS1TAKAgUA7nQAcQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAc+qukPad4ovYXkbNhB0MrRVtFqYsy82KIsrHC
# QT90dtDfUnR3wKaKNOJ+9U1t3Fxw/c1fpBqXu+/UbQM/vQPbA7vHmnxzLAvRS4N6
# Qku0XW9d+S7y+5ogeE+GOt9UdoZS9tUhxtbdj/oZ8h9nicZVkVo6iGfeMIypRUsx
# v6JnjvBsnslILFSEPD0dJnnP/ohT4hju5sqEnTHatCWh2a4FoM0bvyXtyxz6bTcC
# Fwq177BjCtxCpYIAqLca3J8GXyvCn24JijxgcbaaK49F/6OukBaQJTsgGuRpPZWG
# YQTAaAn7NhCIc5GffwHxHFKI9g81XSE2LrkX/DNkfyWJhnrjMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIaqaAdBqAPQ6oA
# AQAAAhowDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgUztsyu/v913150q3QrbnsDVFfXL1p+uuLt3k
# ZDPQLGswgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCdeiHHrbtpKcwB20do
# VU89WHIOH8S7w37uaHcDmemK+zCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACGqmgHQagD0OqAAEAAAIaMCIEIA/+mnbzs4Gob/wcGfet
# a/6kHlF44rAWJmZCWUrEqC57MA0GCSqGSIb3DQEBCwUABIICAAGk/RVf8tvVk1gw
# NfuFJnJlPK63N9I28+ELP81T3D7pq62iX1DeioQxjcO3aXfrIqU2uhAiNCds81qV
# uDTE5PA9iQq5sEg0bQeVoBlq+E3mqpx98GZ8D0bNPOdpUPyaicVlnssj031eikTz
# t3ZwuNAS6zE01JPupu/g83INpg5uaIXNAR9o4uQmS0Ijqgq3HFeivVHTp1Z3Da2y
# 95sjiANTI5VGsFbFoxpt5M4dzm9UDX/Z8FNZbNXSrWbN4NIjlbZ4ecqvlqiLJFYL
# lemNH7v/hc9INFafYWoGxXNaybAKrScNKUDSgmovXBqnuch+bgpaMla9k1+KlCqz
# NALLgVBWI/lDNkM3Tkh4q/FOcRv0/S4rhmLJ+OMkfgHDqXNyRP5MJ3IUKyoz8hZB
# HfEoa3oSltQ1PYcAqARlxs4DVv75sQ+MGMuYfrfg+WcYvw2QmYQDKRsMXZPo/6za
# f79VWIDFjI9Q0+mvqW3piHhSxcws+a4SnRLs43mq3VtNWo+LWv6dp1nq4wVpKFRz
# 81SbtvUZgWDQ5b7ieYGzgksall6R/RqMWaNIQjl7HF5pW4nmiOybbJCKT89WFaN1
# RCmAYNAh9qZY9sdpy+sFa+p6o/jOT9gqAVLuCYPNg5wokv1gDy9SAm6gOarg4vMM
# DMsfupq4EM+ceCKhMi6zf6xYuCZ9
# SIG # End signature block
