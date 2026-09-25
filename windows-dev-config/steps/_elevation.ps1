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
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
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
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
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
    $relaunchArgs = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action
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
# MIInUwYJKoZIhvcNAQcCoIInRDCCJ0ACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDWGcEuxfXxK5gE
# 5RkpWamZuN/2I/UfKfqfFHqXdIsKQKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIH30XdhwFPa4J5PuHU6LiCAc/hx1
# CkpWPd/8QZhdXhbKMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEABiZQWl1avXgHMz7q01FMLnz+bArr1ZD738QiBje/FLSrrCF4VJSwIk1eO8Ur
# Kw9SeV597CgbvdKXJ5Up9EYlQ2zthJUpugrYum4lrZTdOz323EoxTBQac1aZQ2XV
# 6MxWvOh1vw/IUpb+zLKXQUZ9wuRt/k+RoUZDQZdHo6yqHtP8Yw7rSybVo/eO5pS9
# IvJGeU3HtJTqUleV3GlyIKQIrFfgC7EHGOZ0518kgvrSn+xb3qCDe+Kr8KQT1Jou
# yNA5LOFyvPZJe/YcUUKxH8RbbElLXOxfDqpnY5AZOTpSUO/1n6sU+d4Qya8GMLJ7
# ZsP6fZu5DHHb69c5qp7YnGNoQqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gG
# CSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAfbTt4JIqwwu/juaeZASyKX5JfTqvWh3n5f0Rxzq0eIwIGaq0ojBqBGBMy
# MDI2MDkyNTAwMjIyNi4zMDdaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# QjA1LTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACEUUYOZtDz/xsAAEAAAIRMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgxM1oXDTI2MTExMzE4NDgxM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZCMDUtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAz7m7MxAdL5Vayrk7jsMo3Gnh
# N85ktHCZEvEcj4BIccHKd/NKC7uPvpX5dhO63W6VM5iCxklG8qQeVVrPaKvj8dYY
# JC7DNt4NN3XlVdC/voveJuPPhTJ/u7X+pYmV2qehTVPOOB1/hpmt51SzgxZczMdn
# Fl+X2e1PgutSA5CAh9/Xz5NW0CxnYVz8g0Vpxg+Bq32amktRXr8m3BSEgUs8jgWR
# PVzPHEczpbhloGGEfHaROmHhVKIqN+JhMweEjU2NXM2W6hm32j/QH/I/KWqNNfYc
# hHaG0xJljVTYoUKPpcQDuhH9dQKEgvGxj2U5/3Fq1em4dO6Ih04m6R+ttxr6Y8oR
# JH9ZhZ3sciFBIvZh7E2YFXOjP4MGybSylQTPDEFAtHHgpkskeEUhsPDR9VvWWhek
# hQx3qXaAKh+AkLmz/hpE3e0y+RIKO2AREjULJAKgf+R9QnNvqMeMkz9PGrjsijqW
# GzB2k2JNyaUYKlbmQweOabsCioiY2fJbimjVyFAGk5AeYddUFxvJGgRVCH7BeBPK
# Aq7MMOmSCTOMZ0Sw6zyNx4Uhh5Y0uJ0ZOoTKnB3KfdN/ba/eKHFeEhi3WqAfzTxi
# y0rMvhsfsXZK7zoclqaRvVl8Q48J174+eyriypY9HhU+ohgiYi4uQGDDVdTDeKDt
# oC/hD2Cn+ARzwE1rFfECAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRifUUDwOnqIcvf
# b53+yV0EZn7OcDAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEApEKdnMeIIUiU6Pat
# Z/qbrwiDzYUMKRczC4Bp/XY1S9NmHI+2c3dcpwH2SOmDfdvIIqt7mRrgvBPYOvJ9
# CtZS5eeIrsObC0b0ggKTv2wrTgWG+qktqNFEhQeipdURNLN68uHAm5edwBytd1kw
# y5r6B93klxDsldOmVWtw/ngj7knN09muCmwr17JnsMFcoIN/H59s+1RYN7Vid4+7
# nj8FcvYy9rbZOMndBzsTiosF1M+aMIJX2k3EVFVsuDL7/R5ppI9Tg7eWQOWKMZHP
# dsA3ZqWzDuhJqTzoFSQShnZenC+xq/z9BhHPFFbUtfjAoG6EDPjSQJYXmogja8OE
# a19xwnh3wVufeP+ck+/0gxNi7g+kO6WaOm052F4siD8xi6Uv75L7798lHvPThcxH
# HsgXqMY592d1wUof3tL/eDaQ0UhnYCU8yGkU2XJnctONnBKAvURAvf2qiIWDj4Lp
# cm0zA7VuofuJR1Tpuyc5p1ja52bNZBBVqAOwyDhAmqWsJXAjYXnssC/fJkee314F
# h+GIyMgvAPRScgqRZqV16dTBYvoe+w1n/wWs/ySTUsxDw4T/AITcu5PAsLnCVpAr
# DrFLRTFyut+eHUoG6UYZfj8/RsuQ42INse1pb/cPm7G2lcLJtkIKT80xvB1LiaNv
# PTBVEcmNSvFUM0xrXZXcYcxVXiYwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# QjA1LTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAKyp8q2VdgAq1VGkzd7PZwV6zNc2ggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5gOB0wIhgPMjAyNjA5MjUwMDAwMjlaGA8yMDI2MDkyNjAwMDAyOVowdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA7mA4HQIBADAKAgEAAgIO/gIB/zAHAgEAAgITgTAK
# AgUA7mGJnQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQBT8P/KxSCIt367
# aGdO9zIJUAuZDf7DsRnAYl+5ZekBpuuOKEGlAdmCwkGPNSJj2wXUKA0FfyzQ8wXE
# k74gKd62VqbYWua+LRL+BH9x8n4Xs4wTCmUDTy2LC2q/CEfSbxsmxPvJiAFaGYMw
# 3DvIDDVRvUn5lL1zjMSzR6sLfJbq0skvOLFLFYaZc4ndA+jLcrJX474FgeunVLHN
# /u3THDh1fd3p01jXl2u+qox0NIneO6Zb3f8sS9DZacTlipk4nuZY4bOmfI2UEhN9
# PmKEFwKrpyzN1V5M6GFviOV0SsZ0Rteh3qkqBhknx+LTjOHI+u0Lb0RcRBM6qn03
# qaKBDZJnMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIRRRg5m0PP/GwAAQAAAhEwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqG
# SIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg1UoUz7F9i25G
# +VewWDYUhfUqx1KWN/Nj02JNLf3yCdYwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHk
# MIG9BCAsrTOpmu+HTq1aXFwvlhjF8p2nUCNNCEX/OWLHNDMmtzCBmDCBgKR+MHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACEUUYOZtDz/xsAAEAAAIR
# MCIEIDNKOHQulSzdRRYZ5WL02KGHgxJmB4XAYwtynVU5VZR8MA0GCSqGSIb3DQEB
# CwUABIICAJiS2j6WWsrp2wUnCOpTb+uF9F3Ohj45rGYbOT0Bx1bYeMlMCDQC6l19
# npqlkwTVAncGwBG2+oWKwwlo/c7hlCe00kNpvW7fCaCX7HtM4/iavdBwHK24KlwC
# LZPmSVultBxr+wp8XoynIuvc/uItt3Vp/OvQy9uUEv0s8Dd5ujJ9+wd2dsp6LEyX
# JBp4WCYVwAsimy1IMo4sq7wKg2i3hpHS0Q2t0PM9Td4rC/0DzTEHDZwmFSj0mYKj
# C8rSF7kjD30QFwQfwatJFtMaX2ZcYzM9tMQNsRE1mzogKg5EztGj9TIzgUsR1v20
# ZkdeT3NFu1QwbQJeksQDumtBuVdaWYI4fxeYpin1XdGg8rX6MIgtyYUtPrVDX4E1
# M1h2nL9iFG3tgy7sUen/jGsDhZJwyhGc6iyvC5T3fBGdyFN3PArV6BmbQQlgYDon
# JydiqvgTLdf9CMT7f8R1o+BTmIgtN5VGDtYoyiByrb+hiTCH2S1wTNxu9xVU3T5w
# aKxMGlhkj1LfWkVFSqaxiL0cxZR5tEbWUk84ngWREuNzBxclB7m/wiXAYZ8U85ey
# DpLKH0FTE7Q2j7MyJ0e5EnI6MtnIVufyeXXR6czMUwCsKpncQ6E9iYqmm5RKJT4J
# i7788BoJkYxHnn3pizyW8/nuwgZfjXgHyDYJG0AdxLSt/C9YGlIZ
# SIG # End signature block
