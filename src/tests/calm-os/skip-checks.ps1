# Checks bootstrap.ps1 / dev-config.ps1 -Skip without changing the machine: every registry, WinGet,
# WSL, and process call a skipped or kept step could make is replaced by a recording fake.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\windows-dev-config')).Path
$stepsDir = Join-Path $sourceRoot 'steps'
$orchestrator = Join-Path $sourceRoot 'dev-config.ps1'
foreach ($helper in @('_console', '_step-runner', '_elevation', '_reboot-resume', '_registry', '_environment',
        '_retry', '_terminal', '_winget', '_pwsh-bootstrap', '_workload')) {
    . (Join-Path $stepsDir "$helper.ps1")
}
foreach ($phase in @('prerequisites', 'registry-system', 'terminal', 'packages', 'wsl')) {
    . (Join-Path $stepsDir "$phase.ps1")
}

$script:passed = 0
$script:failed = 0
function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
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
function Expect-Failure([scriptblock] $Action) {
    try { & $Action } catch { return $_ }
    throw 'Expected an error, but the operation succeeded.'
}

# ---- Fakes: nothing below reaches the real registry, WinGet, WSL, or task scheduler.
$script:Registry = @{}
$script:Calls = [Collections.Generic.List[string]]::new()
function Test-DevConfigRegistryValue {
    param([string] $KeyPath, [string] $ValueName, $Value)
    $script:Calls.Add("check $KeyPath\$ValueName")
    $key = "$KeyPath\$ValueName"
    return $script:Registry.ContainsKey($key) -and "$($script:Registry[$key])" -eq "$Value"
}
function Set-DevConfigRegistryValue {
    param([string] $KeyPath, [string] $ValueName, $Value, [string] $Type = 'DWord')
    $script:Calls.Add("set $KeyPath\$ValueName=$Value")
    $script:Registry["$KeyPath\$ValueName"] = $Value
}
function Test-DevConfigRegistryValueAbsent {
    param([string] $KeyPath, [string] $ValueName)
    $script:Calls.Add("check $KeyPath\$ValueName")
    return -not $script:Registry.ContainsKey("$KeyPath\$ValueName")
}
function New-ItemProperty { throw 'Checks must not write the registry.' }
function Remove-ItemProperty { throw 'Checks must not write the registry.' }
function Initialize-DevConfigWinGet { $script:Calls.Add('winget init') }
function Confirm-DevConfigWinGetReady { $script:Calls.Add('winget ready') }
function Test-DevConfigWingetPackageInstalled {
    param([string] $Id, [switch] $AnyVersion)
    $script:Calls.Add("check package $Id")
    return $script:Registry.ContainsKey("package:$Id")
}
function Install-DevConfigWingetPackage {
    param([string] $Id)
    $script:Calls.Add("install $Id")
    $script:Registry["package:$Id"] = $true
}
function Wait-DevConfigWingetPackageSettled { param([string] $Id, [switch] $AnyVersion) }
function Invoke-DevConfigPackageCleanup {
    param([string[]] $Ids, $InnoUninstall, [switch] $CheckOnly)
    $script:Calls.Add("$(if ($CheckOnly) { 'check' } else { 'remove' }) package $($Ids -join ',')")
    if (-not $CheckOnly) { foreach ($id in $Ids) { $script:Registry.Remove("package:$id") } }
    return -not @($Ids | Where-Object { $script:Registry.ContainsKey("package:$_") }).Count
}
function Test-DevConfigPs7DefaultProfile { return $true }
function Set-DevConfigPs7DefaultProfile { throw 'Checks must not change Terminal settings.' }
function Test-DevConfigWslComponentsReady { return $true }
function Test-DevConfigUbuntuInstalled { return $script:Registry.ContainsKey('wsl:Ubuntu') }
function Install-DevConfigUbuntuVia {
    param([string[]] $Arguments, [int] $MaxAttempts)
    $script:Calls.Add("wsl $($Arguments -join ' ')")
    $script:Registry['wsl:Ubuntu'] = $true
    return $true
}
function Install-DevConfigWslPlatform { throw 'Checks must not install WSL.' }
$script:FakePwsh = $null
function Get-DevConfigPwshExe { return $script:FakePwsh }
function Install-DevConfigPwshBootstrap { $script:Calls.Add('install pwsh (handoff)') }
function Confirm-DevConfigPwshInUse { $script:Calls.Add('install pwsh (prerequisite)') }
function Test-DevConfigWinGetTargetVersion { return $true }
function Update-DevConfigWinget { throw 'Checks must not update WinGet.' }
# Stops the PowerShell 7 handoff before it would exit this script.
function Start-Process {
    param($FilePath, $ArgumentList, [switch] $Wait, [switch] $NoNewWindow, [switch] $PassThru, $Verb)
    $script:Calls.Add("relaunch $FilePath $($ArgumentList -join ' ')")
    throw 'relaunch stopped'
}

