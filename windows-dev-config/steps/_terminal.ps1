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
$Script:CopilotFragmentGuid = '{b1a4d2c8-6f3e-4a7b-9e2d-1c8f5a3b7d91}'

# Paths backed up in this operation; null means resume could not recover the backup state.
$Script:DevConfigTerminalBackedUp = @()
$Script:DevConfigTerminalFontRunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$Script:DevConfigTerminalFontRunOnceName = 'CalmOS-ApplyTerminalFont'

function Get-DevConfigPendingTerminalFontPath {
    Join-Path $env:LOCALAPPDATA 'CalmOS\terminal-font.json'
}

function Get-DevConfigTerminalFontRunOnceCommand {
    if (Test-Path -LiteralPath $Script:DevConfigTerminalFontRunOnceKey) {
        $values = Get-ItemProperty -LiteralPath $Script:DevConfigTerminalFontRunOnceKey
        $property = $values.PSObject.Properties[$Script:DevConfigTerminalFontRunOnceName]
        if ($property) { return $property.Value }
    }
    return $null
}

function Get-DevConfigPendingTerminalFont {
    $path = Get-DevConfigPendingTerminalFontPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $pending = (Read-DevConfigTextFile -Path $path) | ConvertFrom-Json
    if ($pending -isnot [pscustomobject]) {
        throw 'The pending Terminal font update is invalid. Run setup again to reschedule it.'
    }
    foreach ($name in 'Path', 'FontFace', 'PreviousFace', 'BackupRequired', 'Command') {
        if (-not $pending.PSObject.Properties[$name]) {
            throw 'The pending Terminal font update is incomplete. Run setup again to reschedule it.'
        }
    }
    if ($pending.Path -isnot [string] -or $pending.FontFace -isnot [string] -or
        $pending.Command -isnot [string] -or $pending.BackupRequired -isnot [bool] -or
        ($null -ne $pending.PreviousFace -and $pending.PreviousFace -isnot [string])) {
        throw 'The pending Terminal font update has invalid values. Run setup again to reschedule it.'
    }
    return $pending
}

function Invoke-DevConfigTerminalFontLock {
    param([Parameter(Mandatory)] [scriptblock] $ScriptBlock)

    $lockPath = [IO.Path]::ChangeExtension((Get-DevConfigPendingTerminalFontPath), '.lock')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath)) | Out-Null
    $lock = Invoke-DevConfigRetry -Name 'Terminal font update lock' -InitialDelaySeconds 1 -ScriptBlock {
        [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    try {
        & $ScriptBlock
    } finally {
        $lock.Dispose()
    }
}

function Clear-DevConfigPendingTerminalFont {
    param([switch] $LockHeld)

    if (-not $LockHeld) {
        if ((Test-Path -LiteralPath (Get-DevConfigPendingTerminalFontPath)) -or (Get-DevConfigTerminalFontRunOnceCommand)) {
            Invoke-DevConfigTerminalFontLock { Clear-DevConfigPendingTerminalFont -LockHeld }
        }
        return
    }
    if (Get-DevConfigTerminalFontRunOnceCommand) {
        Remove-ItemProperty -LiteralPath $Script:DevConfigTerminalFontRunOnceKey -Name $Script:DevConfigTerminalFontRunOnceName
    }
    $path = Get-DevConfigPendingTerminalFontPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-DevConfigCopilotFragmentDir {
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\DevConfig'
}

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
        if ($PSVersionTable.PSEdition -ne 'Core') {
            # Windows PowerShell needs JSONC comments and trailing commas removed without changing strings.
            $raw = [regex]::Replace($raw, '("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/', {
                param($match)
                if ($match.Groups[1].Success) { $match.Value } else { ' ' }
            })
            # A trailing comma must follow a value, not an opening delimiter or another comma.
            $raw = [regex]::Replace($raw, '("(?:\\.|[^"\\])*")|(?<=[}\]"0-9el])\s*,\s*(?=[}\]])', '$1')
        }
        $settings = $raw | ConvertFrom-Json
        if ($null -eq $settings) {
            return [pscustomobject]@{}
        }
        return $settings
    } catch {
        throw "Windows Terminal's settings file couldn't be read as JSON, so it was left untouched. Fix or rename $Path and run this again."
    }
}

function Save-DevConfigTerminalBackup {
    param([Parameter(Mandatory)] [string] $Path)

    if ($null -eq $Script:DevConfigTerminalBackedUp) {
        throw 'The Terminal backup state could not be restored; settings were left unchanged to preserve the original backup.'
    }
    if ((Test-Path -LiteralPath $Path) -and ($Script:DevConfigTerminalBackedUp -notcontains $Path)) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        $Script:DevConfigTerminalBackedUp += $Path
    }
}

# Backup preserves the original JSONC because JSON conversion drops comments.
function Save-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Settings
    )
    Save-DevConfigTerminalBackup -Path $Path
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

