[CmdletBinding()]
param(
    [ValidateSet('Configure', 'Verify')]
    [string] $Action = 'Configure'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'common.ps1')

function Invoke-SlipstreamUserCopilot {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [string] $Operation
    )

    $output = @(& $FilePath @ArgumentList 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE`: $($output -join [Environment]::NewLine)"
    }
    return $output
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Per-user configuration must run with a limited token.'
    }

    Refresh-SlipstreamPath
    $copilot = Get-SlipstreamSignedCommand `
        -Name copilot.exe `
        -PublisherPattern 'O="?GitHub, Inc\.?"?'

    $marketplaces = Invoke-SlipstreamUserCopilot `
        -FilePath $copilot `
        -ArgumentList @('plugin', 'marketplace', 'list') `
        -Operation 'Query Copilot plugin marketplaces'
    if (($marketplaces -join "`n") -notmatch '(?i)win-dev-skills') {
        if ($Action -eq 'Verify') {
            throw 'Win Dev Skills marketplace is not configured.'
        }
        Invoke-SlipstreamUserCopilot `
            -FilePath $copilot `
            -ArgumentList @(
                'plugin', 'marketplace', 'add', 'microsoft/win-dev-skills'
            ) `
            -Operation 'Add Win Dev Skills marketplace' | Out-Null
    }

    $plugins = Invoke-SlipstreamUserCopilot `
        -FilePath $copilot `
        -ArgumentList @('plugin', 'list') `
        -Operation 'Query Copilot plugins'
    if (($plugins -join "`n") -notmatch '(?i)\bwinui\b') {
        if ($Action -eq 'Verify') {
            throw 'WinUI Copilot plugin is not installed.'
        }
        Invoke-SlipstreamUserCopilot `
            -FilePath $copilot `
            -ArgumentList @('plugin', 'install', 'winui@win-dev-skills') `
            -Operation 'Install WinUI Copilot plugin' | Out-Null
    }

    $plugins = Invoke-SlipstreamUserCopilot `
        -FilePath $copilot `
        -ArgumentList @('plugin', 'list') `
        -Operation 'Verify Copilot plugins'
    if (($plugins -join "`n") -notmatch '(?i)\bwinui\b') {
        throw 'WinUI Copilot plugin was not present after installation.'
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
