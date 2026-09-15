<#
.SYNOPSIS
  Selects a WinGet front end and installs or queries packages.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Prefer the WinGet module for structured results; fall back to winget.exe when PSGallery is unreachable.
$Script:DevConfigWinGetMode = 'Module'

# Exit codes are stable across locales; console text is not.
$Script:DevConfigWingetNotFound  = -1978335212   # 0x8A150014 no installed package matched
$Script:DevConfigWingetNoUpgrade = -1978335189   # 0x8A15002B already at the latest applicable version

# Repair-WinGetPackageManager -Latest installs this release, so it is what "latest" is measured against.
$Script:DevConfigWinGetLatestReleaseUrl = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'

# Cached per run so the check and its follow-up verification share one network call.
$Script:DevConfigWinGetLatestVersion = $null
$Script:DevConfigWinGetLatestChecked = $false

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

    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        return $null
    }

    try {
        return ConvertTo-DevConfigWinGetVersion -Text ([string](Get-WinGetVersion -ErrorAction Stop))
    } catch {
        Write-Verbose "Get-WinGetVersion failed: $($_.Exception.Message)"
        return $null
    }
}

# A null result means the lookup failed, which callers treat as "cannot tell" rather than "up to date".
function Get-DevConfigWinGetLatestVersion {
    if ($Script:DevConfigWinGetLatestChecked) {
        return $Script:DevConfigWinGetLatestVersion
    }
    $Script:DevConfigWinGetLatestChecked = $true

    try {
        # The GitHub API rejects requests without a User-Agent.
        $release = Invoke-RestMethod -Uri $Script:DevConfigWinGetLatestReleaseUrl -UseBasicParsing -TimeoutSec 30 `
            -Headers @{ 'User-Agent' = 'WindowsDeveloperConfig' }
        $Script:DevConfigWinGetLatestVersion = ConvertTo-DevConfigWinGetVersion -Text ([string]$release.tag_name)
    } catch {
        Write-Verbose "Could not look up the latest WinGet release: $($_.Exception.Message)"
    }
    return $Script:DevConfigWinGetLatestVersion
}

# Quiet by design: this runs on every invocation, including the follow-up verification.
function Test-DevConfigWinGetLatest {
    # An unreadable version means WinGet is missing or broken, which the update path repairs.
    $current = Get-DevConfigWinGetVersion
    if (-not $current) {
        return $false
    }

    # An offline or rate-limited lookup leaves a working WinGet alone rather than flagging every run.
    $latest = Get-DevConfigWinGetLatestVersion
    if (-not $latest) {
        return $true
    }

    # Store and Windows builds can lead the latest stable release, so newer also counts as current.
    return ($current -ge $latest)
}

# WinGet can report its previous version briefly after updating itself in place.
function Wait-DevConfigWinGetVersionSettled {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (Test-DevConfigWinGetLatest) {
            return $true
        }
        if ($attempt -eq 1) {
            Write-Host '  (Updated -- just waiting for WinGet to report its new version...)' -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

# Update runs only after the latest check fails, so machines already current skip the slower path.
function Update-DevConfigWinget {
    $current = Get-DevConfigWinGetVersion
    $latest  = Get-DevConfigWinGetLatestVersion
    if ($current -and $latest) {
        Write-Host "  WinGet $current -> $latest" -ForegroundColor DarkGray
    }

    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        # Repair-WinGetPackageManager has no winget.exe equivalent, so there is nothing to try here.
        Set-DevConfigStepUnverified -Reason 'The built-in winget command cannot update itself from here. Update App Installer from the Microsoft Store, then run this again.'
        return
    }

    Write-Host '  (This can take a few minutes.)' -ForegroundColor DarkGray
    try {
        # Suppress update output; exceptions and the follow-up check decide the result.
        $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop *>&1
        if (Wait-DevConfigWinGetVersionSettled) {
            return
        }
        Set-DevConfigStepUnverified -Reason 'WinGet was updated, but it is still reporting its previous version. Re-run to confirm.'
        return
    } catch {
        Write-Host "  WinGet update did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # If the module update fails, winget.exe may still be usable for package operations.
    if (Test-DevConfigWingetCliUsable) {
        Write-Host '  Falling back to the built-in winget command instead.' -ForegroundColor Yellow
        $Script:DevConfigWinGetMode = 'Cli'
    }

    if (Get-DevConfigWinGetVersion) {
        Set-DevConfigStepUnverified -Reason "WinGet could not be updated to $latest. The version on this machine still works, so the run carries on -- update App Installer from the Microsoft Store when convenient."
    } else {
        Set-DevConfigStepUnverified -Reason 'WinGet could not be updated and is not reporting a version at all. Update App Installer from the Microsoft Store, then run this again.'
    }
}

function Test-DevConfigWingetPackageInstalled {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        $listed = Invoke-DevConfigWingetCli -Arguments @('list', '--id', $Id, '--exact', '--accept-source-agreements')
        if ($listed.ExitCode -eq $Script:DevConfigWingetNotFound) {
            return $false
        }
        if ($listed.ExitCode -ne 0) {
            throw "winget list $Id failed with exit code $($listed.ExitCode)"
        }
        # useLatest requires the package to be current, not only installed, so match the module path.
        return -not (Test-DevConfigWingetUpgradeAvailable -Id $Id)
    }

    # EqualsCaseInsensitive avoids ambiguous substring matches.
    $pkg = Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive
    if (-not $pkg) {
        return $false
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
        [Parameter(Mandatory)] [string] $Id
    )
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (Test-DevConfigWingetPackageInstalled -Id $Id) {
            return
        }
        if ($attempt -eq 1) {
            Write-Host '  (Installed -- just waiting for it to finish registering...)' -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    Set-DevConfigStepUnverified -Reason "WinGet reported $Id installed, but its catalog still doesn't list it as current 15s later. It's on the machine -- re-run to confirm."
}
