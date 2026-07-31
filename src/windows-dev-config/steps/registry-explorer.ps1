<#
.SYNOPSIS
  File Explorer and Desktop registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistryExplorerPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $explorer = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'

    $tweaks = @(
        @{ Name = 'ShowFileExtensions'; KeyPath = $advanced; ValueName = 'HideFileExt';                  Value = 0; Description = 'Show file extensions in Explorer' }
        @{ Name = 'ShowHiddenFiles';    KeyPath = $advanced; ValueName = 'Hidden';                        Value = 1; Description = 'Show hidden files in Explorer' }
        @{ Name = 'FullPathTitlebar';   KeyPath = $advanced; ValueName = 'FullPathAddress';               Value = 1; Description = 'Show full path in Explorer titlebar' }
        @{ Name = 'OpenThisPC';         KeyPath = $advanced; ValueName = 'LaunchTo';                      Value = 1; Description = 'Open File Explorer to This PC' }
        @{ Name = 'FrequentFolders';    KeyPath = $advanced; ValueName = 'ShowFrequent';                  Value = 0; Description = 'Disable frequent folders in Quick Access' }
        @{ Name = 'FrequentFiles';      KeyPath = $explorer; ValueName = 'ShowRecent';                    Value = 0; Description = 'Disable frequent files in Quick Access' }
        @{ Name = 'RecommendedFiles';   KeyPath = $explorer; ValueName = 'ShowCloudFilesInQuickAccess';   Value = 0; Description = 'Disable recommended/cloud files in Quick Access' }
        @{ Name = 'GitCodeFolders';     KeyPath = $advanced; ValueName = 'NavPaneShowVersionControl';     Value = 1; Description = 'Enable Git integration in File Explorer' }
        @{ Name = 'TipsOff';            KeyPath = $advanced; ValueName = 'ShowSyncProviderNotifications'; Value = 0; Description = 'Disable sync provider notifications (tips)' }
    )

    # ArgumentList binds each tweak's values at call time instead of relying on closure capture.
    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigStep -Name $tweak.Name -Description $tweak.Description `
            -Check { param($KeyPath, $ValueName, $Value) Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -Apply { param($KeyPath, $ValueName, $Value) Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -ArgumentList @($tweak.KeyPath, $tweak.ValueName, $tweak.Value)
    }

    Invoke-DevConfigSteps -Steps $steps
}
