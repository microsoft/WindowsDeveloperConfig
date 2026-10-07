<#
.SYNOPSIS
  GitHub Copilot Windows Terminal profile, WinUI templates, and the win-dev-skills Copilot plugin.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigWinUITemplatePackage = 'Microsoft.WindowsAppSDK.WinUI.CSharp.Templates'
$Script:DevConfigWinSkillsMarketplace = 'win-dev-skills'
$Script:DevConfigWinUIPlugin = "winui@$Script:DevConfigWinSkillsMarketplace"

function Test-DevConfigCopilotTerminalProfile {
    $fragmentsDir = Get-DevConfigCopilotFragmentDir
    $fragmentPath = Join-Path $fragmentsDir 'github-copilot.fragment.json'
    if (-not (Test-Path -LiteralPath $fragmentPath)) {
        return $false
    }
    $fragment = (Read-DevConfigTextFile -Path $fragmentPath) | ConvertFrom-Json
    $profiles = @($fragment.profiles | Where-Object { $_.guid -eq $Script:CopilotFragmentGuid })
    if ($profiles.Count -ne 1) {
        return $false
    }
    $icon = $profiles[0].PSObject.Properties['icon']
    return (-not $icon) -or ($icon.Value -eq (Join-Path $fragmentsDir 'copilot.png'))
}

function Set-DevConfigCopilotTerminalProfile {
    $fragmentsDir = Get-DevConfigCopilotFragmentDir
    New-Item -ItemType Directory -Path $fragmentsDir -Force | Out-Null

    $iconPath = Join-Path $fragmentsDir 'copilot.png'
    $icon = $null
    try {
        Invoke-WebRequest -Uri 'https://github.githubassets.com/favicons/favicon-dark.png' -OutFile $iconPath -UseBasicParsing -TimeoutSec 60
        $icon = $iconPath
    } catch {
        Write-Host "  (Couldn't download the Copilot icon -- the profile will use the default one.)"
    }

    $profileEntry = [ordered]@{
        guid              = $Script:CopilotFragmentGuid
        name              = 'GitHub Copilot'
        commandline       = 'pwsh.exe -NoExit -Command "copilot"'
        startingDirectory = '%USERPROFILE%'
        hidden            = $false
        tabTitle          = 'Copilot'
    }
    if ($icon) {
        $profileEntry['icon'] = $icon
    }
    $fragment = @{ profiles = @($profileEntry) }

    $fragmentFile = Join-Path $fragmentsDir 'github-copilot.fragment.json'
    Write-DevConfigTextFile -Path $fragmentFile -Content ($fragment | ConvertTo-Json -Depth 8)

    # Touch settings.json so Windows Terminal hot reload re-scans Fragments\*.json.
    @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    ) | Where-Object { Test-Path $_ } | ForEach-Object {
        try { (Get-Item -LiteralPath $_).LastWriteTime = Get-Date } catch {}
    }

    Write-Host "GitHub Copilot profile fragment written to $fragmentFile"
    Write-Host "Open Windows Terminal: the 'GitHub Copilot' profile is available in the dropdown."
}

function Test-DevConfigWinUITemplatesInstalled {
    if (-not (Get-Command 'dotnet' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'dotnet' -Arguments @('new', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match '(?i)winui'
}

function Install-DevConfigWinUITemplates {
    if (-not (Get-Command 'dotnet' -ErrorAction SilentlyContinue)) {
        throw 'dotnet is not on PATH yet, so the WinUI templates cannot be installed. Re-run once the .NET SDK is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'dotnet' -Arguments @('new', 'install', $Script:DevConfigWinUITemplatePackage)
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "dotnet new install failed with exit code $($r.ExitCode)"
    }
}

function Test-DevConfigWinSkillsMarketplaceAdded {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match [regex]::Escape($Script:DevConfigWinSkillsMarketplace)
}

function Add-DevConfigWinSkillsMarketplace {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        throw 'The copilot command is not on PATH yet, so its marketplace cannot be configured. Re-run once GitHub Copilot CLI is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'add', "microsoft/$Script:DevConfigWinSkillsMarketplace")
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "copilot plugin marketplace add failed with exit code $($r.ExitCode)"
    }
}

function Test-DevConfigWinUIPluginInstalled {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match '(?i)winui'
}

function Install-DevConfigWinUIPlugin {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        throw 'The copilot command is not on PATH yet, so the WinUI plugin cannot be installed. Re-run once GitHub Copilot CLI is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'install', $Script:DevConfigWinUIPlugin)
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "copilot plugin install winui failed with exit code $($r.ExitCode)"
    }
}

function Get-DevConfigInstalledWinUIPlugin {
    if (-not (Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)) {
        return
    }

    $result = Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'list', '--json')
    # Assignment avoids nesting the JSON array in Windows PowerShell 5.1.
    $plugins = $result.Output | ConvertFrom-Json
    foreach ($plugin in $plugins) {
        $id = "$($plugin.name)@$($plugin.marketplace)"
        if ($id -in @($Script:DevConfigWinUIPlugin, 'winui@awesome-copilot')) {
            $id
        }
    }
}

