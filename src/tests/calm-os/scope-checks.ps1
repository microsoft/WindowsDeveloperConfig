<#
.SYNOPSIS
    Mock-only checks for the Dev Config -Scope split (All | Machine | User).

.DESCRIPTION
    Proves that every step is tagged with a scope, that Machine and User select exactly
    their own steps, that All keeps today's behavior, and that the scoped parts never
    elevate, restart, prompt, or wait for a key press. Nothing here changes this PC:
    every command that could install, write, download, or restart is replaced with a
    mock that records the call and throws.

    Run it in both Windows PowerShell 5.1 and PowerShell 7:
        powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\calm-os\scope-checks.ps1
        pwsh -NoProfile -ExecutionPolicy Bypass -File src\tests\calm-os\scope-checks.ps1
#>
param(
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\..\windows-dev-config')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath
$StepsDirectory = Join-Path $SourceDirectory 'steps'
$WorkloadsDirectory = Join-Path $SourceDirectory 'workloads'
$OrchestratorPath = Join-Path $SourceDirectory 'dev-config.ps1'
$BootstrapPath = Join-Path $SourceDirectory 'bootstrap.ps1'

$script:passed = 0
$script:failed = 0
$script:Blocked = @()
$script:HostLines = @()

foreach ($helperName in @(
        '_console', '_step-runner', '_elevation', '_reboot-resume', '_registry', '_environment',
        '_retry', '_terminal', '_winget', '_pwsh-bootstrap', '_workload', '_security', '_scope')) {
    . (Join-Path $StepsDirectory "$helperName.ps1")
}

$phaseFiles = @()
foreach ($workloadAction in @('Full', 'Uninstall')) {
    $workloadDefinition = Get-DevConfigWorkload -Directory $WorkloadsDirectory -Workload 'devconfig' -Action $workloadAction
    foreach ($workloadPhase in @($workloadDefinition.Phases)) {
        if ($phaseFiles -notcontains $workloadPhase.File) { $phaseFiles += $workloadPhase.File }
    }
}
foreach ($phaseFile in $phaseFiles) {
    . (Join-Path $StepsDirectory $phaseFile)
}

$SourceScripts = @(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.ps1' -Recurse -File)

function Write-CheckLine([string]$Text, [string]$Color = '') {
    # Module-qualified so the Write-Host mocks inside checks never swallow results.
    if ($Color) {
        Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Color
    } else {
        Microsoft.PowerShell.Utility\Write-Host $Text
    }
}

function Assert([bool]$Condition, [string]$Message) {
    if ($Condition) {
        $script:passed++
        Write-CheckLine "  PASS  $Message"
    } else {
        $script:failed++
        Write-CheckLine "  FAIL  $Message" 'Red'
    }
}

function Get-FailureMessage([scriptblock]$Body) {
    try {
        $null = & $Body
    } catch {
        return [string]$_.Exception.Message
    }
    return $null
}

function Expect-Failure([scriptblock]$Body, [string]$Message) {
    $failure = Get-FailureMessage $Body
    Assert ($null -ne $failure) "$Message (error: $failure)"
    return $failure
}

function Check([string]$Name, [scriptblock]$Body) {
    Write-CheckLine $Name 'Cyan'
    try {
        $null = & $Body
    } catch {
        $script:failed++
        Write-CheckLine ('  FAIL  {0}: {1}' -f $Name, $_.Exception.Message) 'Red'
    }
}

function Get-ScriptAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        throw ('Parse error in {0}: {1}' -f $Path, @($errors)[0].Message)
    }
    return $ast
}

function Find-Commands($Ast, [string]$Name) {
    return @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $Name
            }, $true))
}

function Get-CommandParameterAst($Command, [string]$Name) {
    $elements = @($Command.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq $Name) {
            if ($null -ne $element.Argument) { return $element.Argument }
            if ($index + 1 -lt $elements.Count) { return $elements[$index + 1] }
            return $null
        }
    }
    return $null
}

function Test-CommandHasParameter($Command, [string]$Name) {
    foreach ($element in @($Command.CommandElements)) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq $Name) {
            return $true
        }
    }
    return $false
}

function Get-ConstantStatementValue($Statement) {
    if ($Statement -is [System.Management.Automation.Language.PipelineAst] -and
        $Statement.PipelineElements.Count -eq 1 -and
        $Statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $Statement.PipelineElements[0].Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Statement.PipelineElements[0].Expression.Value
    }
    return $null
}

function Test-AdjacentArguments([object[]]$Arguments, [string]$Name, [string]$Value) {
    $list = @($Arguments | ForEach-Object { [string]$_ })
    for ($index = 0; $index -lt ($list.Count - 1); $index++) {
        if ($list[$index] -eq $Name -and $list[$index + 1] -eq $Value) { return $true }
    }
    return $false
}

function Format-Locations([object[]]$Items) {
    if ($null -eq $Items -or $Items.Count -eq 0) { return '' }
    return ' -> ' + ((@($Items | ForEach-Object { '{0}:{1}' -f (Split-Path -Leaf $_.File), $_.Line })) -join ', ')
}

function Reset-ScopeState([string]$Scope = 'All', [string]$Action = 'Partial') {
    $script:DevConfigScope = $Scope
    $script:DevConfigAction = $Action
    $script:DevConfigResumed = $false
    $script:DevConfigWorkload = 'devconfig'
    $script:DevConfigPhaseTitle = ''
    $script:DevConfigPhaseHeaderShown = $false
    $script:DevConfigPhaseSteps = $null
    $script:DevConfigPhaseIndex = 0
    $script:DevConfigPhaseTotal = 0
    $script:DevConfigWinGetMode = 'Module'
    $script:Blocked = @()
    $script:HostLines = @()
}

# Every command that could change this PC. Checks dot-source these mocks first, then
# override the few commands they need to observe.
$BlockedCommands = @(
    'Add-AppxPackage', 'Add-AppxProvisionedPackage', 'Remove-AppxPackage',
    'Install-Module', 'Install-PSResource', 'Install-Script', 'Install-PackageProvider', 'Save-Module',
    'Start-Process', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Restart-Computer', 'Stop-Computer',
    'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer',
    'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Item', 'New-Item', 'Remove-Item',
    'Copy-Item', 'Move-Item', 'Rename-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Set-Acl', 'Expand-Archive',
    'Enable-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature', 'Set-ExecutionPolicy',
    'Start-Service', 'Stop-Service', 'Set-Service', 'Start-Transcript',
    'Invoke-DevConfigNativeCommand', 'Install-DevConfigWingetPackage', 'Install-WinGetPackage',
    'Uninstall-WinGetPackage', 'Repair-WinGetPackageManager',
    'Install-DevConfigSignedInstaller', 'Install-DevConfigPwshMsi', 'Install-DevConfigWslMsi'
)

function New-GuardMocks([string[]]$Except = @()) {
    $definitions = foreach ($commandName in $BlockedCommands) {
        if ($Except -contains $commandName) { continue }
        'function {0} {{ $script:Blocked += @(''{0}''); throw ''BLOCKED {0}'' }}' -f $commandName
    }
    return [scriptblock]::Create((@($definitions) -join [Environment]::NewLine))
}

$GuardMocks = New-GuardMocks

# Literal step names (New-DevConfigStep -Name '<literal>') and the scope each must carry.
$ExpectedLiteralScopes = @{
    PowerShell7 = 'Machine'; WinGet = 'All'; CascadiaFonts = 'Machine'; VisualStudioWorkloads = 'Machine'
    WslCleanup = 'Machine'; WslComponents = 'Machine'
    CascadiaDefaultFont = 'User'; TerminalReset = 'User'; DarkTheme = 'User'; Ps7DefaultProfile = 'User'
    OhMyPoshProfileCleanup = 'User'; OhMyPoshProfile = 'User'; CopilotFragmentCleanup = 'User'
    WinUIPluginCleanup = 'User'; WinSkillsMarketplaceCleanup = 'User'; WinUITemplatesCleanup = 'User'
    GitHubCopilotProfile = 'User'; WinUITemplates = 'User'; WinSkillsMarketplace = 'User'; WinUIPlugin = 'User'
    ExplorerDisplayReset = 'User'; RustStableToolchain = 'User'; WslUbuntu = 'User'
    # Uninstall cleanups take their package's catalog scope; the Uninstall build check validates them.
    NvmCleanup = '<dynamic>'; UvCleanup = '<dynamic>'
}