function Reset-Fakes {
    param([string[]] $Skip = @(), [string] $Action = 'Full')
    $script:Registry = @{}
    $script:Calls.Clear()
    $Script:DevConfigSkip = @($Skip)
    $Script:DevConfigAction = $Action
    $Script:DevConfigResumed = $false
    $Script:DevConfigTally = @{ Done = 0; AlreadyOk = 0; Warned = 0 }
    $Script:DevConfigTalliedSteps = @{}
    $Script:DevConfigWarnedSteps = @()
}
function Invoke-Phase {
    param([hashtable] $Phase)
    $Script:DevConfigPhaseTitle = $Phase.Title
    $Script:DevConfigPhaseHeaderShown = $false
    return @(Invoke-DevConfigWorkloadPhase -Phase $Phase -OrchestratorPath $orchestrator 6>&1 | ForEach-Object { "$_" })
}
$registrySystemPhase = @{ File = 'registry-system.ps1'; Function = 'Invoke-RegistrySystemPhase'; Title = 'System settings' }
$terminalPhase = @{ File = 'terminal.ps1'; Function = 'Invoke-TerminalPhase'; Title = 'Windows Terminal' }
$wslPhase = @{ File = 'wsl.ps1'; Function = 'Invoke-WslPhase'; Title = 'WSL + Ubuntu' }
function New-PackagesPhase([string[]] $Packages) {
    @{ File = 'packages.ps1'; Function = 'Invoke-PackagesPhase'; Title = 'Packages'; Parameters = @{ Packages = $Packages } }
}

# The ids callers send, exactly as Windows Dev Config names its settings, steps, and packages.
# Renaming any of these breaks callers, so this list changes only together with them.
$contractIds = @(
    'registry-system/Sudo', 'registry-system/DeveloperMode', 'registry-system/LongPaths', 'registry-system/RemoteDesktop'
    'registry-explorer/ShowFileExtensions', 'registry-explorer/ShowHiddenFiles', 'registry-explorer/FullPathTitlebar'
    'registry-explorer/OpenThisPC', 'registry-explorer/FrequentFolders', 'registry-explorer/FrequentFiles'
    'registry-explorer/RecommendedFiles', 'registry-explorer/TipsOff', 'registry-explorer/DetailsContainer'
    'registry-explorer/ExplorerDisplayReset'
    'registry-taskbar-search/DoNotDisturb', 'registry-taskbar-search/BluetoothOff', 'registry-taskbar-search/EndTask'
    'registry-taskbar-search/WebSearchOff', 'registry-taskbar-search/SearchHighlightOff'
    'registry-taskbar-search/StartRecommendations', 'registry-taskbar-search/StartAccountNotifications'
    'registry-taskbar-search/WidgetServiceOff', 'registry-taskbar-search/QuietHoursProfile'
    'edge/EdgeNewTab', 'edge/EdgeOOBE'
    'prerequisites/PowerShell7', 'prerequisites/WinGet'
    'fonts/CascadiaFonts', 'fonts/CascadiaDefaultFont'
    'terminal/DarkTheme', 'terminal/AppsTheme', 'terminal/SystemTheme', 'terminal/Ps7DefaultProfile', 'terminal/TerminalReset'
    'powershell-profile/OhMyPoshProfile', 'powershell-profile/OhMyPoshProfileCleanup'
    'copilot/GitHubCopilotProfile', 'copilot/WinUITemplates', 'copilot/WinSkillsMarketplace', 'copilot/WinUIPlugin'
    'copilot/CopilotFragmentCleanup', 'copilot/WinUIPluginCleanup', 'copilot/WinSkillsMarketplaceCleanup', 'copilot/WinUITemplatesCleanup'
    'wsl/WslComponents', 'wsl/WslUbuntu', 'wsl/WslFirstRun', 'wsl/WslCleanup'
    'packages/PowerToysAOT'
    'Microsoft.WindowsTerminal', 'Microsoft.IntelligentTerminal', 'Microsoft.PowerShell', 'Git.Git', 'GitHub.cli'
    'Microsoft.AzureCLI', 'GitHub.Copilot', 'Microsoft.VisualStudioCode', 'Microsoft.DotNet.SDK.10', 'Python.Python.3.14'
    'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.arm64', 'astral-sh.uv', 'OpenJS.NodeJS.LTS'
    'CoreyButler.NVMforWindows', 'Microsoft.Coreutils', 'JanDeDobbeleer.OhMyPosh', 'Microsoft.WinAppCli', 'Microsoft.PowerToys'
)

