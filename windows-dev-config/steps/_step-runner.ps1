<#
.SYNOPSIS
  Runs named setup steps, applying only the steps that are not already complete.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# [char] avoids a literal multi-byte glyph that Windows PowerShell 5.1 can misread without a BOM.
$Script:DevConfigCheckMark = [char]0x2713

# Defaults allow the step runner to load before the orchestrator sets run state.
$Script:DevConfigResumed     = $false
$Script:DevConfigTally       = @{ Done = 0; AlreadyOk = 0; Warned = 0 }
# Persist flagged names so a blocked step is counted once across the reboot.
$Script:DevConfigWarnedSteps      = @()
$Script:DevConfigSilentSkips      = 0
$Script:DevConfigStepUnverified   = $null
$Script:DevConfigPhaseIndex       = 0
$Script:DevConfigPhaseTotal       = 0
$Script:DevConfigPhaseTitle       = ''
$Script:DevConfigPhaseHeaderShown = $false

function Write-DevConfigPhaseHeader {
    param(
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [string] $Title
    )
    Write-Host ''
    Write-Host "Phase $Index/$Total -- $Title" -ForegroundColor Cyan
}

# The guard lets phases print early without a duplicate header.
function Show-DevConfigPhaseHeader {
    if ($Script:DevConfigPhaseHeaderShown -or -not $Script:DevConfigPhaseTitle) {
        return
    }
    Write-DevConfigPhaseHeader -Index $Script:DevConfigPhaseIndex -Total $Script:DevConfigPhaseTotal -Title $Script:DevConfigPhaseTitle
    $Script:DevConfigPhaseHeaderShown = $true
}

# Save the tally across the reboot so the final summary covers the whole run.
function Save-DevConfigTally {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    try {
        $state = [pscustomobject]@{
            Done        = $Script:DevConfigTally.Done
            AlreadyOk   = $Script:DevConfigTally.AlreadyOk
            WarnedSteps = ($Script:DevConfigWarnedSteps -join ',')
        }
        $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-Verbose "Could not save the tally before reboot: $($_.Exception.Message)"
    }
}

# Best-effort restore: a missing or unreadable file limits the summary to this process.
function Restore-DevConfigTally {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $Script:DevConfigTally.Done      += [int]$saved.Done
        $Script:DevConfigTally.AlreadyOk += [int]$saved.AlreadyOk
        if ($saved.WarnedSteps) {
            foreach ($name in ($saved.WarnedSteps -split ',')) {
                if ($Script:DevConfigWarnedSteps -notcontains $name) {
                    $Script:DevConfigWarnedSteps += $name
                }
            }
        }
        $Script:DevConfigTally.Warned = $Script:DevConfigWarnedSteps.Count
    } catch {
        Write-Verbose "Could not restore the pre-reboot tally: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    }
}

# Flush silent-skip counts before later output so the summary stays in context.
function Show-DevConfigSilentSkipSummary {
    if ($Script:DevConfigSilentSkips -gt 0) {
        Write-Host ''
        Write-Host "Re-checked $($Script:DevConfigSilentSkips) earlier steps -- all already OK." -ForegroundColor DarkGray
        $Script:DevConfigSilentSkips = 0
    }
}

function New-DevConfigStep {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Check,
        [Parameter(Mandatory)] [scriptblock] $Apply,
        [string] $Description = '',
        [object[]] $ArgumentList = @(),
        [switch] $BestEffort
    )
    # ArgumentList is passed positionally at call time, not captured by closure.
    [pscustomobject]@{
        Name         = $Name
        Description  = $Description
        Check        = $Check
        Apply        = $Apply
        ArgumentList = $ArgumentList
        BestEffort   = [bool]$BestEffort
    }
}

# Deduplicate flags and keep them on the main stream so resume output shows them immediately.
function Write-DevConfigStepFlag {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Message
    )
    if ($Script:DevConfigWarnedSteps -notcontains $Name) {
        $Script:DevConfigWarnedSteps += $Name
    }
    $Script:DevConfigTally.Warned = $Script:DevConfigWarnedSteps.Count
    Write-Host "  ! $Label flagged" -ForegroundColor Yellow
    Write-Host "    $Message" -ForegroundColor Yellow
}

# Drop a flag once the step verifies, so a pre-reboot warning does not outlive the problem.
function Clear-DevConfigStepFlag {
    param(
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Script:DevConfigWarnedSteps -notcontains $Name) {
        return
    }
    $Script:DevConfigWarnedSteps = @($Script:DevConfigWarnedSteps | Where-Object { $_ -ne $Name })
    $Script:DevConfigTally.Warned = $Script:DevConfigWarnedSteps.Count
}

# Allows unverified work to be flagged without failing the run when confirmation lags the apply action.
function Set-DevConfigStepUnverified {
    param(
        [Parameter(Mandatory)] [string] $Reason
    )
    $Script:DevConfigStepUnverified = $Reason
}

