<#
.SYNOPSIS
  Handles elevation, relaunch arguments, and the single-run guard.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigRunMutex = $null

# The mutex prevents concurrent machine-wide WinGet and registry changes from overlapping.
function Enter-DevConfigSingleInstance {
    $mutex = [System.Threading.Mutex]::new($false, 'Global\WindowsDevConfigSetup')
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # An abandoned mutex grants ownership to this process.
        $acquired = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        return $false
    }

    $Script:DevConfigRunMutex = $mutex
    return $true
}

# Release the mutex before the final pause so a completed run does not block the next start.
function Exit-DevConfigSingleInstance {
    if (-not $Script:DevConfigRunMutex) {
        return
    }
    try {
        $Script:DevConfigRunMutex.ReleaseMutex()
    } catch {
        Write-Verbose "The run lock was already released: $($_.Exception.Message)"
    }
    $Script:DevConfigRunMutex.Dispose()
    $Script:DevConfigRunMutex = $null
}

function Test-DevConfigIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-DevConfigUnelevatedCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 900
    )
    if (-not (Test-DevConfigIsAdmin)) {
        return Invoke-DevConfigNativeCommand -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    }

    $taskName = 'WindowsDevConfigUserCommand-' + [guid]::NewGuid().ToString('N')
    $outputPath = [IO.Path]::GetTempFileName()
    $registered = $false
    try {
        $fileLiteral = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($FilePath)
        $outputLiteral = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($outputPath)
        $argumentLiterals = @($Arguments | ForEach-Object {
            "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($_) + "'"
        })
        $nativeHelper = ${function:Invoke-DevConfigNativeCommand}.ToString()
        $command = @"
function Invoke-DevConfigNativeCommand { $nativeHelper }
try {
    `$result = Invoke-DevConfigNativeCommand -FilePath '$fileLiteral' -Arguments @($($argumentLiterals -join ', ')) -TimeoutSeconds $TimeoutSeconds
    [IO.File]::WriteAllText('$outputLiteral', `$result.Output)
    if (`$null -eq `$result.ExitCode) { exit 1 }
    exit `$result.ExitCode
} catch {
    [IO.File]::WriteAllText('$outputLiteral', `$_.Exception.Message)
    if (`$_.Exception -is [TimeoutException]) { exit 258 }
    exit 1
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $shell -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 60)) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        $registered = $true
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextProgress = 60
        $hasStarted = $false
        Start-ScheduledTask -TaskName $taskName
        do {
            Start-Sleep -Milliseconds 500
            $task = Get-ScheduledTask -TaskName $taskName
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            # A new task reports 0x41303 until its first run.
            $hasStarted = $hasStarted -or $task.State -eq 'Running' -or $info.LastTaskResult -ne 0x41303
            if (-not $hasStarted -and $timer.Elapsed.TotalSeconds -ge 30) {
                throw 'Per-user cleanup could not start. Sign in with the account running this script and retry.'
            }
            if ($timer.Elapsed.TotalSeconds -ge ($TimeoutSeconds + 30)) {
                throw "The per-user command timed out: $FilePath $($Arguments -join ' ')."
            }
            if ($timer.Elapsed.TotalSeconds -ge $nextProgress) {
                Write-Host "  still working -- $([int]$timer.Elapsed.TotalMinutes)m so far" -ForegroundColor DarkGray
                $nextProgress += 60
            }
        } while (-not $hasStarted -or $task.State -in @('Running', 'Queued'))

        $exitCode = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$info.LastTaskResult), 0)
        if ($exitCode -eq 258) {
            throw "The per-user command timed out: $FilePath $($Arguments -join ' ')."
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = [IO.File]::ReadAllText($outputPath) }
    } finally {
        if ($registered) {
            if ((Get-ScheduledTask -TaskName $taskName).State -in @('Running', 'Queued')) {
                Stop-ScheduledTask -TaskName $taskName
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }
        Remove-Item -LiteralPath $outputPath -Force
    }
}

function Get-DevConfigShellExe {
    # Prefer pwsh when it is on PATH; Windows PowerShell 5.1 is always available as fallback.
    if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
}

function Get-DevConfigTaskShellExe {
    # Scheduled tasks cannot launch the WindowsApps execution alias that a Store-installed
    # PowerShell 7 leaves on PATH, so resolve to a real file under a machine-wide path.
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    # Windows PowerShell always exists at this fixed path, and these steps run on 5.1.
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# Quote the script path because Start-Process joins arguments with spaces without adding quotes.
function Get-DevConfigRelaunchArguments {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $Resumed,
        [switch] $AllowUnsigned,
        [switch] $RequestElevation,
        [switch] $ApplyTerminalFont,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
    )
    $arguments = @('-NoProfile')
    if (-not $AllowUnsigned) {
        $arguments += '-ExecutionPolicy', 'RemoteSigned'
    }
    $arguments += '-File', "`"$ScriptPath`""
    if ($ApplyTerminalFont) {
        $arguments += '-ApplyTerminalFont'
    } else {
        $arguments += '-Action', $Action
        # The default workload is omitted so these command lines match releases that predate workloads.
        if ($Workload -ne 'devconfig') {
            $arguments += '-Workload', $Workload
        }
        if (-not $RequestElevation) {
            $arguments += '-NoElevate'
        }
        if ($Resumed) {
            $arguments += '-Resumed'
        }
    }
    if ($AllowUnsigned) {
        $arguments += '-AllowUnsigned'
    }
    return $arguments
}

