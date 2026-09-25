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
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCJpZE9z1aUcDne
# 8qm486fYBIHmo2n/tHOpKMgLT6k1haCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEICzfBFlb9T/9Ak+weDjj8PObYGnzYrPhBNjRj0hg0EpAMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAQ43KTNBRu4JRDNzD
# ZaA22yK0TDwHcxkxJpBMibQnzzXn0tV0AKLCA3ikb3pTGv/8z/AE6utnYC8CuxWG
# mtrOtFgKpfopxEZOzPIYC+ip3KHNjodV77lkptedx6CFtarQKfuTQ8Xv4LrmZzOn
# 8Z615xpOzZ1FWIu4AeL1vq3aSTShYGh9S0hTXdqNhxh6r89AvzWUSa4gu82LLcPi
# 5Bd8l1E1gAvnSjYYMUz50vCjsWPkMlU09SmHa7u7jQG/RxzSp2LfsvnZ2Jnt1RvT
# wNDc9GIoPW4oNmZgebLGxLIf6bw8+OYgJGV4Wx5WRj3L8uA+pCoCJfDfYNuC9qlx
# 6gnVpKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCC5r1j1e08jBrMJ
# OjBAfO9i9llESII435bisAyrnPIOzQIGaq1sum97GBMyMDI2MDkyNTAwMjIxOC4w
# NTdaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACE7BDNWbPr5XoAAEAAAITMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxN1oXDTI2MTEx
# MzE4NDgxN1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjM2MDUtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA9Jl64LoZxDINSFgz+9KS5Ozv5m548ePVzc9RXWe4T4/M
# plfga4eq12RGdp5cVvnjde5vxfq2ax/jnu7vUW4rZN4mOUm5vh+kcYsQlYQ53Fwg
# IB3nEjcQHomrG3mZe/ozjFSAr6JbglKtIeAySPzAcFzyAer5lLNUHBEvQMM8BOjM
# yapCvh0xsg4xKFcVEJQLKEfCGBffMZI/amutHFb3CUTZ7aVpG2KHEFUNlZ1vwMKv
# xXTPRDnbwPGzyyqJJznfsLNHQ4vXt2ttS1PeCoGI0hN1Peq8yGsIXM9oocwC06DG
# NSM/4LAx2uKvwmUn6NwLc0+tmvny6w28rZLejskRfnVWofEv1mWY0jHUnHrwSGBS
# 8gVP9gcBs6P5g0OpJPMfxdUkHXRkcMPPW0hIP8NbW8W5Sup8HuwnSKbjpyAlGBUd
# M/V5rZb0sZmkn714r6ULGK+cLLAN6R3FhX6N0nj64F27LTK2BbS0pJZaXjo0eDNz
# 1QcxeIFLUgF+RBsLYDn8E8cCkexK8Nlt3Gi9zJf55w6UfTZ+kwTMxMqFxh7+Tfx7
# +aBObZ+nx961AtiqAy7zVV69o/LWRdKPZdvZn9ESyGbTnPfjkBERv22prSlETlRw
# zP6bmEVOKWLWVwxuwh7bUWUuUb1cj93zvttQYGQat5E9ALLJNmlvLKCskB7raLsC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBQTnhBKx+FryphQWMRipH49sMFAOjAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAgmxaJrGqQ2D6UJhZ6Ql2SZFOaNuGbW3LzB+E
# S+l2BB1MJtBRSFdi/hVY33NpxsJQhQ5TLVp0DXYOkIoPQc17rH+IVhemO8jCt+U6
# I1TIw6cR7c+tEo/Jjp6EqEU1c4/mraMjgHhQ+raC/OUAm98A1r4bIPHtsBmLROGm
# eE5XLIFaBIZWHvh2COXITKObXVd5wGtJ1dZZdwaHACXF506jta+uoUdyzAeuNlTP
# LTrZ8nyhxGwk9Vh6eiDQ7CQMWSSa8DJS9PUXjeoi9vTdS7ZMXqu+tv6Qz3xtoBF5
# +YFK4uE+miGs90Fxm0VK2lWrmFhjkRl5zyoHOdwG7spNYkDomCPNWIudUQmQYKpt
# /Hsspfcb+xpnWIDQdMzgE8pj1vpwLgWEnH7LtT4dZCeoDo9PK40RxBD8kKJ769ng
# kEwfwCD2EX/MQk79eIvOhpnH12GuVByvaKZk5XZvqtPONNwr8q/qA3877IuWwWgn
# aeX+prpw0dZ/QLtbGGVrgP+TRQjt+2dcZA5P3X4LwANhiPsy0Ol4XCdj7OxBLFvO
# zsCPDPaVnkp+dfDFG+NOBir7aqTJ68622pymg1V+6gc/1RvxC/wgvYyG033ecJqv
# 0On0ZRNYr+i/OkwgA3HP1aLD0aHrEpw6lt0263iRkCvrcdcOW8w3jC8TJuaGWyC2
# S9jEjzgwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAmBE8SCjxgjacmy8/VEdk7NxpR6aggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5f05gwIhgPMjAyNjA5
# MjQxNjUxMzZaGA8yMDI2MDkyNTE2NTEzNlowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7l/TmAIBADAHAgEAAgIT1jAHAgEAAgIVXDAKAgUA7mElGAIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAHWhnfg1aZ3ixocNhooCIht2xa0Q+1dMRe6oIV
# Jt9DDKysSUD4S6wSxB+DBubijc8IeLEksq0BOdlQ7AG7MBvf7/IlMutA3iikCRFe
# gyAFzDJkhh9ocq+A8c0BJDn+omYjS/c646jCwU/7HBF3XErnnDlHCt+ztZNsruFG
# AueFs4HdirqGUUh2gpKWjU7P7U1Zaapepu83dOZGUgInE/OjbH6Y4nin8RixGnkN
# R9zkAOnDUWLO/kExXvKwbUSwml7LSaeVIrAc5gNI4KbuTg63PY5LN2uV9ytCpAbc
# zpnJIgLAqsUZ6ZelkLhjhG0CEEN+ss/wRNbViRPA1I4t6W4nMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAITsEM1Zs+vlegA
# AQAAAhMwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgzUROkvhCGV18aqTtQxD0hB541M2txzgUPBFt
# pC/byfkwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDM4QltFIUz8J4DjAzP
# 4nVodZvQxYGleUIfp86Oa5xYaDCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACE7BDNWbPr5XoAAEAAAITMCIEIKhj+dozvyy+c4QBibbh
# cFxIMFISOfoOLum9KPC4v5kFMA0GCSqGSIb3DQEBCwUABIICAJSs0folA9mYFdpJ
# ODY1/OTb2XWtpKu1VpXSku6PrtHyqcCKzj/3VfMFWTBqDN+jY6M10d/6rIEb76pk
# yUVod1DMzyxOfgaJBDmHUc7fyoGd5lFInmD5ZPFiLFTTB8Cu+wqOu7drDz9GY/6y
# 7KGudDXwWQ/mGlBAIk1LErV2y8IbDPN9Bwi+wz8vZMSKjSFytUmFl02TZMdn4+/7
# oyGD1HvYslAHbBRxpqZr3n5Kz6u5BNEA7XK1OWKdSgJHcNKzYS4otd7cbob/mGpL
# TeYhSQpHRCS6gsKooVquFMnHJ/Uo4f9xOZ08gYZQi0OMYI7zofoMENHUVvfLehgN
# YvX4ohoORRfyZ/SEWQ6pMr9qvo/ysc2dTKwRbbzoAazyGvAiSqW+WozEkFbKARFp
# j5EqI1emavyvEJ9KPYX3Vju2pmDrQqTTUbscg5G3pN0o/+91UUL+v8fVfT4ez9wC
# 3k1ji7Zz6+/AuwjJM59uulDdco6GXm/iaZUU/TOM4P6D9AYVnfmjhGQ2+S1SL8E5
# GQpqYZ5wDGqCu3MrMU+vgd1zFXnEfXlRiu3uWLHmYhU7k4n3lkVtL4fC0w4llT2o
# xB4moHwdhU92AaoV1Z0EUACBH0YXNayKtK1Yi6mqQq7/MjzdNROFKEw+U5mXrsjQ
# QvnmZqQ3jHUOO0My43juSasH6Jox
# SIG # End signature block
