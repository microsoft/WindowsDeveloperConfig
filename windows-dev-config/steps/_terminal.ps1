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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCSU9BPcRSpJYY2
# vzMFv5qVaQeP/V6NJ8yhWRUgTYByTKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIMsSneEUUWePLo4jwmz2a7qMSfux
# vjTmuOf4WBbeFo0aMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAKASSyj/lss1D0ay/1G13M/PIaVj7yYHSXdejPH1p81xAPwN58F8w6fXzQp1j
# 9OKE6DhIzLKcPgeS8M59eLI5yFIJEEL0c3DNuS6cgGNWcROFOLANHl2J2rCWq9vs
# rFPZzGETxKr6qQYGY9FntfAC/XdLDEQ16g5hpc6iK6AWsLhQle+CsuRuBDRK66TA
# /+z0AdFh5cHxDZ3X7iSxelNdIV/MI3AFfGugH+S9xq+ZkSNqJglJpXLl9NkQYyjM
# l6UHdlS2HyFkwGeTAKD0Ui71STjHi+/JAH5waHEnuvgUHH5ULC5Eymprk66p4ZUj
# Lb9P8Ztj3qdeMF7X01t8kO2VOqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCA7nWrUiKfWyu6nJChp4Axv33q1iOb8ktQfZEoddpsoywIGaqotZKZCGBMy
# MDI2MTAwMTA0NTEyMi43NjNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
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
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mfHTDAiGA8yMDI2MDkzMDE3MzcxNloY
# DzIwMjYxMDAxMTczNzE2WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuZ8dMAgEA
# MAcCAQACAirGMAcCAQACAhItMAoCBQDuaRjMAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBABRn2lCkgWrNi0I0fMLHxwHX5n2Jon7JsijfNV2n4Ts/zbeVkprV
# qGN+teRUpHPeyeWM11HE9V16MprJtTSrfur3pyFBs8EIi8zs1eY0FeXfnj+7sKQD
# BcfukqvXqDOAlkyAl1G10Pd3XabJ00r3DoyWvqcorbA8v+2G1n6Im1PP+aUcyJVG
# XGINS6qb44WNMsPiCCMYuZMwTcoS2XL46gXh4jpGPC8dfOJ46zvIQQwDu6yqDtKs
# f31nVfW5tiDP76fkWcN4TN1ChEDhR7tIDWKiQgVHX+hLEtW6kqjY8JJNUjLM5erp
# bgw63/h9W+GQK3xIhhgFvv+pSSbVih7YdaMxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiJB0vaq/8i1/wABAAACIjANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCA63s8BuLkJqNSJw71vyZV4yIChPP4zLRboGm/bMQEzJjCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIAVgXQEKBOfGgjNskmDOmbcEIOnHGNwA
# +QcRufDR5AkTMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIiQdL2qv/Itf8AAQAAAiIwIgQgDu+eLs6+Zr4VcTpXOBWTnVrq7ItOJh+S
# 3DMHUT4gfb8wDQYJKoZIhvcNAQELBQAEggIAkGaV8cSJiFk1ykVfEMhxLAHgcMEQ
# 2qT2fAvRiS7Q2Q9cYQZ52RHX7fJX3HLKgFKGtTv9wpK6BZ6rxF5ffNrHonKGswHC
# hVH1YmBTHL7s9eqP3RZbK0v4LjIo3E84y0msVOe2YOewbjZFPXbIdIj0kDFbzzEc
# HopzUZ53X32l5lQIvtMRJkRy2DT7Cm5yPVJPRJZ83QbteMekJoHW8Waa0jQ62Knr
# 7+873VhtEYriPebqHTz1ixgE9YcDnpixV5iapvXnS9ACI6/GwlU+ltsMd6S51PuR
# f9opkmOnR5D3rKYX0Ew0Y/pHIh1kfj7n1oIq8ZVjHXs3pCh/Zde6k0G+uk/zaDEl
# 1TqkAwsV5/F5AbGtxg1VSvmEAGNOVGIl5ArqCU9h26rXvhegXxTJ4yDUpnCd+fHK
# Qjhp7aLMtHbDKFAgWtEr2nGyrIpCP3eyeYtYQxDs0eVNJ8L8kMkoi2vmL9W/G+Tk
# 5YiDFWCdJozru/47i5xbpc1FYGAvTdNk0OW6uC3AEvNHjZq6f165C0glfnIKqKmt
# evjNwVzMDcBRTxxbEBnvD3l5xL021OZ7oHyxy1wxyiki3JOCAHMKzyms0jC101aq
# Ne5swblPXP4VfX6JJl3lFPd4gNnfyr6b/aafNORi63RFbz4M59LTrjRbrgpgsgPA
# 9FPooiMOzFh2dW0=
# SIG # End signature block
