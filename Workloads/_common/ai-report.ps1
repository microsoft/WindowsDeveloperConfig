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
# AQUABCD9UkiwFGvjiHc8AJuWCTFoXwjN7wZuIoIVBqpuIe/h2QIGarfwfBfhGBMy
# MDI2MTAwODAzMDIwMy44ODNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiEzwDX70g8hpAABAAACITANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTRa
# Fw0yNzA1MTcxOTM5NTRaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDbcTACqU1YvRocyWL2PL9fyf/+ULs2qK7U1aZsRnDZSnlC
# r7K7jgA3eFCEJL5BZ7dUTC0DeZepf+ZC+7HEbB4IdzmJfQAUDFFerqY5VTHmQvP2
# XA3lWSFj740idcGUHglP5H/PbCJU7GAHWP2HdcCjdx1lYAo0A+zLI7xwnTQeMyOX
# X212Eg4UmDPPJgxdTMw6WFVWsBPWRBi5gDixy2s+7R8ADk5lbBBFDB5h0CjrNWIN
# 7uCAzF5g7trrL8nXIKp10mj9RxhcGQ+tlht6VIvdygRVTUGdzFB2/nBvJqQ9kxxF
# ltQST70fEdx4TyaKow/f5+BSh4z4/9f7NXIVVTLn/8kcJAfRqFmRrrFt3IKby7Vr
# zmYuoQWD0lmNFtGQ57BrJkPrPFAPek1ALtcbb7FH3nQpvi8ngz/MFX/+cnmNFWFU
# 29VVLmzB9XvLZxbYvkeett0mh5lfteeN2rEwUyrdrKufz9h2S6pbate+C2h02CrX
# wSka0x6ezpTmGkIJLFt25ub/UYXNLdHdsxGD6EfckOIoJYsm4MS9F/vSqLNHK89I
# 0vTLBngQEp6LIFkINanRT3PtNx3pNKRKJRALc6L6mhW4hL4aHL749qPfQ72t5qAM
# m5xiKYMgJ2WanidRLNuI251JIN7raaeA/2vb0XFkZcIbTR1pfQGsco4U0g5tjwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFOYjIs5qa6pfuquPyyK1FTr5QDCnMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA4I/3bkdnTxD2rFum3MF8xVKdEkohAObbePrQ+
# 0fr5bRimjz9sVkKT/7gcj4OMcClSYG+IdX6Mp3EYsLHWfjvwfzFoeZE+yTbdBj/1
# VHZQRuCmw6QqeVCTbw2nnS7nBxnWd9oZXbPUpqEawH5DqXQaWFgR9A4KWVK/IvXV
# DMj1PlPCES1P3JonNbdhkkkz49rJuKOm5b7e/BH8loqAmXOXRc22yxWVTMWrEp4p
# slmv8eT7VoY8X/jdKYTPVEXsfmLbVFcqzMuB8vFGfUyWsWROS8wgq7lQYfWcYqh7
# NymoATX+wWYK3zWG7aRciPGUAzznXdf+aHtIWnQLNa5HFmSXkiak3fSuprWYZiHh
# uYjE16hroApcBHpm+8S/kNqhm9WjQX+2BxnYv+Jejy6lqTi8fLBLS069WXVw/ptf
# 5IV+FtYl34GvVoeg31UoUmVVZe1SDUJkm9dDXc8l/qBDYiAIT2CCsPTyt9XA9JVu
# HxdP63n7ChvWAO/47QRuCDsUlFJoWwyBwl7jeYpaRVMtQt0iuJMGGjgEaJX1Q/2j
# 8sXURvTceLHDD9ipWt092ZDWMQciDRmhHNFOX1dnjBvk/k1UMcg997j5oYznAnSp
# Jvlg/4BP3aVE0h/YH2KgsKbU4NXZHAjJXj2Slqo1C115CG6qBZaFkM8W6vPZCm5q
# nSezOjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjMzMDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQALbEgZ
# ZnyYHXJ1DGb5fGjplXptuaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nDtojAiGA8yMDI2MTAwNzE2MTExNFoY
# DzIwMjYxMDA4MTYxMTE0WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucO2iAgEA
# MAcCAQACAgD1MAcCAQACAhHmMAoCBQDucj8iAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAAqW18ZdP2wjdlV1xQlVl1dXGznRfYc1Vjdc5L/EPaMP3qgF1ZfB
# 3m8T0m13kWqJJwTuHKDSM06hOMgPSX43d3HULJpEeiayooNUyHepKzXvYNXE0nqp
# 6xVe0+Ag1Pv2OCfiiArXAE0quKXFW7foKdbZfgyKp5yZ7Htw45EjX8T5aHUAYdWY
# xlvxQXlsSIkVCeTSf2822GT/NqLRHQmd2xC2gU7BjmvafMS7jrh6EmP6lBOdKilc
# ZHkndBbmSAKHau+AgQ5hGoUDbJi+1/p2QaQ3sFcEuJSE+6XDDMxVhh1KPM5hAXj1
# sNDXrRRk1JMUQ/EtTHnkpqyWLJX5sdMYlBQxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiEzwDX70g8hpAABAAACITANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCADAWkpPdY32OfSjkvBhl0gA7lV6wiiajahFjdB5NjxzjCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIADvIQefFVUa4BJy8IZywMAvmGSKdUVq
# Emy9A++PCj1EMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIhM8A1+9IPIaQAAQAAAiEwIgQgHGMCfjkoXCvG5nhW5+ICmXx1sBvT2iQs
# 5uWulJt4iuowDQYJKoZIhvcNAQELBQAEggIA0M9tUs44fIdV5G4xwTz66yqj3req
# 1JRp6sgmY4Ce6BWO5MadaX8K3saBSU31F5cQa/whFNQkPo5D1KIME5GFJYMvV4g+
# ZurJgJwdTeZhTHoyUpOdvsj7cPjm4XSvi167gDdTzfPOnhCBXwfnEg3FuJyaXAE6
# N7LmnNHU4Jk8741Z6S5TVMG4FGTnTpjExou6Tdi8NVvAThOAI6ZUc9D95KagIsEi
# DEpjHdeEmtdjII8R0IgAfzOe1bYrFbj4NnSCEf+ZHX+9FgH72UohesgaFhtkGpD7
# VFo+X4z1GSgM2GEKfa1YCVtFmGRwy/x7ijDL4xGTpO4UcOZC7PHZbosPsHbJwHBQ
# ULCmGFryjC6LCgZkTZpUEjicqiaN2wjveWa+g7phGHbZnq9CHnsJOKfIaqmsmqzN
# Z9Y6n8TcYIKOajB+HXsxopt+3oQTcgWgzW2VoSA2PP6BXH8EklYykoAxGNa4Kuk2
# LNtZlhBSpGwrhx0OfkJ3F/WX0cLM3ojdnU+S/WwjoC/08BBZw6r28NIw6TtiN8I0
# F7N8HNTukC1WFiE8UrKfsykPo/1NpdTyyK7KEafODFqY6iW/XEEZNSXINPEiWe7o
# XOxw7cVuMp65FBHVbgsA2sQLEGRM6i0SiIYnJtR9KTUIIElKAeU/y+4fdGYm2fXJ
# wx3TXfGarF28Ug0=
# SIG # End signature block
