<#
.SYNOPSIS
  Apply the Comfort Shell setup and run the WSL bootstrap.
.DESCRIPTION
  Ensures WSL + an Ubuntu distro, runs the bootstrap inside it, and registers
  a Windows Terminal profile. Interactive by default: prompts to confirm each
  step and lets you pick the distro. Pass -NonInteractive to accept all
  defaults (auto-pick distro, forward --non-interactive to the bootstrap).
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$Distro,
    [string[]]$BootstrapArgs = @(),
    [string]$ResumeEncodedArgs
)

$ErrorActionPreference = 'Stop'

# PS 7.4+ may throw on native non-zero exits; we check $LASTEXITCODE manually.
$PSNativeCommandUseErrorActionPreference = $false

# Bootstrap and WT banners are UTF-8; OEM code page produces mojibake.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# Restore params from the previous (pre-reboot) invocation if RunOnce armed us.
if ($ResumeEncodedArgs) {
    try {
        $resumeJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ResumeEncodedArgs))
        $resume     = $resumeJson | ConvertFrom-Json
        if ($resume.PSObject.Properties.Match('NonInteractive').Count -gt 0 -and $resume.NonInteractive) {
            $script:NonInteractive = $true
        }
        if ($resume.PSObject.Properties.Match('Distro').Count -gt 0 -and $resume.Distro) {
            $script:Distro = [string]$resume.Distro
        }
        if ($resume.PSObject.Properties.Match('BootstrapArgs').Count -gt 0 -and $resume.BootstrapArgs) {
            $script:BootstrapArgs = @($resume.BootstrapArgs | ForEach-Object { [string]$_ })
        }
        Write-Host "  (Resumed from reboot; restored original arguments.)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  (Could not decode resume state: $_)" -ForegroundColor DarkYellow
    }
}

$script:CurrentStep = 0

function Set-ConsoleTitle {
    param([string]$Title)
    try { $Host.UI.RawUI.WindowTitle = $Title } catch { }
}

function Step {
    param([string]$Message)
    $script:CurrentStep++
    Write-Host ''
    Write-Host "▶ [$script:CurrentStep/$script:TotalSteps] $Message" -ForegroundColor Cyan
    Set-ConsoleTitle "Comfort Shell · $script:CurrentStep/$script:TotalSteps · $Message"
}

# --- Helpers -----------------------------------------------------------------

function Reset-TerminalInputMode {
    # Disable Win32 Input Mode and focus reporting, then drain queued key events.
    $esc = [char]27
    [Console]::Out.Write("$esc[?9001l$esc[?1004l")
    [Console]::Out.Flush()
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    if ($script:NonInteractive) {
        $auto = if ($Default) { 'yes' } else { 'no' }
        Write-Host "$Prompt $hint $auto (auto; -NonInteractive in effect)" -ForegroundColor DarkGray
        return $Default
    }
    Reset-TerminalInputMode
    while ($true) {
        $answer = (Read-Host "$Prompt $hint").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default      { Write-Host '  Please enter y or n.' -ForegroundColor Yellow }
        }
    }
}

function Get-InstalledWslDistros {
    # Returns the names of Ubuntu distros currently installed in WSL.
    # `wsl -l -q` emits UTF-16LE with NUL bytes; strip them before filtering.
    $raw = (& wsl.exe --list --quiet) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    return @($raw |
        ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ -like 'Ubuntu*' })
}

function Invoke-NativeConsole {
    # Run a native exe attached to the parent console so /dev/tty works in the child.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    # Pre-quote args per CommandLineToArgvW so Start-Process forwards them verbatim on PS 5.1.
    $quoted = foreach ($a in $ArgumentList) {
        if ($a -match '[\s"]') {
            '"' + ($a -replace '\\+(?=")', '$0$0' -replace '"', '\"') + '"'
        } else {
            $a
        }
    }

    $startArgs = @{
        FilePath    = $FilePath
        NoNewWindow = $true
        Wait        = $true
        PassThru    = $true
    }
    if ($quoted.Count -gt 0) {
        $startArgs['ArgumentList'] = (($quoted) -join ' ')
    }

    $proc = Start-Process @startArgs
    Reset-TerminalInputMode
    return $proc.ExitCode
}

