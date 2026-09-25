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
}

# SIG # Begin signature block
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA1vjsWvv4q3TX+
# BZhooz+6yTxPEhSwhEIurI+5ZUIC3qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEICn890+QLLOjMlOTPuq2Yt0Tf1K28oGExibm949ni1v0MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAH1sikD1Q5k1H2ua2
# dYGRHN07dKizXa4vrcb1PHYCdVZjqIrX7M5G7vi4v30WuMgPrjs/adOm1T7nFeQl
# U/Z6eOeSRhiUamzmFcUSKr3zNwwubcKRHyDlkH8w0XhxVE67WKYi4AFJGQU/V/oG
# ecBbF0Kw8AzLf3eccWSbDud/4tlOI40W340/Jy4B0qzJzImsfIO3JSeZ4mN0ZXZd
# eTvPmD5PFjQEdPLsJk6bn8q1ypJPbZzIeniYWCCjH2wfoW6L/DFGNT+1y2AttRJa
# hfBbXjJqd26bQVNaZaUPm2cOiLvph5tMALdle8JhZPiayjLy4SzmKEaSoRIQi8vq
# T2Q4paGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kw
# gheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDX8Lv4IorJn0Rm
# IT/6aWWbxyRx98e4+1x4kQRfxa9nJwIGaq2l2N4EGBMyMDI2MDkyNTAwMjIzMy4z
# ODhaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIF
# EKADAgECAhMzAAACGqmgHQagD0OqAAEAAAIaMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyOFoXDTI2MTEx
# MzE4NDgyOFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjMyMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAmYEAwSTz79q2V3ZWzQ5Ev7RKgadQtMBy7+V3XQ8R0NL8
# R9mupxcqJQ/KPeZGJTER+9Qq/t7HOQfBbDy6e0TepvBFV/RY3w+LOPMKn0Uoh2/8
# IvdSbJ8qAWRVoz2S9VrJzZpB8/f5rQcRETgX/t8N66D2JlEXv4fZQB7XzcJMXr1p
# uhuXbOt9RYEyN1Q3Z7YjRkhfBsRc+SD/C9F4iwZqfQgo82GG4wguIhjJU7+XMfrv
# 4vxAFNVg3mn1PoMWGZWio+e14+PGYPVLKlad+0IhdHK5AgPyXKkqAhEZpYhYYVEI
# tHOOvqrwukxVAJXMvWA3GatWkRZn33WDJVtghCW6XPLi1cDKiGE5UcXZSV4OjQIU
# B8vp2LUMRXud5I49FIBcE9nT00z8A+EekrPM+OAk07aDfwZbdmZ56j7ub5fNDLf8
# yIb8QxZ8Mr4RwWy/czBuV5rkWQQ+msjJ5AKtYZxJdnaZehUgUNArU/u36SH1eXKM
# QGRXr/xeKFGI8vvv5Jl1knZ8UqEQr9PxDbis7OXp2WSMK5lLGdYVH8VownYF3sbO
# iRkx5Q5GaEyTehOQp2SfdbsJZlg0SXmHphGnoW1/gQ/5P6BgSq4PAWIZaDJj6AvL
# LCdbURgR5apNQQed2zYUgUbjACA/TomA8Ll7Arrv2oZGiUO5Vdi4xxtA3BRTQTUC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBTwqyIJ3QMoPasDcGdGovbaY8IlNjAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEA1a72WFq7B6bJT3VOJ21nnToPJ9O/q51bw1bh
# PfQy67uy+f8x8akipzNL2k5b6mtxuPbZGpBqpBKguDwQmxVpX8cGmafeo3wGr4a8
# Yk6Sy09tEh/Nwwlsyq7BRrJNn6bGOB8iG4OTy+pmMUh7FejNPRgvgeo/OPytm4NN
# rMMg98UVlrZxGNOYsifpRJFg5jE/Yu6lqFa1lTm9cHuPYxWa2oEwC0sEAsTFb69i
# KpN0sO19xBZCr0h5ClU9Pgo6ekiJb7QJoDzrDoPQHwbNA87Cto7TLuphj0m9l/I7
# 0gLjEq53SHjuURzwpmNxdm18Qg+rlkaMC6Y2KukOfJ7oCSu9vcNGQM+inl9gsNgi
# rZ6yJk9VsXEsoTtoR7fMNU6Py6ufJQGMTmq6ZCq2eIGOXWMBb79ZF6tiKTa4qami
# 3US0mTY41J129XmAglVy+ujSZkHu2lHJDRHs7FjnIXZVUE5pl6yUIl23jG50fRTL
# QcStdwY/LvJUgEHCIzjvlLTqLt6JVR5bcs5aN4Dh0YPG95B9iDMZrq4rli5SnGNW
# ev5LLsDY1fbrK6uVpD+psvSLsNpht27QcHRsYdAMALXM+HNsz2LZ8xiOfwt6rOsV
# WXoiHV86/TeMy5TZFUl7qB59INoMSJgDRladVXeT9fwOuirFIoqgjKGk3vO2bELr
# YMN0QVwwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUA8YrutmKpSrubCaAYsU4pt1Ft8DaggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5gDLgwIhgPMjAyNjA5
# MjQyMDU1MjBaGA8yMDI2MDkyNTIwNTUyMFowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7mAMuAIBADAKAgEAAgIM6wIB/zAHAgEAAgISkDAKAgUA7mFeOAIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQCbL30HGfjH/UcUIUjMpZKYD9MPoH02ymWw
# i5CzYdUMi86PloXUCibdjJNqcKpvG4122S7WFlW9ZEuwuxsG3eVrQf98gjNTGxGh
# kvId1qhzFGJh6z51zl8O7Pu4ZXeniGkTOBnijyo4c7Zz0IQuwV/GPJobFRvVdPGU
# Nz2/RTH8ImJrBZwkLNDF5pSU14Jems5IfHEN1oXsUajFLdyC86e87hXXuAhjqC95
# sK8R+8V6+b2qrq/LeAsOrqwHvtj7hZiV3O7Ck9P9Z4uT13ipeTQ9UHQ5UHvKDcDh
# MPUv8CvDcRZDP1IZLy2M6rutm+GO3vHhADR9G952aAn+AaUHW3KlMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIaqaAdBqAP
# Q6oAAQAAAhowDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgTP9JoTdmR5bT0I4AlMWfEqmckFVKu6YB
# wxFE07ZWWtAwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCdeiHHrbtpKcwB
# 20doVU89WHIOH8S7w37uaHcDmemK+zCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACGqmgHQagD0OqAAEAAAIaMCIEIAy/9tw+Kq/bYTtT
# L8sS+uADXpoDKQPrFpdbAMfhpPjEMA0GCSqGSIb3DQEBCwUABIICAER/Yx8raQbn
# d1SeH9lumw+EdUIApP2sGyQda57p3AJn3sCpOW57ghyi+BqyDWpQoumaIGGL4K2u
# SBSImjJOV635oReWp6qv3O2CikB99PBk5vrMpnltD1yWQLcjn/7zJc1Ht2FjIX/r
# xcLkHJG+JDK5A+T2Vnq5bACfBKRK6PE7rS+Rk/zqYL4W28Mu2ifahbtmviCae0dZ
# 4WfNyzv7sBv+1G3NdsiLOf7ihohgCSLipLHqUabl2VY8+7mwrpnlvz9Nd6ehu0/N
# DHXZ9s6pLY4Gwx1cmczSuRrVzIKKRPUmmKVCjAKeeTyF0UHGv+6/UWuZSk9rDG10
# llXLU8Pm/NpmucCjw3QZ0kDA+1OU69Z3F7Jz/M0AVMLkeP2y2GVe5hkGyoAr6jIE
# u/CFgZFhRDO3Sj08OuIB7uUtaUOhZd+e0TONkxx2ygm70QBOpYmDvL15YV3W3hV9
# dkgQa1ZvW/DK12Rfas5yLqTDUN9w6Mmvg45dN3PCGZ1iumFLiwpk7TPaZRJwXEU0
# LHKqYbIUEYMpH1IIEc8iQoaagF9dHaZ32tEaYZ0C74ziQIIkveAaqf9YRtcSuI1j
# a7XeTFQNZf/W4LSBjFA2ZHJIXQvR1LEvNQMTaymG7TZDsEvyt3m9OhEfcahsATa+
# QT6mrAM9HSthbpgWO7nebPNe5n2Wr+nc
# SIG # End signature block
