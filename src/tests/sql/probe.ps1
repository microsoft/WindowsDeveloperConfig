$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($commandName in @('sqlcmd', 'code')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "$commandName was not found on PATH."
    }
}

$ssms = Get-ItemProperty -Path @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
) -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like '*SQL Server Management Studio*' }
if (-not $ssms) {
    throw 'SQL Server Management Studio was not found in installed programs.'
}

Write-Output 'Hello, SQL developer!'