# Packages in the standard set and where each installs. Other catalog entries only need a valid scope.
$ExpectedPackageScopes = @{
    PowerShell = 'Machine'; Git = 'Machine'; GitHubCLI = 'Machine'; AzureCLI = 'Machine'; DotnetSdk = 'Machine'
    Python = 'Machine'; VCRedist = 'Machine'; NodeJS = 'Machine'; nvmForNode = 'All'; Coreutils = 'Machine'
    Terminal = 'User'; IntelligentTerminal = 'User'; GitHubCopilot = 'User'; VSCode = 'User'; UV = 'User'
    OhMyPosh = 'User'; winappCli = 'User'; PowerToys = 'User'
}

# Standard (-Action Partial) steps each scope selects, in run order.
$ExpectedPartialSteps = @{
    Machine = @(
        'PowerShell7', 'PowerShell', 'Git', 'GitHubCLI', 'AzureCLI', 'DotnetSdk', 'Python', 'VCRedist',
        'NodeJS', 'Coreutils', 'LongPaths', 'CascadiaFonts', 'WslComponents')
    User    = @(
        'Terminal', 'IntelligentTerminal', 'GitHubCopilot', 'VSCode', 'UV', 'OhMyPosh', 'winappCli',
        'PowerToys', 'PowerToysAOT', 'ShowFileExtensions', 'ShowHiddenFiles', 'FullPathTitlebar', 'OpenThisPC',
        'FrequentFolders', 'FrequentFiles', 'TipsOff', 'DetailsContainer', 'EndTask', 'StartRecommendations',
        'StartAccountNotifications', 'CascadiaDefaultFont', 'DarkTheme', 'Ps7DefaultProfile', 'OhMyPoshProfile',
        'GitHubCopilotProfile', 'WinSkillsMarketplace', 'WinUIPlugin', 'WslUbuntu')
    All     = @(
        'PowerShell7', 'WinGet', 'Terminal', 'IntelligentTerminal', 'PowerShell', 'Git', 'GitHubCLI',
        'AzureCLI', 'GitHubCopilot', 'VSCode', 'DotnetSdk', 'Python', 'VCRedist', 'UV', 'NodeJS', 'nvmForNode',
        'Coreutils', 'OhMyPosh', 'winappCli', 'PowerToys', 'PowerToysAOT', 'LongPaths', 'ShowFileExtensions',
        'ShowHiddenFiles', 'FullPathTitlebar', 'OpenThisPC', 'FrequentFolders', 'FrequentFiles', 'TipsOff',
        'DetailsContainer', 'EndTask', 'StartRecommendations', 'StartAccountNotifications', 'CascadiaFonts',
        'CascadiaDefaultFont', 'DarkTheme', 'Ps7DefaultProfile', 'OhMyPoshProfile', 'GitHubCopilotProfile',
        'WinSkillsMarketplace', 'WinUIPlugin', 'WslComponents', 'WslUbuntu')
}

Check 'Every New-DevConfigStep call names a scope' {
    $calls = @()
    foreach ($file in $SourceScripts) {
        $ast = Get-ScriptAst $file.FullName
        foreach ($call in (Find-Commands $ast 'New-DevConfigStep')) {
            $calls += [pscustomobject]@{ File = $file.FullName; Line = $call.Extent.StartLineNumber; Ast = $call }
        }
    }
    Assert ($calls.Count -gt 10) "found $($calls.Count) New-DevConfigStep calls"
    $unscoped = @($calls | Where-Object { -not (Test-CommandHasParameter $_.Ast 'Scope') })
    Assert ($unscoped.Count -eq 0) ('every call passes -Scope' + (Format-Locations $unscoped))
    $splatted = @($calls | Where-Object {
            @($_.Ast.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
                }).Count -gt 0
        })
    Assert ($splatted.Count -eq 0) ('no call hides its scope in a splat' + (Format-Locations $splatted))
}

Check 'Literal step names carry the expected scope' {
    $actual = @()
    foreach ($file in $SourceScripts) {
        $ast = Get-ScriptAst $file.FullName
        foreach ($call in (Find-Commands $ast 'New-DevConfigStep')) {
            $nameAst = Get-CommandParameterAst $call 'Name'
            if ($nameAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            $scopeAst = Get-CommandParameterAst $call 'Scope'
            $stepScope = '<dynamic>'
            if ($scopeAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $stepScope = $scopeAst.Value }
            $actual += ('{0}={1}' -f $nameAst.Value, $stepScope)
        }
    }
    $actual = @($actual | Sort-Object -Unique)
    $expected = @($ExpectedLiteralScopes.Keys | ForEach-Object { '{0}={1}' -f $_, $ExpectedLiteralScopes[$_] } | Sort-Object -Unique)
    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    $unexpected = @($actual | Where-Object { $expected -notcontains $_ })
    Assert ($missing.Count -eq 0) ('no expected literal step is missing' + $(if ($missing.Count) { ' -> ' + ($missing -join ', ') } else { '' }))
    Assert ($unexpected.Count -eq 0) ('no literal step has an unexpected scope' + $(if ($unexpected.Count) { ' -> ' + ($unexpected -join ', ') } else { '' }))
}

Check 'Package catalog scopes' {
    $catalog = @(Get-DevConfigPackageCatalog)
    Assert ($catalog.Count -ge 18) "catalog has $($catalog.Count) packages"
    $names = @()
    foreach ($package in $catalog) {
        $names += [string]$package.Name
        $stepScope = [string]$package.Scope
        Assert (@('Machine', 'User', 'All') -contains $stepScope) "$($package.Name) has a valid scope ('$stepScope')"
        if ($ExpectedPackageScopes.ContainsKey([string]$package.Name)) {
            $want = $ExpectedPackageScopes[[string]$package.Name]
            Assert ($stepScope -eq $want) "$($package.Name) installs in $want scope"
        }
        $settings = @()
        if ($package.ContainsKey('Settings') -and $package.Settings) { $settings = @($package.Settings) }
        foreach ($setting in $settings) {
            $step = New-DevConfigRegistryStep -Setting $setting
            Assert ($step.Scope -eq $stepScope) "$($package.Name) setting $($setting.Name) runs in the package's scope ($stepScope)"
        }
    }
    foreach ($name in $ExpectedPackageScopes.Keys) {
        Assert ($names -contains $name) "catalog contains $name"
    }
}

Check 'New-DevConfigStep demands a valid scope without prompting' {
    $command = Get-Command New-DevConfigStep
    Assert ($command.Parameters.ContainsKey('Scope')) 'New-DevConfigStep has a Scope parameter'
    if ($command.Parameters.ContainsKey('Scope')) {
        $mandatory = @($command.Parameters['Scope'].Attributes | Where-Object {
                $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
            }).Count -gt 0
        Assert (-not $mandatory) 'Scope is not Mandatory, so a missing scope throws instead of prompting'
    }
    $noScope = Get-FailureMessage { New-DevConfigStep -Name 'NoScope' -Check { $true } -Apply { } }
    Assert ($null -ne $noScope -and $noScope -match 'Scope') "a step without a scope throws (error: $noScope)"
    $badScope = Get-FailureMessage { New-DevConfigStep -Name 'BadScope' -Scope 'Everyone' -Check { $true } -Apply { } }
    Assert ($null -ne $badScope) 'an unknown scope throws'
    foreach ($stepScope in @('Machine', 'User', 'All')) {
        $step = New-DevConfigStep -Name "Scoped$stepScope" -Scope $stepScope -Check { $true } -Apply { }
        Assert ($step.Scope -eq $stepScope) "a $stepScope step keeps its scope"
    }
}

Check 'Registry steps take their scope from the hive' {
    foreach ($case in @(
            @{ KeyPath = 'HKLM\SOFTWARE\Contoso\DevConfigScopeTest'; Expected = 'Machine' },
            @{ KeyPath = 'HKCU\Software\Contoso\DevConfigScopeTest'; Expected = 'User' })) {
        $setting = @{ Name = 'ScopeProbe'; KeyPath = $case.KeyPath; ValueName = 'Probe'; Value = 1; Description = 'probe' }
        Assert ((New-DevConfigRegistryStep -Setting $setting).Scope -eq $case.Expected) "$($case.KeyPath) is $($case.Expected)"
        $typed = @{ Name = 'ScopeProbe'; KeyPath = $case.KeyPath; ValueName = 'Probe'; Value = 'x'; Type = 'String'; Description = 'probe'; ResetValue = 'y' }
        Assert ((New-DevConfigRegistryStep -Setting $typed).Scope -eq $case.Expected) "$($case.KeyPath) with ResetValue is $($case.Expected)"
        Assert ((New-DevConfigRegistryStep -Setting $typed -Reset).Scope -eq $case.Expected) "$($case.KeyPath) reset is $($case.Expected)"
    }
    $noHive = Get-FailureMessage {
        New-DevConfigRegistryStep -Setting @{ Name = 'NoHive'; KeyPath = 'SOFTWARE\Contoso'; ValueName = 'Probe'; Value = 1; Description = 'probe' }
    }
    Assert ($null -ne $noHive) "a key path without HKLM or HKCU throws (error: $noHive)"
}

Check 'Every literal registry KeyPath names HKLM or HKCU' {
    $keyPaths = @()
    foreach ($file in $SourceScripts) {
        $ast = Get-ScriptAst $file.FullName
        $tables = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true))
        foreach ($table in $tables) {
            foreach ($pair in $table.KeyValuePairs) {
                if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if ($pair.Item1.Value -ne 'KeyPath') { continue }
                $value = Get-ConstantStatementValue $pair.Item2
                if ($null -eq $value) { continue }
                $keyPaths += [pscustomobject]@{ File = $file.FullName; Line = $pair.Item1.Extent.StartLineNumber; Value = $value }
            }
        }
    }
    Assert ($keyPaths.Count -gt 0) "found $($keyPaths.Count) literal KeyPath values"
    $bad = @($keyPaths | Where-Object { $_.Value -notmatch '^(HKLM|HKCU)\\' })
    Assert ($bad.Count -eq 0) ('every literal KeyPath starts with HKLM\ or HKCU\' + (Format-Locations $bad))
}

