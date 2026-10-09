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
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCX91eeDvw7kLr+
# gCjsjvvXvWpBaa/IJiA56JwA65YTQKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIHJskenK3bEIP1B6SY+gqkSgiW/T
# qJcgZRej/9662vH7MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAvbXiM+3rIKCkSGvkdEf3MoOoKooOBwMz2yODrrDPHj3Br/UYd5KW9ivEK5Lq
# ens9YUgYz/MXpcJY52lqlLsjG9MAuIRnR8tADA9lNq4UBHOd9L4ndnJy750mIJgg
# wdRQcKMynVahT8h6T7fW4BuOvrv9FuKjffK+iL+Fs5dY4nU5NmPyOocnNuzxY8Kt
# 52sgBC6Ki+ZOITuSzUY4FxC4U1owY0uYR8TNbrrd/5cAgtv4/5AMUFWi/qW8Q4IZ
# lCdNDv5EdvsBi8OZOoIDNnTLuunqX3J4JGDJy7kddnw6pGXeqrqENhjwb01sCLmh
# tc0iSr9gk5eT6NdfrifCsk3dPqGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCADILt2CZqtNrbkJzVWpFuRxIJ0Iv8/2JennRq9DZueqgIGaq9VSzmsGBMy
# MDI2MTAwOTIxNDQ1NS4wODVaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACFRgD04EHJnxTAAEAAAIVMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyMFoXDTI2MTExMzE4NDgyMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjY1MUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAw3HV3hVxL0lEYPV03XeNKZ51
# 7VIbgexhlDPdpXwDS0BYtxPwi4XYpZR1ld0u6cr2Xjuugdg50DUx5WHL0QhY2d9v
# kJSk02rE/75hcKt91m2Ih287QRxRMmFu3BF6466k8qp5uXtfe6uciq49YaS8p+dz
# v3uTarD4hQ8UT7La95pOJiRqxxd0qOGLECvHLEXPXioNSx9pyhzhm6lt7ezLxJeF
# VYtxShkavPoZN0dOCiYeh4KgoKoyagzMuSiLCiMUW4Ue4Qsm658FJNGTNh7V5qXY
# VA6k5xjw5WeWdKOz0i9A5jBcbY9fVOo/cA8i1bytzcDTxb3nctcly8/OYeNstkab
# /Isq3Cxe1vq96fIHE1+ZGmJjka1sodwqPycVp/2tb+BjulPL5D6rgUXTPF84U82R
# LKHV57bB8fHRpgnjcWBQuXPgVeSXpERWimt0NF2lCOLzqgrvS/vYqde5Ln9YlKKh
# AZ/xDE0TLIIr6+I/2JTtXP34nfjTENVqMBISWcakIxAwGb3RB5yHCxynIFNVLcfK
# AsEdC5U2em0fAvmVv0sonqnv17cuaYi2eCLWhoK1Ic85Dw7s/lhcXrBpY4n/Rl5l
# 3wHzs4vOIhu87DIy5QUaEupEsyY0NWqgI4BWl6v1wgse+l8DWFeUXofhUuCgVTuT
# HN3K8idoMbn8Q3edUIECAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSJIXfxcqAwFqGj
# 9jdwQtdSqadj1zAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAd42HtV+kGbvxzLBT
# C5O7vkCIBPy/BwpjCzeL53hAiEOebp+VdNnwm9GVCfYq3KMfrj4UvKQTUAaS5Zkw
# e1gvZ3ljSSnCOyS5OwNu9dpg3ww+QW2eOcSLkyVAWFrLn6Iig3TC/zWMvVhqXtdF
# hG2KJ1lSbN222csY3E3/BrGluAlvET9gmxVyyxNy59/7JF5zIGcJibydxs94JL1B
# tPgXJOfZzQ+/3iTc6eDtmaWT6DKdnJocp8wkXKWPIsBEfkD6k1Qitwvt0mHrORah
# 75SjecOKt4oWayVLkPTho12e0ongEg1cje5fxSZGthrMrWKvI4R7HEC7k8maH9eP
# A3ViH0CVSSOefaPTGMzIhHCo5p3jG5SMcyO3eA9uEaYQJITJlLG3BwwGmypY7C/8
# /nj1SOhgx1HgJ0ywOJL9xfP4AOcWmCfbsqgGbCaC7WH5sINdzfMar8V7YNFqkbCG
# UKhc8GpIyE+MKnyVn33jsuaGAlNRg7dVRUSoYLJxvUsw9GOwyBpBwbE9sqOLm+Hs
# O00oF23PMio7WFXcFTZAjp3ujihBAfLrXICgGOHPdkZ042u1LZqOcnlr3XzvgMe+
# mPPyasW8f0rtzJj3V5E/EKiyQlPxj9Mfq2x9himnlXWGZCVPeEBROrNbDYBfazTy
# LNCOTsRtksOSV3FBtPnpQtLN754wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAj6eTejbuYE1Ifjbfrt6tXevCUSCggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5zhsUwIhgPMjAyNjEwMDkxNTI5MDlaGA8yMDI2MTAxMDE1MjkwOVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nOGxQIBADAHAgEAAgIgpzAHAgEAAgITCzAKAgUA
# 7nTYRQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQBpzkfzM6YgDeICeoT6
# 0u4b1MZteXSwfJM/R3l9aWxZwZZz44g3cDZDDjehZE2r5xHUEFIAf3VCzqdSR8Et
# 23KZhb5dCwOe2o1+sdZiqEtGKrIOTYnFU+nqJLqOXqoW26Oxd+uhQA2bP2Lg3p1l
# Gi5y4S0YYKAhZ/fhTN4uPeP9SDvjsFuv/T9pagJWMDafqPP1DGkuL6ISWBJNaNNn
# SRxNXjFuPHE1j/3pAEuDuidwnZNm8sXe1vw9A7Goz/Gqh3U1TvWW3IW1+P+pjIbk
# AFZXMucXbpamzI0EtECutguzZStJGVohKtWyEeXVmkuexv/bNiy+MTZwTikGe8WG
# Vaq3MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIVGAPTgQcmfFMAAQAAAhUwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg3Ga3+HoZzdgcW5z5
# +rVPxQRNcdTnMtQAEUAXZevDVYEwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCBwEPR2PDrTFLcrtQsKrUi7oz5JNRCF/KRHMihSNe7sijCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACFRgD04EHJnxTAAEAAAIVMCIE
# IBP2+IA2N+LEWDFlb1vCiUuipWtfWJsyx4KO1U0cTUtcMA0GCSqGSIb3DQEBCwUA
# BIICAIKo5+Ie/nNLMz9Tqtu4UGrxN6zBv8dtOz3Ih2rA18omD31ulG/HtSqjhP5w
# ngpAYUbOIQa3r9N3Bk209L7KdSBQB72gyR4URcwC60M8X+CxMqSMKQjqCLUwFZBv
# FpkLC/XPQ+G446QZtbWbLnavVk8rl2oIVJeCm78E63o+vMOfamL2RYWekXl+TlL5
# iicpgtz9BRym8Z5G+TlXirkJLYkQM+SZrjzHhvztVeqeYb3ghChUzS9kttgSl7Ri
# HYPFQ0HYC3IhfxGSxJDumWtp37hozeJw/IvSYRPrnILmYustXMsFNvbUtxmsikG6
# 1HMeIo/BuBdY/N5p47VLsP7Axpjo+VrQsrdhmsshYgjIzPIoUuRaVmMQNNFQ5SES
# 6BOgxh1K/UD0qUcccos8vq8YPVvbsrj8bIyukWS6mxAhSWYXOInpy/4d1LDQCI9i
# 1BU4QCdbix2E6wh+Gf237TCRIrzDWREC6LG0CR83WWPTtKwIsSRh7ItBrbdXqBPD
# 59G6MHg6IiJ4TZ+7EumED3PUY5xmcEAjALfpJbfP23q+LHVnCHfZIiHpQBA07wD0
# qoSjb7WU/d88FKQbm4trQCtNkJUZJuTxh1QlRTTltWvSQKfk0UUkf9P4llswVqgP
# 3WfbSjH66nk5VMfGkNYO1LytEqG1cNodctQYvcr9DLd34cHm
# SIG # End signature block
