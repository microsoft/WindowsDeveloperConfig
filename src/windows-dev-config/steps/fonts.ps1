<#
.SYNOPSIS
  Downloads and installs Cascadia Code Nerd Fonts, and sets Cascadia Mono NF as the Windows Terminal default font.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:CascadiaFontVersion     = '2407.24'
$Script:CascadiaWantedFonts     = @('CascadiaCodeNF.ttf', 'CascadiaMonoNF.ttf')
$Script:CascadiaZipSha256       = 'E67A68EE3386DB63F48B9054BD196EA752BC6A4EBB4DF35ADCE6733DA50C8474'
$Script:CascadiaDefaultFontFace = 'Cascadia Mono NF'

function Test-DevConfigCascadiaFontsInstalled {
    $fontsDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regPath   = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $regValues = @(
        (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object Name -notin 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider' |
            Select-Object -ExpandProperty Value
    )
    $filesOk = -not ($Script:CascadiaWantedFonts | Where-Object { -not (Test-Path (Join-Path $fontsDir $_)) })
    $regOk   = -not ($Script:CascadiaWantedFonts | Where-Object { $fn = $_; -not ($regValues | Where-Object { $_ -like "*\$fn" }) })
    return ($filesOk -and $regOk)
}

function Install-DevConfigCascadiaFonts {
    $version = $Script:CascadiaFontVersion
    $zipUrl  = "https://github.com/microsoft/cascadia-code/releases/download/v$version/CascadiaCode-$version.zip"
    $workDir = Join-Path $env:TEMP "CascadiaCode-$version"
    $zipPath = Join-Path $workDir 'CascadiaCode.zip'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    $fontsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regPath  = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    New-Item -ItemType Directory -Path $fontsDir -Force | Out-Null

    Write-Host "Downloading $zipUrl ..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-DevConfigRetry -Name 'Cascadia fonts download' -ScriptBlock {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    }

    $actualHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ne $Script:CascadiaZipSha256) {
        Remove-Item $zipPath -Force
        throw "Hash mismatch for CascadiaCode-$version.zip: expected $($Script:CascadiaZipSha256), got $actualHash"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Drawing

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in $Script:CascadiaWantedFonts) {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) {
                Write-Warning "Not found in archive: $name"
                continue
            }

            $dest = Join-Path $fontsDir $name
            Write-Host "Installing $name -> $dest"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)

            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            try {
                $pfc.AddFontFile($dest)
                $family = $pfc.Families[0].Name
            } finally {
                $pfc.Dispose()
            }

            $regName = "$family (TrueType)"
            New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force | Out-Null
            Write-Host "  registered as '$regName'"
        }
    } finally {
        $zip.Dispose()
    }

    Remove-Item $zipPath -Force
    Write-Host "`nDone. Restart any running apps (terminal, editors) to pick up the new fonts."
}

function Get-DevConfigTerminalSettingsPath {
    # Packaged (MSIX) Terminal first, then the unpackaged/portable location.
    $candidates = @(
        Get-ChildItem "$env:LOCALAPPDATA\Packages" -Filter 'Microsoft.WindowsTerminal*' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    return $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Get-DevConfigTerminalSettingsRaw {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    # Terminal's settings.json is JSONC; strip block and line comments before parsing.
    $raw   = Get-Content -LiteralPath $Path -Raw
    $clean = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
    return [regex]::Replace($clean, '(?m)^\s*//.*$', '')
}

function Get-DevConfigTerminalDefaultFontFace {
    param(
        [Parameter(Mandatory)] [object] $Settings
    )
    # Walk profiles.defaults.font.face defensively: any level may be absent, and strict
    # mode throws on a direct dot-access to a missing property.
    $profilesProp = $Settings.PSObject.Properties['profiles']
    if (-not $profilesProp) { return $null }
    $defaultsProp = $profilesProp.Value.PSObject.Properties['defaults']
    if (-not $defaultsProp) { return $null }
    $fontProp = $defaultsProp.Value.PSObject.Properties['font']
    if (-not $fontProp) { return $null }
    $faceProp = $fontProp.Value.PSObject.Properties['face']
    if (-not $faceProp) { return $null }
    return $faceProp.Value
}

function Test-DevConfigCascadiaDefaultFont {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        return $true
    }
    $settings = Get-DevConfigTerminalSettingsRaw -Path $path | ConvertFrom-Json
    return (Get-DevConfigTerminalDefaultFontFace -Settings $settings) -eq $Script:CascadiaDefaultFontFace
}

function Set-DevConfigCascadiaDefaultFont {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        throw 'Windows Terminal settings.json not found.'
    }
    Write-Host "Using: $path"
    Copy-Item -LiteralPath $path -Destination "$path.bak" -Force

    # Plain ConvertFrom-Json (not -AsHashtable, which needs PowerShell 6+) so this also runs on Windows PowerShell 5.1.
    $json = Get-DevConfigTerminalSettingsRaw -Path $path | ConvertFrom-Json
    if (-not $json.PSObject.Properties['profiles'])               { $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $json.profiles.PSObject.Properties['defaults'])      { $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $json.profiles.defaults.PSObject.Properties['font']) { $json.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) }
    if ($json.profiles.defaults.font.PSObject.Properties['face']) {
        $json.profiles.defaults.font.face = $Script:CascadiaDefaultFontFace
    } else {
        $json.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $Script:CascadiaDefaultFontFace
    }

    $json | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "Set Terminal default font to '$($Script:CascadiaDefaultFontFace)' (backup: $path.bak)"
}

function Invoke-FontsPhase {
    $steps = @(
        New-DevConfigStep -Name 'CascadiaFonts' -Description 'Install Cascadia Code Nerd Fonts' `
            -Check { Test-DevConfigCascadiaFontsInstalled } `
            -Apply { Install-DevConfigCascadiaFonts }
        New-DevConfigStep -Name 'CascadiaDefaultFont' -Description 'Set Cascadia Mono NF as the Windows Terminal default font' `
            -Check { Test-DevConfigCascadiaDefaultFont } `
            -Apply { Set-DevConfigCascadiaDefaultFont }
    )

    Invoke-DevConfigSteps -Steps $steps
}
