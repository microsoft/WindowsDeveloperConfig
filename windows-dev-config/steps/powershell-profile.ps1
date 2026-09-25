<#
.SYNOPSIS
  Configures Oh My Posh initialization in the PowerShell 7 profile.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exact text is needed to recognize existing setup blocks.
$Script:OhMyPoshInitCommand = @'
$(if (Get-Command 'oh-my-posh' -ErrorAction SilentlyContinue) { 
  oh-my-posh init pwsh
  # Set output encoding to UTF-8
  [Console]::OutputEncoding =[System.Text.Encoding]::UTF8
  # Set input encoding to UTF-8 (for reading user input with non-ASCII chars)
  [Console]::InputEncoding =[System.Text.Encoding]::UTF8
})
'@

function Get-DevConfigOhMyPoshProfileBlock {
    $block = "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n" -replace "`r`n", "`n"
    $gate = @'
$usePosh = [bool]$env:WT_SESSION
if (-not $usePosh) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $usePosh = -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        $identity.Dispose()
    }
}
if ($usePosh) {
'@
    return ($gate -replace "`r`n", "`n") + "`n" + $block + "}`n"
}

function Get-DevConfigPwshProfilePath {
    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        return $null
    }
    # Ask pwsh for $PROFILE so the path follows the installed shell.
    return & $pwsh.Source -NoProfile -Command '$PROFILE'
}

function Get-DevConfigProfileAst {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "The PowerShell profile could not be parsed and was left unchanged: $($parseErrors[0].Message)"
    }
    return $ast
}

function Test-DevConfigOhMyPoshInitPresent {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $ast = Get-DevConfigProfileAst -Content $Content
    return $null -ne $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -match '(^|[\\/])oh-my-posh(?:\.exe)?$' -and
            $node.CommandElements.Count -gt 1 -and
            $node.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.CommandElements[1].Value -eq 'init'
    }, $true)
}

function Test-DevConfigOhMyPoshProfileConfigured {
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        return $false
    }
    $content = [string](Read-DevConfigTextFile -Path $profilePath) -replace "`r`n", "`n"
    $desiredBlock = Get-DevConfigOhMyPoshProfileBlock
    return $content.Contains($desiredBlock) -and
        -not (Test-DevConfigOhMyPoshInitPresent -Content $content.Replace($desiredBlock, ''))
}

function Set-DevConfigOhMyPoshProfile {
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        throw 'pwsh.exe not found; install the PowerShell package first.'
    }

    $content = [string](Read-DevConfigTextFile -Path $profilePath) -replace "`r`n", "`n"
    $legacyBlock = "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n" -replace "`r`n", "`n"
    $desiredBlock = Get-DevConfigOhMyPoshProfileBlock

    $managedBlock = if ($content.Contains($desiredBlock)) { $desiredBlock } else { $legacyBlock }
    if (Test-DevConfigOhMyPoshInitPresent -Content $content.Replace($managedBlock, '')) {
        throw 'Oh My Posh initialization outside the setup block was left unchanged. Adjust it manually to run only in Windows Terminal or non-elevated shells.'
    }

    if ($content.Contains($desiredBlock)) {
        return
    } elseif ($content.Contains($legacyBlock)) {
        $content = $content.Replace($legacyBlock, $desiredBlock)
    } else {
        if ($content -and -not $content.EndsWith("`n")) {
            $content += "`n"
        }
        $content += $desiredBlock
    }

    Write-DevConfigTextFile -Path $profilePath -Content $content
    Write-Host "Configured Oh My Posh init in $profilePath"
}

function Remove-DevConfigOhMyPoshProfile {
    param(
        [switch] $CheckOnly
    )
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }
    $original = [string](Read-DevConfigTextFile -Path $profilePath)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($original, [ref]$tokens, [ref]$parseErrors)
    $content = $original
    $blocks = @(
        Get-DevConfigOhMyPoshProfileBlock
        "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n" -replace "`r`n", "`n"
    )
    $blocks += @($blocks | ForEach-Object { $_.Replace("`n", "`r`n") })
    if ($ast.EndBlock) {
        # Match only top-level setup blocks, not examples in strings or custom functions.
        foreach ($statement in @($ast.EndBlock.Statements | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $start = $statement.Extent.StartOffset
            foreach ($block in $blocks) {
                if ($original.Substring($start).StartsWith($block, [StringComparison]::Ordinal)) {
                    $content = $content.Remove($start, $block.Length)
                    break
                }
            }
        }
    }
    # Validate after removing setup blocks, whose leading-pipe syntax requires PowerShell 7.
    [void](Get-DevConfigProfileAst -Content $content)
    if ($CheckOnly) {
        return $content -eq $original
    }
    if ($content -ne $original) {
        Write-DevConfigTextFile -Path $profilePath -Content $content
    }
}

