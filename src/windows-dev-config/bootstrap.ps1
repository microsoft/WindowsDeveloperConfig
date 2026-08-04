<#
.SYNOPSIS
  Fetches the Calm OS developer workstation setup and starts it.

.DESCRIPTION
  Meant to be run straight from the web:

      irm https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1 | iex

  The setup itself cannot run from a piped-in string: it loads two dozen files from its own
  folder, relaunches itself elevated and on PowerShell 7, and registers a task to resume after
  the one reboot it needs. All of that wants real files in a real folder, so this puts them
  somewhere that survives a restart and then hands over.

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

if (-not $InstallRoot) {
    # Per-user and outside the profile's roaming path: it has to still be there after the reboot,
    # and the elevated relaunch is the same user, so this resolves to the same place either way.
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
                # -UseBasicParsing because a freshly imaged machine may have no Internet Explorer
                # engine for the parser to initialise, which fails the download for no real reason.
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

    # The archive's top folder is named after the ref, so find the orchestrator rather than
    # rebuilding that name and getting it wrong for a branch with slashes in it.
    $orchestrator = Get-ChildItem -LiteralPath $expanded -Recurse -Filter 'dev-config.ps1' -File |
        Where-Object { Test-Path (Join-Path $_.DirectoryName 'steps') } |
        Select-Object -First 1
    if (-not $orchestrator) {
        throw "The download from '$Ref' doesn't contain the setup files. Check that the branch or tag name is right."
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    # Copied over the top rather than replacing the folder: a run that is waiting on its reboot
    # keeps its log and its tally of what has already been done sitting right here.
    Copy-Item -LiteralPath $orchestrator.FullName -Destination $InstallRoot -Force
    Copy-Item -LiteralPath (Join-Path $orchestrator.DirectoryName 'steps') -Destination $InstallRoot -Recurse -Force

    # Files that arrived in a zip from the internet are marked as such, and PowerShell refuses to
    # load a marked file under the default policy -- which would stop the setup on its first line.
    Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

    # Cleared here rather than in the finally block below: the setup restarts the machine partway
    # through, so this process never comes back to run it, and the download would be left behind.
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

    $target = Join-Path $InstallRoot 'dev-config.ps1'
    Write-Host "  Ready in $InstallRoot" -ForegroundColor DarkGray

    if ($NoLaunch) {
        Write-Host ''
        Write-Host "Run it when you're ready:" -ForegroundColor Cyan
        Write-Host "  & '$target'" -ForegroundColor DarkGray
        return
    }

    # A child process with an explicit policy, because the file on disk is subject to the machine's
    # execution policy even though this bootstrap arrived as a string that wasn't. Same window: the
    # setup asks for elevation itself, and that prompt opens the window it actually runs in.
    $shell = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$target`"")
    $proc = Start-Process -FilePath $shell -ArgumentList $arguments -NoNewWindow -Wait -PassThru

    # Deliberately no 'exit': this script is usually running inside the user's own console, and
    # exiting would close their window along with whatever the setup just told them.
    if ($proc.ExitCode -ne 0) {
        Write-Host ''
        Write-Host "Setup finished with exit code $($proc.ExitCode). The log is in $InstallRoot." -ForegroundColor Yellow
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
