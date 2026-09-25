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
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
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
# npRyufehjlirubObUD83MBOb4aGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDEOxfOyDzXlkajDdWMWNK4+AfZVzqDbwxjZbo+uGKh+gIGaq9TkKL9GBMy
# MDI2MDkyNTAwMjEyNy40MjNaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACFRgD04EHJnxTAAEAAAIVMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyMFoXDTI2MTExMzE4NDgyMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjY1MUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAw3HV3hVxL0lEYPV03XeNKZ51
# 7VIbgexhlDPdpXwDS0BYtxPwi4XYpZR1ld0u6cr2Xjuugdg50DUx5WHL0QhY2d9v
# kJSk02rE/75hcKt91m2Ih287QRxRMmFu3BF6466k8qp5uXtfe6uciq49YaS8p+dz
# v3uTarD4hQ8UT7La95pOJiRqxxd0qOGLECvHLEXPXioNSx9pyhzhm6lt7ezLxJeF
# VYtxShkavPoZN0dOCiYeh4KgoKoyagzMuSiLCiMUW4Ue4Qsm658FJNGTNh7V5qXY
# VA6k5xjw5WeWdKOz0i9A5jBcbY9fVOo/cA8i1bytzcDTxb3nctcly8/OYeNstkab
# /Isq3Cxe1vq96fIHE1+ZGmJjka1sodwqPycVp/2tb+BjulPL5D6rgUXTPF84U82R
# LKHV57bB8fHRpgnjcWBQuXPgVeSXpERWimt0NF2lCOLzqgrvS/vYqde5Ln9YlKKh
# AZ/xDE0TLIIr6+I/2JTtXP34nfjTENVqMBISWcakIxAwGb3RB5yHCxynIFNVLcfK
# AsEdC5U2em0fAvmVv0sonqnv17cuaYi2eCLWhoK1Ic85Dw7s/lhcXrBpY4n/Rl5l
# 3wHzs4vOIhu87DIy5QUaEupEsyY0NWqgI4BWl6v1wgse+l8DWFeUXofhUuCgVTuT
# HN3K8idoMbn8Q3edUIECAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSJIXfxcqAwFqGj
# 9jdwQtdSqadj1zAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAd42HtV+kGbvxzLBT
# C5O7vkCIBPy/BwpjCzeL53hAiEOebp+VdNnwm9GVCfYq3KMfrj4UvKQTUAaS5Zkw
# e1gvZ3ljSSnCOyS5OwNu9dpg3ww+QW2eOcSLkyVAWFrLn6Iig3TC/zWMvVhqXtdF
# hG2KJ1lSbN222csY3E3/BrGluAlvET9gmxVyyxNy59/7JF5zIGcJibydxs94JL1B
# tPgXJOfZzQ+/3iTc6eDtmaWT6DKdnJocp8wkXKWPIsBEfkD6k1Qitwvt0mHrORah
# 75SjecOKt4oWayVLkPTho12e0ongEg1cje5fxSZGthrMrWKvI4R7HEC7k8maH9eP
# A3ViH0CVSSOefaPTGMzIhHCo5p3jG5SMcyO3eA9uEaYQJITJlLG3BwwGmypY7C/8
# /nj1SOhgx1HgJ0ywOJL9xfP4AOcWmCfbsqgGbCaC7WH5sINdzfMar8V7YNFqkbCG
# UKhc8GpIyE+MKnyVn33jsuaGAlNRg7dVRUSoYLJxvUsw9GOwyBpBwbE9sqOLm+Hs
# O00oF23PMio7WFXcFTZAjp3ujihBAfLrXICgGOHPdkZ042u1LZqOcnlr3XzvgMe+
# mPPyasW8f0rtzJj3V5E/EKiyQlPxj9Mfq2x9himnlXWGZCVPeEBROrNbDYBfazTy
# LNCOTsRtksOSV3FBtPnpQtLN754wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAj6eTejbuYE1Ifjbfrt6tXevCUSCggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5fwEUwIhgPMjAyNjA5MjQxNTI5MDlaGA8yMDI2MDkyNTE1MjkwOVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7l/ARQIBADAHAgEAAgIIbTAHAgEAAgIStjAKAgUA
# 7mERxQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQAJ0O2SqDV/C7gyZK82
# 6NRkF7JoV0DgWmpqZUSHTfoi9cW85bOCmPXWtonyrZ2WVm0aaW+vCRQNcKituYN9
# wCbgmRZOXbVmonu14gBUbX91fTIXnW79pMIyyDTAmx4hK/CcSTZhdCzS9vSisj+L
# DuOoQCakFP56P9+SZ0Af/vOwSwvy6qA09RrAK+jNcCt6I/o1Omrx2d4rUa6gHzAi
# aTovuWwguyJ18QAbU7XteAc7nQsdDWYWj1Z/IK/mQ8EacyEQkWniRvQsJHQwvxKG
# oRJcm94+5hdAbZ/NSqcCJXHalb+kOf7ywMzESxE9L8R0LolaKcClNfUEPhhjxCE4
# 7kHFMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIVGAPTgQcmfFMAAQAAAhUwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgE0w0x8j/FlC40wHa
# bTwwx/epZV++aBLqvXSlD2LaJdUwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCBwEPR2PDrTFLcrtQsKrUi7oz5JNRCF/KRHMihSNe7sijCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACFRgD04EHJnxTAAEAAAIVMCIE
# IPhL7qGMssS1VRT7c75nS4bzMQ8QH0PVUSB0GYbdbwt1MA0GCSqGSIb3DQEBCwUA
# BIICAJO05f3p1Emt9+AlKWX2U6RLOu5GEsw2GXz2fMjVW/Qs4DmvGMWaj9a+a1R0
# d+lPyaJSNnsGZ1lqjqeLunYTu0SpHcd2vliJK/YJO+RUOui6s2rqwmx3grk1CevK
# foGdOnGP+4JcSmoObt8/xdrsmnzUX/2DzX6GK3HUY3NHHpnV5tL0MqgBvZM+o25q
# lE1v5rJixX4E23nftfu6xmFGzT9eOnEqzAA9wnbkc/UxyXkQsXGsqImLGLdhW2JV
# Q4pWD0TgzobghJI/FhGe6kPuyiWvxI+ohS/eNCy4yq4SUXrstwKrsVF/N6obFo7k
# Nh4NMDbtI6S93XvWT5WNRjon4eLy/VISL+gao4kWqgiXwreOGzQfPey3oLV0Yezv
# MOhqNnCXNRM/6hv27wBgsvx4kUVAE2YesbmROZZwNS4e/y+6t1yUZ2iMpB3T+kLN
# QKPqTves6SXmcZ8hMykj5JYMqiZjQXY7tWClafZJTQ2gVb6KLob6bsbvGA+quShj
# 6kSc7GL6dW5CANMehVkGUD2TdXv0ufU/N1Uj1NEviLIYebj5maqxKvcp3Kj17i5V
# nBCMhxKGwJlbU8BfA62aA3djX469+Vphflg6RntKp21fP2JG7oy+HQiCS7O96e3f
# cbTXQ6jG6E85E+g3EwC0L7iLrJdfrhhTueQ/w5f2Mh2w3a8W
# SIG # End signature block
