<#
.SYNOPSIS
  Selects a WinGet front end and installs or queries packages.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Prefer structured module results; use winget.exe when the module is unavailable.
$Script:DevConfigWinGetMode = 'Module'
$Script:DevConfigWingetSourceFailure = $null

# Exit codes are stable across locales; console text is not.
$Script:DevConfigWingetNotFound  = -1978335212   # 0x8A150014 no installed package matched
$Script:DevConfigWingetNoUpgrade = -1978335189   # 0x8A15002B already at the latest applicable version

# Update the version and both official release asset hashes together.
$Script:DevConfigWinGetTargetVersion = [version]'1.29.380'
$Script:DevConfigWinGetAssets = [ordered]@{
    'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' = '65DEA9C01CE08EE7B763366B27C0E651F97DB857C11CA9B9C301826C10092F2E'
    'DesktopAppInstaller_Dependencies.zip' = 'BA875AFE9D190F61218985AC0292A99D1DB710BF93E13C68944CA9D89F0D82D1'
}

# dev-config.ps1 sets DevConfigScope for its machine and user parts. Workloads that load only these
# helpers keep the unscoped behavior.
function Get-DevConfigWingetScope {
    $runScope = Get-Variable -Name DevConfigScope -Scope Script -ValueOnly -ErrorAction Ignore
    if ($runScope) {
        return $runScope
    }
    return 'All'
}

# At first sign-in, App Installer's per-user winget alias can appear after this process started, so the
# user part calls it by full path.
function Get-DevConfigWingetExe {
    if ((Get-DevConfigWingetScope) -eq 'User') {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias) {
            return $alias
        }
    }
    return 'winget.exe'
}

