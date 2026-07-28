<#
.SYNOPSIS
  Non-destructive validation for the Calm OS Slipstream payload.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$srcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$payloadRoot = Join-Path $srcRoot 'windows-dev-config'
$installPath = Join-Path $payloadRoot 'install.ps1'
$validationRoot = Join-Path $env:TEMP "WindowsDeveloperConfig-Validation-$([guid]::NewGuid())"

try {
    $summary = & $installPath -Action Validate -AllowUnsigned
    if ($summary.Status -ne 'Valid') {
        throw "Unexpected validation status: $($summary.Status)"
    }
    if ($summary.Scripts -ne 8 -or
        $summary.Packages -ne 15 -or
        $summary.RegistryValues -ne 26) {
        throw "Unexpected payload counts: scripts=$($summary.Scripts), packages=$($summary.Packages), registry=$($summary.RegistryValues)"
    }
    if ($summary.TaskLogonType -ne 'Interactive' -or $summary.TaskRunLevel -ne 'Highest') {
        throw "Unsafe resume principal: $($summary.TaskLogonType) / $($summary.TaskRunLevel)"
    }
    if ($summary.UserTaskLogonType -ne 'Interactive' -or
        $summary.UserTaskRunLevel -ne 'Limited') {
        throw "Unsafe user-task principal: $($summary.UserTaskLogonType) / $($summary.UserTaskRunLevel)"
    }

    . (Join-Path $payloadRoot 'bootstrap\common.ps1')
    $script:SlipstreamProgramDataRoot = $validationRoot
    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        runId = [guid]::NewGuid().ToString()
        status = 'Running'
        phase = 'Preflight'
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Save-SlipstreamState -State $state
    $state.phase = 'RepairPlatform'
    Save-SlipstreamState -State $state
    $roundTrip = Read-SlipstreamState -RunId $state.runId
    if ($roundTrip.phase -ne 'RepairPlatform') {
        throw 'Atomic state round-trip did not retain the latest phase.'
    }

    $runtimeScripts = Get-ChildItem `
        -LiteralPath $payloadRoot `
        -Recurse `
        -Filter *.ps1 `
        -File
    $dscReferences = $runtimeScripts |
        Select-String -Pattern '\bwinget\s+configure\b|\bdsc\.exe\b'
    if ($dscReferences) {
        throw "Slipstream runtime still invokes DSC: $($dscReferences.Path -join ', ')"
    }

    Write-Host 'SLIPSTREAM_VALIDATION_OK'
}
finally {
    if (Test-Path -LiteralPath $validationRoot) {
        Remove-Item -LiteralPath $validationRoot -Recurse -Force
    }
}
