<#
.SYNOPSIS
  Selects a WinGet front end and installs or queries packages.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Prefer structured module results; use winget.exe when the module is unavailable.
$Script:DevConfigWinGetMode = 'Module'

# Exit codes are stable across locales; console text is not.
$Script:DevConfigWingetNotFound  = -1978335212   # 0x8A150014 no installed package matched
$Script:DevConfigWingetNoUpgrade = -1978335189   # 0x8A15002B already at the latest applicable version

# Update the version and both official release asset hashes together.
$Script:DevConfigWinGetTargetVersion = [version]'1.29.380'
$Script:DevConfigWinGetAssets = [ordered]@{
    'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' = '65DEA9C01CE08EE7B763366B27C0E651F97DB857C11CA9B9C301826C10092F2E'
    'DesktopAppInstaller_Dependencies.zip' = 'BA875AFE9D190F61218985AC0292A99D1DB710BF93E13C68944CA9D89F0D82D1'
}

function Install-DevConfigWinGetModule {
    Enable-DevConfigModernTls

    # A fresh machine can prompt to install the NuGet provider on first use; bootstrap it non-interactively first.
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
    }
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Register-PSRepository -Default -ErrorAction Stop
    }

    # Retry module download because it is the most network-dependent call in the run.
    Invoke-DevConfigRetry -Name 'WinGet module download' -MaxAttempts 4 -InitialDelaySeconds 10 -ScriptBlock {
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
    }
}

# Safe to call repeatedly: the second call onwards is a no-op once a front end is chosen.
function Initialize-DevConfigWinGet {
    if (Get-Module -Name Microsoft.WinGet.Client) {
        return
    }
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        return
    }

    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
        try {
            Import-Module -Name Microsoft.WinGet.Client -ErrorAction Stop
            $Script:DevConfigWinGetMode = 'Module'
            return
        } catch {
            # Reinstall the module if an earlier run left a partial module folder.
            $reason = $_.Exception.Message
            Write-Host '  The WinGet module is installed but did not load -- reinstalling it.' -ForegroundColor Yellow
        }
    }

    Write-Host '  Setting up the WinGet PowerShell module...' -ForegroundColor DarkCyan
    Write-Host '  (First time only. This can take a few minutes.)' -ForegroundColor DarkGray
    try {
        Install-DevConfigWinGetModule
        Import-Module -Name Microsoft.WinGet.Client -ErrorAction Stop
        $Script:DevConfigWinGetMode = 'Module'
        return
    } catch {
        $reason = $_.Exception.Message
    }

    if (-not (Test-DevConfigWingetCliUsable)) {
        throw "The WinGet PowerShell module isn't usable on this machine ($reason), and the built-in winget command isn't working either. Check your internet connection or proxy settings, then run this again."
    }

    Write-Host '  Using the built-in winget command instead.' -ForegroundColor Yellow
    Write-Verbose "WinGet module unavailable: $reason"
    $Script:DevConfigWinGetMode = 'Cli'
}

function Invoke-DevConfigWinGetDeployment {
    param(
        [string] $Directory = ''
    )

    # Keep Appx operations in Windows PowerShell to avoid dependency-array remoting issues.
    $deployment = {
        param([string] $Directory)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        try {
            if ($Directory) {
                $architectures = switch ([Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')) {
                    'AMD64' { 'x64'; 'x86' }
                    'ARM64' { 'arm64'; 'x64'; 'x86' }
                    'x86'   { 'x86' }
                    default { throw 'Unsupported Windows architecture for WinGet deployment.' }
                }
                $dependenciesRoot = Join-Path $Directory 'Dependencies'
                Expand-Archive -LiteralPath (Join-Path $Directory 'DesktopAppInstaller_Dependencies.zip') `
                    -DestinationPath $dependenciesRoot -ErrorAction Stop
                $dependencies = @(
                    foreach ($architecture in $architectures) {
                        $packages = @(Get-ChildItem -LiteralPath (Join-Path $dependenciesRoot $architecture) -Filter '*.appx' -File)
                        if (-not $packages.Count) {
                            throw "WinGet dependencies are missing for $architecture."
                        }
                        $packages.FullName
                    }
                )
                $bundle = Join-Path $Directory 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
                Add-AppxPackage -Path $bundle -DependencyPath $dependencies -ForceTargetApplicationShutdown -ErrorAction Stop
            } else {
                $package = Get-AppxPackage -Name Microsoft.DesktopAppInstaller |
                    Sort-Object Version -Descending | Select-Object -First 1
                if (-not $package) {
                    $package = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -AllUsers |
                        Sort-Object Version -Descending | Select-Object -First 1
                }
                if (-not $package -or -not $package.InstallLocation) {
                    throw 'No installed App Installer package is available to register.'
                }
                Add-AppxPackage -Register (Join-Path $package.InstallLocation 'AppxManifest.xml') `
                    -DisableDevelopmentMode -ForceTargetApplicationShutdown -ErrorAction Stop
            }
            exit 0
        } catch {
            Write-Error -ErrorRecord $_ -ErrorAction Continue
            exit 1
        }
    }
    $escapedDirectory = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Directory)
    $command = "& { $deployment } '$escapedDirectory'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $shell = Join-Path $env:SystemRoot "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
    $result = Invoke-DevConfigNativeCommand -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds 600
    if ($null -eq $result.ExitCode -or $result.ExitCode -ne 0) {
        throw "WinGet package deployment failed ($($result.ExitCode)): $(([string]$result.Output).Trim())"
    }
    Update-DevConfigSessionPath
}