function Invoke-DevConfigSteps {
    param(
        [Parameter(Mandatory)] [object[]] $Steps
    )

    # Fresh runs print before slow checks so the console shows why it is waiting.
    if (-not $Script:DevConfigResumed) {
        Show-DevConfigPhaseHeader
        Write-Host "  Checking what's already set up..." -ForegroundColor DarkGray
    }

    # Checks run before output so no-op resumed phases collapse; @() preserves StrictMode array behavior.
    $checked = @(foreach ($step in $Steps) {
        $alreadyDone = $false
        try {
            # Splat (@) needs a plain variable, not a property-access expression.
            $stepArgs = $step.ArgumentList
            $alreadyDone = [bool](& $step.Check @stepArgs)
        } catch {
            Write-Host "  ? $($step.Name): couldn't tell whether this was already done ($($_.Exception.Message)); doing it anyway." -ForegroundColor DarkYellow
        }
        # Tally before printing so collapsed phases still count.
        if ($alreadyDone) {
            $Script:DevConfigTally.AlreadyOk++
            # Clearing here also covers resumed phases that return before the reporting loop.
            Clear-DevConfigStepFlag -Name $step.Name
        }
        [pscustomobject]@{ Step = $step; AlreadyDone = $alreadyDone }
    })

    # After a reboot, collapse a fully no-op phase into a running count instead of repeating every step.
    $allAlreadyOk = -not ($checked | Where-Object { -not $_.AlreadyDone })
    if ($Script:DevConfigResumed -and $allAlreadyOk) {
        $Script:DevConfigSilentSkips += $checked.Count
        return
    }

    Show-DevConfigSilentSkipSummary
    Show-DevConfigPhaseHeader

    foreach ($item in $checked) {
        $step     = $item.Step
        $stepArgs = $step.ArgumentList
        $label    = $step.Name.PadRight(22)

        if ($item.AlreadyDone) {
            Write-Host "  $Script:DevConfigCheckMark $label already OK" -ForegroundColor DarkGray
            continue
        }

        # Print before slow apply work so the console shows current progress.
        $what = if ($step.Description) { $step.Description } else { $step.Name }
        Write-Host "  -> $what..." -ForegroundColor DarkCyan

        # BestEffort steps flag and continue instead of blocking the whole run.
        $Script:DevConfigStepUnverified = $null
        try {
            & $step.Apply @stepArgs
            if ($Script:DevConfigStepUnverified) {
                Write-DevConfigStepFlag -Name $step.Name -Label $label -Message $Script:DevConfigStepUnverified
            } elseif (-not [bool](& $step.Check @stepArgs)) {
                throw "ran, but the follow-up check still says it isn't done."
            } else {
                $Script:DevConfigTally.Done++
                Clear-DevConfigStepFlag -Name $step.Name
                Write-Host "  $Script:DevConfigCheckMark $label done" -ForegroundColor Green
            }
        } catch {
            if ($step.BestEffort) {
                Write-DevConfigStepFlag -Name $step.Name -Label $label -Message "$($_.Exception.Message) (best-effort step, continuing)"
            } else {
                throw
            }
        }
    }
}

