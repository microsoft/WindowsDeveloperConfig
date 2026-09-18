<#
.SYNOPSIS
  Scheduled-task plumbing so the flow can resume elevated after the WSL-required reboot.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigResumeTask = 'WindowsDevConfigResume'

function Clear-DevConfigResume {
    # SilentlyContinue allows cleanup when no resume task is registered.
    Unregister-ScheduledTask -TaskName $Script:DevConfigResumeTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Suspend-DevConfigForReboot {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )

    $shell = Get-DevConfigTaskShellExe
    # The limited task requires fresh UAC consent before any resumed code runs elevated.
    $arguments = (Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed -AllowUnsigned:$Script:DevConfigAllowUnsigned -RequestElevation) -join ' '
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
    Register-ScheduledTask -TaskName $Script:DevConfigResumeTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Save-DevConfigTally -Path (Join-Path (Split-Path -Path $ScriptPath -Parent) 'devconfig-tally.json')

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
# MIInTwYJKoZIhvcNAQcCoIInQDCCJzwCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC44qWjTqo3qshf
# W8XG4W3kxmkVGdLa+ZVx35zGtroM2KCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghncMIIZ2AIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIIZg6QVG1OUivNVZSkHn1QB2GarU
# k6aH1/x1s9udngpNMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAOjdEp7J4LWkVM1EDU4I6Y6uKbOpRiFglHSixY6UVljDeZy26vMOWG9bUVVZA
# IWsFfCnHvtCsXc6Br/kFuJ69RRM7XPu2b0LIM+hfP0fD1GDIAhEVt7s9ct7lOM+B
# oy2bRMd7gnIJ3oY6xG7G6KDBDuqv+7vwRE72tWysEXpYbsZY1EGNUqxz6YwttPPV
# e4jEbwC1sPEgKTcaqN02G2rO0q3qVQNDExHCDDqNdJGFAn3JOktoxy0lh8mzKT6X
# nd1vDgUMLTeCGRKsvpDohr24pRS2O9GWV/A7LioggfIrK4n4U2wpkVECuN/LLhhN
# u4G2WZrFfo8I4kZWLzTpc6bkWaGCF6wwgheoBgorBgEEAYI3AwMBMYIXmDCCF5QG
# CSqGSIb3DQEHAqCCF4UwgheBAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG
# 9w0BCRABBKCCAUgEggFEMIIBQAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAQd0pM2P+Gn7I9nMzN73fPuAF6y8iiM0BzXnPY1YD83wIGaoii8EI/GBIy
# MDI2MDkxODE2MTEzNy4wMVowBIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJE
# MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2
# aWNloIIR+zCCBygwggUQoAMCAQICEzMAAAIS0QgGPMoYT6oAAQAAAhIwDQYJKoZI
# hvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0
# MTg0ODE1WhcNMjYxMTEzMTg0ODE1WjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0
# aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MkQxQS0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCvTNOgOSlZC2xl6RLRxXSq4N0p
# JMaSi+8FpkfQ4AgSLQ7cJw7vsmJfxzgSmr26JsdVlnVb8ui58TXva+RFc75Bg21Z
# aisQInYBxlDXRukCW2SFk2JeVUnwvdDOEqCteuYySbYn7+DzVTbck9w7jBccR+2i
# dPfCl3//3fquObDEybs2RuzKBsl/7gBUEw2vhow9CEF3vqh3QowHpau/IQY45TTz
# 3c4W59LkQN7LifjhaBrEkTRWe/f846+47DkqnUo+qONgn4v3LAu4Ey1wN8uk1A7+
# HV4USgytuIQzrtM582Vd/FsPPgyWxi8uKjGB3ZfN7LVDGtXX6L4nJUMkyJJ72Ao6
# 7OmJBAUTX0NQ+CyJ3KMtPNcSFJUsGVGivR4JV/uALpF+Tw1jes7ayCA4vv29TkW4
# MpOH+wg61xQd4cLjaMEYH6190oLUo4FH5SU31o7ODyalQ0jYWCpC+KtU/2mlt4xR
# ++nbAD2+jJOJFa8ODMLGjzGUnWexxhMchCuaQX2P8JrQgOa3x+86frieeUk4ZRhl
# gcwLWXTG2CRhMTURJSqqRrAqTuKpvF2cvLJxL51H7NrE+50wMutAXPyWB/L2huTQ
# PwcLZ3OFalg2fmF2Sg8TOAKpBQ6ny/dCP+x3hqfK6l7kqgKSMAE4/fKFJDhb1n4O
# smeEz+tuxcLuhO/bpwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFFIFuVLFvlxgpg7C
# 939V+hc5+7feMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBedICSZfv1FzuXFLXA
# 6jNcntXSi7kOe1Vw4mmUiQOO8Q3wEhCmHhT6BI4tm5VF4//P1h1SJSRw/AvU8zbj
# n+QRfUR6CnE1zwcMDqEoIeDQAs0Ry7GcY6WAouiRd9R6vUPmGJbw8AEz1H6d6K15
# OA9ppGUkW8ZNi+i1zS6oaIRLmExCEvxE0WGlL1FwhYe2dAYSet05S8ICGzgV5WJr
# ByYtMq/7XzvRz8x5MeLRAN15H7v9aDiqGQnaTWIQcl2Zh/yshXQ1EFlx1FNN0d57
# flJc/md40J8CSMMi5nJxG53qPM8sI0uI1jMZcGzDMnKCPgR5I5FPvAy9oW4p5EBe
# hcLfDBi+AiwjXOfcMZjrblj7JlKLxQ1I0e6uLfpm/1r5Di8nAOlgrfpLRMHal/vE
# uKIffaeTtgrvdGD3xbp9nYg27NjNnsaGC999+SPgRReDUTQR99jWkSqRukNM/uH8
# MGq3Og9ezLDYxSH7vK9ZyrYEZlK5xroJjpfiKgy5zk9amya846WLsBE0DsBvyQp0
# JzaA0MtpyCWzB5kRz39VAHqGWz9voqTfaeTC4cTEqVp6hJWsoHlT3GWnX5zwn/sY
# mPhHDsCJDy1yn5aZ/IPwrFfZCUpsOLhJSOeCW/jrXtHz5r9wNYnJoy3zbv1aft/b
# Ix503uR8YhDlJmPrpF2F2Vk6rzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# VTNYs6FwZvKhggNWMIICPgIBATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJE
# MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2
# aWNloiMKAQEwBwYFKw4DAhoDFQDlUcGviHTQQ3uNR1DfdIT6puT/wKCBgzCBgKR+
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA
# 7ldfqzAiGA8yMDI2MDkxODA2NTg1MVoYDzIwMjYwOTE5MDY1ODUxWjB0MDoGCisG
# AQQBhFkKBAExLDAqMAoCBQDuV1+rAgEAMAcCAQACAhpbMAcCAQACAhKiMAoCBQDu
# WLErAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMH
# oSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBACxUXGKrgUooOAI25cZo
# ZjT1DokZrzcA7+C3VFcDngbUp8Qs/ynbFLBMVKKElpuGjYWHSPOBKeruE1ZBUy0i
# E//xyo28Lr2EEH9eUZOm5X5QylCb3v2U7D1F+tTJF0q8POjfGUWaRJhvF5O7Zhlc
# 9XcIG5VBfQCMb6jE978B6U8EtJpxosYJ+xMI++W4frenVe4jbrcI6BXP3skh1Bzr
# B37Cd+nPkm7gQLxfNgcqs3ld0b9WW+j30BjF4Qf6h212yuBXoOPQeXfY5+OAHPwP
# qJ9NpXenfAIlJv6h8fC4XppRt/TD3yWyv3t0pDevmTSzKK5DICW5YvHBiBQC4Nwm
# hlQxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAIT
# MwAAAhLRCAY8yhhPqgABAAACEjANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcN
# AQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBI+tSY+pc2Q7ZfId9u
# ksA+YavOZxB3Ha8Qx7YQlg5DtTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0E
# IHP5fka87taeCScfgFl5hT4HMEvUnLmgnzBWVM0jF9iDMIGYMIGApH4wfDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIS0QgGPMoYT6oAAQAAAhIwIgQg
# tsRDU6sq04mrGBnZyv4Y0+3eRfZRnsI64mdFlY98dhAwDQYJKoZIhvcNAQELBQAE
# ggIAXYtEQMFxVeleFlZIG5V33A9xhyjlD7WLssEIprLvqdazZxlCHxmZCakJpLTZ
# Yb5sIDGJjPZyBNH5AI2EhM2UJzVwlpOq0OX/P76mcDFBLbDihrik+W70n6jkX0lv
# hDg6JxZw4fwqspVDAclVV88V/Z7Gc1KdYEGRVnXqsruJWvMo7cwrT1kNhkOBpIyo
# 4kapCpXquSb9wlVwD5mlaqywogKwFZNbXeGRJKYNaGRd1wt6tg0JuYmwHGsJLsc+
# c8NvftJwknfFR8gMm1hzqDFdGVzbFlBNdIR+Qv59+YVz36ZVKf/ndsTlitZqtOqN
# eSi/N3qvO8wXSt+Yh1O6TnF0NKdgNOyUWfC7WdFmeFPu8ESrRcpbkXC170BXHsTx
# hkEhPbcOkqJubW1Gu9yy/LGzY6AKUtDJBRN/hfNL0LseYgTnVVQXfY6PceEf+hDs
# XUcvN+HOFxqTZigKIpUbavaUFYooTl72hopIjExO9Cmjnm/Yf28ZdlZ8b6yJoDRU
# EEn0tNxDICKDJUTzwOUi9eIqbhtbogZaR1cH+OS3j79zrCAD5Vyvu0TQh0qdnDHd
# NtgvkUUXgLryWuaznD/urII19cjzacWaAwDYdQfT1pxy7jUBzvHrHEBHG4T6xgq7
# 1/TQhy/xJcGQnmH67010mEFQrVjG6qTbxyZy+851yEePA8w=
# SIG # End signature block