Check 'Invoke-DevConfigSteps runs only the steps of the requested scope' {
    . $GuardMocks
    function Write-Host { $script:HostLines += @("$args") }
    $case = 0
    foreach ($runScope in @('Machine', 'User', 'All')) {
        $case++
        Reset-ScopeState -Scope $runScope
        $script:DevConfigPhaseTitle = 'Scope test'
        $script:DevConfigPhaseIndex = 1
        $script:DevConfigPhaseTotal = 1
        $script:Applied = @()
        $steps = @(
            New-DevConfigStep -Name "ScopeMachine$case" -Scope Machine -Check { @($script:Applied) -contains 'Machine' } -Apply { $script:Applied += @('Machine') }
            New-DevConfigStep -Name "ScopeUser$case" -Scope User -Check { @($script:Applied) -contains 'User' } -Apply { $script:Applied += @('User') }
            New-DevConfigStep -Name "ScopeAll$case" -Scope All -Check { @($script:Applied) -contains 'All' } -Apply { $script:Applied += @('All') }
        )
        $failure = Get-FailureMessage { Invoke-DevConfigSteps -Steps $steps }
        $want = @{ Machine = 'Machine'; User = 'User'; All = 'Machine,User,All' }[$runScope]
        Assert ($null -eq $failure) "$runScope run completes (error: $failure)"
        Assert ((@($script:Applied) -join ',') -eq $want) "$runScope applies $want (applied: $(@($script:Applied) -join ','))"
        Assert (@($script:Blocked).Count -eq 0) "$runScope touched nothing real (blocked: $(@($script:Blocked) -join ', '))"
    }

    Reset-ScopeState -Scope 'User'
    $script:DevConfigPhaseTitle = 'Machine-only test'
    $script:DevConfigPhaseIndex = 1
    $script:DevConfigPhaseTotal = 1
    $script:Applied = @()
    $machineOnly = @(New-DevConfigStep -Name 'ScopeMachineOnly' -Scope Machine -Check { $false } -Apply { $script:Applied += @('Machine') })
    $failure = Get-FailureMessage { Invoke-DevConfigSteps -Steps $machineOnly }
    Assert ($null -eq $failure) "a User run passes over a Machine-only phase (error: $failure)"
    Assert (@($script:Applied).Count -eq 0) 'the Machine-only step did not run'
    Assert (@($script:HostLines).Count -eq 0) "a phase with nothing left prints nothing (printed: $(@($script:HostLines) -join ' | '))"
    Assert (-not $script:DevConfigPhaseHeaderShown) 'the phase header stays hidden'
}

Check 'Scoped runs never wait for a key press' {
    function Write-Host { $script:HostLines += @("$args") }
    function Start-Sleep { $script:Sleeps++; throw 'SENTINEL Start-Sleep' }
    foreach ($runScope in @('Machine', 'User')) {
        Reset-ScopeState -Scope $runScope
        $script:Sleeps = 0
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $failure = Get-FailureMessage { Wait-DevConfigKeyPress -TimeoutSeconds 900 }
        $watch.Stop()
        Assert ($null -eq $failure) "$runScope wait returns without error (error: $failure)"
        Assert ($script:Sleeps -eq 0 -and $watch.Elapsed.TotalSeconds -lt 2) "$runScope wait returns at once"
        Assert (@($script:HostLines).Count -eq 0) "$runScope wait prints no 'press any key' line"
    }

    # Production gives both spots a real console stdin, where KeyAvailable stays false and the
    # wait would run its full 15 minutes. dev-config.ps1 must record the scope before any wait.
    $ast = Get-ScriptAst $OrchestratorPath
    $waits = @(Find-Commands $ast 'Wait-DevConfigKeyPress')
    $assignments = @($ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
                $left = $node.Left
                if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
                $left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $left.VariablePath.UserPath -match '^(script:)?DevConfigScope$'
            }, $true))
    Assert ($waits.Count -gt 0) "dev-config.ps1 has $($waits.Count) key waits to guard"
    Assert ($assignments.Count -gt 0) 'dev-config.ps1 records the scope in $Script:DevConfigScope'
    if ($assignments.Count -gt 0) {
        $firstAssignment = @($assignments | Sort-Object { $_.Extent.StartOffset })[0].Extent.StartOffset
        $early = @($waits | Where-Object { $_.Extent.StartOffset -lt $firstAssignment } | ForEach-Object {
                [pscustomobject]@{ File = $OrchestratorPath; Line = $_.Extent.StartLineNumber }
            })
        Assert ($early.Count -eq 0) ('the scope is recorded before the first key wait' + (Format-Locations $early))
    }
}

Check 'Scoped runs never ask for elevation' {
    function Write-Host { $script:HostLines += @("$args") }
    function Start-Process { $script:Started++; throw 'SENTINEL Start-Process' }
    function Wait-DevConfigKeyPress { throw 'SENTINEL Wait-DevConfigKeyPress' }
    function Test-DevConfigIsAdmin { $script:IsAdmin }

    Reset-ScopeState -Scope 'User'
    $script:Started = 0
    $script:IsAdmin = $false
    $failure = Get-FailureMessage { Invoke-DevConfigElevate -ScriptPath $OrchestratorPath -Action 'Partial' -Scope 'User' }
    Assert ($null -eq $failure) "User carries on without elevating (error: $failure)"
    Assert ($script:Started -eq 0) 'User starts no elevated process'

    Reset-ScopeState -Scope 'Machine'
    $script:Started = 0
    $script:IsAdmin = $true
    $failure = Get-FailureMessage { Invoke-DevConfigElevate -ScriptPath $OrchestratorPath -Action 'Partial' -Scope 'Machine' }
    Assert ($null -eq $failure -and $script:Started -eq 0) "Machine with admin rights (SYSTEM) carries on in place (error: $failure)"

    Reset-ScopeState -Scope 'Machine'
    $script:Started = 0
    $script:IsAdmin = $false
    $failure = Expect-Failure { Invoke-DevConfigElevate -ScriptPath $OrchestratorPath -Action 'Partial' -Scope 'Machine' } 'Machine without admin rights fails'
    Assert ($null -ne $failure -and $failure -notmatch 'SENTINEL') "Machine fails with its own message before any prompt or key wait (error: $failure)"
    Assert ($script:Started -eq 0) 'Machine starts no elevated process'
}

