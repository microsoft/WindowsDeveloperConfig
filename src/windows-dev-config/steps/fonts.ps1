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