# Windows registers App Installer for a new account in the background after its first sign-in, so the
# user part registers it itself (no elevation needed) and waits briefly for the winget alias.
function Register-DevConfigAppInstaller {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) {
        return
    }
    Write-Host '  Registering App Installer (WinGet) for this account...' -ForegroundColor DarkCyan
    # Appx cmdlets run in Windows PowerShell, as in Invoke-DevConfigWinGetDeployment.
    $command = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'; " +
        'Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $shell = Join-Path $env:SystemRoot "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
    $result = Invoke-DevConfigNativeCommand -FilePath $shell `
        -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds 300
    if ($result.ExitCode -ne 0) {
        Write-Host "  App Installer registration reported: $(([string]$result.Output).Trim())" -ForegroundColor Yellow
    }
    for ($waited = 0; $waited -lt 60; $waited += 2) {
        if (Test-Path -LiteralPath $alias) {
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "WinGet isn't available for this account yet: App Installer didn't register within a minute. Sign out and back in, then run the user part again."
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

    # The machine part runs as SYSTEM, so its copy goes where every account's PowerShell finds it.
    $moduleScope = if ((Get-DevConfigWingetScope) -eq 'Machine') { 'AllUsers' } else { 'CurrentUser' }
    # Retry module download because it is the most network-dependent call in the run.
    Invoke-DevConfigRetry -Name 'WinGet module download' -MaxAttempts 4 -InitialDelaySeconds 10 -ScriptBlock {
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope $moduleScope -Force -AllowClobber -ErrorAction Stop | Out-Null
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

    # The user part uses the winget command, the route proven at first sign-in, and skips the module's
    # PowerShell Gallery download in a run that has a time limit.
    if ((Get-DevConfigWingetScope) -eq 'User') {
        Register-DevConfigAppInstaller
        $Script:DevConfigWinGetMode = 'Cli'
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

    if ((Get-DevConfigWingetScope) -eq 'Machine') {
        throw "The WinGet PowerShell module isn't usable ($reason). The machine part runs as SYSTEM, where only the module can install packages. Check the internet connection or proxy settings, then run it again."
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
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $dependencies = @(
                    foreach ($dependency in $dependencies) {
                        $archive = [IO.Compression.ZipFile]::OpenRead($dependency)
                        try {
                            $entry = $archive.GetEntry('AppxManifest.xml')
                            if (-not $entry) { throw "Missing AppxManifest.xml in $dependency." }
                            $reader = [IO.StreamReader]::new($entry.Open())
                            try { $manifest = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
                        } finally { $archive.Dispose() }
                        $identity = $manifest.Package.Identity
                        if (-not $identity.Name -or -not $identity.Publisher -or -not $identity.ProcessorArchitecture -or -not $identity.Version) {
                            throw "Incomplete dependency identity in $dependency."
                        }
                        $installed = @(Get-AppxPackage -Name $identity.Name -ErrorAction Stop | Where-Object {
                            $_.Publisher -eq $identity.Publisher -and
                            [string]$_.Architecture -eq $identity.ProcessorArchitecture -and
                            [version]$_.Version -ge [version]$identity.Version
                        })
                        if (-not $installed.Count) { $dependency }
                    }
                )
                $parameters = @{ Path = $bundle; ForceTargetApplicationShutdown = $true; ErrorAction = 'Stop' }
                if ($dependencies.Count) { $parameters.DependencyPath = $dependencies }
                Add-AppxPackage @parameters
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
    param([switch] $AllowCliFallback)

    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        return
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Invoke-DevConfigWingetSourceOperation -Name 'WinGet source query' -ScriptBlock {
                Get-WinGetPackage -Source winget -ErrorAction Stop
            } | Out-Null
            return
        } catch {
            $moduleError = $_.Exception.Message
            # As SYSTEM the module runs WinGet in-process: there's no App Installer to repair and no command to fall back to.
            if ((Get-DevConfigWingetScope) -eq 'Machine') { throw }
            if ($AllowCliFallback -and
                $_.Exception.GetType().FullName -eq 'Microsoft.WinGet.Client.Engine.Exceptions.WinGetIntegrityException' -and
                [string]$_.Exception.Category -eq 'AppInstallerNotInstalled') {
                Write-Host "  App Installer is unavailable to the WinGet module ($moduleError). Checking the built-in winget command..." -ForegroundColor Yellow
                break
            }
            # 0x800706BA means the module could not reach WinGet's RPC server.
            if ($_.Exception.HResult -ne -2147023174) { throw }
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
        Invoke-DevConfigWingetSourceOperation -Name 'WinGet CLI source query' -ScriptBlock {
            $listed = Invoke-DevConfigWingetCli -Arguments @('list', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
            if ($listed.ExitCode -ne 0 -and $listed.ExitCode -ne $Script:DevConfigWingetNotFound) {
                throw [Runtime.InteropServices.COMException]::new("winget list failed with exit code $($listed.ExitCode)", $listed.ExitCode)
            }
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
    if ((Get-DevConfigWingetScope) -eq 'All') {
        return Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments $Arguments
    }
    # The hidden parts have a time limit, so a stalled winget call is stopped after 20 minutes.
    return Invoke-DevConfigNativeCommand -FilePath (Get-DevConfigWingetExe) -Arguments $Arguments -TimeoutSeconds 1200
}

function Test-DevConfigWingetSourceFailure {
    param(
        [Parameter(Mandatory)] [Exception] $Exception
    )
    $sourceFailure = $false
    while ($null -ne $Exception) {
        # RPC failures belong to the existing repair and CLI fallback path.
        if ($Exception.HResult -eq -2147023174) { return $false }
        # Missing source data (0x8A15000F), source open failure (0x8A150045), or all sources failed (0x8A15004B).
        if ($Exception.HResult -in @(-1978335217, -1978335163, -1978335157) -or
            $Exception.GetType().FullName -eq 'Microsoft.WinGet.Client.Engine.Exceptions.CatalogConnectException') {
            $sourceFailure = $true
        }
        $Exception = $Exception.InnerException
    }
    return $sourceFailure
}

function Invoke-DevConfigWingetSourceOperation {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [switch] $RetryPackageFailure
    )
    if ($Script:DevConfigWingetSourceFailure) {
        throw $Script:DevConfigWingetSourceFailure
    }
    try {
        Invoke-DevConfigRetry -Name $Name -ScriptBlock $ScriptBlock -ShouldRetry {
            param($Failure)
            $RetryPackageFailure -or (Test-DevConfigWingetSourceFailure -Exception $Failure.Exception)
        }
    } catch {
        if (Test-DevConfigWingetSourceFailure -Exception $_.Exception) {
            $Script:DevConfigWingetSourceFailure = "The winget source is unavailable after retries. Remaining package operations are skipped for this run. Check your connection and WinGet source configuration, then run setup again. $($_.Exception.Message)"
            throw $Script:DevConfigWingetSourceFailure
        }
        throw
    }
}

# App Execution Alias stubs can exist without a registered App Installer package, so invoke winget.exe.
function Test-DevConfigWingetCliUsable {
    # The winget command isn't supported as SYSTEM, where the machine part runs.
    if ((Get-DevConfigWingetScope) -eq 'Machine') {
        return $false
    }
    if (-not (Get-Command (Get-DevConfigWingetExe) -ErrorAction SilentlyContinue)) {
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
        $listed = Invoke-DevConfigWingetSourceOperation -Name "winget list $Id" -ScriptBlock {
            $result = Invoke-DevConfigWingetCli -Arguments @('list', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements')
            if ($result.ExitCode -ne 0 -and $result.ExitCode -ne $Script:DevConfigWingetNotFound) {
                throw [Runtime.InteropServices.COMException]::new("winget list $Id failed with exit code $($result.ExitCode)", $result.ExitCode)
            }
            return $result
        }
        if ($listed.ExitCode -eq $Script:DevConfigWingetNotFound) {
            return $false
        }
        if ($AnyVersion) {
            return $true
        }
        # useLatest requires the package to be current, not only installed, so match the module path.
        return -not (Test-DevConfigWingetUpgradeAvailable -Id $Id)
    }

    # EqualsCaseInsensitive avoids ambiguous substring matches.
    $pkg = Invoke-DevConfigWingetSourceOperation -Name "WinGet package query $Id" -ScriptBlock {
        Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive -ErrorAction Stop
    }
    if (-not $pkg) {
        return $false
    }
    if ($AnyVersion) {
        return $true
    }

    # useLatest requires the package to be current, not only installed.
    return -not $pkg.IsUpdateAvailable
}

function Get-DevConfigWingetPackageState {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        $listed = Invoke-DevConfigWingetSourceOperation -Name "winget list $Id" -ScriptBlock {
            $result = Invoke-DevConfigWingetCli -Arguments @('list', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements')
            if ($result.ExitCode -ne 0 -and $result.ExitCode -ne $Script:DevConfigWingetNotFound) {
                throw [Runtime.InteropServices.COMException]::new("winget list $Id failed with exit code $($result.ExitCode)", $result.ExitCode)
            }
            return $result
        }
        if ($listed.ExitCode -eq $Script:DevConfigWingetNotFound) {
            return [pscustomobject]@{ State = 'Absent'; Package = $null }
        }
        $state = if (Test-DevConfigWingetUpgradeAvailable -Id $Id) { 'UpgradeAvailable' } else { 'Current' }
        return [pscustomobject]@{ State = $state; Package = $null }
    }

    $pkg = Invoke-DevConfigWingetSourceOperation -Name "WinGet package query $Id" -ScriptBlock {
        Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive -ErrorAction Stop
    }
    if (-not $pkg) {
        return [pscustomobject]@{ State = 'Absent'; Package = $null }
    }
    $state = if ($pkg.IsUpdateAvailable) { 'UpgradeAvailable' } else { 'Current' }
    return [pscustomobject]@{ State = $state; Package = $pkg }
}

# winget list exits 0 whether or not an upgrade exists, and every message it prints is localized.
# The package id is the one token in that output that is never translated, so it is what gets matched.
function Test-DevConfigWingetUpgradeAvailable {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    $upgrade = Invoke-DevConfigWingetSourceOperation -Name "winget upgrade query $Id" -ScriptBlock {
        $result = Invoke-DevConfigWingetCli -Arguments @('list', '--id', $Id, '--exact', '--source', 'winget', '--upgrade-available', '--accept-source-agreements')
        if ($result.ExitCode -ne 0 -and $result.ExitCode -ne $Script:DevConfigWingetNotFound) {
            throw [Runtime.InteropServices.COMException]::new("winget upgrade query $Id failed with exit code $($result.ExitCode)", $result.ExitCode)
        }
        return $result
    }
    if ($upgrade.ExitCode -ne 0) {
        return $false
    }
    # @() keeps the count valid when nothing matches; under Set-StrictMode a bare $null has no Count.
    return @($upgrade.Output -split '\r?\n' | Where-Object { $_ -match ('(^|\s)' + [regex]::Escape($Id) + '(\s|$)') }).Count -gt 0
}

function Get-DevConfigWingetInstallArguments {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $DisableInteractivity,
        [switch] $UserScope
    )
    return @(
        'install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
        if ($UserScope) { '--scope', 'user' }
        if ($DisableInteractivity) { '--disable-interactivity' }
    )
}

function Get-DevConfigWingetUpgradeArguments {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $DisableInteractivity,
        [switch] $UserScope
    )
    return @(
        'upgrade', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
        if ($UserScope) { '--scope', 'user' }
        if ($DisableInteractivity) { '--disable-interactivity' }
    )
}

function Install-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $AllowCliFallback,
        [switch] $DisableInteractivity
    )
    # The user part never picks a machine-wide installer: it would wait on a UAC prompt nobody can see.
    $runScope = Get-DevConfigWingetScope
    $userScope = $runScope -eq 'User'
    $noPrompt = $DisableInteractivity -or $runScope -ne 'All'
    # As SYSTEM there's no signed-in user, so only machine-wide or unscoped installers apply.
    $scopeParameters = @{}
    if ($runScope -eq 'Machine') {
        $scopeParameters.Scope = 'SystemOrUnknown'
    }
    Invoke-DevConfigWingetSourceOperation -Name "winget install $Id" -RetryPackageFailure -ScriptBlock {
        if ($Script:DevConfigWinGetMode -eq 'Cli') {
            $r = Invoke-DevConfigWingetCli -Arguments (Get-DevConfigWingetInstallArguments -Id $Id -DisableInteractivity:$noPrompt -UserScope:$userScope)
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $Script:DevConfigWingetNoUpgrade) {
                throw [Runtime.InteropServices.COMException]::new("winget install $Id failed with exit code $($r.ExitCode)", $r.ExitCode)
            }
            return
        }

        try {
            $result = Install-WinGetPackage -Id $Id -Source winget -Mode Silent -MatchOption EqualsCaseInsensitive -ErrorAction Stop @scopeParameters
            # NoApplicableUpgrade means the package is already installed and current.
            if (-not $result.Succeeded() -and $result.Status -ne 'NoApplicableUpgrade') {
                throw [InvalidOperationException]::new("winget install $Id failed: $($result.ErrorMessage())", $result.ExtendedErrorCode)
            }
            return
        } catch {
            $moduleError = $_.Exception.Message
            if (-not $AllowCliFallback -or -not (Test-DevConfigWingetCliUsable)) {
                throw
            }
            Write-Host "  WinGet module install failed; retrying with winget.exe ($moduleError)" -ForegroundColor Yellow
            $r = Invoke-DevConfigWingetCli -Arguments (Get-DevConfigWingetInstallArguments -Id $Id -DisableInteractivity:$DisableInteractivity)
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $Script:DevConfigWingetNoUpgrade) {
                throw [Runtime.InteropServices.COMException]::new("winget install $Id failed after module fallback (module: $moduleError; CLI exit: $($r.ExitCode))", $r.ExitCode)
            }
            $Script:DevConfigWinGetMode = 'Cli'
        }
    }
}

function Update-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $AllowCliFallback,
        [switch] $DisableInteractivity
    )
    $runScope = Get-DevConfigWingetScope
    $userScope = $runScope -eq 'User'
    $noPrompt = $DisableInteractivity -or $runScope -ne 'All'
    Invoke-DevConfigWingetSourceOperation -Name "winget upgrade $Id" -RetryPackageFailure -ScriptBlock {
        if ($Script:DevConfigWinGetMode -eq 'Cli') {
            $r = Invoke-DevConfigWingetCli -Arguments (Get-DevConfigWingetUpgradeArguments -Id $Id -DisableInteractivity:$noPrompt -UserScope:$userScope)
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $Script:DevConfigWingetNoUpgrade) {
                throw [Runtime.InteropServices.COMException]::new("winget upgrade $Id failed with exit code $($r.ExitCode)", $r.ExitCode)
            }
            return
        }

        try {
            $result = Update-WinGetPackage -Id $Id -Source winget -Mode Silent -MatchOption EqualsCaseInsensitive -ErrorAction Stop
            if (-not $result.Succeeded() -and $result.Status -ne 'NoApplicableUpgrade') {
                throw [InvalidOperationException]::new("winget module upgrade $Id failed: $($result.ErrorMessage())", $result.ExtendedErrorCode)
            }
            return
        } catch {
            $moduleError = $_.Exception.Message
            if (-not $AllowCliFallback -or -not (Test-DevConfigWingetCliUsable)) {
                throw
            }
            Write-Host "  WinGet module upgrade failed; retrying with winget.exe ($moduleError)" -ForegroundColor Yellow
            $r = Invoke-DevConfigWingetCli -Arguments (Get-DevConfigWingetUpgradeArguments -Id $Id -DisableInteractivity:$DisableInteractivity)
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $Script:DevConfigWingetNoUpgrade) {
                throw [Runtime.InteropServices.COMException]::new("winget upgrade $Id failed after module fallback (module: $moduleError; CLI exit: $($r.ExitCode))", $r.ExitCode)
            }
            $Script:DevConfigWinGetMode = 'Cli'
        }
    }
}

function Ensure-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $AllowCliFallback,
        [switch] $DisableInteractivity
    )

    $state = Get-DevConfigWingetPackageState -Id $Id
    switch ($state.State) {
        'Current' {
            return 'already-current'
        }
        'UpgradeAvailable' {
            Update-DevConfigWingetPackage -Id $Id -AllowCliFallback:$AllowCliFallback -DisableInteractivity:$DisableInteractivity
            $action = 'upgraded'
        }
        'Absent' {
            Install-DevConfigWingetPackage -Id $Id -AllowCliFallback:$AllowCliFallback -DisableInteractivity:$DisableInteractivity
            $action = 'installed'
        }
        default {
            throw "Unknown WinGet package state '$($state.State)' for '$Id'."
        }
    }

    Wait-DevConfigWingetPackageSettled -Id $Id
    if ((Get-DevConfigWingetPackageState -Id $Id).State -ne 'Current') {
        throw "WinGet did not verify '$Id' as installed and current after $action."
    }
    return $action
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
                -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') | Out-Null
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
    # Large MSI removals such as Azure CLI can take over 15 minutes on slower machines.
    $timeoutSeconds = if ($CheckOnly) { 900 } else { 3600 }
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
                    -SuccessCodes @(0, $Script:DevConfigWingetNotFound) -TimeoutSeconds $timeoutSeconds `
                    -Unelevated:($scope -eq 'user' -and -not $CheckOnly)
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
