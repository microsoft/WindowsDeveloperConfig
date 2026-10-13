# Helpers for the machine and user parts of the standard setup (dev-config.ps1 -Scope Machine|User).
# The machine part runs as SYSTEM or an administrator, often before anyone signs in. The user part
# runs as the signed-in user without elevation. Both run hidden and unattended, so nothing here may
# prompt, open a window or restart Windows.

function Test-DevConfigRunningAsSystem {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
}

function Assert-DevConfigScopeAccount {
    param(
        [Parameter(Mandatory)] [ValidateSet('Machine', 'User')] [string] $Scope
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Scope -eq 'User') {
        if ($identity.User.Value -eq 'S-1-5-18') {
            throw 'The user part configures the signed-in user. Run it as that user, not as SYSTEM.'
        }
        return
    }
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The machine part needs administrator rights. Run it as SYSTEM or from an elevated PowerShell.'
    }
}

function Get-DevConfigNativeArchitecture {
    # The registry reports the OS architecture even to emulated or 32-bit processes.
    $environment = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction Stop
    switch ($environment.PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
    }
    throw "The machine part supports x64 and Arm64 Windows only, not $($environment.PROCESSOR_ARCHITECTURE)."
}

function Get-DevConfigGitHubReleaseAsset {
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$')] [string] $Repository,
        [Parameter(Mandatory)] [string] $AssetPattern,
        # Used without the GitHub API: {0} is the release tag and {1} is the tag without a leading 'v'.
        [Parameter(Mandatory)] [string] $FallbackName
    )

    try {
        $response = Invoke-DevConfigWebRequest -Parameters @{
            Uri = "https://api.github.com/repos/$Repository/releases/latest"
            Headers = @{ 'User-Agent' = 'WindowsDeveloperConfig'; Accept = 'application/vnd.github+json' }
            TimeoutSec = 60
        }
        $content = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string]$response.Content
        }
        $release = $content | ConvertFrom-Json
        foreach ($asset in @($release.assets)) {
            if ([string]$asset.name -match $AssetPattern) {
                return [pscustomobject]@{
                    Tag  = [string]$release.tag_name
                    Name = [string]$asset.name
                    Uri  = [string]$asset.browser_download_url
                }
            }
        }
        Write-Host "  The latest $Repository release lists no asset like $AssetPattern; trying its download link." -ForegroundColor DarkGray
    } catch {
        Write-Host "  Could not read the latest $Repository release from the GitHub API ($($_.Exception.Message)); trying its download link." -ForegroundColor DarkGray
    }

    # The latest-release page redirects to the release tag, which names the assets.
    $response = Invoke-DevConfigWebRequest -Parameters @{
        Uri = "https://github.com/$Repository/releases/latest"; Method = 'Head'; TimeoutSec = 60
    }
    $baseResponse = $response.BaseResponse
    $finalUri = if ($baseResponse.PSObject.Properties['ResponseUri']) {
        $baseResponse.ResponseUri
    } elseif ($baseResponse.PSObject.Properties['RequestMessage']) {
        $baseResponse.RequestMessage.RequestUri
    } else {
        $null
    }
    if (-not $finalUri -or ([Uri]$finalUri).AbsoluteUri -notmatch '/releases/tag/([^/?#]+)$') {
        throw "Could not find the latest $Repository release. Check the internet connection, then run setup again."
    }
    $tag = [Uri]::UnescapeDataString($Matches[1])
    $name = [string]::Format($FallbackName, $tag, ($tag -replace '^v', ''))
    if ($name -notmatch $AssetPattern) {
        throw "The latest $Repository release ($tag) doesn't have the expected asset name ($name)."
    }
    return [pscustomobject]@{
        Tag  = $tag
        Name = $name
        Uri  = "https://github.com/$Repository/releases/download/$tag/$name"
    }
}

