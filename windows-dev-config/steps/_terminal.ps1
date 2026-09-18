<#
.SYNOPSIS
  Shared helpers for locating, reading, and safely writing Windows Terminal settings.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Terminal settings are deeply nested, so ConvertTo-Json needs a depth that preserves custom files.
$Script:DevConfigTerminalJsonDepth = 32

# The settings schema accepts a profile name for defaultProfile when a GUID is not available.
$Script:DevConfigPs7ProfileName = 'PowerShell'

# Paths already backed up in this run, so a later phase cannot overwrite the pre-run original.
$Script:DevConfigTerminalBackedUp = @()

# Stable Terminal is preferred over Preview because it is the profile users launch by default.
function Get-DevConfigTerminalPackagedSettingsPath {
    $packagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
    foreach ($pattern in 'Microsoft.WindowsTerminal_*', 'Microsoft.WindowsTerminalPreview_*') {
        $dir = Get-ChildItem -Path $packagesDir -Filter $pattern -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($dir) {
            return Join-Path $dir.FullName 'LocalState\settings.json'
        }
    }
    return $null
}

function Get-DevConfigTerminalUnpackagedSettingsPath {
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
}

function Get-DevConfigTerminalSettingsPath {
    $candidates = @(
        Get-DevConfigTerminalPackagedSettingsPath
        Get-DevConfigTerminalUnpackagedSettingsPath
    )
    return $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# A null target means Terminal is not installed, so configuration can be skipped.
function Get-DevConfigTerminalSettingsTarget {
    $existing = Get-DevConfigTerminalSettingsPath
    if ($existing) {
        return $existing
    }
    return Get-DevConfigTerminalPackagedSettingsPath
}

# An empty object lets first-run Terminal settings merge with Terminal defaults.
function Read-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{}
    }

    # A zero-byte settings file is treated like an unwritten first-run file.
    $raw = Read-DevConfigTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }

    # Invalid JSON stops the run so a hand-edited settings file is not overwritten.
    try {
        $settings = $raw | ConvertFrom-Json
        if ($null -eq $settings) {
            return [pscustomobject]@{}
        }
        return $settings
    } catch {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            throw "PowerShell 7 is required to safely read Windows Terminal's settings, so $Path was left untouched."
        }
        throw "Windows Terminal's settings file couldn't be read as JSON, so it was left untouched. Fix or rename $Path and run this again."
    }
}

# Backup preserves the original JSONC because JSON conversion drops comments.
function Save-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Settings
    )
    if ((Test-Path -LiteralPath $Path) -and ($Script:DevConfigTerminalBackedUp -notcontains $Path)) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        $Script:DevConfigTerminalBackedUp += $Path
    }
    $json = $Settings | ConvertTo-Json -Depth $Script:DevConfigTerminalJsonDepth
    Write-DevConfigTextFile -Path $Path -Content $json
}

function Resolve-DevConfigJsonBranch {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Path
    )
    $node = $Object
    foreach ($name in $Path) {
        if (-not $node.PSObject.Properties[$name]) {
            $node | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{})
        }
        $node = $node.PSObject.Properties[$name].Value
    }
    return $node
}

# Add-Member cannot update existing properties, so creation and assignment are handled separately.
function Set-DevConfigJsonProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

# Strict mode requires defensive reads when any nested setting may be absent.
function Get-DevConfigJsonValue {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Path
    )
    $node = $Object
    foreach ($name in $Path) {
        if ($null -eq $node) {
            return $null
        }
        $property = $node.PSObject.Properties[$name]
        if (-not $property) {
            return $null
        }
        $node = $property.Value
    }
    return $node
}

