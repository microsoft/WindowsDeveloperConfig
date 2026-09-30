<#
.SYNOPSIS
  Loads a workload definition from workloads\ and runs its phases.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Unknown keys fail the run so a misspelled setting is not silently ignored.
$Script:DevConfigWorkloadKeys = @('Name', 'Actions', 'Phases', 'MinimumOSVersion', 'SetupNote', 'UninstallWarning', 'Notes')
$Script:DevConfigPhaseKeys    = @('File', 'Function', 'Title', 'Parameters', 'Steps', 'Uninstall')

function Assert-DevConfigWorkloadDefinition {
    param(
        [Parameter(Mandatory)] [AllowNull()] $Definition,
        [Parameter(Mandatory)] [string] $Workload
    )
    if ($Definition -isnot [hashtable]) {
        throw "workloads\$Workload.ps1 must return a hashtable."
    }

    $problems = @()
    foreach ($key in $Definition.Keys) {
        if ($Script:DevConfigWorkloadKeys -notcontains $key) {
            $problems += "unknown setting '$key'"
        }
    }
    if (-not ($Definition['Name'] -is [string] -and $Definition['Name'])) {
        $problems += 'Name must be a non-empty string'
    }
    $actions = @($Definition['Actions'] | Where-Object { $null -ne $_ })
    if ($actions.Count -eq 0 -or @($actions | Where-Object { $_ -notin @('Full', 'Partial', 'Uninstall') }).Count -gt 0) {
        $problems += 'Actions must list Full, Partial, and/or Uninstall'
    }
    if ($Definition['MinimumOSVersion'] -and -not ($Definition['MinimumOSVersion'] -as [version])) {
        $problems += 'MinimumOSVersion must be a version such as 10.0.17763'
    }

    $phases = @($Definition['Phases'] | Where-Object { $null -ne $_ })
    if ($phases.Count -eq 0) {
        $problems += 'Phases must list at least one phase'
    }
    foreach ($phase in $phases) {
        if ($phase -isnot [hashtable]) {
            $problems += 'every phase must be a hashtable'
            continue
        }
        $label = if ($phase['Title']) { "phase '$($phase['Title'])'" } else { 'a phase' }
        foreach ($key in $phase.Keys) {
            if ($Script:DevConfigPhaseKeys -notcontains $key) {
                $problems += "$label has unknown setting '$key'"
            }
        }
        # Files starting with _ are shared helpers, which are always loaded and are never phases.
        if (-not ($phase['File'] -is [string] -and $phase['File'] -match '^[a-z0-9]+(-[a-z0-9]+)*\.ps1$')) {
            $problems += "$label needs File set to a phase file under steps\"
        }
        if (-not ($phase['Function'] -is [string] -and $phase['Function'] -match '^Invoke-\w+Phase$')) {
            $problems += "$label needs Function set to the phase's Invoke-<Name>Phase function"
        }
        if (-not ($phase['Title'] -is [string] -and $phase['Title'])) {
            $problems += "$label needs a Title"
        }
        if ($phase.ContainsKey('Parameters') -and $phase['Parameters'] -isnot [hashtable]) {
            $problems += "$label Parameters must be a hashtable"
        }
        if ($phase.ContainsKey('Steps') -and
            (@($phase['Steps']).Count -eq 0 -or @($phase['Steps'] | Where-Object { $_ -isnot [string] -or -not $_ }).Count -gt 0)) {
            $problems += "$label Steps must list step names"
        }
    }

    if ($problems.Count -gt 0) {
        throw "workloads\$Workload.ps1 is not a valid workload: $($problems -join '; ')."
    }
}

function Get-DevConfigWorkload {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Workload,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full'
    )
    $path = Join-Path $Directory "$Workload.ps1"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $available = @(Get-ChildItem -LiteralPath $Directory -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName }) -join ', '
        throw "There is no '$Workload' workload. Available workloads: $available."
    }

    # Definitions only describe phases; they are invoked for the requested action and must not change the machine.
    $definition = & $path -Action $Action
    Assert-DevConfigWorkloadDefinition -Definition $definition -Workload $Workload

    if (@($definition['Actions']) -notcontains $Action) {
        throw "The $($definition['Name']) workload supports -Action $(@($definition['Actions']) -join ', ') only."
    }
    if ($definition['MinimumOSVersion']) {
        $current = [Environment]::OSVersion.Version
        if ($current -lt [version]$definition['MinimumOSVersion']) {
            throw "The $($definition['Name']) workload needs Windows $($definition['MinimumOSVersion']) or later. This machine runs $current."
        }
    }
    return $definition
}

# Parameters come from the workload; phases that can reboot also receive the orchestrator path so resume can relaunch it.
function Resolve-DevConfigWorkloadPhase {
    param(
        [Parameter(Mandatory)] [hashtable] $Phase,
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )
    $command = Get-Command -Name $Phase['Function'] -CommandType Function -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$($Phase['File']) does not define $($Phase['Function'])."
    }

    $parameters = @{}
    if ($Phase['Parameters']) {
        foreach ($name in $Phase['Parameters'].Keys) {
            if (-not $command.Parameters.ContainsKey($name)) {
                throw "$($Phase['Function']) has no -$name parameter, so the workload cannot pass it."
            }
            $parameters[$name] = $Phase['Parameters'][$name]
        }
    }
    if ($command.Parameters.ContainsKey('OrchestratorPath')) {
        $parameters['OrchestratorPath'] = $OrchestratorPath
    }

    # A missing mandatory value would otherwise stop the run at a parameter prompt.
    foreach ($parameter in $command.Parameters.Values) {
        $mandatory = @($parameter.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory }).Count -gt 0
        if ($mandatory -and -not $parameters.ContainsKey($parameter.Name)) {
            throw "$($Phase['Function']) requires -$($parameter.Name), so the workload must set it in Parameters."
        }
    }
    return @{ Command = $command; Parameters = $parameters }
}

function Invoke-DevConfigWorkloadPhase {
    param(
        [Parameter(Mandatory)] [hashtable] $Phase,
        [Parameter(Mandatory)] [string] $OrchestratorPath
    )
    $resolved = Resolve-DevConfigWorkloadPhase -Phase $Phase -OrchestratorPath $OrchestratorPath
    $parameters = $resolved.Parameters

    $Script:DevConfigPhaseSteps = $Phase['Steps']
    try {
        & $resolved.Command @parameters
    } finally {
        $Script:DevConfigPhaseSteps = $null
    }
}