Check 'Scoped runs refuse to schedule a restart' {
    . $GuardMocks
    function Write-Host { $script:HostLines += @("$args") }
    function Get-DevConfigTaskShellExe { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    function New-ScheduledTaskAction { [pscustomobject]@{ Kind = 'Action' } }
    function New-ScheduledTaskTrigger { [pscustomobject]@{ Kind = 'Trigger' } }
    function New-ScheduledTaskPrincipal { [pscustomobject]@{ Kind = 'Principal' } }
    function New-ScheduledTaskSettingsSet { [pscustomobject]@{ Kind = 'Settings' } }
    function Clear-DevConfigResume { }
    function Save-DevConfigTally { }
    function Get-DevConfigTallyPath { Join-Path $env:TEMP 'devconfig-scope-checks-tally.json' }
    function Register-ScheduledTask { $script:RestartCalls++; throw 'SENTINEL Register-ScheduledTask' }
    function Invoke-DevConfigNativeCommand { $script:RestartCalls++; throw 'SENTINEL Invoke-DevConfigNativeCommand' }
    function Start-Sleep { $script:RestartCalls++; throw 'SENTINEL Start-Sleep' }
    function Restart-Computer { $script:RestartCalls++; throw 'SENTINEL Restart-Computer' }
    function Wait-DevConfigKeyPress { throw 'SENTINEL Wait-DevConfigKeyPress' }
    foreach ($runScope in @('Machine', 'User')) {
        Reset-ScopeState -Scope $runScope
        $script:DevConfigAllowUnsigned = $false
        $script:RestartCalls = 0
        $failure = Get-FailureMessage { Suspend-DevConfigForReboot -ScriptPath $OrchestratorPath }
        Assert ($null -ne $failure -and $failure -notmatch 'SENTINEL') "$runScope refuses to suspend for a restart (error: $failure)"
        Assert ($script:RestartCalls -eq 0) "$runScope registered no resume task and ran no shutdown"
    }
}

Check 'Machine WSL setup reports a pending restart instead of restarting' {
    . $GuardMocks
    function Write-Host { $script:HostLines += @("$args") }
    function Enable-DevConfigWslFeatures { if ($script:FeaturesChange) { $script:DevConfigWslRestartSignalled = $true } }
    function Test-Path { param([string]$LiteralPath, [string]$Path, $PathType) $script:WslExeExists }
    function Install-DevConfigWslMsi { $script:MsiCalls++ }
    function Test-DevConfigServicingRebootPending { $script:ServicingPending }
    function Add-DevConfigNote { param([string]$Message) $script:Notes += @($Message) }
    function Suspend-DevConfigForReboot { $script:SuspendCalls++; throw 'SENTINEL Suspend-DevConfigForReboot' }

    foreach ($case in @(
            @{ Label = 'a fresh PC'; FeaturesChange = $true; WslExeExists = $false; ServicingPending = $true; Msi = 1; Noted = $true },
            @{ Label = 'a repeat run'; FeaturesChange = $false; WslExeExists = $true; ServicingPending = $false; Msi = 0; Noted = $false })) {
        Reset-ScopeState -Scope 'Machine'
        $script:FeaturesChange = $case.FeaturesChange
        $script:WslExeExists = $case.WslExeExists
        $script:ServicingPending = $case.ServicingPending
        $script:SuspendCalls = 0
        $script:MsiCalls = 0
        $script:Notes = @()
        $failure = Get-FailureMessage { Install-DevConfigWslMachineComponents }
        Assert ($null -eq $failure) "Machine WSL setup on $($case.Label) finishes (error: $failure)"
        Assert ($script:SuspendCalls -eq 0) "Machine WSL setup on $($case.Label) never suspends for a restart"
        Assert ($script:MsiCalls -eq $case.Msi) "Machine WSL setup on $($case.Label) installs the WSL MSI $($case.Msi) time(s) (actual $($script:MsiCalls))"
        Assert ((@($script:Notes).Count -gt 0) -eq $case.Noted) "Machine WSL setup on $($case.Label) notes a pending restart: $($case.Noted) (notes: $(@($script:Notes) -join ' | '))"
        Assert (@($script:Blocked).Count -eq 0) "Machine WSL setup on $($case.Label) touched nothing real (blocked: $(@($script:Blocked) -join ', '))"
    }

    function Install-DevConfigWslComponents { $script:DevConfigWslRestartSignalled = $true }
    function Test-DevConfigWslComponentsReady { $false }
    Reset-ScopeState -Scope 'All'
    $script:ServicingPending = $true
    $script:SuspendCalls = 0
    $script:MsiCalls = 0
    $script:Notes = @()
    $failure = Get-FailureMessage { Install-DevConfigWslPlatform -OrchestratorPath $OrchestratorPath }
    Assert ($script:SuspendCalls -eq 1 -and $failure -match 'SENTINEL Suspend') "All still suspends for the restart as before (error: $failure)"
    Assert (@($script:Blocked).Count -eq 0) "All WSL setup touched nothing real (blocked: $(@($script:Blocked) -join ', '))"
}

Check 'The WSL phase takes the machine install path only in Machine runs' {
    . $GuardMocks
    function Write-Host { $script:HostLines += @("$args") }
    function Invoke-DevConfigSteps {
        param([object[]]$Steps)
        $script:Captured += @($Steps | Where-Object { $null -ne $_ })
    }
    foreach ($case in @(
            @{ RunScope = 'Machine'; Want = 'Install-DevConfigWslMachineComponents'; Avoid = 'Install-DevConfigWslPlatform' },
            @{ RunScope = 'All'; Want = 'Install-DevConfigWslPlatform'; Avoid = 'Install-DevConfigWslMachineComponents' })) {
        Reset-ScopeState -Scope $case.RunScope
        $script:Captured = @()
        $failure = Get-FailureMessage { Invoke-WslPhase -OrchestratorPath $OrchestratorPath }
        Assert ($null -eq $failure) "$($case.RunScope) builds the WSL phase (error: $failure)"
        $components = @($script:Captured | Where-Object { $_.Name -eq 'WslComponents' })
        Assert ($components.Count -eq 1) "$($case.RunScope) builds one WslComponents step"
        if ($components.Count -eq 1) {
            $applyText = $components[0].Apply.ToString()
            Assert ($applyText -match [regex]::Escape($case.Want) -and $applyText -notmatch [regex]::Escape($case.Avoid)) "$($case.RunScope) WslComponents runs $($case.Want)"
            Assert ($components[0].Scope -eq 'Machine') "$($case.RunScope) WslComponents is a Machine step"
        }
        Assert (@($script:Blocked).Count -eq 0) "$($case.RunScope) WSL phase build touched nothing real (blocked: $(@($script:Blocked) -join ', '))"
    }
}

Check 'Only the resume helper can restart the PC' {
    $hits = @()
    foreach ($file in $SourceScripts) {
        $ast = Get-ScriptAst $file.FullName
        foreach ($call in (Find-Commands $ast 'Restart-Computer')) {
            $hits += [pscustomobject]@{ File = $file.FullName; Line = $call.Extent.StartLineNumber }
        }
        if ($file.Name -eq '_reboot-resume.ps1') { continue }
        $shutdowns = @($ast.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                    $node.Value -match '(^|\\)shutdown(\.exe)?$'
                }, $true))
        foreach ($node in $shutdowns) {
            $hits += [pscustomobject]@{ File = $file.FullName; Line = $node.Extent.StartLineNumber }
        }
    }
    Assert ($hits.Count -eq 0) ('no script outside _reboot-resume.ps1 runs shutdown or Restart-Computer' + (Format-Locations $hits))
}

Check 'Relaunch arguments carry the scope' {
    $path = 'C:\Dev Config\dev-config.ps1'
    $today = @(Get-DevConfigRelaunchArguments -ScriptPath $path -Action 'Partial')
    $expectedToday = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f $path), '-Action', 'Partial', '-NoElevate')
    Assert (($today -join '|') -eq ($expectedToday -join '|')) "All keeps today's arguments ($($today -join ' '))"
    $explicitAll = @(Get-DevConfigRelaunchArguments -ScriptPath $path -Action 'Partial' -Scope 'All')
    Assert (($explicitAll -join '|') -eq ($today -join '|')) '-Scope All adds nothing'
    Assert ($today -notcontains '-NonInteractive') 'All relaunches stay interactive'
    foreach ($runScope in @('Machine', 'User')) {
        foreach ($font in @($false, $true)) {
            $arguments = @(Get-DevConfigRelaunchArguments -ScriptPath $path -Action 'Partial' -Scope $runScope -ApplyTerminalFont:$font)
            $index = [array]::IndexOf([object[]]$arguments, '-Scope')
            $ok = $index -ge 0 -and ($index + 1) -lt $arguments.Count -and $arguments[$index + 1] -eq $runScope
            Assert $ok "$runScope relaunch (ApplyTerminalFont: $font) passes -Scope $runScope ($($arguments -join ' '))"
            Assert ($arguments -contains '-NonInteractive') "$runScope relaunch (ApplyTerminalFont: $font) runs -NonInteractive"
        }
    }
}

