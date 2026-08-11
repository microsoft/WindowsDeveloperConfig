<#
.SYNOPSIS
  Fetches the Calm OS developer workstation setup and starts it.

.DESCRIPTION
  Meant to be run straight from the web:

      irm https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1 | iex

  The setup cannot run from a piped-in string: it loads two dozen files from its own folder,
  relaunches itself elevated, and resumes after a reboot. This puts it somewhere real first.

  The files it installs come from the signed release copy when the ref has one, and from
  src/ otherwise, whichever address this script itself was fetched from.

  To pick a branch or pin a tag, run it as a script block instead:

      & ([scriptblock]::Create((irm <url>))) -Ref 'v1.2.3'
#>

[CmdletBinding()]
param(
    [string] $Ref = 'main',
    [string] $InstallRoot,
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'microsoft/WindowsDeveloperConfig'

# The ref goes straight into the download URL, and '..' in it would redirect to another repository.
if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref.Contains('..')) {
    throw "'$Ref' is not a valid branch, tag or commit name. Use letters, digits, and . _ - / only."
}

# A UNC install root would put the files the elevated setup loads on a remote share.
if ($InstallRoot -and ($InstallRoot.StartsWith('\\') -or $InstallRoot.StartsWith('//'))) {
    throw '-InstallRoot must be a local path, not a network share.'
}

if (-not $InstallRoot) {
    # Per-user and outside the roaming profile: it has to still be there after the reboot.
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $InstallRoot = Join-Path $base 'CalmOS'
}

# Windows PowerShell 5.1 still defaults to protocols GitHub no longer accepts.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
}

function Save-CalmOsArchive {
    param(
        [Parameter(Mandatory)] [string] $Destination
    )

    # Branches need the refs/heads form, while tags and commit SHAs resolve under the short one.
    $candidates = @(
        "https://github.com/$repo/archive/refs/heads/$Ref.zip"
        "https://github.com/$repo/archive/$Ref.zip"
    )

    $lastError = $null
    $everyAttemptWas404 = $true
    foreach ($url in $candidates) {
        foreach ($attempt in 1..3) {
            try {
                # -UseBasicParsing: a freshly imaged machine may have no Internet Explorer engine.
                Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
                return
            } catch {
                $lastError = $_
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                if ($status -eq 404) {
                    # The ref simply isn't there under this form; retrying cannot change that.
                    break
                }
                $everyAttemptWas404 = $false
                if ($attempt -lt 3) {
                    Write-Host "  Download attempt $attempt didn't work -- trying again..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }
        }
    }

    if ($everyAttemptWas404) {
        throw "$repo has no branch, tag or commit called '$Ref'. Check the name and run this again."
    }
    throw "Could not download '$Ref' from $repo ($($lastError.Exception.Message)). Check your internet connection or proxy settings, then run this again."
}

Write-Host ''
Write-Host 'Calm OS setup' -ForegroundColor Cyan
Write-Host "  Fetching '$Ref' from $repo..." -ForegroundColor DarkGray

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("calm-os-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    $zip = Join-Path $work 'source.zip'
    Save-CalmOsArchive -Destination $zip

    $expanded = Join-Path $work 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force

    # The signed copy the release pipeline publishes, then the source it was built from.
    $top = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
    if (-not $top) {
        throw "The download from '$Ref' was empty. Check that the branch or tag name is right."
    }

    $signed = Join-Path $top.FullName 'windows-dev-config'
    $source = Join-Path (Join-Path $top.FullName 'src') 'windows-dev-config'

    $setupDir = $null
    foreach ($candidate in @($signed, $source)) {
        if ((Test-Path (Join-Path $candidate 'dev-config.ps1')) -and (Test-Path (Join-Path $candidate 'steps'))) {
            $setupDir = $candidate
            break
        }
    }

    if (-not $setupDir) {
        # A folder having moved is not on its own a reason to give up.
        $found = Get-ChildItem -LiteralPath $expanded -Recurse -Filter 'dev-config.ps1' -File |
            Where-Object { Test-Path (Join-Path $_.DirectoryName 'steps') } |
            Select-Object -First 1
        if (-not $found) {
            throw "The download from '$Ref' doesn't contain the setup files. Check that the branch or tag name is right."
        }
        $setupDir = $found.DirectoryName
    } elseif ($setupDir -eq $source) {
        Write-Host "  '$Ref' has no signed copy yet, so its source files are being used." -ForegroundColor DarkGray
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    # Copied over the top so a run waiting on its reboot keeps its log and its tally.
    Copy-Item -LiteralPath (Join-Path $setupDir 'dev-config.ps1') -Destination $InstallRoot -Force
    Copy-Item -LiteralPath (Join-Path $setupDir 'steps') -Destination $InstallRoot -Recurse -Force

    # PowerShell refuses to load a file marked as downloaded, which is every file in this zip.
    Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

    # Cleared here because the setup restarts the machine, so the finally block never runs.
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

    $target = Join-Path $InstallRoot 'dev-config.ps1'
    Write-Host "  Ready in $InstallRoot" -ForegroundColor DarkGray

    if ($NoLaunch) {
        Write-Host ''
        Write-Host "Run it when you're ready:" -ForegroundColor Cyan
        Write-Host "  & '$target'" -ForegroundColor DarkGray
        return
    }

    # The file on disk is subject to the execution policy even though this script wasn't.
    $shell = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$target`"")
    $proc = Start-Process -FilePath $shell -ArgumentList $arguments -NoNewWindow -Wait -PassThru

    # No 'exit': this usually runs in the user's own console and would close their window.
    if ($proc.ExitCode -ne 0) {
        Write-Host ''
        Write-Host "Setup finished with exit code $($proc.ExitCode). The log is in $InstallRoot." -ForegroundColor Yellow
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
