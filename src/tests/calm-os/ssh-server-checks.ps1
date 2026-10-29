# Checks the opt-in -EnableSshServer flow with mocks, without elevating or changing the machine.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Join-Path $PSScriptRoot '..\..\windows-dev-config'
$stepsDir = Join-Path $sourceRoot 'steps'
. (Join-Path $stepsDir '_step-runner.ps1')
. (Join-Path $stepsDir '_registry.ps1')
. (Join-Path $stepsDir '_elevation.ps1')
. (Join-Path $stepsDir '_pwsh-bootstrap.ps1')
. (Join-Path $stepsDir '_reboot-resume.ps1')
. (Join-Path $stepsDir 'registry-system.ps1')

$script:passed = 0
$script:failed = 0
function Check([string] $Name, [scriptblock] $Test) {
    try {
        if (-not (& $Test)) { throw 'returned false' }
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "FAIL  ${Name}: $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}
function Get-Failure([scriptblock] $Action) {
    try { & $Action } catch { return $_.Exception.Message }
    return ''
}

# Phase and machine mocks.
$script:captured = @()
function Invoke-DevConfigSteps { param([object[]] $Steps) $script:captured = @($Steps) }
function Start-Sleep { }
$script:states = @()
$script:adds = 0
function Get-WindowsCapability {
    $state = if ($script:states.Count -gt 1) { $script:states[0]; $script:states = @($script:states[1..($script:states.Count - 1)]) } else { $script:states[0] }
    [pscustomobject]@{ State = $state }
}
function Add-WindowsCapability { $script:adds++; [pscustomobject]@{ RestartNeeded = $false } }
$script:rule = $null
$script:ports = $null
$script:firewallCalls = @()
function Get-NetFirewallRule { param($Name) $script:rule }
function Get-NetFirewallPortFilter { param($AssociatedNetFirewallRule) $script:ports }
function Set-NetFirewallRule { $script:firewallCalls += [pscustomobject]@{ Verb = 'Set'; Args = $args } }
function New-NetFirewallRule { $script:firewallCalls += [pscustomobject]@{ Verb = 'New'; Args = $args } }
$script:profiles = @()
function Get-NetConnectionProfile { $script:profiles }

function Get-PhaseStepNames([string] $Action, [bool] $Enabled) {
    $Script:DevConfigAction = $Action
    $Script:DevConfigEnableSshServer = $Enabled
    $Script:DevConfigNotes = @()
    Invoke-RegistrySystemPhase
    return @($script:captured | ForEach-Object { $_.Name })
}
$sshSteps = @('OpenSshServer', 'SshServerService', 'SshFirewallRule')

Check 'Full omits the SSH server by default' {
    $names = Get-PhaseStepNames Full $false
    @($names | Where-Object { $_ -in $sshSteps }).Count -eq 0 -and $names -contains 'RemoteDesktop'
}
Check 'Full -EnableSshServer adds install, service, and firewall steps in order' {
    $names = Get-PhaseStepNames Full $true
    ($names[-3..-1] -join ',') -eq ($sshSteps -join ',') -and
        @($script:captured | Where-Object { $_.Name -in $sshSteps -and -not $_.BestEffort }).Count -eq 0
}
Check 'Partial never adds the SSH server' {
    @((Get-PhaseStepNames Partial $true) | Where-Object { $_ -like '*Ssh*' }).Count -eq 0
}
Check 'Uninstall always removes the server and its firewall rule' {
    $off = Get-PhaseStepNames Uninstall $false
    $on = Get-PhaseStepNames Uninstall $true
    ($off[-2..-1] -join ',') -eq 'OpenSshServerCleanup,SshFirewallRuleCleanup' -and ($on -join ',') -eq ($off -join ',')
}
Check 'A Public network adds a summary note without changing the category' {
    $script:profiles = @([pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Public' })
    $null = Get-PhaseStepNames Full $true
    $public = @($Script:DevConfigNotes | Where-Object { $_.Message -like '*Ethernet is Public*' }).Count -eq 1
    $script:profiles = @([pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' })
    $null = Get-PhaseStepNames Full $true
    $public -and $Script:DevConfigNotes.Count -eq 0
}

Check 'Install retries when Add-WindowsCapability reports success but the state stays NotPresent' {
    $script:adds = 0
    $script:states = @('NotPresent', 'Installed')
    Install-DevConfigSshServer
    $script:adds -eq 2
}
Check 'Install gives up after three attempts with a clear message' {
    $script:adds = 0
    $script:states = @('NotPresent')
    $message = Get-Failure { Install-DevConfigSshServer }
    $script:adds -eq 3 -and $message -like '*still NotPresent after 3 attempts*'
}
Check 'A pending install is flagged for a restart instead of failing' {
    $script:states = @('InstallPending')
    $Script:DevConfigStepUnverified = $null
    Install-DevConfigSshServer
    $Script:DevConfigStepUnverified -like '*after a restart*'
}

Check 'Firewall check accepts only enabled inbound TCP 22 on Private' {
    $script:rule = [pscustomobject]@{ Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private' }
    $script:ports = [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '22' }
    $ok = Test-DevConfigSshFirewallRule
    $script:rule.Profile = 'Any'
    $any = Test-DevConfigSshFirewallRule
    $script:rule.Profile = 'Private'; $script:rule.Enabled = 'False'
    $disabled = Test-DevConfigSshFirewallRule
    $script:rule = $null
    $ok -and -not $any -and -not $disabled -and -not (Test-DevConfigSshFirewallRule)
}
Check 'Firewall apply narrows an existing rule or creates a Private-only rule' {
    $script:firewallCalls = @()
    $script:rule = [pscustomobject]@{ Enabled = 'True' }
    Set-DevConfigSshFirewallRule
    $script:rule = $null
    Set-DevConfigSshFirewallRule
    $text = @($script:firewallCalls | ForEach-Object { "$($_.Verb) $($_.Args -join ' ')" })
    $text.Count -eq 2 -and $text[0] -like 'Set *-Profile: Private*' -and $text[1] -like 'New *-Profile: Private*' -and
        @($text | Where-Object { $_ -notlike '*-LocalPort: 22*' }).Count -eq 0
}
function Remove-NetFirewallRule { $script:firewallCalls += [pscustomobject]@{ Verb = 'Remove'; Args = $args } }
Check 'Firewall cleanup tolerates a rule already removed with the capability' {
    $script:firewallCalls = @()
    $script:rule = $null
    Remove-DevConfigSshFirewallRule
    $gone = $script:firewallCalls.Count -eq 0
    $script:rule = [pscustomobject]@{ Enabled = 'True' }
    Remove-DevConfigSshFirewallRule
    $script:rule = $null
    $gone -and $script:firewallCalls.Count -eq 1 -and $script:firewallCalls[0].Verb -eq 'Remove'
}

Check 'Relaunch arguments carry -EnableSshServer only when set' {
    $on = (Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -EnableSshServer -Resumed) -join ' '
    $off = (Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -Resumed) -join ' '
    $font = (Get-DevConfigRelaunchArguments -ScriptPath 'C:\Setup\dev-config.ps1' -EnableSshServer -ApplyTerminalFont) -join ' '
    $on -like '*-Action Full -EnableSshServer -NoElevate -Resumed' -and $off -notlike '*Ssh*' -and $font -notlike '*Ssh*'
}

$script:starts = @()
function Start-Process { $script:starts += ,@($args | ForEach-Object { $_ }); throw 'stop before launch' }
function Wait-DevConfigKeyPress { throw 'stop before exit' }
function Test-DevConfigIsAdmin { $false }
Check 'UAC elevation keeps -EnableSshServer' {
    $script:starts = @()
    $null = Get-Failure { Invoke-DevConfigElevate -ScriptPath 'C:\Setup\dev-config.ps1' -EnableSshServer }
    ($script:starts[0] -join ' ') -like '*-EnableSshServer*'
}
function Get-DevConfigPwshExe { 'C:\PowerShell\7\pwsh.exe' }
Check 'The PowerShell 7 handoff keeps -EnableSshServer' {
    $script:starts = @()
    $edition = $PSVersionTable.PSEdition
    try {
        $PSVersionTable.PSEdition = 'Desktop'
        $null = Get-Failure { Invoke-DevConfigEnsurePwsh -ScriptPath 'C:\Setup\dev-config.ps1' -EnableSshServer }
    } finally {
        $PSVersionTable.PSEdition = $edition
    }
    ($script:starts[0] -join ' ') -like '*-EnableSshServer*'
}

$script:taskArgument = ''
function New-ScheduledTaskAction { param($Execute, $Argument) $script:taskArgument = $Argument }
function New-ScheduledTaskTrigger { [pscustomobject]@{ Delay = '' } }
function New-ScheduledTaskPrincipal { }
function Register-ScheduledTask { }
function Unregister-ScheduledTask { }
function Save-DevConfigTally { }
function Invoke-DevConfigNativeCommand { throw 'stop before restart' }
Check 'The post-reboot resume task keeps -EnableSshServer' {
    $Script:DevConfigAction = 'Full'
    $Script:DevConfigEnableSshServer = $true
    $Script:DevConfigTerminalBackedUp = @()
    $Script:DevConfigAllowUnsigned = $false
    $null = Get-Failure { Suspend-DevConfigForReboot -ScriptPath 'C:\Setup\dev-config.ps1' }
    $script:taskArgument -like '*-Action Full -EnableSshServer -Resumed*'
}

Check 'Only the Full wrapper offers the switch' {
    (Get-Command (Join-Path $sourceRoot 'setup-full.ps1')).Parameters.ContainsKey('EnableSshServer') -and
        -not (Get-Command (Join-Path $sourceRoot 'setup-standard.ps1')).Parameters.ContainsKey('EnableSshServer') -and
        -not (Get-Command (Join-Path $sourceRoot 'uninstall.ps1')).Parameters.ContainsKey('EnableSshServer')
}

# The wrapper must keep working with a pinned bootstrap that predates the switch.
$global:SshCheckBootstrap = ''
$global:SshCheckBound = $null
function Invoke-RestMethod { $global:SshCheckBootstrap }
function Get-AuthenticodeSignature {
    [pscustomobject]@{
        Status            = 'Valid'
        SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
    }
}
$modulePath = $env:PSModulePath
try {
    Check 'The Full wrapper passes the switch only when set' {
        $global:SshCheckBootstrap = '[CmdletBinding()] param($Ref, $Action) $global:SshCheckBound = @($PSBoundParameters.Keys) -join ","'
        & (Join-Path $sourceRoot 'setup-full.ps1')
        $old = $global:SshCheckBound
        $global:SshCheckBootstrap = '[CmdletBinding()] param($Ref, $Action, [switch] $EnableSshServer) $global:SshCheckBound = "$Action $EnableSshServer"'
        & (Join-Path $sourceRoot 'setup-full.ps1') -EnableSshServer
        $old -eq 'Ref,Action' -and $global:SshCheckBound -eq 'Full True'
    }

    $bootstrap = Join-Path $sourceRoot 'bootstrap.ps1'
    foreach ($case in @(@{ Action = 'Partial' }, @{ Action = 'Uninstall' }, @{ Workload = 'winui' }, @{ Scenario = 'cuda' })) {
        $label = ($case.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
        Check "Bootstrap rejects -EnableSshServer with $label before any download" {
            $message = Get-Failure { & $bootstrap @case -EnableSshServer }
            $message -like '-EnableSshServer applies only to the full Calm OS setup*'
        }
    }
} finally {
    $env:PSModulePath = $modulePath
    Remove-Variable -Name SshCheckBound, SshCheckBootstrap -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "Results: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
