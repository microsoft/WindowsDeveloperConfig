$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($commandName in @('sqlcmd', 'code')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "$commandName was not found on PATH."
    }
}

Write-Output 'Hello, SQL developer!'