Check 'Every Windows Dev Config setting, step, and package id is accepted, and nothing else' {
    Reset-Fakes
    $ids = @(Get-DevConfigWorkloadSkipIds -Directory (Join-Path $sourceRoot 'workloads') -Workload devconfig `
        -Actions @('Full', 'Partial', 'Uninstall') -OrchestratorPath $orchestrator)
    $missing = @($contractIds | Where-Object { $ids -notcontains $_ })
    $extra = @($ids | Where-Object { $contractIds -notcontains $_ })
    Assert ($missing.Count -eq 0) "Missing ids: $($missing -join ', ')"
    Assert ($extra.Count -eq 0) "Unexpected ids: $($extra -join ', ')"
    Assert ($script:Calls.Count -eq 0) "Listing ids checked or changed something: $($script:Calls -join '; ')"
    Assert ($null -eq $Script:DevConfigSkipCatalog -and $Script:DevConfigAction -eq 'Full' -and -not $Script:DevConfigPhaseName) 'Listing ids left run state behind.'
}

Check 'Every workload lists its ids without running a phase' {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'workloads') -Filter '*.ps1') {
        Reset-Fakes
        $definition = & $file.FullName -Action Full
        $ids = @(Get-DevConfigWorkloadSkipIds -Directory $file.DirectoryName -Workload $file.BaseName `
            -Actions @($definition['Actions']) -OrchestratorPath $orchestrator)
        Assert ($ids.Count -gt 0) "$($file.BaseName) listed no ids."
        Assert ($script:Calls.Count -eq 0) "$($file.BaseName) checked or changed something while listing ids."
    }
}

Check 'An unknown id stops before anything runs and names the valid ids' {
    Reset-Fakes
    $failure = Expect-Failure {
        Assert-DevConfigWorkloadSkipIds -Skip @('registry-system/Sudo', 'registry-system/Sudoo') -Directory (Join-Path $sourceRoot 'workloads') `
            -Workload devconfig -Actions @('Full', 'Partial', 'Uninstall') -OrchestratorPath $orchestrator
    }
    $message = $failure.Exception.Message
    Assert ($message -like '*no item called registry-system/Sudoo,*nothing was changed*') "Unclear message: $message"
    Assert ($message -like '*registry-system/Sudo,*' -and $message -like '*Microsoft.AzureCLI*') 'The message must list the accepted ids.'
    Assert ($script:Calls.Count -eq 0) 'Validation must not check or change anything.'
    Assert-DevConfigWorkloadSkipIds -Skip @('REGISTRY-SYSTEM/sudo', 'microsoft.azurecli') -Directory (Join-Path $sourceRoot 'workloads') `
        -Workload devconfig -Actions @('Full') -OrchestratorPath $orchestrator
}

Check 'dev-config.ps1 validates -Skip before TLS, elevation, PowerShell 7, the run lock, or any phase' {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($orchestrator, [ref]$tokens, [ref]$parseErrors)
    Assert (-not $parseErrors) 'dev-config.ps1 must parse.'
    $first = {
        param([string] $Name)
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true)
        Assert ($null -ne $node) "$Name was not found."
        $node.Extent.StartOffset
    }
    $validate = & $first 'Assert-DevConfigWorkloadSkipIds'
    foreach ($later in @('Enable-DevConfigModernTls', 'Invoke-DevConfigElevate', 'Invoke-DevConfigEnsurePwsh',
            'Invoke-DevConfigEnsureCleanupShell', 'Enter-DevConfigSingleInstance', 'Invoke-DevConfigWorkloadPhase')) {
        Assert ($validate -lt (& $first $later)) "-Skip must be validated before $later."
    }
}