# Built-in profiles may omit source, so profile fields are read defensively.
function Find-DevConfigPs7Profile {
    param(
        [Parameter(Mandatory)] [object] $Settings
    )
    $list = Get-DevConfigJsonValue -Object $Settings -Path 'profiles', 'list'
    if (-not $list) {
        return $null
    }
    return $list | Where-Object {
        (Get-DevConfigJsonValue -Object $_ -Path 'source') -eq 'Windows.Terminal.PowershellCore' -or
        (Get-DevConfigJsonValue -Object $_ -Path 'name')   -eq $Script:DevConfigPs7ProfileName
    } | Select-Object -First 1
}

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDcAeAp8t6JtNZL
# jENti4DjXd+TpdxrS8aJpmCYkB3AMKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIIlu3Adam9482TXbqDRvyYCQOG3Kcz82RefjFgtCyiLzMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAMaEdcb0HnuhYgI88
# xeWdhTniATALqk04NOpXq8xh8+PzQQ6xYEQk3L+7sbBIjOrCbJMiWNctMc6/tW/b
# 743l9jO9+JMNBphmmFxCV6g6vsF+U235NtYTloaXBZLwsBqt65T5YHL2Jnvgds/M
# 3AWa9zq5HZylujGjBjwHDbsHe/GpdOhdBpW3mQrHm7sG/FM5y8IntghmGGriKNQ1
# nq+vUxqEqv8EOI+ngm2bRdLVE4oteRTF77wjWv+TkJH14XAJiYpIWUeqt/5559rp
# hDLWld+2at4HlLykE0LTJkuE+PjgSq7PdTPaJJGXJ9BMtDk3NKRb6LPBniZl9vmb
# 7koA+6GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCg3oAhvsfXS1Zt
# uArsmLuGMkn78H+ykJOhZ90I5KSqqQIGaqk1WUhbGBMyMDI2MDkxODA1MjEyMy45
# MTRaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAijwpYfX88geQAABAAACKDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDZaFw0yNzA1MTcxOTQwMDZa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# jvbk/sqcCSReZaJfCuf1NwRcc7XknhE6wkLofkNj1mxEAg35qy2xcFjgjartVvA0
# 9W8QHcpyMqVSXOTxNHJsmk0qP2CDLvUAulWg7aS5oBORpEX1oz3n0R2nPqeH0IHK
# 1zJxjxaHW21AbuZ0Z+wM3WYNzkBlcHmVe03ZG7rlk28h72r5P5ME8FGpFmYW5Hl7
# psKbgLEfrYAitpttsb+sZsBUI+hMKl4uLJYotKyZv1ewOIinBfRU8QosivjofaBe
# zUf9NdV+iGrWh321WnSsK3A/Jl6GLtbSWXcJWULgbxuqnobPK+YlB3174TMWTgX4
# YWjG7o0Otz/pjHNCKBbB788dynhLdGY6B08E9+4SGrRpsty4iJHOydHCA5M4i5yY
# Rwsdut+gmvxIpT8yNXJcjJCg0vO8mv/nFY9Wytv2qmCtCFFivGUWqU20/sUeRooQ
# ZGiQOJQn095Cj3isIsvRP8KU7hN/EDI8HVsb/NPzMFLvRznrRnj0TOnDiOTUcnYw
# mk+XfoS1owskcCCCwHnbC00D58z83y7K5ZJB745hcn4CE2nR3e6RGsr42y5qtt6M
# dz/s7MTnDS2UmVHWX1X/HZe3UlX8gj/t63L50xIPqkRCBEdM1ADNUaSfo9OQiKb/
# bj1diZCGTfEDUBBLop1mhkwIF82faplV2busZ+U4kQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFKrJpYz48tzouvVkBVthASFpQ93DMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCQ6NfLmrRahgVtgWg383GaS07fHyod6bhcUONt2tet+6BaNuH0r7ABkVHh
# eOpxBdrUrOEYVEaIii9dK3cuZLNmp1iUAx/VbmOZYl7xz+tNrjCWqrg1jQmq0oRB
# 8iE4QJpwNhGP67oY5huYIU0D4lhDoahqfgKJn/0Bk+9UKDPw5XlUYmreFmJlj9YQ
# zcPPep8MxBXxh/Y5I7vQeRaW5SjtiLQOLRk3ggvraDs5Sf49MJV6/BwxXC2rvUfE
# FX6SUDooqKIE9NgVIRq0RZu7Ot0i0Is+HvPP0hB6KwOxMg1SWKOfTtFpWpdo8MJv
# gKCHkPpXEzgprP+pyIHuO7gVRlSTsbYBFLh2yId/itM4uYL0R+2SSBBTpSSRthrG
# uEmElI5BCHMxzMg/oqHSPwZAIAkM2C4xxi0St7qMuA+m+ZzFYkfoF41QoSJn+Hjq
# hqWYQ0m/SO9/KnJRJJUwMd5TiMnjZ+E/DJiUry5udiWyQpvfj2hQFI0djhahoAXD
# azeEciLF2uEnTur9UfjcwOun/oMY+ULftnOi2jKLMrreV097akzz/JxpnDgYJU/t
# gU7fQflg7IqiL9+0276+joQHo21mVeY5YD8Kh/kUaY6Jm/OTM88G7evTz/qnRumx
# ovTjMStvpbAHNRhmSTdIPTV32CyuxDKS/V5a5iwA+f9ViBo+wjCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB1rbmFkzS7qAK1Oav08AUnhbNI
# UqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7lb/TzAiGA8yMDI2MDkxODAwMDc0M1oYDzIwMjYwOTE5MDAwNzQz
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuVv9PAgEAMAcCAQACAhF7MAcCAQAC
# AhNYMAoCBQDuWFDPAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBABrd1TpY
# bZpjUY9KEJlZSxZ3wNgfMFnKqFVkaSJL+vMSpH08uhmL/nPjLYqLGYqylkUzDKAx
# cVl6xXf6X4OPO63oZABuhkP02xEoFR6SvV60sG1Gvrs1eBWjlGuzHe3FBUBsKG6w
# arb/tOkANeixdnEsbxW29J4ztTz9D47WDGEVMffVFlYxNc9GfqbhpPRuiX1GDgPc
# 39YsIHUKwaHAL8rU0Wma+t7yjpm2+USIQL8Tu8llMETZ8YoritoCMJcpXY9AVWNy
# afnWdM0CStOy78j/gqGMZDWUrSrkrYr8bVH04Sa3CjG/aFEv8o9Tm3bhakFBhSk9
# q0ThfNNu33XAzrYxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDgc9PA
# hG9AJu4y8S19mNUrjsevvX9siO5mOqfTYoDJ9TCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIFWxikZRYGNf4oEVZK1eT45H+3GQ3/qxV75VwuBt+iLXMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIo8KWH1/PIHkAA
# AQAAAigwIgQgfEx9mq3nFGveLs00kpn9JBJyStEknvPs84jm+/YmpRswDQYJKoZI
# hvcNAQELBQAEggIAAoXLzxond9LZhnYhaFg5VAYtk8CoD6w6cy/WtIburrMF/20Y
# C0yR+ELjXzuiajBF9W3ykrLH2q0OpX9hWz9YZSMY7LjfSwzUp38pJyPUWbWzHL2l
# WXfGLoZLsfkm6gDqC1IbhKV7ZjgRFVMqloOfn26oEgFPcOsKkCT1ceVrCtA5Gv4A
# lB7E+ysGn1pFOUwqc+sysN8i5wkyxrOY0v/5VN6ayqHQtH7a05tQsHOTmkBRoVKs
# J1uztUtLc8kC9I9VU8Lqj3X/YBVXfHWomq9uLfkBoH9aoSSC0T+XcGXFpCHcZpzT
# UjJyPIJzcbE4D/PGTqYqHMPG/NBh0bArHXzl4o0s0OYj1mEugkG++fN/Ax0D2EKp
# 3+cP8v8xu87vxjbHgguNgyoXGW3ua0A/aJzxuapybs2c1shQFnGwanJ6QuXUBVaj
# kXk86UMaJYbZyaUMU/inykDEkRBuzxbgpb2RRGfiRfSAGPGXf1Sq78sxdwSqIH0e
# 2wFNsV9A/7LV93mZ6w16oGyLRADZAWfVyQYsxV1PAnIxIm0grKQYWGIGi83djSrB
# vD4On9IAty99f2iKy8clX0jGKwCn9QEcdFXkeknL86OlkDrEQTMjuWrBhHT1Wjt4
# AItZCJJ2lE04A1JCXJxcEpHg0Kphgy6N763+7KjaTARft6uo5oZBGFiAALw=
# SIG # End signature block
