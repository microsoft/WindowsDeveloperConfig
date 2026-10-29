<#
.SYNOPSIS
  System-level developer settings: Sudo, Developer Mode, long path support, Remote Desktop,
  and the opt-in OpenSSH Server.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigSshCapability   = 'OpenSSH.Server~~~~0.0.1.0'
$Script:DevConfigSshFirewallRule = 'OpenSSH-Server-In-TCP'

function Get-DevConfigSshServerState {
    return [string](Get-WindowsCapability -Online -Name $Script:DevConfigSshCapability -ErrorAction Stop).State
}

# Add-WindowsCapability can report success while Windows Update services itself (0x800f0827),
# leaving the capability NotPresent, so the state is rechecked and the install retried.
function Install-DevConfigSshServer {
    $state = 'NotPresent'
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $result = Add-WindowsCapability -Online -Name $Script:DevConfigSshCapability -ErrorAction Stop
            if ($result -and $result.RestartNeeded) {
                Add-DevConfigNote -Warning -Message 'Restart Windows to finish installing OpenSSH Server.'
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        $state = Get-DevConfigSshServerState
        if ($state -eq 'Installed') {
            return
        }
        if ($state -eq 'InstallPending') {
            Set-DevConfigStepUnverified -Reason 'OpenSSH Server finishes installing after a restart. Run setup again afterwards.'
            return
        }
        if ($attempt -lt 3) {
            Write-Host "    OpenSSH Server is still $state after attempt $attempt; retrying." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 10
        }
    }
    $detail = if ($lastError) { " Last error: $lastError" } else { '' }
    throw "OpenSSH Server is still $state after 3 attempts. Windows Update may be busy; restart, then run setup again.$detail"
}

function Test-DevConfigSshService {
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    return [bool]($service -and "$($service.StartType)" -eq 'Automatic' -and "$($service.Status)" -eq 'Running')
}

function Start-DevConfigSshService {
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        throw 'The sshd service is missing because OpenSSH Server is not installed yet.'
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}

# The rule must allow inbound TCP 22 on Private networks only, never Public or Domain.
function Test-DevConfigSshFirewallRule {
    $rule = Get-NetFirewallRule -Name $Script:DevConfigSshFirewallRule -ErrorAction SilentlyContinue
    if (-not $rule) {
        return $false
    }
    $ports = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    return "$($rule.Enabled)" -eq 'True' -and "$($rule.Direction)" -eq 'Inbound' -and
        "$($rule.Action)" -eq 'Allow' -and "$($rule.Profile)" -eq 'Private' -and
        "$($ports.Protocol)" -eq 'TCP' -and "$(@($ports.LocalPort) -join ',')" -eq '22'
}

function Set-DevConfigSshFirewallRule {
    $settings = @{
        Enabled   = 'True'
        Direction = 'Inbound'
        Action    = 'Allow'
        Profile   = 'Private'
        Protocol  = 'TCP'
        LocalPort = '22'
    }
    if (Get-NetFirewallRule -Name $Script:DevConfigSshFirewallRule -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $Script:DevConfigSshFirewallRule @settings
    } else {
        New-NetFirewallRule -Name $Script:DevConfigSshFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' @settings | Out-Null
    }
}

function Remove-DevConfigSshServer {
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        Stop-Service -Name sshd -Force
    }
    $result = Remove-WindowsCapability -Online -Name $Script:DevConfigSshCapability -ErrorAction Stop
    if (($result -and $result.RestartNeeded) -or (Get-DevConfigSshServerState) -eq 'UninstallPending') {
        Add-DevConfigNote -Warning -Message 'Restart Windows to finish removing OpenSSH Server.'
    }
}

function Get-DevConfigSshServerSteps {
    param(
        [switch] $Reset
    )
    if ($Reset) {
        # Like Remote Desktop, cleanup removes the server even if it predates setup.
        return @(
            New-DevConfigStep -Name 'OpenSshServerCleanup' -Description 'Stop sshd and remove OpenSSH Server' -BestEffort `
                -Check { (Get-DevConfigSshServerState) -notin @('Installed', 'InstallPending', 'PartiallyInstalled') } `
                -Apply { Remove-DevConfigSshServer }
            New-DevConfigStep -Name 'SshFirewallRuleCleanup' -Description "Remove the $Script:DevConfigSshFirewallRule firewall rule" -BestEffort `
                -Check { -not (Get-NetFirewallRule -Name $Script:DevConfigSshFirewallRule -ErrorAction SilentlyContinue) } `
                -Apply { Remove-NetFirewallRule -Name $Script:DevConfigSshFirewallRule -ErrorAction Stop }
        )
    }

    # BestEffort: the install needs Windows Update, so a failure is flagged and retried on the next run.
    return @(
        New-DevConfigStep -Name 'OpenSshServer' -Description 'Install OpenSSH Server (can take a few minutes)' -BestEffort `
            -Check { (Get-DevConfigSshServerState) -eq 'Installed' } `
            -Apply { Install-DevConfigSshServer }
        New-DevConfigStep -Name 'SshServerService' -Description 'Start sshd and set it to start automatically' -BestEffort `
            -Check { Test-DevConfigSshService } `
            -Apply { Start-DevConfigSshService }
        New-DevConfigStep -Name 'SshFirewallRule' -Description 'Allow SSH (TCP 22) on Private networks only' -BestEffort `
            -Check { Test-DevConfigSshFirewallRule } `
            -Apply { Set-DevConfigSshFirewallRule }
    )
}

# The network category is left alone; a Public network blocks SSH until the user marks it Private.
function Add-DevConfigSshNetworkNote {
    $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { "$($_.NetworkCategory)" -eq 'Public' } | ForEach-Object { $_.InterfaceAlias })
    if ($public.Count -gt 0) {
        Add-DevConfigNote -Warning -Message ("SSH is allowed on Private networks only, and $($public -join ', ') is Public. " +
            'Mark a trusted network Private in Settings > Network & internet to connect.')
    }
}

function Invoke-RegistrySystemPhase {
    $tweaks = @(
        @{
            Name        = 'Sudo'
            KeyPath     = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'
            ValueName   = 'Enabled'
            Value       = 3
            ResetValue  = 0
            Description = 'Enable Sudo in inline mode'
        }
        @{
            Name        = 'DeveloperMode'
            KeyPath     = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            ValueName   = 'AllowDevelopmentWithoutDevLicense'
            Value       = 1
            ResetValue  = 0
            Description = 'Enable Developer Mode (sideload + dev features)'
        }
        @{
            Name        = 'LongPaths'
            KeyPath     = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'
            ValueName   = 'LongPathsEnabled'
            Value       = 1
            Description = 'Enable Win32 long path support'
        }
        @{
            Name        = 'RemoteDesktop'
            KeyPath     = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'
            ValueName   = 'fDenyTSConnections'
            Value       = 0
            ResetValue  = 1
            Description = 'Enable Remote Desktop (firewall rule still needs separate enable)'
        }
    )

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -eq 'LongPaths' })
    }

    $steps = @(foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak -Reset:($Script:DevConfigAction -eq 'Uninstall')
    })

    # OpenSSH Server is opt-in for Full (-EnableSshServer); cleanup always removes it.
    $sshServer = $Script:DevConfigAction -eq 'Full' -and $Script:DevConfigEnableSshServer
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps += Get-DevConfigSshServerSteps -Reset
    } elseif ($sshServer) {
        $steps += Get-DevConfigSshServerSteps
    }

    Invoke-DevConfigSteps -Steps $steps

    if ($sshServer) {
        Add-DevConfigSshNetworkNote
    }
}
