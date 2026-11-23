# Checks the Python install manager steps without installing Python or changing PATH.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$stepsDirectory = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
. (Join-Path $stepsDirectory '_environment.ps1')
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
function Get-DevConfigPyManagerPath { $script:pyManager }
function Test-DevConfigUserPathEntry { param($Directory) $script:onPath }
function Add-DevConfigUserPathEntry { param($Directory) $script:calls.Add("path $Directory") }
function Invoke-DevConfigPackageCleanup { param($Ids) $script:calls.Add("cleanup $($Ids -join ',')") }
function Invoke-DevConfigCleanupCommand {
    param($FilePath, $Arguments)
    $script:calls.Add("$FilePath $($Arguments -join ' ')")
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
    Remove-DevConfigPython -Ids @('Python.PythonInstallManager', 'Python.Python.3.14')
    Assert (($script:calls -join '|') -eq 'C:\Fixture\pymanager.exe uninstall --purge --yes|cleanup Python.PythonInstallManager,Python.Python.3.14') "Unexpected cleanup: $($script:calls -join '|')"
    $script:calls.Clear()
    $script:pyManager = $null
    Remove-DevConfigPython -Ids @('Python.PythonInstallManager')
    Assert (($script:calls -join '|') -eq 'cleanup Python.PythonInstallManager') 'Without pymanager, only package cleanup may run.'
    $script:pyManager = 'C:\Fixture\pymanager.exe'
}

Check 'Match PATH entries after expanding environment variables' {
    . (Join-Path $stepsDirectory '_environment.ps1')
    function Get-DevConfigUserPathValue {
        [pscustomobject]@{ Value = 'C:\Other;%LOCALAPPDATA%\Python\bin\'; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    }
    Assert (Test-DevConfigUserPathEntry -Directory (Join-Path $env:LOCALAPPDATA 'Python\bin')) 'An expandable entry must match.'
    Assert (-not (Test-DevConfigUserPathEntry -Directory 'C:\Missing')) 'An absent entry must not match.'
}

Write-Host "Results: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
