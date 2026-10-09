<#
.SYNOPSIS
  Scheduled-task plumbing so the flow can resume elevated after the WSL-required reboot.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Each workload has its own task so one workload's run never cancels another's pending resume.
function Get-DevConfigResumeTaskName {
    if ($Script:DevConfigWorkload -eq 'devconfig') {
        return 'WindowsDevConfigResume'
    }
    return "WindowsDevConfigResume-$Script:DevConfigWorkload"
}

function Clear-DevConfigResume {
    # SilentlyContinue allows cleanup when no resume task is registered.
    Unregister-ScheduledTask -TaskName (Get-DevConfigResumeTaskName) -Confirm:$false -ErrorAction SilentlyContinue
}

function Suspend-DevConfigForReboot {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )

    $shell = Get-DevConfigTaskShellExe
    # The limited task requires fresh UAC consent before any resumed code runs elevated.
    $arguments = (Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed -AllowUnsigned:$Script:DevConfigAllowUnsigned -RequestElevation -Action $Script:DevConfigAction -Workload $Script:DevConfigWorkload) -join ' '
    $action = New-ScheduledTaskAction -Execute $shell -Argument $arguments

    # Scheduled task logon matching requires the DOMAIN\User or MACHINE\User account name.
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger     = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal   = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

    # A short delay lets desktop and network initialization complete before package checks resume.
    try {
        $trigger.Delay = 'PT30S'
    } catch {
        Write-Verbose "Could not delay the resume trigger: $($_.Exception.Message)"
    }

    Clear-DevConfigResume
    Save-DevConfigTally -Path (Get-DevConfigTallyPath -Directory (Split-Path -Path $ScriptPath -Parent)) `
        -TerminalBackedUp $Script:DevConfigTerminalBackedUp
    Register-ScheduledTask -TaskName (Get-DevConfigResumeTaskName) -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-Host ''
    Write-Host 'WSL needs a restart to finish. Rebooting in 10s -- setup continues after you' -ForegroundColor Yellow
    Write-Host 'log back in and accept one more UAC prompt. This is expected, not an error.' -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    # The resume task is already registered, so a manual restart continues from the same point.
    # shutdown.exe is used instead of Restart-Computer because the latter goes through WMI even
    # for the local machine, and that call can time out and report failure mid-restart.
    $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $result   = Invoke-DevConfigNativeCommand -FilePath $shutdown -Arguments @('/r', '/t', '0', '/f')

    # 1115 means a restart is already under way, which is the outcome this wants either way.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1115) {
        Write-Host ''
        Write-Host "Windows would not let setup restart this machine (shutdown.exe returned $($result.ExitCode))." -ForegroundColor Yellow
        Write-Host 'Restart when convenient -- setup carries on by itself once you log back in.' -ForegroundColor Yellow
        # Keep the window open so the remaining manual restart instruction is visible.
        Wait-DevConfigKeyPress
        exit 0
    }

    # The restart request returns straight away, so pause before any fall-through code.
    Start-Sleep -Seconds 60
    exit 0
}

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCGhd82K3xUChEV
# Is/Cd52A+9XppD6ds2COUrKGzKLMDqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIBcjMI2RrElXRGDWCm2DPxASvYn4eDTlRaQ5aV1x3WLvMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAEhgjFldrJoFC45O9
# lewFKW+5lx2DA5PjfQrmZZTOiL1Ii2WEIH0RokUC2zMg50Xr2O1iKzwAhkFeZW7s
# MlVZpWj1xW4VgIGsbJ7snc2wHMUEUhg0Pa8bQzxOh28qFTIrEIVCoqsrgVfdp+5Q
# 08SWi+Qg4y4q4q0k0CCz8HOZGjqWADjJKtJPgZpn9hHzFIdZxwyqODTWTBJgUCEO
# xADOhg1Id1ULxxBPL83whUlXwUkwZ7UNG4s6DmCQPkgqeh44UT8PynxoUYWUQypd
# 2ZKgAiQHOufODJIcI4M/wzTlfidEUTRFs+4Z7cltpMx2TJ/9a3QD7OPaPfUsmDRT
# ZUV2vqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBsHoWTvmq3IN1Z
# jrP2PVo+JxLZgVqun0EdOcWVShYjpAIGaqk4vu+DGBMyMDI2MTAwOTAwMTkzMC42
# NzhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAijwpYfX88geQAABAAACKDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDZaFw0yNzA1MTcxOTQwMDZa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# jvbk/sqcCSReZaJfCuf1NwRcc7XknhE6wkLofkNj1mxEAg35qy2xcFjgjartVvA0
# 9W8QHcpyMqVSXOTxNHJsmk0qP2CDLvUAulWg7aS5oBORpEX1oz3n0R2nPqeH0IHK
# 1zJxjxaHW21AbuZ0Z+wM3WYNzkBlcHmVe03ZG7rlk28h72r5P5ME8FGpFmYW5Hl7
# psKbgLEfrYAitpttsb+sZsBUI+hMKl4uLJYotKyZv1ewOIinBfRU8QosivjofaBe
# zUf9NdV+iGrWh321WnSsK3A/Jl6GLtbSWXcJWULgbxuqnobPK+YlB3174TMWTgX4
# YWjG7o0Otz/pjHNCKBbB788dynhLdGY6B08E9+4SGrRpsty4iJHOydHCA5M4i5yY
# Rwsdut+gmvxIpT8yNXJcjJCg0vO8mv/nFY9Wytv2qmCtCFFivGUWqU20/sUeRooQ
# ZGiQOJQn095Cj3isIsvRP8KU7hN/EDI8HVsb/NPzMFLvRznrRnj0TOnDiOTUcnYw
# mk+XfoS1owskcCCCwHnbC00D58z83y7K5ZJB745hcn4CE2nR3e6RGsr42y5qtt6M
# dz/s7MTnDS2UmVHWX1X/HZe3UlX8gj/t63L50xIPqkRCBEdM1ADNUaSfo9OQiKb/
# bj1diZCGTfEDUBBLop1mhkwIF82faplV2busZ+U4kQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFKrJpYz48tzouvVkBVthASFpQ93DMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCQ6NfLmrRahgVtgWg383GaS07fHyod6bhcUONt2tet+6BaNuH0r7ABkVHh
# eOpxBdrUrOEYVEaIii9dK3cuZLNmp1iUAx/VbmOZYl7xz+tNrjCWqrg1jQmq0oRB
# 8iE4QJpwNhGP67oY5huYIU0D4lhDoahqfgKJn/0Bk+9UKDPw5XlUYmreFmJlj9YQ
# zcPPep8MxBXxh/Y5I7vQeRaW5SjtiLQOLRk3ggvraDs5Sf49MJV6/BwxXC2rvUfE
# FX6SUDooqKIE9NgVIRq0RZu7Ot0i0Is+HvPP0hB6KwOxMg1SWKOfTtFpWpdo8MJv
# gKCHkPpXEzgprP+pyIHuO7gVRlSTsbYBFLh2yId/itM4uYL0R+2SSBBTpSSRthrG
# uEmElI5BCHMxzMg/oqHSPwZAIAkM2C4xxi0St7qMuA+m+ZzFYkfoF41QoSJn+Hjq
# hqWYQ0m/SO9/KnJRJJUwMd5TiMnjZ+E/DJiUry5udiWyQpvfj2hQFI0djhahoAXD
# azeEciLF2uEnTur9UfjcwOun/oMY+ULftnOi2jKLMrreV097akzz/JxpnDgYJU/t
# gU7fQflg7IqiL9+0276+joQHo21mVeY5YD8Kh/kUaY6Jm/OTM88G7evTz/qnRumx
# ovTjMStvpbAHNRhmSTdIPTV32CyuxDKS/V5a5iwA+f9ViBo+wjCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB1rbmFkzS7qAK1Oav08AUnhbNI
# UqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nKuzzAiGA8yMDI2MTAwOTAwMDc0M1oYDzIwMjYxMDEwMDAwNzQz
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucq7PAgEAMAcCAQACAgsMMAcCAQAC
# AhQcMAoCBQDudABPAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAB+KoPZx
# 1P82QS66mTTm/ngumgJATaB26jqzMviOQLwnH2WgoCHPaw0nAHVACY7SMzgxLEqC
# enrBiebzLVs0fg8+xwnwjcrJmEAyXRJyqu+0+Zef+rcE+7AbBVLoa7KH1E+2XCRu
# PxorQ2a3SHG4L64yFh4LcCKvmcsDb7cGdUXZKfp9jxnULDf6H9VHoKDTye+BYm7i
# cCXYtOEX5YLFDN08DSsFy8xuoXrjuyM4vNbGtQ+q5j31gHeIPimsQp9mzlQBIZbY
# OiYjN2Nzwv72usCxkbuSH76ovjgwn620UACJwn4/xufYZiGohlvUQc1qyn8Hj8Oa
# xHNsqo+2V5TdFm4xggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCEmG9A
# cp/Y10OZtytzBlR0+Q63sUAnyX/NN++/TyH0CjCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIFWxikZRYGNf4oEVZK1eT45H+3GQ3/qxV75VwuBt+iLXMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIo8KWH1/PIHkAA
# AQAAAigwIgQghef/+fMEtvDCDwHcD9od3pRlQmfSrDvOKmAllfDV7rswDQYJKoZI
# hvcNAQELBQAEggIANnnhXGLfVeZQ19as0aWgef5C+dXTriO0DWJv3qjNRmLAQN8J
# CHCC9w6dmr0vfxlvoQ2hyb7htAOdexjI23HRpvU1j3gR7tCSHpQxh0fVK2IErSHl
# QqnS2b7riQVszlRT2IvrwbwBXWWmjyVZdqkDUU3DHiC9tfpwgvOTMrsSiuZ927cS
# X+O8tyi2FwlhD2F0HNsaFUMU52NfUdv4UGmu59n19osTBM2oH9BHrhZK3UK0Ke6W
# bYQwEudYfupGazaea6IZD8WKwY7S/V+TX3mutAYWzmTff/MEp9st+WJWQ5tv3CZG
# 36Kknad+NIvi/xW4c0O8dx+HddpoyIFahulusSmSVTq2h52WnAzSW1/kfWmN82ye
# Zz/EsY9m/VpbQy1hH4iR813miYeRr4mPIF1Z/WD9UF1j94VpNT99Wp8qf6DbkM4u
# T00HiH0pVqvA76y5sGMSfY3/vk9MJwHIHHIl2h6Go0Q7kGZAI/rwbdgA8HoH2VlK
# a2vHnUnkGJVORFAXiS7NCedXKVbewX/msQh3uu7CXgaUYSvA2iaV+fbVH/FzF/F/
# NtJVQEPA8pwNJeV+zZinrLxpEYvPdHWesUkRgmkTS0Vw0X0FYWMOIrMJh+t6mVB9
# rlSed6y3UjFk6s4tptfQcNs6sPVJ5aAv7wXuK5LjQd868mXfj+mVo8eF9nE=
# SIG # End signature block