Check 'A comma-separated string from a process command line becomes the same ids' {
    $ids = @(ConvertTo-DevConfigSkipIds -Skip @('registry-system/Sudo,fonts/CascadiaDefaultFont, Microsoft.AzureCLI,,registry-system/sudo'))
    Assert (($ids -join '|') -ceq 'registry-system/Sudo|fonts/CascadiaDefaultFont|Microsoft.AzureCLI') "Unexpected ids: $($ids -join '|')"
    Assert (@(ConvertTo-DevConfigSkipIds -Skip $null).Count -eq 0) 'No -Skip must mean no ids.'
    foreach ($bad in @("registry-system/Sudo'; calc", 'a b', 'registry-system/Sudo/x', '"quoted"')) {
        $failure = Expect-Failure { ConvertTo-DevConfigSkipIds -Skip @($bad) }
        Assert ($failure.Exception.Message -like '*is not a -Skip id*') "Accepted a malformed id: $bad"
    }
}

Check 'Relaunches, PowerShell 7 handoff, cleanup shell, and reboot resume keep -Skip' {
    $arguments = Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup Files\dev-config.ps1' -Action Full -Skip @('registry-system/Sudo', 'Git.Git')
    Assert (($arguments -join ' ') -eq '-NoProfile -ExecutionPolicy RemoteSigned -File "C:\Setup Files\dev-config.ps1" -Action Full -Skip registry-system/Sudo,Git.Git -NoElevate') "Unexpected arguments: $arguments"
    $plain = Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -Action Partial -Skip @()
    Assert (($plain -join ' ') -eq '-NoProfile -ExecutionPolicy RemoteSigned -File "C:\Setup\dev-config.ps1" -Action Partial -NoElevate') 'No -Skip must leave the command line unchanged.'
    $roundTrip = @(ConvertTo-DevConfigSkipIds -Skip @($arguments[$arguments.IndexOf('-Skip') + 1]))
    Assert (($roundTrip -join '|') -ceq 'registry-system/Sudo|Git.Git') 'The relaunched process must receive the same ids.'

    foreach ($function in @('Invoke-DevConfigElevate', 'Invoke-DevConfigEnsurePwsh', 'Invoke-DevConfigEnsureCleanupShell')) {
        $calls = @((Get-Command $function).ScriptBlock.Ast.FindAll({
            param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-DevConfigRelaunchArguments'
        }, $true))
        Assert ($calls.Count -eq 1 -and $calls[0].Extent.Text -like '*-Skip $Skip*') "$function must forward -Skip."
    }

    $script:taskArgument = $null
    function New-ScheduledTaskAction { param($Execute, $Argument) $script:taskArgument = $Argument; throw 'stop before registering' }
    function Register-ScheduledTask { throw 'Checks must not register tasks.' }
    function Invoke-DevConfigNativeCommand { throw 'Checks must not restart Windows.' }
    $Script:DevConfigSkip = @('registry-system/Sudo', 'wsl/WslFirstRun')
    $Script:DevConfigAction = 'Full'
    $Script:DevConfigAllowUnsigned = $false
    $null = Expect-Failure { Suspend-DevConfigForReboot -ScriptPath 'C:\Setup\dev-config.ps1' }
    Assert ($script:taskArgument -like '*-Action Full -Skip registry-system/Sudo,wsl/WslFirstRun -Resumed*') "Resume lost -Skip: $script:taskArgument"
}

