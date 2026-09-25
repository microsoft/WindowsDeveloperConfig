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
# MIInOQYJKoZIhvcNAQcCoIInKjCCJyYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCM5HY2nzm/+sUt
# JMfDht5obfO2BeV9E3JhFCcN9vtiLqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnGMIIZwgIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIMA/xIJJas8GWmBqwZ5jWBrA/71f
# Sqzb1nQWcM1tHQrdMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAxx91rh469Vgtlp2/H6ZNrvtKsW4nSI+4RTgBCMhNs26rX0hHg9ThS562l3y/
# CbMhGYbleg7Ils5O5jYnFXiKmv1JPaxgfD93XTcXdho6nM6RbZIjbt6Sie0I38SO
# HV0YtOEfzAwXXm442XFvgAu/QRWCIp+ducrwvHSrmBX+arcPVViY7sbngYcMsSiD
# KXVXw5U8ZN3IL/MGFklHMhA/040ej6MeYr6sLOBb14IzTfoWi7ymrMSnu0+EN9Mv
# gvsCM8M251duxbBV6URc+193GymhmSvRGnx5XBbUn9ATQBjPzidFz2rni6f61U81
# mbSJi7gbplaEyBzNnIX0EsgeaqGCF5YwgheSBgorBgEEAYI3AwMBMYIXgjCCF34G
# CSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG
# 9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAP/vHgkfSF3Wfl9Y1Ok+Knu6inTFDtLwFTqpv59Ax0WAIGaqrDkkT2GBIy
# MDI2MDkyNTIwMzkyNS43MVowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMzAzLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEe0w
# ggcgMIIFCKADAgECAhMzAAACITPANfvSDyGkAAEAAAIhMA0GCSqGSIb3DQEBCwUA
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5Mzk1NFoX
# DTI3MDUxNzE5Mzk1NFowgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMzAzLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBANtxMAKpTVi9GhzJYvY8v1/J//5QuzaortTVpmxGcNlKeUKv
# sruOADd4UIQkvkFnt1RMLQN5l6l/5kL7scRsHgh3OYl9ABQMUV6upjlVMeZC8/Zc
# DeVZIWPvjSJ1wZQeCU/kf89sIlTsYAdY/Yd1wKN3HWVgCjQD7MsjvHCdNB4zI5df
# bXYSDhSYM88mDF1MzDpYVVawE9ZEGLmAOLHLaz7tHwAOTmVsEEUMHmHQKOs1Yg3u
# 4IDMXmDu2usvydcgqnXSaP1HGFwZD62WG3pUi93KBFVNQZ3MUHb+cG8mpD2THEWW
# 1BJPvR8R3HhPJoqjD9/n4FKHjPj/1/s1chVVMuf/yRwkB9GoWZGusW3cgpvLtWvO
# Zi6hBYPSWY0W0ZDnsGsmQ+s8UA96TUAu1xtvsUfedCm+LyeDP8wVf/5yeY0VYVTb
# 1VUubMH1e8tnFti+R5623SaHmV+1543asTBTKt2sq5/P2HZLqltq174LaHTYKtfB
# KRrTHp7OlOYaQgksW3bm5v9Rhc0t0d2zEYPoR9yQ4igliybgxL0X+9Kos0crz0jS
# 9MsGeBASnosgWQg1qdFPc+03Hek0pEolEAtzovqaFbiEvhocvvj2o99Dva3moAyb
# nGIpgyAnZZqeJ1Es24jbnUkg3utpp4D/a9vRcWRlwhtNHWl9AaxyjhTSDm2PAgMB
# AAGjggFJMIIBRTAdBgNVHQ4EFgQU5iMizmprql+6q4/LIrUVOvlAMKcwHwYDVR0j
# BBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggr
# BgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0T
# AQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4Aw
# DQYJKoZIhvcNAQELBQADggIBADgj/duR2dPEPasW6bcwXzFUp0SSiEA5tt4+tD7R
# +vltGKaPP2xWQpP/uByPg4xwKVJgb4h1foyncRiwsdZ+O/B/MWh5kT7JNt0GP/VU
# dlBG4KbDpCp5UJNvDaedLucHGdZ32hlds9SmoRrAfkOpdBpYWBH0DgpZUr8i9dUM
# yPU+U8IRLU/cmic1t2GSSTPj2sm4o6blvt78EfyWioCZc5dFzbbLFZVMxasSnimy
# Wa/x5PtWhjxf+N0phM9URex+YttUVyrMy4Hy8UZ9TJaxZE5LzCCruVBh9ZxiqHs3
# KagBNf7BZgrfNYbtpFyI8ZQDPOdd1/5oe0hadAs1rkcWZJeSJqTd9K6mtZhmIeG5
# iMTXqGugClwEemb7xL+Q2qGb1aNBf7YHGdi/4l6PLqWpOLx8sEtLTr1ZdXD+m1/k
# hX4W1iXfga9Wh6DfVShSZVVl7VINQmSb10NdzyX+oENiIAhPYIKw9PK31cD0lW4f
# F0/refsKG9YA7/jtBG4IOxSUUmhbDIHCXuN5ilpFUy1C3SK4kwYaOARolfVD/aPy
# xdRG9Nx4scMP2Kla3T3ZkNYxByINGaEc0U5fV2eMG+T+TVQxyD33uPmhjOcCdKkm
# +WD/gE/dpUTSH9gfYqCwptTg1dkcCMlePZKWqjULXXkIbqoFloWQzxbq89kKbmqd
# J7M6MIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0B
# AQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAG
# A1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAw
# HhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOTh
# pkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xP
# x2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ
# 3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOt
# gFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYt
# cI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXA
# hjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0S
# idb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSC
# D/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEB
# c8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh
# 8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8Fdsa
# N8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkr
# BgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q
# /y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBR
# BgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsG
# AQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAP
# BgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjE
# MFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kv
# Y3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEF
# BQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEB
# CwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnX
# wnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOw
# Bb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jf
# ZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ
# 5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+
# ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgs
# sU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6
# OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p
# /cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6
# TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784
# cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA1AwggI4
# AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAAtsSBlm
# fJgdcnUMZvl8aOmVem25oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTAwDQYJKoZIhvcNAQELBQACBQDuYR4dMCIYDzIwMjYwOTI1MTYyMTQ5WhgP
# MjAyNjA5MjYxNjIxNDlaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAO5hHh0CAQAw
# CgIBAAICDfsCAf8wBwIBAAICFJIwCgIFAO5ib50CAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEActrUi4Y9oem3lPoqhVlIytxiCoCvKq13V2oNG6vBFUEAA70u
# GDLF3pWY3L+uWEjMyjTiY3K76F1bH+TNmk+98B8pen+vzmsPr4aBfAUF9oJVklJ/
# JirZo8Yl8wzPPDdqaTK+AF18XdUvrCow7fWtvqgf0QJEkkp9al0tdk7MQ/RF3lLz
# e4zJHqsPra8O2WQ2yW7zi6qYqvGkEm0SDXkIh6XYRP4sz0eaOUXHz6dvhztbwdK7
# d0XzQNCu5p63amR0iW/NfxeE7soEqG4VGCp+SEosCzuBjL7P/u2K7D3ZSrzwzdzI
# T5jkuld7IVyR/Ox71tLSWAIVJ3jcqSB6mToYbDGCBA0wggQJAgEBMIGTMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACITPANfvSDyGkAAEAAAIhMA0G
# CWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJ
# KoZIhvcNAQkEMSIEIAppYrUJ+B7QEOZ+uYUv5sCi2hWHDgd4Cfah48u2B/f3MIH6
# BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgAO8hB58VVRrgEnLwhnLAwC+YZIp1
# RWoSbL0D748KPUQwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MAITMwAAAiEzwDX70g8hpAABAAACITAiBCAy9lauaxuCaF0EmYr0vwvkmXteY69d
# feEGysfQd01mdTANBgkqhkiG9w0BAQsFAASCAgCd7c9z+pJBcYevyZDJKz5MG+Cj
# SiukfJAzOKBsWGzze25+wT8n9Pc87Yao4eeLh1FGHfZlGeIbvHqBiAnkHZJmwt/1
# h0IfnNAADCl7mpfBhoILKgweW/jKnZdJ8eIlNngA+gJe2IClx6wpRXuRQ583+pnU
# akfSh20xLu0pfMFGVnZsnt6EYyE8wFrL1ABW0XDu0L79gHRmfY6wr3fFper4rDN/
# 4ksvHNEfKQXPCVPpQHg3Bwne7aM3vDUgNqgjutTiGZnr2cL7eDgOUSaSdBY29v+o
# rRIzyvjCn6/thU5rWd5uwYS4zrHxBrpEW4yngIYubMki7CBXdDcCKIMw0rwaKvJt
# Xbt5Jn6oQNRaIV+Hhpt60c3k5XuqdR7dEWdPzyI/jQw4ZkO9TAVgStdUUIQhRL6i
# 3zqZIpkUiUCZNo2qPwP3YkZravSM4ol5S4ooAkjVq/TiyqasO9dlu62jhE9pEfLo
# 8QpnD77W6u9WKlH4IItRUCNHacU4Igyin0qnLCqDKpCKaCB6xfe4K+er3IegOB7r
# vodd4rdDCATLRxGNLT28fcBvLU/pkrYr0OfOn+KQCMpPpCgN4HnitE7w2k7NjbyY
# yiKyCSFB0xGE1VqtEdUMBb0ApNB0zXhrhHIN51xodz2ZXRCUVm4EUUhvF8eHLLJk
# a3dcOrVTwXfz1+L1Hw==
# SIG # End signature block
