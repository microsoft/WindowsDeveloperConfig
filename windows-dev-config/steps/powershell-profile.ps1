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
# MIInUgYJKoZIhvcNAQcCoIInQzCCJz8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnfMIIZ2wIBATBu
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
# L195q4KVMJzEiUc34klQHGHfpKGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cG
# CSqGSIb3DQEHAqCCF4gwgheEAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG
# 9w0BCRABBKCCAUgEggFEMIIBQAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBPMWM4V80b1hu/BnXobRbkXIGz5Ab1YNY87xi2tbxdxwIGaq9UX3niGBIy
# MDI2MTAwMjAwMTQwOS45MVowBIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjY1
# MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2
# aWNloIIR/jCCBygwggUQoAMCAQICEzMAAAIVGAPTgQcmfFMAAQAAAhUwDQYJKoZI
# hvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0
# MTg0ODIwWhcNMjYxMTEzMTg0ODIwWjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0
# aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NjUxQS0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDDcdXeFXEvSURg9XTdd40pnnXt
# UhuB7GGUM92lfANLQFi3E/CLhdillHWV3S7pyvZeO66B2DnQNTHlYcvRCFjZ32+Q
# lKTTasT/vmFwq33WbYiHbztBHFEyYW7cEXrjrqTyqnm5e197q5yKrj1hpLyn53O/
# e5NqsPiFDxRPstr3mk4mJGrHF3So4YsQK8csRc9eKg1LH2nKHOGbqW3t7MvEl4VV
# i3FKGRq8+hk3R04KJh6HgqCgqjJqDMy5KIsKIxRbhR7hCybrnwUk0ZM2HtXmpdhU
# DqTnGPDlZ5Z0o7PSL0DmMFxtj19U6j9wDyLVvK3NwNPFvedy1yXLz85h42y2Rpv8
# iyrcLF7W+r3p8gcTX5kaYmORrWyh3Co/JxWn/a1v4GO6U8vkPquBRdM8XzhTzZEs
# odXntsHx8dGmCeNxYFC5c+BV5JekRFaKa3Q0XaUI4vOqCu9L+9ip17kuf1iUoqEB
# n/EMTRMsgivr4j/YlO1c/fid+NMQ1WowEhJZxqQjEDAZvdEHnIcLHKcgU1Utx8oC
# wR0LlTZ6bR8C+ZW/Syieqe/Xty5piLZ4ItaGgrUhzzkPDuz+WFxesGljif9GXmXf
# AfOzi84iG7zsMjLlBRoS6kSzJjQ1aqAjgFaXq/XCCx76XwNYV5Reh+FS4KBVO5Mc
# 3cryJ2gxufxDd51QgQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFIkhd/FyoDAWoaP2
# N3BC11Kpp2PXMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQB3jYe1X6QZu/HMsFML
# k7u+QIgE/L8HCmMLN4vneECIQ55un5V02fCb0ZUJ9ircox+uPhS8pBNQBpLlmTB7
# WC9neWNJKcI7JLk7A2712mDfDD5BbZ45xIuTJUBYWsufoiKDdML/NYy9WGpe10WE
# bYonWVJs3bbZyxjcTf8GsaW4CW8RP2CbFXLLE3Ln3/skXnMgZwmJvJ3Gz3gkvUG0
# +Bck59nND7/eJNzp4O2ZpZPoMp2cmhynzCRcpY8iwER+QPqTVCK3C+3SYes5FqHv
# lKN5w4q3ihZrJUuQ9OGjXZ7SieASDVyN7l/FJka2GsytYq8jhHscQLuTyZof148D
# dWIfQJVJI559o9MYzMiEcKjmneMblIxzI7d4D24RphAkhMmUsbcHDAabKljsL/z+
# ePVI6GDHUeAnTLA4kv3F8/gA5xaYJ9uyqAZsJoLtYfmwg13N8xqvxXtg0WqRsIZQ
# qFzwakjIT4wqfJWffeOy5oYCU1GDt1VFRKhgsnG9SzD0Y7DIGkHBsT2yo4ub4ew7
# TSgXbc8yKjtYVdwVNkCOne6OKEEB8utcgKAY4c92RnTja7Utmo5yeWvdfO+Ax76Y
# 8/Jqxbx/Su3MmPdXkT8QqLJCU/GP0x+rbH2GKaeVdYZkJU94QFE6s1sNgF9rNPIs
# 0I5OxG2Sw5JXcUG0+elC0s3vnjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNZMIICQQIBATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjY1
# MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2
# aWNloiMKAQEwBwYFKw4DAhoDFQCPp5N6Nu5gTUh+Nt+u3q1d68JRIKCBgzCBgKR+
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA
# 7mj6xTAiGA8yMDI2MTAwMTE1MjkwOVoYDzIwMjYxMDAyMTUyOTA5WjB3MD0GCisG
# AQQBhFkKBAExLzAtMAoCBQDuaPrFAgEAMAoCAQACAhg/AgH/MAcCAQACAhOCMAoC
# BQDuakxFAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEA
# AgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAFpZBWaeXD9W4QmL
# 3qoTB6cAyaU6BwpELxT3JWLSkhm4tv9KrQ9CEVjPNVUAMHKWiT9hXf/NEaYh9dAG
# hlaunFF1lizS6722KvGDjkcmdVhSTKIl9JkT2NnXnACJ5tFrmxUfAr+wboDiNJ1d
# lRRW9kl8OzXi5eUEpZRabg4042BGrVvR3I/zOoU8pKElPvnVSJtcYI9EM6Z3MF2M
# oVfDJP+YICCaYgUbioL8weoMnkuFI6d7QNBJIOHIzXXuT6IklCwPBNAnfLO0LfJm
# BrHP4sdS7v/JV621fGVUIAsDNZrH+h2ADym1lEKhY1MMLZ87YL8inb+8Z86KFD8s
# Dn7snlsxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MAITMwAAAhUYA9OBByZ8UwABAAACFTANBglghkgBZQMEAgEFAKCCAUowGgYJKoZI
# hvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBQc/pQdxI7SvWk
# PBsNJdrmj7IB544IkfKUWT8Q73aIXTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQw
# gb0EIHAQ9HY8OtMUtyu1CwqtSLujPkk1EIX8pEcyKFI17uyKMIGYMIGApH4wfDEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWlj
# cm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIVGAPTgQcmfFMAAQAAAhUw
# IgQg/KUU0fosNTtzkvQDqsk3UZVz02G0XoH/64fvP/QEuLswDQYJKoZIhvcNAQEL
# BQAEggIAdcEW7uoo935ExJBojyOHE8OB56wvhLM2uPPGBIMSTNKezMS+XQMUt4dN
# 2uWm0ZiF00TPieCwp8JT6vQ0pGfsL76W/P/stEh8FPGR9eX0fL06TwUJ3lA6HMn7
# yXLKOMarU/gq2aaI+vtP81Xn7AJuYONh1klis6a0bOgV+7jTxvDZkVx3kxoOjgCg
# zJMqkXzoUJ65VdaOJPoVu/o3rqCik/gx0Gfn95ofnoE8wpuRT8g9gj2tKIEOw+oL
# E1HJ6msjDn/+g1+KPmg/+NWSVsJGSSw5zfRkwpbcPz+PupwiG366tm4UCg77f73+
# 3uZ/GCnWXFTmq4d0YLntnNl3AYRdFtI19vYmQ/LIiGBUooAny1jbW2F074hNcih8
# VplurJ3aStTYiE/m65auVbdNthBEkTJFU9LUN69IVNu+GxYRZhakq4bf3uSP1riF
# wSUmccjuxrEnEskorEeboFqhlkXhKPEfGoW+L39f/akRxsUn8OJyFVKCpfBcIGDb
# Oia0jzr1xP0147CnFT/lKSNc5/jXGU9RCsxv5XtUgEDhUghxpNYuWW+EBEzvTSW/
# ecw/AETMO7h+znP89+yhkdETdXo6xXCNYh+2ndfgPIIepIfJvaZpIAJxGKWf/zlc
# ck9nlzkmK0X9d/iA9dTty3Cl9EUKmYtFj1R4UhX1i1RhoBSW5W4=
# SIG # End signature block