function Get-SupportedUbuntuDistros {
    return @(
        [pscustomobject]@{ Name = 'Ubuntu';       FriendlyName = 'Ubuntu (latest LTS)' }
        [pscustomobject]@{ Name = 'Ubuntu-24.04'; FriendlyName = 'Ubuntu 24.04 LTS' }
        [pscustomobject]@{ Name = 'Ubuntu-22.04'; FriendlyName = 'Ubuntu 22.04 LTS' }
        [pscustomobject]@{ Name = 'Ubuntu-20.04'; FriendlyName = 'Ubuntu 20.04 LTS' }
    )
}

function Select-WslDistro {
    param([string]$DefaultName = 'Ubuntu')

    $online = @(Get-SupportedUbuntuDistros)

    Write-Host ''
    Write-Host 'Available Ubuntu distros:' -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    foreach ($d in $online) {
        $marker = if ($d.Name -eq $DefaultName) { ' (default)' } else { '' }
        Write-Host ("  {0,2}) {1,-30} {2}{3}" -f $i, $d.Name, $d.FriendlyName, $marker)
        $i++
    }
    Write-Host ''

    if ($script:NonInteractive) {
        Write-Host "Using default distro: $DefaultName (auto; -NonInteractive in effect)" -ForegroundColor DarkGray
        return $DefaultName
    }

    Reset-TerminalInputMode
    while ($true) {
        $answer = (Read-Host "Pick a distro [$DefaultName]").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultName }

        if ($answer -match '^\d+$') {
            $idx = [int]$answer
            if ($idx -ge 1 -and $idx -le $online.Count) {
                return $online[$idx - 1].Name
            }
        }

        $match = $online | Where-Object { $_.Name -eq $answer }
        if ($match) { return $match.Name }

        Write-Host "  Invalid choice. Enter a number (1-$($online.Count)) or distro name." -ForegroundColor Yellow
    }
}

# --- Step functions -----------------------------------------------------------

function Assert-WindowsTerminal {
    # wt.exe is required: we install a WT profile and resume in wt after reboot.
    if (Get-Command 'wt.exe' -ErrorAction SilentlyContinue) { return }

    Write-Host ''
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host '  Windows Terminal is required but not available on PATH.' -ForegroundColor Red
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host ''
    Write-Host '  The Comfort Shell flow installs a Windows Terminal profile' -ForegroundColor Yellow
    Write-Host '  fragment, so wt.exe must be installed before we proceed.' -ForegroundColor Yellow
    Write-Host ''
    throw 'Windows Terminal (wt.exe) is a required prerequisite for the Comfort Shell flow.'
}

function Test-WslReady {
    if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) { return $false }
    # try/catch covers stubs that bypass `*> $null` via WriteConsoleW.
    try {
        & wsl.exe --status *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Set-ResumeAfterReboot {
    # HKCU RunOnce: re-launches this script (elevated, in wt.exe) at next logon.
    param([Parameter(Mandatory)][string]$ScriptPath)

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Host "  (Could not register auto-resume: script path missing: $ScriptPath)" -ForegroundColor DarkYellow
        return
    }

    $escapedPath = $ScriptPath -replace "'", "''"

    # Round-trip the original args via base64-JSON so they survive RunOnce -> wt -> powershell -File.
    $resumePayload = @{}
    if ($script:NonInteractive) { $resumePayload['NonInteractive'] = $true }
    if (-not [string]::IsNullOrEmpty($script:Distro)) { $resumePayload['Distro'] = [string]$script:Distro }
    if ($script:BootstrapArgs -and @($script:BootstrapArgs).Count -gt 0) {
        $resumePayload['BootstrapArgs'] = @($script:BootstrapArgs | ForEach-Object { [string]$_ })
    }

    $resumeArgs = ''
    if ($resumePayload.Count -gt 0) {
        $resumeJson = $resumePayload | ConvertTo-Json -Compress -Depth 4
        $resumeB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($resumeJson))
        $resumeArgs = " -ResumeEncodedArgs $resumeB64"
    }

    # Encode the launcher so it survives RunOnce -> powershell -> wt.exe.
    $launcherScript = @"
Start-Process -FilePath 'wt.exe' -ArgumentList 'new-tab --title "Comfort Shell Setup" powershell.exe -NoExit -ExecutionPolicy Bypass -File "$escapedPath"$resumeArgs'
"@
    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($launcherScript)
    $encoded = [Convert]::ToBase64String($bytes)

    $cmd = "powershell.exe -NoProfile -EncodedCommand $encoded"

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    Set-ItemProperty -Path $key -Name 'ComfortShellResume' -Value $cmd -Force

    Write-Host '  Auto-resume registered: this script will re-launch in Windows Terminal at next login.' -ForegroundColor DarkGray
}

