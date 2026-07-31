<#
.SYNOPSIS
  Microsoft Edge policy tweaks: blank new tab page, no first-run experience.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-EdgePhase {
    $tweaks = @(
        @{ Name = 'EdgeNewTab'; KeyPath = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; ValueName = 'NewTabPageLocation';  Value = 'about:blank'; Type = 'String'; Description = 'Set Edge new tab to blank' }
        @{ Name = 'EdgeOOBE';   KeyPath = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; ValueName = 'HideFirstRunExperience'; Value = 1;          Type = 'DWord';  Description = 'Disable Edge first-run experience' }
    )

    # ArgumentList binds each tweak's values at call time instead of relying on closure capture.
    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigStep -Name $tweak.Name -Description $tweak.Description `
            -Check { param($KeyPath, $ValueName, $Value, $Type) Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -Apply { param($KeyPath, $ValueName, $Value, $Type) Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value -Type $Type } `
            -ArgumentList @($tweak.KeyPath, $tweak.ValueName, $tweak.Value, $tweak.Type)
    }

    Invoke-DevConfigSteps -Steps $steps
}
