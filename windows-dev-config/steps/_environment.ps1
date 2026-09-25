<#
.SYNOPSIS
  Shared helpers for PATH refresh, TLS, native process execution, and UTF-8 text I/O.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Update-DevConfigSessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    # A missing per-user PATH is normal, so empty values are filtered before joining.
    $env:Path    = (@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

# Normalize native failures to exit codes so callers are not tied to shell-specific error behavior.
function Invoke-DevConfigNativeCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [ValidateRange(0, 86400)] [int] $TimeoutSeconds = 0
    )
    $invoke = {
        param($FilePath, $Arguments)
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $FilePath @Arguments 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    if ($TimeoutSeconds -eq 0) {
        return & $invoke $FilePath $Arguments
    }

    $pipeline = [PowerShell]::Create().AddScript($invoke.ToString()).AddArgument($FilePath).AddArgument($Arguments)
    try {
        $pending = $pipeline.BeginInvoke()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextProgress = 60
        while (-not $pending.IsCompleted) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $pipeline.Stop()
                throw [TimeoutException]::new("The command timed out and was stopped: $FilePath $($Arguments -join ' ').")
            }
            if ($timer.Elapsed.TotalSeconds -ge $nextProgress) {
                Write-Host "  still working -- $([int]$timer.Elapsed.TotalMinutes)m so far" -ForegroundColor DarkGray
                $nextProgress += 60
            }
            Start-Sleep -Milliseconds 500
        }
        return $pipeline.EndInvoke($pending)
    } finally {
        $pipeline.Dispose()
    }
}

function Invoke-DevConfigCleanupCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [int[]] $SuccessCodes = @(0),
        [switch] $Unelevated,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 900
    )
    $command = Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = if ($Unelevated) {
        Invoke-DevConfigUnelevatedCommand -FilePath $command.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } else {
        Invoke-DevConfigNativeCommand -FilePath $command.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    }
    if ($null -eq $result.ExitCode -or $result.ExitCode -notin $SuccessCodes) {
        throw "$FilePath $($Arguments -join ' ') failed ($($result.ExitCode)): $($result.Output.Trim())"
    }
    return $result
}

# Some installers can wait indefinitely, so process waits are bounded and emit periodic progress.
function Invoke-DevConfigProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [switch] $NoNewWindow,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError
    )
    $start = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments.Count)         { $start.ArgumentList           = $Arguments }
    if ($NoNewWindow)             { $start.NoNewWindow            = $true }
    if ($RedirectStandardOutput)  { $start.RedirectStandardOutput = $RedirectStandardOutput }
    if ($RedirectStandardError)   { $start.RedirectStandardError  = $RedirectStandardError }

    $process   = Start-Process @start
    # Cache the process handle before exit so Windows PowerShell can still report ExitCode.
    try { $null = $process.Handle } catch { Write-Verbose "Could not hold a handle on $FilePath." }
    $startedAt = Get-Date
    $deadline  = $startedAt.AddSeconds($TimeoutSeconds)
    $nextBeat  = $startedAt.AddSeconds(60)
    while (-not $process.HasExited) {
        $now = Get-Date
        if ($now -ge $deadline) {
            try { $process.Kill() } catch { Write-Verbose "Could not stop $FilePath : $($_.Exception.Message)" }
            $minutes = [Math]::Round($TimeoutSeconds / 60)
            # TimeoutException lets retry logic distinguish a bounded wait from retryable install failures.
            throw [System.TimeoutException]::new("$FilePath did not finish within $minutes minutes, so it was stopped.")
        }
        if ($now -ge $nextBeat) {
            Write-Host "  still working -- $([int]($now - $startedAt).TotalMinutes)m so far" -ForegroundColor DarkGray
            $nextBeat = $now.AddSeconds(60)
        }
        Start-Sleep -Milliseconds 500
    }
    $process.WaitForExit()
    return $process.ExitCode
}

# TLS 1.2 is enabled once so downloads work on Windows PowerShell 5.1 defaults.
function Enable-DevConfigModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
    }
}

# ReadAllText preserves UTF-8 files without relying on Windows PowerShell 5.1 ANSI decoding.
function Read-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

