<#
.SYNOPSIS
  Configures a Windows developer workstation and resumes after the WSL reboot.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed,
    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $AllowUnsigned -and (Get-ExecutionPolicy) -ne 'AllSigned') {
    throw 'Signed setup requires AllSigned. Launch PowerShell with -ExecutionPolicy AllSigned; Group Policy may override it. Use -AllowUnsigned only for development.'
}

# Windows PowerShell 5.1 defaults to ANSI; force UTF-8 for console symbols.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

$stepsDir = Join-Path $PSScriptRoot 'steps'
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

# TLS is configured before any download step runs.
Enable-DevConfigModernTls

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned

# WinGet module behavior is more consistent in PowerShell 7 than in Windows PowerShell 5.1.
Invoke-DevConfigEnsurePwsh -ScriptPath $PSCommandPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned

# The lock starts after relaunches so the worker process owns the log file.
if (-not (Enter-DevConfigSingleInstance)) {
    Write-Host ''
    Write-Host 'Calm OS setup is already running in another window.' -ForegroundColor Yellow
    Write-Host 'Switch to it rather than starting a second copy -- they would fight over the same installs.' -ForegroundColor DarkGray
    Wait-DevConfigKeyPress
    exit 1
}

Start-DevConfigLog -Path (Join-Path $PSScriptRoot 'devconfig-log.txt') -Append:$Resumed

# Any prior resume task is stale once this run starts.
Clear-DevConfigResume

$Script:DevConfigResumed = [bool]$Resumed
$Script:DevConfigAllowUnsigned = [bool]$AllowUnsigned
if ($Script:DevConfigResumed) {
    # Restore the pre-reboot tally so the final summary covers the whole run.
    Restore-DevConfigTally -Path (Join-Path $PSScriptRoot 'devconfig-tally.json')
}
Write-Host ''
if ($Script:DevConfigResumed) {
    Write-Host 'Welcome back. Resuming Calm OS setup after the reboot...' -ForegroundColor Cyan
} else {
    Write-Host 'Calm OS setup -- 11 phases, one reboot along the way (expected, not an error)' -ForegroundColor Cyan
}

# WSL stays last so its required reboot happens after other phases.
$phases = @(
    @{ File = 'prerequisites.ps1';           Function = 'Invoke-PrerequisitesPhase';          Title = 'Getting ready' }
    @{ File = 'packages.ps1';               Function = 'Invoke-PackagesPhase';               Title = 'Packages' }
    @{ File = 'registry-system.ps1';         Function = 'Invoke-RegistrySystemPhase';         Title = 'System settings' }
    @{ File = 'registry-explorer.ps1';       Function = 'Invoke-RegistryExplorerPhase';       Title = 'File Explorer tweaks' }
    @{ File = 'registry-taskbar-search.ps1'; Function = 'Invoke-RegistryTaskbarSearchPhase';  Title = 'Taskbar, search & start tweaks' }
    @{ File = 'edge.ps1';                    Function = 'Invoke-EdgePhase';                   Title = 'Microsoft Edge tweaks' }
    @{ File = 'fonts.ps1';                   Function = 'Invoke-FontsPhase';                  Title = 'Fonts' }
    @{ File = 'terminal.ps1';                Function = 'Invoke-TerminalPhase';               Title = 'Windows Terminal' }
    @{ File = 'powershell-profile.ps1';      Function = 'Invoke-PowerShellProfilePhase';      Title = 'PowerShell profile' }
    @{ File = 'copilot.ps1';                 Function = 'Invoke-CopilotPhase';                Title = 'GitHub Copilot' }
    @{ File = 'wsl.ps1';                     Function = 'Invoke-WslPhase';                    Title = 'WSL + Ubuntu' }
)

