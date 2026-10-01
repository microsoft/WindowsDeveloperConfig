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

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDcdtIyadQTgJO4
# e32dEbuMf+/xt4Yjrpnu0Wn+ud38mqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIGnbTfGKJ0vmWn5fUXGoZhe6HXTqCZn2RJfehiqV8zdNMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAG69tImsg4BX8Z7Yf
# 1xCIHN0s3xZE0IWH64j2vg+QlH/nxHhj/YC+Xk9COF/8rzDt+te0B3mJ0Qei3uXS
# 45IG8cW7Lxc2TqhYFWDELCN+arSyNyaQHN5FnnWJcsHoEGU/DZCmlTDHSU3bU8xj
# K0NsoTFw2fFIAq5KnibT0Sb+zf4GEZVPq5DX2X446evzsmCeflMNTEJrpLdV6Jat
# Ss5o3LI4i2TbGjsr37AuO3F26NWL63GKHlBxEAmQw6gL4q/ydpCBwWsj2Dwopg38
# CRfMuU8psAWtAKfJhQnOJhGQ8xzBpcsRi1ltp25xsc1VFJXlZIiLO79duLeDultZ
# 4PPy8KGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCC8bBij1WDDewP4
# RoOBEnyIr4rjB/R9NTaR30inVGcANAIGarfvStELGBMyMDI2MTAwMTA0NTMxMC4w
# MDNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiEzwDX70g8hpAABAAACITANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTRaFw0yNzA1MTcxOTM5NTRa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDb
# cTACqU1YvRocyWL2PL9fyf/+ULs2qK7U1aZsRnDZSnlCr7K7jgA3eFCEJL5BZ7dU
# TC0DeZepf+ZC+7HEbB4IdzmJfQAUDFFerqY5VTHmQvP2XA3lWSFj740idcGUHglP
# 5H/PbCJU7GAHWP2HdcCjdx1lYAo0A+zLI7xwnTQeMyOXX212Eg4UmDPPJgxdTMw6
# WFVWsBPWRBi5gDixy2s+7R8ADk5lbBBFDB5h0CjrNWIN7uCAzF5g7trrL8nXIKp1
# 0mj9RxhcGQ+tlht6VIvdygRVTUGdzFB2/nBvJqQ9kxxFltQST70fEdx4TyaKow/f
# 5+BSh4z4/9f7NXIVVTLn/8kcJAfRqFmRrrFt3IKby7VrzmYuoQWD0lmNFtGQ57Br
# JkPrPFAPek1ALtcbb7FH3nQpvi8ngz/MFX/+cnmNFWFU29VVLmzB9XvLZxbYvkee
# tt0mh5lfteeN2rEwUyrdrKufz9h2S6pbate+C2h02CrXwSka0x6ezpTmGkIJLFt2
# 5ub/UYXNLdHdsxGD6EfckOIoJYsm4MS9F/vSqLNHK89I0vTLBngQEp6LIFkINanR
# T3PtNx3pNKRKJRALc6L6mhW4hL4aHL749qPfQ72t5qAMm5xiKYMgJ2WanidRLNuI
# 251JIN7raaeA/2vb0XFkZcIbTR1pfQGsco4U0g5tjwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFOYjIs5qa6pfuquPyyK1FTr5QDCnMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA4I/3bkdnTxD2rFum3MF8xVKdEkohAObbePrQ+0fr5bRimjz9sVkKT/7gc
# j4OMcClSYG+IdX6Mp3EYsLHWfjvwfzFoeZE+yTbdBj/1VHZQRuCmw6QqeVCTbw2n
# nS7nBxnWd9oZXbPUpqEawH5DqXQaWFgR9A4KWVK/IvXVDMj1PlPCES1P3JonNbdh
# kkkz49rJuKOm5b7e/BH8loqAmXOXRc22yxWVTMWrEp4pslmv8eT7VoY8X/jdKYTP
# VEXsfmLbVFcqzMuB8vFGfUyWsWROS8wgq7lQYfWcYqh7NymoATX+wWYK3zWG7aRc
# iPGUAzznXdf+aHtIWnQLNa5HFmSXkiak3fSuprWYZiHhuYjE16hroApcBHpm+8S/
# kNqhm9WjQX+2BxnYv+Jejy6lqTi8fLBLS069WXVw/ptf5IV+FtYl34GvVoeg31Uo
# UmVVZe1SDUJkm9dDXc8l/qBDYiAIT2CCsPTyt9XA9JVuHxdP63n7ChvWAO/47QRu
# CDsUlFJoWwyBwl7jeYpaRVMtQt0iuJMGGjgEaJX1Q/2j8sXURvTceLHDD9ipWt09
# 2ZDWMQciDRmhHNFOX1dnjBvk/k1UMcg997j5oYznAnSpJvlg/4BP3aVE0h/YH2Kg
# sKbU4NXZHAjJXj2Slqo1C115CG6qBZaFkM8W6vPZCm5qnSezOjCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjMzMDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQALbEgZZnyYHXJ1DGb5fGjplXpt
# uaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7mhb4jAiGA8yMDI2MTAwMTA0MTExNFoYDzIwMjYxMDAyMDQxMTE0
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuaFviAgEAMAcCAQACAjTIMAcCAQAC
# AhLVMAoCBQDuaa1iAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBABwmoO5p
# VO8jvB1kjTzEmADV7qQJuIB3GsagXmx4IfcC4mxDBgaj1ucihB7g/oYSknHaR1jC
# 7zaO2UwXVBdIgqfKeMFXlXDrrbJVh5vyXF+EWjGwE8GIG1c3tZi9Pk7EpJVhcLvU
# O4kL2vgC0+zX0Tf8seMcnbN/tmPFdH8yzB6YDaBEIZrOcY4yHPmgXjV5bN5aGBWW
# Zq562cirjluEglKMmf0teySUQs6iLqfEiYgWtrjV7ss9iXeVj9ISTSDDeVJckQy4
# wRN2aYa9ZSKu+aw38Vi5I3UHPhhALOyKGqc/L2h1lweTcO8jdrLHfb/449xLYHa/
# LrcggeXXDuz2ea0xggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiEzwDX70g8hpAABAAACITANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAfVfrT
# YuGHslnqawSCp7wuHCdLvoPOU6/oFvO4orVizjCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIADvIQefFVUa4BJy8IZywMAvmGSKdUVqEmy9A++PCj1EMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIhM8A1+9IPIaQA
# AQAAAiEwIgQgSziUjV7LvHLFEomOOaJOgZlNnEOd4ui1WtClxfRsCjswDQYJKoZI
# hvcNAQELBQAEggIAfWuA6afUKOLxd5KFzHgUpmxERbtrfIsEPFPFHf4sDbus00iw
# 3Lji5lr3ApQ0yibmZiONfFiO5RSj3LUf60GhH8y9+yBipRGRlEvJ40+faTefgvk/
# hvYY9QI/yUC/kNssGrpvEHZ0vEnct/3pZF+La0SSegQh5pYGldS4CIdyXKvxDel3
# n4f600Dy/wSEGVw607pUS0pb2fQMupVXbfwwnBHP6OEAxics89jPzdM9EMfOxh98
# P60CIQPJtW0xuGxdE3p9rP+xmo8gQ2scHVtLF+gTZdtfuSVQJeVGjl+I1MjxNJFi
# G57YDnTNQSMqfrPQwAu3zhkOhSB3ExHytgapLGTq5YBwhUJhrTUA3Xje3q659ZfA
# JyXLBif/pmlqGfGZ24Rf+ZpNhDRiSFgsVhco9JpzHJwwGpq914XcjRmoZnHRpDXG
# yvHFhJwSTMS6jq5UPxoLFFDnZzp++9xRHHOI6OhX4yBZc9r4QUvhHhOagC+kiYRa
# Ziy4d4GhkGOJ8Dmae6KZG5nzXeKFPQ9pFXtEgwsEgavJ8MLxFjzIGpy7cQTKMXOG
# 0bi20f/+lKm210TGsdoRa6CUPcZLRd5sqUOi6142og+s0LKTpKgvJ2sDzDFHp+fc
# 7etr1L6hxoC9o4A6CDeAKiBHf6H6hIkJdp6ZGdT/MYayjbw3tmV1BGOCxYM=
# SIG # End signature block