Check 'WinGet installs follow the scope of the run' {
    . (New-GuardMocks -Except 'Install-DevConfigWingetPackage')
    function Write-Host { $script:HostLines += @("$args") }
    function Start-Sleep { }
    function Get-WinGetPackage { }
    function Find-WinGetPackage { }
    function Invoke-DevConfigWingetCli {
        param([string[]]$Arguments, [int]$TimeoutSeconds)
        $script:CliCalls += , @($Arguments)
        [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
    function Install-WinGetPackage {
        [CmdletBinding()]
        param(
            [string]$Id, [string]$Source, [string]$Mode, [string]$MatchOption, [string]$Scope, [string]$Version,
            [switch]$Force, [string]$Override, [string]$Custom, [string]$Log, [string]$Architecture,
            [string]$InstallerType, [string]$Location
        )
        $script:ModuleCalls += @([pscustomobject]@{ Id = $Id; Scope = $Scope })
        $result = [pscustomobject]@{
            Status = 'Ok'; RebootRequired = $false; InstallerErrorCode = 0; ExtendedErrorCode = $null
            Id = $Id; Name = $Id; Source = 'winget'; CorrelationData = ''
        }
        $result | Add-Member -MemberType ScriptMethod -Name Succeeded -Value { $true }
        $result
    }

    foreach ($case in @(
            @{ Scope = 'User'; Mode = 'Cli' },
            @{ Scope = 'All'; Mode = 'Cli' },
            @{ Scope = 'All'; Mode = 'Module' },
            @{ Scope = 'Machine'; Mode = 'Module' })) {
        Reset-ScopeState -Scope $case.Scope
        $script:DevConfigWinGetMode = $case.Mode
        $script:CliCalls = @()
        $script:ModuleCalls = @()
        $label = '{0}/{1}' -f $case.Scope, $case.Mode
        $failure = Get-FailureMessage { Install-DevConfigWingetPackage -Id 'Contoso.ScopeProbe' }
        Assert ($null -eq $failure) "$label install succeeds (error: $failure)"
        $install = $null
        foreach ($call in $script:CliCalls) {
            if (@($call) -contains 'install') { $install = @($call) }
        }
        $installText = if ($null -ne $install) { $install -join ' ' } else { '<no install call>' }
        switch ($label) {
            'User/Cli' {
                Assert ($null -ne $install -and (Test-AdjacentArguments $install '--scope' 'user')) "User installs with --scope user ($installText)"
                Assert (@($script:ModuleCalls).Count -eq 0) 'User never uses the WinGet module'
            }
            'All/Cli' {
                Assert ($null -ne $install -and @($install) -notcontains '--scope') "All passes no --scope, as before ($installText)"
            }
            'All/Module' {
                $scoped = @($script:ModuleCalls | Where-Object { $_.Scope })
                Assert (@($script:ModuleCalls).Count -gt 0 -and $scoped.Count -eq 0) 'All passes no module -Scope, as before'
            }
            'Machine/Module' {
                $other = @($script:ModuleCalls | Where-Object { $_.Scope -ne 'SystemOrUnknown' })
                Assert (@($script:ModuleCalls).Count -gt 0 -and $other.Count -eq 0) 'Machine installs with -Scope SystemOrUnknown'
                Assert (@($script:CliCalls).Count -eq 0) 'Machine never calls the winget CLI (unsupported as SYSTEM)'
            }
        }
        Assert (@($script:Blocked).Count -eq 0) "$label touched nothing real (blocked: $(@($script:Blocked) -join ', '))"
    }
}

function Invoke-CapturedPhases([string]$Scope, [string]$Action) {
    . $GuardMocks
    function Write-Host { $script:HostLines += @("$args") }
    function Start-Sleep { }
    function Initialize-DevConfigWinGet { }
    function Confirm-DevConfigWinGetReady { }
    function Get-DevConfigTerminalFontRunOnceCommand { $null }
    function Add-DevConfigNote { }
    function Invoke-DevConfigSteps {
        param([object[]]$Steps)
        $built = @($Steps | Where-Object { $null -ne $_ })
        $selected = $built
        if ($script:DevConfigPhaseSteps) {
            # Same rule as the real runner: every selected name must exist in the phase.
            $names = @($built | ForEach-Object { $_.Name })
            $unknown = @($script:DevConfigPhaseSteps | Where-Object { $names -notcontains $_ })
            if ($unknown.Count -gt 0) {
                throw "The '$($script:DevConfigPhaseTitle)' phase has no step named $($unknown -join ', ')."
            }
            $selected = @($built | Where-Object { @($script:DevConfigPhaseSteps) -contains $_.Name })
        }
        foreach ($step in $selected) {
            $script:Captured += @([pscustomobject]@{ Name = [string]$step.Name; Scope = [string]$step.Scope })
        }
    }

    Reset-ScopeState -Scope $Scope -Action $Action
    $script:Captured = @()
    $workload = Get-DevConfigWorkload -Directory $WorkloadsDirectory -Workload 'devconfig' -Action $Action
    foreach ($phase in @($workload.Phases)) {
        Invoke-DevConfigWorkloadPhase -Phase $phase -OrchestratorPath $OrchestratorPath | Out-Null
    }
    if (@($script:Blocked).Count -gt 0) {
        throw "building the $Action phases touched real commands: $(@($script:Blocked) -join ', ')"
    }
    $script:Captured
}

Check 'Standard (Partial) steps split cleanly into Machine and User' {
    foreach ($runScope in @('Machine', 'User', 'All')) {
        $captured = @(Invoke-CapturedPhases -Scope $runScope -Action 'Partial')
        $invalid = @($captured | Where-Object { @('Machine', 'User', 'All') -notcontains $_.Scope } | ForEach-Object { $_.Name })
        Assert ($invalid.Count -eq 0) "Partial/$runScope steps all have a valid scope$(if ($invalid.Count) { ' -> ' + ($invalid -join ', ') })"
        $selected = @($captured | Where-Object { $runScope -eq 'All' -or $_.Scope -eq $runScope } | ForEach-Object { $_.Name })
        $want = @($ExpectedPartialSteps[$runScope])
        Assert (($selected -join ',') -eq ($want -join ',')) "Partial/$runScope selects exactly its $($want.Count) steps (actual $($selected.Count): $($selected -join ', '))"
    }
}

Check 'Full and Uninstall steps all carry a scope' {
    foreach ($action in @('Full', 'Uninstall')) {
        $captured = @(Invoke-CapturedPhases -Scope 'All' -Action $action)
        Assert ($captured.Count -gt 0) "$action builds $($captured.Count) steps"
        $invalid = @($captured | Where-Object { @('Machine', 'User', 'All') -notcontains $_.Scope } | ForEach-Object { $_.Name })
        Assert ($invalid.Count -eq 0) "$action steps all have a valid scope$(if ($invalid.Count) { ' -> ' + ($invalid -join ', ') })"
    }
}

Check 'Scoped launches get an empty stdin and no tree wait; All keeps today''s launch' {
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($BootstrapPath, [ref]$null, [ref]$parseErrors)
    Assert (@($parseErrors).Count -eq 0) 'bootstrap.ps1 must parse.'
    $helpers = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-CalmOsSetupProcess'
    }, $true))
    Assert ($helpers.Count -eq 1) 'bootstrap.ps1 must define Start-CalmOsSetupProcess exactly once.'

    # Every Start-Process is the RunAs relaunch (All only) or goes through the helper.
    foreach ($command in @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process'
    }, $true))) {
        $hasVerb = @($command.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Verb'
        }).Count -gt 0
        $owner = $null
        for ($parent = $command.Parent; $parent; $parent = $parent.Parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $parent.Name; break }
        }
        Assert ($hasVerb -or $owner -eq 'Start-CalmOsSetupProcess') "bootstrap.ps1 line $($command.Extent.StartLineNumber) starts a process outside Start-CalmOsSetupProcess."
    }
    $launches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-CalmOsSetupProcess'
    }, $true))
    Assert ($launches.Count -eq 1) "Setup must be launched exactly once through Start-CalmOsSetupProcess (found $($launches.Count))."

    . ([scriptblock]::Create($helpers[0].Extent.Text))
    function Start-Process {
        param(
            [string] $FilePath, [string[]] $ArgumentList, [switch] $Wait, [switch] $PassThru,
            [switch] $NoNewWindow, [string] $RedirectStandardInput, [string] $Verb
        )
        $exists = [bool]($RedirectStandardInput -and (Test-Path -LiteralPath $RedirectStandardInput -PathType Leaf))
        $script:StartCalls += [pscustomobject]@{
            Wait        = [bool]$Wait
            PassThru    = [bool]$PassThru
            NoNewWindow = [bool]$NoNewWindow
            Stdin       = $RedirectStandardInput
            StdinExists = $exists
            StdinLength = if ($exists) { (Get-Item -LiteralPath $RedirectStandardInput).Length } else { -1 }
            Verb        = $Verb
        }
        $proc = [pscustomobject]@{ Handle = [IntPtr]::Zero; ExitCode = 7 }
        $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $script:Waits++ }
        return $proc
    }

    try {
        $launchArguments = @('-NoProfile', '-File', '"C:\Setup\dev-config.ps1"', '-Action', 'Partial')
        foreach ($action in @('Partial', 'Full', 'Uninstall')) {
            $script:StartCalls = @()
            $script:Waits = 0
            $code = Start-CalmOsSetupProcess -FilePath 'C:\PS\pwsh.exe' -ArgumentList $launchArguments -Action $action -Scope All
            Assert ($code -eq 7) "All/$action must return the child's exit code."
            Assert ($script:StartCalls.Count -eq 1) "All/$action must start one process."
            $call = $script:StartCalls[0]
            Assert ($call.Wait -and $call.PassThru -and -not $call.Stdin -and -not $call.Verb) "All/$action launch options changed."
            Assert ($call.NoNewWindow -eq ($action -ne 'Uninstall')) "All/$action console behavior changed."
            Assert ($script:Waits -eq 0) "All/$action must keep Start-Process -Wait."
        }
        foreach ($runScope in @('Machine', 'User')) {
            $script:StartCalls = @()
            $script:Waits = 0
            $code = Start-CalmOsSetupProcess -FilePath 'C:\PS\pwsh.exe' -ArgumentList $launchArguments -Action Partial -Scope $runScope
            Assert ($code -eq 7) "$runScope must return the child's exit code."
            Assert ($script:StartCalls.Count -eq 1) "$runScope must start one process."
            $call = $script:StartCalls[0]
            Assert ($call.StdinExists -and $call.StdinLength -eq 0) "$runScope must give setup an empty stdin file."
            Assert ($call.NoNewWindow -and $call.PassThru -and -not $call.Wait -and -not $call.Verb) "$runScope must not open a window, elevate, or wait for the process tree."
            Assert ($script:Waits -eq 1) "$runScope must wait for the setup process itself."
            Assert (-not (Test-Path -LiteralPath $call.Stdin)) "$runScope must delete its stdin file."
        }
    } finally {
        Remove-Item -Path Function:\Start-Process -ErrorAction SilentlyContinue
    }
}

