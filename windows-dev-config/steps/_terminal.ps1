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
# MIInQgYJKoZIhvcNAQcCoIInMzCCJy8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghneMIIZ2gIBATBuMFcxCzAJBgNVBAYTAlVT
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
# G+0i1KGCF64wgheqBgorBgEEAYI3AwMBMYIXmjCCF5YGCSqGSIb3DQEHAqCCF4cw
# gheDAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFYBgsqhkiG9w0BCRABBKCCAUcEggFD
# MIIBPwIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAO3mkKDzZvFiSn
# nEYXdz5AkXIRzXMFlrmY2xx5Z8fSHAIGaq1thB5iGBEyMDI2MTAwMjAwMTQxMC45
# WjAEgAIB9KCB2aSB1jCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1p
# dGVkMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzYwNS0wNUUwLUQ5NDcxJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghH+MIIHKDCCBRCg
# AwIBAgITMwAAAhOwQzVmz6+V6AABAAACEzANBgkqhkiG9w0BAQsFADB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNTA4MTQxODQ4MTdaFw0yNjExMTMx
# ODQ4MTdaMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0w
# KwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAPSZeuC6GcQyDUhYM/vSkuTs7+ZuePHj1c3PUV1nuE+PzKZX
# 4GuHqtdkRnaeXFb543Xub8X6tmsf457u71FuK2TeJjlJub4fpHGLEJWEOdxcICAd
# 5xI3EB6Jqxt5mXv6M4xUgK+iW4JSrSHgMkj8wHBc8gHq+ZSzVBwRL0DDPATozMmq
# Qr4dMbIOMShXFRCUCyhHwhgX3zGSP2prrRxW9wlE2e2laRtihxBVDZWdb8DCr8V0
# z0Q528Dxs8sqiSc537CzR0OL17drbUtT3gqBiNITdT3qvMhrCFzPaKHMAtOgxjUj
# P+CwMdrir8JlJ+jcC3NPrZr58usNvK2S3o7JEX51VqHxL9ZlmNIx1Jx68EhgUvIF
# T/YHAbOj+YNDqSTzH8XVJB10ZHDDz1tISD/DW1vFuUrqfB7sJ0im46cgJRgVHTP1
# ea2W9LGZpJ+9eK+lCxivnCywDekdxYV+jdJ4+uBduy0ytgW0tKSWWl46NHgzc9UH
# MXiBS1IBfkQbC2A5/BPHApHsSvDZbdxovcyX+ecOlH02fpMEzMTKhcYe/k38e/mg
# Tm2fp8fetQLYqgMu81VevaPy1kXSj2Xb2Z/REshm05z345AREb9tqa0pRE5UcMz+
# m5hFTili1lcMbsIe21FlLlG9XI/d877bUGBkGreRPQCyyTZpbyygrJAe62i7AgMB
# AAGjggFJMIIBRTAdBgNVHQ4EFgQUE54QSsfha8qYUFjEYqR+PbDBQDowHwYDVR0j
# BBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggr
# BgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0T
# AQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4Aw
# DQYJKoZIhvcNAQELBQADggIBAIJsWiaxqkNg+lCYWekJdkmRTmjbhm1ty8wfhEvp
# dgQdTCbQUUhXYv4VWN9zacbCUIUOUy1adA12DpCKD0HNe6x/iFYXpjvIwrflOiNU
# yMOnEe3PrRKPyY6ehKhFNXOP5q2jI4B4UPq2gvzlAJvfANa+GyDx7bAZi0ThpnhO
# VyyBWgSGVh74dgjlyEyjm11XecBrSdXWWXcGhwAlxedOo7WvrqFHcswHrjZUzy06
# 2fJ8ocRsJPVYenog0OwkDFkkmvAyUvT1F43qIvb03Uu2TF6rvrb+kM98baARefmB
# SuLhPpohrPdBcZtFStpVq5hYY5EZec8qBzncBu7KTWJA6JgjzViLnVEJkGCqbfx7
# LKX3G/saZ1iA0HTM4BPKY9b6cC4FhJx+y7U+HWQnqA6PTyuNEcQQ/JCie+vZ4JBM
# H8Ag9hF/zEJO/XiLzoaZx9dhrlQcr2imZOV2b6rTzjTcK/Kv6gN/O+yLlsFoJ2nl
# /qa6cNHWf0C7Wxhla4D/k0UI7ftnXGQOT91+C8ADYYj7MtDpeFwnY+zsQSxbzs7A
# jwz2lZ5KfnXwxRvjTgYq+2qkyevOttqcpoNVfuoHP9Ub8Qv8IL2MhtN93nCar9Dp
# 9GUTWK/ovzpMIANxz9Wiw9Gh6xKcOpbdNut4kZAr63HXDlvMN4wvEybmhlsgtkvY
# xI84MIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0B
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
# cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA1kwggJB
# AgEBMIIBAaGB2aSB1jCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1p
# dGVkMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzYwNS0wNUUwLUQ5NDcxJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMC
# GgMVAJgRPEgo8YI2nJsvP1RHZOzcaUemoIGDMIGApH4wfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDuaQ4YMCIYDzIwMjYxMDAx
# MTY1MTM2WhgPMjAyNjEwMDIxNjUxMzZaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIF
# AO5pDhgCAQAwCgIBAAICGrgCAf8wBwIBAAICE3UwCgIFAO5qX5gCAQAwNgYKKwYB
# BAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGG
# oDANBgkqhkiG9w0BAQsFAAOCAQEAIiMsWNTZ9rRCVHO6C/jl2o6V0z7TGTxvTThO
# +dIBflYOjbVdGzYQH90zyLzzrgAnJqew8xyH4E830V/DP5vP4yFGA3mmSDisV4rl
# aMWFQvXt0HBU0pGk1sgBowIRZGAhmP4WbDO1Icji6VnWFzyoTAvc1jOAPTkywX9e
# ovXAKzImYlIzqMGikfnJDmPkOTMvobZb5kyTsvaa1aj2jFJ0A1o2DLcUunJvE9oc
# lVLKSYpgGdeU7nW0FasjUIyLVhWXmPj/Tdv4zhRyr8BHvc+rvUbDKTd3mUlflfL/
# 4QuplFHdaKzsykA9n3r9gbrFdDA2ykovbhxKrDoX8G+HM6z84zGCBA0wggQJAgEB
# MIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACE7BDNWbPr5Xo
# AAEAAAITMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwLwYJKoZIhvcNAQkEMSIEIJOZg/VRGy8knuzXEzIbWatzMhvJJwTCJKYw
# xpgoPHoXMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgzOEJbRSFM/CeA4wM
# z+J1aHWb0MWBpXlCH6fOjmucWGgwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAhOwQzVmz6+V6AABAAACEzAiBCDoYJBP2o1eXEUkAHtT
# sM6Bcn7LqYFx53+d2re7rcS7LzANBgkqhkiG9w0BAQsFAASCAgCYb+unKuV76ZTB
# c9qH96S+aDpOZUlNHvSAlS31NdYVhEYPmE5kGb0pBJudBUiDaa+PpTKXV5rCSC7H
# +egD+YH6Tqx46G5B7uFkvJuWrzIoTO1KdcVmhb1b73z157HyacQ5TR27A8WLqS9W
# KX6U46Y24rTFEc8/Z3VGsCYroy+Dj9IERQqn9Opac3tRqQI02gPXWZBKgZKlp4ig
# 6catFAGWN7PYYcJYMfi161aWOwKQxxJ2p4LthdvPzeXUTpq2pqXTEmbB5DEfqEBX
# RJlp++Rqft3Sx+MUHgbnyQyuVgGlqAMk47yMfljrr9Ti2UrjPMh6YY3FblQmoOh/
# GV+wxVz/ecfGIPbGB9juzmnF55ONMLklC21GDMtW18M2n5C6GWeOl5h6o+7xPVjk
# P7L8p3oU+Fvul1f2biSmDAFCqxc4zsuXAXc9BXm7bHTScI9vNaQgmAF2B3ZDf4z7
# UTALXGYMkTZsi85djA+VtKuyarPrndqrEK5W7h133toDyGImyhNp4zbmH7ph5Ow1
# M2tmiHDg5wqF5yfSuYPPd4ML3SBR910gPeYcQWbQ4pMNinoOkcMrxaJc9X4REFKe
# 5Jms31wbF6OxvKraalmSQ2jyiCmRXm1gCJHAkbAfytHeb2wwA7FTYbzI7IrkyQ++
# c2dZrqis+UKvpeb5CqCNDALIO4R+rA==
# SIG # End signature block
