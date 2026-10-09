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
    return Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments $Arguments
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
        [switch] $DisableInteractivity
    )
    return @(
        'install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
        if ($DisableInteractivity) { '--disable-interactivity' }
    )
}

function Get-DevConfigWingetUpgradeArguments {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $DisableInteractivity
    )
    return @(
        'upgrade', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
        if ($DisableInteractivity) { '--disable-interactivity' }
    )
}

function Install-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $AllowCliFallback,
        [switch] $DisableInteractivity
    )
    Invoke-DevConfigWingetSourceOperation -Name "winget install $Id" -RetryPackageFailure -ScriptBlock {
        if ($Script:DevConfigWinGetMode -eq 'Cli') {
            $r = Invoke-DevConfigWingetCli -Arguments (Get-DevConfigWingetInstallArguments -Id $Id -DisableInteractivity:$DisableInteractivity)
            if ($r.ExitCode -ne 0 -and $r.ExitCode -ne $Script:DevConfigWingetNoUpgrade) {
                throw [Runtime.InteropServices.COMException]::new("winget install $Id failed with exit code $($r.ExitCode)", $r.ExitCode)
            }
            return
        }

        try {
            $result = Install-WinGetPackage -Id $Id -Source winget -Mode Silent -MatchOption EqualsCaseInsensitive -ErrorAction Stop
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
    Invoke-DevConfigWingetSourceOperation -Name "winget upgrade $Id" -RetryPackageFailure -ScriptBlock {
        if ($Script:DevConfigWinGetMode -eq 'Cli') {
            $r = Invoke-DevConfigWingetCli -Arguments (Get-DevConfigWingetUpgradeArguments -Id $Id -DisableInteractivity:$DisableInteractivity)
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

# SIG # Begin signature block
# MIInOgYJKoZIhvcNAQcCoIInKzCCJycCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+A8/WgeVWtj2o
# f62mW4j0DibIcGVEti/7+itHMzdEY6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIA+kJ+u0y0gbLZDT3AWS4YaM/asP
# 9xHzLPntpwlHpZ28MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAxJWJbut2CfMhYoCLLP/17dIaXj/Y8HAXZa1tJZdLhzhUxVt0z/1bRcpxm0aG
# 6DL7Knwa3T1IT4FxmrY8wy7n+p/WZKkWc2LXcdAhAHIB/OHNP33m8W1N9t1YbNri
# UZPLuGfR3ISuHidmzh55wNU/R7xd9xk/8sG39vIJanFLXCLdFWYQ5gX8ya7jciSV
# EFfsweCsU8vC05sCftdeyVMqVppA+DG+94kO3EObo5B92398oweyjRwDaq4hoq3c
# LkqWOhHqHMJoyZekiM9Cn0zz/U7b6uSjl0NGj2amTp3ODMcOsVPEn+B4YMObQw0c
# i+guLOqPNM2VIOixa8hx4ml/YqGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38G
# CSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDmQgd81t+XEgcn//onURjxzrXLzGmMyj9xcEw6d4nv7gIGaqluTtp7GBMy
# MDI2MTAwOTIxNDQ1Mi43MzNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHt
# MIIHIDCCBQigAwIBAgITMwAAAiNP2WAkU8/+KwABAAACIzANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTda
# Fw0yNzA1MTcxOTM5NTdaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCK6Q2nk5WUdKzSCSafp+UjUARsWxHKS63rJhFC/zSabFum
# TBuaJ0QNrmqevub5Db7fSj5qtwwKnjIO92+HXF67192fujL7DFot5WEj/AtEZ/Xr
# zFHimKlN1h6gEQwP5I67wizaPW5ZzSBNpaLBg5oHvASPOZtwdNUoZ+DQKF3hJl1K
# ZuoIlVK+qi7cLjgak6s5oOZcRCMrKnuC3aoVa6wRDbYvKUuj7rkFx9KO0PsHJ/k+
# LnZMggRheh4AVdawyh+oOzKPjlQGUNfSeWUgym2U9CLa8tt0mQX4DxDz6+ram50g
# j1oAfyQ6TQ7r96PADFOKBgaU7+cpHnaZG89dTegQ6ydBRGIycOw1dRX2eKDRRzzi
# K3cn0WaIm/7OeGsyQKjIzEQuUTDv0Jj/9zQ7truLOOpJD98BJVOK7je84Sz2hb3H
# vUST7j1j2N8peD6olkpFHR/1Z8Jz4F+mkrUF7MmPAirYHRzunbIg3HrDMNwFYN7y
# BkDA4/VMo9CY0y9oGUoq2yjbCwTibz9VYl93nB3QQiTCT9nW3M+TOWB+PMrZpExq
# 1BSHmKPzIqehKqrUDoM33PK+dEKwpYLET6uXq4HuQRMXWT//sPubUnQAaaUMfQhA
# ZSy23HtxwtN3eK9+T4wCav2wQFt57eUOwUW5/DCzMF9tua5He1hNvgcAXaiG1wID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFNbAh89v29nPY9bwQb1QYCzxVgeXMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCHQwe7z5tp4NZwAf1cB+4c9J4svw3P6WqGBMxt
# qznS6DdzUzStXHCaPZhM41g1iKHNnmcnLjwLujOEaNjhSnUDiAZqQjW5ZapOBxgc
# 7Egghh9k+r78qWAe3rJ4QohBbhSGdZtKivTRaeRqmnhy8+ThrKhzCeEwaarXJimZ
# wSpdQQUDbheWHeyAxASqultd5KO0m/UFvO03tfepqGXA4tCg/WGECwKqOjJzpRAf
# PIB6y1HyVrk+vmL5rpEbTwwLOtX7WxFGG8+cYLk9HjaDkxraA/HYlKQRx1sdza+w
# /gulLwgOnByRJKF2rr8M7FNIlwoi6ywFpaNc8A7HewaGjgw/tfcE260I1XekGluA
# NI9HnONOYWlI7BKBQbWE2teo6vsQ1Vg8B8rTZSePVdmXL1PPqqs3KVdFKM5kYocP
# CDM+6VL32IV96sESf2T7DjxanpCg2D2UYj4Z1i7cy8U1LLDGg55KWs4af2RRBjH2
# MulHgAmW5obKxiZCDQjRaroJ2XElXUhigE9BzvhCFbT/HDY2vpVpl5HnSpcCSxmL
# 5i5lIT/xbAQMI7Luh75Xrm+IslfFWOGOGMlCp+24qEJEglXEP7xwsolNdBNndXih
# hyIefVGlI1DR7xGELiJrk8ifVWYo9XEbEXv/lbvp6F2R2UsnweWckvq0y1HWnLHD
# qH6dPjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIIC
# OAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQA4RWFs
# +kTiZnoZiAj1BtYj8zCNaqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nOM3DAiGA8yMDI2MTAwOTE1NTUwOFoY
# DzIwMjYxMDEwMTU1NTA4WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuc4zcAgEA
# MAoCAQACAgM0AgH/MAcCAQACAhKDMAoCBQDudN5cAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBAEuiOiJrrd+lW0mRpnGcVfcMfgS3IvKvSvZYCH/xUywQ1OpO
# tVJQggaorfbbAvqUNTB7PosKAIz+QvuUlNoE95aZF94vSxjEwMf17VLkWCHe8xaU
# GNq4ruP7oAmuuJaL0Wu9GuPDOgFO0LotldWHQFMP6TQledhbUtgZUp7xO8axxY86
# 0zfj6s26oNdmjLuKvuYui/9Yxl0cykBMTk7ABn3kqMbnwbzxv/VDfdXBT7VOTqiV
# Qc4h7HA7/turdl6miie/Oshi06v88f1k5evSsw+2484+cj/7H62tBTUdlo8yYcAv
# Bsq1u15WPAsDvgu6732xJ4qW8bqOW98GG3cy7WIxggQNMIIECQIBATCBkzB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiNP2WAkU8/+KwABAAACIzAN
# BglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8G
# CSqGSIb3DQEJBDEiBCDZ2d6AUdUTZUXG+BLvIJ+rWaTCny4pTJtCJPzhNKBRijCB
# +gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIJbwMywRbvcGiynjnwjAqcaD47yY
# vebKZRAvtEAR5u6zMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIjT9lgJFPP/isAAQAAAiMwIgQgb8PUR0wf7qHKSgoLKy2jSb6mVSCU
# JfkzADCmwoivzrowDQYJKoZIhvcNAQELBQAEggIAX91McPrenMxBZdAReS0J25Db
# 4lGWgBsaLWKDSUW/i7AlbBbs1ZWe2jY8NsqIPtd8pwOULGwSwhhUKK/ThmF9Cj7J
# Xs3pHQFquClBvHfbjuIARaSkQHgijQOv68bGWzjr58/snfobcLp5LD9VBLXrqSqa
# IVaz0NwNOml6+CcEmOagB+tmYSSkXGosXdIoKnCcEn18nPZHXzpUSbolLGlKPMNM
# dnqXUIsObYtQ3hYjc8DXFR44JygUFIGBYkIZOFrlFinKc+OOcuuFQGcnnPxLUgYL
# BSapq9c5fextoe7y7sq8run6GTuoDKumbXd5RdvyWVVSSzGbc2WEU71few7OIM03
# XT83DPSnFlyER8iZYFfWwAusVUIfzbYMY54lx/AVN7Ik4/Kp81plDDO6olTv+R5v
# eJhZdTX1/Uc8jIra4dU2veX6o5YznFQRbWj0jLuQ+1XtCa08QMTFaRasqgj5yNrv
# 5mmIp7xBIJget4rPnqeeplosKqJX+yEn5sM2rkDpVKxIBmJv9A01XbkZZmIKampR
# tpuhIaHXGtly0lTFa4HvccgC10Wf1VG7CiZvLwhkuCZeq4zoVb6iAWshOBALO7Bu
# gt0ZWmxB3N4MT+zD+l0/ukkMarEtfWYTZLDpb6DxoPeovb8ZxJone8hr9qg3KZmf
# 8qDo66N+1UsSvC75xZk=
# SIG # End signature block
