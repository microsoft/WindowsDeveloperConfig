<#
.SYNOPSIS
  Installs Cascadia Code Nerd Fonts.
  Schedules Cascadia Mono NF as the Windows Terminal default font at next sign-in.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:CascadiaFontVersion     = '2407.24'
$Script:CascadiaWantedFonts     = @('CascadiaCodeNF.ttf', 'CascadiaMonoNF.ttf')
$Script:CascadiaZipSha256       = 'E67A68EE3386DB63F48B9054BD196EA752BC6A4EBB4DF35ADCE6733DA50C8474'
$Script:CascadiaDefaultFontFace = 'Cascadia Mono NF'
$Script:CascadiaFontRegPath     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$Script:CascadiaUserFontRegPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Test-DevConfigCascadiaFontsInstalled {
    $fontsDir  = Join-Path $env:SystemRoot 'Fonts'
    $regValues = @(
        (Get-ItemProperty $Script:CascadiaFontRegPath -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object Name -notin 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider' |
            Select-Object -ExpandProperty Value
    )
    $filesOk = -not ($Script:CascadiaWantedFonts | Where-Object { -not (Test-Path (Join-Path $fontsDir $_)) })
    $regOk   = -not ($Script:CascadiaWantedFonts | Where-Object { $fn = $_; -not ($regValues | Where-Object { $_ -eq $fn }) })
    return ($filesOk -and $regOk)
}

function Remove-DevConfigStalePerUserFont {
    param(
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string] $RegName
    )
    $userReg  = $Script:CascadiaUserFontRegPath
    $userFile = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') $FileName
    try {
        Remove-ItemProperty -Path $userReg -Name $RegName -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $userFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Could not remove the per-user copy of ${FileName}: $($_.Exception.Message)"
    }
}

function Test-DevConfigFontFileInUseError {
    param(
        [Parameter(Mandatory)] [System.Exception] $Exception
    )
    while ($Exception) {
        if ($Exception -is [System.IO.IOException] -and ($Exception.HResult -band 0xFFFF) -in 32, 33) {
            return $true
        }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Test-DevConfigFontFileMatchesEntry {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string] $Path
    )
    $entryStream = $null
    $fileStream  = $null
    try {
        $entryStream = $Entry.Open()
        $fileStream  = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $entryHash = (Get-FileHash -InputStream $entryStream -Algorithm SHA256).Hash
        $fileHash  = (Get-FileHash -InputStream $fileStream -Algorithm SHA256).Hash
        return ($entryHash -eq $fileHash)
    } finally {
        if ($fileStream)  { $fileStream.Dispose() }
        if ($entryStream) { $entryStream.Dispose() }
    }
}

function Expand-DevConfigFontEntry {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string] $Path
    )
    try {
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Path, $true)
    } catch {
        if (-not (Test-DevConfigFontFileInUseError -Exception $_.Exception)) {
            throw
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            throw
        }
        if (-not (Test-DevConfigFontFileMatchesEntry -Entry $Entry -Path $Path)) {
            throw "Couldn't replace $($Entry.Name) because the installed font is in use and doesn't match version $Script:CascadiaFontVersion."
        }
        Write-Host '  (keeping the matching copy already in place)' -ForegroundColor DarkGray
    }
}

function Install-DevConfigCascadiaFonts {
    $version = $Script:CascadiaFontVersion
    $zipUrl  = "https://github.com/microsoft/cascadia-code/releases/download/v$version/CascadiaCode-$version.zip"
    $workDir = Join-Path $env:TEMP "CascadiaCode-$version"
    $zipPath = Join-Path $workDir 'CascadiaCode.zip'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    $fontsDir = Join-Path $env:SystemRoot 'Fonts'

    Write-Host "Downloading $zipUrl ..."
    Write-Host '  (About 10 MB from GitHub. This usually takes a few seconds.)' -ForegroundColor DarkGray
    $ProgressPreference = 'SilentlyContinue'

    # The retry covers timeout-bound download stalls and hash mismatches from incomplete downloads.
    Invoke-DevConfigRetry -Name 'Cascadia fonts download' -ScriptBlock {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
        $actualHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
        if ($actualHash -ne $Script:CascadiaZipSha256) {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            throw "the downloaded file didn't match the expected contents (expected hash $($Script:CascadiaZipSha256), got $actualHash)"
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Drawing

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in $Script:CascadiaWantedFonts) {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) {
                Write-Host "  ! $name is not in the downloaded archive; skipping it." -ForegroundColor Yellow
                continue
            }

            $dest = Join-Path $fontsDir $name
            Write-Host "Installing $name -> $dest"
            Expand-DevConfigFontEntry -Entry $entry -Path $dest

            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            try {
                $pfc.AddFontFile($dest)
                $family = $pfc.Families[0].Name
            } finally {
                $pfc.Dispose()
            }

            $regName = "$family (TrueType)"
            # Machine-wide entries hold the file name; the system resolves it under the Fonts folder.
            New-ItemProperty -Path $Script:CascadiaFontRegPath -Name $regName -Value $name -PropertyType String -Force | Out-Null
            Remove-DevConfigStalePerUserFont -FileName $name -RegName $regName
            Write-Host "  registered as '$regName'"
        }
    } finally {
        $zip.Dispose()
    }

    Remove-Item $zipPath -Force
    Write-Host "`nDone."
}

