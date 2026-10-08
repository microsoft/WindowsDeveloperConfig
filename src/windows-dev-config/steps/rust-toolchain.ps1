<#
.SYNOPSIS
  Installs and defaults the stable Rust toolchain (rustc, cargo, ...) via rustup.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigRustStableToolchain {
    if (-not (Get-Command 'rustup' -CommandType Application -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'rustup' -Arguments @('toolchain', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match '(?im)^stable-.*\(default\)\s*$'
}

function Set-DevConfigRustStableToolchain {
    if (-not (Get-Command 'rustup' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'rustup is not on PATH yet, so the Rust toolchain cannot be installed. Re-run once Rustup is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'rustup' -Arguments @('default', 'stable')
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "rustup default stable failed with exit code $($r.ExitCode)"
    }
}

function Invoke-RustToolchainPhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        throw 'The Rust toolchain phase has no cleanup steps yet, so no workload can include it in Uninstall.'
    }

    Show-DevConfigPhaseHeader

    $steps = @(
        New-DevConfigStep -Name 'RustStableToolchain' -Description 'Install and default the stable Rust toolchain' `
            -Check { Test-DevConfigRustStableToolchain } `
            -Apply { Set-DevConfigRustStableToolchain }
    )

    Invoke-DevConfigSteps -Steps $steps
}
