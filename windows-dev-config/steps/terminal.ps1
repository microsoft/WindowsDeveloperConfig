<#
.SYNOPSIS
  Dark theme and Windows Terminal profile defaults.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigThemeKey = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$Script:DevConfigThemeSettings = @(
    @{ Name = 'AppsTheme'; KeyPath = $Script:DevConfigThemeKey; ValueName = 'AppsUseLightTheme'; Value = 0; ResetValue = 1 }
    @{ Name = 'SystemTheme'; KeyPath = $Script:DevConfigThemeKey; ValueName = 'SystemUsesLightTheme'; Value = 0; ResetValue = 1 }
)

function Test-DevConfigDarkThemeSet {
    foreach ($setting in $Script:DevConfigThemeSettings) {
        if (-not (Test-DevConfigRegistryValue -KeyPath $setting.KeyPath -ValueName $setting.ValueName -Value $setting.Value)) {
            return $false
        }
    }
    return $true
}

function Set-DevConfigDarkTheme {
    foreach ($setting in $Script:DevConfigThemeSettings) {
        Set-DevConfigRegistryValue -KeyPath $setting.KeyPath -ValueName $setting.ValueName -Value $setting.Value
    }
}

function Test-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        # Missing settings still need configuration when Terminal is installed but has not launched.
        return (-not (Get-DevConfigTerminalSettingsTarget))
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $current  = Get-DevConfigJsonValue -Object $settings -Path 'defaultProfile'
    if (-not $current) {
        return $false
    }
    if ($current -eq $Script:DevConfigPs7ProfileName) {
        return $true
    }

    $ps7 = Find-DevConfigPs7Profile -Settings $settings
    return [bool]($ps7 -and $current -eq (Get-DevConfigJsonValue -Object $ps7 -Path 'guid'))
}

function Set-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsTarget
    if (-not $path) {
        throw 'Windows Terminal is not installed, so its default profile cannot be set.'
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $ps7      = Find-DevConfigPs7Profile -Settings $settings

    # The documented profile name works before Terminal has listed the PowerShell 7 profile.
    $profileRef = if ($ps7) {
        Get-DevConfigJsonValue -Object $ps7 -Path 'guid'
    } else {
        $Script:DevConfigPs7ProfileName
    }

    Set-DevConfigJsonProperty -Object $settings -Name 'defaultProfile' -Value $profileRef
    Save-DevConfigTerminalSettings -Path $path -Settings $settings
    Write-Host "Set the Windows Terminal default profile to '$profileRef'."
}