function Install-DevConfigSignedInstaller {
    param(
        [Parameter(Mandatory)] [ValidatePattern('^https://')] [string] $Uri,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]*\.(msi|exe)$')] [string] $FileName,
        [Parameter(Mandatory)] [string] $Label,
        [string[]] $Arguments = @(),
        [int[]] $SuccessCodes = @(0, 1641, 3010),
        [ValidateRange(60, 7200)] [int] $TimeoutSeconds = 1800
    )

    # Both are Microsoft release identities; Windows components such as WSL can use the second.
    $microsoftSubjects = @(
        'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    )
    $ProgressPreference = 'SilentlyContinue'
    $work = New-DevConfigProtectedDirectory -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('CalmOS-download-' + [guid]::NewGuid().ToString('N')))
    try {
        $installer = Join-Path $work $FileName
        Write-Host "  Downloading $Label..." -ForegroundColor DarkGray
        $null = Invoke-DevConfigWebRequest -Parameters @{ Uri = $Uri; OutFile = $installer; TimeoutSec = 900 }
        $signature = Get-AuthenticodeSignature -FilePath $installer
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notin $microsoftSubjects) {
            throw "The $Label installer from $Uri is not signed by Microsoft ($($signature.Status)), so it was not run."
        }

        $log = $null
        if ($FileName -like '*.msi') {
            $log = Join-Path $env:TEMP ('DevConfig-' + [IO.Path]::GetFileNameWithoutExtension($FileName) + '.log')
            $filePath = Join-Path ([Environment]::GetFolderPath('System')) 'msiexec.exe'
            $runArguments = @('/i', "`"$installer`"", '/qn', '/norestart', '/l*v', "`"$log`"") + $Arguments
        } else {
            $filePath = $installer
            $runArguments = $Arguments
        }

        Write-Host "  Installing $Label..." -ForegroundColor DarkGray
        $attempt = 0
        do {
            $attempt++
            $exitCode = Invoke-DevConfigProcess -FilePath $filePath -Arguments $runArguments -TimeoutSeconds $TimeoutSeconds -NoNewWindow
            # 1618: another installation is running, which is common right after Windows Setup.
            $busy = $exitCode -eq 1618 -and $attempt -lt 10
            if ($busy) {
                Write-Host "  Another installation is running; trying $Label again in 30 seconds..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 30
            }
        } while ($busy)

        if ($exitCode -notin $SuccessCodes) {
            $detail = if ($log) { " The installer log is $log." } else { '' }
            throw "The $Label installer failed with exit code $exitCode.$detail"
        }
        return $exitCode
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The machine part installs PowerShell 7 without winget: the winget CLI is not supported as SYSTEM,
# and the WinGet PowerShell module needs PowerShell 7 to run in-process there.
function Install-DevConfigPwshMsi {
    $architecture = Get-DevConfigNativeArchitecture
    $asset = Get-DevConfigGitHubReleaseAsset -Repository 'PowerShell/PowerShell' `
        -AssetPattern ('^PowerShell-\d+\.\d+\.\d+-win-' + $architecture + '\.msi$') `
        -FallbackName ('PowerShell-{1}-win-' + $architecture + '.msi')
    $exitCode = Install-DevConfigSignedInstaller -Uri $asset.Uri -FileName $asset.Name `
        -Label "PowerShell $($asset.Tag)" -Arguments @('ADD_PATH=1')
    $null = Update-DevConfigSessionPath
    return $exitCode
}

# wsl --install and wsl --update exit early as SYSTEM; the signed MSI from the WSL release works.
function Install-DevConfigWslMsi {
    $architecture = Get-DevConfigNativeArchitecture
    $asset = Get-DevConfigGitHubReleaseAsset -Repository 'microsoft/WSL' `
        -AssetPattern ('^wsl\.\d+(\.\d+)+\.' + $architecture + '\.msi$') `
        -FallbackName ('wsl.{1}.0.' + $architecture + '.msi')
    return Install-DevConfigSignedInstaller -Uri $asset.Uri -FileName $asset.Name -Label "WSL $($asset.Tag)"
}