function Test-DevConfigWinUITemplatePackageInstalled {
    if (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue) {
        $sdks = Invoke-DevConfigCleanupCommand -FilePath 'dotnet' -Arguments @('--list-sdks')
        if (-not [string]::IsNullOrWhiteSpace($sdks.Output)) {
            $result = Invoke-DevConfigCleanupCommand -FilePath 'dotnet' -Arguments @('new', 'uninstall')
            return @($result.Output -split '\r?\n' | Where-Object { $_.Trim() -eq $Script:DevConfigWinUITemplatePackage }).Count -gt 0
        }
    }

    $cliHome = if ($env:DOTNET_CLI_HOME) { $env:DOTNET_CLI_HOME } else { $env:USERPROFILE }
    $packages = Join-Path $cliHome '.templateengine\packages'
    if ((Test-Path -LiteralPath $packages) -and
        @(Get-ChildItem -LiteralPath $packages -Filter "$Script:DevConfigWinUITemplatePackage.*.nupkg" -File).Count -gt 0) {
        throw 'The WinUI template package remains, but no .NET SDK is available. Repair the SDK and retry cleanup.'
    }
    return $false
}

function Test-DevConfigWinSkillsMarketplaceRegistered {
    if (-not (Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)) {
        return $false
    }
    $result = Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'list', '--json')
    $marketplaces = $result.Output | ConvertFrom-Json
    return @($marketplaces | Where-Object { $_.name -eq $Script:DevConfigWinSkillsMarketplace }).Count -gt 0
}

