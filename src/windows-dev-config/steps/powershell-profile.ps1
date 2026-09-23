<#
.SYNOPSIS
  Configures Oh My Posh initialization in the PowerShell 7 profile.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exact text is needed to recognize existing setup blocks.
$Script:OhMyPoshInitCommand = @'
$(if (Get-Command 'oh-my-posh' -ErrorAction SilentlyContinue) { 
  oh-my-posh init pwsh
  # Set output encoding to UTF-8
  [Console]::OutputEncoding =[System.Text.Encoding]::UTF8
  # Set input encoding to UTF-8 (for reading user input with non-ASCII chars)
  [Console]::InputEncoding =[System.Text.Encoding]::UTF8
})
'@

function Get-DevConfigOhMyPoshProfileBlock {
    $block = "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n" -replace "`r`n", "`n"
    $gate = @'
$usePosh = [bool]$env:WT_SESSION
if (-not $usePosh) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $usePosh = -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        $identity.Dispose()
    }
}
if ($usePosh) {
'@
    return ($gate -replace "`r`n", "`n") + "`n" + $block + "}`n"
}

function Get-DevConfigPwshProfilePath {
    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        return $null
    }
    # Ask pwsh for $PROFILE so the path follows the installed shell.
    return & $pwsh.Source -NoProfile -Command '$PROFILE'
}

function Get-DevConfigProfileAst {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "The PowerShell profile could not be parsed and was left unchanged: $($parseErrors[0].Message)"
    }
    return $ast
}

function Test-DevConfigOhMyPoshInitPresent {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $ast = Get-DevConfigProfileAst -Content $Content
    return $null -ne $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -match '(^|[\\/])oh-my-posh(?:\.exe)?$' -and
            $node.CommandElements.Count -gt 1 -and
            $node.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.CommandElements[1].Value -eq 'init'
    }, $true)
}

function Test-DevConfigOhMyPoshProfileConfigured {
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        return $false
    }
    $content = [string](Read-DevConfigTextFile -Path $profilePath) -replace "`r`n", "`n"
    $desiredBlock = Get-DevConfigOhMyPoshProfileBlock
    return $content.Contains($desiredBlock) -and
        -not (Test-DevConfigOhMyPoshInitPresent -Content $content.Replace($desiredBlock, ''))
}

function Set-DevConfigOhMyPoshProfile {
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        throw 'pwsh.exe not found; install the PowerShell package first.'
    }

    $content = [string](Read-DevConfigTextFile -Path $profilePath) -replace "`r`n", "`n"
    $legacyBlock = "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n" -replace "`r`n", "`n"
    $desiredBlock = Get-DevConfigOhMyPoshProfileBlock

    $managedBlock = if ($content.Contains($desiredBlock)) { $desiredBlock } else { $legacyBlock }
    if (Test-DevConfigOhMyPoshInitPresent -Content $content.Replace($managedBlock, '')) {
        throw 'Oh My Posh initialization outside the setup block was left unchanged. Adjust it manually to run only in Windows Terminal or non-elevated shells.'
    }

    if ($content.Contains($desiredBlock)) {
        return
    } elseif ($content.Contains($legacyBlock)) {
        $content = $content.Replace($legacyBlock, $desiredBlock)
    } else {
        if ($content -and -not $content.EndsWith("`n")) {
            $content += "`n"
        }
        $content += $desiredBlock
    }

    Write-DevConfigTextFile -Path $profilePath -Content $content
    Write-Host "Configured Oh My Posh init in $profilePath"
}

function Remove-DevConfigOhMyPoshProfile {
    param(
        [switch] $CheckOnly
    )
    $profilePath = Get-DevConfigPwshProfilePath
    if (-not $profilePath) {
        $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }
    $original = [string](Read-DevConfigTextFile -Path $profilePath)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($original, [ref]$tokens, [ref]$parseErrors)
    $content = $original
    $blocks = @(
        Get-DevConfigOhMyPoshProfileBlock
        "$Script:OhMyPoshInitCommand`n | Invoke-Expression`n" -replace "`r`n", "`n"
    )
    $blocks += @($blocks | ForEach-Object { $_.Replace("`n", "`r`n") })
    if ($ast.EndBlock) {
        # Match only top-level setup blocks, not examples in strings or custom functions.
        foreach ($statement in @($ast.EndBlock.Statements | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $start = $statement.Extent.StartOffset
            foreach ($block in $blocks) {
                if ($original.Substring($start).StartsWith($block, [StringComparison]::Ordinal)) {
                    $content = $content.Remove($start, $block.Length)
                    break
                }
            }
        }
    }
    # Validate after removing setup blocks, whose leading-pipe syntax requires PowerShell 7.
    [void](Get-DevConfigProfileAst -Content $content)
    if ($CheckOnly) {
        return $content -eq $original
    }
    if ($content -ne $original) {
        Write-DevConfigTextFile -Path $profilePath -Content $content
    }
}

function Invoke-PowerShellProfilePhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @(
            New-DevConfigStep -Name 'OhMyPoshProfileCleanup' -Description 'Remove managed Oh My Posh profile initialization' -BestEffort `
                -Check { Remove-DevConfigOhMyPoshProfile -CheckOnly } `
                -Apply { Remove-DevConfigOhMyPoshProfile }
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # BestEffort keeps prompt customization from blocking later phases.
    $steps = @(
        New-DevConfigStep -Name 'OhMyPoshProfile' -Description 'Add Oh My Posh init to the PowerShell 7 profile' -BestEffort `
            -Check { Test-DevConfigOhMyPoshProfileConfigured } `
            -Apply { Set-DevConfigOhMyPoshProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}
