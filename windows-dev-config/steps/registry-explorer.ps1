<#
.SYNOPSIS
  File Explorer and Desktop registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Reset-DevConfigExplorerDisplay {
    param(
        [switch] $CheckOnly
    )
    if (-not ('DevConfigExplorerSettings' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DevConfigExplorerSettings
{
    [StructLayout(LayoutKind.Sequential)]
    public struct CabinetState
    {
        public ushort Length;
        public ushort Version;
        public uint Flags;
        public uint MenuEnumFilter;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ShellState
    {
        public uint Flags1;
        public uint Win95Unused;
        public uint Win95Unused2;
        public int SortParameter;
        public int SortDirection;
        public uint Version;
        public uint NotUsed;
        public uint Flags2;
    }

    [DllImport("shell32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadCabinetState(ref CabinetState state, int length);

    [DllImport("shell32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteCabinetState(ref CabinetState state);

    [DllImport("shell32.dll", ExactSpelling = true)]
    public static extern void SHGetSetSettings(
        ref ShellState state, uint mask, [MarshalAs(UnmanagedType.Bool)] bool set);
}
'@
    }

    $fullPathTitleMask = [uint32]1
    $fileVisibilityMask = [uint32]3
    $cabinet = [DevConfigExplorerSettings+CabinetState]::new()
    $cabinet.Length = [Runtime.InteropServices.Marshal]::SizeOf([type][DevConfigExplorerSettings+CabinetState])
    # A false result supplies defaults when no cabinet settings have been saved.
    [void][DevConfigExplorerSettings]::ReadCabinetState([ref]$cabinet, $cabinet.Length)

    $shell = [DevConfigExplorerSettings+ShellState]::new()
    # The mask covers hidden files and file extensions, not other Explorer preferences.
    [DevConfigExplorerSettings]::SHGetSetSettings([ref]$shell, $fileVisibilityMask, $false)
    if ($CheckOnly) {
        return ($cabinet.Flags -band $fullPathTitleMask) -eq 0 -and
            ($shell.Flags1 -band $fileVisibilityMask) -eq 0
    }

    $cabinet.Flags = $cabinet.Flags -band (-bnot $fullPathTitleMask)
    if (-not [DevConfigExplorerSettings]::WriteCabinetState([ref]$cabinet)) {
        throw 'Could not reset the Explorer cabinet settings.'
    }
    $shell.Flags1 = $shell.Flags1 -band (-bnot $fileVisibilityMask)
    [DevConfigExplorerSettings]::SHGetSetSettings([ref]$shell, $fileVisibilityMask, $true)
}

function Invoke-RegistryExplorerPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $explorer = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    $cabinet = "$explorer\CabinetState"

    $tweaks = @(
        @{
            Name        = 'ShowFileExtensions'
            KeyPath     = $advanced
            ValueName   = 'HideFileExt'
            Value       = 0
            ResetValue  = 1
            Description = 'Show file extensions in Explorer'
        }
        @{
            Name        = 'ShowHiddenFiles'
            KeyPath     = $advanced
            ValueName   = 'Hidden'
            Value       = 1
            ResetValue  = 2
            Description = 'Show hidden files in Explorer'
        }
        @{
            Name        = 'FullPathTitlebar'
            KeyPath     = $cabinet
            ValueName   = 'FullPath'
            Value       = 1
            ResetValue  = 0
            Description = 'Show full path in Explorer titlebar'
        }
        @{
            Name        = 'OpenThisPC'
            KeyPath     = $advanced
            ValueName   = 'LaunchTo'
            Value       = 1
            Description = 'Open File Explorer to This PC'
        }
        @{
            Name        = 'FrequentFolders'
            KeyPath     = $explorer
            ValueName   = 'ShowFrequent'
            Value       = 0
            Description = 'Disable frequent folders in Quick Access'
        }
        @{
            Name        = 'FrequentFiles'
            KeyPath     = $explorer
            ValueName   = 'ShowRecent'
            Value       = 0
            Description = 'Disable frequent files in Quick Access'
        }
        @{
            Name        = 'RecommendedFiles'
            KeyPath     = $explorer
            ValueName   = 'ShowCloudFilesInQuickAccess'
            Value       = 0
            Description = 'Disable recommended/cloud files in Quick Access'
        }
        @{
            Name        = 'TipsOff'
            KeyPath     = $advanced
            ValueName   = 'ShowSyncProviderNotifications'
            Value       = 0
            Description = 'Disable sync provider notifications (tips)'
        }
        @{
            Name        = 'DetailsContainer'
            KeyPath     = "$explorer\Modules\GlobalSettings\DetailsContainer"
            ValueName   = 'DetailsContainer'
            Value       = [byte[]](0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00)
            Type        = 'Binary'
            Description = 'Configure Explorer Details pane state'
        }
    )

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -ne 'RecommendedFiles' })
    }

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak -Reset:($Script:DevConfigAction -eq 'Uninstall')
    }
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps += New-DevConfigStep -Name 'ExplorerDisplayReset' -Description 'Reset hidden files, file extensions, and full-path titles' -BestEffort `
            -Check { Reset-DevConfigExplorerDisplay -CheckOnly } `
            -Apply { Reset-DevConfigExplorerDisplay }
    }

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCM5HY2nzm/+sUt
# JMfDht5obfO2BeV9E3JhFCcN9vtiLqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIMA/xIJJas8GWmBqwZ5jWBrA/71fSqzb1nQWcM1tHQrdMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAMW50UVvrqTuOuTzD
# 628IBIFZC09ZckPSpuO23PdXnjGHHdHeyo+qa2LORHxSLnquRphaGaXWFS/AR5Pe
# LAA1XTWc/ZWAxzfIl05jaXFLLtEZvU2MxhlKCRkq2eD9QuM9XjjmAxuyVEXa5Ce8
# gOvSdgCQgol/vX7HgdLKedFj0T41CPrZf+yqL0ppnfa81zidxdQyCAV9hw/OJJ7R
# WTkm2NHpeALGoJA7c1oHukKOgXpneh7BcYnyfZ3erUBZ2kwMbqoS37KqH0pMXfej
# g438w4qaKzpA9dIMUFkLj0nOi4/v5LSvI0VoX6a/dpBcoVYH2GAffvClDPeAqzkd
# prtTI6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCGUGKlLfk+IrO8
# YVS8iKP22yiTsHHSTgDKlOuy8nQtpwIGaq3I5+QDGBMyMDI2MTAwODAzMDIwNS43
# NDJaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACEtEIBjzKGE+qAAEAAAISMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxNVoXDTI2MTEx
# MzE4NDgxNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAr0zToDkpWQtsZekS0cV0quDdKSTGkovvBaZH0OAIEi0O
# 3CcO77JiX8c4Epq9uibHVZZ1W/LoufE172vkRXO+QYNtWWorECJ2AcZQ10bpAltk
# hZNiXlVJ8L3QzhKgrXrmMkm2J+/g81U23JPcO4wXHEftonT3wpd//936rjmwxMm7
# NkbsygbJf+4AVBMNr4aMPQhBd76od0KMB6WrvyEGOOU0893OFufS5EDey4n44Wga
# xJE0Vnv3/OOvuOw5Kp1KPqjjYJ+L9ywLuBMtcDfLpNQO/h1eFEoMrbiEM67TOfNl
# XfxbDz4MlsYvLioxgd2Xzey1QxrV1+i+JyVDJMiSe9gKOuzpiQQFE19DUPgsidyj
# LTzXEhSVLBlRor0eCVf7gC6Rfk8NY3rO2sggOL79vU5FuDKTh/sIOtcUHeHC42jB
# GB+tfdKC1KOBR+UlN9aOzg8mpUNI2FgqQvirVP9ppbeMUfvp2wA9voyTiRWvDgzC
# xo8xlJ1nscYTHIQrmkF9j/Ca0IDmt8fvOn64nnlJOGUYZYHMC1l0xtgkYTE1ESUq
# qkawKk7iqbxdnLyycS+dR+zaxPudMDLrQFz8lgfy9obk0D8HC2dzhWpYNn5hdkoP
# EzgCqQUOp8v3Qj/sd4anyupe5KoCkjABOP3yhSQ4W9Z+DrJnhM/rbsXC7oTv26cC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRSBblSxb5cYKYOwvd/VfoXOfu33jAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAXnSAkmX79Rc7lxS1wOozXJ7V0ou5DntVcOJp
# lIkDjvEN8BIQph4U+gSOLZuVReP/z9YdUiUkcPwL1PM245/kEX1EegpxNc8HDA6h
# KCHg0ALNEcuxnGOlgKLokXfUer1D5hiW8PABM9R+neiteTgPaaRlJFvGTYvotc0u
# qGiES5hMQhL8RNFhpS9RcIWHtnQGEnrdOUvCAhs4FeViawcmLTKv+1870c/MeTHi
# 0QDdeR+7/Wg4qhkJ2k1iEHJdmYf8rIV0NRBZcdRTTdHee35SXP5neNCfAkjDIuZy
# cRud6jzPLCNLiNYzGXBswzJygj4EeSORT7wMvaFuKeRAXoXC3wwYvgIsI1zn3DGY
# 625Y+yZSi8UNSNHuri36Zv9a+Q4vJwDpYK36S0TB2pf7xLiiH32nk7YK73Rg98W6
# fZ2INuzYzZ7Ghgvfffkj4EUXg1E0EffY1pEqkbpDTP7h/DBqtzoPXsyw2MUh+7yv
# Wcq2BGZSuca6CY6X4ioMuc5PWpsmvOOli7ARNA7Ab8kKdCc2gNDLacglsweZEc9/
# VQB6hls/b6Kk32nkwuHExKlaeoSVrKB5U9xlp1+c8J/7GJj4Rw7AiQ8tcp+WmfyD
# 8KxX2QlKbDi4SUjnglv4617R8+a/cDWJyaMt8279Wn7f2yMedN7kfGIQ5SZj66Rd
# hdlZOq8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUA5VHBr4h00EN7jUdQ33SE+qbk/8CggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5xUcwwIhgPMjAyNjEw
# MDcyMzE4MzZaGA8yMDI2MTAwODIzMTgzNlowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7nFRzAIBADAHAgEAAgISdjAHAgEAAgIUVjAKAgUA7nKjTAIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQA32otfXh8AZPh/EltDe8LDcmRyWw2oZjAF6Kn5
# u1e/y/Vkl01NrngOzxkn8NlSZ0RnQRUQi+RG+slsxuDfCwDA9VVSybvtB2vnFruP
# PXAWWW7fY6bLULnMQ8FZeVVZm8rxjJ/KPXVQmfybyZsdmaJoeYd+ofvusamMmXxT
# LvE76umnFNktl1Lv74Lig8GzX/rLw2M79FzBEQX13glFl2K//8uL0DPNbMKMrCAn
# Z8tgZrfp/mquhs6KpOBfnPz4l03xVL5nxpADvasmsWHsiyDdFerEvxMzEFzW1kyM
# ec30XzXdK17g4QcETM0Rah7GfDupo1sgo/bYsaHzNwX04QB1MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIS0QgGPMoYT6oA
# AQAAAhIwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgQFUIt2K/9oLO+ibv47dS+ow55LUqvUZp3SjA
# O2i05oQwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBz+X5GvO7WngknH4BZ
# eYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIEIHZszfzpe6OhWEZWJlp2
# mgxv/+xEVeNC5fNKOQGdzb0CMA0GCSqGSIb3DQEBCwUABIICAKCcEnoKACtAAKGs
# RMUU+UNtzEm/bMmrgRkd0u/n/0vcNn8YogCCI/BprB9gLQbUFx5xBK8dDtW2IIRT
# a45s3+hpoZVkWBImaxexY+ynAtooRb6cdxPAEADARBhin78oAf1Gkv8skk1QpXH2
# 7qEd3Z6+hImpAz8imaaTg2az1buyP1VoYKFAhhGHPYgcPnd9DuRqt+4tXr6VYtZJ
# S0SkLU8SD/NGluMB2qp1zkK4jE17w4IyDXi5+AK3PQexEIYEZd0MYk+Tsnc6LdSu
# nWsWpyphTv/jwSqbVwzObWCVPwaguG/i7k+6Y92yOqvc9dfAcJDsYdjPu9dTMjVU
# TbeTIvLChn1hbUnG++DCyITGJPYnom3M4HRAeeMhZa5F+cBp9dunDxcJhTVstHyd
# rc7azV1JeFE0/+7l4wEdpIyPITYUY53RgB0wlSiI41jqeXhKdAWvY/mkMyJqfHba
# 0odtsCz892amoWlBzemK23PacwTG/fFKUmyRakuRaR9YomgW++zK+heTL/4srjEd
# MVuDxjLco7J+3+BfNQEys3hdER6YT9pzbLDoYRnabq3wLFkzkyhEnMAv7exgoPWU
# JUXHT9gFFvebhlW9P0mNhnkk4OQgJXzz0GcFESpaJORBuMCiJ03xAwtMZCoPfdGX
# GN0ESAZeHsrmYznEgYeluLGNhI6M
# SIG # End signature block
