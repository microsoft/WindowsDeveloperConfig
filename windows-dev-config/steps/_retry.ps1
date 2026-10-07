<#
.SYNOPSIS
  Retries a script block with exponential backoff for transient failures.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-DevConfigRetry {
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Name = 'operation',
        [int] $MaxAttempts = 3,
        [int] $InitialDelaySeconds = 5,
        [scriptblock] $ShouldRetry
    )
    $attempt = 0
    $delay = $InitialDelaySeconds
    while ($true) {
        $attempt++
        try {
            & $ScriptBlock
            return
        } catch {
            # Timeout exceptions already consumed their allowance, so callers handle the fallback path.
            if ($_.Exception -is [System.TimeoutException]) {
                throw
            }
            if ($ShouldRetry -and -not (& $ShouldRetry $_)) {
                throw
            }
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            # Write-Warning becomes redirected stderr after reboot and would appear after the retry.
            Write-Host "  ... $Name didn't take on attempt $attempt ($($_.Exception.Message)). Trying again in ${delay}s." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}

# Bootstrap carries this self-contained helper too, before shared files are available.
function Invoke-DevConfigWebRequest {
    param(
        [Parameter(Mandatory)] [hashtable] $Parameters
    )

    $waited = 0.0
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            return Invoke-WebRequest @Parameters -UseBasicParsing -ErrorAction Stop
        } catch {
            $response = $null
            $networkFailure = $false
            for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                if ($exception -is [Security.Authentication.AuthenticationException]) { throw }
                if ($exception.PSObject.Properties['Response'] -and $null -ne $exception.Response) {
                    $response = $exception.Response
                }
                if ($exception -is [Net.WebException]) {
                    $networkFailure = $exception.Status.ToString() -in @(
                        'Timeout', 'ConnectFailure', 'ConnectionClosed', 'KeepAliveFailure',
                        'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ReceiveFailure', 'SendFailure'
                    )
                } elseif ($exception.GetType().FullName -in @(
                    'System.Net.Http.HttpRequestException', 'System.Net.Http.HttpIOException',
                    'System.Threading.Tasks.TaskCanceledException', 'System.TimeoutException'
                )) {
                    $networkFailure = $true
                }
            }
            $status = if ($null -ne $response) { [int]$response.StatusCode } else { 0 }
            if ($attempt -eq 4 -or
                ($status -ne 0 -and $status -notin @(408, 429, 500, 502, 503, 504)) -or
                ($status -eq 0 -and -not $networkFailure)) {
                throw
            }

            $retryAfter = $null
            if ($null -ne $response) {
                if ($response.Headers -is [Net.WebHeaderCollection]) {
                    $retryAfter = $response.Headers['Retry-After']
                } elseif ($response.Headers.Contains('Retry-After')) {
                    $retryAfter = @($response.Headers.GetValues('Retry-After'))[0]
                }
            }
            $serverDelay = 0.0
            $date = [DateTimeOffset]::MinValue
            if ($retryAfter -match '^\d+$') {
                if (-not [double]::TryParse($retryAfter, [Globalization.NumberStyles]::None,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$serverDelay)) { throw }
            } elseif ($retryAfter -and [DateTimeOffset]::TryParse($retryAfter,
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                $serverDelay = [Math]::Max(0, [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds))
            } elseif ($retryAfter) {
                Write-Verbose 'Ignoring an invalid Retry-After header.'
            }

            $backoff = 5 * [Math]::Pow(2, $attempt - 1)
            $delay = [Math]::Max($backoff, $serverDelay)
            $remaining = 120 - $waited
            if ($delay -gt $remaining) {
                Write-Host '  Download retry wait exceeds the remaining two-minute budget.' -ForegroundColor DarkYellow
                throw
            }
            $jitterMilliseconds = [int][Math]::Floor([Math]::Min($backoff, $remaining - $delay) * 1000)
            $milliseconds = [int]($delay * 1000) + (Get-Random -Minimum 0 -Maximum ($jitterMilliseconds + 1))
            Write-Host "  Download attempt $attempt failed; retrying in $([Math]::Round($milliseconds / 1000, 1))s." -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds $milliseconds
            $waited += $milliseconds / 1000
        }
    }
}

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBhCJq1db6WQiY1
# Yv3CVNgEVHOzYZYSktamkbgYA9pdVqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEICgbEmBU3lwNoNps1zzvIg3ZIYuq
# Ov0P5rE3Knfc9pDmMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAZNmtrGxAOCuzKZKwW+j2/NVlm0I461DT99WkBvIjUM8umf5ZUgqLG16H/m1w
# ZctyKszKaXMOve0pnUhe2LJWRyL/60CMm6bEitKIGLhhW2bdSHn1fCEEmyvzWM9u
# 1h/lTOThDr1di6Bk314wiB7OnXb2YWNBfe8L9OIi4bANqDzfd5u5GX6GimnLFEtO
# KrVP0jo7jzI3xRQZD8pVs4XtUV1UCliKfe+6ShGGNv9/4qPa1I84cbVGlLZgJNtC
# f5eNZdWwjBqq2Q7q7Srw2fg2Qkrl5RzVpWvOz7FavvR1kfFN2CMxyMcCNYNCMSJ3
# mS1hEN+6Kpm+45Z5nTeB2x1RUKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAUC+sPZpSSfD06bsxWfm22Eax3zx42tCwcO6BW0a3wQwIGaqouWqo+GBMy
# MDI2MTAwNzAwMjgxOC41MDhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiJB0vaq/8i1/wABAAACIjANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTZa
# Fw0yNzA1MTcxOTM5NTZaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC1ueKJukIuUsAAJo/AY5DZRqH7bhgv7CWGNlEdbRGoITrd
# E6Wsn57NaNu1BTdjBbFcv7Rfixte0x+HRvXSqsD+WeSX/6/y9wE0Mz+xRPTGIY20
# K7aQDa68OyzVyUeUCypyZC/gW/3ytO/ZOnU9H2ri77kJP8ABrqyy1UxX/OseEgvH
# sj8yikWT0ARtrjWbXMHFzSOo5hQcfUmMXKqWWz6+N0+UynhGy1n+doW4WZgpH8Y5
# W7hpSokWj1M/Lu4wi3o6Dz9vVWukcgUFGjLAl4YZpOhah7HuiC/alXImMQf8C3A8
# q/6/1hFoeIZB4UGkywxB/OSTOSsL6+39pDqzM7CgOpf4V799kN94yM9uXJI5T/Si
# A5MdIZIhEW0+bh85RqDh5YW3/oav54RPxw5OPlH64QV6KJkl0FIElMVoLNo8UWRQ
# cMD179x7WASjC6LsaNZ7yK0qcESIsL1wiQmdfQBxcqrFCpIQfnmQFkOp9IyXUWqz
# a8tmpz8E6aXg9b1eiAT3PVTgrOlPi/hYZCfPxX/6jGtyPjy1CiwOmJamohmSU//C
# OAenfRT2G2HMRUpCX1zs+AmDmdQM1XRab4YSALLAlDzGCsgI77nnuJjoXAliJmv7
# NfrvWAcA5KqCUOWQ6kSPt5r28MfKXWJJpSXtFeS/MkDzJy/iJRVyHcFy/B+MtwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFFkHwGoDJ5ZbEEiu8KstiusqaozQMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQBiAM+nqrpwG29txSXv42o+CsTe2C4boaRfFju9
# JaWkLTHwq7pknNONL3n+UG3x/B083EKXiFYrAmul7BTHCGXU63/xRsZ2wj3ZmR0A
# 4d9nf9saCJVm4juPVFBai/oktOOYH2j+1+zM70woN5ongB/pvy7X8AfY6JB4XPvb
# 80Qz7fY5eddbnwjzg1sZhUPFbbcweWeACINrzqFK62mMeXKmhtufMraoogJeJXfW
# Y3x4/pbubgENT3+pXT65203CPF9kfdKE7GKAIRYy3xkBTDvFd8dufjOpCn38nK6q
# MlVtnBjDhWQG0PM3E/oxBs5UBrI6pBYkmIHtbjifDquHT+ThaVV7xHc6InoSc3aN
# zX49JHUgQmuvDdMjLkbYXeA0/1q5IxSg2U+ycZBOvAi3udZPKhA5VzODjf/ucu/v
# FtXrYcRkmGKN3jujaK3/yMZi2Ju5NEL3ISWorwp7RjeZg+JMIK0fosuVj+YCm5r6
# 4LH/D9QJDAj+XfZaNeFdv90K5A0QRRGP/poB9yTIVjEXj/uJzp8L4Dd44sAquqDO
# iHdkLgxfK8nPqpCSWPZ9G+RCPm85o9cAfxENtrSuOwcpyKzxsRCYCL+PK4+98ori
# t9EVJ/LLoCeG+jLlj0KaD4Qy6sZe4rWMr1brQLosTBZNwFnXxNjInCWBd0i7is1y
# TS/4qTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjg5MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC7ycXV
# Zx3bsDpJkr7VucgpksozuKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7m+wTDAiGA8yMDI2MTAwNjE3MzcxNloY
# DzIwMjYxMDA3MTczNzE2WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDub7BMAgEA
# MAcCAQACAiPkMAcCAQACAhW0MAoCBQDucQHMAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAKhFlheAK8lTSifzjZt0bkfGx0QNCUZ/dum8wi1EBZo9nKecf6XJ
# 7MaVNhLMvzGfO+r3yZ0VREo+OFmwUWVcpsWKeYuTpb1wdYsO7z4spM/oQTMgr5I0
# cGrF5xaV0urTaaWwCsafgx2MG4OxZYOWZfP8EK32awdghyvtZF6/YsPG+bv6Vtn9
# 548Yl8ycpyZNdVyHsd2Jf4loOZQ8hHIRNeZYo+ytvaX8mkQnFVNR4QDoXvve6YeD
# W/buZmCA4xTD4/MdAkMEsve0Y/FjEVF+skXcpK6mNfl6pfLu4HmYEvNrTepmv939
# AGb0Uu10Oe8EpWkk6bCwDypnXlJ5YYvI+WcxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiJB0vaq/8i1/wABAAACIjANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCDScfc5Ga9gYSfO0zaN6V0UgeQcJkKtGfa7RTGJm3tiJDCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIAVgXQEKBOfGgjNskmDOmbcEIOnHGNwA
# +QcRufDR5AkTMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIiQdL2qv/Itf8AAQAAAiIwIgQgM97+HL2PrC0RsQ3+mziSEz4w/M8OxHz2
# I0gGesEjgdkwDQYJKoZIhvcNAQELBQAEggIANkAa2U2nYMPFqyxNdDFhtLyIhiW0
# q9QGP5H7cqocyr6Hji7AP/voYPG5poqYluJEjGaJ49TbRgzJXjlNa/AmKMxiUsEM
# IJAuIbpYwqcvm1ByqWeX+HAeJ5Nzs48mLDAGG2ZKFm+LoQfgBxNsKvVoxRugpw+c
# QpAlv7AUJYbiklb8NXCCFIqN6RUu9Tt189pO/HlbmgBXnwz92vrQmEpPPplXBM9s
# XjOApMpWEhr6q11gtVr18CdIXGe+F9ml7pbJTudZ6BjwIx72jsYT6+n5TAFWvnl6
# tqIoHQUQQbk9d0J+JBj6638RhkNgtN29Q+IMKcS6E7xs2U4N72IZAAMkvpjAsW2q
# 81PmSooznVyBbrZXGEsIZKHUoXphjk4sp3ll52WIKzlppwsxYZpIqOJ7GzuFTYql
# xHlbWo6FNbWzfuGnwE5yqH9HwipX0aWK6G7NrCEFY6jGcRtgOqeF/wNCXJsYMgaV
# pvuB0BcUv5/GDLw/6AjOtBvtKOcHAD+cE3UHDqq/FuPxASsw8vgre0gr3+9NIusF
# HmmvPKnNtnIuTNn02S9i+ClFYZMdyQz7LsLQwiyVryFs2rrYnoMVayM6NxsRU+9H
# WMo+hwYyWxm2R8ZD809Q+IS0B1tvi7qF3Xi/1PqrjZnHbazS+uviopzr6TCSc3N9
# dmvJk/IROVEzB5c=
# SIG # End signature block
