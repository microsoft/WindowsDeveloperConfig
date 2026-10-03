<#
.SYNOPSIS
  Checks WinGet source retries without installing packages or changing the machine.
#>
param(
    [string] $StepsDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $StepsDirectory) {
    $StepsDirectory = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
}
. (Join-Path $StepsDirectory '_retry.ps1')
. (Join-Path $StepsDirectory '_winget.ps1')
. (Join-Path $StepsDirectory '_step-runner.ps1')
. (Join-Path $StepsDirectory 'packages.ps1')

Add-Type -TypeDefinition @'
namespace Microsoft.WinGet.Client.Engine.Exceptions
{
    public class CatalogConnectException : System.Management.Automation.RuntimeException
    {
        public CatalogConnectException(System.Exception inner) : base("Catalog connection failed", inner) {}
    }
}
'@

$passed = 0
$failed = 0
function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Expect-Failure([scriptblock] $Action) {
    try { & $Action } catch { return $_ }
    throw 'Expected an error, but the operation succeeded.'
}
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
function Reset-TestState([string] $Mode = 'Cli') {
    . (Join-Path $StepsDirectory '_winget.ps1')
    . (Join-Path $StepsDirectory '_step-runner.ps1')
    $Script:DevConfigWinGetMode = $Mode
    $Script:Results = [Collections.Generic.Queue[object]]::new()
    $Script:Calls = @()
    $Script:Delays = @()
    $Script:Repairs = 0
    $Script:LocalApplied = $false
}
function Read-MockResult([string] $Command) {
    $Script:Calls += $Command
    if ($Script:Results.Count -eq 0) { throw "Unexpected command: $Command" }
    $result = $Script:Results.Dequeue()
    if ($result -is [Exception]) { throw $result }
    return $result
}
function Invoke-DevConfigNativeCommand($FilePath, $Arguments) {
    Assert ($FilePath -eq 'winget.exe') "Unexpected executable: $FilePath"
    Read-MockResult "$FilePath $($Arguments -join ' ')"
}
function Get-WinGetPackage($Id, $Source, $MatchOption, $ErrorAction) {
    Assert ($Source -eq 'winget') 'Module query must target winget.'
    Read-MockResult "Get-WinGetPackage $Id"
}
function Install-WinGetPackage($Id, $Source, $Mode, $MatchOption, $ErrorAction) {
    Assert ($Source -eq 'winget') 'Module install must target winget.'
    Read-MockResult "Install-WinGetPackage $Id"
}
function Start-Sleep($Seconds) { $Script:Delays += $Seconds }
function Initialize-DevConfigWinGet {}
function Invoke-DevConfigWinGetDeployment { $Script:Repairs++ }
function Get-DevConfigPackageCatalog {
    foreach ($index in 1..18) {
        @{
            Name = "Tool$index"
            Id = "Example.Tool$index"
            AnyVersion = $true
            Settings = if ($index -eq 1) { @(@{ Name = 'LocalSetting' }) } else { @() }
        }
    }
}
function New-DevConfigRegistryStep($Setting) {
    New-DevConfigStep -Name $Setting.Name -Check { $Script:LocalApplied } -Apply { $Script:LocalApplied = $true }
}
function New-CliResult([int] $Code = 0, [string] $Output = '') {
    [pscustomobject]@{ ExitCode = $Code; Output = $Output }
}
function New-ModuleResult([string] $Status = 'Ok', [int] $Code = 0) {
    $result = [pscustomobject]@{
        Status = $Status
        ExtendedErrorCode = [Runtime.InteropServices.COMException]::new('Install error', $Code)
    }
    $result | Add-Member ScriptMethod Succeeded { $this.Status -eq 'Ok' }
    $result | Add-Member ScriptMethod ErrorMessage { "Install status: $($this.Status)" }
    return $result
}
function New-CatalogFailure([int] $Code = -1978335217) {
    [Microsoft.WinGet.Client.Engine.Exceptions.CatalogConnectException]::new(
        [Runtime.InteropServices.COMException]::new('Source error', $Code))
}

