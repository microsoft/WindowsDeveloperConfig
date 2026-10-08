<#
.SYNOPSIS
  Install Foundry Local, acquire a small catalog model, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default qwen3-0.6b download and inference. The install then verifies
  only the CLI and server and does not claim workload readiness.
#>
[CmdletBinding()]
param(
    [switch] $SkipModelSmoke,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$component = (Get-AiCatalog).Components.FoundryLocal
$report = New-AiWorkloadReport -Id 'foundry' -Request @{
    SkipModelSmoke = [bool]$SkipModelSmoke
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'foundry' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
try {
    $plan = Resolve-FoundryInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: foundry'
        return
    }
    throw
}
if (-not $PlanOnly) { Assert-AiAdministrator }
Write-Host "Foundry Local plan: $($plan.Architecture), WinML, CUDA dependency: $($plan.RequiresCuda)"

$vcRedistPackage = Ensure-AiWingetPackage -Id "Microsoft.VCRedist.2015+.$($architecture.ToLowerInvariant())" -PlanOnly:$PlanOnly
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = 'Visual C++ Redistributable'
    sourceType = 'winget'
    packageId = $vcRedistPackage.Id
    architecture = $architecture
    action = $vcRedistPackage.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $vcRedistPackage.Evidence })
})
$package = Ensure-AiWingetPackage -Id 'Microsoft.FoundryLocal' -PlanOnly:$PlanOnly
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    packageId = $component.PackageId
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    promotionCandidate = $component.PromotionCandidate
    action = $package.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $package.Evidence })
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{
        model = 'qwen3-0.6b'
        selection = 'Foundry alias resolves the highest-priority hardware variant'
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: foundry'
    return
}

Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('--version') -DisplayName 'Foundry Local CLI verification'
$serverStatus = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('server', 'status')
if ($serverStatus.ExitCode -ne 0) {
    Write-Host 'Foundry Local server is not ready; restarting it once.'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'restart') -DisplayName 'Foundry Local server restart'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'status') -DisplayName 'Foundry Local server readiness'
}

