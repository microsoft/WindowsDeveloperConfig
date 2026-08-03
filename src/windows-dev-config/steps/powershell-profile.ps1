<#
.SYNOPSIS
  Adds the Oh My Posh init line to the PowerShell 7 profile.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Matches the oh-my-posh DSC resource's own detection: any non-commented line calling
# "oh-my-posh init" is treated as a valid, already-configured init, ours or user-customized.
$Script:OhMyPoshInitLineRegex = 'oh-my-posh(?:\.exe)?\s+init'

$Script:OhMyPoshInitCommand = @'
$(if (Get-Command 'oh-my-posh' -ErrorAction SilentlyContinue) { 
  oh-my-posh init pwsh
  # Set output encoding to UTF-8
  [Console]::OutputEncoding =[System.Text.Encoding]::UTF8
  # Set input encoding to UTF-8 (for reading user input with non-ASCII chars)
  [Console]::InputEncoding =[System.Text.Encoding]::UTF8
})
'@

function Get-DevConfigPwshProfilePath {
    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        return $null
    }
    # Ask pwsh itself for $PROFILE rather than hardcoding the path.
    return & $pwsh.Source -NoProfile -Command '$PROFILE'
}

function Test-DevConfigOhMyPoshInitLinePresent {
    param(
        [Parameter(Mandatory)] [string] $ProfilePath
    )
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        return $false
    }

    # Scan from the end: the last non-comment matching line is what counts, matching the source resource.
    $lines = @((Read-DevConfigTextFile -Path $ProfilePath) -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].TrimStart().StartsWith('#')) {
            continue
        }
        if ($lines[$i] -cmatch $Script:OhMyPoshInitLineRegex) {
            return $true
        }
    }
    return $false
}

function Test-DevConfigOhMyPoshProfileConfigured {
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        return $false
    }
    return Test-DevConfigOhMyPoshInitLinePresent -ProfilePath $profilePath
}

function Set-DevConfigOhMyPoshProfile {
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        throw 'pwsh.exe not found; install the PowerShell package first.'
    }

    if (Test-DevConfigOhMyPoshInitLinePresent -ProfilePath $profilePath) {
        return
    }

    # Mirrors the resource's own shellCommand(): the whole block piped to Invoke-Expression.
    $content = Read-DevConfigTextFile -Path $profilePath
    if (-not $content) {
        $content = ''
    }
    if ($content -and -not $content.EndsWith("`n")) {
        $content += "`n"
    }
    $content += "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n"

    Write-DevConfigTextFile -Path $profilePath -Content $content
    Write-Host "Added Oh My Posh init to $profilePath"
}

function Invoke-PowerShellProfilePhase {
    # BestEffort: this only changes what the prompt looks like, so it must never cost the run the
    # Copilot and WSL phases behind it.
    $steps = @(
        New-DevConfigStep -Name 'OhMyPoshProfile' -Description 'Add Oh My Posh init to the PowerShell 7 profile' -BestEffort `
            -Check { Test-DevConfigOhMyPoshProfileConfigured } `
            -Apply { Set-DevConfigOhMyPoshProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}