Check 'Without -Skip every step is checked as before' {
    Reset-Fakes -Action Full
    $null = Invoke-Phase $registrySystemPhase
    foreach ($value in @('Sudo\Enabled=3', 'AppModelUnlock\AllowDevelopmentWithoutDevLicense=1', 'FileSystem\LongPathsEnabled=1', 'Terminal Server\fDenyTSConnections=0')) {
        Assert (@($script:Calls | Where-Object { $_ -like "set *$value" }).Count -eq 1) "Expected $value to be applied."
    }
}

foreach ($action in @('Full', 'Uninstall')) {
    Check "A skipped Security setting (Sudo) is never read or written during $action" {
        Reset-Fakes -Skip @('registry-system/Sudo') -Action $action
        $output = Invoke-Phase $registrySystemPhase
        Assert (@($script:Calls | Where-Object { $_ -like '*\Sudo\*' }).Count -eq 0) "Sudo was touched: $($script:Calls -join '; ')"
        Assert (@($script:Calls | Where-Object { $_ -like 'set *AppModelUnlock*' }).Count -eq 1) 'Other settings must still be applied.'
        Assert (@($output | Where-Object { $_ -match '^\s+- Sudo(Reset)?\s+skipped$' }).Count -eq 1) 'The skipped step must be reported.'
    }
}

Check 'Skipping one theme setting leaves it alone; skipping both skips DarkTheme' {
    Reset-Fakes -Skip @('terminal/AppsTheme') -Action Full
    $null = Invoke-Phase $terminalPhase
    $sets = @($script:Calls | Where-Object { $_ -like 'set *' })
    Assert ($sets.Count -eq 1 -and $sets[0] -like '*\SystemUsesLightTheme=0') "Unexpected theme writes: $($sets -join '; ')"
    Assert (@($script:Calls | Where-Object { $_ -like '*AppsUseLightTheme*' }).Count -eq 0) 'The skipped theme setting was read or written.'

    Reset-Fakes -Skip @('terminal/AppsTheme', 'terminal/SystemTheme') -Action Full
    $output = Invoke-Phase $terminalPhase
    Assert ($script:Calls.Count -eq 0) "Theme was touched: $($script:Calls -join '; ')"
    Assert (@($output | Where-Object { $_ -match '^\s+- DarkTheme\s+skipped$' }).Count -eq 1) 'DarkTheme must be reported as skipped.'
}

Check 'A skipped package is never installed, and its settings stay untouched' {
    Reset-Fakes -Skip @('Microsoft.PowerToys', 'Microsoft.VCRedist.2015+.x64', 'microsoft.vcredist.2015+.arm64') -Action Full
    $null = Invoke-Phase (New-PackagesPhase @('Git', 'VCRedist', 'PowerToys'))
    $installs = @($script:Calls | Where-Object { $_ -like 'install *' })
    Assert (($installs -join ';') -eq 'install Git.Git') "Unexpected installs: $($installs -join '; ')"
    Assert (@($script:Calls | Where-Object { $_ -like '*PowerToys*' -or $_ -like '*VCRedist*' }).Count -eq 0) "A skipped package was touched: $($script:Calls -join '; ')"

    Reset-Fakes -Skip @('packages/PowerToysAOT') -Action Full
    $null = Invoke-Phase (New-PackagesPhase @('PowerToys'))
    Assert (@($script:Calls | Where-Object { $_ -like 'install Microsoft.PowerToys' }).Count -eq 1) 'PowerToys itself must still install.'
    Assert (@($script:Calls | Where-Object { $_ -like '*PowerToysWin32*' }).Count -eq 0) 'The skipped PowerToys setting was touched.'

    Reset-Fakes -Skip @('Git.Git') -Action Full
    $null = Invoke-Phase (New-PackagesPhase @('Git'))
    Assert ($script:Calls.Count -eq 0) "Skipping every package must also skip WinGet setup: $($script:Calls -join '; ')"
}