function Test-DevConfigCascadiaDefaultFont {
    $path = Get-DevConfigTerminalSettingsTarget
    if (-not $path) {
        return $true
    }
    $settings = Read-DevConfigTerminalSettings -Path $path
    if (-not (Test-DevConfigCascadiaFontsInstalled)) {
        return $false
    }
    $face = Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults', 'font', 'face'
    if ($face -eq $Script:CascadiaDefaultFontFace) {
        return $true
    }
    $pending = Get-DevConfigPendingTerminalFont
    return [bool]($pending -and $pending.Path -eq $path -and
        $pending.FontFace -eq $Script:CascadiaDefaultFontFace -and $pending.PreviousFace -eq $face -and
        $pending.Command -eq (Get-DevConfigTerminalFontRunOnceCommand))
}

function Set-DevConfigCascadiaDefaultFont {
    param(
        [string] $ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dev-config.ps1')
    )

    $path = Get-DevConfigTerminalSettingsTarget
    if (-not $path) {
        throw 'Windows Terminal is not installed, so its default font cannot be set.'
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $face = $Script:CascadiaDefaultFontFace
    if (-not (Test-DevConfigCascadiaFontsInstalled)) {
        Clear-DevConfigPendingTerminalFont
        if ((Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults', 'font', 'face') -ne $face) {
            throw 'Cascadia fonts are not installed; the current Windows Terminal font was left unchanged.'
        }
        $face = 'Cascadia Mono'
        Set-DevConfigStepUnverified -Reason 'Cascadia fonts are not installed; using Cascadia Mono until installation succeeds.'
        $font = Resolve-DevConfigJsonBranch -Object $settings -Path 'profiles', 'defaults', 'font'
        Set-DevConfigJsonProperty -Object $font -Name 'face' -Value $face
        Save-DevConfigTerminalSettings -Path $path -Settings $settings
        Write-Host "Set the Windows Terminal default font to '$face' in $path"
        return
    }

    $ScriptPath = (Get-Item -LiteralPath $ScriptPath -ErrorAction Stop).FullName
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -ApplyTerminalFont -AllowUnsigned:$Script:DevConfigAllowUnsigned
    $command = "`"$shell`" $($arguments -join ' ')"
    if ($command.Length -gt 260) {
        throw 'The setup path is too long for the next-sign-in font update. Use a shorter install directory.'
    }
    $scheduled = Invoke-DevConfigTerminalFontLock {
        $settings = Read-DevConfigTerminalSettings -Path $path
        if ((Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults', 'font', 'face') -eq $face) {
            Clear-DevConfigPendingTerminalFont -LockHeld
            return $false
        }
        Save-DevConfigTerminalBackup -Path $path
        $pending = [pscustomobject]@{
            Path           = $path
            FontFace       = $face
            PreviousFace   = Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults', 'font', 'face'
            BackupRequired = [bool](Test-Path -LiteralPath $path)
            Command        = $command
        }
        Write-DevConfigTextFile -Path (Get-DevConfigPendingTerminalFontPath) -Content ($pending | ConvertTo-Json -Compress)
        if (-not (Test-Path -LiteralPath $Script:DevConfigTerminalFontRunOnceKey)) {
            New-Item -Path $Script:DevConfigTerminalFontRunOnceKey -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $Script:DevConfigTerminalFontRunOnceKey -Name $Script:DevConfigTerminalFontRunOnceName `
            -Value $command -PropertyType String -Force | Out-Null
        return $true
    }
    if ($scheduled) {
        Write-Host "Scheduled '$face' for your next sign-in; the current Terminal font is unchanged."
    } else {
        Write-Host "Windows Terminal already uses '$face'."
    }
}

function Invoke-DevConfigPendingTerminalFont {
    Invoke-DevConfigTerminalFontLock {
        $pending = Get-DevConfigPendingTerminalFont
        if (-not $pending) {
            Write-Host 'No Terminal font update is pending.'
            return
        }
        $path = Get-DevConfigTerminalSettingsTarget
        if (-not $path) {
            Clear-DevConfigPendingTerminalFont -LockHeld
            Write-Host 'Windows Terminal is no longer installed; the pending font update was canceled.'
            return
        }
        if ($pending.Path -ne $path -or $pending.FontFace -ne $Script:CascadiaDefaultFontFace) {
            throw 'The pending Terminal font update no longer matches this configuration. Run setup again to reschedule it.'
        }
        if (-not (Test-DevConfigCascadiaFontsInstalled)) {
            throw 'Cascadia fonts are no longer installed. The Terminal font was left unchanged.'
        }
        $settings = Read-DevConfigTerminalSettings -Path $path
        $face = Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults', 'font', 'face'
        if ($face -ne $pending.PreviousFace -and $face -ne $pending.FontFace) {
            Clear-DevConfigPendingTerminalFont -LockHeld
            Write-Host 'The Terminal font changed after setup; your choice was left unchanged.'
            return
        }
        if ($face -ne $pending.FontFace) {
            if ($pending.BackupRequired -and -not (Test-Path -LiteralPath "$path.bak")) {
                throw 'The original Terminal backup is missing. The font was left unchanged; run setup again to reschedule it.'
            }
            $Script:DevConfigTerminalBackedUp = @($path)
            $font = Resolve-DevConfigJsonBranch -Object $settings -Path 'profiles', 'defaults', 'font'
            Set-DevConfigJsonProperty -Object $font -Name 'face' -Value $pending.FontFace
            Save-DevConfigTerminalSettings -Path $path -Settings $settings
            Write-Host "Set the Windows Terminal default font to '$($pending.FontFace)' in $path"
        }
        Clear-DevConfigPendingTerminalFont -LockHeld
    }
}

function Invoke-FontsPhase {
    # BestEffort keeps later setup phases running if the font download or settings update cannot complete.
    $steps = @(
        New-DevConfigStep -Name 'CascadiaFonts' -Description 'Install Cascadia Code Nerd Fonts' `
            -Check { Test-DevConfigCascadiaFontsInstalled } `
            -Apply { Install-DevConfigCascadiaFonts } `
            -BestEffort
        New-DevConfigStep -Name 'CascadiaDefaultFont' -Description 'Configure Cascadia Mono NF for the next sign-in' `
            -Check { Test-DevConfigCascadiaDefaultFont } `
            -Apply { Set-DevConfigCascadiaDefaultFont } `
            -BestEffort
    )

    Invoke-DevConfigSteps -Steps $steps

    if (Get-DevConfigTerminalFontRunOnceCommand) {
        Add-DevConfigNote -Message 'The Terminal font will change at your next sign-in; no setup rerun is needed.'
    }
}

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAZpWLtij3AVzRs
# MnTDtBuAQIHmZvd8flc7DIHsl/g0JKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIDgG+LeiLyRt9eOGncLYypyQsfcV
# CsSd/AV0kK/6H2ohMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAoSQsd/Rh4k9TYeR/O3/m98xx+bXxQOnOTq6oSsgZL6c3XUx9Ps/b8eLRRTM4
# YucFHgY42+894jZjDX0hemwjanJlo/7z5dXQ0auErlXE71SI4UXaJASzHhQovlrY
# /Zr/ruopVyuSQ86a0ZxOmgqYkiBlJOIJBlL9R+H4sGLIhXd00I98QLe+5a/LzsuW
# pKUCM6TztlGT/5r2RatGKVphw/X7DHwzwABGBlOmI3rCraBgmyqAFDeQqpygnHm5
# +RMiWpedE8nrvwQqZ9e2gWf8S40jo2a3VIDVWGOL4HCotwZxyjr1hV40rg79C2pg
# sKm7nEF9EPRqF/+pGNCDMHb6aqGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCClmtp7EUpgdAtweO4VhWPn6n60nqSTWweoI4y3LUa2TAIGargHQpmaGBMy
# MDI2MTAwOTIxNDQ1Mi40ODJaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyM1oXDTI2MTExMzE4NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNh
# RM+BzF2AYiq5dUpZpJFPRjCcipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU
# /W6fecujjILkPqn9pngtWRkfQgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY
# /Qk/jtjsHdFXVBe+tshlIkSJ3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQM
# JP7tO8/BJ7ITs4/AV3D2bv8eHk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf
# 5x1lXxAwEw5a7dpS+CKTanhtv+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1
# S9e8h1TszXFzjLLvE9EmjnNfIewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J
# 60fGOl7A1UoUyAkhpb2Bja+SwSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6
# FZlPO8iuNyk680Di8VnbSNpIdJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asN
# t/Ng6o4m2dnooWOdM3yKsJaWjyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+
# XSvI2m1yN4iibqjm5HPaAO3OJ+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C
# /+n1KFBpDGdDMw9gmu8CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5
# ZQqnF5x8S1bJQzAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg
# 5I/5S+gx67aR6RiW8ZAwtE3mz8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyv
# h3e2q/BV8rjHE3ud9PyYyq32euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZ
# sSypbXDBbQkWkNl6g82yTy3AbBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dM
# SkSZweCNDXqd9r/9W2VdRZsDJKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69
# /N5CP/Tq3YgI1ub4b9+3MJFKWhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2
# NFXJFQHef6AdRe1ERvYQeqtyrBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67
# oNwR4pEEJyAIEREvkdhjjfWcgsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D
# 59r7/qebNSyQPTfwI9++jEY0Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HE
# ovbA69qGlZ3OpUE3H1RBGDVp/FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IE
# XO2SeD1aD3IqvAOdHFKHg1vpbPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7
# zw64aO5hmJ7eQwoMfTu0Vay6r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# HVUzWLOhcGbyoYIDVjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5zp8kwIhgPMjAyNjEwMDkxNzUwMDFaGA8yMDI2MTAxMDE3NTAwMVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nOnyQIBADAHAgEAAgIF5TAHAgEAAgIT5DAKAgUA
# 7nT5SQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQA7pw9ZttIR7wWJYYMx
# AR6AnGVVVhEstNkQd9Th6MftmGzYl41cwp2kV9UdikJSBb+uB20MFyvobtobAwpG
# uw6yIjorZpnR+wTXvzFRG+4U3NAiAxdIoY7RjDYJ0XIJAzOxYE8cBbaeMn1Yq3JK
# iJkWT8lJl/qkTtx/ytirsC9gf56NybUIoeiPQnPgPvnZNVY3zxA1YpOfXuvzcBZ0
# ogGTWzo818tZfnTLmPOpo1HeiKbV7vSWOKCf3ycpcIx0ym6nTYc4i/KiqcmfnME7
# kfUeGZoy6jQQUpCBWhv42ql7P86d4vGP7nh6ImdK0Ya4POsJcEGq0mpcD4Q1YV0F
# wA56MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIXcfsupa8BHeoAAQAAAhcwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQghVcUhLgbHrpH6qmR
# zFQcUFCgNTJPPtbMUenQJVb8ZgswgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCDQ8lBgPl23yZ0SzUSt5phOIegHPywrkNwevxe2k+RaWzCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACF3H7LqWvAR3qAAEAAAIXMCIE
# IGimmxmuSXKXzzoqo7DDSU7Cbko0MVNcKniiA4PT/LvMMA0GCSqGSIb3DQEBCwUA
# BIICAEUpOQQJK2YYnsscPNUQiNI011p0A9e9O9H5qafa83Zdh8FG+o3w2saNBPd/
# +YxzvffrNw/wI7A/LuLxveL9TDW7HFKZkcok9EZnwdN3tdzx84+xPMmgM1wt+5BJ
# J5GQXDlRO0TuQSeb6BMTbSOWkDFOYljHmqeLKxVp13EV2NxjdsZWc9VBVtZbQs1L
# rCrbok6YjOqj5Oy2TVGa8ajEVIIxmpnuUWUUimP43M7YV+tnhNuA8CEQsSjEjT2U
# HrUjKDyrhnBVLjnJUs68eeuuEe5l4yg3trAgVvl8cKWyV+x9afZQdAD5Y6Ym7qI4
# 89O8ko1f0qArH7XdwfGJuZ5kwJrOlnwR21MXJK7lcjBqF9M42vIityqViA5RIw1z
# uOd4ufld4nzoyCqJrAy7XbVOKuJYj6/3I2l3pmZ99tM5k77HwIOCn9tW/uTfEcDZ
# xuWFHKsY7M7iPlJt/qfwoi0yQmGXq6zKzoB+Po5A5lkitNZE8ig5L/7Q9krcBY1u
# pWXsULhujG568xGhdaRBxFk5lCmaw2j2osqiZbhkCdas3EzDNl9UNJAQQOMGpi5n
# Vs1vNkTFlSVlwL6SLNfiRIPzhIojxq5e5OQxRg+veMM4/52VupQ1qwhvCfxewwao
# d5gTE3tFFM9mlepoU/+VIQU/OMyJ2sabI1meoo9CFn/jKmI6
# SIG # End signature block