$failure = $null
try {
    # Every phase file is loaded before any of them runs, so the elevated process is not still reading new code off disk minutes in.
    $loadedPhases = @()
    foreach ($phase in $phases) {
        $path = Join-Path $stepsDir $phase.File
        if (-not (Test-Path -LiteralPath $path)) {
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
    Write-Host 'Calm OS setup complete.' -ForegroundColor Green
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
    Write-Host '  A few Explorer and taskbar changes appear once you sign out and back in.' -ForegroundColor DarkGray
} catch {
    $failure = $_
}

if ($failure) {
    Write-Host ''
    Write-Host 'Calm OS setup stopped early.' -ForegroundColor Red
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

# Release the run lock before the final pause so a completed run does not block the next start.
Exit-DevConfigSingleInstance

# The elevated window owns the final pause on both the initial and resumed runs.
Wait-DevConfigKeyPress

Stop-DevConfigLog
if ($failure) {
    exit 1
}

# SIG # Begin signature block
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCALliXxMzCgGIHv
# BjMaFWUo0idVd1pzFih3CNUaZCnspaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIG8+lEP5ZLwORlqq6K33iF3b3MrWXeeCi7/PH2cw50irMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEA0Fvi4ZPZHLS0VUkl
# uUrS1yy3NuFs55mNcwA1L1VlveRAJnrRgnHPwfMFBRx68uN32S5jiru7BDgXBLWG
# x8mLU4BhiCJ4u+ahEE65joorxXEJc879ROYboiZSEroaql6dF1od4+Cp2ryHs/+j
# lXd0YG5vUylKIEVeeoWnvnBBlEuf/OE0wOOost3PgBqQPbLiUySUGgvkvQ64/462
# eZer14MFhAfuo26hnspXLdb4kimLh4e9+F7lyAWb1p4gSkwmakV1WmwOtVcTK1Dh
# hV9PwkojJpytEyiniOdmAKJOYH7mFb+cOxuGg3XO/FMD4BPRjSTPD0kRxh3ZxT5W
# xBn5K6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kw
# gheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAkQWPB8q7p7D2m
# qiBFpZ/CUXPNB/HGq0rWHwvhpP6XYQIGaoiirn0SGBMyMDI2MDkxNjE4Mjg1My45
# NDJaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIF
# EKADAgECAhMzAAACEtEIBjzKGE+qAAEAAAISMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxNVoXDTI2MTEx
# MzE4NDgxNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAr0zToDkpWQtsZekS0cV0quDdKSTGkovvBaZH0OAIEi0O
# 3CcO77JiX8c4Epq9uibHVZZ1W/LoufE172vkRXO+QYNtWWorECJ2AcZQ10bpAltk
# hZNiXlVJ8L3QzhKgrXrmMkm2J+/g81U23JPcO4wXHEftonT3wpd//936rjmwxMm7
# NkbsygbJf+4AVBMNr4aMPQhBd76od0KMB6WrvyEGOOU0893OFufS5EDey4n44Wga
# xJE0Vnv3/OOvuOw5Kp1KPqjjYJ+L9ywLuBMtcDfLpNQO/h1eFEoMrbiEM67TOfNl
# XfxbDz4MlsYvLioxgd2Xzey1QxrV1+i+JyVDJMiSe9gKOuzpiQQFE19DUPgsidyj
# LTzXEhSVLBlRor0eCVf7gC6Rfk8NY3rO2sggOL79vU5FuDKTh/sIOtcUHeHC42jB
# GB+tfdKC1KOBR+UlN9aOzg8mpUNI2FgqQvirVP9ppbeMUfvp2wA9voyTiRWvDgzC
# xo8xlJ1nscYTHIQrmkF9j/Ca0IDmt8fvOn64nnlJOGUYZYHMC1l0xtgkYTE1ESUq
# qkawKk7iqbxdnLyycS+dR+zaxPudMDLrQFz8lgfy9obk0D8HC2dzhWpYNn5hdkoP
# EzgCqQUOp8v3Qj/sd4anyupe5KoCkjABOP3yhSQ4W9Z+DrJnhM/rbsXC7oTv26cC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRSBblSxb5cYKYOwvd/VfoXOfu33jAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAXnSAkmX79Rc7lxS1wOozXJ7V0ou5DntVcOJp
# lIkDjvEN8BIQph4U+gSOLZuVReP/z9YdUiUkcPwL1PM245/kEX1EegpxNc8HDA6h
# KCHg0ALNEcuxnGOlgKLokXfUer1D5hiW8PABM9R+neiteTgPaaRlJFvGTYvotc0u
# qGiES5hMQhL8RNFhpS9RcIWHtnQGEnrdOUvCAhs4FeViawcmLTKv+1870c/MeTHi
# 0QDdeR+7/Wg4qhkJ2k1iEHJdmYf8rIV0NRBZcdRTTdHee35SXP5neNCfAkjDIuZy
# cRud6jzPLCNLiNYzGXBswzJygj4EeSORT7wMvaFuKeRAXoXC3wwYvgIsI1zn3DGY
# 625Y+yZSi8UNSNHuri36Zv9a+Q4vJwDpYK36S0TB2pf7xLiiH32nk7YK73Rg98W6
# fZ2INuzYzZ7Ghgvfffkj4EUXg1E0EffY1pEqkbpDTP7h/DBqtzoPXsyw2MUh+7yv
# Wcq2BGZSuca6CY6X4ioMuc5PWpsmvOOli7ARNA7Ab8kKdCc2gNDLacglsweZEc9/
# VQB6hls/b6Kk32nkwuHExKlaeoSVrKB5U9xlp1+c8J/7GJj4Rw7AiQ8tcp+WmfyD
# 8KxX2QlKbDi4SUjnglv4617R8+a/cDWJyaMt8279Wn7f2yMedN7kfGIQ5SZj66Rd
# hdlZOq8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUA5VHBr4h00EN7jUdQ33SE+qbk/8CggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5UvKswIhgPMjAyNjA5
# MTYwNjU4NTFaGA8yMDI2MDkxNzA2NTg1MVowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7lS8qwIBADAKAgEAAgIFDQIB/zAHAgEAAgIThjAKAgUA7lYOKwIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQBy8NrEs4J9Eait8Kqw/JoNqk/WVN+XnL1G
# w+IWU8vL+XjeZUmdGfF3xJNRT0diDeJffilkYwO5WGltet0iJW9yWOvJMKxp7f2D
# WJfUsWkMS5QhCOUKfbjhORkdAI95G5pSvc4OFQM/ncVHyeqTiglLa9gYoXHHVT7j
# S2kdZLeW+Rb9lFvsGOT02JzgoPLiwtoaD4tEJcB4W4oMYUjFH61/sTQBwRJsOpoJ
# mrOezSboFAm67hbkXKGwiQYvXqmD6SsWHmk77/O7EmslFC6oyAWIjGIsMNmnI38I
# mjTM49V3KquXX8iw3pC1osZZj0SB7cnQzs9IKg79HVvwkyUR9cqkMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIS0QgGPMoY
# T6oAAQAAAhIwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg0+TnYNRDDrX6MNjnsb4iGhsiFh8gzN6Q
# khxZP577YfUwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBz+X5GvO7Wngkn
# H4BZeYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIEIB+9T2xxWaXcUke/
# ImP07xCX0QSzo2wWQhkOHuUgSMVWMA0GCSqGSIb3DQEBCwUABIICAHV3HspdhFjG
# xVnpn+A/SmPdZv1V+9nikBw+4WMqDjfS2rdq9qaAfwhT7syUM+JNEFHx5IPK9RPD
# 4/SNGiGQkgJ3H2pPyw5GbEM/G6U4Vx82cH9wKHqWDE4AXe6Ap5aOGao+Uew2qfFd
# L4EtZgIb9taI8j9Kg4ev2/v/uIJGqGflqfRF3YJGGO94kSBacBH8QIV3SIjV1MpS
# wgW6qgc9Gz0bJH4AvRC9WKdh3jgAECOpqCpreBWQ50Yrbv0N+a0nepSC4qwXZ5S6
# VTa7xXCpS/ngpyd7AF/nFVernWVcI4sa97oOTJEiHjjeDYBfpzdfK5NdU5FvKneQ
# h9dFqqSbI2HYScLf78tPGIIcIY1avZMoiN56E8jOYIQeG7AcHJ8C/eiAHFg0Qj1X
# 4pU7LXJSwAMvroq7CQeh3u5sUhwilxF+yt5c/IzHP7uV1AUCJYffhS4g42GHY9op
# JuzRXJq4mTw+pqgIab9mFEUaPy8VsRw20x/ta9ulD6W1080XCi9kloFJ4hewNL3P
# i7DAZFhDkrAuhwffK/Sem93ud4O34QqIbSF+o0IFxSMb+7ow5PfHbrYILoEnTVeK
# 4PBF0E+V/TBij0u0fT1LXNAbFrySCMPv/OImJGXMNZOVuLlB1Lj1trKDxiIiJwzt
# jB8YnWi/ww09WUwsxC8wXejLycUYm7bx
# SIG # End signature block