foreach ($code in @(-1978335217, -1978335163, -1978335157)) {
    Check "CLI source failure $code stops repeated package work" {
        Reset-TestState
        foreach ($attempt in 1..3) { $Script:Results.Enqueue((New-CliResult $code)) }
        Invoke-PackagesPhase -Packages @(1..18 | ForEach-Object { "Tool$_" })
        Assert ($Script:Calls.Count -eq 3) 'Offline packages must share three attempts.'
        Assert (($Script:Delays -join ',') -eq '5,10') 'Only one retry backoff allowance is expected.'
        Assert ($Script:DevConfigTally.Warned -eq 18) 'Every unverified package must be flagged.'
        Assert ($Script:DevConfigTally.Done -eq 1 -and $Script:DevConfigTally.AlreadyOk -eq 0) 'Only the local setting may succeed.'
        Assert $Script:LocalApplied 'Independent settings must still apply.'
        Assert (@($Script:Calls | Where-Object { $_ -notmatch '--source winget' }).Count -eq 0) 'CLI queries must target only winget.'
        $Script:LocalApplied = $false
        Invoke-DevConfigSteps -Steps @(New-DevConfigStep -Name 'LaterPhase' -Check { $Script:LocalApplied } -Apply { $Script:LocalApplied = $true })
        Assert $Script:LocalApplied 'Later local phases must still run.'
    }
}

Check 'Module source failure during readiness flags packages without aborting local settings' {
    Reset-TestState Module
    foreach ($attempt in 1..3) { $Script:Results.Enqueue((New-CatalogFailure)) }
    Invoke-PackagesPhase -Packages @(1..18 | ForEach-Object { "Tool$_" })
    Assert ($Script:Calls.Count -eq 3 -and $Script:Repairs -eq 0) 'Source errors must not trigger RPC repair.'
    Assert (($Script:Delays -join ',') -eq '5,10') 'Module recovery must use one retry allowance.'
    Assert ($Script:DevConfigTally.Warned -eq 18 -and $Script:DevConfigTally.Done -eq 1) 'Flag packages, not local settings.'
    Assert $Script:LocalApplied 'Local settings must run after a module source failure.'
}

foreach ($mode in @('Cli', 'Module')) {
    Check "$mode source recovery during retry permits subsequent installs" {
        Reset-TestState $mode
        foreach ($attempt in 1..2) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult -1978335217 } else { New-CatalogFailure }))
        }
        $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult $Script:DevConfigWingetNotFound } else { $null }))
        Assert (-not (Test-DevConfigWingetPackageInstalled -Id 'Example.First')) 'Recovered query must report the missing package.'
        foreach ($id in @('Example.First', 'Example.Second')) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult } else { New-ModuleResult }))
            Install-DevConfigWingetPackage -Id $id
        }
        Assert ($Script:Calls.Count -eq 5 -and -not $Script:DevConfigWingetSourceFailure) 'Recovery must leave package work enabled.'
        Assert (($Script:Delays -join ',') -eq '5,10') 'Recovery must retain existing backoff.'
    }

    Check "$mode source failure during install prevents further source operations" {
        Reset-TestState $mode
        foreach ($attempt in 1..3) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult -1978335217 } else { New-ModuleResult 'CatalogError' -1978335217 }))
        }
        $failure = Expect-Failure { Install-DevConfigWingetPackage -Id 'Example.First' }
        Assert ($failure.Exception.Message -match 'Check your connection.*run setup again') 'Error must explain how to retry.'
        $null = Expect-Failure { Test-DevConfigWingetPackageInstalled -Id 'Example.Second' }
        $null = Expect-Failure { Install-DevConfigWingetPackage -Id 'Example.Second' }
        Assert ($Script:Calls.Count -eq 3 -and $Script:Delays.Count -eq 2) 'Skipped packages must not query, install, or sleep.'
    }

    Check "$mode package-specific failures keep independent retry allowances" {
        Reset-TestState $mode
        foreach ($id in @('Example.First', 'Example.Second')) {
            foreach ($attempt in 1..3) {
                $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult -1 } else { New-ModuleResult 'InstallError' -1 }))
            }
            $null = Expect-Failure { Install-DevConfigWingetPackage -Id $id }
        }
        Assert ($Script:Calls.Count -eq 6 -and -not $Script:DevConfigWingetSourceFailure) 'Installer failures must not disable the source.'
        Assert (($Script:Delays -join ',') -eq '5,10,5,10') 'Each installer must retain its retries.'
    }

    Check "$mode healthy package phase checks, installs, and verifies all packages" {
        Reset-TestState $mode
        if ($mode -eq 'Module') { $Script:Results.Enqueue($null) }
        foreach ($index in 1..18) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult $Script:DevConfigWingetNotFound } else { $null }))
        }
        foreach ($index in 1..18) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult } else { New-ModuleResult }))
            foreach ($verification in 1..2) {
                $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult } else { [pscustomobject]@{ IsUpdateAvailable = $false } }))
            }
        }
        Invoke-PackagesPhase -Packages @(1..18 | ForEach-Object { "Tool$_" })
        Assert ($Script:Results.Count -eq 0) 'All checks, installs, and verifications must execute.'
        Assert ($Script:DevConfigTally.Done -eq 19 -and $Script:DevConfigTally.Warned -eq 0) 'Healthy installs must be verified, not flagged.'
        Assert ($Script:Delays.Count -eq 0) 'Successful operations must not back off.'
    }

    Check "$mode source loss after a successful precheck preserves already-current packages" {
        Reset-TestState $mode
        if ($mode -eq 'Module') { $Script:Results.Enqueue($null) }
        $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult } else { [pscustomobject]@{ IsUpdateAvailable = $false } }))
        foreach ($attempt in 1..3) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult -1978335217 } else { New-CatalogFailure }))
        }
        Invoke-PackagesPhase -Packages @(1..18 | ForEach-Object { "Tool$_" })
        Assert ($Script:Results.Count -eq 0) 'Source loss must receive its recovery attempts.'
        Assert ($Script:DevConfigTally.AlreadyOk -eq 1 -and $Script:DevConfigTally.Warned -eq 17) 'Verified packages must stay current; remaining packages must be flagged.'
        Assert ($Script:DevConfigWarnedSteps -notcontains 'Tool1') 'Do not flag the verified package.'
        Assert ($Script:LocalApplied -and $Script:Delays.Count -eq 2) 'Local settings must continue without per-package backoff.'
    }

    Check "$mode source failure during post-install verification is not reported as success" {
        Reset-TestState $mode
        if ($mode -eq 'Module') { $Script:Results.Enqueue($null) }
        $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult $Script:DevConfigWingetNotFound } else { $null }))
        $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult } else { New-ModuleResult }))
        foreach ($attempt in 1..3) {
            $Script:Results.Enqueue($(if ($mode -eq 'Cli') { New-CliResult -1978335217 } else { New-CatalogFailure }))
        }
        Invoke-PackagesPhase -Packages @('Tool1')
        Assert ($Script:Results.Count -eq 0 -and $Script:DevConfigTally.Warned -eq 1) 'Unverified installation must be flagged.'
        Assert ($Script:DevConfigTally.Done -eq 1 -and $Script:LocalApplied) 'Only local settings may report success.'
        Assert (($Script:Delays -join ',') -eq '5,10') 'Catalog settling must not add more retries after source exhaustion.'
    }
}

