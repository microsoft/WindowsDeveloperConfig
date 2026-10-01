<#
.SYNOPSIS
  Verifies setup signatures and protects installed files from non-elevated writes.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-DevConfigProtectedPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Ancestor
    )

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Setup cannot use a junction or symbolic link: $Path"
    }

    $owners = @('S-1-5-18', 'S-1-5-32-544')
    if ($Ancestor) {
        # Windows drive roots can be owned by TrustedInstaller.
        $owners += 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    }
    $acl = Get-Acl -LiteralPath $item.FullName
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $owners) {
        throw "Setup requires an Administrator/SYSTEM-owned directory tree: $Path"
    }
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $descriptor.DiscretionaryAcl) {
        throw "Setup cannot use a path without access restrictions: $Path"
    }

    $unsafeRights = [int][Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    # Generic access masks are not named by FileSystemRights.
    $unsafeRights = $unsafeRights -bor 0x10000000
    if (-not $Ancestor) {
        $unsafeRights = $unsafeRights -bor [int][Security.AccessControl.FileSystemRights]::Write -bor 0x40000000
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($Ancestor -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($rule.AccessControlType -eq 'Allow' -and
            $rule.IdentityReference.Value -notin $owners -and
            ($rule.FileSystemRights -band $unsafeRights)) {
            throw "Setup cannot use a path writable or replaceable by non-administrators: $Path"
        }
    }
}

function Assert-DevConfigProtectedTree {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $root = Get-Item -LiteralPath $Directory -Force
    if (-not $root.PSIsContainer) {
        throw "Setup requires a directory: $Directory"
    }
    for ($parent = $root.Parent; $null -ne $parent; $parent = $parent.Parent) {
        Assert-DevConfigProtectedPath -Path $parent.FullName -Ancestor
    }

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root.FullName)
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        Assert-DevConfigProtectedPath -Path $path
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $path -Force) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function New-DevConfigProtectedDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($Path -notmatch '^[A-Za-z]:\\[^:]+$') {
        throw 'Setup requires a local directory, not a drive root or network path.'
    }
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Directory]::GetParent($Path)
    if (-not $parent -or -not $parent.Exists) {
        throw "The parent directory must already exist: $Path"
    }
    for ($ancestor = $parent; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        Assert-DevConfigProtectedPath -Path $ancestor.FullName -Ancestor
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid), $rights,
                'ContainerInherit, ObjectInherit', 'None', 'Allow'
            ))
        }
        # Set ownership and permissions atomically to prevent unprivileged writes.
        if ($PSVersionTable.PSEdition -eq 'Core') {
            [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), $acl)
        } else {
            [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
        }
    }

    Assert-DevConfigProtectedTree -Directory $Path
    return $Path
}

