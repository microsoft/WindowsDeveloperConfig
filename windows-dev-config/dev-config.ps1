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
# MIInOgYJKoZIhvcNAQcCoIInKzCCJycCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC84SDKnzUn6ouM
# 0bqVWWOhXEXkdmz9rVDR1WhhlWw5+aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIF/gYms+8pgBsZLFRG9niGco7O/Z
# lOuJwSYOQ+gfNO14MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAKsFXaUSEom4iicyzxiTg6TIY4POCNif18Cn2UsCGkhCgk5ZK8l02zVxfloc7
# yugoOe6/jhkx00wik+HJn1V3tbb2fQY66a1wSapAnz42LywpA+p3aNQmUFi42q+h
# 8ieTMbiFXNvnCUbndTWiSXuLe4HK5sM4KA+tafpUrtN38F9K1t9DfME2pmHK2WCq
# g8dlOGj/lAyLLtPfkgPqX2OExtofv/GRg1b9/Wy4a9993ZzcMitVbeFBY3aejJMM
# 0Gs5yLyZNyOodBn/uLVqjZZNL1IRqQh7UwOmsxmDf+zYfBfD+VW5ilhAtJbekfvV
# VMtpzs50OO9WOH251wEt6vCJYKGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38G
# CSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBx59E5g0jq2yOfeauo1Kz5MT9D9eICOfwdYfhCxLNx0QIGaqqIZvi0GBMy
# MDI2MDkxODA1MjEyNi4zODVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHt
# MIIHIDCCBQigAwIBAgITMwAAAiAk4ebgF7m0jgABAAACIDANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTJa
# Fw0yNzA1MTcxOTM5NTJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDRYY7yr7ijW6CR178uKveIMufutWOicxgJwKOce/2GOQce
# us6ZWfX14i3jNg3JOP7MGJMkOAucwWBwiA8URp+ZYkGjpVoVkGZsV27WjqLwpf2A
# wqBsJ/TzqwE7JFFaxup3Ldxj8GjdJymDFRrdVN/pYHoBFrjD1IkIDu8b1CWn8tgo
# miKRSY+STvJq99mVkdphMBIUGOegQny8qRd24VME0xi8Oomks9Zq9EjDeKHGpvAb
# XUEQ6m3cROoEPhTE/miweQH9TqJt3IOsqPv3L8urojB747XBC2y0CDIHlKLcLl3Z
# G8D7JXKnWTFen3msMPJpcvrQ3zUBVJrH/mI3RxHmCh9ppDP0uG1+PJwk6H/x+sfo
# G9hW64xoXkpx6DEfNZNfcXdKbXF28XEXdLNnzo3SLNVymeQJhNqOSKhnU84QnKmr
# jEk541JiurlDCkCWO9lUBUMb9x0nyfXUbNRPVLgP+PTMRdXOowJdYCzCQfN2ZqL0
# s4YI28F1Dbn7Bgw2E4P1E9unsvMzJHtzhS2Th3TpCfBbOGalIlF9x/DJZ/ssm/yy
# zT9YtIFeqmfNxBPTE3aOuh6HxmTICzfYAATvWNhBbo19QwsjPeA9JvhqTLC2KUNg
# rXroGy4eDZo0n7jFYjZkUih1Ty+8E6qEvV2Na6Z5gUyD5a+tHGDmq69CmUiHfwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFNvInOCIhxGA8mY7l1g07UHvyNgzMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCtKGBto1BSvm4WFI+J0NSyVhU1LHL7F3fbjZ2d
# 7F5Kn/FCTBZXpzrDVl63FLRNcIFpnJy4/nlg43r7T5sJPdo4Ms8ADSHQEJnHSu3x
# 9UpjCzREBPi9+nHhvDgRx/1WmBD6gQUZJLOhcN2TxW4KJyhinMtiBFtkNRZ2vmZ1
# MAdNXTm5d0Lwk3wzj+/f7VCCTWCXJSoqNa3VU/6sACHI97Evbnzg8bd3hxrfz6Cc
# CVuf77egvRHinthJuwSRePP7aVmcevb1nWUIAICdBebHQOrzNIeWBIQwvcFaS3SF
# c+49rqrwQOMFDR4FYBzS7b0QeBVxFuLL2iVu4KAHMNUhLLSD4iKLDFBNTOtTzTlh
# GvMgG77A1cjeQrDMHa6oReMDeUDqHUrxv8g7IRdIh+h0gDLkzN0xIuzli0Bv7Jty
# bGJbV6JxaDF4CzSCIMRpK59nI6iKo4LgnbQBZJW7+6akYsKG/pXPlfxNv2InpD10
# tSCkCvw9kr6W1+NRN+EuZczRgAwWlcK9XJZ3uu/v/oxHtO7/kmVIs51F9qV6Y2QN
# Xd6tU46YPrK98m2QDys+lvLNimK0e1xZ7Z1GawKohKGvlLALWDlZQqgHfJ31CB0L
# lIDI7iLyYTpd2iyKjqskbQiyMtICH+RmH/oCg7JOK0ZA3XIMba9aSWgBF3QZ6pG3
# EGeQqjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIIC
# OAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkYwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCTGA9v
# psJ6glqCLmI0rggGx4YEEqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7lcA3DAiGA8yMDI2MDkxODAwMTQyMFoY
# DzIwMjYwOTE5MDAxNDIwWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuVwDcAgEA
# MAoCAQACAidfAgH/MAcCAQACAhQCMAoCBQDuWFJcAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBAL/U99iLtYBrM8X/5d6BP3yW/swdOD8gsIB1uICB3IUvwM8Y
# TIgTD36wtMaTJfxewx1v2x6gqlZOWE/BSCY232YC15gxxWdBGuMPcLdbeXNCeSGi
# 7eEgsIfjCIQ56rkSxK/M/7lVuFjEA+P2MRfoq5ShBayVp60jWArgo6ZdD5XboEhh
# 2XdBB+E9gBhAPWcrZID4krQvAnhFrauRaj3x1cgwqa7rqFdLtFVxXrxEZKqrIPq4
# dl6of3TiVuXu+xP6jXdII0D5ZCPC0z3mIUg8RBrezkxI7F/TM7yg0BzIhtEQIzDq
# LXio+lvemmusq/bwSPQDBYxnX0/W6BMqNNUsgx8xggQNMIIECQIBATCBkzB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiAk4ebgF7m0jgABAAACIDAN
# BglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8G
# CSqGSIb3DQEJBDEiBCDZ9qG5MlXLjGQaiqjmaqVcRiA1wB5EVToeRMp+9JkTgjCB
# +gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EION7vyOlPA1VqlEp0QIVGlNd8S5Y
# WBnKj97LuTWHSO2vMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIgJOHm4Be5tI4AAQAAAiAwIgQg5m4+4da5muucJrvc+XnXaVIC1Rv7
# EfUtM8IrsK3ugaUwDQYJKoZIhvcNAQELBQAEggIAGQRslGClz0X7J8B+MfHQWy2d
# NAH3lJKJHUFtylw0fHBmNU9FkvePXeKEFXBm18tLmn1D/PFENXGTThPR7OnkNopK
# FjTZLoi96ac6LC8RuSYQHMe6dvXJKTENm5B1RuOiYxrFUN3jRTmwmlJ/gUkwFtlY
# Yz4SJZJm0XRy1WcqKZj783plUBraGG0qedxGJ+XIZdB0HccdG6Zh0qs7PHmi67sh
# e+DbCwgj5Nh+09fsvc5A2JTvNo53JM1g0kcQ3PD4WPIeOyoktVVp7GJf2unhWj67
# y4eN4Np4Q7qhIhzR2vNCJu56OKdhTagM82zpioi8saOAGH8Ebef4pl6YEyGZP0QB
# +iFnKKLdGMSzaGLnEGBT6zfTKtm92DLGwml4ad2Kf4SAx0h4Op27uw1Ciwlr4lXV
# g50GYx/FRVLsbBCwL5mb9yrRE80v0DyUBx/VNvT1CwinTD7AbhH1Evjms6OyQkgc
# E34DXKVx2Pkfe/G+TTkUa/We3VFKQEnT8xzBDEHv6QsAk/uYB7vGpEfolYDrG95q
# KAT9za2frnAhMAbGGXPNUmSDhLzWKL5A/xbSUTS+SqG6LSOrBVVcA7p2vWnAezKs
# muWZivHTWCd5oIeUkRL/BwkRFmLEViK8m4MeJ/0k9C+XuDkPz0lqvYo2by9KyWey
# B9ufzKzvNiNLs+zq1q0=
# SIG # End signature block
