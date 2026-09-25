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
$Script:DevConfigAction      = 'Full'
$Script:DevConfigTally       = @{ Done = 0; AlreadyOk = 0; Warned = 0 }
$Script:DevConfigTalliedSteps = @{}
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

# Save progress and Terminal backup tracking across the reboot.
function Save-DevConfigTally {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $TerminalBackedUp = @()
    )
    try {
        $state = [pscustomobject]@{
            Done             = $Script:DevConfigTally.Done
            AlreadyOk        = $Script:DevConfigTally.AlreadyOk
            TalliedSteps     = $Script:DevConfigTalliedSteps
            WarnedSteps      = ($Script:DevConfigWarnedSteps -join ',')
            TerminalBackedUp = @($TerminalBackedUp)
        }
        $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        throw "Could not save setup progress before reboot: $($_.Exception.Message)"
    }
}

# Unknown backup state prevents resumed Terminal changes from overwriting an original.
function Restore-DevConfigTally {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    $Script:DevConfigTerminalBackedUp = $null
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.PSObject.Properties['TerminalBackedUp'] -and $null -ne $saved.TerminalBackedUp) {
            $backupPaths = @($saved.TerminalBackedUp)
            if (@($backupPaths | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
                throw 'The saved Terminal backup paths are invalid.'
            }
            $Script:DevConfigTerminalBackedUp = $backupPaths
        }
        $Script:DevConfigTally.Done      += [int]$saved.Done
        $Script:DevConfigTally.AlreadyOk += [int]$saved.AlreadyOk
        if ($saved.PSObject.Properties['TalliedSteps']) {
            foreach ($property in $saved.TalliedSteps.PSObject.Properties) {
                $Script:DevConfigTalliedSteps[$property.Name] = [string]$property.Value
            }
        }
        if ($saved.WarnedSteps) {
            foreach ($name in ($saved.WarnedSteps -split ',')) {
                if ($Script:DevConfigWarnedSteps -notcontains $name) {
                    $Script:DevConfigWarnedSteps += $name
                }
            }
        }
        $Script:DevConfigTally.Warned = $Script:DevConfigWarnedSteps.Count
    } catch {
        Write-Warning "Could not restore setup progress after reboot: $($_.Exception.Message)"
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
    $previous = $Script:DevConfigTalliedSteps[$Name]
    if ($previous) {
        $Script:DevConfigTally[$previous]--
        $Script:DevConfigTalliedSteps.Remove($Name)
    }
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

function Set-DevConfigStepTally {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Done', 'AlreadyOk')] [string] $State
    )
    $previous = $Script:DevConfigTalliedSteps[$Name]
    if ($previous -eq 'Done' -or $previous -eq $State) {
        return
    }
    if ($previous) {
        $Script:DevConfigTally[$previous]--
    }
    $Script:DevConfigTally[$State]++
    $Script:DevConfigTalliedSteps[$Name] = $State
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
            Set-DevConfigStepTally -Name $step.Name -State AlreadyOk
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
                Set-DevConfigStepTally -Name $step.Name -State Done
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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC033V32RXiiwky
# ApDaR16kGz3HG7v7iUQqAbwFk6YMoqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIJaXNNAaEkJYk+qbrvBXuW06x817
# 9fTdB19kIHbTgf3jMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAJ1kXgCR6qPk4JRERKkOjm+ltFXGIuAgq0JO4BkivE7D1s+6RP6ZZwSFLUkXa
# nMv/NZxTbQbTGbFZhRq8jSzzrt0TNH1uYQRU/SWacxOcSiYeimme0mNH918O8pCR
# G/i2y3XRR2WFXbj/JbmSlN8TIfMy//eiu5EuakZwbJEIwoAn69w+MZktueFJciyD
# dcB2iAiFyxErNgLtR1Y7Rg1eyswLRnn4vJWoqtQFwJiUBdj+VtUuYCRcKzj5drjM
# S5Uceju/8VF6SLa5Lsbx9ncJLuccgz9OV/doxXRAMt1kBHkt79f6KgV/XM/zEfVc
# y1ebZ3RsZydpqyJf7ntOyzTziqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCuil/PdYI3k4sm4nTVkPW0Jm7qZmLtYPfW64vCBzvFBgIGarUjmaxYGBMy
# MDI2MDkyNTIwMzkyNC40MzdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0Uw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAifVwIPDsS5XLQABAAACJzANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDRa
# Fw0yNzA1MTcxOTQwMDRaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0UwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDixWy1fDOSL4qj3A1pady+elIDLwnF3UuLzJIOWwGHcEgr
# xxwtnyviUIDmmxylTUl1u+2rBPp2zT4BwwQhvGaJpExqvPLlDFlbfmSflKI86eFq
# ofiZ7j8NTRO4l7wGg9Njm+muNauTcFW2qdfIjKE950Okrm9MnMOGYy+fibNYdxTP
# RPq1T4MLZK3s3vdMyMEOldcOQkSKpxD6/1Gk6gOmCu2KgI8f0ex6vYxnKDl9W0OL
# SEa/6y82oIbsm+1QBifOQ47xWKTG1CmvtGr85LzA75/MAcUmRw5/of/qET0UFV1W
# ulMcJrI6DASAsNCNB+6WLrotuBZAj+VMlqbn5RMZ6Q4IY7JwaAiIXh7VjxrnwUOY
# ZG8WEGhfrA98di+7LEn9AqvvEOyG+UQcjVhCCbMGXigJXSApeyeWupCsD0jgQMNC
# xfB5BLBDWxgdY3dJBEPgxfkgTDQLBggtVv2d5CYxHKgIItB4bI5eSb5jkIG2Wotn
# FetT0legpw/Eozwf39ao6tENY21eVWIzRw/GsmvwjYQF6vVrxOD0pGVsfqGF8s3V
# PeY7hI2TxHFMqNA0IB/a2NLY7JTxYAKAP/11EJZt7xbqDLMgD1YDdGEzGpQijm3n
# APCL2CebP/jmu90abJ2W425yglGHTI/nCBrwSpfRCgwzrfFelJaCKM6+35aFfwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFNLW58N4MGSG6ud7jWqgT92orfReMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQAqncud4PSC1teb2H6nRuy7sDiKK13FXJirVB4T
# fwjdo2Mb+QL4j7wZ/k4G9P0CANHZFrDQcK0VFDTysrYu8Z0Aha14acDZPsyIoPvA
# GRRhaHEuf7NckRjkfa/ylo1KyII8jbL9N9sJAqBPL8V4FNBjljv+1GHDOw127rZz
# 5ZSTPoAPb2SA0v5yDgcpUMfxglPyp6cnPPoQpTtD9OGx8Dwm2P+o1TPxBIy6I0T9
# RauulogVCvKwflfeLTcKAvnSG1rCjerSXmU1DNXOsAD/bsrSjgbX5mAbD7XTRMF/
# vawAWESFcn/BjjizxeWZb00aYSlkJA2rVtFlMM481aVWXdAbXPP5RzUiWTlgyHf/
# G7lCxHYWGIZuB13T3aI6Y8mEgn/ou40aiFJo8r0+i0P5GdNneWtxiR0CMKUfko+5
# s/73cwe1Wfp8BKXa270cicVQasFf5sRV7pFm+V7fNRXwCu7anTOmga76zO7/2t+z
# OlibvphT+Q6Zd+B2qYsSn4xBaY+YzHpnycLW5cvJyhPxBCcb1oRYfhRzCADb2utI
# 2EtGCjc2P2ii4LyR4QMb/n8cOweL9IqVTKKzzVk+zZJxV3vrp4LyuQXw0O30la6B
# cHdNAAAB9UC83zs3G9d+AlIfZLM97tMUNKWjbBpIirFx6LTDFXVtZQd7hqzLYByj
# bjH0ujCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkE5MzUtMDNFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAjHzqt
# hPwO0GDckDMA6x54lIiMKqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mDzWzAiGA8yMDI2MDkyNTEzMTkyM1oY
# DzIwMjYwOTI2MTMxOTIzWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuYPNbAgEA
# MAcCAQACAgrZMAcCAQACAheeMAoCBQDuYkTbAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBADV0RFIVAjDwQfvIm+CsxfdT4Jf8PRb8WHi7mri/t/XnBpVBFpks
# 3xeuInzbqphpDIIp8GUqePe1FF7cvgP7qkEHV6Xwwh9xZ30vgulAuBTpPpjzArZ4
# uoqO8mhsXD8b5m6XdkzXu49NRY5AopPhJGg2OKcWi1ZBUYyqrdBEX8vEVw6LSyJn
# 0A0i9YXhbfUvkrRDvYYqe0tfgrV5JuEwFiV7hMxWzc3fkb+mSsGthIUHbYxE5jVk
# KbsY/mNKt6aQDFZH8LP3rc52+V//xwYyfw9RUbrzLRTojrIi0jDTKWPWQEVSlwLs
# /55RtvGxuoyuwyF4QVFKInDaaRsYsVcJoFsxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAifVwIPDsS5XLQABAAACJzANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCAENNdrZjfsK2N52Y+KPN6eks4IB50qHcDamjyyVOJYJDCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIOXnARo1oVIcOLJKDqlE0adq/jZ9TXdl
# nXWRcXGThBFyMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIn1cCDw7EuVy0AAQAAAicwIgQgOyvLKWqPz41D5/4e6WOJx4OuTqg4z6lo
# RUJh/PIQuQQwDQYJKoZIhvcNAQELBQAEggIAfy96Hutmw0AY9Epbtytst241gKTI
# T6cr9/Uo8jFB/lJy3m0WSfwmRzHPTigrxohu1jp9721LqqobX9qf439I2slZRsnT
# 179zBuTcBTVWacCX1u1guvdVWI8pJNQG4CTJLcoMlR8tLsdrTwwo8REEMy0hO8xB
# 1VxSlbGK05Md2jUxtM8+pPoE3rzGpogTxqBLZ3JHTCgVc30yCxKnAW2epSji4Dyp
# dwOR5K6JDC+JjGrXPJLc4IqHBp5xu2lfN6XH5tVO+i8WjFswxtyLwmsUN2FfxF9Z
# UvbcYp3UQerlvuaEwweYLZQvQOBqMILE633ykmnmuDwzIEDVB4c9gLRywNE6jYxq
# FMa4lwb5EDMETydPtmYYPRp9duYSuJ3ki60JW4XIUEfhViKo06BJ0gUeCJ4G20Od
# hze4r0/BodQFu6eFy+ghyiobt7H+0ZYFKk6NuIgOf8pyl14JzxpS5vb7fKd1IkMv
# 9iRW+RZFVce1QRUqfV0cfD4WPc7Z8CTpo81VnU5tlluZvTte7rXfbMlNrEcEEhrQ
# Lu8jsDffukr6agkVXH2UgdQ+cgMjuncpcrRbKv9apX1FDGTK45zKlH+gRTac4WZc
# sKhpU7YZXA9O9kfZotwJgDIwRqSsItP4zcPHqfcMTML/AJumK2FSpy/Fm/LNShCp
# cl1Qjcy3j/SoH/Y=
# SIG # End signature block
