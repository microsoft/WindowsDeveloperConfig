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
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBuMFcxCzAJBgNVBAYTAlVT
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
# G+0i1KGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAO3mkKDzZvFiSn
# nEYXdz5AkXIRzXMFlrmY2xx5Z8fSHAIGaqlr/27LGBMyMDI2MDkyNTIyNDc1NC4x
# OTFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAiNP2WAkU8/+KwABAAACIzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTdaFw0yNzA1MTcxOTM5NTda
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCK
# 6Q2nk5WUdKzSCSafp+UjUARsWxHKS63rJhFC/zSabFumTBuaJ0QNrmqevub5Db7f
# Sj5qtwwKnjIO92+HXF67192fujL7DFot5WEj/AtEZ/XrzFHimKlN1h6gEQwP5I67
# wizaPW5ZzSBNpaLBg5oHvASPOZtwdNUoZ+DQKF3hJl1KZuoIlVK+qi7cLjgak6s5
# oOZcRCMrKnuC3aoVa6wRDbYvKUuj7rkFx9KO0PsHJ/k+LnZMggRheh4AVdawyh+o
# OzKPjlQGUNfSeWUgym2U9CLa8tt0mQX4DxDz6+ram50gj1oAfyQ6TQ7r96PADFOK
# BgaU7+cpHnaZG89dTegQ6ydBRGIycOw1dRX2eKDRRzziK3cn0WaIm/7OeGsyQKjI
# zEQuUTDv0Jj/9zQ7truLOOpJD98BJVOK7je84Sz2hb3HvUST7j1j2N8peD6olkpF
# HR/1Z8Jz4F+mkrUF7MmPAirYHRzunbIg3HrDMNwFYN7yBkDA4/VMo9CY0y9oGUoq
# 2yjbCwTibz9VYl93nB3QQiTCT9nW3M+TOWB+PMrZpExq1BSHmKPzIqehKqrUDoM3
# 3PK+dEKwpYLET6uXq4HuQRMXWT//sPubUnQAaaUMfQhAZSy23HtxwtN3eK9+T4wC
# av2wQFt57eUOwUW5/DCzMF9tua5He1hNvgcAXaiG1wIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFNbAh89v29nPY9bwQb1QYCzxVgeXMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCHQwe7z5tp4NZwAf1cB+4c9J4svw3P6WqGBMxtqznS6DdzUzStXHCaPZhM
# 41g1iKHNnmcnLjwLujOEaNjhSnUDiAZqQjW5ZapOBxgc7Egghh9k+r78qWAe3rJ4
# QohBbhSGdZtKivTRaeRqmnhy8+ThrKhzCeEwaarXJimZwSpdQQUDbheWHeyAxASq
# ultd5KO0m/UFvO03tfepqGXA4tCg/WGECwKqOjJzpRAfPIB6y1HyVrk+vmL5rpEb
# TwwLOtX7WxFGG8+cYLk9HjaDkxraA/HYlKQRx1sdza+w/gulLwgOnByRJKF2rr8M
# 7FNIlwoi6ywFpaNc8A7HewaGjgw/tfcE260I1XekGluANI9HnONOYWlI7BKBQbWE
# 2teo6vsQ1Vg8B8rTZSePVdmXL1PPqqs3KVdFKM5kYocPCDM+6VL32IV96sESf2T7
# DjxanpCg2D2UYj4Z1i7cy8U1LLDGg55KWs4af2RRBjH2MulHgAmW5obKxiZCDQjR
# aroJ2XElXUhigE9BzvhCFbT/HDY2vpVpl5HnSpcCSxmL5i5lIT/xbAQMI7Luh75X
# rm+IslfFWOGOGMlCp+24qEJEglXEP7xwsolNdBNndXihhyIefVGlI1DR7xGELiJr
# k8ifVWYo9XEbEXv/lbvp6F2R2UsnweWckvq0y1HWnLHDqH6dPjCCB3EwggVZoAMC
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjkyMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQA4RWFs+kTiZnoZiAj1BtYj8zCN
# aqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7mEX3TAiGA8yMDI2MDkyNTE1NTUwOVoYDzIwMjYwOTI2MTU1NTA5
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuYRfdAgEAMAoCAQACAg13AgH/MAcC
# AQACAhLHMAoCBQDuYmldAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBACIq
# QzsxGMowLjDKdhE4UoVzehs02GTLMSqCPKGQpXRsP80CfIuFlJ5JU/llUNrlmaV9
# w2O93qxPha3R+mMPOPnWPmFMbDQgP4iEmDw7luHI56Rf03NARckSVWdrZf/JOXDC
# I4OiS4qkgTIrGHbIFHYcxXCU50RHEUhHv6fFvBCI7IsG91aAwqwA8wXBnbrXLJ1y
# 43FrIVqV5h6tAgPr/KsjrAlKGdB0Gbg/R7gSNN/SWtBTSfV1tgTq8fh7SKR8beoJ
# 4EqEFDFv+UGc4ahm5JzvDdGCgAgaEweOCMfe8h4SAYKrPOXhzFi3R8lud/IXxgyT
# yRAhxgY/CKBscdtHBl0xggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiNP2WAkU8/+KwABAAACIzANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAM
# /CHldLg7SKukaIpaKP28ySa6z2Da93A+LtuOaSrb4TCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIJbwMywRbvcGiynjnwjAqcaD47yYvebKZRAvtEAR5u6zMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIjT9lgJFPP
# /isAAQAAAiMwIgQg1sebf8GMjrP5iRYdvaF4YACGCg2TmfIfKIbCpBItIF8wDQYJ
# KoZIhvcNAQELBQAEggIAH81ThUsog3ajMJqJFc7YFL1//spxG28a2kVSDpw+IKzS
# muqeffgxA6vMkc6xcS6VGUcq129+11TsbtkIlJUcMAfEGYPsOMYQl4mOsuAYMSgZ
# mlPdAWMKUbXS6o83ma1zmBHojZWu+xOSDSFT1Gg3U/kHhIjozlBIj9KW9mvy8Ft1
# aH1IyjMgDNWPbfrZHBmnzZGL26Btjj6peTc09X+uVmjJNuS51blA6Rro/o+9DwOq
# g024lImJEfw2PS1clVPCYryX6eT6nXBpn+7u4H4vRoF0Yqvq2r82+AfQ8+xCRggn
# Dtm8FrXLSNHiwrD6LcUtpwIJ7cr4u98Lbk8mtNTZDaP3cY3z/5bA6NbmINi8QwCW
# 9b/+brOPEhKcWkTyQ24Da2H1M8SecJHxw+4RiRIi5TA5AZ+Mq5lL4KVt49/eb/UC
# AwMjLaAjtM0TbawVNA1vHG5JFlrD7t3lx+iCebz2H9W7d9aYPAsWkdwQno/QBa3u
# T1rHqyGb+CLxsLNdJV+KZOVH6Ea/QwUNmnbOGp31oiN2j20qvQy8cc4d4OqIyoAu
# s+RS5ISfDrOyDDq0AHLNaZuU6Z470PB2N7a0T7gM9vKuQ3stdTknqGyU5XYhKAke
# 8PWU+/Z+NM+29AV4DcTJ1L/bsUwPm0WLASUXJQI4DA8jrMgx5ZzQ1mWoAdxZ5p0=
# SIG # End signature block