function Install-DevConfigWinGetRelease {
    Enable-DevConfigModernTls
    $ProgressPreference = 'SilentlyContinue'
    $directory = Join-Path ([IO.Path]::GetTempPath()) "DevConfig-WinGet-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    try {
        $baseUri = "https://github.com/microsoft/winget-cli/releases/download/v$Script:DevConfigWinGetTargetVersion"
        foreach ($asset in $Script:DevConfigWinGetAssets.GetEnumerator()) {
            $path = Join-Path $directory $asset.Key
            Invoke-DevConfigWebRequest -Parameters @{
                Uri = "$baseUri/$($asset.Key)"; OutFile = $path; TimeoutSec = 300
            }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $asset.Value) {
                throw "WinGet release asset failed SHA-256 verification: $($asset.Key)"
            }
        }
        Invoke-DevConfigWinGetDeployment -Directory $directory
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
    }
}

function Confirm-DevConfigWinGetReady {
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        return
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Get-WinGetPackage -Source winget -ErrorAction Stop | Out-Null
            return
        } catch [System.Runtime.InteropServices.COMException] {
            # 0x800706BA means the module could not reach WinGet's RPC server.
            if ($_.Exception.HResult -ne -2147023174) { throw }
            $moduleError = $_.Exception.Message
        }

        if ($attempt -eq 1) {
            Write-Host "  The WinGet module could not connect ($moduleError). Repairing WinGet..." -ForegroundColor Yellow
            try {
                Invoke-DevConfigWinGetDeployment
            } catch {
                Write-Host "  WinGet repair did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    try {
        $listed = Invoke-DevConfigWingetCli -Arguments @('list', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
        if ($listed.ExitCode -ne 0 -and $listed.ExitCode -ne $Script:DevConfigWingetNotFound) {
            throw "winget list failed with exit code $($listed.ExitCode)"
        }
    } catch {
        throw "The WinGet module cannot connect ($moduleError), and winget.exe cannot query packages ($($_.Exception.Message)). Update App Installer from the Microsoft Store, then reopen PowerShell and run setup again."
    }

    Write-Host '  The WinGet module still cannot connect. Using the built-in winget command instead.' -ForegroundColor Yellow
    $Script:DevConfigWinGetMode = 'Cli'
}

# Exit code, not console text: winget output is localized and reformatted between versions.
function Invoke-DevConfigWingetCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    return Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments $Arguments
}

# App Execution Alias stubs can exist without a registered App Installer package, so invoke winget.exe.
function Test-DevConfigWingetCliUsable {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        return (Invoke-DevConfigWingetCli -Arguments @('--version')).ExitCode -eq 0
    } catch {
        Write-Verbose "winget.exe is present but could not run: $($_.Exception.Message)"
        return $false
    }
}

# WinGet reports versions as text with optional prefixes or suffixes, so parse before comparing.
function ConvertTo-DevConfigWinGetVersion {
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Text
    )
    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) {
        return $null
    }
    $build = if ($match.Groups[3].Success) { $match.Groups[3].Value } else { '0' }
    return [version]"$($match.Groups[1].Value).$($match.Groups[2].Value).$build"
}

# winget.exe runs in a fresh process, so it is the only source that reflects an in-place update:
# the module resolves the engine version once and keeps reporting it for the life of this process.
function Get-DevConfigWinGetVersion {
    param(
        [switch] $CliOnly
    )

    # Skip the call when the alias is missing so a bare machine does not log a failed launch.
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        try {
            $result = Invoke-DevConfigWingetCli -Arguments @('--version')
            if ($result.ExitCode -eq 0) {
                $fromCli = ConvertTo-DevConfigWinGetVersion -Text ([string]$result.Output)
                if ($fromCli) {
                    return $fromCli
                }
            }
        } catch {
            Write-Verbose "winget.exe --version could not run: $($_.Exception.Message)"
        }
    }

    if ($CliOnly -or $Script:DevConfigWinGetMode -eq 'Cli') {
        return $null
    }

    try {
        return ConvertTo-DevConfigWinGetVersion -Text ([string](Get-WinGetVersion -ErrorAction Stop))
    } catch {
        Write-Verbose "Get-WinGetVersion failed: $($_.Exception.Message)"
        return $null
    }
}