Check 'A skipped package is not removed during Uninstall' {
    Reset-Fakes -Skip @('Git.Git', 'Microsoft.PowerToys') -Action Uninstall
    $script:Registry['package:Git.Git'] = $true
    $script:Registry['package:astral-sh.uv'] = $true
    $script:Registry['package:Microsoft.PowerToys'] = $true
    function Get-DevConfigUvCleanupPath { }
    function Remove-DevConfigUv { param($Id) Invoke-DevConfigPackageCleanup -Ids @($Id) }
    $null = Invoke-Phase (New-PackagesPhase @('Git', 'UV', 'PowerToys'))
    Assert (@($script:Calls | Where-Object { $_ -like '*Git.Git*' -or $_ -like '*PowerToys*' }).Count -eq 0) "A skipped package was touched: $($script:Calls -join '; ')"
    Assert (@($script:Calls | Where-Object { $_ -eq 'remove package astral-sh.uv' }).Count -eq 1) 'Other packages must still be removed.'
}

Check 'Skipping WslFirstRun installs Ubuntu without writing the first-run setting' {
    Reset-Fakes -Skip @('wsl/WslFirstRun', 'wsl/WslComponents') -Action Full
    $null = Invoke-Phase $wslPhase
    Assert (@($script:Calls | Where-Object { $_ -like 'wsl --install -d Ubuntu*' }).Count -eq 1) 'Ubuntu must still install.'
    Assert (@($script:Calls | Where-Object { $_ -like '*Lxss*' }).Count -eq 0) 'The skipped first-run setting was written.'

    Reset-Fakes -Skip @('wsl/WslComponents') -Action Full
    $null = Invoke-Phase $wslPhase
    Assert (@($script:Calls | Where-Object { $_ -like 'set *Lxss\OOBEComplete=1' }).Count -eq 1) 'Without the skip, the first-run setting must be written.'
}

# PowerShell 7 can be installed by the handoff before the phases, by the PowerShell7 prerequisite, or as a package.
$originalEdition = $PSVersionTable.PSEdition
$originalVersion = $PSVersionTable.PSVersion
try {
    $PSVersionTable.PSEdition = 'Desktop'
    $PSVersionTable.PSVersion = [version]'5.1'
    $prerequisitesPhase = @{ File = 'prerequisites.ps1'; Function = 'Invoke-PrerequisitesPhase'; Title = 'Getting ready' }

    foreach ($id in @('prerequisites/PowerShell7', 'Microsoft.PowerShell', 'microsoft.powershell')) {
        Check "Declining PowerShell 7 as $id blocks every install path when it is absent" {
            Reset-Fakes -Skip @($id) -Action Full
            $script:FakePwsh = $null
            $null = Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1' -Action Full -Skip @($id) 6>&1
            $null = Invoke-Phase $prerequisitesPhase
            $null = Invoke-Phase (New-PackagesPhase @('PowerShell', 'Git'))
            Assert (@($script:Calls | Where-Object { $_ -like '*pwsh*' -or $_ -like '*Microsoft.PowerShell*' }).Count -eq 0) "PowerShell 7 was touched: $($script:Calls -join '; ')"
            Assert (@($script:Calls | Where-Object { $_ -eq 'install Git.Git' }).Count -eq 1) 'Other packages must still install.'
        }
    }

    Check 'Declining PowerShell 7 still uses a copy that is already installed' {
        Reset-Fakes -Skip @('Microsoft.PowerShell') -Action Full
        $script:FakePwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $null = Expect-Failure { Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1' -Action Full -Skip @('Microsoft.PowerShell') 6>$null }
        Assert (@($script:Calls | Where-Object { $_ -like 'install pwsh*' }).Count -eq 0) 'An installed PowerShell 7 must not be reinstalled.'
        Assert (@($script:Calls | Where-Object { $_ -like 'relaunch C:\Program Files\PowerShell\7\pwsh.exe *-Skip Microsoft.PowerShell*' }).Count -eq 1) "The handoff must reuse it and keep -Skip: $($script:Calls -join '; ')"
    }

    Check 'Without -Skip, a missing PowerShell 7 is installed as before' {
        Reset-Fakes -Action Full
        $script:FakePwsh = $null
        $null = Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1' -Action Full 6>$null
        $null = Invoke-Phase $prerequisitesPhase
        Assert (@($script:Calls | Where-Object { $_ -eq 'install pwsh (handoff)' }).Count -eq 1) 'The handoff must install PowerShell 7.'
        Assert (@($script:Calls | Where-Object { $_ -eq 'install pwsh (prerequisite)' }).Count -eq 1) 'The prerequisite must still run.'
    }
} finally {
    $PSVersionTable.PSEdition = $originalEdition
    $PSVersionTable.PSVersion = $originalVersion
    $script:FakePwsh = $null
}

# ---- bootstrap.ps1
$tokens = $null; $parseErrors = $null
$bootstrapAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join [Environment]::NewLine) }
$bootstrapFunction = $bootstrapAst.Find({
    param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CalmOsBootstrap'
}, $true)
. ([scriptblock]::Create($bootstrapFunction.Extent.Text))