function Clear-ResumeAfterReboot {
    Remove-ItemProperty `
        -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
        -Name 'ComfortShellResume' `
        -ErrorAction SilentlyContinue
}

function Install-WslPlatform {
    # Installs the WSL platform only (no distro). Always requires a reboot; caller must return.
    Write-Host ''
    Write-Host 'WSL is not installed on this machine.' -ForegroundColor Yellow
    Write-Host 'WSL is required to run the Comfort Shell bootstrap.' -ForegroundColor Yellow
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Would you like to install WSL now?' -Default $true)) {
        Write-Host ''
        Write-Host 'Skipping WSL installation. The Comfort Shell flow requires WSL,' -ForegroundColor Yellow
        Write-Host 'so nothing was changed on this machine.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'To install WSL manually:  wsl --install --no-distribution' -ForegroundColor Yellow
        Write-Host 'Then re-run this script.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Installing WSL platform...' -ForegroundColor Cyan
    $wslExit = Invoke-NativeConsole -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution')
    Write-Host ''

    if ($wslExit -ne 0) {
        # Skip auto-resume on failure so a reboot doesn't repeat the same error.
        Write-Host '---------------------------------------------------------------' -ForegroundColor Red
        Write-Host "  WSL installation failed or was cancelled (exit code $wslExit)." -ForegroundColor Red
        Write-Host ''
        Write-Host '  Review the output above for the underlying error, then re-run' -ForegroundColor Yellow
        Write-Host '  this script. To install WSL by hand:' -ForegroundColor Yellow
        Write-Host '    wsl --install --no-distribution' -ForegroundColor Yellow
        Write-Host '---------------------------------------------------------------' -ForegroundColor Red
        Write-Host ''
        return
    }

    Write-Host '---------------------------------------------------------------' -ForegroundColor Green
    Write-Host '  WSL platform installed! A reboot is required.' -ForegroundColor Green
    Write-Host '' -ForegroundColor Green
    Write-Host '  After rebooting, this script will auto-resume to pick a' -ForegroundColor Green
    Write-Host '  Linux distro and finish setup.' -ForegroundColor Green
    Write-Host '---------------------------------------------------------------' -ForegroundColor Green
    Write-Host ''

    # Arm auto-resume so a manual reboot still picks up where we left off.
    Set-ResumeAfterReboot -ScriptPath $PSCommandPath

    if (Read-YesNo -Prompt 'Reboot now?' -Default $true) {
        Write-Host 'Rebooting in 10 seconds... (Ctrl+C to cancel)' -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Host 'Reboot when ready; the script will resume automatically after you log in.' -ForegroundColor Yellow
    }
}

