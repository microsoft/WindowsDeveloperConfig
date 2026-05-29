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
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEID1qFL79qY5blnKC1x9hLorlq6kvzyyU40JrWExwVb2ZMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAufXlTSgUxGo/S9te
# Qn7uGVA2l1vT5w7oZznL+DQpcISQbncO6p0bw89+Q2F5LFl0dGRa5WL2X4lP+Spz
# 6fnk9i/BGPkgdvjG96cn4dHE9yItQg4/6b9rsew1kAFiydNaoWQZj05CC5m8Mtob
# RFkMolkPLa9zfA5hyaLf2vOmmLq0A8S6R08VvC3wKw6l9VqE9OSKDw/PCUCt4TJc
# zN7zYkGSsBWNUj6/mYc3M4PBJJT3fUkjsQ0zkMuFPP9YLi0AZdCzzWN8Gr09mZFy
# pyZ7nkfR0ugEpgYJ0U7w6A3T3P7+XtHnwwXmSVAuNraJSb6M82goeLkPsi6dEla8
# CGVbCqGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCYvm5Y4fKLo4ZB
# IojZHT9yKjlUeHdeR/cLeQ+jkxVY4QIGahGqhIHQGBMyMDI2MDUyNzIyMTc1Ny4y
# NTZaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACHAlVFdfDWQfRAAEAAAIcMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgzMVoXDTI2MTEx
# MzE4NDgzMVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZGMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAow0xEAUaFIyyLIXeFzeI8IKyBON2u0Dr02ISE5p9G5CU
# XfnFu2S0E1gWCMvDWpopX6lRxjmgnqaL3BtnWlBVTo8xUNRZu23ie4YBMAJB7Ut6
# mnqnHVwvDJxGO4TD3SnrCd+yg35B9QFejq3o4+OByvXjynaypZyukcQaLsKQvoxE
# 8ElHH7zcOXEJWmU3rnXzaW/S4SH3OPhoUbTTcy6nUgKx5pRWiQ24UEPLYzcxGJjq
# jkz+GiCWGPFHDMdW86laWvmCslouQPsN2eBk8dxJcEZmW4l6p4TthoXcfexEA9Yd
# YaMz10aMhZNpdsNaDtDQUMDEC3k1D1My69MXSPlUmD9xFyDlkXiVa7BCEp3XcVtq
# TgzHGwr28JD6oE7zEPYeuZOiuCBXTZSo/wk3tbDlsESbIPV6inYqrzxiMYqlxfCd
# zC3Cimh9/NT/Lk9/aU+Iyyc9b3OaT0dZ8wgLaVDCGELRMrqyImdFHv0MudctzW/k
# PsV3Ja9ufpKWujEiN3CW//X8hFa9j5ImNeQzcMit3MoSaoGwnbiZJX1IyibIphlq
# ccXFk4oTTSOQBsAUw8U0gwOnM5UJD8mBUBd65Np6NBkx2cviJ4I34GyXFCWyy5Ft
# 1QsBYyVfAG3KOhCfPHQf8lQzJvLr57YW0bD/xVs4Ag4gTS6KZNyFEfX9jFdRlr0C
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRa3mOCzB8u7zpvDh8MGKVYLCk7ZDAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAklb6w/deaid3BujQCtWFBe0n9pkyRy+yyWEg
# 70iDwoJ5u0e0O+4GerNzdZb1zTPsHJ8EGMyo1K7ytL21+pmdFMTl19PC8OJ5Y2p+
# XKUQy2dD+hggRMmJgDQsgbOCxHYeO+jg4t+vg61wUrovzzLkH3z0PJXXvoNuBj9L
# da9CiNMd60451Kube99ArSf6ZMj3t0p4rFbgSazDs+8TJ+8KA5GVaYjPHj9rlMuI
# 3WjohEc9apnQ6hMjMck3jlHZIwluVYeUQE0qjmApfMtTAEzbMUdY8sLTunL1GkbD
# SeKn9O7llBGnNtyM1uM9Mdv1VyWh0z/IriQKIjntqqGyoF0HvDHOFZCyUDBPLfly
# iu7Y1zQ/sPounsb96aBfQdq3h3LOn6t+m9EnNz/G6MzzWvpJk6YgTHTIqeQN/F/X
# piPvbfek3nq/PYbL3au+kBfRUHiCFXSvt6lor0HC626vUmz9ZNPOxwEWLuccomxs
# y3JwWH79vsM/7ARqoG5h6d6NahfaOuRP4XI9xtdH3Pa/NCLyQjxKXyLxzwQzjddk
# X2EpTJnlypuhPmEdea59Uz2E303LxyXSnKBvGsAnyWYAfnejr3YAiL9YrN2l2dn1
# 98RpA4DCm9QtZYiwC0q2fuUvui34PfPIUZByf7wHuuWu50hY9WLx1kOMI8xyo7AI
# 6TaNrnIwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
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
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAWmTiA01u5mxq/nVxiRJLMOskVGeggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO3BbpMwIhgPMjAyNjA1
# MjcxMzIyMjdaGA8yMDI2MDUyODEzMjIyN1owdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7cFukwIBADAHAgEAAgIL5jAHAgEAAgIb0DAKAgUA7cLAEwIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQDJIT51byDxHjsvVxpOSGwMc2mHjCLoAMyZ8ujV
# vmHoQ2nfdnXZI39zr4NE2XQEGSLHD3tFQ321Pl6IdVEclmLUgGwm786UbFm7feZB
# TN7I7TY15/zYxfi0Ndn5muhFvqe/aWIB2DuVlizNHCde9tSeAPZra+1yfXNJQeaV
# ZDNzEWmpcoolOHdWVYOrCZ+uWdnRILhVRYLq2pLk4AKRT3GfHxWuRoMWG/eovDJb
# Ujh2KbbZ2N8Z1nura+Uw8cVdGuYRYu5E/P4ngdFmpFOIfianj8VeMG7itmAEQJJv
# p++IHy30F1QU0Py5AN+hCq2a0RjiKJefUe39GXOqNCszlUGfMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIcCVUV18NZB9EA
# AQAAAhwwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgqVwuoJZd6/MCBiandoKEAMG5joAfaNXLdM9M
# Ne+JVb8wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCgIGkmNhdo7+KE7dWh
# I+E2Ctx2RLWoYvvJodCIciHHaDCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACHAlVFdfDWQfRAAEAAAIcMCIEIF+66Xi45FtuLKFYCVhI
# 3x54IFvTEka3Ng7/W1kyX0vfMA0GCSqGSIb3DQEBCwUABIICADjXJ78UjcPivawz
# sM8iIwKP7GpbwxWfK1kb7hTDTbTF2b2NzXakjCQh2zxng2jO+u3FaMEpigl6SytD
# vqtYDL62oDPhNEqOe4HwiDUvm38iecb7DI3nGxR9EJuGHnZjjjeWfct+6Mo+eHoE
# vGxrkxhEG+pTyGzCAOu05HjDFbZe8vv5KCbt6qXGNlHa6PQTo4NS5SmLkXQ6/VSc
# 2hR5ShGva7QSG1b3Kb0295bnM6Z6MS48UaDmZnbgtdn8I403hp1IKaMLqDZq7DpT
# 7Q+jj/SpI2LZchVuzCRj/x4R1dYfd3OiRQCvWO/BOp/kfYpYvBkorfvnEj+KFzPK
# 0U5KKIWtvHtGG0fZmz1ZoRKf0PpPEm0JeU0iOtfR1MTEElTlJ4BA78ebaVfIz0kO
# TAqbZsRcmIUqI7D9g/lUu/BblA0M4r9eevoVqzD74xMGjF4lnYKedwXI90L2AmH8
# 5az5bkNVdOll6C43apinl5jVz+dL8S/u56zS+UcRNfCfd+AFYqRZZ/BQdeKDBEfL
# jCk6OnIWjOeMSJ/ceI/1FH/ocFJoKJKhzeD619yJukyIfj6/mA4vOunfkO1/SZvN
# +ccAsOQF3iRY9fPltNL9L1VaVtezuAPUU/gT48xfZgjfC7Ly34fa5TlhM/ucTQ01
# jyw9InPlma02hDO1gqNydo7jrAAj
# SIG # End signature block
