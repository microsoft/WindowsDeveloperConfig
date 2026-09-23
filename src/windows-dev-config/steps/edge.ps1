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

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak -Reset:($Script:DevConfigAction -eq 'Uninstall')
    }

    Invoke-DevConfigSteps -Steps $steps
}
