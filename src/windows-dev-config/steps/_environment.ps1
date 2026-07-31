<#
.SYNOPSIS
  Refreshes this process's PATH from the registry, so tools installed earlier in the same run become runnable.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Update-DevConfigSessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = @($machinePath, $userPath) -join ';'
}
