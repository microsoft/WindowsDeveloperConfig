# Checks the Python install manager steps without installing Python or changing PATH.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$stepsDirectory = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
. (Join-Path $stepsDirectory '_environment.ps1')
. (Join-Path $stepsDirectory '_winget.ps1')
. (Join-Path $stepsDirectory 'packages.ps1')

$script:passed = 0
$script:failed = 0
function Check([string] $Name, [scriptblock] $Action) {
    try {
        & $Action
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "FAIL  ${Name}: $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}
function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$script:calls = [Collections.Generic.List[string]]::new()
$script:pyManager = 'C:\Fixture\pymanager.exe'
$script:installed = '{"versions": [{"id": "pythoncore-3.14-64", "sort-version": "3.14.2"}]}'
$script:online = '{"versions": [{"id": "pythoncore-3.14-64", "sort-version": "3.14.2"}]}'
$script:onPath = $true
$script:leftover = $false
$script:packagesRemoved = $true
$script:restoreWorks = $true
function Get-DevConfigPyManagerPath { $script:pyManager }
function Test-DevConfigUserPathEntry { param($Directory) $script:onPath }
function Test-DevConfigPythonLeftover { $script:leftover }
function Add-DevConfigUserPathEntry { param($Directory) $script:calls.Add("path $Directory") }
function Invoke-DevConfigPackageCleanup {
    param($Ids, [switch] $CheckOnly)
    if ($CheckOnly) { return $script:packagesRemoved }
    $script:calls.Add("cleanup $($Ids -join ',')")
}
function Invoke-DevConfigCleanupCommand {
    param($FilePath, $Arguments, $SuccessCodes)
    $script:calls.Add("$FilePath $($Arguments -join ' ')")
    if ($FilePath -eq 'winget.exe' -and $script:restoreWorks) { $script:pyManager = 'C:\Fixture\pymanager.exe' }
}
function Invoke-DevConfigNativeCommand {
    param($FilePath, $Arguments, $TimeoutSeconds)
    $script:calls.Add("$FilePath $($Arguments -join ' ')")
    $json = if ($Arguments -contains '--online') { $script:online } else { $script:installed }
    # pymanager can print notices around its JSON output.
    [pscustomobject]@{ ExitCode = 0; Output = "Welcome to the Python install manager.`r`n$json`r`n" }
}

Check 'Treat the runtime as missing until pymanager exists' {
    $script:calls.Clear()
    $script:pyManager = $null
    Assert (-not (Test-DevConfigPythonRuntime -Version '3.14')) 'A missing pymanager must report the runtime as missing.'
    Assert ($script:calls.Count -eq 0) 'No command may run without pymanager.'
    $script:pyManager = 'C:\Fixture\pymanager.exe'
}

Check 'Accept the newest managed release with its commands on PATH' {
    $script:calls.Clear()
    Assert (Test-DevConfigPythonRuntime -Version '3.14') 'The current release must count as done.'
    Assert ($script:calls[0] -eq 'C:\Fixture\pymanager.exe list --format=json --only-managed 3.14') "Unexpected query: $($script:calls[0])"
}

Check 'Reinstall when a newer patch release exists or the commands are off PATH' {
    $script:online = '{"versions": [{"id": "pythoncore-3.14-64", "sort-version": "3.14.3"}]}'
    Assert (-not (Test-DevConfigPythonRuntime -Version '3.14')) 'An older patch release must not count as done.'
    $script:online = $script:installed
    $script:onPath = $false
    Assert (-not (Test-DevConfigPythonRuntime -Version '3.14')) 'Commands missing from PATH must not count as done.'
    $script:onPath = $true
}

Check 'Ignore runtimes from other installers' {
    $script:installed = '{"versions": []}'
    Assert (-not (Test-DevConfigPythonRuntime -Version '3.14')) 'Only managed runtimes may satisfy the step.'
    $script:installed = $script:online
}

Check 'Install or update the runtime, then add its commands to PATH' {
    $script:calls.Clear()
    Install-DevConfigPythonRuntime -Version '3.14'
    Assert ($script:calls[0] -eq 'C:\Fixture\pymanager.exe install --update --yes 3.14') "Unexpected install: $($script:calls[0])"
    Assert ($script:calls[1] -eq "path $(Join-Path $env:LOCALAPPDATA 'Python\bin')") "Unexpected PATH change: $($script:calls[1])"
}

Check 'Purge managed runtimes before uninstalling the manager' {
    $script:calls.Clear()
    Remove-DevConfigPython -ManagerId 'Python.PythonInstallManager' -Ids @('Python.PythonInstallManager', 'Python.Python.3.14')
    Assert (($script:calls -join '|') -eq 'C:\Fixture\pymanager.exe uninstall --purge --yes|cleanup Python.PythonInstallManager,Python.Python.3.14') "Unexpected cleanup: $($script:calls -join '|')"
    $script:calls.Clear()
    $script:pyManager = $null
    Remove-DevConfigPython -ManagerId 'Python.PythonInstallManager' -Ids @('Python.PythonInstallManager')
    Assert (($script:calls -join '|') -eq 'cleanup Python.PythonInstallManager') 'Without pymanager or leftovers, only package cleanup may run.'
    $script:pyManager = 'C:\Fixture\pymanager.exe'
}

Check 'Restore a manager removed on its own so leftover runtimes can be purged' {
    $script:calls.Clear()
    $script:pyManager = $null
    $script:leftover = $true
    Remove-DevConfigPython -ManagerId 'Python.PythonInstallManager' -Ids @('Python.PythonInstallManager')
    Assert ($script:calls.Count -eq 3) "Unexpected cleanup: $($script:calls -join '|')"
    Assert ($script:calls[0] -like 'winget.exe install --id Python.PythonInstallManager --exact --source winget *--disable-interactivity') "Unexpected restore: $($script:calls[0])"
    Assert ($script:calls[1] -eq 'C:\Fixture\pymanager.exe uninstall --purge --yes') "Unexpected purge: $($script:calls[1])"
    Assert ($script:calls[2] -eq 'cleanup Python.PythonInstallManager') "Unexpected package cleanup: $($script:calls[2])"
    $script:leftover = $false
}

Check 'Report leftover runtimes when the manager cannot be restored' {
    $script:calls.Clear()
    $script:pyManager = $null
    $script:leftover = $true
    $script:restoreWorks = $false
    $message = $null
    try { Remove-DevConfigPython -ManagerId 'Python.PythonInstallManager' -Ids @('Python.PythonInstallManager') } catch { $message = $_.Exception.Message }
    Assert ($message -like '*runtimes remain*winget install -e --id Python.PythonInstallManager*') "Unexpected error: $message"
    Assert ($script:calls.Count -eq 1) 'Nothing may be purged or uninstalled after a failed restore.'
    $script:leftover = $false
    $script:restoreWorks = $true
    $script:pyManager = 'C:\Fixture\pymanager.exe'
}

Check 'Count cleanup as done only when packages and leftovers are gone' {
    $script:leftover = $true
    Assert (-not (Test-DevConfigPythonRemoved -Ids @('Python.PythonInstallManager'))) 'Leftover runtimes must keep cleanup pending.'
    $script:leftover = $false
    $script:packagesRemoved = $false
    Assert (-not (Test-DevConfigPythonRemoved -Ids @('Python.PythonInstallManager'))) 'Installed packages must keep cleanup pending.'
    $script:packagesRemoved = $true
    Assert (Test-DevConfigPythonRemoved -Ids @('Python.PythonInstallManager')) 'No packages or leftovers means cleanup is done.'
}

Check 'Expand PATH entries only when the user PATH is REG_EXPAND_SZ' {
    . (Join-Path $stepsDirectory '_environment.ps1')
    $script:pathValue = [pscustomobject]@{ Value = 'C:\Other;%LOCALAPPDATA%\Python\bin\'; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    function Get-DevConfigUserPathValue { $script:pathValue }
    $commands = Join-Path $env:LOCALAPPDATA 'Python\bin'
    Assert (Test-DevConfigUserPathEntry -Directory $commands) 'An expandable entry must match.'
    Assert (-not (Test-DevConfigUserPathEntry -Directory 'C:\Missing')) 'An absent entry must not match.'
    $script:pathValue.Kind = [Microsoft.Win32.RegistryValueKind]::String
    Assert (-not (Test-DevConfigUserPathEntry -Directory $commands)) 'A REG_SZ PATH keeps %VAR% literal, so it must not match.'
    $script:pathValue.Value = "C:\Other;$commands"
    Assert (Test-DevConfigUserPathEntry -Directory $commands) 'An absolute REG_SZ entry must match.'
}

Write-Host "Results: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
