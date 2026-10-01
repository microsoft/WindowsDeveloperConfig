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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
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
# sKm7nEF9EPRqF/+pGNCDMHb6aqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCClmtp7EUpgdAtweO4VhWPn6n60nqSTWweoI4y3LUa2TAIGaql/5ZGWGBMy
# MDI2MTAwMTA0NTE1Mi45NzZaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiu7AFD/TTuaoQABAAACKzANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMTFa
# Fw0yNzA1MTcxOTQwMTFaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCX3mi6OD3syUqQm4QqgkrKPbcsK/Qx3fYctL8+VM1uOY3b
# ooi5GxwauTgQf6JFHITToxS7gjqKlK8OFLzL6UTl0jxEK5t6DuOcgJXdvutimoTl
# OS0C3kyITXBAXoj/gp6hRR9z6WRip1Ktkilb3dJXCjQqT9P2Cuujr+Vz8r+Z+jDl
# 09ji/ic/4G34r3mVwjs//Gnx9Pu31V8rXFicNiAzxpubawpbd8pqfzlWT2vnG3kF
# 9l6MiREbvJ3XHLUwHQsh0t/TrSFx/s/yCqpJWYJ6oClG70tvsFH0aRP8wB4cP/CF
# a2ILvk26i3OcJBl+pqKjHTSBy9mvwTPEDlnzco0Nt8R6pSPTXZgBsscHhoKfC0WQ
# mOzY2keXbAmRTcZMyXz5v/AJbmoI0y07Bazvt5NkXddG9TErQWwtsFyIKrElDgWf
# HeCoTu1wu2ciD3dK72z3ca2gzoEDxT2j9BXIUKaiTzTdQPRsAMaO3dU0zaGwMMlw
# tSJyDh14YEgZoUu5vS8MugMqdrNjphyL65yKhjpAWbhYkIHO/0uZju95tP8zZNqX
# IRh4tdfWHJPATn9r+cxkyuh2x0VLdfx1lmK9X3NjH0NtgAs5JB/wOlkyuudxmFTf
# WVyRrL37ispOZ8aPAFgvyR6cNTkGpkFo35JRjciNmZiU4qT9Uty+V5gudFk1jwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFD4WjuQTUJbtbd3jmvZku0FZ2eU2MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQDO/CKsciEM8kr1fqH4TlfT66ENoTjxXw810pyE
# q0PdrgLwfgT3x+1gz7CQHtUdevqMQ5qHyDLhm6pT911CYkGN+6g+MU7fMYTr6d3S
# xieJwBIoWkfR4g7SitGzMKU465KEYejfddoUgovC/xcRpaALO5p3/A248ByhJiMt
# tBQNDtsT/HaCFwRFCURby/f8c1kky8F8xkCXFz+/MtZ5d1lWFjwOI2geZHWq9Xih
# DOgee5nS2koo5V6n8XG220UTevVf+pgmpIH71XKDVIYTGGZJs6yPlfJ2aXqw1ME4
# NR6okNsY3P1M31H6DMYRfJGNBNep595kXGh3YzA3cCiyg+jmJ58h/fTvjngIpuUF
# fODpDjFx0ic1YoLANxhCF3RhS9qYM7K40NEhKshYuaAkIG2XBKYig3r/0/b0sjvj
# Bws55AYonMm3A8qcX/6k9Vfc0mv9dtonHuWGfA2b+qE2qpCnhzGbdDHq7iOSZEw0
# 1nNupAMf1c41k9IoTQ2z3iw6w4ZZoLOyg4TKMbp1krpT4trip/y30Cv5khyqCDNq
# aXQpBkOYON8LgtoQ3amVOX7ix5jdrnx/vUxTUSigXvrWdL7Uk8kpmS0zto2Toy7a
# T5oBzCTvfj9iJ/BN/E1vhFBkhJCvZ7PVvsMSnTTmkx2Fal2lVkztuAI44fD/uyLJ
# daMQSzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkEwMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAJrD90
# ykHpo/0AGb7lmwvsCtqROaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mfCcjAiGA8yMDI2MDkzMDE3MTYzNFoY
# DzIwMjYxMDAxMTcxNjM0WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuZ8JyAgEA
# MAcCAQACAg5FMAcCAQACAhJ4MAoCBQDuaRPyAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAEhvK8YAQwQGjavEsHhDbAKYaJLZhW60d8HrM0uQapzJIjPm8/kZ
# MrTvXvo3GmcXjj6TSUeRdLJ+uzkrgxXD70rGBjcqBJ5JLrs2IBmaPOez6Vv6eSl6
# 1unay3iepkKJlreb+7su7WC5e5pRdJ03BDNIkov5AMofMM1KkEy/BcFnfiJngmwG
# A6D77LsQJGA3snf/0UUfV5yEce/3AkmfL5kv1OQc4WBYOjV8Y3KVtP4NVg9mzBAq
# WdQlkeziAF9NEC8xnuwlNsJUQha/yZAQFRFjArI97rS9z+fFwjzmR93YucnwzjdW
# tzDenc5m7cWnF/wTeWb8lHb8IhOc1XnXmikxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7AFD/TTuaoQABAAACKzANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCAmY/ihrWz/O+z51VpGCuMRku+Ex9eDus6iCYdqBYwfVTCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHIOI/Q/kFftYA+M2OY+1Bx3ajBD6/WD
# AtPT2vFkv25SMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIruwBQ/007mqEAAQAAAiswIgQg2Lp9nNdvglCr2/5xvViYzv51mXktsPRX
# SCIH/EtmENQwDQYJKoZIhvcNAQELBQAEggIAEuVNPlzLJNJ6ZsHxQlD1c00i1WbB
# 4n+v7PxqlVH9gHNT+Pw8kv4qVjtyDj6+3re04kn0jlCS7VymCaO9HfaUEj6iD7GN
# BPFVavPkeJdGZtNOZJCF8Nvv8T7g1aYIQ9WM+CiEdaMxa64j++Tk6BoYcdQ2XFWp
# yiiPovcv4ax2gnrx4wer3fPyKNtew4GV1lOSXeTOtHlxVsgcWTwzsTsZ/vLgLDoV
# tUlhcpE9MVCyPme3tfb/s/gNX4FKIUdqqXxTEfvJMxGrp0RYceOVq0y5ae8YSfkL
# jim67r01Nwk+LzyAXtJOFvqHjfU4nzyoYzGDc31RdWyAsOLu9zKwclRKR2Uquv/5
# Kguu71MGPt35C56bhfrjTb4U7iLgwdKIcQuWjtVhgAYHyHKFJGXsNUT1o68lOxRW
# VBxiGSaNRdP+S6aUYdQxJ8OyjB0bhPerqdKomCCC2FbwQF5I0ePXA3Nz9lVnJ322
# PemDGV+CHcMjpwfZx6xOuWA2OWNQRoJ/atlzqbBNsnw5S5RYNxV8WrZx3X4JaGZY
# +DnFTePxwbe0QvLsKD2+EFRB44agWHJiuA0jbpXuyKT2r1gPoWhkD6au8lhVAGLY
# uxx6tjkk507WOl3rmYCsIvmNFk4YSaKiEZ+acX5wY5zH3Te3xU8WWvFch537uI+V
# TZohLHArKMhyrRA=
# SIG # End signature block