function Invoke-CopilotPhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $fragmentsDir = Get-DevConfigCopilotFragmentDir
        $fragmentPaths = @(
            (Join-Path $fragmentsDir 'github-copilot.fragment.json')
            (Join-Path $fragmentsDir 'copilot.png')
        )
        $steps = @(
            New-DevConfigStep -Name 'CopilotFragmentCleanup' -Description 'Remove the Copilot Terminal fragment and icon' -BestEffort `
                -Check { param($Paths) @($Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 } `
                -Apply {
                    param($Paths)
                    foreach ($path in $Paths) {
                        if (Test-Path -LiteralPath $path) {
                            Remove-Item -LiteralPath $path -Force
                        }
                    }
                } `
                -ArgumentList @(, $fragmentPaths)
            New-DevConfigStep -Name 'WinUIPluginCleanup' -Description 'Uninstall the WinUI Copilot plugin' -BestEffort `
                -Check { @(Get-DevConfigInstalledWinUIPlugin).Count -eq 0 } `
                -Apply {
                    foreach ($plugin in @(Get-DevConfigInstalledWinUIPlugin)) {
                        Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'uninstall', $plugin) | Out-Null
                    }
                }
            New-DevConfigStep -Name 'WinSkillsMarketplaceCleanup' -Description 'Remove the win-dev-skills Copilot marketplace' -BestEffort `
                -Check { -not (Test-DevConfigWinSkillsMarketplaceRegistered) } `
                -Apply {
                    Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'remove', $Script:DevConfigWinSkillsMarketplace) | Out-Null
                }
            New-DevConfigStep -Name 'WinUITemplatesCleanup' -Description 'Uninstall the WinUI dotnet-new template package' -BestEffort `
                -Check { -not (Test-DevConfigWinUITemplatePackageInstalled) } `
                -Apply {
                    Invoke-DevConfigCleanupCommand -FilePath 'dotnet' -Arguments @('new', 'uninstall', $Script:DevConfigWinUITemplatePackage) | Out-Null
                }
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # BestEffort keeps network-dependent integrations from blocking the WSL and reboot phase.
    $steps = @(
        New-DevConfigStep -Name 'GitHubCopilotProfile' -Description 'Add a GitHub Copilot profile to Windows Terminal' `
            -Check { Test-DevConfigCopilotTerminalProfile } `
            -Apply { Set-DevConfigCopilotTerminalProfile } `
            -BestEffort
        New-DevConfigStep -Name 'WinUITemplates' -Description 'Install WinUI dotnet-new templates' `
            -Check { Test-DevConfigWinUITemplatesInstalled } `
            -Apply { Install-DevConfigWinUITemplates } `
            -BestEffort
        New-DevConfigStep -Name 'WinSkillsMarketplace' -Description 'Add win-dev-skills to the Copilot plugin marketplace' `
            -Check { Test-DevConfigWinSkillsMarketplaceAdded } `
            -Apply { Add-DevConfigWinSkillsMarketplace } `
            -BestEffort
        New-DevConfigStep -Name 'WinUIPlugin' -Description 'Install the WinUI Copilot plugin from win-dev-skills' `
            -Check { Test-DevConfigWinUIPluginInstalled } `
            -Apply { Install-DevConfigWinUIPlugin } `
            -BestEffort
    )
    if ($Script:DevConfigAction -eq 'Partial') {
        $steps = @($steps | Where-Object { $_.Name -ne 'WinUITemplates' })
    }

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDJevIvOKJZj0Bp
# uhbmAUGClZO8ZJd0p+mRcKmKClWXzaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIGd467fM/wYFpIeOzE3FXRaO6KY6VkvdttClgACfdYwQMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAXHRqqPsmZ4M20mic
# oOat6BwRangnSev5fJ18OV/5TCvrjJdug2EVSEjBPqagSJgwsTZ5CKta75SO9Cqp
# YCu53sjKASo3s46R52Nwy3BdvCv+yF0JhWIjURcEHTBov8eAZaEYndkpOQ3Kr2Ki
# zJeTS/wH4PKhsyGI0gE/pr4yDhZrgd04iPP76MLXsLa3sV4NThC2VbYVwPWmM5tl
# GSy5zKggGtXgUtzqppJjp7ItAB4Sge6RjHDeYTjbDk9Q7rT8nb6m4dfB+bduFEZ4
# +GAUKvFdtB3KbyfPsvWHc7oxxYYtPH4HcpPd+IL2JANljHastSxDI6pZ+EpPQwtH
# jXgV6KGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCC6vHBATvvhk8Nt
# 5Y5KjkD+413ELRu1LJ03OaYIBI7PHgIGaq0p5QjPGBMyMDI2MTAwNzAwMjgxNi42
# MjhaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2QjA1LTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACEUUYOZtDz/xsAAEAAAIRMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxM1oXDTI2MTEx
# MzE4NDgxM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZCMDUtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAz7m7MxAdL5Vayrk7jsMo3GnhN85ktHCZEvEcj4BIccHK
# d/NKC7uPvpX5dhO63W6VM5iCxklG8qQeVVrPaKvj8dYYJC7DNt4NN3XlVdC/vove
# JuPPhTJ/u7X+pYmV2qehTVPOOB1/hpmt51SzgxZczMdnFl+X2e1PgutSA5CAh9/X
# z5NW0CxnYVz8g0Vpxg+Bq32amktRXr8m3BSEgUs8jgWRPVzPHEczpbhloGGEfHaR
# OmHhVKIqN+JhMweEjU2NXM2W6hm32j/QH/I/KWqNNfYchHaG0xJljVTYoUKPpcQD
# uhH9dQKEgvGxj2U5/3Fq1em4dO6Ih04m6R+ttxr6Y8oRJH9ZhZ3sciFBIvZh7E2Y
# FXOjP4MGybSylQTPDEFAtHHgpkskeEUhsPDR9VvWWhekhQx3qXaAKh+AkLmz/hpE
# 3e0y+RIKO2AREjULJAKgf+R9QnNvqMeMkz9PGrjsijqWGzB2k2JNyaUYKlbmQweO
# absCioiY2fJbimjVyFAGk5AeYddUFxvJGgRVCH7BeBPKAq7MMOmSCTOMZ0Sw6zyN
# x4Uhh5Y0uJ0ZOoTKnB3KfdN/ba/eKHFeEhi3WqAfzTxiy0rMvhsfsXZK7zoclqaR
# vVl8Q48J174+eyriypY9HhU+ohgiYi4uQGDDVdTDeKDtoC/hD2Cn+ARzwE1rFfEC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRifUUDwOnqIcvfb53+yV0EZn7OcDAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEApEKdnMeIIUiU6PatZ/qbrwiDzYUMKRczC4Bp
# /XY1S9NmHI+2c3dcpwH2SOmDfdvIIqt7mRrgvBPYOvJ9CtZS5eeIrsObC0b0ggKT
# v2wrTgWG+qktqNFEhQeipdURNLN68uHAm5edwBytd1kwy5r6B93klxDsldOmVWtw
# /ngj7knN09muCmwr17JnsMFcoIN/H59s+1RYN7Vid4+7nj8FcvYy9rbZOMndBzsT
# iosF1M+aMIJX2k3EVFVsuDL7/R5ppI9Tg7eWQOWKMZHPdsA3ZqWzDuhJqTzoFSQS
# hnZenC+xq/z9BhHPFFbUtfjAoG6EDPjSQJYXmogja8OEa19xwnh3wVufeP+ck+/0
# gxNi7g+kO6WaOm052F4siD8xi6Uv75L7798lHvPThcxHHsgXqMY592d1wUof3tL/
# eDaQ0UhnYCU8yGkU2XJnctONnBKAvURAvf2qiIWDj4Lpcm0zA7VuofuJR1Tpuyc5
# p1ja52bNZBBVqAOwyDhAmqWsJXAjYXnssC/fJkee314Fh+GIyMgvAPRScgqRZqV1
# 6dTBYvoe+w1n/wWs/ySTUsxDw4T/AITcu5PAsLnCVpArDrFLRTFyut+eHUoG6UYZ
# fj8/RsuQ42INse1pb/cPm7G2lcLJtkIKT80xvB1LiaNvPTBVEcmNSvFUM0xrXZXc
# YcxVXiYwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2QjA1LTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAKyp8q2VdgAq1VGkzd7PZwV6zNc2ggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5wCh0wIhgPMjAyNjEw
# MDcwMDAwMjlaGA8yMDI2MTAwODAwMDAyOVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7nAKHQIBADAHAgEAAgI77DAHAgEAAgISrTAKAgUA7nFbnQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQBZN42ILwaZwxr/Hy8TqXk+27LRDCesiQzWygOq
# TyLkTFZciBnURUcL26ouPczwH+1VrTAD0iyzB/mBRZKiUqWSeeC8UwFzS4vxYMXb
# tNHUQ2fd/CEZJks+luSXIx5WGpq1O9Dg9pyOxs4OZ1FyblL/v8khOtEEiTAaduaW
# hE6+oULscpbZnWTSHt3qwgqo2ay37HRrgwP82GffvxC/aV7AfoMAQ3YYihKElZ3M
# optC75JE8xR7bJcDRfkzLTrNs5g+pjTGCs+ghNC36k4oK28EzaszdxRpY4f+Kl4j
# bhCUzVO/p6a2T+WIEOg6WfMxWpvplJNETOFLiF2wWI2yRseSMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIRRRg5m0PP/GwA
# AQAAAhEwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgf/Lmo4DZJjKU9kyv4fd7xOAK3+1YfPs8Bqd6
# GQMy84owgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCAsrTOpmu+HTq1aXFwv
# lhjF8p2nUCNNCEX/OWLHNDMmtzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEUUYOZtDz/xsAAEAAAIRMCIEIC2EI+2/MpVKHlUI52ff
# Wgq3T/R3AWTRT3uGC1B2hcBfMA0GCSqGSIb3DQEBCwUABIICALfPohGI7uXyqPMJ
# +DzvjcG8G8PbC7StWeIokbzLTQkeWWxXxxZMAcfxgwposRecyYUXkb7MOwfhPdf+
# TLiK0UPYdmr/wsN2TaciUCkOE/5FErWA2g4bsghMPl2LNOPhqeZgUV2JAb+dItug
# 5nixQ6+6no96PxGEzg3qiO1bQ2AoKjzKebgx6fZkgoPjADEiZfUkWa0p0pz1YDub
# 4dq4E5VBeV2qoKJOmrfmy5x0HT+zIqSgQUOGHZklieuv/1aI73uCPkABZZMsgo16
# TuhyqUE4/OH3YUFmDnFXC/gdL0D6ovU+dywp+zBRDmhWkXNj/t82RZMyQmd1fSsh
# u4IjCWoNfkhaME1aWQ5NsfhPYoby++sgBRzYiF1MRfrRvJoU9Qc9VzCXIda+dv8q
# 2Z6p71tmwvcf37kEJNN7XbXjvke41iSc7Mh7w5R+qJ7AHF6pRZtTGK3KPxBDbUDS
# nriNbx9wsz5twSvw0NQPqWvw9rYLOXsPUyYunPIErgDefnDamtbZ6tYizqXVqRfi
# 9oKCNjG4sI0xz97E1ELxle1j4WYV67Riy8hCSvtBovKjuF2eFv8yN+CBx2bRg018
# JRt35AaIzv37WZj0LVFOA01jIjhSvve/O3QE9gNiIZ24dzLsa3s3wXk0pEgBMLE8
# Czz9h49rucPg69vBIh56VIx7lbMc
# SIG # End signature block