function Install-NewDistro {
    param([string]$Name)

    $maxAttempts = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host ''
        if ($attempt -eq 1) {
            Write-Host "Installing $Name..." -ForegroundColor Cyan
        } else {
            Write-Host "Installing $Name (attempt $attempt of $maxAttempts)..." -ForegroundColor Cyan
        }

        $exitCode = Invoke-NativeConsole -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $Name, '--no-launch')
        Write-Host ''

        if ((@(Get-InstalledWslDistros)) -contains $Name) { return $Name }

        if ($attempt -lt $maxAttempts) {
            $delay = if ($attempt -eq 1) { 5 } else { 15 }
            Write-Host "  Install failed (exit code $exitCode). Retrying in $delay seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
    }

    Write-Host ''
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host "  Failed to install '$Name' after $maxAttempts attempts." -ForegroundColor Red
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Common causes:' -ForegroundColor Yellow
    Write-Host '    - DNS failure (Wsl/InstallDistro/WININET_E_NAME_NOT_RESOLVED)'
    Write-Host '    - Corporate proxy or firewall blocking the WSL distro download'
    Write-Host '    - VPN dropping the connection mid-transfer'
    Write-Host '    - Temporary outage on the Microsoft endpoint'
    Write-Host ''
    Write-Host '  To retry, run this script again:' -ForegroundColor Yellow
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { 'install.ps1' }
    Write-Host "    powershell.exe -File `"$scriptPath`""
    Write-Host ''
    return $null
}

function Select-ExistingOrInstallDistro {
    param([string[]]$Existing)

    Write-Host ''
    Write-Host 'Existing WSL distros:' -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    foreach ($d in $Existing) {
        Write-Host ("  {0,2}) {1}" -f $i, $d)
        $i++
    }
    $newOption = $Existing.Count + 1
    Write-Host ("  {0,2}) Install a new distro" -f $newOption) -ForegroundColor DarkGray
    Write-Host ''

    if ($script:NonInteractive) {
        Write-Host "Using existing distro: $($Existing[0]) (auto; -NonInteractive in effect)" -ForegroundColor DarkGray
        return $Existing[0]
    }

    Reset-TerminalInputMode
    while ($true) {
        $answer = (Read-Host "Pick a distro [$($Existing[0])]").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Existing[0] }

        if ($answer -match '^\d+$') {
            $idx = [int]$answer
            if ($idx -ge 1 -and $idx -le $Existing.Count) {
                return $Existing[$idx - 1]
            }
            if ($idx -eq $newOption) {
                $online = Select-WslDistro -DefaultName 'Ubuntu'
                return Install-NewDistro -Name $online
            }
        }

        if ($Existing -contains $answer) { return $answer }

        Write-Host "  Invalid choice." -ForegroundColor Yellow
    }
}

function Resolve-Distro {
    $existing = @(Get-InstalledWslDistros)

    if ($Distro) {
        if (-not ($Distro -like 'Ubuntu*')) {
            throw "Comfort Shell currently supports Ubuntu only. Requested: '$Distro'."
        }
        if ($existing -contains $Distro) {
            Write-Host "Using requested distro: $Distro" -ForegroundColor Cyan
            return $Distro
        }
        Write-Host "Requested distro '$Distro' is not installed; installing it..." -ForegroundColor Cyan
        return Install-NewDistro -Name $Distro
    }

    if ($existing.Count -eq 0) {
        Write-Host ''
        Write-Host 'No Ubuntu distros found. Pick one to install:' -ForegroundColor Yellow
        $online = Select-WslDistro -DefaultName 'Ubuntu'
        return Install-NewDistro -Name $online
    }

    return Select-ExistingOrInstallDistro -Existing $existing
}

function Get-WslDefaultUser {
    # Registry probe first to avoid cold-starting WSL (and triggering OOBE) on fresh distros.
    param([string]$DistroName)

    $lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $lxssRoot)) { return '' }

    $uid = $null
    foreach ($entry in Get-ChildItem -LiteralPath $lxssRoot -ErrorAction SilentlyContinue) {
        $props = Get-ItemProperty -LiteralPath $entry.PsPath -ErrorAction SilentlyContinue
        if ($props -and $props.DistributionName -eq $DistroName) {
            if ($null -ne $props.DefaultUid) { $uid = [int]$props.DefaultUid } else { $uid = 0 }
            break
        }
    }

    if ($null -eq $uid) { return '' }
    if ($uid -eq 0) { return 'root' }

    # Resolve the non-root UID to a username.
    $raw = ((& wsl.exe -d $DistroName -- whoami) 2>$null) -replace "`0", ''
    $line = ($raw | Where-Object { $_ } | Select-Object -First 1)
    if ($line) { return $line.Trim() }
    return ''
}

