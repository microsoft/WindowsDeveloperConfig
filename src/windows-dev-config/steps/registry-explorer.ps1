<#
.SYNOPSIS
  File Explorer and Desktop registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistryExplorerPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $explorer = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    $cabinet = "$explorer\CabinetState"

    $tweaks = @(
        @{ Name = 'ShowFileExtensions'; KeyPath = $advanced; ValueName = 'HideFileExt';                  Value = 0; Description = 'Show file extensions in Explorer' }
        @{ Name = 'ShowHiddenFiles';    KeyPath = $advanced; ValueName = 'Hidden';                        Value = 1; Description = 'Show hidden files in Explorer' }
        @{ Name = 'FullPathTitlebar';   KeyPath = $cabinet;  ValueName = 'FullPath';                      Value = 1; Description = 'Show full path in Explorer titlebar' }
        @{ Name = 'OpenThisPC';         KeyPath = $advanced; ValueName = 'LaunchTo';                      Value = 1; Description = 'Open File Explorer to This PC' }
        @{ Name = 'FrequentFolders';    KeyPath = $explorer; ValueName = 'ShowFrequent';                  Value = 0; Description = 'Disable frequent folders in Quick Access' }
        @{ Name = 'FrequentFiles';      KeyPath = $explorer; ValueName = 'ShowRecent';                    Value = 0; Description = 'Disable frequent files in Quick Access' }
        @{ Name = 'RecommendedFiles';   KeyPath = $explorer; ValueName = 'ShowCloudFilesInQuickAccess';   Value = 0; Description = 'Disable recommended/cloud files in Quick Access' }
        @{ Name = 'TipsOff';            KeyPath = $advanced; ValueName = 'ShowSyncProviderNotifications'; Value = 0; Description = 'Disable sync provider notifications (tips)' }
        @{ Name = 'DetailsContainer';   KeyPath = "$explorer\Modules\GlobalSettings\DetailsContainer"; ValueName = 'DetailsContainer'; Value = [byte[]](0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00); Type = 'Binary'; Description = 'Configure Explorer Details pane state' }
    )
    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -ne 'RecommendedFiles' })
    }

    # ArgumentList binds each tweak's values at call time instead of closure capture.
    $steps = foreach ($tweak in $tweaks) {
        $type = if ($tweak.ContainsKey('Type')) { $tweak.Type } else { 'DWord' }
        New-DevConfigStep -Name $tweak.Name -Description $tweak.Description `
            -Check { param($KeyPath, $ValueName, $Value) Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -Apply { param($KeyPath, $ValueName, $Value, $Type) Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value -Type $Type } `
            -ArgumentList @($tweak.KeyPath, $tweak.ValueName, $tweak.Value, $type)
    }

    Invoke-DevConfigSteps -Steps $steps
}