Check 'bootstrap.ps1 declares -Skip as a string array callers can detect' {
    $parameter = @($bootstrapAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Skip' })
    Assert ($parameter.Count -eq 1 -and $parameter[0].StaticType -eq [string[]]) 'bootstrap.ps1 must declare [string[]] $Skip.'
}

# '..' fails ref validation, so a missing -Skip check still cannot reach the network or UAC.
Check 'bootstrap.ps1 rejects malformed ids and -Scenario before downloading or elevating' {
    $failure = Expect-Failure { Invoke-CalmOsBootstrap -Ref '..' -Skip "registry-system/Sudo,bad id'" }
    Assert ($failure.Exception.Message -like "*'bad id'' is not a -Skip id*") "Unexpected error: $($failure.Exception.Message)"
    $failure = Expect-Failure { Invoke-CalmOsBootstrap -Ref '..' -Scenario cuda -Skip 'registry-system/Sudo' }
    Assert ($failure.Exception.Message -like '*cannot be combined with -Scenario*') "Unexpected error: $($failure.Exception.Message)"
    $failure = Expect-Failure { Invoke-CalmOsBootstrap -Ref '..' -Skip 'registry-system/Sudo,fonts/CascadiaDefaultFont,Microsoft.AzureCLI' }
    Assert ($failure.Exception.Message -like "*'..' is not a valid branch*") "Valid ids were rejected: $($failure.Exception.Message)"
}

Check 'bootstrap.ps1 forwards -Skip through UAC, the downloaded bootstrap, and dev-config.ps1' {
    $elevation = $bootstrapAst.Find({
        param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CalmOsElevationCommand'
    }, $true)
    function Invoke-DevConfigWebRequest { }
    . ([scriptblock]::Create($elevation.Extent.Text))
    $command = Get-CalmOsElevationCommand -Ref ('a' * 40) -InstallRoot 'C:\ProgramData\CalmOS' -Action Full `
        -Skip @('registry-system/Sudo', 'Microsoft.AzureCLI')
    Assert ($command -like "*-Action 'Full' -Skip 'registry-system/Sudo,Microsoft.AzureCLI'*") 'The elevated command must carry -Skip.'
    $plain = Get-CalmOsElevationCommand -Ref ('a' * 40) -InstallRoot 'C:\ProgramData\CalmOS' -Action Full
    Assert ($plain -notlike "*-Skip '*") 'No -Skip must leave the elevated command unchanged.'
    Assert ($elevation.Extent.Text -like "*`$arguments += '-Skip', (`$Skip -join ',')*") 'The launcher must pass -Skip to the downloaded bootstrap.'
    Assert ($bootstrapFunction.Extent.Text -like "*if (`$Skip.Count -gt 0) { `$arguments += '-Skip', (`$Skip -join ',') }*") 'Bootstrap must pass -Skip to dev-config.ps1.'
}

Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
