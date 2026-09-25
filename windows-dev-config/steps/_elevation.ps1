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
# MIInNgYJKoZIhvcNAQcCoIInJzCCJyMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnDMIIZvwIBATBu
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
# ZsP6fZu5DHHb69c5qp7YnGNoQqGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sG
# CSqGSIb3DQEHAqCCF2wwghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG
# 9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAfbTt4JIqwwu/juaeZASyKX5JfTqvWh3n5f0Rxzq0eIwIGaqk2kjeEGBIy
# MDI2MDkyNTIwMzkyNS4xMVowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNDAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeow
# ggcgMIIFCKADAgECAhMzAAACKPClh9fzyB5AAAEAAAIoMA0GCSqGSIb3DQEBCwUA
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5NDAwNloX
# DTI3MDUxNzE5NDAwNlowgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNDAwLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAK6O9uT+ypwJJF5lol8K5/U3BFxzteSeETrCQuh+Q2PWbEQC
# DfmrLbFwWOCNqu1W8DT1bxAdynIypVJc5PE0cmyaTSo/YIMu9QC6VaDtpLmgE5Gk
# RfWjPefRHac+p4fQgcrXMnGPFodbbUBu5nRn7AzdZg3OQGVweZV7TdkbuuWTbyHv
# avk/kwTwUakWZhbkeXumwpuAsR+tgCK2m22xv6xmwFQj6EwqXi4slii0rJm/V7A4
# iKcF9FTxCiyK+Oh9oF7NR/011X6IataHfbVadKwrcD8mXoYu1tJZdwlZQuBvG6qe
# hs8r5iUHfXvhMxZOBfhhaMbujQ63P+mMc0IoFsHvzx3KeEt0ZjoHTwT37hIatGmy
# 3LiIkc7J0cIDkziLnJhHCx2636Ca/EilPzI1clyMkKDS87ya/+cVj1bK2/aqYK0I
# UWK8ZRapTbT+xR5GihBkaJA4lCfT3kKPeKwiy9E/wpTuE38QMjwdWxv80/MwUu9H
# OetGePRM6cOI5NRydjCaT5d+hLWjCyRwIILAedsLTQPnzPzfLsrlkkHvjmFyfgIT
# adHd7pEayvjbLmq23ox3P+zsxOcNLZSZUdZfVf8dl7dSVfyCP+3rcvnTEg+qREIE
# R0zUAM1RpJ+j05CIpv9uPV2JkIZN8QNQEEuinWaGTAgXzZ9qmVXZu6xn5TiRAgMB
# AAGjggFJMIIBRTAdBgNVHQ4EFgQUqsmljPjy3Oi69WQFW2EBIWlD3cMwHwYDVR0j
# BBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggr
# BgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0T
# AQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4Aw
# DQYJKoZIhvcNAQELBQADggIBAJDo18uatFqGBW2BaDfzcZpLTt8fKh3puFxQ423a
# 1637oFo24fSvsAGRUeF46nEF2tSs4RhURoiKL10rdy5ks2anWJQDH9VuY5liXvHP
# 602uMJaquDWNCarShEHyIThAmnA2EY/ruhjmG5ghTQPiWEOhqGp+Aomf/QGT71Qo
# M/DleVRiat4WYmWP1hDNw896nwzEFfGH9jkju9B5FpblKO2ItA4tGTeCC+toOzlJ
# /j0wlXr8HDFcLau9R8QVfpJQOiioogT02BUhGrRFm7s63SLQiz4e88/SEHorA7Ey
# DVJYo59O0Wlal2jwwm+AoIeQ+lcTOCms/6nIge47uBVGVJOxtgEUuHbIh3+K0zi5
# gvRH7ZJIEFOlJJG2Gsa4SYSUjkEIczHMyD+iodI/BkAgCQzYLjHGLRK3uoy4D6b5
# nMViR+gXjVChImf4eOqGpZhDSb9I738qclEklTAx3lOIyeNn4T8MmJSvLm52JbJC
# m9+PaFAUjR2OFqGgBcNrN4RyIsXa4SdO6v1R+NzA66f+gxj5Qt+2c6LaMosyut5X
# T3tqTPP8nGmcOBglT+2BTt9B+WDsiqIv37Tbvr6OhAejbWZV5jlgPwqH+RRpjomb
# 85Mzzwbt69PP+qdG6bGi9OMxK2+lsAc1GGZJN0g9NXfYLK7EMpL9XlrmLAD5/1WI
# Gj7CMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0B
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
# cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA00wggI1
# AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAHWtuYWT
# NLuoArU5q/TwBSeFs0hSoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTAwDQYJKoZIhvcNAQELBQACBQDuYOKPMCIYDzIwMjYwOTI1MTIwNzQzWhgP
# MjAyNjA5MjYxMjA3NDNaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO5g4o8CAQAw
# BwIBAAICHpgwBwIBAAICEzUwCgIFAO5iNA8CAQAwNgYKKwYBBAGEWQoEAjEoMCYw
# DAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0B
# AQsFAAOCAQEAQzF9MnrNesfXpFtsGT6sQ1UYX4gArrIUmPYGOoxXeoO7eq5NYCb2
# WxxlGoUNyxYID0DKeBugYHmOr2W66mlsRxGu8nXwku+G5FuB1CL6omnHMfjybLal
# K1JClb6su2JsRnovqUj+BPvjdciA1QdlUrDFdDAOLK9HKhKkvt9fngn+FWKE+BkI
# skaGVsMewa2BxP3npGARJN3mszV0Yz+e4j/mG7uFgjx1eanPsu8WrxK1NAJcj0Bz
# xIbrTp9G2xYfpT59u3NqbSMv4sncm2GjYpTUpoz51X9qz5wgurRcE6inT2CzfNUx
# x8AM4fR4GRvTylA2aeW6ziAa7NmrIem7xzGCBA0wggQJAgEBMIGTMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACKPClh9fzyB5AAAEAAAIoMA0GCWCG
# SAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZI
# hvcNAQkEMSIEIENdOmiKUmiuHwTMsGeWP1bxb5/K/sOT4Y0wbnhmJkzJMIH6Bgsq
# hkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgVbGKRlFgY1/igRVkrV5Pjkf7cZDf+rFX
# vlXC4G36ItcwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAIT
# MwAAAijwpYfX88geQAABAAACKDAiBCBL4uBt0YD8D9wrGrF9JhVJYMCFnjUQ0jwW
# k1K+vy+q4zANBgkqhkiG9w0BAQsFAASCAgAuz/pJ+PVk1F76xpXXmZMcaMUJMWte
# buci43iAq2Qj9/ERV0ofKOevP1R38dy4OWnzkffxuwykHfaqeeKVr2VP3mFylDG2
# LrGFNGY4fHbZT+IbSyOj9eTuyKHZl1T7y0mmRqjnGfmnA9sGcloxQH8xbawNf1v+
# +AadWNbMGwecz0o41UKHupPyknHhCGI+YxQwIWX0w9pWmSihPNVYUkEMTxpVWP7c
# fIQ9IF1ZTtHx3HONqwJXuuG/YGjZFdSizO83f0b5/Ecfa6eruOrtrvgqzkqWlEEI
# qgExE2kHs9nBRIktL4C1xevticgs1YlmlVy3vZIqR8T2GQXQ+iJl39CH3Pe3b6It
# MZo0IBJg2GS7CUCh82Nx3Xwpkh7mSr7R/Hjixr3nOJs4IvLyvfhVhc9b7ATzOhXH
# nb8/Y+pMoclWG5unqWstdRZdQkvyDT2h8d5tMBbO6vLuAMzPTI1YFELsP4YagKNq
# gxQt1ClhfNWE6xjIUI4Riuy/5yoK1L3ceeiucNantIN9vccFLnrFwkw30o37/TyH
# mVbEMg1UoVd2CtQ/wB2vQIFQCNt4A8PNHdUXxMTHbAFv+mrg530MOOnktDerldze
# B2H273GTn22/Tx5sLqy4Dls/igl2ZPyiWnS0Y+LFA76HCdf51LgPwyuakC6Hd9m3
# C80EV1wOx+PZRg==
# SIG # End signature block