function Invoke-DevConfigElevate {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $NoElevate,
        [switch] $Resumed,
        [switch] $AllowUnsigned,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
    )

    if (Test-DevConfigIsAdmin) {
        return
    }

    if ($NoElevate) {
        throw 'Not running as Administrator and -NoElevate was passed; re-launch from an elevated shell.'
    }

    Write-Host 'This needs to run elevated once (a UAC prompt will appear)...' -ForegroundColor Yellow

    $shell = if ($Action -eq 'Uninstall') {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        Get-DevConfigShellExe
    }
    # Preserve -Resumed so the elevated process continues after the WSL reboot.
    $relaunchArgs = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload
    try {
        $proc = Start-Process -FilePath $shell -ArgumentList $relaunchArgs -Verb RunAs -Wait -PassThru
    } catch {
        # A declined UAC prompt returns here; pause so Explorer-launched users can read the reason.
        Write-Host ''
        Write-Host 'Setup needs Administrator rights to continue, so nothing was changed.' -ForegroundColor Yellow
        Write-Host 'Run it again and accept the prompt, or start it from an elevated terminal.' -ForegroundColor Yellow
        Wait-DevConfigKeyPress
        exit 1
    }

    # The elevated relaunch did the work, so this process reports its exit code.
    exit $proc.ExitCode
}

