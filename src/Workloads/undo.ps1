<#
.SYNOPSIS
  Undo (uninstall) a workload previously applied via its configuration.winget.

.DESCRIPTION
  Best-effort reversal of the winget DSC configurations under src/Workloads.
  For the selected workload it:
    * reverses the RunCommandOnSet / script extras first (npm global
      typescript, rustup toolchains, VS Code extensions, PSScriptAnalyzer
      settings, Visual Studio workloads),
    * then uninstalls the winget packages the configuration installed.

  Components shared by several workloads (PowerShell 7, VS Code, .NET SDK 10,
  Visual Studio Community, the Microsoft.VSCode.Dsc module) are kept by
  default so undoing one workload does not break another. Pass -IncludeShared
  to remove those too.

  winget DSC has no "unset", so this script mirrors each configuration by
  hand. Keep it in sync when a configuration.winget changes.

.PARAMETER Workload
  Workload to undo, or 'all' for every workload.

.PARAMETER IncludeShared
  Also uninstall components shared across workloads.

.EXAMPLE
  pwsh -File src/Workloads/undo.ps1 -Workload typescript

.EXAMPLE
  pwsh -File src/Workloads/undo.ps1 -Workload all -IncludeShared -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('typescript', 'php', 'python', 'dotnet', 'go', 'java',
                 'rust', 'sql', 'powershell', 'winforms', 'winui', 'all')]
    [string] $Workload,

    [switch] $IncludeShared
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Undo table. One entry per workload, mirroring its configuration.winget.
#   packages    : winget package ids to uninstall, in reverse install order.
#                 shared = $true is skipped unless -IncludeShared.
#   pre         : script blocks run before package uninstalls (undo the
#                 RunCommandOnSet / PowerShellScript extras).
#   vsWorkloads : Visual Studio workload/component ids to remove from the
#                 given product when the product itself is kept.
# ---------------------------------------------------------------------------
$undoTable = [ordered]@{
    typescript = @{
        pre = @(
            {
                if (Get-Command npm -ErrorAction SilentlyContinue) {
                    Invoke-Step "npm uninstall --global typescript" {
                        & npm uninstall --global --no-fund --no-audit typescript
                    }
                }
            }
        )
        packages = @(
            @{ id = 'OpenJS.NodeJS.LTS' }
        )
    }
    php = @{
        packages = @(
            @{ id = 'PHP.PHP.8.5' }
        )
    }
    python = @{
        packages = @(
            @{ id = 'astral-sh.uv' }
            @{ id = 'Python.Python.3.14' }
        )
    }
    dotnet = @{
        packages = @(
            @{ id = 'Microsoft.DotNet.SDK.10'; shared = $true }
        )
    }
    go = @{
        packages = @(
            @{ id = 'GoLang.Go' }
        )
    }
    java = @{
        packages = @(
            @{ id = 'Microsoft.OpenJDK.25' }
        )
    }
    rust = @{
        pre = @(
            {
                # `rustup self uninstall` removes ~/.cargo and ~/.rustup; the
                # winget uninstall below then clears the package registration.
                if (Get-Command rustup -ErrorAction SilentlyContinue) {
                    Invoke-Step "rustup self uninstall" {
                        & rustup self uninstall -y
                    }
                }
            }
        )
        packages = @(
            @{ id = 'Rustlang.Rustup' }
            # Installed by the rust flow to provide MSVC link.exe; heavyweight
            # and potentially useful to other tooling, so treated as shared.
            @{ id = 'Microsoft.VisualStudio.2022.BuildTools'; shared = $true }
        )
    }
    sql = @{
        pre = @(
            { Remove-VSCodeExtension 'ms-mssql.sql-database-projects-vscode' }
            { Remove-VSCodeDscModule }
        )
        packages = @(
            @{ id = 'Microsoft.SQLServer.2025.Developer' }
            @{ id = 'Microsoft.Sqlcmd' }
            @{ id = 'Microsoft.VisualStudioCode'; shared = $true }
            @{ id = 'Microsoft.PowerShell'; shared = $true }
        )
    }
    powershell = @{
        pre = @(
            { Remove-VSCodeExtension 'ms-vscode.powershell' }
            { Remove-VSCodeExtension 'pspester.pester-test' }
            { Remove-ScriptAnalyzerSettings }
            { Remove-VSCodeDscModule }
        )
        packages = @(
            @{ id = 'Microsoft.VisualStudioCode'; shared = $true }
            @{ id = 'Microsoft.PowerShell'; shared = $true }
        )
    }
    winforms = @{
        vsWorkloads = @{
            channelId = 'VisualStudio.18.Release'
            productId = 'Microsoft.VisualStudio.Product.Community'
            ids       = @('Microsoft.VisualStudio.Workload.ManagedDesktop')
        }
        packages = @(
            @{ id = 'Microsoft.VisualStudio.Community'; shared = $true }
            @{ id = 'Microsoft.DotNet.SDK.10'; shared = $true }
            @{ id = 'Microsoft.PowerShell'; shared = $true }
        )
    }
    winui = @{
        vsWorkloads = @{
            channelId = 'VisualStudio.18.Release'
            productId = 'Microsoft.VisualStudio.Product.Community'
            ids       = @(
                'Microsoft.VisualStudio.Workload.ManagedDesktop'
                'Microsoft.VisualStudio.Workload.Universal'
                'Microsoft.VisualStudio.ComponentGroup.WindowsAppSDK.Cs'
            )
        }
        packages = @(
            @{ id = 'Microsoft.WindowsAppRuntime.1.8' }
            @{ id = 'Microsoft.WinAppCLI' }
            @{ id = 'Microsoft.VisualStudio.Community'; shared = $true }
            @{ id = 'Microsoft.DotNet.SDK.10'; shared = $true }
            @{ id = 'Microsoft.PowerShell'; shared = $true }
        )
    }
}

