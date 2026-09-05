<#
.SYNOPSIS
  Adds the Oh My Posh init line to the PowerShell 7 profile.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Any oh-my-posh init line that is not commented out means the profile is already configured.
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
    # Ask pwsh for $PROFILE so the path follows the installed shell.
    return & $pwsh.Source -NoProfile -Command '$PROFILE'
}

function Test-DevConfigOhMyPoshInitLinePresent {
    param(
        [Parameter(Mandatory)] [string] $ProfilePath
    )
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        return $false
    }

    # Scan from the end so the last non-comment matching line controls the result.
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

    # The whole block is piped to Invoke-Expression, which is the documented Oh My Posh init form.
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
    # BestEffort keeps prompt customization from blocking later phases.
    $steps = @(
        New-DevConfigStep -Name 'OhMyPoshProfile' -Description 'Add Oh My Posh init to the PowerShell 7 profile' -BestEffort `
            -Check { Test-DevConfigOhMyPoshProfileConfigured } `
            -Apply { Set-DevConfigOhMyPoshProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}