function Reset-DevConfigTerminal {
    param(
        [Parameter(Mandatory)] [string] $DistributionName,
        [switch] $CheckOnly
    )
    if ($CheckOnly) {
        if ((Test-Path -LiteralPath (Get-DevConfigPendingTerminalFontPath)) -or (Get-DevConfigTerminalFontRunOnceCommand)) {
            return $false
        }
    } else {
        Clear-DevConfigPendingTerminalFont
    }
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        return $true
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $changed = $false
    if ($settings.PSObject.Properties['defaultProfile']) {
        $settings.PSObject.Properties.Remove('defaultProfile')
        $changed = $true
    }

    $profiles = Get-DevConfigJsonValue -Object $settings -Path 'profiles'
    if ($null -ne $profiles -and $profiles.PSObject.Properties['defaults']) {
        $profiles.PSObject.Properties.Remove('defaults')
        $changed = $true
    }

    $list = Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'list'
    if ($null -ne $list) {
        $profileGuids = @(
            '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            '{463c642a-294e-5f7d-87c0-3061fde7adfd}'
            $Script:CopilotFragmentGuid
            '{2c4de342-38b7-51cf-b940-2309a097f518}'
            '{08c3a759-e9c2-5cd9-a652-37191c8995ca}'
        )
        $remaining = @($list | Where-Object {
            $guid = Get-DevConfigJsonValue -Object $_ -Path 'guid'
            $name = Get-DevConfigJsonValue -Object $_ -Path 'name'
            $source = Get-DevConfigJsonValue -Object $_ -Path 'source'
            $guid -notin $profileGuids -and $name -ne $DistributionName -and
                $source -ne 'Windows.Terminal.PowershellCore'
        })
        if ($remaining.Count -ne @($list).Count) {
            $profiles.PSObject.Properties['list'].Value = $remaining
            $changed = $true
        }
    }

    if ($CheckOnly) {
        return -not $changed
    }
    if ($changed) {
        Save-DevConfigTerminalSettings -Path $path -Settings $settings
    }
}