# Workloads whose configurations reference each shared component. Used to
# warn when -IncludeShared removes something another workload may still need.
$sharedUsers = @{
    'Microsoft.PowerShell'                    = @('powershell', 'sql', 'winforms', 'winui')
    'Microsoft.VisualStudioCode'              = @('powershell', 'sql')
    'Microsoft.DotNet.SDK.10'                 = @('dotnet', 'winforms', 'winui')
    'Microsoft.VisualStudio.Community'        = @('winforms', 'winui')
    'Microsoft.VisualStudio.2022.BuildTools'  = @('rust')
}

$script:failures = @()

function Invoke-Step {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [scriptblock] $Action
    )
    if (-not $PSCmdlet.ShouldProcess($Description)) { return }
    Write-Host ">> $Description"
    try {
        $global:LASTEXITCODE = 0
        & $Action
        if ((Test-Path variable:LASTEXITCODE) -and $LASTEXITCODE -ne 0) {
            throw "exit code $LASTEXITCODE"
        }
    } catch {
        Write-Warning "FAILED: $Description — $_"
        $script:failures += $Description
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)] [string] $Id)
    & winget list --id $Id --exact --source winget --disable-interactivity `
        --accept-source-agreements *> $null
    return ($LASTEXITCODE -eq 0)
}

function Remove-WingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [bool] $Shared = $false
    )
    if ($Shared -and -not $IncludeShared) {
        $users = $sharedUsers[$Id] -join ', '
        Write-Host "-- keeping shared package $Id (used by: $users); pass -IncludeShared to remove"
        return
    }
    if (-not (Test-WingetPackageInstalled -Id $Id)) {
        Write-Host "-- $Id not installed; skipping"
        return
    }
    if ($Shared) {
        $users = $sharedUsers[$Id] -join ', '
        Write-Warning "$Id is shared by workloads: $users — removing because -IncludeShared was set"
    }
    Invoke-Step "winget uninstall $Id" {
        & winget uninstall --id $Id --exact --silent `
            --disable-interactivity --accept-source-agreements
    }
}

function Remove-VSCodeExtension {
    param([Parameter(Mandatory)] [string] $Name)
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Host "-- VS Code not on PATH; skipping extension $Name"
        return
    }
    $installed = @(& code --list-extensions 2>$null)
    if ($installed -notcontains $Name) {
        Write-Host "-- VS Code extension $Name not installed; skipping"
        return
    }
    Invoke-Step "code --uninstall-extension $Name" {
        & code --uninstall-extension $Name
    }
}

function Remove-VSCodeDscModule {
    # Shared helper module installed by the powershell and sql workloads.
    if (-not $IncludeShared) {
        Write-Host '-- keeping shared module Microsoft.VSCode.Dsc (used by: powershell, sql); pass -IncludeShared to remove'
        return
    }
    if (-not (Get-Command Get-InstalledPSResource -ErrorAction SilentlyContinue)) {
        Write-Host '-- PSResourceGet not available; skipping Microsoft.VSCode.Dsc removal'
        return
    }
    if (-not (Get-InstalledPSResource -Name Microsoft.VSCode.Dsc -ErrorAction SilentlyContinue)) {
        Write-Host '-- Microsoft.VSCode.Dsc module not installed; skipping'
        return
    }
    Invoke-Step 'Uninstall-PSResource Microsoft.VSCode.Dsc' {
        Uninstall-PSResource -Name Microsoft.VSCode.Dsc -Scope CurrentUser
    }
}