# SIG # Begin signature block
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBU5Mt3f9ClBMYb
# p+hiqYDyHsuQGWhh0k6eQoyxo6P1w6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIMemhwUcKyuqxmXdFMifrm5Zrv96hlMsuUYBAhkZ7YkDMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAVFO3upI945+HoRVQ
# 0Q9R/o1CD/eJHQ+IGM49iWca2XZKPu0Y2e1O1npeEmhc2EzezM/DQNCqZdX/s17E
# C+/ZHAxKuWVdYoe3kq4/29em7YC3lgs/n9dlW7ZqUUj7UhzfijPZ+ZeGmR4Q+orx
# /VWwVCkuRe12xXpkJ6oiJP/ea7jfZ9ivyG2WHVv3IdoAdGH47ig6ucjgqlspxHpW
# LoyxqcQo6Cwr5BVpijMtuMAxBeRVmnLegl5wVL6Ye24yZCeXalyM5M4RjLabBjBI
# yPHySenxi3/9va+vhI0VeN1e9F25wrsYzu/DOIUQSoqR53b1rcwWRcm8sD/cdKmi
# VT2pTKGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kw
# gheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCA1zYMEi6GvtdSG
# Krhi4Sewt5hCdNJ3WE7DNyde1C+sawIGaq45HUIVGBMyMDI2MTAwNzAwMjgxNy4y
# MTdaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0MDFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIF
# EKADAgECAhMzAAACGV6y2FR19LGNAAEAAAIZMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyNloXDTI2MTEx
# MzE4NDgyNlowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQwMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEApqFIyUkzIyxpL3Q03WmLuy4G9YIUScznhKr+cHOT+/u7
# ParxI96gxxb1WrWuAxB8qjGLfsbImx8V3ouK1nUcf+R/nsnXas5/iTgV/Tl3QTRG
# T0DeuXBNbpHqc+wC1NiTyA76gLnirvSBEoBzlrpNQFEnuwdbPLCLpTS3KWSCu5J0
# 2b+RFWR/kcFzVxnhoE3gIaeURtrGKGBZGKLBXvqggkDENtKkvtvRT32xLvAvL/Rp
# Reu5z18ZojCs72ZSoa74Dy8YbaWsDm3OZOpJRZxZsPKCHZ6xNqgFKf0xNHj0t9v0
# Q3W+2z5gAVaasJJCvR52Sl0XJ2AOf3l0LSetXgUA5gD5IQ1RvEslTmNnSouTrGID
# 3D1njY7mBu0puiIdPK2jK/1Weef2+YR4cQpWQkeBZmXidh9AuWdlwxKQL15LJ6K2
# dw8y/t/PBhmLyt6QAf0CepWRdgZnMytVAUuWHwlZRV9JLY7aX8D55eL9+cOLpX3b
# GNOmN24UpIW8qtZaqXaesFvIOW23JNLhaaQVvObr1eu7GE/5Mn43e+/DbtdYl/bL
# P2IQ1xYEJdSbcUkDFfW3KlZEh+nBKDtaRnNRkbgIgxIbKdT38OKQwZ/aA4uSsiAg
# 6nEPiWBHGuytIo5wU75M5VdjhEqqTHfXYu8BJi6GTzvWT+9ekfMXezqCkksxaG8C
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBSAaOo5HWatNzqZn1IF1fcD6nr3ITAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAXxzVZLLXBFfoCCCTiY7MHXdb7civJSTfrHYJ
# C5Ok2NN75NpzTMT9V2TcIQjfQ3AFUbh1NBAYtMUuwxC6D4ceEXG5lXAnbvkC9Yje
# LVDRyImXYYmft7z+Qpl9t3C/8a0tiqnOz8Ue8/DYLtMTgvWMnsqLNjILDaImOfnH
# I36TLCjGFe8RYLXGdCUdOLlfAdMGePxSTA3TAAOc+GQbmPWjrguLWbxvnl3NVjRv
# rBZVkxFMoVZH0f7qGwDOShjpnv5nYnQ48ufL0uBz52RbPGdX4Fv9+UGOrBprmcHz
# mIutFtJec2Y4kujNtTK2wBGgWscEOVhFiaVdje8VLJ7MVNKE5TmsuGM3jTLr1nuR
# 5AFGs3UKkP7g3cQD4cHK7XdLiTm7e606QJ+WqeQsADYE9dvU9wIUbI9Dl4UcIErF
# w+FHaWSTrkfJ4SvLmhKnl5khhpJ1sF3z6e1BxepUliXHqzRLiHWihWIWESF8IHEl
# F3POxbP4VJqHBiYvaXMV0SyRgwoD6zXddbUnX9WR6JL2BlqAjjHxINwelsp/VhxA
# WThzuMA58LxvE/VAzjfFF4Wm7a1ZALmJVw3oL/s/uxo1Op4tcT+hfZ9uN1htC1JN
# 4DuRqFfLttjuoAmUQobO5zUFRzvCn8Ck/hiO+bzR15sqkjlxLMyMjpkc/ef4SUUi
# kD468vUwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCC
# AkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0MDFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAMXYp/Wqqdyb0enigrLfxl0InAz6ggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5vx/UwIhgPMjAyNjEw
# MDYxOTE4MTNaGA8yMDI2MTAwNzE5MTgxM1owdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7m/H9QIBADAKAgEAAgIMUgIB/zAHAgEAAgIS0zAKAgUA7nEZdQIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQBZlnNfB/UMirjejlNVTIUarvmFOKzpqNP9
# XKaHUHKVZewx2/dhAoe8KtErXKcSfk64iDjXik+SYdjasyJZTOOx7zECbMBCqgz/
# hGosAk0UxGIqnGb+WzyOCZPvldHd/uAx3bziUbuFxXh1BU2o7Bp2p681YeCPftI9
# 7ayCNfIzznCwUvLeC5RKyh1DP6slVsQUKKNA1ZUuPrFtnkkaivhfs3gyPRqY7d7Y
# EPtZP4CBb/x8OLwF+Q9qSqX0mXlAqTX2fqnvoNSymmxnxb6A2zo9TgP9oO/RDpiS
# y8+MoA0toC+/EyrU8kf558Rk4ezxSm0MxtRWgFK3/2GDfJcrGm4mMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIZXrLYVHX0
# sY0AAQAAAhkwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgVS0PWbSIp5a0GxIQe4id9pLUimIHT0ON
# bNyCacqoeVswgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDckX633E1y1EF3
# 2V18zQcrsgjzI9+3Le7mlvk2OebthjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACGV6y2FR19LGNAAEAAAIZMCIEIK0UA/2ohXJ4rk13
# fKsrxvtZWYCPt5NDJQFpfo6HcfpgMA0GCSqGSIb3DQEBCwUABIICAKRi+wE+n5WL
# zbVQPzESb+G5zoowQn4FddItBx7QFG40R+wcZLKDf07yUUzLs1lfWnqvafcKbSj8
# K6MUorEd1DlMNurnCxAYwGavTUoPi8BPgbItbnxvqvt1B1RNMBjUKVcl9D2aNGL/
# OcRIyT5zsZ+Hd+wDXGn4Qyi5skSns4Qxe1OA4ZfJTTmzCjWeKfRA1PbnLNUItpVA
# X/uAhwRGfyGqsyT2HTp+2TMbO3OroQ08cfrKPt40B6VojhlIm/j3cHUy+PSiJOl/
# kZf0UPa1KR2m3U567/Sk/l/9Q7fEtSdrZUcIOhWIW+HnWg62QbT+DxXKM6QMu7wH
# kKG7uAVyQy6LEFHbV0RQ6GGsHod3NN3wTOkxBARyV8LVS4+O4KWWrdlc+G6r722o
# WY2qsqgL/zb76vNWr7Aqe1rGL+msCYHqQO3lb8eRqLbhftj6S1RE666ljEMFFstN
# 8XQUA5jt6LqO689dEX4nq5k9B02y3MkuEdcw08pyootLKUrrHZqahKUDyp5cLaSr
# yCS47CDDWjKwLxFCiFMGVtMC+WVZSOHdtaQ/dJYACsokBonzcAcSgH0mKhHZ2OEe
# 4WAJ6t+BBUxflN2qt2crL/lN73hxy24cOy39pR3qmlu1kaX0IVQMs9j0zezAJCc0
# m8xNDPcbAk8q1/OpPIrBQHEGcZZCv0fW
# SIG # End signature block