function Assert-DevConfigMicrosoftSigned {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $Directory = (Get-Item -LiteralPath $Directory -Force).FullName
    $scripts = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.ps1' -Force)
    if ($scripts.Count -eq 0) {
        throw "The Calm OS payload in '$Directory' contains no PowerShell files."
    }

    $failures = @()
    foreach ($script in $scripts) {
        $signature = Get-AuthenticodeSignature -LiteralPath $script.FullName
        $relativePath = $script.FullName.Substring($Directory.Length).TrimStart([char]'\')
        if ($signature.Status -ne 'Valid') {
            $failures += "$relativePath [$($signature.Status)]"
        } elseif (-not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
            $failures += "$relativePath [unexpected signer]"
        }
    }

    if ($failures.Count -gt 0) {
        $details = ($failures | ForEach-Object { "    $_" }) -join [Environment]::NewLine
        throw "The Calm OS payload in '$Directory' failed Microsoft signature verification:$([Environment]::NewLine)$details$([Environment]::NewLine)Setup was not started. Use -AllowUnsigned only for development."
    }

    Write-Host "  Verified $($scripts.Count) Microsoft-signed PowerShell files." -ForegroundColor DarkGray
}

# SIG # Begin signature block
# MIInUwYJKoZIhvcNAQcCoIInRDCCJ0ACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCJpZE9z1aUcDne
# 8qm486fYBIHmo2n/tHOpKMgLT6k1haCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEICzfBFlb9T/9Ak+weDjj8PObYGnz
# YrPhBNjRj0hg0EpAMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAH9p4UbHMUiThOTH9GPxW+FAGs1M9y89HytpOgNfd7shRnbWjD+NlW39S8Hv+
# lja6KkA2GxE4+e3k8370f1gyHL1rQ53skDikUO6jWF9TApd43aIH1nKSrlA6LPMz
# ir+PhONLPBwF4VJc6u98u6AQbNHnrOOMyr1iuztBIViRnlmLSVefkbN7iVkhIm6k
# gDoq6NmcXsO34FUNiWa1tOheqeTWXSjPn4S35kk2BkjwZ/F016KyniGRjK6SEcqH
# ZhaYohP3yFK7MwERBiGZciUbcbqKCm+fC7SS/Jdgrvny8MDJm27XG1cifZSLRu89
# kp9TQ6kU7yE2Nzq3ib+F6hH0I6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gG
# CSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAD09wALhhQTuFRTLy5v/P1iRChfJxmAwZI7UWrBerGjwIGaq6v8lsAGBMy
# MDI2MTAwMTA0NTEyMS4zNjZaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# MzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACHUvAkoc4hX45AAEAAAIdMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgzM1oXDTI2MTExMzE4NDgzM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQzMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAorSgaAA8oOl4ph574zw29egU
# N8DDepRHLX8FM1zHNJmXG6KrSqUKwzcKafopuYdPTETTCvb9aJfESuAU0iGNUFI/
# D6R0kvdfpe2oPX+E3sbTQvGi4JPH5qdIYUaJ45V/4bqe8eNvbWzpC+ZKjH193Dei
# I1XAI918JoQmBhlEXo/Ton1721luZJgincsf5LjMY3jX84WyXUSX3dsS7h/7xVI+
# w1yjg7pa+0y3o/me2Tsv6UJUdSTQap5ORGSfCnclnP1z3IiiWIWr3Vo7aIPWsgJz
# q3m5GxpxUHCQk8qzUhk50y/uB+LGE3WIK2C77iy9iFsSfSLUnyMEzGRDW9mXHT4P
# H7Ozz6CHqQEiNvwcHqlvlCh1pHQh1NXQSAqOoVBs5mi6easf6yxWTfe5DrR79503
# r8pU6VqC2Y9XMRU4wH9QbYXYsIUZ33Jmndy22W1LBDAbxBPQHCBlncGDU3BgdhVU
# VLe80mggFO98FdkWho67w4kPdCTRkvdvkY8PrQYE/nQjHXCa0g7LcMttZb6ejMHf
# Q+tUWXv6+nZ4Ynkr2OkaxclFCw4RIYNMWD26AWbQj/WEdzga18fKtw66L5gzXPza
# 6jFBfPJeKE3H8QAuwpirmH4ms+5nUjNNQOmNgqJn0U1+3Yn7ClswD79YN0r3fdbY
# BMDApBZJpNlK7q7HXRsCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSEWfBxNEamZtXm
# 8gl92Yq80jfxXTAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAkdweB4yxvLspLKq0
# D+miyD4Q0EcxVFpNZuJxiR54gWRkeTDDuymNeB03JhlsBpbwSYJ5uZSgDBCvwHED
# 2VL8lJpFlOprJzxsXWC2NTfA+O+PO5Fk5jw6LHh6jeBADDEdQAx3Hqi7Zm0JwvQ9
# 3z5f6dtxkm29WqOcHYXRXfAQwy1hSrLXyfeblqR66jpP/9n0fCkWU4ggsUjQpQ2N
# gj1DV09J4Y3y7p9Nd81+Xs6qYo++7RKm8qiB/5NDeigOLjlAeFgiEXIRUJW+mJyq
# pQw+OORlaqcFjR8Hu0G+/7bMdek68YX+kPpDBk7Ue+I/xgiYJ1xcDRBn/vczLtN7
# 2+RIlD4UgXYLuBSCk//pDEPX5z39Cr+rkc6E4Y28FPk4BhloAyvp628P4xfElQY8
# TcxraUbZShypocE6ny95D1K1BkltZmrHVKCxmglnuOlM15NKIrXFlXCzdqpCtIwQ
# 417wNAVF/QDPvzzbumPdTi6fb0tLbScYobV6zvbBsMsKEME4Tj1b9oIXC8dybJq4
# nbboEXYpRwi1QAbpSNrn+PxGW9uf1q63FnMJu4gm3Oh63njW/iVf723quzyHrSij
# WMgY0HiRiHQi0Jyu0h8MdhRUp7mxbmLQckPiOFwAlIaUN/k725y/aLWpkRU6fqmL
# lEOyH5WpyLd23AYy9r8v+Qoba6swggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# HVUzWLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# MzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAuoO+BKbfXzqyfi9GLEdWHkCLeT+ggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5oVnUwIhgPMjAyNjEwMDEwMzQ4MDVaGA8yMDI2MTAwMjAzNDgwNVowdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA7mhWdQIBADAKAgEAAgItWQIB/zAHAgEAAgISWTAK
# AgUA7mmn9QIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQBx9oXZLUBatXGg
# oTr4xTHn2L40rw8rULRViDqIH8T+snpCfXo0ZE3+2H33bKfXY2adx/TUOJRxONwK
# 01YIcOxHAfati4hQjz7zh2s4ntPT+rMY7Wa1w789aNNxTLo44fArl409lHruVQM0
# 4PjJbxi5ENiWgGm5lg4RYtwcZSITgQ4LnKtRJ9CrYVrgfvA3i5/arX3h4ESoVt1Y
# e58Sd7OACPZEwabJ2aePQ4qdjNMJ0T9FfiUiE2e9kwo7d0Wa07dgNAokyHK67iMr
# b1e638dYCDyX7zCZwskTBOXb/CdGylHwVzlXHkjSCJea70pdMhYA7t8TNzDzJ0l6
# eGCYI/VbMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIdS8CShziFfjkAAQAAAh0wDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqG
# SIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgWWOkMkt2KAy7
# d1paE+gaKbdT6znvKAIxC3Lsf3dRenkwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHk
# MIG9BCCxtpXMXEiLJzrqM77ep4rTNwrMOj6gpWN9hZvpj5QFUTCBmDCBgKR+MHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACHUvAkoc4hX45AAEAAAId
# MCIEIG/2IoFtn8J4jE6X9M7cwQupAHVBIVcncV1rW+Now4lVMA0GCSqGSIb3DQEB
# CwUABIICACNRDJBTVdLdlw1wep3LfeOhwThQ7XLi6684gJZoVeGRrUX+M3V099nO
# uEGQuZ+ZsMc0LpfHqM/AftOi9HchPLm35kfkONJoiccauL5SbNGnNvXzaiJQ9Ajo
# FV85AYF23ApP9T6ZB4CL8l4V0AsvltTee+mkJIsG/s3G7hox0ThY4ReLxoh9aIRL
# FZgNoTexnnyXyob//diRzKIwG/K3DLkYhWdqmyezPCVFOKQtrplnyErUkDGK9THV
# sTQc5U6X9y4OwHyI2f/6Dd/RGnd/WTmY5Vi1M+tK41I2J5L3ehiymot4d1CTcE+m
# btMq2qU2Vbtk5DQ1kraAkS+dVHex6mpoQkcsOSsatL4DFlbpvTeY0TnYhtnWBzrw
# TftMYEnSisubfP92CvU5a+HZ/XIhrxnYZScVffZlvZeRsr9negOvidJafj3aiUa0
# H5RTIIMCTecw0n0uYBgcniV+nIG1Gc/CRxVUXk55DCVZuki2yD59pwC8taTf+18F
# HXgeGEYvWIptc6GB1Zg7MPyMcriUduJBfk4QG8H549hX5TW9+uruoRK/Vce3jw9i
# 75yVjj9d8XpiX52n3wjlCN4aJMau7gLrzb8pII7VKyLfUWk+DDEPliJXB9dEW3Jl
# V36yygNCQ8IkjXIrQw2/VWgN8dJKCNZuZ20HKRE9uNA5DkCLjLQQ
# SIG # End signature block