# SIG # Begin signature block
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCSU9BPcRSpJYY2
# vzMFv5qVaQeP/V6NJ8yhWRUgTYByTKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIMsSneEUUWePLo4jwmz2a7qMSfuxvjTmuOf4WBbeFo0aMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAGT7Uz/5iDCDSVpG2
# 21UdPw2U9KKsXU5z8cPdkySBP2mpqZnlTNFcBOqdoKxJL43WkztF1+wDm3ByXP6b
# WOKUYEb7oS6Da4JsPN25b8sk0CPjTSgAaKeVCTSQDlfYAtStOohLn4w6lLUf+hh/
# j1AOZoaKD1RbxajIqT4BNcVa99qwdsRq/U20Vo1pY0h4BiwkcSqQPUhSdkxE2sjN
# YHldiw1vNwzXc3QZzc641mV2BOihN51EYF0Z5YTEadX9TuQAZzVZEsxDOl3gwU+l
# rtbqoImm4eWI4YrUoJMAf6TSY20ZGbpqKSPyxkI/hyyl76fUylTOEFqUju/VfyaU
# G+0i1KGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAO3mkKDzZvFiSn
# nEYXdz5AkXIRzXMFlrmY2xx5Z8fSHAIGaq5gaBgqGBMyMDI2MDkyNTIwMzkyNC4w
# NDRaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0QzFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACGCXZkgXi5+XkAAEAAAIYMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyNVoXDTI2MTEx
# MzE4NDgyNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjRDMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAsdzo6uuQJqAfxLnvEBfIvj6knK+p6bnMXEFZ/QjPOFyw
# lcjDfzI8Dg1nzDlxm7/pqbvjWhyvazKmFyO6qbPwClfRnI57h5OCixgpOOCGJJQI
# ZSTiMgui3B8DPiFtJPcfzRt3FsnxjLXwBIjGgnjGfmQl7zejA1WoYL/qBmQhw/FD
# FTWebxfo4m0RCCOxf2qwj31aOjc2aYUePtLMXHsXKPFH0tp5SKIF/9tJxRSg0NYE
# vQqVilje8aQkPd3qzAux2Mc5HMSK4NMTtVVCYAWDUZ4p+6iDI9t5BNCBIsf5ooFN
# UWtxCqnpFYiLYkHfFfxhVUBZ8LGGxYsA36snD65s2Hf4t86k0e8WelH/usfhYqOM
# 3z2yaI8rg08631IkwqUzyQoEPqMsHgBem1xpmOGSIUnVvTsAv+lmECL2RqrcOZlZ
# ax8K0aiij8h6UkWBN2IA/ikackTSGVRBQmWWZuLFWV/T4xuNzscC0X7xo4fetgps
# qaEA0jY/QevkTvLv4OlNN9eOL8LNh7Vm0R65P7oabOQDqtUFAwCgjgPJ0iV/jQCa
# MAcO3SYpG5wSAYiJkk4XLjNSlNxU2Idjs1sORhl7s7LC6hOb7bVAHVwON74GxfFN
# iEIA6BfudANjpQJ0nUc/ppEXpT4pgDBHsYtV8OyKSjKsIxOdFR7fIJIjDc8DvUkC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBQkLqHEXDobY7dHuoQCBa4sX7aL0TAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAnkjRhjwPgdoIpvt4YioT/j0LWuBxF3ARBKXD
# ENggraKvC0oRPwbjAmsXnPEmtuo5MD8uJ9Xw9eYrxqqkK4DF9snZMrHMfooxCa++
# 1irLz8YoozC4tci+a4N37Sbke1pt1xs9qZtvkPgZGWn5BcwVfmAwSZLHi2CuZ06Y
# 0/X+t6fNBnrbMVovNaDX4WPdyI9GEzxfIggDsck2Ipo4VXL/Arcz7p2F7bEZGRuy
# xjgMC+woCkDJaH/yk/wcZpAsixe4POdN0DW6Zb35O3Dg3+a6prANMc3WIdvfKDl7
# 5P0aqcQbQAR7b0f4gH4NMkUct0Wm4GN5KhsE1YK7V/wAqDKmK4jx3zLz3a8Hsxa9
# HB3GyitlmC5sDhOl4QTGN5kRi6oCoV4hK+kIFgnkWjHhSRNomz36QnbCSG/BHLEm
# 2GRU9u3/I4zUd9E1AC97IJEGfwb+0NWb3QEcrkypdGdWwl0LEObhrQR9B1V7+edc
# yNmsX0p2BX0rFpd1PkXJSbxf8IcEiw/bkNgagZE+VlDtxXeruLdo5k3lGOv7rPYu
# OEaoZYxDvZtpHP9P36wmW4INjR6NInn2UM+krP/xeLnRbDBkm9RslnoDhVraliKD
# H62BxhcgL9tiRgOHlcI0wqvVWLdv8yW8rxkawOlhCRqT3EKECW8ktUAPwNbBULkT
# +oWcvBcwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0QzFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAnWtGrXWiuNE8QrKfm4CtGr57z+mggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5gxzowIhgPMjAyNjA5
# MjUxMDExMDZaGA8yMDI2MDkyNjEwMTEwNlowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7mDHOgIBADAHAgEAAgISpDAHAgEAAgIUEDAKAgUA7mIYugIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQDAHQ5/4TI5XWXftHme9vsNqejLW7HW8r3KzOYn
# O2s+RNdNWm3tkOs+3lbvg0wxS+rNkWoxX0fwrLzZGp5L1rR/S1jXYNZ+/g87Wsy1
# yqbjE17IOvXnAxHpVOvdndNvkJybDHFT4O9r2piP3c3be6TWa5sko97VNGO9dvlT
# Vk0wpzq3DA/HFqfHO9R0FLWsqRUO+da+880ch5AW02H0OkfMkJXfFdfmIHEmulA/
# fPO4fZo+kF792LF+6NHT15SK0KY2vtX7RQX+9DbJn0s+935hLdAeb0SXvLP3hEkZ
# +nT4m0pemX8/Vp/+CMZd9ubIvNnemC4GuqEp1yIj8lcC21bDMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIYJdmSBeLn5eQA
# AQAAAhgwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgSjg1a9doxGPEYCXgRocy6qYgTSkt4J7Z2hNH
# 83oKqbQwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCZE9yJuOTItIwWaES6
# lzGKK1XcSoz1ynRzaOVzx9eFajCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACGCXZkgXi5+XkAAEAAAIYMCIEIJ+hx3YTJRfcLsEsNTjn
# nO7Bis8x1FIr2GZRZOYar2kIMA0GCSqGSIb3DQEBCwUABIICAJXat2tnWU18wNcM
# HvU+HdCQ+wUC2rNiXzT0PoHYHbaOkV8Y4q5o1fPD3pakaWyPuqaTvPGPARqNbl3U
# btAk080oHMwEPVis2pTtVjg6SNYydt9LbDewwPGEWECDuieboP9ZyYTIe+ZVGDay
# ULU2DQUOcnNN0w4H0FaJ1SzxQUICavYwxDnU5kHKA1JqRwtE/8hUCYL+K7B98Gfr
# oF3umdOpfm5Z89o9rzEDbtwM8xN5/NjyWSgGNwqtGUBiH+hbI+JLywDVIyVm6DzT
# Duynm3jQ56s/WV91X/sujuHXxEKRvuzw9j+eYUX86Q19w9G8hN8N7s37ckwhR4iO
# HBPFzLarng1rfnu+/G0Iutj5lWPJm3eGbJmOA6/V+GK74+akISwtP0BwtPETNY4s
# GwRJAxvAWK9MleopMfJgkkH+cMcEbNfM2fEl78Y6JjVFFK5A8cEM3ReOppWvAOMB
# OBQkxjcbAyUvHIYupqMMkL+BQrUAFS8erIoAsx49dMjRI53+OBjZlxUcx29sosCB
# cq4hSAmyEYzs0lXIEnHNULLB+G8Zsx1DvM+Lt/lwd4vBcGIKP6U7cgf9wg6TtdeB
# oAgluVaXWMBeX/Plg6TpdrdoFMi3sV/+TS8NzUjKovvTLHV8EvNyc8TnSu+n0QGO
# q5rjSe3gNzXCL9GcVaX2nKsgJpEw
# SIG # End signature block