function Invoke-ComfortShellBootstrap {
    param([string]$DistroName)

    $bootstrapScript = Join-Path $PSScriptRoot 'comfort-shell-bootstrap.sh'
    if (-not (Test-Path -LiteralPath $bootstrapScript)) {
        throw "Bootstrap script not found: $bootstrapScript"
    }

    # Stage to local temp so WSL can read the script regardless of source drive.
    $stagedScript = Join-Path $env:TEMP ("comfort-shell-bootstrap-" + [guid]::NewGuid().ToString('N') + ".sh")
    Copy-Item -LiteralPath $bootstrapScript -Destination $stagedScript -Force

    try {
        $escapedForBash = $stagedScript -replace "'", "'\''"
        $wslpathCmd = "wslpath -u '$escapedForBash'"
        $rawWslPath = ((& wsl.exe -d $DistroName bash -c $wslpathCmd) 2>$null) -replace "`0", ''
        $wslScriptPath = $rawWslPath | Where-Object { $_ } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($wslScriptPath)) {
            throw "wslpath could not convert '$stagedScript' inside '$DistroName'."
        }
        $wslScriptPath = $wslScriptPath.Trim()

        $bsArgs = @()
        if ($NonInteractive) { $bsArgs += '--non-interactive' }
        $bsArgs += $BootstrapArgs
        $quotedArgs = ($bsArgs | ForEach-Object { "'$($_ -replace "'", "'\''")'" }) -join ' '

        Write-Host ''
        Write-Host '--- Running Comfort Shell bootstrap in WSL... ---' -ForegroundColor Cyan
        Write-Host ''

        $wslScriptPathQuoted = "'" + ($wslScriptPath -replace "'", "'\''") + "'"

        $bashCmd = "set -euo pipefail; cp $wslScriptPathQuoted ~/comfort-shell-bootstrap.sh && sed -i 's/\r$//' ~/comfort-shell-bootstrap.sh && chmod +x ~/comfort-shell-bootstrap.sh && ~/comfort-shell-bootstrap.sh $quotedArgs"
        $bootstrapExit = Invoke-NativeConsole -FilePath 'wsl.exe' `
            -ArgumentList @('-d', $DistroName, '--', 'bash', '-lc', $bashCmd)
        if ($bootstrapExit -ne 0) {
            throw "Comfort Shell bootstrap failed inside '$DistroName' (exit code $bootstrapExit). Review the output above and re-run this script."
        }
    }
    finally {
        Remove-Item -LiteralPath $stagedScript -Force -ErrorAction SilentlyContinue
    }
}

function Install-NerdFont {
    $ErrorActionPreference = 'Stop'

    $Version     = '2407.24'
    $WantedFonts = @('CascadiaCodeNF.ttf', 'CascadiaMonoNF.ttf')

    # Skip if all font files and registry entries are already present
    $fontsDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regPath   = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $regValues = @(
        (Get-ItemProperty $regPath -EA SilentlyContinue).PSObject.Properties |
        Where-Object Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' |
        Select-Object -ExpandProperty Value
    )
    $filesOk = -not ($WantedFonts | Where-Object { -not (Test-Path (Join-Path $fontsDir $_)) })
    $regOk   = -not ($WantedFonts | Where-Object { $fn = $_; -not ($regValues | Where-Object { $_ -like "*\$fn" }) })
    if ($filesOk -and $regOk) {
        Write-Host "Nerd fonts already installed; skipping."
        return
    }

    $zipUrl  = "https://github.com/microsoft/cascadia-code/releases/download/v$Version/CascadiaCode-$Version.zip"
    $workDir = Join-Path $env:TEMP "CascadiaCode-$Version"
    $zipPath = Join-Path $workDir 'CascadiaCode.zip'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    New-Item -ItemType Directory -Path $fontsDir -Force | Out-Null

    Write-Host "Downloading $zipUrl ..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

    $expectedHash = 'E67A68EE3386DB63F48B9054BD196EA752BC6A4EBB4DF35ADCE6733DA50C8474'
    $actualHash   = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        Remove-Item $zipPath -Force
        throw "Hash mismatch for CascadiaCode-$Version.zip: expected $expectedHash, got $actualHash"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Drawing

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in $WantedFonts) {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) { Write-Warning "Not found in archive: $name"; continue }

            $dest = Join-Path $fontsDir $name
            Write-Host "Installing $name -> $dest"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)

            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            try {
                $pfc.AddFontFile($dest)
                $family = $pfc.Families[0].Name
            } finally { $pfc.Dispose() }

            $regName = "$family (TrueType)"
            New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force | Out-Null
            Write-Host "  registered as '$regName'"
        }
    }
    finally {
        $zip.Dispose()
    }

    Remove-Item $zipPath -Force
    Write-Host "`nDone. Restart any running apps (terminal, editors) to pick up the new fonts."
}

