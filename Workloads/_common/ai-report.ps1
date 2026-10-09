$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AiGpuInventory {
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match '^PCI\\' -and $_.Name -notmatch '(?i)\bNPU\b' })
    return @($controllers | ForEach-Object {
        $vendor = if ($_.PNPDeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA') {
            'NVIDIA'
        } elseif ($_.PNPDeviceID -match 'VEN_1002' -or $_.Name -match 'AMD|Radeon') {
            'AMD'
        } elseif ($_.PNPDeviceID -match 'VEN_8086' -or $_.Name -match 'Intel') {
            'Intel'
        } elseif ($_.PNPDeviceID -match 'VEN_17CB' -or $_.Name -match 'Qualcomm|Adreno') {
            'Qualcomm'
        } else {
            'Unknown'
        }
        [ordered]@{
            vendor = $vendor
            name = $_.Name
            pnpDeviceId = $_.PNPDeviceID
            driverVersion = $_.DriverVersion
        }
    })
}

function Get-AiNpuInventory {
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match '(?i)(\bNPU\b|AI Boost|Neural Processing)' } |
        ForEach-Object {
            [ordered]@{
                name = $_.FriendlyName
                instanceId = $_.InstanceId
                status = $_.Status
            }
        })
}

function New-AiWorkloadReport {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [hashtable] $Request = @{}
    )
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    return [ordered]@{
        schemaVersion = 1
        workload = $Id
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        completedAtUtc = $null
        host = [ordered]@{
            os = $os.Caption
            osVersion = $os.Version
            osBuild = $os.BuildNumber
            architecture = (Get-DevConfigArchitecture)
            powershell = $PSVersionTable.PSVersion.ToString()
            gpus = @(Get-AiGpuInventory)
            npus = @(Get-AiNpuInventory)
        }
        request = $Request
        acquisitions = [System.Collections.ArrayList]::new()
        phases = [System.Collections.ArrayList]::new()
        acceptance = [ordered]@{}
        result = [ordered]@{
            ready = $false
            planOnly = [bool]$(if ($Request.ContainsKey('PlanOnly')) { $Request.PlanOnly } else { $false })
            fallbackUsed = $false
            warnings = [System.Collections.ArrayList]::new()
            blockers = [System.Collections.ArrayList]::new()
        }
    }
}

function Add-AiReportAcquisition {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] $Entry
    )
    [void]$Report.acquisitions.Add($Entry)
}

function Add-AiReportPhase {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Status,
        $Evidence = $null
    )
    [void]$Report.phases.Add([ordered]@{ name = $Name; status = $Status; evidence = $Evidence })
}

function Complete-AiWorkloadReport {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [bool] $Ready,
        [Parameter(Mandatory)] [string] $Path
    )
    $Report.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $Report.result.ready = $Ready
    Write-DevConfigTextFile -Path $Path -Content ($Report | ConvertTo-Json -Depth 20)
    Write-Host "AI_REPORT: $Path"
}

function Write-AiFailureReport {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $ErrorRecord
    )
    [void]$Report.result.blockers.Add($ErrorRecord.Exception.Message)
    Complete-AiWorkloadReport -Report $Report -Ready $false -Path $Path
}

function Get-AiDefaultReportPath {
    param([Parameter(Mandatory)] [string] $Id)
    return Join-Path $env:LOCALAPPDATA "DevConfig\reports\$Id-latest.json"
}

function Get-AiCatalog {
    return Get-AiCatalogData
}

function Get-AiCatalogValue {
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Entry.ContainsKey($Name)) {
        return $Entry[$Name]
    }
    return $null
}

