<#
.SYNOPSIS
  How this script talks to WinGet: acquiring a working front end, repairing a broken install,
  and querying or installing individual packages.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# WinGet has two front ends: the PowerShell module (preferred -- structured results, nothing to
# parse) and winget.exe. The module comes from the PowerShell Gallery, which a proxied, offline or
# locked-down network may not reach, so fall back to the CLI that already ships with Windows rather
# than failing the whole run over it.
$Script:DevConfigWinGetMode = 'Module'

# WinGet's own exit codes, which are stable across locales -- unlike its console text.
$Script:DevConfigWingetNotFound  = -1978335212   # 0x8A150014 no installed package matched
$Script:DevConfigWingetNoUpgrade = -1978335189   # 0x8A15002B already at the latest applicable version

# The oldest WinGet this script is willing to drive. Every install below passes --disable-interactivity,
# which older builds reject outright as an unknown argument, and the Microsoft.WinGet.Client module
# needs a comparable vintage to talk to the package manager at all. Answering a version probe is not
# enough on its own: a WinGet can respond perfectly while being too old to accept the work.
$Script:DevConfigWinGetMinimumVersion = [version]'1.6.0'

function Install-DevConfigWinGetModule {
    Enable-DevConfigModernTls

    # A fresh machine can prompt to install the NuGet provider on first use; bootstrap it non-interactively first.
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
    }
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Register-PSRepository -Default -ErrorAction Stop
    }

    # A VPN reconnect or a waking proxy routinely outlasts a couple of seconds, and this is the most
    # network-dependent call in the whole run.
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
            # A module folder left half-written by an interrupted run imports no better on a second
            # attempt, but reinstalling over it usually does fix it -- so fall through rather than
            # failing phase 1 outright with winget.exe sitting right there unused.
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

# Exit code, not console text: winget's output is localised and reformatted between versions.
function Invoke-DevConfigWingetCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    return Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments $Arguments
}

# winget.exe on PATH is an App Execution Alias: a zero-byte stub that satisfies Get-Command even when
# the App Installer package behind it isn't registered for this account -- which is one of the very
# failure modes this script exists to survive. Launching such a stub fails outright instead of
# returning an exit code, so only a real invocation settles whether the CLI is usable.
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

# Reads the version from whichever front end is in use, as a [version] that can be compared.
# WinGet reports it as text ("v1.29.280", sometimes with a -preview suffix), so it needs parsing
# rather than casting. Returns $null when WinGet does not answer at all.
function Get-DevConfigWinGetVersion {
    $text = $null
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        try {
            $result = Invoke-DevConfigWingetCli -Arguments @('--version')
            if ($result.ExitCode -eq 0) {
                $text = $result.Output
            }
        } catch {
            Write-Verbose "winget.exe --version could not run: $($_.Exception.Message)"
        }
    } else {
        try {
            $text = Get-WinGetVersion -ErrorAction Stop
        } catch {
            Write-Verbose "Get-WinGetVersion failed: $($_.Exception.Message)"
        }
    }

    if (-not $text) {
        return $null
    }
    $match = [regex]::Match([string]$text, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) {
        return $null
    }
    $build = if ($match.Groups[3].Success) { $match.Groups[3].Value } else { '0' }
    return [version]"$($match.Groups[1].Value).$($match.Groups[2].Value).$build"
}

# WinGet is ready when it answers and is new enough to accept the work this script gives it.
function Test-DevConfigWinGetReady {
    $version = Get-DevConfigWinGetVersion
    if (-not $version) {
        return $false
    }
    if ($version -lt $Script:DevConfigWinGetMinimumVersion) {
        Write-Host "  WinGet $version is older than $($Script:DevConfigWinGetMinimumVersion), which this script needs." -ForegroundColor DarkGray
        return $false
    }
    return $true
}

# Only reached when the check above found WinGet missing, broken, or too old, so a healthy machine
# never pays for the slow repair.
function Repair-DevConfigWinget {
    if ($Script:DevConfigWinGetMode -eq 'Cli') {
        # Repair-WinGetPackageManager has no winget.exe equivalent, so there is nothing to try here.
        Set-DevConfigStepUnverified -Reason 'The built-in winget command is too old for this script and cannot be updated from here. Update App Installer from the Microsoft Store, then run this again.'
        return
    }

    Write-Host '  (This can take a few minutes.)' -ForegroundColor DarkGray
    try {
        # *>&1 into $null so nothing the repair narrates can reach the console: it probes for a
        # winget that is missing or broken by definition here, and says so in its own streams.
        # A genuine failure still throws to the catch below, and the follow-up check still decides.
        $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop *>&1
        return
    } catch {
        Write-Host "  WinGet repair did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Repair failed outright, so the module front end is unlikely to work for any package. winget.exe
    # is a separate implementation and usually still answers; switching now beats letting every
    # package step fail one at a time for the same underlying reason.
    if (Test-DevConfigWingetCliUsable) {
        Write-Host '  Falling back to the built-in winget command instead.' -ForegroundColor Yellow
        $Script:DevConfigWinGetMode = 'Cli'
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
        # No upgrade probe here: winget list --upgrade-available exits 0 for any installed package,
        # upgrade or not, so testing its exit code marked every package as missing and reinstalled
        # and flagged all of them on every run. Installed is the bar the CLI can actually answer for.
        return $true
    }

    # EqualsCaseInsensitive avoids ambiguous substring matches (e.g. an MSIX-correlated entry sharing the same Id text).
    $pkg = Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive
    if (-not $pkg) {
        return $false
    }

    # useLatest: true in the original -- an available upgrade means this step isn't satisfied yet.
    return -not $pkg.IsUpdateAvailable
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
        # NoApplicableUpgrade: already installed and up to date, not a failure (module's equivalent of the
        # CLI's APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE exit code).
        if (-not $result.Succeeded() -and $result.Status -ne 'NoApplicableUpgrade') {
            throw "winget install $Id failed: $($result.ErrorMessage())"
        }
    }
}

# Get-WinGetPackage's catalog read can lag right after a successful install (an upstream WinGet
# quirk, not specific to one PowerShell edition), so give it a moment before judging the result.
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