function Install-TerminalProfile {
    param([string]$DistroName)

    $fragmentsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ComfortShell'
    New-Item -ItemType Directory -Path $fragmentsDir -Force | Out-Null

    # Per-distro file + GUID so multiple distros produce coexisting profiles.
    $slug = (($DistroName -replace '[^a-zA-Z0-9]+', '-').Trim('-')).ToLower()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'default' }
    $fragmentFile = Join-Path $fragmentsDir "comfort-shell-$slug.fragment.json"

    $sunglasses = [string]::new(@([char]0xD83D, [char]0xDE0E))

    # Deterministic GUID per distro: re-runs update in place, different distros coexist.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("comfort-shell:$DistroName"))
    } finally {
        $md5.Dispose()
    }
    $profileGuid = "{$([guid]::new($hashBytes).ToString().ToLower())}"

    $fragment = @{
        profiles = @(
            @{
                guid            = $profileGuid
                name            = "Comfort Shell - $DistroName"
                icon            = $sunglasses
                commandline     = "wsl.exe -d $DistroName"
                startingDirectory = '~'
                colorScheme     = 'Comfort Shell Dark'
                cursorShape     = 'bar'
                hidden          = $false
                font            = @{
                    face = 'Cascadia Mono NF'
                    size = 13
                }
            }
        )
        schemes = @(
            @{
                name            = 'Comfort Shell Dark'
                background      = '#1E1E2E'
                foreground      = '#CDD6F4'
                cursorColor     = '#A6E3A1'
                selectionBackground = '#45475A'
                black           = '#45475A'
                red             = '#F38BA8'
                green           = '#A6E3A1'
                yellow          = '#F9E2AF'
                blue            = '#89B4FA'
                purple          = '#CBA6F7'
                cyan            = '#94E2D5'
                white           = '#BAC2DE'
                brightBlack     = '#585B70'
                brightRed       = '#F38BA8'
                brightGreen     = '#A6E3A1'
                brightYellow    = '#F9E2AF'
                brightBlue      = '#89B4FA'
                brightPurple    = '#CBA6F7'
                brightCyan      = '#94E2D5'
                brightWhite     = '#A6ADC8'
            }
        )
    }

    $fragment | ConvertTo-Json -Depth 8 | Out-File -FilePath $fragmentFile -Encoding Utf8

    # Touch settings.json to trigger WT's hot-reload (re-scans Fragments\*.json).
    $settingsCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $nudged = $false
    foreach ($settingsPath in $settingsCandidates) {
        if (Test-Path -LiteralPath $settingsPath) {
            try {
                (Get-Item -LiteralPath $settingsPath).LastWriteTime = Get-Date
                $nudged = $true
            } catch {
            }

        }
    }

    Write-Host ''
    Write-Host '--- Windows Terminal profile installed ---' -ForegroundColor Cyan
    Write-Host "  Profile: Comfort Shell - $DistroName" -ForegroundColor Green
    Write-Host "  Distro:  $DistroName"
    Write-Host "  File:    $fragmentFile" -ForegroundColor DarkGray
    Write-Host ''
    if ($nudged) {
        Write-Host '  Open Windows Terminal: the new profile is available in the dropdown.' -ForegroundColor Green
    } else {
        Write-Host '  Restart Windows Terminal to see the new profile.' -ForegroundColor Yellow
    }
}

# --- Main flow ---------------------------------------------------------------
# Steps: WSL platform + distro + bootstrap + nerd fonts + WT profile
$script:TotalSteps = 5

Assert-WindowsTerminal
Clear-ResumeAfterReboot

Step "Ensuring WSL platform"
if (-not (Test-WslReady)) {
    Install-WslPlatform
    return
}

Step "Choosing Ubuntu distro"
$Distro = Resolve-Distro
if (-not $Distro) { return }

# Capture BEFORE bootstrap so the final message reflects the original state.
$preBootstrapUser = Get-WslDefaultUser -DistroName $Distro

Step "Running Comfort Shell bootstrap in $Distro"
Invoke-ComfortShellBootstrap -DistroName $Distro

Step "Installing Cascadia Code Nerd Fonts"
Install-NerdFont

Step "Installing Windows Terminal profile"
Install-TerminalProfile     -DistroName $Distro

Set-ConsoleTitle "Comfort Shell · ready"

Write-Host ''
Write-Host '---------------------------------------------------------------' -ForegroundColor Green
$sun = [string]::new(@([char]0xD83D, [char]0xDE0E))
Write-Host "  $sun Comfort Shell install complete" -ForegroundColor Green
Write-Host '---------------------------------------------------------------' -ForegroundColor Green
if ($preBootstrapUser -eq 'root' -or [string]::IsNullOrWhiteSpace($preBootstrapUser)) {
    Write-Host ''
    Write-Host '  First Terminal launch will:' -ForegroundColor Cyan
    Write-Host "    1. Prompt you to create a UNIX username and password for $Distro"
    Write-Host '    2. Drop you into zsh with your dotfiles already in place'
    Write-Host '    3. Install Homebrew (a few minutes, one-time)'
    Write-Host ''
    Write-Host "  Open the 'Comfort Shell $sun ($Distro)' profile in Windows Terminal to begin." -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host "  Open the 'Comfort Shell $sun ($Distro)' profile in Windows Terminal." -ForegroundColor Yellow
    Write-Host "  You're already a regular user ($preBootstrapUser); no further setup needed." -ForegroundColor DarkGray
}
Write-Host ''


# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBlsVwey9uvyG+H
# mstPZGLtaqX2YB9FDf3ft/cVnI3LU6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnlMIIZ4QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEID1qFL79
# qY5blnKC1x9hLorlq6kvzyyU40JrWExwVb2ZMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAdaQpFZoAgZx6vz1YN4b2ViPOcSPXRDfkbbfB2F4e
# jGKn3+hzCSjwFE8oVrDL3wV+I3NQMPm7eNszNApwTF2NgT+xlVih4up4tlfhHi1d
# TWNmSICBjVUAj6iae3ynrFjU7RUuIae+K9MBU8QYMXJO+MwJlskdAHBBAmolTHDL
# jaH4ma4l2lziH831/femtoG7YPWpkzietvSHVQ4rykL2P+fVoogB6UTIH243R1vn
# KI0AAaeuKvqDQhouU/Yk8dbZ+FbAr6EY1DJMAQot/4fwhFOiZAbnva6rnImkhnft
# 6LzMVTR9OJEC4vSAx9YG3GPnGeS7Zti0pdOGk+tyk4XQ76GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCCAK799EYDI3LMm+YW3mMEmErPW1qg49kyTrE0T
# JqTm9QIGakfudnfbGBMyMDI2MDcwOTIzMTA0My45NTNaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiNP2WAkU8/+KwABAAAC
# IzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTdaFw0yNzA1MTcxOTM5NTdaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCK6Q2nk5WUdKzSCSafp+UjUARs
# WxHKS63rJhFC/zSabFumTBuaJ0QNrmqevub5Db7fSj5qtwwKnjIO92+HXF67192f
# ujL7DFot5WEj/AtEZ/XrzFHimKlN1h6gEQwP5I67wizaPW5ZzSBNpaLBg5oHvASP
# OZtwdNUoZ+DQKF3hJl1KZuoIlVK+qi7cLjgak6s5oOZcRCMrKnuC3aoVa6wRDbYv
# KUuj7rkFx9KO0PsHJ/k+LnZMggRheh4AVdawyh+oOzKPjlQGUNfSeWUgym2U9CLa
# 8tt0mQX4DxDz6+ram50gj1oAfyQ6TQ7r96PADFOKBgaU7+cpHnaZG89dTegQ6ydB
# RGIycOw1dRX2eKDRRzziK3cn0WaIm/7OeGsyQKjIzEQuUTDv0Jj/9zQ7truLOOpJ
# D98BJVOK7je84Sz2hb3HvUST7j1j2N8peD6olkpFHR/1Z8Jz4F+mkrUF7MmPAirY
# HRzunbIg3HrDMNwFYN7yBkDA4/VMo9CY0y9oGUoq2yjbCwTibz9VYl93nB3QQiTC
# T9nW3M+TOWB+PMrZpExq1BSHmKPzIqehKqrUDoM33PK+dEKwpYLET6uXq4HuQRMX
# WT//sPubUnQAaaUMfQhAZSy23HtxwtN3eK9+T4wCav2wQFt57eUOwUW5/DCzMF9t
# ua5He1hNvgcAXaiG1wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNbAh89v29nPY9bw
# Qb1QYCzxVgeXMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCHQwe7z5tp4NZwAf1c
# B+4c9J4svw3P6WqGBMxtqznS6DdzUzStXHCaPZhM41g1iKHNnmcnLjwLujOEaNjh
# SnUDiAZqQjW5ZapOBxgc7Egghh9k+r78qWAe3rJ4QohBbhSGdZtKivTRaeRqmnhy
# 8+ThrKhzCeEwaarXJimZwSpdQQUDbheWHeyAxASqultd5KO0m/UFvO03tfepqGXA
# 4tCg/WGECwKqOjJzpRAfPIB6y1HyVrk+vmL5rpEbTwwLOtX7WxFGG8+cYLk9HjaD
# kxraA/HYlKQRx1sdza+w/gulLwgOnByRJKF2rr8M7FNIlwoi6ywFpaNc8A7HewaG
# jgw/tfcE260I1XekGluANI9HnONOYWlI7BKBQbWE2teo6vsQ1Vg8B8rTZSePVdmX
# L1PPqqs3KVdFKM5kYocPCDM+6VL32IV96sESf2T7DjxanpCg2D2UYj4Z1i7cy8U1
# LLDGg55KWs4af2RRBjH2MulHgAmW5obKxiZCDQjRaroJ2XElXUhigE9BzvhCFbT/
# HDY2vpVpl5HnSpcCSxmL5i5lIT/xbAQMI7Luh75Xrm+IslfFWOGOGMlCp+24qEJE
# glXEP7xwsolNdBNndXihhyIefVGlI1DR7xGELiJrk8ifVWYo9XEbEXv/lbvp6F2R
# 2UsnweWckvq0y1HWnLHDqH6dPjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQA4RWFs+kTiZnoZiAj1BtYj8zCNaqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7fpVNzAiGA8y
# MDI2MDcwOTE3MTMyN1oYDzIwMjYwNzEwMTcxMzI3WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDt+lU3AgEAMAoCAQACAgOqAgH/MAcCAQACAhK4MAoCBQDt+6a3AgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAHlZmSRaw7pzDwCEp8iA/skt0HaL
# KJRGRQvW30895bSUuo+vE1UTIjO7SxKh1CVMqvUI6CwljFT+cPcgpYFKS21SKU9J
# UQmiLS/vwHvqHUDmjs+arJVMKXXoUxbO8IWaJVNR03001Kd006WQO/JHvUg3PLmJ
# qiTbpIWly4R2qS7+CXsTPi1l7ByE1tsyZxo4Vy+oVptJmkPEWAyAXpA3rX4mLb+s
# lPuRKbaoX/Raq295Mai6eFNm3FVIdHAJ27WXdMQoQJ/vEHtD1Pw0FADuz/yFY5m1
# sYd7/Cv7lBd6vwU0kOEp2ds4Usu3ffMP7j6XF+lPo+THyYrokFK7VtThQAMxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiNP
# 2WAkU8/+KwABAAACIzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBPc4z2ektlxxOUpyi38/0rBiJK
# EiK+nbQJxkL0sOHpnjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIJbwMywR
# bvcGiynjnwjAqcaD47yYvebKZRAvtEAR5u6zMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIjT9lgJFPP/isAAQAAAiMwIgQgA+lhR3SR
# u/WLXPFwgLDbiBnkJZ7WzC5ZZfzMi+dRQ1owDQYJKoZIhvcNAQELBQAEggIAYF5w
# FzTuAkVz8xGJTGAIvgI5P3M8WA4tjXOrpYfUsmA9w+4vT9Uwc4pr1OrX30gQ+323
# CSWJAT2rTAwEmg9dL8IXyQEUTDgqQfrAAFEaWZUMlTs+u0WTa1DLDXt8JS5WqV6D
# RitFF8fq+WXpMSmmhEVt7aR2t3GbptN1nxupNNjw1a5AkIZIshQ/2/TANwAl5ojJ
# yURfDJ6JOF/qrU1iJg7+KzW4ahBXwHLYcIZ0YjzzMYgUqiNftCpL/nRzOoZIPt1o
# xWadKs5EvRAZzE4HbsZUB9lELTs6/ni3MfuCtgWf7nD3Oh4mld++howr00NzINTB
# y8jsFYaoGiJBbXEuGCDFdyp6wmiEJyf44eAV4QA2Ke4OvkM91HP9fYxODn8QrQYI
# 9qdCdAT99+72NhOsWyFFT7XTku40LwKbTNF+I+RjusUoe3oCrwRLBqOuc/fbVJSF
# JQbevn+go2/cibCbIIENRfTvmO8G0R49ygCrkhTOdjxH95sbazF9HP5stXUdtOcZ
# IWLcFkZdnV2fkTMUBko1EwBtI20QSf4w6OP72VTsZkCNHhqxmRY8qfh35og1uIUr
# 42WFd4EG2x+FahI+S1NG38z5cQ+V/MKulZj2s5fPN46PcmqEtH2RMAOuZM7m0IlG
# gO6GOEzw70i8qo3/6g5BsJR6/i4SVzbJvRoAoWY=
# SIG # End signature block
