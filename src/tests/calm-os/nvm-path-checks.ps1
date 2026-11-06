# Checks which NVM variables the NvmPathVariables step converts, against temporary registry keys.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Join-Path $PSScriptRoot '..\..\windows-dev-config'
. (Join-Path $sourceRoot 'steps\packages.ps1')

$script:passed = 0
$script:failed = 0
function Assert-Check([bool] $Condition, [string] $Label) {
    if ($Condition) {
        Write-Host "PASS  $Label" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "FAIL  $Label" -ForegroundColor Red
        $script:failed++
    }
}

$root = "HKCU:\Software\DevConfigTests\nvm-path-$([guid]::NewGuid().ToString('N'))"
$keys = [ordered]@{ Machine = "$root\Machine"; User = "$root\User" }
foreach ($path in $keys.Values) { New-Item -Path $path -Force | Out-Null }
try {
    Assert-Check (-not (Test-DevConfigNvmPathVariables -Keys $keys)) 'Not done before NVM is installed, so it applies after the install'

    New-ItemProperty -LiteralPath $keys.Machine -Name 'NVM_HOME' -Value 'C:\Program Files\nvm' -PropertyType ExpandString | Out-Null
    New-ItemProperty -LiteralPath $keys.Machine -Name 'NVM_SYMLINK' -Value 'C:\nvm4w\nodejs' -PropertyType ExpandString | Out-Null
    $found = @(Get-DevConfigNvmExpandableVariable -Keys $keys)
    Assert-Check ($found.Count -eq 2 -and @($found | Where-Object { $_.Scope -ne 'Machine' }).Count -eq 0) 'Find both expandable machine variables'
    Assert-Check (($found | Where-Object { $_.Name -eq 'NVM_HOME' }).Value -eq 'C:\Program Files\nvm') 'Keep the value as written'
    Assert-Check (-not (Test-DevConfigNvmPathVariables -Keys $keys)) 'Report expandable variables as needing the fix'

    Set-ItemProperty -LiteralPath $keys.Machine -Name 'NVM_HOME' -Value 'C:\Program Files\nvm' -Type String
    Set-ItemProperty -LiteralPath $keys.Machine -Name 'NVM_SYMLINK' -Value 'C:\nvm4w\nodejs' -Type String
    Assert-Check (Test-DevConfigNvmPathVariables -Keys $keys) 'Report plain-string variables as done'

    Set-ItemProperty -LiteralPath $keys.Machine -Name 'NVM_SYMLINK' -Value '%SystemDrive%\nvm4w\nodejs' -Type ExpandString
    Assert-Check (@(Get-DevConfigNvmExpandableVariable -Keys $keys).Count -eq 0) 'Leave a value that names another variable expandable'

    New-ItemProperty -LiteralPath $keys.User -Name 'NVM_HOME' -Value 'C:\Users\Fixture\AppData\Local\nvm' -PropertyType ExpandString | Out-Null
    $found = @(Get-DevConfigNvmExpandableVariable -Keys $keys)
    Assert-Check ($found.Count -eq 1 -and $found[0].Scope -eq 'User') 'Find a per-user NVM_HOME'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'HKCU:\Software\DevConfigTests' -ErrorAction SilentlyContinue
}

Write-Host "Results: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
