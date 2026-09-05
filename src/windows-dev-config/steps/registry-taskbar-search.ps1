<#
.SYNOPSIS
  Taskbar, Start, Search, notifications, and Widget service registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistryTaskbarSearchPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    $tweaks = @(
        @{ Name = 'DoNotDisturb';          KeyPath = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; ValueName = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'; Value = 0; Description = 'Enable Do Not Disturb (disable all notifications)' }
        @{ Name = 'BluetoothOff';           KeyPath = 'HKCU\Control Panel\Bluetooth';                                        ValueName = 'Notification Area Icon';              Value = 0; Description = 'Hide Bluetooth icon in taskbar notification area' }
        @{ Name = 'EndTask';                KeyPath = $advanced;                                                              ValueName = 'TaskbarEndTask';                      Value = 1; Description = 'Enable "End Task" on right-click of taskbar icons' }
        @{ Name = 'WebSearchOff';           KeyPath = 'HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer';                    ValueName = 'DisableSearchBoxSuggestions';         Value = 1; Description = 'Disable web search in Start/Search' }
        @{ Name = 'SearchHighlightOff';     KeyPath = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings';        ValueName = 'IsDynamicSearchBoxEnabled';           Value = 0; Description = 'Disable Show search highlights' }
        @{ Name = 'StartRecommendations';   KeyPath = $advanced;                                                              ValueName = 'Start_IrisRecommendations';           Value = 0; Description = 'Disable Start menu recommendations' }
        # Widgets are configured at OS policy level because the direct taskbar icon key is blocked on 24H2+.
        @{ Name = 'WidgetServiceOff';       KeyPath = 'HKLM\SOFTWARE\Policies\Microsoft\Dsh';                                 ValueName = 'AllowNewsAndInterests';               Value = 0; Description = 'Disable Widget service' }
    )

    # ArgumentList binds each tweak's values at call time instead of closure capture.
    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigStep -Name $tweak.Name -Description $tweak.Description `
            -Check { param($KeyPath, $ValueName, $Value) Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -Apply { param($KeyPath, $ValueName, $Value) Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -ArgumentList @($tweak.KeyPath, $tweak.ValueName, $tweak.Value)
    }

    Invoke-DevConfigSteps -Steps $steps
}