Check 'A new run clears exhausted source state' {
    Reset-TestState
    foreach ($attempt in 1..3) { $Script:Results.Enqueue((New-CliResult -1978335157)) }
    $null = Expect-Failure { Test-DevConfigWingetPackageInstalled -Id 'Example.Tool' }
    Assert $Script:DevConfigWingetSourceFailure 'First run must exhaust its source retries.'
    . (Join-Path $StepsDirectory '_winget.ps1')
    $Script:DevConfigWinGetMode = 'Cli'
    $Script:Results.Enqueue((New-CliResult))
    Install-DevConfigWingetPackage -Id 'Example.Tool'
    Assert ($Script:Calls.Count -eq 4 -and -not $Script:DevConfigWingetSourceFailure) 'Reloading the helper must allow retrying on a new run.'
}

Check 'CLI no-upgrade exit remains successful without retrying' {
    Reset-TestState
    $Script:Results.Enqueue((New-CliResult $Script:DevConfigWingetNoUpgrade))
    Install-DevConfigWingetPackage -Id 'Example.Tool'
    Assert ($Script:Calls.Count -eq 1 -and $Script:Delays.Count -eq 0) 'No-upgrade must remain a success.'
}

Check 'Module NoApplicableUpgrade remains successful without retrying' {
    Reset-TestState Module
    $Script:Results.Enqueue((New-ModuleResult 'NoApplicableUpgrade'))
    Install-DevConfigWingetPackage -Id 'Example.Tool'
    Assert ($Script:Calls.Count -eq 1 -and $Script:Delays.Count -eq 0) 'No-upgrade must remain a success.'
}

Check 'CLI upgrade checks distinguish current and outdated packages' {
    foreach ($outdated in @($false, $true)) {
        Reset-TestState
        $Script:Results.Enqueue((New-CliResult))
        $Script:Results.Enqueue((New-CliResult -Output $(if ($outdated) { 'Tool Example.Tool 1.0 2.0 winget' } else { 'No upgrades' })))
        Assert ((Test-DevConfigWingetPackageInstalled -Id 'Example.Tool') -eq (-not $outdated)) 'Upgrade availability must be preserved.'
        Assert ($Script:Calls[1] -match '--source winget.*--upgrade-available') 'Upgrade query must use the same source.'
    }
}