Check 'Scoped native commands without their own limit stop after 15 minutes' {
    if (-not (Get-Command Invoke-DevConfigNativeCommand -CommandType Function -ErrorAction SilentlyContinue)) {
        . (Join-Path $StepsDirectory '_environment.ps1')
    }
    # The bounded path polls with Start-Sleep; stop it there and record the limit it chose.
    function Start-Sleep {
        param([int] $Milliseconds, [int] $Seconds)
        $script:ObservedTimeout = Get-Variable -Name TimeoutSeconds -Scope 1 -ValueOnly
        throw 'SENTINEL-SLEEP'
    }
    $ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
    $slow = @('-n', '3', '127.0.0.1')
    try {
        foreach ($case in @(
            @{ RunScope = 'Machine'; Timeout = 0; Expected = 900 }
            @{ RunScope = 'User'; Timeout = 0; Expected = 900 }
            @{ RunScope = 'User'; Timeout = 1200; Expected = 1200 }
            @{ RunScope = 'All'; Timeout = 5; Expected = 5 }
        )) {
            $script:DevConfigScope = $case.RunScope
            $script:ObservedTimeout = $null
            $message = $null
            try {
                $null = Invoke-DevConfigNativeCommand -FilePath $ping -Arguments $slow -TimeoutSeconds $case.Timeout
            } catch {
                $message = $_.Exception.Message
            }
            Assert ($message -eq 'SENTINEL-SLEEP') "$($case.RunScope) with timeout $($case.Timeout) must use the bounded path (got: $message)."
            Assert ($script:ObservedTimeout -eq $case.Expected) "$($case.RunScope) with timeout $($case.Timeout) chose $($script:ObservedTimeout) s, not $($case.Expected) s."
        }

        # All without a limit, and a file loaded on its own (no DevConfigScope), stay unbounded.
        foreach ($unbounded in @('All', $null)) {
            if ($unbounded) {
                $script:DevConfigScope = $unbounded
            } else {
                Remove-Variable -Name DevConfigScope -Scope Script -ErrorAction SilentlyContinue
            }
            $script:ObservedTimeout = $null
            $result = Invoke-DevConfigNativeCommand -FilePath $ping -Arguments @('-n', '1', '127.0.0.1')
            Assert ($result.ExitCode -eq 0 -and $null -eq $script:ObservedTimeout) "Unscoped native commands must keep running in-process without a limit ($unbounded)."
        }
    } finally {
        Remove-Item -Path Function:\Start-Sleep -ErrorAction SilentlyContinue
        Reset-ScopeState
    }
}

Check 'No loop or script-scope write named scope rebinds a -Scope parameter' {
    function Test-HasScopeParameter {
        param($Node)
        $parameters = @()
        if ($Node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            if ($Node.Parameters) { $parameters += $Node.Parameters }
            if ($Node.Body.ParamBlock) { $parameters += $Node.Body.ParamBlock.Parameters }
        } elseif ($Node -is [System.Management.Automation.Language.ScriptBlockAst] -and $Node.ParamBlock) {
            $parameters += $Node.ParamBlock.Parameters
        }
        return @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scope' }).Count -gt 0
    }
    function Get-AssignedVariable {
        param($Target, [bool] $Typed = $false)
        if ($Target -is [System.Management.Automation.Language.VariableExpressionAst]) {
            return [pscustomobject]@{ Variable = $Target; Typed = $Typed }
        }
        # [string] $x = ... and [ValidateSet()] $x = ... re-declare the variable and drop the parameter's attributes.
        if ($Target -is [System.Management.Automation.Language.AttributedExpressionAst]) {
            return Get-AssignedVariable -Target $Target.Child -Typed $true
        }
        if ($Target -is [System.Management.Automation.Language.ArrayLiteralAst]) {
            foreach ($element in $Target.Elements) { Get-AssignedVariable -Target $element -Typed $Typed }
        }
    }
    # Variable names ignore case, so foreach ($scope ...) inside an owner of -Scope rebinds it.
    # Step files are dot-sourced into dev-config.ps1, so their top-level and $script: writes rebind its -Scope.
    function Find-ScopeReuse {
        param($Ast, [switch] $DotSourced)
        $scriptOwnsScope = $DotSourced -or (Test-HasScopeParameter $Ast)
        $hits = @()
        foreach ($write in @($Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -or
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
        }, $true))) {
            $isLoop = $write -is [System.Management.Automation.Language.ForEachStatementAst]
            $written = if ($isLoop) {
                @([pscustomobject]@{ Variable = $write.Variable; Typed = $false })
            } else {
                @(Get-AssignedVariable -Target $write.Left)
            }
            foreach ($entry in $written) {
                $path = $entry.Variable.VariablePath
                if ($path.IsDriveQualified) { continue }
                if (($path.UserPath -replace '^(global|local|private|script):', '') -ne 'scope') { continue }
                $owner = $null
                for ($parent = $write.Parent; $parent; $parent = $parent.Parent) {
                    if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $parent; break }
                }
                if ($path.IsScript) {
                    $flag = $scriptOwnsScope
                } elseif ($path.IsGlobal) {
                    $flag = $false
                } else {
                    $ownerHasScope = if ($owner) { Test-HasScopeParameter $owner } else { $scriptOwnsScope }
                    $flag = $ownerHasScope -and ($isLoop -or $entry.Typed -or ($DotSourced -and -not $owner))
                }
                if ($flag) {
                    $file = if ($write.Extent.File) { Split-Path -Leaf $write.Extent.File } else { '<input>' }
                    $hits += '{0}:{1}' -f $file, $write.Extent.StartLineNumber
                }
            }
        }
        return $hits
    }

    $sample = [System.Management.Automation.Language.Parser]::ParseInput(@'
function Test-Sample {
    param([ValidateSet('All', 'Machine', 'User')] [string] $Scope = 'All')
    foreach ($scope in @('MachinePolicy', 'UserPolicy')) { }
    [string] $SCOPE = 'x'
    $Scope = $Scope.Trim()
    function Test-Nested { foreach ($scope in 1) { } }
}
function Test-Writer { $script:scope = 1; foreach ($scope in 1) { } }
foreach ($scope in 1) { }
$scope = 2
'@, [ref]$null, [ref]$null)
    $plainHits = @(Find-ScopeReuse -Ast $sample)
    Assert ($plainHits.Count -eq 2) "The detector must flag the loop and the typed write that rebind -Scope, and nothing else (got $($plainHits -join ', '))."
    $dotHits = @(Find-ScopeReuse -Ast $sample -DotSourced)
    Assert ($dotHits.Count -eq 5) "The detector must also flag script-scope and top-level writes in dot-sourced files (got $($dotHits -join ', '))."

    $targets = @(
        @{ Path = $BootstrapPath; DotSourced = $false; MustOwn = $true }
        @{ Path = $OrchestratorPath; DotSourced = $false; MustOwn = $true }
    )
    $skip = @([IO.Path]::GetFullPath($BootstrapPath), [IO.Path]::GetFullPath($OrchestratorPath))
    $targets += @(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.ps1' -File |
        Where-Object { $skip -notcontains $_.FullName } |
        ForEach-Object { @{ Path = $_.FullName; DotSourced = $false; MustOwn = $false } })
    foreach ($folder in @($StepsDirectory, (Join-Path $SourceDirectory 'workloads'))) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $targets += @(Get-ChildItem -LiteralPath $folder -Filter '*.ps1' -File |
                ForEach-Object { @{ Path = $_.FullName; DotSourced = $true; MustOwn = $false } })
        }
    }

    $problems = @()
    foreach ($target in $targets) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($target.Path, [ref]$null, [ref]$parseErrors)
        Assert (@($parseErrors).Count -eq 0) "$($target.Path) must parse."
        if ($target.MustOwn) {
            Assert (Test-HasScopeParameter $ast) "$(Split-Path -Leaf $target.Path) must declare -Scope."
        }
        if ($target.Path -eq $BootstrapPath) {
            $bootstrapFunction = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CalmOsBootstrap'
            }, $true)
            Assert ($bootstrapFunction -and (Test-HasScopeParameter $bootstrapFunction)) 'Invoke-CalmOsBootstrap must declare -Scope.'
        }
        $problems += @(Find-ScopeReuse -Ast $ast -DotSourced:$target.DotSourced)
    }
    Assert ($problems.Count -eq 0) ('A variable named scope rebinds a -Scope parameter at: ' + ($problems -join ', '))
}

$MicrosoftSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$LauncherFixture = @'
param([string]$Ref, [string]$Action, [string]$Scope, [string]$Workload, [switch]$AllowUnsigned, [switch]$NoLaunch)
[pscustomobject]@{ Ref = $Ref; Action = $Action; Scope = $Scope; Extra = @($args) }
'@

function New-SignatureResult([object]$Status, [string]$Subject) {
    $certificate = $null
    if ($Subject) { $certificate = [pscustomobject]@{ Subject = $Subject } }
    [pscustomobject]@{ Status = $Status; SignerCertificate = $certificate; StatusMessage = "mock $Status" }
}

function Invoke-LauncherUnderTest([string]$LauncherPath) {
    function Invoke-RestMethod {
        param([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec)
        $script:Downloads += @([pscustomobject]@{ Uri = $Uri; TimeoutSec = $TimeoutSec })
        [string][char]0xFEFF + $LauncherFixture
    }
    function Get-AuthenticodeSignature {
        param([byte[]]$Content, [string]$SourcePathOrExtension, [string]$FilePath)
        $script:SignatureChecks++
        $script:SignatureResult
    }
    function Start-Process { $script:Blocked += @('Start-Process'); throw 'BLOCKED Start-Process' }
    if ((Get-Command Invoke-RestMethod).CommandType -ne 'Function') { throw 'the Invoke-RestMethod mock is not in effect' }
    $modulePath = $env:PSModulePath
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        & { Get-Content -LiteralPath $LauncherPath -Raw | Invoke-Expression }
    } finally {
        $env:PSModulePath = $modulePath
        [Net.ServicePointManager]::SecurityProtocol = $protocol
    }
}

foreach ($launcher in @(
        @{ File = 'setup-standard-machine.ps1'; Scope = 'Machine' },
        @{ File = 'setup-standard-user.ps1'; Scope = 'User' })) {
    Check "Launcher $($launcher.File) runs the signed bootstrap with -Scope $($launcher.Scope)" {
        $launcherPath = Join-Path $SourceDirectory $launcher.File
        Assert (Test-Path -LiteralPath $launcherPath) "$($launcher.File) exists"
        if (-not (Test-Path -LiteralPath $launcherPath)) { return }
        $ast = Get-ScriptAst $launcherPath
        $exits = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        Assert ($exits.Count -eq 0) 'the launcher throws on failure instead of calling exit, so the spot process exits non-zero'
        $risky = @($ast.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.CommandAst] -and
                    @('irm', 'iwr', 'Invoke-WebRequest', 'Start-Process', 'saps', 'start', 'curl', 'wget') -contains $node.GetCommandName()) -or
                    ($node -is [System.Management.Automation.Language.TypeExpressionAst] -and $node.TypeName.FullName -match 'WebClient')
                }, $true))
        Assert ($risky.Count -eq 0) 'the launcher downloads only with plain Invoke-RestMethod and starts no process'
        Assert (@(Find-Commands $ast 'Wait-DevConfigKeyPress').Count -eq 0) 'the launcher never waits for a key press'
        if ($exits.Count -gt 0 -or $risky.Count -gt 0) { return }

        $script:Downloads = @()
        $script:SignatureChecks = 0
        $script:Blocked = @()
        $script:SignatureResult = New-SignatureResult ([System.Management.Automation.SignatureStatus]::Valid) $MicrosoftSubject
        $result = @(Invoke-LauncherUnderTest $launcherPath | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Ref'] })
        Assert ($result.Count -eq 1) 'the launcher ran the downloaded bootstrap once'
        Assert (@($script:Downloads).Count -eq 1) 'the launcher downloaded one file'
        if (@($script:Downloads).Count -ge 1) {
            $download = @($script:Downloads)[0]
            Assert ($download.Uri -match '^https://raw\.githubusercontent\.com/microsoft/WindowsDeveloperConfig/[0-9a-f]{40}/windows-dev-config/bootstrap\.ps1$') "the launcher downloads the pinned signed bootstrap ($($download.Uri))"
            Assert ($download.TimeoutSec -eq 60) 'the download times out after 60 seconds'
        }
        Assert ($script:SignatureChecks -ge 1) 'the launcher verifies the Microsoft signature'
        if ($result.Count -eq 1) {
            Assert ($result[0].Ref -match '^([0-9a-f]{40}|main)$') "the bootstrap gets a pinned -Ref ($($result[0].Ref))"
            Assert ($result[0].Action -eq 'Partial') 'the bootstrap gets -Action Partial'
            Assert ($result[0].Scope -eq $launcher.Scope) "the bootstrap gets -Scope $($launcher.Scope)"
        }
        Assert (@($script:Blocked).Count -eq 0) 'the launcher started no process'

        foreach ($bad in @(
                (New-SignatureResult ([System.Management.Automation.SignatureStatus]::NotSigned) $null),
                (New-SignatureResult ([System.Management.Automation.SignatureStatus]::HashMismatch) $MicrosoftSubject),
                (New-SignatureResult ([System.Management.Automation.SignatureStatus]::Valid) 'CN=Contoso, O=Contoso, L=Redmond, S=Washington, C=US'),
                (New-SignatureResult ([System.Management.Automation.SignatureStatus]::Valid) $null))) {
            $script:SignatureResult = $bad
            $script:Downloads = @()
            $failure = Get-FailureMessage { Invoke-LauncherUnderTest $launcherPath }
            Assert ($null -ne $failure -and $failure -like '*failed Microsoft signature verification*') "a $($bad.Status) signature from '$(if ($bad.SignerCertificate) { $bad.SignerCertificate.Subject } else { 'no signer' })' is rejected"
        }
    }
}

