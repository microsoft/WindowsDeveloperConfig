<#
.SYNOPSIS
  Taskbar, Start, Search, notifications, and Widget service registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistryTaskbarSearchPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    $tweaks = @(
        @{
            Name        = 'DoNotDisturb'
            KeyPath     = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
            ValueName   = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
            Value       = 0
            Description = 'Enable Do Not Disturb (disable all notifications)'
        }
        @{
            Name        = 'BluetoothOff'
            KeyPath     = 'HKCU\Control Panel\Bluetooth'
            ValueName   = 'Notification Area Icon'
            Value       = 0
            Description = 'Hide Bluetooth icon in taskbar notification area'
        }
        @{
            Name        = 'EndTask'
            KeyPath     = "$advanced\TaskbarDeveloperSettings"
            ValueName   = 'TaskbarEndTask'
            Value       = 1
            Description = 'Enable "End Task" on right-click of taskbar icons'
        }
        @{
            Name        = 'WebSearchOff'
            KeyPath     = 'HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer'
            ValueName   = 'DisableSearchBoxSuggestions'
            Value       = 1
            Description = 'Disable web search in Start/Search'
        }
        @{
            Name        = 'SearchHighlightOff'
            KeyPath     = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings'
            ValueName   = 'IsDynamicSearchBoxEnabled'
            Value       = 0
            Description = 'Disable Show search highlights'
        }
        @{
            Name        = 'StartRecommendations'
            KeyPath     = $advanced
            ValueName   = 'Start_IrisRecommendations'
            Value       = 0
            Description = 'Disable Start menu recommendations'
        }
        @{
            Name        = 'StartAccountNotifications'
            KeyPath     = $advanced
            ValueName   = 'Start_AccountNotifications'
            Value       = 0
            Description = 'Disable Start menu account notifications'
        }
        # Windows may protect the Widgets policy even from an administrator.
        @{
            Name        = 'WidgetServiceOff'
            KeyPath     = 'HKLM\SOFTWARE\Policies\Microsoft\Dsh'
            ValueName   = 'AllowNewsAndInterests'
            Value       = 0
            Description = 'Disable Widgets'
            BestEffort  = $true
        }
    )

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -in @('EndTask', 'StartRecommendations', 'StartAccountNotifications') })
    }

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak -Reset:($Script:DevConfigAction -eq 'Uninstall')
    }
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps += New-DevConfigRegistryStep -Reset -Setting @{
            Name      = 'QuietHoursProfile'
            KeyPath   = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\QuietHours\Profiles'
            ValueName = 'DefaultProfile'
        }
    }

    Invoke-DevConfigSteps -Steps $steps
}