# Quiet by design: this runs on every invocation, including the follow-up verification.
function Test-DevConfigWinGetTargetVersion {
    # An unreadable version means WinGet is missing or broken, which the update path repairs.
    $current = Get-DevConfigWinGetVersion -CliOnly
    if (-not $current) {
        return $false
    }

    # Store and Windows builds can lead the pinned release; never downgrade them.
    return ($current -ge $Script:DevConfigWinGetTargetVersion)
}

# WinGet can report its previous version briefly after updating itself in place.
function Wait-DevConfigWinGetVersionSettled {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (Test-DevConfigWinGetTargetVersion) {
            return $true
        }
        if ($attempt -eq 1) {
            Write-Host '  (Updated -- just waiting for WinGet to report its new version...)' -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

# Update runs only when the installed version does not meet the pinned target.
function Update-DevConfigWinget {
    $current = Get-DevConfigWinGetVersion
    if ($current) {
        Write-Host "  WinGet $current -> $Script:DevConfigWinGetTargetVersion" -ForegroundColor DarkGray
    }

    Write-Host '  (This can take a few minutes.)' -ForegroundColor DarkGray
    try {
        Install-DevConfigWinGetRelease
        if (Wait-DevConfigWinGetVersionSettled) {
            return
        }
        Set-DevConfigStepUnverified -Reason 'WinGet was updated, but it is still reporting its previous version. Re-run to confirm.'
        return
    } catch {
        Write-Host "  WinGet update did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # If the update fails, winget.exe may still be usable for package operations.
    if (Test-DevConfigWingetCliUsable) {
        Write-Host '  Falling back to the built-in winget command instead.' -ForegroundColor Yellow
        $Script:DevConfigWinGetMode = 'Cli'
    }

    if (Get-DevConfigWinGetVersion) {
        Set-DevConfigStepUnverified -Reason "WinGet could not be updated to $Script:DevConfigWinGetTargetVersion. The version on this machine still works, so the run carries on -- update App Installer from the Microsoft Store when convenient."
    } else {
        Set-DevConfigStepUnverified -Reason 'WinGet could not be updated and is not reporting a version at all. Update App Installer from the Microsoft Store, then run this again.'
    }
}

function Test-DevConfigWingetPackageInstalled {
    param(
        [Parameter(Mandatory)] [string] $Id,
        # Accepts an installed version that has an update, for apps that update themselves.
        [switch] $AnyVersion
    )
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        $listed = Invoke-DevConfigWingetCli -Arguments @('list', '--id', $Id, '--exact', '--accept-source-agreements')
        if ($listed.ExitCode -eq $Script:DevConfigWingetNotFound) {
            return $false
        }
        if ($listed.ExitCode -ne 0) {
            throw "winget list $Id failed with exit code $($listed.ExitCode)"
        }
        if ($AnyVersion) {
            return $true
        }
        # useLatest requires the package to be current, not only installed, so match the module path.
        return -not (Test-DevConfigWingetUpgradeAvailable -Id $Id)
    }

    # EqualsCaseInsensitive avoids ambiguous substring matches.
    $pkg = Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive
    if (-not $pkg) {
        return $false
    }
    if ($AnyVersion) {
        return $true
    }

    # useLatest requires the package to be current, not only installed.
    return -not $pkg.IsUpdateAvailable
}

# winget list exits 0 whether or not an upgrade exists, and every message it prints is localized.
# The package id is the one token in that output that is never translated, so it is what gets matched.
function Test-DevConfigWingetUpgradeAvailable {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    $upgrade = Invoke-DevConfigWingetCli -Arguments @('list', '--id', $Id, '--exact', '--upgrade-available', '--accept-source-agreements')
    if ($upgrade.ExitCode -ne 0) {
        # No listing means nothing to upgrade to; a broken query must not force an endless reinstall.
        return $false
    }
    # @() keeps the count valid when nothing matches; under Set-StrictMode a bare $null has no Count.
    return @($upgrade.Output -split '\r?\n' | Where-Object { $_ -match ('(^|\s)' + [regex]::Escape($Id) + '(\s|$)') }).Count -gt 0
}

function Install-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    Invoke-DevConfigRetry -Name "winget install $Id" -ScriptBlock {
        if ($Script:DevConfigWinGetMode -eq 'Cli') {
            $r = Invoke-DevConfigWingetCli -Arguments @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $Script:DevConfigWingetNoUpgrade) {
                throw "winget install $Id failed with exit code $($r.ExitCode)"
            }
            return
        }

        $result = Install-WinGetPackage -Id $Id -Source winget -Mode Silent -MatchOption EqualsCaseInsensitive
        # NoApplicableUpgrade means the package is already installed and current.
        if (-not $result.Succeeded() -and $result.Status -ne 'NoApplicableUpgrade') {
            throw "winget install $Id failed: $($result.ErrorMessage())"
        }
    }
}

