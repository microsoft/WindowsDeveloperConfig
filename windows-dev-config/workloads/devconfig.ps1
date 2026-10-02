<#
.SYNOPSIS
  Windows Dev Config: developer tools, Windows settings, fonts, Terminal, and WSL + Ubuntu.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It only lists phases; the phase files under
  steps\ do the work. This is the default workload behind setup-full.ps1,
  setup-standard.ps1 (Partial), and uninstall.ps1.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# WSL stays last so its required reboot happens after other phases.
$phases = @(
    @{
        File     = 'prerequisites.ps1'
        Function = 'Invoke-PrerequisitesPhase'
        Title    = 'Getting ready'
    }
    @{
        File       = 'packages.ps1'
        Function   = 'Invoke-PackagesPhase'
        Title      = 'Packages'
        Uninstall  = $true
        # Install order; names refer to the package catalog in steps\packages.ps1.
        Parameters = @{
            Packages = @(
                'Terminal'
                'IntelligentTerminal'
                'PowerShell'
                'Git'
                'GitHubCLI'
                'AzureCLI'
                'GitHubCopilot'
                'VSCode'
                'DotnetSdk'
                'Python'
                'VCRedist'
                'UV'
                'NodeJS'
                'nvmForNode'
                'Coreutils'
                'OhMyPosh'
                'winappCli'
                'PowerToys'
            )
        }
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

@{
    Name             = 'Calm OS'
    Actions          = @('Full', 'Partial', 'Uninstall')
    SetupNote        = 'one reboot expected along the way'
    UninstallWarning = 'Ubuntu and its files will be deleted. Targeted tools are removed even if they predate setup.'
    Notes            = @('A few Explorer and taskbar changes appear once you sign out and back in.')
    Phases           = $phases
}

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBte8DpWIQvHH0K
# HLBXAMCL0lFCDuGaE58+Hg3K2R2rJ6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIEQZnsVV5LGjBAZ6KVMJnKff84CL
# fV/QBfZyBa9UNlGBMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAzdp42wFQAC8jgP/zYB/mutz0rFUOzU07nEA79NSRUFhsvIckcM+7mx5gk38x
# kdeAAxNHaDnhbG5xuQD6L7320vpoJvV5RBnFFUSDMZbP1KyP3gKKEl4ejfEq3VN7
# pBxNGAfhnbCraqM3l+xGX6ubqlhpT9R1mI+0HfJ9Udz9/5J0F5Sdk+BdfWYV/HWP
# V9dmCJ+uaxwQCYx4u+cW7uM/ky1V4rIX9G6pjxDBvfsD/Pb9peyrNHiO2/obuHLt
# TuPFm3ZAwB0DbSM6gUU9/BG7gXHGStNBVEZ4cmDF94XbuW+2WFT8A52Khxcj1VIF
# XuT0+6nXm/bpMl78xTGRU1zLjKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDJijITVAH6cTXbneQSCryhUGlCf46CW7gjwBhPF4R2GAIGaqpov2UwGBMy
# MDI2MTAwMjAwMTQwOS43OTdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiY1tD5nQ5P2HwABAAACJjANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDJa
# Fw0yNzA1MTcxOTQwMDJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC//w+ZZIL5RFFpVI8D3ZyuNu8IzcAEOD30OLYjh337rXjc
# rIlOSzpJc4ZeUxEyli6x6F6zm4NR8dbPb9diDp/hOUzHWGxiA1Z3RXKBb/4F/ojy
# vN43SEGWqSfVc3I3BlsYT35ecVAJ9kVf90YOv29tFjJBBZkYvrT/DwwyRLscOyP4
# p+9/lyJjD+ULs3YXBhVrfZ+MbQB+BYKLqRvBKbj/wR9akNrMxQINoGaD5jZO/N/n
# SsmG2P1zv/cv4gSoMBnWeQIBkjd2I5w1DeXupp2vSiNmR5sA2ZkBK3yiQWaJvRxO
# DlkfiyHk9Mkk/TrYTjmjPCbhe+uqhHNRy8UlbOvWsCq0tRtUykHv39DgqAfJNrE8
# OSt835rBzDprrcAhwmgfhoVi4AKeqwikY0nUa48K0Qy80XT4fiEA3ExEZNaRFo9N
# q/GwbfgqKqGmc9xhKuRFcjtua4KHZvnAvpWgEFSOCkovXs/BcLnkEHM9xZ8iUag5
# CyhNqXYYE/z0pcXdYaNIkQ68EWmuvLm7g9oofV2vOm5GVNoghnkWG6nGPo/JwEgm
# A9oSS0EfvFRMWPA/gpSvF3shArKHnaEpVSSi3DNbyiuYiEs9Ko0IkZc8xKFeQRaq
# GRxrB+2r/7B3X81Tps99KhFwg+wD87od22F2MUg1x7twt3gaVnFk0IZIwUPCGwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFF3hn9fYJN2Y/Z9LVbBPIxAzXHsQMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA2Ux0tr9sYCjsq0FRyiVpx15OurNXv6Qk7iX+A
# rVPlz3w4tqjcTNm1dt3tTua2wJMpJhPH8n7UXhmT98d5Du44Ll4adnse4SQfVg3Q
# L6aRkXHnJUn8y9iftB/Py22n9xnwPFfj3QlDOSgLuHleu97U0iH2ZaluYabWXJih
# diYpK8cPHFlqZOAiot0+GD8dP+RMuvpxt/F2LmYelpoZwriiFOUmlxEUV7xJHyZZ
# lDquskeyuq01DTv91N4qM8cfPPhl/2pc4HeMf/nd2HouifJbDQFNd4WPhLzn0Sy3
# u1Zh3+S3tjQdqN+dyw60RaV+RXCoOLgFZ3MAg/GoDl+fvb5hy/1a71ctX8wEad1P
# f6def2pqfl3wFc++hkF8DXXTZofJN4YVaN3InwbAGQDDkNK4lqecCixxmSKwidPy
# nGeE5OtvNoK1pkLsm/i8F1RjGczZ/kSF2VDkqG866iQ+jVbGOQ6Du3eyyFcFKZoD
# J4B5mEAS9aT2SKqllLeybOboH6r67siR5B/2Hnu7+KYuYZy0BEadtA6ngG4cnSR9
# JsrkhhsKmb11ujqwgJyNx92MsoGGwNgN1aI0QID8CsjCFwpfmMzlA44xHKYv3hmj
# xeqBS4uU5rQeiAnVgpJeaVGKm/lzPDtnppGV+7XhRp5b1ZxT/Z7Xxc+I7H7/jCtQ
# DZoaZTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjk2MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCi/fMx
# Ftkqr7XMXdsRyWU0lSKHZ6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mlUBjAiGA8yMDI2MTAwMTIxNDk1OFoY
# DzIwMjYxMDAyMjE0OTU4WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuaVQGAgEA
# MAcCAQACAifLMAcCAQACAhQMMAoCBQDuaqWGAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBADfWK8FJNFCHIutcwaNTiqnfKIWT7gw7Ie503NGS7PO3c7moIRkL
# nDUdhRXHNUPdZZk1o71D4eS9arjRMrv4dEuWILpnTctn0FkdF0lfbbdE9xaO+pok
# sE7qUh7FVRHzFSUSIwH76TciEaHvITal2n6f+6V4pGzvDmM4ShbqiXse+XVoSN1i
# QEFj6P3DIcpeg9onjWxddGAyDD/HWIcf8ky4hnJe+hnXsFq7p33D0+h5CO+B6aLQ
# yL6/KLsiBtFe/3Sf9kgGCUokGlSMGwN+osw0oJoGIaCl1ULCnJ46rFc61Y7LE7ZM
# gq0Cl+iaOgL+U5UHv86wqLt9RJnmb0yeJCgxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCCg7+pG78m/nBdEWI9Yh1rjYml9nkniElD2cfUqD8HbdTCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaNP3VB
# YqLFjUsFnbgqMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAImNbQ+Z0OT9h8AAQAAAiYwIgQgZPa2+BiHJ32O4XNbA9Ln4Y8xX7UBc3GQ
# mZ55BpKLqHIwDQYJKoZIhvcNAQELBQAEggIArlZcCJ5WTIkHZhgT67U1L3kt2DCb
# IQ1RxFDx4LZPAXwP/PGm2bVg61UzXRjQy4h0M4776mnc07UVN+gP3RB6EogLT4YS
# YOF5P8QzFPSCGFnRfCkur1GaKnrPoQs6v9w5WfGHC6Jl0YRF3KbX6o4FXXpUUkgB
# 4XHbxWsJNYsmtjZBVzfIiAqPzQixpm9IKJ9X9K40cYTEVvr8aZNgObUo6iSTYM4Y
# YTvm0c29wkT/306j5Ez4Ovcgt6Y9pOqRPolax0F9ZE+mZs1XMMSU7eyH6tsrGq/y
# S0il4vHRDluVZHHGQ9NfwePNrA3TDHhOtAtfvCg/GV10JEtU16usNRlkYSPZm+2i
# 7ASWP09V/f/KozWrtJb0J/kLqRU71CZdbnSwikeMSxJ8mv/IlS3Zkug/q9x40yWC
# ad3H7i1uioHelYLHsQ24Y6EPMepWofJVgn1aXQy0YyN7VlSTB3sLt7At+uoaVU/o
# 7GAz/CUKfQO5tri4JMcJhtoio6/VKl6BF6BFIo6RNRCXwkg05SVhdxnGPBA5w5bC
# dO+kUaFbcnpZT/bOEkuyrJfzocCZAtQG+y7ux55zMOxvc4Li6tYBW8vDN3hjZcg/
# swdZY5JtW0BoQ80BFimqQduu1t7OnTPoq5dXgM6MBboP9Zhby5SH2H3k9R9IyujY
# buhbBR9LS0C8N24=
# SIG # End signature block