function Set-AiAcquisitionAction {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [string] $Action
    )
    $Report.acquisitions[$Index].action = $Action
}

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDm8WNr4bDbIC80
# nr5RaEjlrj7bEvi+DJ+fBbwQ0OJLqaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEICKs8TE1C69qjCqgz+L9bNax8F2u
# 9JiXrDpJOjzFsCbQMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAlbuZ/zhHZQlPtgihV6Pd0TVNwA4cYmHAFWQV4qUbm3RtO04sm/XIUIeau+MO
# nDfnL96YnxrHeRsPPaQukLyeB29j5e3K6CfMvMHTrYN3waoC2/IURnCeXUWWcuUv
# Nzsp0jSIHZpPuj/QcY5WpNBDSkq+08K9Kyc3/SMFKR3oKitTXSC2S/Ykrdvkua/c
# NsmUoNQ04+FnYXaaZi0Rq5CSdql9kqATT/AGEqlVS2l/o+fFTRUnQpHAnzYyddOq
# KJrhO2nM4Nm1H0TLAQJRXDYpleWKVJwQSCC8uJ2AmzKVkMHlQc+2gEeWk/yGzTKf
# X+Q4Y0tbYaR2wpXm3K+cijHGOKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCD9UkiwFGvjiHc8AJuWCTFoXwjN7wZuIoIVBqpuIe/h2QIGaqmskmu0GBMy
# MDI2MTAwOTAwMTc0My43NDNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiWAxzfGzap3SQABAAACJTANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDFa
# Fw0yNzA1MTcxOTQwMDFaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCm8RIP0eLA46VcCPovvmqsIlN6qkmz5IsHWmUU0neUqp8u
# Gxadeo+SwWBCwQ5alZI/DNdpXfyiZLZR6XYgpRPFzepIl7OCDb4NtEskJCIZDkQM
# NwrH9YwUyu71GGigsLIxeleHtA3utoVTeHjS1b8UnwORRtknKkyrUArT6ZpB2rod
# IcmcLcv3x3wwgYlOs0FEg5EsVrZb7LNc/nd0bXDp+HTOWWui8eoTVwJeLxcVP869
# oF8li5SU81aa2tGJ6/Jsejiz9JMW8SJXKBT2DCXMOUkCsGjonPZRqfvoMSIQZgta
# OTyAJlrvsy0TZ78XrGqoygtQimQnbOAL4KNLSCuW5TZEQGTHLOQJGgggb3j5gKC7
# 78+RIPJA+n/hmHJ/x4qT/HTTPoVeMCcuBKWrQXR1+/pYau3Fwe0tWIyG+LWzkRr/
# ZNPPupcA2Yci3qn8HR9RwvQopqSNJwn2Ri6am8AQyfVVy/BBw0t6jpoRPjwKvuUj
# fCzpae6duOxQtQ1XDN9PA2yl9sDko/+AXV/SOe8ea8QoQcv3s3ErkG+Lp6hnvw6O
# MPian4ggNkRtgtB7ro1OiopOUXJn9Y5EO3JUAXNcuM9m+5My1VEuvGytgAH3uxms
# lTnW3YbrfazaySCSSnWkhaOZ33hgbuUQfH7n2NFEAUc/cFzfmCQUikWisnJYywID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFLE40qoXTuMHX3AfZUu1n8nx2h93MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQAHnfc2yUyoHZbvvyVKFuXh5HxxHIvIaR9JWpIf
# ITJlc/Ki03juR+vckzq3tp5fFH5LL7eIFXRIuoewMsvWeFrWufrrW4HhmhCwkqAr
# fA1C0xk+HaYs2O48YSxMX9lgS1kTTIb3YsfoFdFpKurPf2nc2Yd4wLg+Fgwmkxke
# yE3MUKVna8SZeVpEjnS5ucFck4srPwK2ORAf70I23GGyPhqgIKZphNXhSscTAQsy
# IqB5GwDMdRV5LK37NfU4YmxvCYh3TFYE/Gh01Q6yJvf9HxiEZpwW+oUk0gruHobg
# 3sgIR5rfgUo8l30vUnaDYMcPAClaFMC/QbHZSaUhWXZG1OOcMp0g9vYQNLDEqFX2
# jlquvzVSSwtHtm1KTldCjRED+kdCybcPxbPalwJigXc1BsI9CitnTf0ljwb9NkZ/
# JVI8/D62rXXzhz4F3u0iVGzwncGaxRxHG/Xv4nTrpkOeepoYbNBbMWS2G1qP3Xj7
# pVf0+4qRyAqJ0stjQjoVOJImVPWRjz5PR3Dn6adQVMBJDM6gDrj1rZTFVgCtTijq
# GZSGzvXpGkF3vYsyE6ZDma/kGdiUe5saeI6lH66PiWWXgqxt7sy2Ezv0yIjSVv+e
# MOT2QMUiZ6WCc7gVtAmXpfeIus+NmgFvM+Ic1X58e4I9EL4ZSAidSpWW0GZTLNC0
# 2mryLjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjg2MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQBTb+bK
# OPAjCBflhzw5EXBuSWxeDqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nJ5yzAiGA8yMDI2MTAwODIwMjEzMVoY
# DzIwMjYxMDA5MjAyMTMxWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucnnLAgEA
# MAcCAQACAhiyMAcCAQACAhX4MAoCBQDuc8tLAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAMQABardHlQRw0N5a3zCrwhoktQoYWz+OP2w8CpFK1gL4rRvAAgt
# dgYfyImIbMvpNy6I0XPnESvwo+cn4uSUI22SaozIjfaxBkG34MSBZUHuy8FWi24Z
# 5b/nC+rybnvhe5OiYmqLeQqJgcx71wvzzUufCUiLX8qW6s+ZeXQUmqRzEHvzoFe2
# YSbuC73nCpbdpGGwRHnEXr+RPzkEWKORxbI1ogxF3M8frUOirNsSJu/2V4TmMDBh
# fP1iEN+v5GnVwu2JdxSR0cuyb3mA/uPEeE/jfbtNuu6RVFyrIJDimQaFQmRzNmEq
# QBs5+DJzVU3zaI+gVg2HRk+zZoMA1QXBrkoxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiWAxzfGzap3SQABAAACJTANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCBTM3u1Xv9BH/7MUQpLvQYGCNE6ErWBjjA9bho4NRyBVDCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFYN7oh6ON3y92CmAl/lF0CYwrjWWQP6
# dCUxajPSHKEQMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIlgMc3xs2qd0kAAQAAAiUwIgQgzcRbqpIhcdX/xu1uCUUynG0Orhx0mTed
# n/r5DoOtKSowDQYJKoZIhvcNAQELBQAEggIACqrHUo5qItioM74MuKVKYck9csDR
# u0Ll3nEZMY4PJEfowoGg7HfldqPNEbE2pqaMYbVXpTOobp1GFJu/sLYJZmJpaEW3
# Ka6AQoq16Cg0RrplTydu8xn9qfZpy6uao7jLoYIQXcgl6VaQ+p19RSwqNc3CCfFx
# BkdT3oBPKQt+N78r1kj3mrqHjoZ/oSdC1Fj8ZaELtIsegkSVNdHzlgSU9s3bwWnK
# rYo1KS0obw2xmzfECe7H7Hlrrbk6+sOPOpYglHhT93Qct/5NF08s59KEFtk3LjHg
# 6VRBEQXIE07J8mIruYqDEux1tZURG6MgFe2/vkDq0ECra2GRtCGz4IsVV6Evplht
# kJp472OEmRwXYXLfw3BECqEnABitrbNdfcp311N/dHsQg+ke1/wWRQuxbsOa/fpH
# 1zmkesf3+e5VRa6lXC9Ji9G2c4WfpWiVqwz/hYmlyMqB9WxCjhOkwnQV6z0eBGqY
# 4qrJTuPj5sKC26FGCbPS8SXZ1c4Ks1ubaZdqALvjngF4fZ6ZusFdzDkVkISPKqnt
# GR6VQk6jVgefwBYdvWN2UZ5je0+fzQwO1YiLIUAyp6S0ofOym/KKm14OarWcL9MU
# KCB+8Z4fWoRXyJT2WJVidtppDWA+fDFNWhTNYXXj6IuBYezONgF6wRZWrdyy6Pdi
# Gwg7uSfXWwyRuuA=
# SIG # End signature block