# Get-WinGetPackage catalog reads can lag after install, so wait before checking the result.
function Wait-DevConfigWingetPackageSettled {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $AnyVersion
    )
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (Test-DevConfigWingetPackageInstalled -Id $Id -AnyVersion:$AnyVersion) {
            return
        }
        if ($attempt -eq 1) {
            Write-Host '  (Installed -- just waiting for it to finish registering...)' -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    $state = if ($AnyVersion) { 'installed' } else { 'current' }
    Set-DevConfigStepUnverified -Reason "WinGet reported $Id installed, but its catalog still doesn't list it as $state 15s later. It's on the machine -- re-run to confirm."
}

function Invoke-DevConfigInnoCleanup {
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $Publisher,
        [Parameter(Mandatory)] [ValidateSet('user', 'machine')] [string] $Scope
    )
    $hive = if ($Scope -eq 'user') { 'HKCU' } else { 'HKLM' }
    foreach ($root in @("${hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "${hive}:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $keys = Get-ChildItem -LiteralPath $root -ErrorAction Stop |
            Where-Object { $_.PSChildName -like '*_is1' }
        foreach ($key in $keys) {
            $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if (-not $entry.PSObject.Properties['DisplayName'] -or
                $entry.DisplayName -notin @($DisplayName, "$DisplayName (User)") -or
                -not $entry.PSObject.Properties['Publisher'] -or $entry.Publisher -ne $Publisher) {
                continue
            }
            $command = $entry.PSObject.Properties['UninstallString']
            if (-not $command) {
                throw "The registered $DisplayName uninstaller is missing. Repair its installation and retry."
            }
            $match = [regex]::Match([string]$command.Value, '(?i)^(?:"(?<Path>[^"]+\\unins[0-9]+\.exe)"|(?<Path>[^\s"]+\\unins[0-9]+\.exe))$')
            $path = [Environment]::ExpandEnvironmentVariables($match.Groups['Path'].Value)
            if (-not $match.Success -or $path -notmatch '^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+\\)') {
                throw "The registered $DisplayName Inno uninstaller is not a supported executable path. Repair its installation and retry."
            }
            Invoke-DevConfigCleanupCommand -FilePath $path `
                -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') -Unelevated:($Scope -eq 'user') | Out-Null
        }
    }
}

function Invoke-DevConfigPackageCleanup {
    param(
        [Parameter(Mandatory)] [string[]] $Ids,
        [hashtable] $InnoUninstall,
        [switch] $CheckOnly
    )
    $failures = @()
    $operation = if ($CheckOnly) { 'list' } else { 'uninstall' }
    foreach ($id in $Ids) {
        foreach ($scope in @('user', 'machine')) {
            try {
                if (-not $CheckOnly -and $InnoUninstall) {
                    Invoke-DevConfigInnoCleanup @InnoUninstall -Scope $scope
                }
                $arguments = @($operation, $id)
                if (-not $CheckOnly) {
                    $arguments += '--silent'
                }
                $arguments += '--exact', '--scope', $scope, '--disable-interactivity', '--accept-source-agreements'
                $result = Invoke-DevConfigCleanupCommand -FilePath 'winget.exe' -Arguments $arguments `
                    -SuccessCodes @(0, $Script:DevConfigWingetNotFound) -Unelevated:($scope -eq 'user' -and -not $CheckOnly)
                if ($CheckOnly -and $result.ExitCode -eq 0) {
                    return $false
                }
            } catch {
                $failures += "$id ($scope): $($_.Exception.Message)"
            }
        }

        try {
            $packages = @(Get-AppxPackage -AllUsers -Name $id -ErrorAction Stop)
            if ($CheckOnly) {
                if ($packages.Count -gt 0) {
                    return $false
                }
            } else {
                foreach ($package in $packages) {
                    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                }
            }
        } catch {
            $failures += "$id (MSIX): $($_.Exception.Message)"
        }
    }

    if ($failures.Count -gt 0) {
        throw ($failures -join "`n")
    }
    if ($CheckOnly) {
        return $true
    }
}