# Write through a UTF-8 no-BOM temp file to avoid truncation and edition-specific encoding behavior.
function Write-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = "$Path.new"
    [System.IO.File]::WriteAllText($temp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

# SIG # Begin signature block
# MIInUgYJKoZIhvcNAQcCoIInQzCCJz8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCb3wAXH0VSvuT1
# EdZ3WWXiTj/qewvuT6B2OTGCRo5B1aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnfMIIZ2wIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIMJ1kwggob+DAjsyaBUHr6I+kmki
# nHO8ErRSWtvXUWh3MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEADa6P7++ESDAd7/vwoxyv/RX8Hotl4sv2kf3pNpyCbUuCkRgs7eYUqqy12Euw
# Oh/YM/QXa9eWVbmRcSMabYm2JlOYanDqIqFjOWiCQSzXU9Uj6b9tSiW3wPxTWNwK
# gmK8c53wLwKr1sAJi4w4Pm6f6PAN+YIJnpgL089c/PHW0Tsa4/1PW69wiHiA6JPI
# oaBtfdOJdsZXRC25F2QwpsMzZJdDszhmbCkFw9u/uV57raPBMkYlb7mdLLR1EwSx
# fVYWHXNIE6mNMGHf2lWtEmGdiN8ijaycqlatw5GurcT/c4dPhcMKax3Jow3A2f8h
# Jyt+f45qTo+jYNgaQgG/B17snKGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cG
# CSqGSIb3DQEHAqCCF4gwgheEAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAE9bmdlPKDLsIyZS04nB+2uSrm90VMfDeF7JuKra5cSQIGaq7X9RN0GBMy
# MDI2MDkyNTAwMjEyOS4wNzRaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEf0wggcoMIIFEKADAgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyM1oXDTI2MTExMzE4NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNh
# RM+BzF2AYiq5dUpZpJFPRjCcipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU
# /W6fecujjILkPqn9pngtWRkfQgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY
# /Qk/jtjsHdFXVBe+tshlIkSJ3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQM
# JP7tO8/BJ7ITs4/AV3D2bv8eHk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf
# 5x1lXxAwEw5a7dpS+CKTanhtv+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1
# S9e8h1TszXFzjLLvE9EmjnNfIewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J
# 60fGOl7A1UoUyAkhpb2Bja+SwSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6
# FZlPO8iuNyk680Di8VnbSNpIdJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asN
# t/Ng6o4m2dnooWOdM3yKsJaWjyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+
# XSvI2m1yN4iibqjm5HPaAO3OJ+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C
# /+n1KFBpDGdDMw9gmu8CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5
# ZQqnF5x8S1bJQzAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg
# 5I/5S+gx67aR6RiW8ZAwtE3mz8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyv
# h3e2q/BV8rjHE3ud9PyYyq32euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZ
# sSypbXDBbQkWkNl6g82yTy3AbBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dM
# SkSZweCNDXqd9r/9W2VdRZsDJKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69
# /N5CP/Tq3YgI1ub4b9+3MJFKWhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2
# NFXJFQHef6AdRe1ERvYQeqtyrBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67
# oNwR4pEEJyAIEREvkdhjjfWcgsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D
# 59r7/qebNSyQPTfwI9++jEY0Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HE
# ovbA69qGlZ3OpUE3H1RBGDVp/FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IE
# XO2SeD1aD3IqvAOdHFKHg1vpbPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7
# zw64aO5hmJ7eQwoMfTu0Vay6r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# HVUzWLOhcGbyoYIDWDCCAkACAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5f7WYwIhgPMjAyNjA5MjQxODQxNDJaGA8yMDI2MDkyNTE4NDE0MlowdjA8Bgor
# BgEEAYRZCgQBMS4wLDAKAgUA7l/tZgIBADAJAgEAAgERAgH/MAcCAQACAhP4MAoC
# BQDuYT7mAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEA
# AgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAJJKJklR8xHlpKIJ
# rAXROFU6gByZLyQrxrAjbh2cnxA9TA9sRlV1PNXLaQpvYHwcFz4WKBjsb9GDJLpX
# tGZjHoo428QvC73WbBIRSeaOP73IXUtwzDFgdpM1Sv7kFObw8Huk9+Dow2We5Ran
# O/Tw8DUrL+z0E6P1cT9BUmJrNlj2Kont282ZvLoL5PgMncbuv5lm8I+8V0nnfQgD
# 28UKHGqYQZTiGGJC8fXfsCfTtYaJ05nu5ED1EtCONXyk6pwhu9JepBwOkJtr4atY
# qx1I3FsYMQor0+8I9mMXG8UiFQwt8+byekuE/ifUMmLWqrhGhMongGyBvouDOJ1g
# /OQ+3mMxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MAITMwAAAhdx+y6lrwEd6gABAAACFzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZI
# hvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAb/zmIaHRvmQrY
# aAVm3lYkODBE83wcSiOhBFaJIHbgyDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQw
# gb0EINDyUGA+XbfJnRLNRK3mmE4h6Ac/LCuQ3B6/F7aT5FpbMIGYMIGApH4wfDEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWlj
# cm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIXcfsupa8BHeoAAQAAAhcw
# IgQgAa/y9V3l2OMmn1EX8DZtuO5dcKJViosofuXacXTtIqkwDQYJKoZIhvcNAQEL
# BQAEggIAKkT0IdlbxqfoToUr+IrVshzT4KAb2OEkFAKffhpaVnE3OV3yPRFIVlpH
# 0OAq3AltqqPRUh675tMp/pNCa/PeUmH8WqI3/ZhMlmTy836DOlMjwH/2Somqypsf
# HHXwLBTg8CT+5j5S08V0U5eEKwqvcXYK5Q56pM8QKzYBV9+a2O7g4BEX8kFgZK3C
# /JT+sxiCj2xsgt7GlSt3Z9b1sx88y6QK14FL8yH52qsWsFJgM0RrVcHbHBht/Os3
# tpiXTQuzZWDrqBnGx6Moc51as0vMPCmrzT9ZPuJWiyqAKepoudrYW9q30uSug86z
# 6A+LcC8kpfZy6SgOzh/ObaEK5grTbStu95P/ZFiDzOy2WUFacenPbcrfvJdRiU2j
# lCYY1gHkHRnaneQn+8Qy074thJgDG+en8P2KwAL3S1NwLSX4mE068gVJeod2J3J/
# KgmCaxxduAyRy2C6mKLPjJcu3MfVBc/XanqIt7CP2leyuPd58TWo7lBJgihlU1IW
# UaI5XB9hOSgsUa4gUrRAj3W9E9+08l2EW42LzF+y+5k0cMa5pgIU1jR3wCHEn/MO
# 1Sd5f8FBxIZA3La8w4ZxYGMCvO01Mq+C2Hoe/Fq2Q4tirGwy2gVtPN9Lnb6jahh+
# eK32ITUWIAkNA5+twVbh2Gp3Qw5B2jCbwH6IPtHcBqLJ96tKAXU=
# SIG # End signature block