function Invoke-TerminalPhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @(
            foreach ($setting in $Script:DevConfigThemeSettings) {
                New-DevConfigRegistryStep -Setting $setting -Reset
            }
            New-DevConfigStep -Name 'TerminalReset' -Description 'Remove Terminal defaults and PowerShell, Copilot, and Ubuntu profiles' -BestEffort `
                -Check { param($DistributionName) Reset-DevConfigTerminal -DistributionName $DistributionName -CheckOnly } `
                -Apply { param($DistributionName) Reset-DevConfigTerminal -DistributionName $DistributionName } `
                -ArgumentList @($Script:DevConfigWslDistributionName)
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # These user preferences are best-effort so later setup phases can continue.
    $steps = @(
        New-DevConfigStep -Name 'DarkTheme' -Description 'Force dark app/system theme' -BestEffort `
            -Check { Test-DevConfigDarkThemeSet } `
            -Apply { Set-DevConfigDarkTheme }
        New-DevConfigStep -Name 'Ps7DefaultProfile' -Description 'Set PowerShell 7 as the default Windows Terminal profile' -BestEffort `
            -Check { Test-DevConfigPs7DefaultProfile } `
            -Apply { Set-DevConfigPs7DefaultProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBZhUkjewpLCplm
# vGoEeNmxZlVNILWsKKrmvmaAJ4G5k6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIC3yCEQlMmSt7LEDPs6dfzEhWffX
# A9lJeiQqWgFNnhM9MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAFwZYBnuqDytN4GaCH/mYwxJbTiE8TIpcnpKZBgHYVleE25aksoZ7aGm4OLGA
# 3laoBfBJ+CD0QDUxUksW7/E2eqJnMQVCatUI2hKeXtGiLp0KQbB/EcyOsZatH6DZ
# NIvxaSR33JaB9ntRHwQj/XZnzC7Tc6ip1SfrAh4nZuFBbV7bOAFLVQK0JN1nQdHx
# oBqQ7/iwpbxEbqndTj+nn9u0Bj1qQUM6SE4AuuQVtQyw03ACP0NsZf9qYo67SDI3
# YlvgI4sGBw8CIXBP4hFFAId+SuxkUBqeUyf99f+sNlalyEIsE+SeH5McjAoj86KM
# tqFVecsCDkblpM9hxcxe3jWZf6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCB/tf2H1G/blMXXjB/hdUJuVAhvZ/D/CRuXru+oo5kI2AIGaq0qJpYPGBMy
# MDI2MTAwOTAwMTgzMy43MzVaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# QjA1LTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACEUUYOZtDz/xsAAEAAAIRMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgxM1oXDTI2MTExMzE4NDgxM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZCMDUtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAz7m7MxAdL5Vayrk7jsMo3Gnh
# N85ktHCZEvEcj4BIccHKd/NKC7uPvpX5dhO63W6VM5iCxklG8qQeVVrPaKvj8dYY
# JC7DNt4NN3XlVdC/voveJuPPhTJ/u7X+pYmV2qehTVPOOB1/hpmt51SzgxZczMdn
# Fl+X2e1PgutSA5CAh9/Xz5NW0CxnYVz8g0Vpxg+Bq32amktRXr8m3BSEgUs8jgWR
# PVzPHEczpbhloGGEfHaROmHhVKIqN+JhMweEjU2NXM2W6hm32j/QH/I/KWqNNfYc
# hHaG0xJljVTYoUKPpcQDuhH9dQKEgvGxj2U5/3Fq1em4dO6Ih04m6R+ttxr6Y8oR
# JH9ZhZ3sciFBIvZh7E2YFXOjP4MGybSylQTPDEFAtHHgpkskeEUhsPDR9VvWWhek
# hQx3qXaAKh+AkLmz/hpE3e0y+RIKO2AREjULJAKgf+R9QnNvqMeMkz9PGrjsijqW
# GzB2k2JNyaUYKlbmQweOabsCioiY2fJbimjVyFAGk5AeYddUFxvJGgRVCH7BeBPK
# Aq7MMOmSCTOMZ0Sw6zyNx4Uhh5Y0uJ0ZOoTKnB3KfdN/ba/eKHFeEhi3WqAfzTxi
# y0rMvhsfsXZK7zoclqaRvVl8Q48J174+eyriypY9HhU+ohgiYi4uQGDDVdTDeKDt
# oC/hD2Cn+ARzwE1rFfECAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRifUUDwOnqIcvf
# b53+yV0EZn7OcDAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEApEKdnMeIIUiU6Pat
# Z/qbrwiDzYUMKRczC4Bp/XY1S9NmHI+2c3dcpwH2SOmDfdvIIqt7mRrgvBPYOvJ9
# CtZS5eeIrsObC0b0ggKTv2wrTgWG+qktqNFEhQeipdURNLN68uHAm5edwBytd1kw
# y5r6B93klxDsldOmVWtw/ngj7knN09muCmwr17JnsMFcoIN/H59s+1RYN7Vid4+7
# nj8FcvYy9rbZOMndBzsTiosF1M+aMIJX2k3EVFVsuDL7/R5ppI9Tg7eWQOWKMZHP
# dsA3ZqWzDuhJqTzoFSQShnZenC+xq/z9BhHPFFbUtfjAoG6EDPjSQJYXmogja8OE
# a19xwnh3wVufeP+ck+/0gxNi7g+kO6WaOm052F4siD8xi6Uv75L7798lHvPThcxH
# HsgXqMY592d1wUof3tL/eDaQ0UhnYCU8yGkU2XJnctONnBKAvURAvf2qiIWDj4Lp
# cm0zA7VuofuJR1Tpuyc5p1ja52bNZBBVqAOwyDhAmqWsJXAjYXnssC/fJkee314F
# h+GIyMgvAPRScgqRZqV16dTBYvoe+w1n/wWs/ySTUsxDw4T/AITcu5PAsLnCVpAr
# DrFLRTFyut+eHUoG6UYZfj8/RsuQ42INse1pb/cPm7G2lcLJtkIKT80xvB1LiaNv
# PTBVEcmNSvFUM0xrXZXcYcxVXiYwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# QjA1LTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAKyp8q2VdgAq1VGkzd7PZwV6zNc2ggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5yrR0wIhgPMjAyNjEwMDkwMDAwMjlaGA8yMDI2MTAxMDAwMDAyOVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nKtHQIBADAHAgEAAgIbKzAHAgEAAgISbjAKAgUA
# 7nP+nQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQCaGPLNGRglF9rDqE7q
# KYR4/1Fkxxv5TnpJ0UKAp08SiOI2RJFxxAvdYwvvRd50RA0O1wR0JFPG9Gae7gq2
# qn5JLsO2cjclQoNa7bzXo7EeEtbitpHdDVduvrZG+HjH8Y47mch5qheUHS2rZtpw
# nLDJrWbSftmKHtMAE96fzObdcR+9vNdNZRM3wbxQf3dlbO6xCRSoTsj7QGwwutUB
# Wn71m3Q7Sn23bqBRaB0UV+MMOGeMxTCxdIWUBCglQFc1V9Sv9guB9eRmKPnZg6ck
# i0sEUfEUFTygReLjpmsV2NtQt3Z7BIWVF4kEngXHQ8BTXmAc2VObKknL59ySP4dD
# xLTHMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIRRRg5m0PP/GwAAQAAAhEwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgLqfvaIWq9y8ZH5wF
# w/M4mdmJB4OxfLTpxx82xyQwCzEwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCAsrTOpmu+HTq1aXFwvlhjF8p2nUCNNCEX/OWLHNDMmtzCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACEUUYOZtDz/xsAAEAAAIRMCIE
# IPxKoOP54IwSVSsxAJOqWKnqn/hoy0tgwGPrU21HvC27MA0GCSqGSIb3DQEBCwUA
# BIICAB2L4RBbZr9wi/TeZx4DW1SwhwPGCsLZaY8bpoVhGMCI4Y2uGta4JFEEdIUe
# NQXnSmGu29fCijZooGglJ8pCUTCtUjn2Uma0HN5ERs9Mfr3O4pZjP+jUkT42uuip
# jv47T5HjQaxzn2CSGUQPT+HJ4lu+W4fpS5amcuT8e+q239SjpT2JQ363EF+PvomT
# WD6Dk8fSey23x1TXTeFdE/k7cQ//pVSxn1HE0Ce174Vhqjq+0wrMU3ZfStuDIY4S
# /XyyKM+T/LEg4+Yk0xM8eNNmiVpCphyNTmAZHd17KMMVlR2c5+90JcF+mM13/DVh
# eZho35Brc5FQZ7gqC1ZDzadsl0evT5oRESEMM/GB03rbDF7SnMA94yRc/3tvBl5Y
# ZP+hNmFU18+lNGEkGnlbIooYzEbfEhOz83L73uf92iWzEqc8FuTmTjkN0Cs1hjiq
# CTKRvSIW7QgXme5CP9xvsIpJokxbdQ7q5sgbYr3/r8Lemb0kis3wwDswO6p+Ln8r
# 8v6VLogSwH19w+N9B7I4Ini1tjMdFqe+rXi8RWdLiD35bvrmoH+SqOqCuXJ7iota
# gps2hja0RUd1yVYkSXZRwj+t7Un5AOaSYagThf0IecPfWAaQg46GKer1AxP18UV2
# 0ntJ7tDJ1PFQydQ/fCF5njqQkehdhfOilQr8IiFqRcHLyDbp
# SIG # End signature block
