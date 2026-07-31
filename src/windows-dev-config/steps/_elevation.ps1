<#
.SYNOPSIS
  Admin check plus a one-time elevation relaunch, so the whole flow needs only a single UAC prompt.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DevConfigShellExe {
    # Prefer pwsh if it's already on PATH; Windows PowerShell 5.1 is always present as a fallback.
    if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
}

function Invoke-DevConfigElevate {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $NoElevate
    )

    if (Test-DevConfigIsAdmin) {
        return
    }

    if ($NoElevate) {
        throw 'Not running as Administrator and -NoElevate was passed; re-launch from an elevated shell.'
    }

    Write-Host 'This needs to run elevated once (a UAC prompt will appear)...' -ForegroundColor Yellow

    $shell        = Get-DevConfigShellExe
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-NoElevate')
    Start-Process -FilePath $shell -ArgumentList $relaunchArgs -Verb RunAs -Wait

    # The elevated relaunch already did the work; nothing left for this process to do.
    exit 0
}