function Invoke-PowerShellProfilePhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @(
            New-DevConfigStep -Name 'OhMyPoshProfileCleanup' -Description 'Remove managed Oh My Posh profile initialization' -BestEffort `
                -Check { Remove-DevConfigOhMyPoshProfile -CheckOnly } `
                -Apply { Remove-DevConfigOhMyPoshProfile }
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # BestEffort keeps prompt customization from blocking later phases.
    $steps = @(
        New-DevConfigStep -Name 'OhMyPoshProfile' -Description 'Add Oh My Posh init to the PowerShell 7 profile' -BestEffort `
            -Check { Test-DevConfigOhMyPoshProfileConfigured } `
            -Apply { Set-DevConfigOhMyPoshProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBHb86WvCg/pP1t
# UAP2lNnebMquS4cFMcAgcwOUgfe326CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIKAyh4aLVyNHB3JsKn/OLcmGpPwn
# QVVupPgd/2zhxQCnMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAkgNpHcCZKFKMCD/iA++RH1srs+uBVQjzUdglOgOHOsQkmHf+Fm9W/FzC7wup
# wiSW/IlIb8zhYFNOUyLnwMT3K3yGxMmXRCvG7ahHN4EoQuo/KigPYn111zWhOP2f
# v0IwaS+7BykzDWMiYgi8uXQfcVB0aIbZfCqbwj+MknuHVaxVoSk8zZJ4O7moBBQ1
# LZak3RuNlMZzH0NOA5iB6H1Xhc5eyZjWtByhOgGE81RlL7kpjfFUmD5sx02AnJLu
# YMo3Y/upeVcaOO1QK5qrpepYn1BwdNfODtMrVBRBt3PGlssA1MI0CE0fsU4eIbHi
# L195q4KVMJzEiUc34klQHGHfpKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBPMWM4V80b1hu/BnXobRbkXIGz5Ab1YNY87xi2tbxdxwIGaq9u8yqSGBMy
# MDI2MDkyNTAwMjEyOS43NzlaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# RjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACHAlVFdfDWQfRAAEAAAIcMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgzMVoXDTI2MTExMzE4NDgzMVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZGMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAow0xEAUaFIyyLIXeFzeI8IKy
# BON2u0Dr02ISE5p9G5CUXfnFu2S0E1gWCMvDWpopX6lRxjmgnqaL3BtnWlBVTo8x
# UNRZu23ie4YBMAJB7Ut6mnqnHVwvDJxGO4TD3SnrCd+yg35B9QFejq3o4+OByvXj
# ynaypZyukcQaLsKQvoxE8ElHH7zcOXEJWmU3rnXzaW/S4SH3OPhoUbTTcy6nUgKx
# 5pRWiQ24UEPLYzcxGJjqjkz+GiCWGPFHDMdW86laWvmCslouQPsN2eBk8dxJcEZm
# W4l6p4TthoXcfexEA9YdYaMz10aMhZNpdsNaDtDQUMDEC3k1D1My69MXSPlUmD9x
# FyDlkXiVa7BCEp3XcVtqTgzHGwr28JD6oE7zEPYeuZOiuCBXTZSo/wk3tbDlsESb
# IPV6inYqrzxiMYqlxfCdzC3Cimh9/NT/Lk9/aU+Iyyc9b3OaT0dZ8wgLaVDCGELR
# MrqyImdFHv0MudctzW/kPsV3Ja9ufpKWujEiN3CW//X8hFa9j5ImNeQzcMit3MoS
# aoGwnbiZJX1IyibIphlqccXFk4oTTSOQBsAUw8U0gwOnM5UJD8mBUBd65Np6NBkx
# 2cviJ4I34GyXFCWyy5Ft1QsBYyVfAG3KOhCfPHQf8lQzJvLr57YW0bD/xVs4Ag4g
# TS6KZNyFEfX9jFdRlr0CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRa3mOCzB8u7zpv
# Dh8MGKVYLCk7ZDAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAklb6w/deaid3BujQ
# CtWFBe0n9pkyRy+yyWEg70iDwoJ5u0e0O+4GerNzdZb1zTPsHJ8EGMyo1K7ytL21
# +pmdFMTl19PC8OJ5Y2p+XKUQy2dD+hggRMmJgDQsgbOCxHYeO+jg4t+vg61wUrov
# zzLkH3z0PJXXvoNuBj9Lda9CiNMd60451Kube99ArSf6ZMj3t0p4rFbgSazDs+8T
# J+8KA5GVaYjPHj9rlMuI3WjohEc9apnQ6hMjMck3jlHZIwluVYeUQE0qjmApfMtT
# AEzbMUdY8sLTunL1GkbDSeKn9O7llBGnNtyM1uM9Mdv1VyWh0z/IriQKIjntqqGy
# oF0HvDHOFZCyUDBPLflyiu7Y1zQ/sPounsb96aBfQdq3h3LOn6t+m9EnNz/G6Mzz
# WvpJk6YgTHTIqeQN/F/XpiPvbfek3nq/PYbL3au+kBfRUHiCFXSvt6lor0HC626v
# Umz9ZNPOxwEWLuccomxsy3JwWH79vsM/7ARqoG5h6d6NahfaOuRP4XI9xtdH3Pa/
# NCLyQjxKXyLxzwQzjddkX2EpTJnlypuhPmEdea59Uz2E303LxyXSnKBvGsAnyWYA
# fnejr3YAiL9YrN2l2dn198RpA4DCm9QtZYiwC0q2fuUvui34PfPIUZByf7wHuuWu
# 50hY9WLx1kOMI8xyo7AI6TaNrnIwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# RjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAWmTiA01u5mxq/nVxiRJLMOskVGeggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5f26cwIhgPMjAyNjA5MjQxNzI1NTlaGA8yMDI2MDkyNTE3MjU1OVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7l/bpwIBADAHAgEAAgIBbTAHAgEAAgISyzAKAgUA
# 7mEtJwIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQBvJEy7sHFFVWT1ALfC
# rbC1xJQJmIz3DAEYjBLSwGYuyOSALIGR89zZqaR32IEVIJTI0Xvb7moAnN5byM1f
# 2OOzNxHF7Joit7M7awiECP8x37pphKQWj1VFVUp7hEw/y9k4mLYTNrTveDmvcy6E
# O76x/0fUF3qE/L2101O2Dn+GcG922X+ChCShXzLrU1DMJ+Ss/FKtf1/KZOw5BatM
# pE0GhJaCSs+fTRr66EMOfMvVIb9oQ2SEzw4urda0BC96sGYxMmM6mpzwnot0s2/g
# shpbDNQT+C3+RJ8Zw7H1wpGpv2P6pstZs6PEJ3DC/gW1xwYKtBcGhfQxLR658sk4
# O5AfMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIcCVUV18NZB9EAAQAAAhwwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg/vtY9FajzBqaoWir
# tgS8J5rFGv2dJdBqpUQObZDWpAIwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCCgIGkmNhdo7+KE7dWhI+E2Ctx2RLWoYvvJodCIciHHaDCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACHAlVFdfDWQfRAAEAAAIcMCIE
# IEtdI++u94H3dSiFAMyU2i8Jx4IvTx5fJibPSS+kEp67MA0GCSqGSIb3DQEBCwUA
# BIICAEhGmXoq0f0IUu6xdQbM4a+OsJeuQOTXtJzJP6zdwmaXRgIccCB5u3s432It
# XDsRMjGPpjikcHuKmIGGzAt+EyvBOPgjNhSAYshVihOz1CeMt1Wb9N8bFB3lBDpx
# 1WI1HAaZwuVtSDbVTMD5TGdbArYRU510lFo5wTwKOgVIm9QyL/W0JDMQBIqqTQ17
# ZCuinN9jCgfIyFOkwSRbQL+qtaPeGko1+xEmURK+8aKHX6uZuL7fJ7x7lnkpWRW8
# 9MgU1BBdKD6JDSGGR4iOZIfJPON3IATzXwYJXqFZ5xnSXqnAo8O/jXWclD9TAdez
# v50vH3ZcDlh1or6WxS4UQY4yn2NjOROt5JkZgHudNHG9jBcvAK4+/XarK4L+7dRb
# HUFF92dkCdmrTNdoaPj/3iunMm6ww7nZ06kKixrp27muGfYYSte8oLcAAQ76vRLd
# 8HeMANNaGr+7By4awgzSLDBmrpeXsa/ypQDUP9GSznJdmIDKTX2WqRg8HkOjzDdE
# /oVkVVGB0+iNOKsXjOYVduOuq3saSKXNpuSZJZPyzudSjcKPAOL81R7t90FrCja+
# S/nDp0w1xGPy5NUNFxi4t47FihOfMxc6/Nyt6z6q+I4fxsPnTAg2NydH/OxZaZWO
# a3iRKk7f6LC5wlCttllPu5thdkmRcIeTGWNbx4ZwXhYky2A0
# SIG # End signature block