Check 'No script reads the console or prompts' {
    $banned = @('ReadKey', 'KeyAvailable', 'PromptForChoice', 'RawUI', 'CursorLeft', 'WindowWidth')
    $hits = @()
    foreach ($file in $SourceScripts) {
        if ($file.Name -eq '_console.ps1') { continue }
        $ast = Get-ScriptAst $file.FullName
        foreach ($call in (Find-Commands $ast 'Read-Host')) {
            $hits += [pscustomobject]@{ File = $file.FullName; Line = $call.Extent.StartLineNumber }
        }
        $members = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $banned -contains $node.Member.Value
                }, $true))
        foreach ($member in $members) {
            $hits += [pscustomobject]@{ File = $file.FullName; Line = $member.Extent.StartLineNumber }
        }
    }
    Assert ($hits.Count -eq 0) ('only _console.ps1 touches console input or prompts' + (Format-Locations $hits))
    foreach ($name in @('bootstrap.ps1', 'setup-standard-machine.ps1', 'setup-standard-user.ps1')) {
        $path = Join-Path $SourceDirectory $name
        if (Test-Path -LiteralPath $path) {
            Assert (@(Find-Commands (Get-ScriptAst $path) 'Wait-DevConfigKeyPress').Count -eq 0) "$name never waits for a key press"
        }
    }
}

function Test-ScopeGuarded($Node) {
    # True when the node sits in an if/elseif/else clause whose own or earlier condition reads a
    # scope variable, so a User run can be kept away from it.
    $child = $Node
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
            $conditions = @()
            $found = $false
            foreach ($clause in $parent.Clauses) {
                $conditions += $clause.Item1
                $inClause = $clause.Item2.Extent.StartOffset -le $child.Extent.StartOffset -and $child.Extent.EndOffset -le $clause.Item2.Extent.EndOffset
                if ($inClause) { $found = $true; break }
            }
            if (-not $found -and $null -eq $parent.ElseClause) { $conditions = @() }
            foreach ($condition in $conditions) {
                $scopeVariables = @($condition.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $node.VariablePath.UserPath -notmatch '^env:' -and
                            $node.VariablePath.UserPath -match 'Scope|User|Scenario'
                        }, $true))
                if ($scopeVariables.Count -gt 0) { return $true }
            }
        }
        $child = $parent
        $parent = $parent.Parent
    }
    return $false
}

function Get-NearestFunctionName {
    param($Node)
    for ($p = $Node.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
    }
    return $null
}

Check 'User runs skip elevation and the Administrators-only folders' {
    $bootstrapAst = Get-ScriptAst $BootstrapPath
    $runAs = @(Find-Commands $bootstrapAst 'Start-Process' | Where-Object {
            $verb = Get-CommandParameterAst $_ 'Verb'
            $null -ne $verb -and $verb.Extent.Text -match 'RunAs'
        })
    Assert ($runAs.Count -gt 0) "bootstrap.ps1 has $($runAs.Count) RunAs relaunch to guard"
    $unguarded = @($runAs | Where-Object { -not (Test-ScopeGuarded $_) } | ForEach-Object {
            [pscustomobject]@{ File = $BootstrapPath; Line = $_.Extent.StartLineNumber }
        })
    Assert ($unguarded.Count -eq 0) ('a User run can never reach the RunAs relaunch' + (Format-Locations $unguarded))

    $protected = @()
    foreach ($name in @('New-DevConfigProtectedDirectory', 'Assert-DevConfigProtectedTree')) {
        foreach ($call in (Find-Commands $bootstrapAst $name)) {
            if ((Get-NearestFunctionName $call) -eq 'Invoke-CalmOsBootstrap') { $protected += [pscustomobject]@{ File = $BootstrapPath; Line = $call.Extent.StartLineNumber; Ast = $call } }
        }
    }
    $orchestratorAst = Get-ScriptAst $OrchestratorPath
    foreach ($call in (Find-Commands $orchestratorAst 'Assert-DevConfigProtectedTree')) {
        if ($null -eq (Get-NearestFunctionName $call)) { $protected += [pscustomobject]@{ File = $OrchestratorPath; Line = $call.Extent.StartLineNumber; Ast = $call } }
    }
    Assert ($protected.Count -gt 0) "found $($protected.Count) protected-folder calls to guard"
    $unguardedProtected = @($protected | Where-Object { -not (Test-ScopeGuarded $_.Ast) })
    Assert ($unguardedProtected.Count -eq 0) ('a User run never creates or asserts an Administrators-only folder' + (Format-Locations $unguardedProtected))

    $signedChecks = @(Find-Commands $bootstrapAst 'Assert-DevConfigMicrosoftSigned').Count + @(Find-Commands $orchestratorAst 'Assert-DevConfigMicrosoftSigned').Count
    Assert ($signedChecks -gt 0) 'signed runs still verify the Microsoft signature'
}

Check 'Machine and User parts accept only the standard setup (-Action Partial)' {
    $bootstrapAst = Get-ScriptAst $BootstrapPath
    $bootstrapFunction = $bootstrapAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CalmOsBootstrap'
        }, $true)
    Assert ($null -ne $bootstrapFunction) 'bootstrap.ps1 defines Invoke-CalmOsBootstrap'
    if ($null -eq $bootstrapFunction) { return }
    . ([scriptblock]::Create($bootstrapFunction.Extent.Text))
    . $GuardMocks
    function Write-Host { $script:HostLines += @("$args") }
    function New-DevConfigProtectedDirectory { $script:Blocked += @('New-DevConfigProtectedDirectory'); throw 'BLOCKED New-DevConfigProtectedDirectory' }
    function Assert-DevConfigProtectedTree { $script:Blocked += @('Assert-DevConfigProtectedTree'); throw 'BLOCKED Assert-DevConfigProtectedTree' }
    # Bootstrap reads the execution policy right after it validates its parameters; stop there.
    function Get-ExecutionPolicy { throw 'SENTINEL past validation' }

    $message = '-Scope Machine and -Scope User apply only to the standard Windows Dev Config setup (-Action Partial).'
    $modulePath = $env:PSModulePath
    try {
        $script:Blocked = @()
        foreach ($case in @(
                @{ Label = '-Scope Machine -Action Full'; Arguments = @{ Scope = 'Machine'; Action = 'Full' } },
                @{ Label = '-Scope User -Action Full'; Arguments = @{ Scope = 'User'; Action = 'Full' } },
                @{ Label = '-Scope Machine -Action Uninstall'; Arguments = @{ Scope = 'Machine'; Action = 'Uninstall' } },
                @{ Label = '-Scope User -Action Uninstall'; Arguments = @{ Scope = 'User'; Action = 'Uninstall' } },
                @{ Label = '-Scope Machine without -Action (Full)'; Arguments = @{ Scope = 'Machine' } },
                @{ Label = '-Scope User -Scenario cuda'; Arguments = @{ Scope = 'User'; Scenario = 'cuda' } },
                @{ Label = '-Scope Machine -Action Partial -Workload winui'; Arguments = @{ Scope = 'Machine'; Action = 'Partial'; Workload = 'winui' } })) {
            $arguments = $case.Arguments
            $failure = Get-FailureMessage { Invoke-CalmOsBootstrap -Ref 'main' -AllowUnsigned -NoLaunch @arguments }
            Assert ($failure -eq $message) "bootstrap rejects $($case.Label) (error: $failure)"
        }
        foreach ($runScope in @('Machine', 'User')) {
            $failure = Get-FailureMessage { Invoke-CalmOsBootstrap -Ref 'main' -AllowUnsigned -NoLaunch -Action Partial -Scope $runScope }
            Assert ($failure -eq 'SENTINEL past validation') "bootstrap accepts -Scope $runScope -Action Partial (stopped at: $failure)"
        }
        foreach ($action in @('Full', 'Partial', 'Uninstall')) {
            $failure = Get-FailureMessage { Invoke-CalmOsBootstrap -Ref 'main' -AllowUnsigned -NoLaunch -Action $action }
            Assert ($failure -eq 'SENTINEL past validation') "bootstrap still accepts -Action $action without -Scope (stopped at: $failure)"
        }
        Assert (@($script:Blocked).Count -eq 0) "validation touched nothing real (blocked: $(@($script:Blocked) -join ', '))"
    } finally {
        $env:PSModulePath = $modulePath
    }

    $orchestratorAst = Get-ScriptAst $OrchestratorPath
    $throws = @($orchestratorAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ThrowStatementAst] -and $null -ne $node.Pipeline -and
                (Get-ConstantStatementValue $node.Pipeline) -eq $message
            }, $true))
    Assert ($throws.Count -eq 1) 'dev-config.ps1 rejects the same combinations with the same message'
}

Write-CheckLine ''
$summaryColor = 'Green'
if ($script:failed -gt 0) { $summaryColor = 'Red' }
Write-CheckLine ('Scope checks: {0} passed, {1} failed' -f $script:passed, $script:failed) $summaryColor
if ($script:failed -gt 0) { exit 1 }
exit 0
