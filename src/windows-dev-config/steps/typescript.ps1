<#
.SYNOPSIS
  Installs or verifies the global TypeScript compiler.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigTypeScriptCompiler {
    return $null -ne (Get-Command tsc -ErrorAction SilentlyContinue)
}

function Set-DevConfigTypeScriptCompiler {
    Update-DevConfigSessionPath
    $npm = Get-Command npm -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-DevConfigNativeCommand -FilePath $npm.Source `
        -Arguments @('install', '--global', '--no-fund', '--no-audit', 'typescript') `
        -TimeoutSeconds 1800
    if ($result.ExitCode -ne 0) {
        Write-Host $result.Output
        throw "npm failed to install TypeScript (exit code $($result.ExitCode))."
    }
    if (-not (Test-DevConfigTypeScriptCompiler)) {
        throw 'npm reported success, but the TypeScript compiler is not available on PATH.'
    }
}

function Invoke-TypeScriptPhase {
    Show-DevConfigPhaseHeader

    $steps = @(
        New-DevConfigStep -Name 'TypeScriptCompiler' -Description 'Install the TypeScript compiler globally with npm.' `
            -Check { Test-DevConfigTypeScriptCompiler } `
            -Apply { Set-DevConfigTypeScriptCompiler }
    )
    Invoke-DevConfigSteps -Steps $steps
}
