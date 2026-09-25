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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
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
# mbSJi7gbplaEyBzNnIX0EsgeaqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAP/vHgkfSF3Wfl9Y1Ok+Knu6inTFDtLwFTqpv59Ax0WAIGaqk2lymiGBMy
# MDI2MDkyNTIyNDc1Ni45OTZaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAijwpYfX88geQAABAAACKDANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDZa
# Fw0yNzA1MTcxOTQwMDZaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCujvbk/sqcCSReZaJfCuf1NwRcc7XknhE6wkLofkNj1mxE
# Ag35qy2xcFjgjartVvA09W8QHcpyMqVSXOTxNHJsmk0qP2CDLvUAulWg7aS5oBOR
# pEX1oz3n0R2nPqeH0IHK1zJxjxaHW21AbuZ0Z+wM3WYNzkBlcHmVe03ZG7rlk28h
# 72r5P5ME8FGpFmYW5Hl7psKbgLEfrYAitpttsb+sZsBUI+hMKl4uLJYotKyZv1ew
# OIinBfRU8QosivjofaBezUf9NdV+iGrWh321WnSsK3A/Jl6GLtbSWXcJWULgbxuq
# nobPK+YlB3174TMWTgX4YWjG7o0Otz/pjHNCKBbB788dynhLdGY6B08E9+4SGrRp
# sty4iJHOydHCA5M4i5yYRwsdut+gmvxIpT8yNXJcjJCg0vO8mv/nFY9Wytv2qmCt
# CFFivGUWqU20/sUeRooQZGiQOJQn095Cj3isIsvRP8KU7hN/EDI8HVsb/NPzMFLv
# RznrRnj0TOnDiOTUcnYwmk+XfoS1owskcCCCwHnbC00D58z83y7K5ZJB745hcn4C
# E2nR3e6RGsr42y5qtt6Mdz/s7MTnDS2UmVHWX1X/HZe3UlX8gj/t63L50xIPqkRC
# BEdM1ADNUaSfo9OQiKb/bj1diZCGTfEDUBBLop1mhkwIF82faplV2busZ+U4kQID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFKrJpYz48tzouvVkBVthASFpQ93DMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCQ6NfLmrRahgVtgWg383GaS07fHyod6bhcUONt
# 2tet+6BaNuH0r7ABkVHheOpxBdrUrOEYVEaIii9dK3cuZLNmp1iUAx/VbmOZYl7x
# z+tNrjCWqrg1jQmq0oRB8iE4QJpwNhGP67oY5huYIU0D4lhDoahqfgKJn/0Bk+9U
# KDPw5XlUYmreFmJlj9YQzcPPep8MxBXxh/Y5I7vQeRaW5SjtiLQOLRk3ggvraDs5
# Sf49MJV6/BwxXC2rvUfEFX6SUDooqKIE9NgVIRq0RZu7Ot0i0Is+HvPP0hB6KwOx
# Mg1SWKOfTtFpWpdo8MJvgKCHkPpXEzgprP+pyIHuO7gVRlSTsbYBFLh2yId/itM4
# uYL0R+2SSBBTpSSRthrGuEmElI5BCHMxzMg/oqHSPwZAIAkM2C4xxi0St7qMuA+m
# +ZzFYkfoF41QoSJn+HjqhqWYQ0m/SO9/KnJRJJUwMd5TiMnjZ+E/DJiUry5udiWy
# Qpvfj2hQFI0djhahoAXDazeEciLF2uEnTur9UfjcwOun/oMY+ULftnOi2jKLMrre
# V097akzz/JxpnDgYJU/tgU7fQflg7IqiL9+0276+joQHo21mVeY5YD8Kh/kUaY6J
# m/OTM88G7evTz/qnRumxovTjMStvpbAHNRhmSTdIPTV32CyuxDKS/V5a5iwA+f9V
# iBo+wjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB1rbmF
# kzS7qAK1Oav08AUnhbNIUqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mDijzAiGA8yMDI2MDkyNTEyMDc0M1oY
# DzIwMjYwOTI2MTIwNzQzWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuYOKPAgEA
# MAcCAQACAh6YMAcCAQACAhM1MAoCBQDuYjQPAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAEMxfTJ6zXrH16RbbBk+rENVGF+IAK6yFJj2BjqMV3qDu3quTWAm
# 9lscZRqFDcsWCA9AyngboGB5jq9luuppbEcRrvJ18JLvhuRbgdQi+qJpxzH48my2
# pStSQpW+rLtibEZ6L6lI/gT743XIgNUHZVKwxXQwDiyvRyoSpL7fX54J/hVihPgZ
# CLJGhlbDHsGtgcT956RgESTd5rM1dGM/nuI/5hu7hYI8dXmpz7LvFq8StTQCXI9A
# c8SG606fRtsWH6U+fbtzam0jL+LJ3Jtho2KU1KaM+dV/as+cILq0XBOop09gs3zV
# McfADOH0eBkb08pQNmnlus4gGuzZqyHpu8cxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCD+KUgkMlLdb94qJqNBYjLZSJX3Lq4+LQY6cxxYziArKzCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFWxikZRYGNf4oEVZK1eT45H+3GQ3/qx
# V75VwuBt+iLXMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIo8KWH1/PIHkAAAQAAAigwIgQgS+LgbdGA/A/cKxqxfSYVSWDAhZ41ENI8
# FpNSvr8vquMwDQYJKoZIhvcNAQELBQAEggIALtFApn6D3ccLEMJ78lDAkXDAQRzy
# Zfxuxbbh8jCjOoLuvbYzml4qf8i6ft2Nc+CXqgrZY58emo3nP+FOsMhc69IDXMeD
# gDIya1nLHgAMbdy/X70bYhfBOC+cYznU8B8aHmTcfWjWt7TrdTg0RFw2VdDZ/63X
# cW0EdtV6ACeHbHrrSuuwcbC8KLxsHcIwklC13RSi3x3wZOdG0BW5eg/lGFvTdb8f
# kvZgzQZfCEn0jOsuhPTV/dmjVWkAnKrMxjSY4mXNtzmGaXQx5a1APXXvmIRwHp+V
# 7LKT9OW9nUwAH4nHItYXiNSOLuYESY0kQySXWuTuggrv86uYN1igg+SIupKVuR9t
# /yBwCpAwWpHXN8/IKUBz32CY/Oz/hTrpvDB+C0I5/oSbaZL3ioQ2oPzvLzOzO0Ml
# b0vJceFdxuGzq9bLRO7qkl1XTqwsumPzLJQZvyzfmceYdYsQygcKRGDrtjOm8Ggj
# uPOZk3Umkqogte/3h2vNpJWVqn9e6WTeP3LwfHg0tmuuYBB1WZ707YyGirVnOEdA
# 5qpJq4zRN2ewHrBgQ7FHKwUevFMyp0+UqgyPKUjn/ZhVQknYCMJjLViih9VBUG2+
# vVKKpaagu0ZkYx2NtG9DkKOYLnn+ePpU+m/iuGeGNMdFndsMfHc/ogHSRWIL5Lvp
# nGt8KdT21emz0D4=
# SIG # End signature block
