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
    # Reset Terminal after removing the tools and WSL fragments that can recreate profiles.
    $phases = @($phases | Where-Object { $_.File -notin @('packages.ps1', 'terminal.ps1') }) +
        @($phases | Where-Object { $_.File -eq 'packages.ps1' }) +
        @($phases | Where-Object { $_.File -eq 'terminal.ps1' })
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
# MIInNgYJKoZIhvcNAQcCoIInJzCCJyMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBPCvhr2A2cz3z7
# fkzCXnI0gxoVSev9B5yNDKuwO1hjMqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnDMIIZvwIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEINBrw8FA5qEWx8yXQaImdpHQySpi
# 8MbNSdFU+5a/QhHPMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAEpWMi+/w00WwwIlH4CyqNuHXQsV3WoO9qHF35id2AQS1yOVoKWf8OkViSvEN
# d86FQKBe4v5C473/sG55X03WFV66FrUeNk2a4HFDckxUJBJjDw8Es/8vtuPQbYML
# MD9f5ArQTdA5m3C7plTq9dLabYXPHDd0CuwFChCQz9hGUYahDCbvrRABCItzqoD1
# wdbW9AeDc5nYWRjaSYYJtwZ/TdXS/JdATQN+0vHQLw5PjNsLv1dx6wjJT7TEUR+u
# wt+bwabYhgR3zM137ZSn4Js5mhbu0/R5xxOdREqiuMiVaeGI8FP6aLgel2CudQg5
# +1w0Hk/FX8Rat+QWbwq8/Fi8vaGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sG
# CSqGSIb3DQEHAqCCF2wwghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG
# 9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCYWgA9h+WIvD/i0FAehyod/D/7Mo8KUgUEfC09dZbj2AIGaqppheEtGBIy
# MDI2MTAwNzAwMjgxOC4zM1owBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo5NjAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeow
# ggcgMIIFCKADAgECAhMzAAACJjW0PmdDk/YfAAEAAAImMA0GCSqGSIb3DQEBCwUA
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5NDAwMloX
# DTI3MDUxNzE5NDAwMlowgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjo5NjAwLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAL//D5lkgvlEUWlUjwPdnK427wjNwAQ4PfQ4tiOHffuteNys
# iU5LOklzhl5TETKWLrHoXrObg1Hx1s9v12IOn+E5TMdYbGIDVndFcoFv/gX+iPK8
# 3jdIQZapJ9VzcjcGWxhPfl5xUAn2RV/3Rg6/b20WMkEFmRi+tP8PDDJEuxw7I/in
# 73+XImMP5QuzdhcGFWt9n4xtAH4FgoupG8EpuP/BH1qQ2szFAg2gZoPmNk783+dK
# yYbY/XO/9y/iBKgwGdZ5AgGSN3YjnDUN5e6mna9KI2ZHmwDZmQErfKJBZom9HE4O
# WR+LIeT0yST9OthOOaM8JuF766qEc1HLxSVs69awKrS1G1TKQe/f0OCoB8k2sTw5
# K3zfmsHMOmutwCHCaB+GhWLgAp6rCKRjSdRrjwrRDLzRdPh+IQDcTERk1pEWj02r
# 8bBt+CoqoaZz3GEq5EVyO25rgodm+cC+laAQVI4KSi9ez8FwueQQcz3FnyJRqDkL
# KE2pdhgT/PSlxd1ho0iRDrwRaa68ubuD2ih9Xa86bkZU2iCGeRYbqcY+j8nASCYD
# 2hJLQR+8VExY8D+ClK8XeyECsoedoSlVJKLcM1vKK5iISz0qjQiRlzzEoV5BFqoZ
# HGsH7av/sHdfzVOmz30qEXCD7APzuh3bYXYxSDXHu3C3eBpWcWTQhkjBQ8IbAgMB
# AAGjggFJMIIBRTAdBgNVHQ4EFgQUXeGf19gk3Zj9n0tVsE8jEDNcexAwHwYDVR0j
# BBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggr
# BgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0T
# AQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4Aw
# DQYJKoZIhvcNAQELBQADggIBADZTHS2v2xgKOyrQVHKJWnHXk66s1e/pCTuJf4Ct
# U+XPfDi2qNxM2bV23e1O5rbAkykmE8fyftReGZP3x3kO7jguXhp2ex7hJB9WDdAv
# ppGRceclSfzL2J+0H8/Lbaf3GfA8V+PdCUM5KAu4eV673tTSIfZlqW5hptZcmKF2
# Jikrxw8cWWpk4CKi3T4YPx0/5Ey6+nG38XYuZh6WmhnCuKIU5SaXERRXvEkfJlmU
# Oq6yR7K6rTUNO/3U3iozxx88+GX/alzgd4x/+d3Yei6J8lsNAU13hY+EvOfRLLe7
# VmHf5Le2NB2o353LDrRFpX5FcKg4uAVncwCD8agOX5+9vmHL/VrvVy1fzARp3U9/
# p15/amp+XfAVz76GQXwNddNmh8k3hhVo3cifBsAZAMOQ0riWp5wKLHGZIrCJ0/Kc
# Z4Tk6282grWmQuyb+LwXVGMZzNn+RIXZUOSobzrqJD6NVsY5DoO7d7LIVwUpmgMn
# gHmYQBL1pPZIqqWUt7Js5ugfqvruyJHkH/Yee7v4pi5hnLQERp20DqeAbhydJH0m
# yuSGGwqZvXW6OrCAnI3H3YyygYbA2A3VojRAgPwKyMIXCl+YzOUDjjEcpi/eGaPF
# 6oFLi5TmtB6ICdWCkl5pUYqb+XM8O2emkZX7teFGnlvVnFP9ntfFz4jsfv+MK1AN
# mhplMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0B
# AQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAG
# A1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAw
# HhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOTh
# pkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xP
# x2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ
# 3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOt
# gFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYt
# cI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXA
# hjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0S
# idb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSC
# D/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEB
# c8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh
# 8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8Fdsa
# N8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkr
# BgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q
# /y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBR
# BgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsG
# AQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAP
# BgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjE
# MFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kv
# Y3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEF
# BQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEB
# CwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnX
# wnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOw
# Bb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jf
# ZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ
# 5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+
# ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgs
# sU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6
# OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p
# /cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6
# TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784
# cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA00wggI1
# AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAKL98zEW
# 2Sqvtcxd2xHJZTSVIodnoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTAwDQYJKoZIhvcNAQELBQACBQDub+uHMCIYDzIwMjYxMDA2MjE0OTU5WhgP
# MjAyNjEwMDcyMTQ5NTlaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO5v64cCAQAw
# BwIBAAICM7UwBwIBAAICEHowCgIFAO5xPQcCAQAwNgYKKwYBBAGEWQoEAjEoMCYw
# DAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0B
# AQsFAAOCAQEAi5BlsEZYsddw3sgxOtRmqNFl8+j7CyrWMsmGUHNh/70wHCOrp7Vz
# 0DJ4Pg1H8ZOVUYTaUKL+JBOxzsLydqcT2m1gEmE9Bq83Ob3AhMuWzYZ312966M4n
# yMBgYxgWgwKwgkAKfdHv2TFfSKveqo5D5DIorMYditLJ0hxsYiXB+XiR8QV6gJBy
# JTb9B2COOY5oloLfl2e+8GsTTV4BuyJ5v+EWNcHJmZKR2HbDVvHJi8gRzoF6hKjg
# pFyLqDZAhHViOSQO0ZeMU2osM5eTZwYs+vpJZHvJTXG+yxqoMIJm/sb4sS4REIZ+
# gHL2iwE8vZ3fT+nQ3J072VEJG5V7bXjsnDGCBA0wggQJAgEBMIGTMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACJjW0PmdDk/YfAAEAAAImMA0GCWCG
# SAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZI
# hvcNAQkEMSIEIKms5zXWjX3w1STW2mdNYQxJpnd3lyqncXia7hQjrLBZMIH6Bgsq
# hkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgzDJcYWdM2xlEGuzoY38FtXSiRo0/dUFi
# osWNSwWduCowgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAIT
# MwAAAiY1tD5nQ5P2HwABAAACJjAiBCCBpSDSa4NWiwz9HyGHgbGD+WDv4ZdC2B3y
# oGNzD7yTazANBgkqhkiG9w0BAQsFAASCAgA3KAFGpcxb2if+XNtTvPpLN3Y9tdgw
# 1Oh73TUqWSjONTg5kgqODvrIq7tzMZngFBK+7EoRXktpLbL/4BmtPwe37pm87iIc
# uXUrrr8QnREX4yDuvN7WJdOemL4PGx9k2rifXMMU05mHDWdaJJn12zAnMmi1dSde
# 75nbRR30wf/+CuaTBEVObmagjCLKNkfeMtZQwhbDiJI2n/TYarooAdvtZxowvHuv
# uXNv/G31ekLD5NW64pgbzJTBQ0VHLGaL811caHeVkFOz58wjP9fZPzeWzEfZokdn
# 9AC6Iqx+6QNSCtmrFUdyD0DjYQYdm0ujZu04usSMl7wcJzZuMiIvNFKvWzquW+TD
# 0a9zZjrY7ZeEeeR3LaHiKEcImHaU2/wQIkkMP+D17L1tGkWWQiqzrstAgqKZCbPA
# VIYKCeqlBvXgGl/bwnDER/y6fyJJIcTqAL42AHgpnN4H6BsBBALgv0fn/+Qi5iFr
# 5fD2HZidOVCWOHbhtxuYxa9O8mn3cpgLR8NKpb9b7kcJN2Zn3oAJ7c1QlyWahPh7
# 5Ork2k6mL3z4h+CbuprrNaxpU762SHsw7MXY46XrVI+18zr1O75vfhKx9OUsRkqw
# N+zVFWSV6X6ZfiAXz4QxjY6PffwSddO/+A44YRBKg6qo3TjLJT9jLffXx8d2cnbN
# Aa8Lu0z+p5lt8w==
# SIG # End signature block