function Remove-ScriptAnalyzerSettings {
    # Reverses ConfigurePowerShellScriptAnalyzer in powershell/configuration.winget:
    # deletes PSScriptAnalyzerSettings.psd1 and the two settings.json keys.
    $userDirectory = Join-Path $env:APPDATA 'Code\User'
    $settingsPath = Join-Path $userDirectory 'settings.json'
    $analyzerSettingsPath = Join-Path $userDirectory 'PSScriptAnalyzerSettings.psd1'

    if (Test-Path -LiteralPath $analyzerSettingsPath) {
        Invoke-Step "remove $analyzerSettingsPath" {
            Remove-Item -LiteralPath $analyzerSettingsPath -Force
        }
    }

    if (Test-Path -LiteralPath $settingsPath) {
        Invoke-Step 'remove powershell.scriptAnalysis.* keys from VS Code settings.json' {
            $raw = Get-Content -LiteralPath $settingsPath -Raw
            $clean = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
            $clean = [regex]::Replace($clean, '(?m)^\s*//.*$', '')
            if ([string]::IsNullOrWhiteSpace($clean)) { return }
            $settings = $clean | ConvertFrom-Json -AsHashtable
            $settings.Remove('powershell.scriptAnalysis.enable')
            $settings.Remove('powershell.scriptAnalysis.settingsPath')
            $settings | ConvertTo-Json -Depth 100 |
                Set-Content -LiteralPath $settingsPath -Encoding utf8
        }
    }
}

function Remove-VSWorkloads {
    param([Parameter(Mandatory)] [hashtable] $Spec)

    # When the VS product itself is being removed, dropping individual
    # workloads first is pointless.
    if ($IncludeShared) {
        Write-Host '-- skipping per-workload VS modify; Visual Studio itself will be uninstalled'
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $setup   = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
    if (-not (Test-Path $vswhere) -or -not (Test-Path $setup)) {
        Write-Host '-- Visual Studio Installer not found; skipping VS workload removal'
        return
    }
    $installPath = & $vswhere -latest -products * -property installationPath
    if (-not $installPath) {
        Write-Host '-- no Visual Studio installation found; skipping VS workload removal'
        return
    }

    $removeArgs = @('modify', '--installPath', $installPath,
                    '--channelId', $Spec.channelId,
                    '--productId', $Spec.productId)
    foreach ($id in $Spec.ids) { $removeArgs += @('--remove', $id) }
    $removeArgs += @('--quiet', '--norestart', '--wait')

    Invoke-Step "VS setup.exe modify --remove $($Spec.ids -join ', ')" {
        & $setup @removeArgs
        # 3010 = success, reboot required.
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            throw "setup.exe exited with code $LASTEXITCODE"
        }
        $global:LASTEXITCODE = 0
    }
}

function Invoke-WorkloadUndo {
    param([Parameter(Mandatory)] [string] $Id)

    $spec = $undoTable[$Id]
    Write-Host ''
    Write-Host "=== Undo workload: $Id ==="

    if ($spec.Contains('pre')) {
        foreach ($step in $spec.pre) { & $step }
    }
    if ($spec.Contains('vsWorkloads')) {
        Remove-VSWorkloads -Spec $spec.vsWorkloads
    }
    foreach ($pkg in $spec.packages) {
        $isShared = $pkg.Contains('shared') -and $pkg.shared
        Remove-WingetPackage -Id $pkg.id -Shared $isShared
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found on PATH; cannot undo workload installs.'
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Not running elevated; machine-scope uninstalls may fail. Re-run from an elevated shell if steps fail.'
}

$targets = @($Workload)
if ($Workload -eq 'all') { $targets = @($undoTable.Keys) }

foreach ($id in $targets) {
    Invoke-WorkloadUndo -Id $id
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Warning "Completed with $($script:failures.Count) failed step(s):"
    $script:failures | ForEach-Object { Write-Warning "  - $_" }
    exit 1
}
Write-Host "UNDO_OK: $($targets -join ', ')"
