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
                $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop *>&1
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

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC1v0C2TPtlAKkV
# 64rjgxhn20tLkKWz6JFMKrOLhEEM/KCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEICQE30JxKW+wUyv+tzcII3UdMcul
# hczgSgzEJE6JF8S/MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAm5PzJRj2wtuKr9RFFe4+F5MM90ad0RmxDRaGB7Jvl1XsHbwJzq9G2CKdYTv2
# NMrrMFGfEO8l+ahnB1M1djkXk2nuE1VEXG70KP0TlXiiLYHnFdqXpr5cnZ3YTWsd
# WooN/1PL7DAI6P3EHdBHW09quXTnQw8wqceT2tq5M9sYUrMXhRturT9Ai9cMFgUd
# Xtyc0COY7k/janLLa0kjuun3ag7m8KlQ3r0Y6iuJQclgutgsBDoA1QztBjNFhwCn
# dmyjlslH7PBYtdrQ+FPSTVKBb6aiAa7q/OEmohfQVsPCxMFbv4+3c5+oSYbWXCWR
# QgEnQzXZPwBpDBjaSNzSEDyhc6GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBbGsZxfVCHala5ezhKP/mNKmYPaKTCakzKxoyF41RznQIGaql/Gt9eGBMy
# MDI2MDkyNTIwNDA0NS4zMTZaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiu7AFD/TTuaoQABAAACKzANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMTFa
# Fw0yNzA1MTcxOTQwMTFaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCX3mi6OD3syUqQm4QqgkrKPbcsK/Qx3fYctL8+VM1uOY3b
# ooi5GxwauTgQf6JFHITToxS7gjqKlK8OFLzL6UTl0jxEK5t6DuOcgJXdvutimoTl
# OS0C3kyITXBAXoj/gp6hRR9z6WRip1Ktkilb3dJXCjQqT9P2Cuujr+Vz8r+Z+jDl
# 09ji/ic/4G34r3mVwjs//Gnx9Pu31V8rXFicNiAzxpubawpbd8pqfzlWT2vnG3kF
# 9l6MiREbvJ3XHLUwHQsh0t/TrSFx/s/yCqpJWYJ6oClG70tvsFH0aRP8wB4cP/CF
# a2ILvk26i3OcJBl+pqKjHTSBy9mvwTPEDlnzco0Nt8R6pSPTXZgBsscHhoKfC0WQ
# mOzY2keXbAmRTcZMyXz5v/AJbmoI0y07Bazvt5NkXddG9TErQWwtsFyIKrElDgWf
# HeCoTu1wu2ciD3dK72z3ca2gzoEDxT2j9BXIUKaiTzTdQPRsAMaO3dU0zaGwMMlw
# tSJyDh14YEgZoUu5vS8MugMqdrNjphyL65yKhjpAWbhYkIHO/0uZju95tP8zZNqX
# IRh4tdfWHJPATn9r+cxkyuh2x0VLdfx1lmK9X3NjH0NtgAs5JB/wOlkyuudxmFTf
# WVyRrL37ispOZ8aPAFgvyR6cNTkGpkFo35JRjciNmZiU4qT9Uty+V5gudFk1jwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFD4WjuQTUJbtbd3jmvZku0FZ2eU2MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQDO/CKsciEM8kr1fqH4TlfT66ENoTjxXw810pyE
# q0PdrgLwfgT3x+1gz7CQHtUdevqMQ5qHyDLhm6pT911CYkGN+6g+MU7fMYTr6d3S
# xieJwBIoWkfR4g7SitGzMKU465KEYejfddoUgovC/xcRpaALO5p3/A248ByhJiMt
# tBQNDtsT/HaCFwRFCURby/f8c1kky8F8xkCXFz+/MtZ5d1lWFjwOI2geZHWq9Xih
# DOgee5nS2koo5V6n8XG220UTevVf+pgmpIH71XKDVIYTGGZJs6yPlfJ2aXqw1ME4
# NR6okNsY3P1M31H6DMYRfJGNBNep595kXGh3YzA3cCiyg+jmJ58h/fTvjngIpuUF
# fODpDjFx0ic1YoLANxhCF3RhS9qYM7K40NEhKshYuaAkIG2XBKYig3r/0/b0sjvj
# Bws55AYonMm3A8qcX/6k9Vfc0mv9dtonHuWGfA2b+qE2qpCnhzGbdDHq7iOSZEw0
# 1nNupAMf1c41k9IoTQ2z3iw6w4ZZoLOyg4TKMbp1krpT4trip/y30Cv5khyqCDNq
# aXQpBkOYON8LgtoQ3amVOX7ix5jdrnx/vUxTUSigXvrWdL7Uk8kpmS0zto2Toy7a
# T5oBzCTvfj9iJ/BN/E1vhFBkhJCvZ7PVvsMSnTTmkx2Fal2lVkztuAI44fD/uyLJ
# daMQSzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIIC
# NQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkEwMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAJrD90
# ykHpo/0AGb7lmwvsCtqROaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7mEq8jAiGA8yMDI2MDkyNTE3MTYzNFoY
# DzIwMjYwOTI2MTcxNjM0WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuYSryAgEA
# MAcCAQACAg2qMAcCAQACAhMyMAoCBQDuYnxyAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAE2orXnkblHI/pdOW0aYcTkMpaLUj3nxtz7PZvs7vDg4rBr69gtH
# vjDO7ZwQ36whcg0giWud1mv+jwGsbnKIBNRkn05ICDVjL5dlcVGuegLkZOp84DM+
# 18E4bWzaYyL/kszl6m4wg3LD1GCOWpo8Up7D9EO1Z6EWmoxaB1ZP53bhvqZv6Kru
# 6jNktfnHJ4JuVlUjcFfteNw3H4rxu+NZVMDPiQQitGSUWW4VlfdLHKi2yFzioarz
# tyzh85noTQAZ513rfCI9uMVjqcsoVf/DJtUgewLUY6We9CDd8TFA1JQ88jIHEYUA
# /nrf0nfxgx6OvlVHa6QFIfi+eESBROSF7OMxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7AFD/TTuaoQABAAACKzANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCDBHfThcuTHtZcyBZ5Q8Y3T27JNG66z2KubU10Tw0U82zCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHIOI/Q/kFftYA+M2OY+1Bx3ajBD6/WD
# AtPT2vFkv25SMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIruwBQ/007mqEAAQAAAiswIgQgcOrdDVIthrAhMGpaLnUYYMS/zu+flJjN
# tUM++Y8YdY0wDQYJKoZIhvcNAQELBQAEggIAQ74/LgET8fSGhBTkyf0QJkCb1+m4
# FmlolKlCzWY/Mvhb1aUuYEjHAcJ75sP0wHp3sLC0qYT0lT1GNOgitL8hmPKBHIEm
# IqqmRNVi6QrL2LR7wuj/fMA1+OQ88nhZDihTRzx6u9FjGwBEmV1cpZS7JvH+dT+5
# q1OF9I+BIC75KPOgBAAwppn4wFFX3jSxUqmpEwkTAlfl2ppGCRKc10k2i4M5Wqzh
# q3jmLXwZx7uM1LZfbiPa6o9hxrWJRNps+enWIhtlPIbXGn5lenVrYfRH369DZd9N
# kjrsJZE6AhhGTBYVuJ5R7dH8fr1PpxU3QJwSFSxDS/f13UyQ4bg/osy0FNwdBTRV
# agPHyCf12/1qO/AfR1BtrubLxyhxrlc3wKkoqixscigXwj4MOzlPlEbmBG4rZxdL
# lEqQrMBhWsML363g0TokzztcVRF5QfoXfw9z138XHSLlZAlHNFXAepl1AHex3E6A
# 47rOBaR62OLXWwuq1Rth2yLa//CBu3Yn5RVNqWAwkh8NC9ek0LYx9DTn1utAF7xD
# 1LekwftKlsiyfDgIE9l6yDdmb8GECVL+accx/ZX7RGDhrQK20wzBd2xmDuxQPcg0
# nNUeF36+lZe1kP+M+AmxxJ9NHLdHC3ZRRoWCPGiopedF3OiqYUaICbvRU2eMvWxL
# +e9MBWkiXlEt8hg=
# SIG # End signature block