Check 'Module upgrade checks distinguish current and outdated packages' {
    foreach ($outdated in @($false, $true)) {
        Reset-TestState Module
        $Script:Results.Enqueue([pscustomobject]@{ IsUpdateAvailable = $outdated })
        Assert ((Test-DevConfigWingetPackageInstalled -Id 'Example.Tool') -eq (-not $outdated)) 'Module update detection must be preserved.'
    }
}

Check 'Failed CLI upgrade source queries must not report a package as current' {
    Reset-TestState
    $Script:Results.Enqueue((New-CliResult))
    foreach ($attempt in 1..3) { $Script:Results.Enqueue((New-CliResult -1978335163)) }
    $null = Expect-Failure { Test-DevConfigWingetPackageInstalled -Id 'Example.Tool' }
    Assert ($Script:Calls.Count -eq 4 -and $Script:DevConfigWingetSourceFailure) 'Failed upgrade query must exhaust the shared source allowance.'
}

Check 'Unexpected module readiness errors still stop the phase' {
    Reset-TestState Module
    $Script:Results.Enqueue([InvalidOperationException]::new('Unexpected module error'))
    $failure = Expect-Failure { Invoke-PackagesPhase -Packages @('Tool1') }
    Assert ($failure.Exception.Message -eq 'Unexpected module error') 'Unrelated readiness errors must not be swallowed.'
    Assert (-not $Script:LocalApplied -and -not $Script:DevConfigWingetSourceFailure) 'Unknown errors must not be classified as a source outage.'
}

Check 'Module RPC repair and CLI fallback remain available' {
    foreach ($fallback in @($false, $true)) {
        Reset-TestState Module
        $Script:Results.Enqueue([Runtime.InteropServices.COMException]::new('RPC unavailable', -2147023174))
        if ($fallback) {
            $Script:Results.Enqueue([Runtime.InteropServices.COMException]::new('RPC unavailable', -2147023174))
            $Script:Results.Enqueue((New-CliResult))
        } else {
            $Script:Results.Enqueue($null)
        }
        Confirm-DevConfigWinGetReady
        Assert ($Script:Repairs -eq 1 -and $Script:Delays.Count -eq 0) 'RPC failure must use its existing repair, not source retries.'
        Assert (-not $Script:DevConfigWingetSourceFailure) 'RPC repair must not disable source operations.'
        Assert (($Script:DevConfigWinGetMode -eq 'Cli') -eq $fallback) 'CLI fallback must still work.'
    }
}

Check 'Catalog-wrapped RPC failures are not classified as source outages' {
    Assert (-not (Test-DevConfigWingetSourceFailure -Exception (New-CatalogFailure -2147023174))) 'RPC must not exhaust source recovery.'
}

Check 'Source failure in the RPC fallback still permits independent settings' {
    Reset-TestState Module
    foreach ($attempt in 1..2) {
        $Script:Results.Enqueue([Runtime.InteropServices.COMException]::new('RPC unavailable', -2147023174))
    }
    foreach ($attempt in 1..3) { $Script:Results.Enqueue((New-CliResult -1978335157)) }
    Invoke-PackagesPhase -Packages @('Tool1')
    Assert ($Script:Calls.Count -eq 5 -and $Script:Repairs -eq 1) 'RPC repair and source retries must each keep their own allowance.'
    Assert ($Script:DevConfigTally.Warned -eq 1 -and $Script:LocalApplied) 'Fallback source failure must flag the package and allow local settings.'
}

Check 'Cleanup bypasses exhausted setup source state' {
    Reset-TestState
    $Script:DevConfigWingetSourceFailure = 'Setup source retries exhausted'
    $Script:Results.Enqueue((New-CliResult))
    $result = Invoke-DevConfigWingetCli -Arguments @('uninstall', '--id', 'Example.Tool', '--exact')
    Assert ($result.ExitCode -eq 0 -and $Script:Calls.Count -eq 1) 'Raw CLI cleanup calls must remain available.'
}

Check 'Generic retries retain their default behavior and timeout handling' {
    Reset-TestState
    $Script:Attempts = 0
    $null = Expect-Failure {
        Invoke-DevConfigRetry -ScriptBlock { $Script:Attempts++; throw 'Failure' }
    }
    Assert ($Script:Attempts -eq 3 -and ($Script:Delays -join ',') -eq '5,10') 'Default retry behavior must remain unchanged.'
    $Script:Attempts = 0
    $Script:Delays = @()
    $null = Expect-Failure {
        Invoke-DevConfigRetry -ShouldRetry { $true } -ScriptBlock { $Script:Attempts++; throw [TimeoutException]::new('Timed out') }
    }
    Assert ($Script:Attempts -eq 1 -and $Script:Delays.Count -eq 0) 'Timeouts must never be retried.'
}

Write-Host "Results: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