# SIG # Begin signature block
# MIInKgYJKoZIhvcNAQcCoIInGzCCJxcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC+3FUqEM8qbIxU
# /P9juPVoApUC8/5T0AByZnP5B7vrMaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnGMIIZwgIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIPUigDBs4gqwhnZux8fjlLx1Vi8lMav26UnGMmaT1tmOMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAVR5MDWtGh8o+cWZ5
# H8X7GTs5RqVE8+kszRkF0BESt6jT21+CCqbYFOJKnuD5xubRVmw0LMt23R32pbck
# vZWmldtOUUVzG6n4yo5qnOHVDb5lBDAfPPmvVCldvrMrouT0S90qUkKFAkVxlj8O
# EcHqof4p7JTYnNthuPnbOe7++LrCjpjGrPvW4b9GbVbAL6eId+EgY81BDeergCNN
# ZF7JQAzugMOOvE7aBsgVqeTkpT3BbPBwMKZpqA4KVFsLuTnX8SzDn8Z+MEoi+6ul
# m0fs2jmhDKdfzE0xOeaBubfMafQPl6CGPp41JfN0WsYVm1Ci5rufKgXOISkdaOhR
# owIaqKGCF5YwgheSBgorBgEEAYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28w
# ghdrAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBy/YyuWPPEPO2R
# s1pB2Nm3qu4a/Ul8WzlLn3vX5KQOVAIGaqnOA/PRGBMyMDI2MDkxODA1MjEyNi43
# NjdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHsMIIHIDCCBQigAwIBAgIT
# MwAAAiQ7hCGwLKxkIgABAAACJDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTla
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj
# 6W3UaQ2Zr4hNvSy7j7UMPFVys7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrL
# QCOZcgLvz6FkqmghzQxzmkgKtLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcV
# iBX4LcHk38RusZiF7wxSa5t/Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9
# pU9uriGdDxfJXn/lc49CxbXqA3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfd
# rA29sWTSNKig9CtBC5tzQj0flbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjl
# yUP9ZO38839NwSuiHtvsFCNkTNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PD
# ERyrAs0pvfUWOLapVQajHPoCnuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8W
# wBtk3Yxyhjj0GXw909i0EkTkVyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1Y
# GnYwCjIwa5/lMW0pFn/HpJdB6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v
# 3E9kwN9VBC+wJESBECC1gZMCS5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3
# SNt0a0Q5Nc2Ul+rMlQxXoP9isXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFHMfkX1u/zJLCMe0gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA+wHSbmhIpM8CRVZ4tk624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko
# 6diEDHXPNWvAagxastCewPzm5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/
# Fwps1sbNUEu7Bzg004qULIVJ963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQT
# HZgwuNB6QhcEEsgogLVwNRj37VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi
# 6jlcfqfo619uDH9r8k2qAOHCeEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilU
# Son07wjHu0e0ssBmtBafPb4Gd+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oc
# zxC/4JT3Hf45JEtszToXwNskV3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGE
# lPl5GRoPtJiDEvRIbv5MFKIw2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOk
# X4ug0/0mN2CSarhuSi9NmHIOpUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1o
# bjAGKdWMPCrlSyNAs0jZYzkha535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbU
# VqMU1OrQbHfdyzJpbhJC1PbAZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMC
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNPMIICNwIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+
# 46CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7lbvIjAiGA8yMDI2MDkxNzIyNTg0MloYDzIwMjYwOTE4MjI1ODQy
# WjB2MDwGCisGAQQBhFkKBAExLjAsMAoCBQDuVu8iAgEAMAkCAQACAScCAf8wBwIB
# AAICEoIwCgIFAO5YQKICAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoD
# AqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAHiB4
# RYrtHGc0G+E6Gm/Mguty0IIhJoqDMoKCl9b1C0Y4eU9hgXKvXCjp3vpOHWtiQijj
# ygN6o63zwr0MJwb5cQtH3k4LUttxZ/TfPDZ+fZIWTwh/5SgIvGRJwnAAhr7NZw5w
# DoLIApRJjxr/dSi9zLD/CLxMtlXhBrln5n/vpqJA4UuPv4LPBWO88yBC9gyXJ6Zz
# KYFviIhyD9juoY6uqS1nPUJTQdCVESmD6nJQTuFw6HK/vNr7Uk78BkKSRyqmQbVv
# hIU2vmhzpjEtOOsqtuS8h4Gr4IKh55INCNWjuIGleARjkl1DDvZVuJxyoVx7WdrN
# J8grcXYgObDWV7DtZzGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACJDuEIbAsrGQiAAEAAAIkMA0GCWCGSAFlAwQCAQUAoIIB
# SjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIL+7
# DGSBh+MLQbxfCPCuHThhPR1tQpZMW4fXngVdyxi3MIH6BgsqhkiG9w0BCRACLzGB
# 6jCB5zCB5DCBvQQgSCE9N2qb91HJnQFzNdx2WhUSogJ1yalU1sf0IRXNZI4wgZgw
# gYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiQ7hCGwLKxk
# IgABAAACJDAiBCAEZqlFDBXYxiALjPl3roket0WrE/q9s2gkg+g3tS+S0TANBgkq
# hkiG9w0BAQsFAASCAgBDZGhWeeYGcICKt/Lq7zPnwsBa7DxqpIX51HvWxFQ43dMS
# 0MJqpiMqit+t96eP1txVG+2ieNXksQ0GIOjZI53m8q0/t+esHp7d07QrbxcbWkyB
# s2Jf4Inayqe+l/BUorkcLX+iaY/A0Gm1YI/38rs4VXRjbKAN6WF7HFO0UrO79acY
# eX1xdzEAlwBcF5MsDtE7j3kmhr06VDkuCzehMH8CpJPZktpwl4rxZBy+2yiws42D
# 7J8nlPbzv5mBlQR01OcAIYR/f4uwmvvrR485NdkyRoT3jzYuBbA34eUIEPK4pUO3
# BzWdPIGtiwIU96IfAnVxRpasbGmu+kRWMwCKrD5aPxhCVFkSS0a3zTpsv8MJuxnk
# aHZZ11viK44i4WZ2c1vTu2q7nFm3sE53Gy/1qrvo0INpt66I/yZ2x97WmZjSyRhI
# L+P7QPoPYtRfqlg2EIYgex4CSkadzvvQYcEuhWqMRTyGrmoe73ADVw8xO+g+reFY
# 8hL6Pwd/6VnIQligpdZF9gONkVzDHKC/whrubRwtv24Qo2CBnIalgsUN6tpdz+SY
# gE/EtVtNKk8nEIvQ3t44T57CrSc9TQAN9A0RY7mCCZZIFYMPCSoZgjUu3TKu6O/U
# jmabqDVQKLeb+fIZHw5oGaDRLTradnhsSXrT2C0tiRpbIg7IdWcoYeioRhbxKw==
# SIG # End signature block
