<#
.SYNOPSIS
  Installs Cascadia Code Nerd Fonts.
  Sets Cascadia Mono NF as the Windows Terminal default font.
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
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        # Terminal writes settings.json on first launch; no target path means no default font can be verified.
        return (-not (Get-DevConfigTerminalSettingsTarget))
    }
    $settings = Read-DevConfigTerminalSettings -Path $path
    return (Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults', 'font', 'face') -eq $Script:CascadiaDefaultFontFace
}

function Set-DevConfigCascadiaDefaultFont {
    $path = Get-DevConfigTerminalSettingsTarget
    if (-not $path) {
        throw 'Windows Terminal is not installed, so its default font cannot be set.'
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $font     = Resolve-DevConfigJsonBranch -Object $settings -Path 'profiles', 'defaults', 'font'
    Set-DevConfigJsonProperty -Object $font -Name 'face' -Value $Script:CascadiaDefaultFontFace

    Save-DevConfigTerminalSettings -Path $path -Settings $settings
    Write-Host "Set the Windows Terminal default font to '$($Script:CascadiaDefaultFontFace)' in $path"
}

function Invoke-FontsPhase {
    # BestEffort keeps later setup phases running if the font download or settings update cannot complete.
    $steps = @(
        New-DevConfigStep -Name 'CascadiaFonts' -Description 'Install Cascadia Code Nerd Fonts' `
            -Check { Test-DevConfigCascadiaFontsInstalled } `
            -Apply { Install-DevConfigCascadiaFonts } `
            -BestEffort
        New-DevConfigStep -Name 'CascadiaDefaultFont' -Description 'Set Cascadia Mono NF as the Windows Terminal default font' `
            -Check { Test-DevConfigCascadiaDefaultFont } `
            -Apply { Set-DevConfigCascadiaDefaultFont } `
            -BestEffort
    )

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDBHVpqmhFmax+9
# o4HOcq8Ko1Ivs/kbIQhV3Qc7JJ+TiaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIHjFdbJeJIbIUW0jw00k7M8x+PCzoA2oHMJzJfDmBrg/MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAAbTIFR3jvAlOODBT
# VIFtvQQxDqrY4s9LD+DQEhCPJ9FZFnNmC+sBVzJOeNR0qyUEVh/1F/BgPeIKLDSf
# eHNNfRkwfAImTAd6Cu0xCYQxYIoFT9O9CndFClOCiwG8wvTXKghyH3xLzVg1u2G6
# OhGtuhzHpeN+F4Pgl+b5Eni9LwqUSjpQZV/xbq14aomjRzjDLx0V6I5xieeqQaCP
# eAPKe9oNpJjs0Ul5kkHqNOfvBe+Pa2oVvz7lC4B9n0I7vh4/Wdm9qygF+Qgzx1Tm
# oThQ5tFTiErl8qd2W3DSeVKEz8XmJdapUflQkhe0zsNvIDL2MROJY4mW4xM4I/DC
# b60PqKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBe10Uov+gqX2q3
# UEDWg5t40DIXSptiuy5ZlQcdM79XpwIGaohsTIKpGBMyMDI2MDkxNjE4Mjg1OC41
# NDNaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
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
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUA8YrutmKpSrubCaAYsU4pt1Ft8DaggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5VLwMwIhgPMjAyNjA5
# MTYxNTA2NDNaGA8yMDI2MDkxNzE1MDY0M1owdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7lUvAwIBADAHAgEAAgIHaTAHAgEAAgISZTAKAgUA7laAgwIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCgJu3EhdDTz6E8jUY/kwqjO7iCH1x/OHOw1QNw
# CeWc533n3ydbYGH7ndFchGjJpYl+m4x0pL9ArkHfySqS/CrPEW1mOPnFdI+k4Rt4
# IyYaCBQXyZ3RpwE+RVViNSvPonWVajwHAB2b4q1Z0LGuycMubuEP3fnTrr5THztU
# 82trb43LGizJaQGERh4zH+zM3ii1MG6Z8k5dKOtURQBc+1SsrjYPAdjSVkb+AemQ
# Mnu2VXfOs1br6kd1FZ7fsCVdI5G6cwSl3iK3zF/HphRsd9UDI41FacWC4E5JNORX
# dg5cU2KeoJU9QUcPT4bDQ9thyofH6u17x4N6qPTkn/7u0DL4MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIaqaAdBqAPQ6oA
# AQAAAhowDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQg2qrYUE2yD6mVUldEhlf6GI0pvmrxjNyS96S2
# b32uK14wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCdeiHHrbtpKcwB20do
# VU89WHIOH8S7w37uaHcDmemK+zCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACGqmgHQagD0OqAAEAAAIaMCIEICPZyp/VBagmp+sGM1vR
# CFHrU/7umHFPwlePNcFSxsp2MA0GCSqGSIb3DQEBCwUABIICAEN+A7YSQJIV7iLB
# WH/GqWYHpkF9rIxmCnvAP8bzRzS+Kdnkv+Y6NcHJW9EJ2q0C8jZBh0XMLgR5LGAq
# /v0HzgCAlk2sL2rrhrodvHMExFx2oFDOd+hdRuGm8VsFyaV9VxRodacPvV7SarT0
# VdWLN0OtfohJehj9Zqfy6rxddzywOi9UPIpq/aWyn6JFbjF2PGKzig4Y6A6PMvad
# dTyuHIQ0WL+xdtqIsw1TnPBjMUiuVwU24Gp5ZRi6r182JFCClYVbD6fSzLiVjl6a
# 0Q/ehwVvucXVbZq5brGLkgWr67zSgiCFlMReW+kQ5cviS5NkMnj6QGldoCq7+rQH
# c/kGjT3OVabplbf6GXd9/+/fqNvTx4iYLV/ddJhjiXg6wkxK8gYmQz6iZgFzHAJW
# Io4jfaRTXg8vU6AyRIxXbB4uMWQ94cLLLIyCqcJG5D0C6EjJCUvo19tr02lmXpQp
# 7wq49u4WN0ZnBSf/Lc378crfxgbY82oGHKMizVlVrMY2opjVwo3bYGP+n+BxwfR7
# mZ3B+euv9rqjTBZ/K8EU6ZGDJ9NZcRkmW0ciBF92rwRAWsXjhifVMvQxs2p0aKYX
# BzQu5Jbb2++lg9UnlaA4I6uRNmkNJipxcWSSxEwri5MgiKiWPCYyHQi35ubASVbT
# lxI47uX24fisYZ6IK9UVw2ENCRMC
# SIG # End signature block
