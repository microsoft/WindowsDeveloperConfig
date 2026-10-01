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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDJevIvOKJZj0Bp
# uhbmAUGClZO8ZJd0p+mRcKmKClWXzaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIGd467fM/wYFpIeOzE3FXRaO6KY6
# VkvdttClgACfdYwQMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAjOr6AKXf/ZWbiD2kOhDLu/MoNbLhGyw/ezjyjqHStD4Slg1iktVokf68OLiv
# 4Kj5ciJxmZx7eGpztfRZWlrDWc1VvpeHYquh7TIVrUqrk45bMoIueSKNInS1RZit
# tPBB58Ej7PGC8G1yLriKnkivZcyvk0PlZSFwRiNP1t2aHA6oPuVXXRNv6x74Sc4q
# Kj3SMh84rWtGMWrzw5ThQy5TJX0kMuJRWQ1zEYc6fBJqDcnxTH4MSkCg6QbRLuYw
# ehpGW4AAUyvVH5/Wv8Er6wSUCMiKjA98yN4rdr038zq4kQzazPSOP3C86cM8J9fB
# npRyufehjlirubObUD83MBOb4aGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDEOxfOyDzXlkajDdWMWNK4+AfZVzqDbwxjZbo+uGKh+gIGaqpokv4qGBMy
# MDI2MTAwMTA0NTMyMC42MzFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
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
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mgChjAiGA8yMDI2MDkzMDIxNDk1OFoY
# DzIwMjYxMDAxMjE0OTU4WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuaAKGAgEA
# MAcCAQACAgEPMAcCAQACAhO6MAoCBQDuaVQGAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAI1ddPYM4wxA3Zmx4j8N1f3s50ZEvm/wq9YeeIABvj84aA9OwGTL
# 1sSvZmdIShMBmH5ASMUlMblgO8l8ptgfYwPys5DFcgGLhEnX9zTRz+YCRYKQl2wr
# MqqTuQYClnwxQLhw9AF0miCcCFQUIe+orMjDhGjCL5j81XohOdp6MqnwPhzBdOWK
# QGTBQqWlrB/cC7cMmesOir5Ipthj7yhgMMcXAVo8lioi/kALfG1Cqd2WdduP/rVz
# v3MUHrdBU5+eJZvTMBJBJe3e2xBYa34eTBVQqOQYvryXh4ffsBdoJ+QGpn0yl8oA
# NGFTbuWqqDC2GddOaGdrkJLLhBa0OXq0OuIxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCAahKaprNx7kPphFEUUUcsH9N7yWv99c76hHuxiwn+d6TCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaNP3VB
# YqLFjUsFnbgqMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAImNbQ+Z0OT9h8AAQAAAiYwIgQgZCaqVuRWQWOx6vZ7bBKQL2c4xdIqMAP/
# GzlNoEty9HgwDQYJKoZIhvcNAQELBQAEggIAFrbMrADZbMZkpLUUm56MPkqgIUXy
# /WVNa6PxmNZcgvotwKbLCGB6fP+KU391YzTWEdhTpH/eUDNgK0DBeRAfi526dM41
# y3n1ppFO2mguVPEB+uUosITDiml8FbLtxK/wzaQ4RIb7HOsgAVXiNUFImjvZCqSo
# 9J9gwBg+mHbNAjpx6ILz1LSpAtFYdtPlaTDF1BMPQ1WPr0H+T2xeSftaWuwT9D81
# obxSI524YiPUq2WwtjBdiy2CBvcyo9gBkS3y7sl98dNuHwrKz/iqQxyerGEaHgua
# /GRBLcvSQVIuPeGA4biezZk+sDkYOO2Kd36VItZZX1XSfmluvUNNtzUtC4jBQ+1c
# B2rbtgH5Zhq1Uzep0Pm9IcFNCFJFw7gtrmj5Z5iPXoTDAdBDqa/7FX6IogBGl4EZ
# YQNWjVl4nyrn2kTQSFimLE4Rk/VIi1n5wUPAgPebwCYHFtKqHMj474R6vk5IaP3t
# hyLpoILNEDDmdH9xHlJwpvnO5dxFKQMVDZoyz9L6WX6MNPZNOTFJTv0B5TYJsxSN
# kZxgcTYgF+ra5lcfTVN357GBEQ5gkj6USqwszO3YXwzYJUPCKI7Krk07Ik6axDdZ
# 423OOFqfBZNd+RDb/Rrt1oljfF1q7wV6sU1xBN50lOlHwmAjAmZ2CcIlwodfD56O
# G7K0z9x90ktaz7M=
# SIG # End signature block
