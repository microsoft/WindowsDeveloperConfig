<#
.SYNOPSIS
  Calm OS developer workstation setup, in plain PowerShell.

.DESCRIPTION
  Configures apps, desktop/taskbar tweaks, the PowerShell profile, and WSL + Ubuntu.
  Safe to re-run: each phase skips work that's already done. The WSL phase runs
  last on purpose, so the one disruptive reboot it needs happens after everything
  else is configured; it resumes automatically after you log back in.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 defaults to the ANSI code page; force UTF-8 so glyphs render correctly.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

$stepsDir = Join-Path $PSScriptRoot 'steps'
. (Join-Path $stepsDir '_step-runner.ps1')
. (Join-Path $stepsDir '_elevation.ps1')
. (Join-Path $stepsDir '_reboot-resume.ps1')
. (Join-Path $stepsDir '_registry.ps1')
. (Join-Path $stepsDir '_environment.ps1')
. (Join-Path $stepsDir '_retry.ps1')

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate

# Whether this is a fresh start or the post-reboot resume, any leftover task is done with.
Clear-DevConfigResume

# WSL is last on purpose -- see the file header.
$phases = @(
    @{ File = 'packages.ps1';               Function = 'Invoke-PackagesPhase' }
    @{ File = 'registry-system.ps1';         Function = 'Invoke-RegistrySystemPhase' }
    @{ File = 'registry-explorer.ps1';       Function = 'Invoke-RegistryExplorerPhase' }
    @{ File = 'registry-taskbar-search.ps1'; Function = 'Invoke-RegistryTaskbarSearchPhase' }
    @{ File = 'edge.ps1';                    Function = 'Invoke-EdgePhase' }
    @{ File = 'fonts.ps1';                   Function = 'Invoke-FontsPhase' }
    @{ File = 'terminal.ps1';                Function = 'Invoke-TerminalPhase' }
    @{ File = 'powershell-profile.ps1';      Function = 'Invoke-PowerShellProfilePhase' }
    @{ File = 'copilot.ps1';                 Function = 'Invoke-CopilotPhase' }
    @{ File = 'wsl.ps1';                     Function = 'Invoke-WslPhase' }
)

foreach ($phase in $phases) {
    $path = Join-Path $stepsDir $phase.File
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "-- $($phase.File) not written yet, skipping" -ForegroundColor DarkGray
        continue
    }

    . $path
    if ($phase.File -eq 'wsl.ps1') {
        # The WSL phase needs the orchestrator's own path to register the reboot-resume task.
        Invoke-WslPhase -OrchestratorPath $PSCommandPath
    } else {
        & $phase.Function
    }

    if ($phase.File -eq 'packages.ps1') {
        # Packages installed above (pwsh, dotnet, git, ...) won't resolve on PATH until this refreshes.
        Update-DevConfigSessionPath
    }
}

Write-Host ''
Write-Host 'Calm OS setup complete.' -ForegroundColor Green