$modelPlan = Get-FoundryModelSmokePlan
$inferenceEvidence = $null
if ($SkipModelSmoke) {
    Write-Warning 'FOUNDRY_MODEL_SMOKE_SKIPPED: CLI and server are ready, but no model inference was performed.'
} else {
    $commands = Get-FoundryModelSmokeCommands -Model $modelPlan.Model -Marker $modelPlan.Marker
    Write-Host "Downloading Foundry catalog model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList $commands.Download -DisplayName 'Foundry Local model download'
    $modelInfoResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('model', 'info', $modelPlan.Model)
    $modelInfo = $modelInfoResult.Output.Trim()
    if ($modelInfoResult.ExitCode -ne 0 -or -not $modelInfo) {
        throw "Foundry Local could not report the selected $($modelPlan.Model) hardware variant."
    }
    Write-Host $modelInfo
    $logsBeforeResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('server', 'logs', '-n', '200')
    if ($logsBeforeResult.ExitCode -ne 0) {
        throw "Foundry Local could not capture the pre-inference server log boundary: $($logsBeforeResult.Output)"
    }
    $completeArguments = @($commands.Complete)
    $completionResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments $completeArguments
    $completion = $completionResult.Output
    if ($completionResult.ExitCode -ne 0 -or $completion -notmatch [regex]::Escape($modelPlan.Marker)) {
        throw "Foundry Local model inference did not produce marker '$($modelPlan.Marker)'. Output: $completion"
    }
    $cacheResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('cache', 'location')
    if ($cacheResult.ExitCode -ne 0) {
        throw "Foundry Local cache location failed: $($cacheResult.Output)"
    }
    $cache = Get-AiWindowsPathFromOutput -Text $cacheResult.Output
    $logsResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('server', 'logs', '-n', '200')
    if ($logsResult.ExitCode -ne 0) {
        throw "Foundry Local could not capture post-inference provider evidence: $($logsResult.Output)"
    }
    $logs = $logsResult.Output.Trim()
    $currentInferenceLogs = Get-AiAppendedLogText -Before $logsBeforeResult.Output -After $logsResult.Output
    $providerEvidence = Get-FoundryExecutionProviderEvidence -ModelInfo $modelInfo -ServerLogs $currentInferenceLogs
    $report.acceptance.inference = [ordered]@{
        modelAlias = $modelPlan.Model
        modelInfo = $modelInfo
        marker = $modelPlan.Marker
        outputMatched = $true
        cache = $cache
        serverLogTail = $logs
        currentInferenceProviderLogs = $currentInferenceLogs
        selectedExecutionProvider = $providerEvidence.SelectedProvider
        selectedDevice = $providerEvidence.SelectedDevice
        observedExecutionProviders = $providerEvidence.ObservedProviders
        evidenceClass = 'resolved-variant-plus-successful-inference'
    }
    $inferenceEvidence = $report.acceptance.inference
    $report.result.fallbackUsed = $providerEvidence.CpuFallback
    Write-Host "FOUNDRY_READY: $($modelPlan.Model) downloaded to '$cache' and generated the deterministic marker using $($providerEvidence.SelectedProvider)."
}
Add-AiReportPhase -Report $report -Name 'foundry-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: foundry'

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCp1iJRFX3acMfW
# 4E7+XA4svqEDQuMMOR7eJafbUoTvhKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIBgKW6nv6beJ0KXVuIW+46meXgsS
# XDVUitzliboUPbarMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAmJXlJkfxZxqK12eKBNvElPmJ7M+/7xK1TXO/JjzTFgBdfGg9MCgb54q9c8rE
# YHeDHT9SQY6y1g5MYsNV9Aye0dDGoTzK404wDutF1t4ZUjmaxqIjKGykRqHd6Ds/
# MoY4wh9f1n8hBCLtj29nkWwOVrKN22r9A/upd+LPzu/Z22THGkmVNwlpjK3h/WrJ
# vAPdMGUOihxhuk5ezrZgx0XYmutOutJtT5hTRdcWwSK6TTyvQCyCwMkwlrCzf9O3
# X9DkLSWRvsVQ9pV3JODPnECuJai+08JWpCq3DCU0aGPCAI6tfYjCzYrE4C3WCa0h
# EPxzQUDtCEjj7z4w6YsTIw2yhaGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCw+FeBBYX0Nyf+8Nu2Dny2YoW9np+ZkJRA5oIoFtCN0AIGarUlnK5dGBMy
# MDI2MTAwODAzMDIwMy42MzhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0Uw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAifVwIPDsS5XLQABAAACJzANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDRa
# Fw0yNzA1MTcxOTQwMDRaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0UwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDixWy1fDOSL4qj3A1pady+elIDLwnF3UuLzJIOWwGHcEgr
# xxwtnyviUIDmmxylTUl1u+2rBPp2zT4BwwQhvGaJpExqvPLlDFlbfmSflKI86eFq
# ofiZ7j8NTRO4l7wGg9Njm+muNauTcFW2qdfIjKE950Okrm9MnMOGYy+fibNYdxTP
# RPq1T4MLZK3s3vdMyMEOldcOQkSKpxD6/1Gk6gOmCu2KgI8f0ex6vYxnKDl9W0OL
# SEa/6y82oIbsm+1QBifOQ47xWKTG1CmvtGr85LzA75/MAcUmRw5/of/qET0UFV1W
# ulMcJrI6DASAsNCNB+6WLrotuBZAj+VMlqbn5RMZ6Q4IY7JwaAiIXh7VjxrnwUOY
# ZG8WEGhfrA98di+7LEn9AqvvEOyG+UQcjVhCCbMGXigJXSApeyeWupCsD0jgQMNC
# xfB5BLBDWxgdY3dJBEPgxfkgTDQLBggtVv2d5CYxHKgIItB4bI5eSb5jkIG2Wotn
# FetT0legpw/Eozwf39ao6tENY21eVWIzRw/GsmvwjYQF6vVrxOD0pGVsfqGF8s3V
# PeY7hI2TxHFMqNA0IB/a2NLY7JTxYAKAP/11EJZt7xbqDLMgD1YDdGEzGpQijm3n
# APCL2CebP/jmu90abJ2W425yglGHTI/nCBrwSpfRCgwzrfFelJaCKM6+35aFfwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFNLW58N4MGSG6ud7jWqgT92orfReMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQAqncud4PSC1teb2H6nRuy7sDiKK13FXJirVB4T
# fwjdo2Mb+QL4j7wZ/k4G9P0CANHZFrDQcK0VFDTysrYu8Z0Aha14acDZPsyIoPvA
# GRRhaHEuf7NckRjkfa/ylo1KyII8jbL9N9sJAqBPL8V4FNBjljv+1GHDOw127rZz
# 5ZSTPoAPb2SA0v5yDgcpUMfxglPyp6cnPPoQpTtD9OGx8Dwm2P+o1TPxBIy6I0T9
# RauulogVCvKwflfeLTcKAvnSG1rCjerSXmU1DNXOsAD/bsrSjgbX5mAbD7XTRMF/
# vawAWESFcn/BjjizxeWZb00aYSlkJA2rVtFlMM481aVWXdAbXPP5RzUiWTlgyHf/
# G7lCxHYWGIZuB13T3aI6Y8mEgn/ou40aiFJo8r0+i0P5GdNneWtxiR0CMKUfko+5
# s/73cwe1Wfp8BKXa270cicVQasFf5sRV7pFm+V7fNRXwCu7anTOmga76zO7/2t+z
# OlibvphT+Q6Zd+B2qYsSn4xBaY+YzHpnycLW5cvJyhPxBCcb1oRYfhRzCADb2utI
# 2EtGCjc2P2ii4LyR4QMb/n8cOweL9IqVTKKzzVk+zZJxV3vrp4LyuQXw0O30la6B
# cHdNAAAB9UC83zs3G9d+AlIfZLM97tMUNKWjbBpIirFx6LTDFXVtZQd7hqzLYByj
# bjH0ujCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkE5MzUtMDNFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAjHzqt
# hPwO0GDckDMA6x54lIiMKqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nFuGzAiGA8yMDI2MTAwODAxMTkyM1oY
# DzIwMjYxMDA5MDExOTIzWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucW4bAgEA
# MAcCAQACAgXUMAcCAQACAhKeMAoCBQDucr+bAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAFar76MkOC1QaaFnrh0qKrQAM9cGYEY4FXKeJsyW2rllg3ksshQf
# no1hgjwopGEMzL+v4r028I1fJ7enpb15tEMudXViVqkJI5OT+SUkPzo5Hx8Nyl6c
# tKMrehUmrQErVsW/XG+heMOscn9YuirdFEk35gqltgXAcHPa+HlgL+EcSpPxZLCO
# 0ljD2uRY694KCdgVv3zSS3y+K8XErRpTZ9uNiTKuMdfJxxSAZlwHfVWUwE0p5PO4
# FIt3bPCKJM7eEnSolLEZCpWwXEGSxmdzhIMMKItHbY9y/3+SCFLurhO8o0RA9tBv
# UDd0DsKwjgYwYanNqOTMNwHNCEBcIpvw/YwxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAifVwIPDsS5XLQABAAACJzANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCBQGnkFLBXyJZYfqbbwJlWXkeNIA5R6Rt1v2x+5wWBUMTCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIOXnARo1oVIcOLJKDqlE0adq/jZ9TXdl
# nXWRcXGThBFyMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIn1cCDw7EuVy0AAQAAAicwIgQggb0jjwGATQ4fPot3sG0B/UZ+M/Ct6k25
# Cw3JIq2r43YwDQYJKoZIhvcNAQELBQAEggIAz2UyTEMkKTkxWnSuPIMMiDC+oAnD
# mTUx983yCqomwXH8ootXXn5pY1n/kKHhWQ7NyihqoguXG99pSiRi/0YmAel4f1lg
# 3yPs7qxQcwLQ15ak3dJMxRB6jSI01wEpw4dFLXWOcrKevrVt3O7lNCPXhIaU1Rxr
# /LeCgywTzYzYeaIo7iZO8oV1vaIy4OFs4JZzkJ94dgXjg4aG3CBDihb/9V+MTFMo
# 1Y2SoM4VlVGEMfsW4buOa0yd+GJLOKqO7CsEUwArSHNyB89kYEKsoS1uhxWKAf0b
# GuisSFbYLcCwDJu5CiGHcU7jrYr/91+HRsvZdimlJL4CBt9+k4is/qoYknZHW9TQ
# utqUgEerJFR+cx+kM851rb8hdmrECuc5PFFcWm4/dnQQKhUfOC1GxwC4OYwYj89D
# n3NAcj79Qe/rUjQRgTWUd1ZwGigX2HxeadTz3m92MLjMimPiSk5ZLF/IPgnr4sN/
# V0Bz81pILmFpjeacwVscE9I7EmoT/s9lSErGpPnI2c7jEMsbfY0QbNyYI2/AR/MW
# ap2kV0+sUF3G96RyI5iwcJxUMQzyAjQyqcm7S/C3KyIC4nzqm5UYkAxS9Ef1sPd0
# ryoaYTEiN5GnRidvRJhO8PwOQ/o/0L3nbeIHbjiuOdO5ROsRv2n69mYTA1Pl8mXL
# UGV0+bAWdfFKdSo=
# SIG # End signature block
