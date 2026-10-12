<#
.SYNOPSIS
  Configures PSScriptAnalyzer settings for the VS Code PowerShell extension.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigPowerShellAnalyzerRuleNames = @(
    'PSAvoidDefaultValueSwitchParameter'
    'PSAvoidGlobalVars'
    'PSAvoidUsingCmdletAliases'
    'PSAvoidUsingComputerNameHardcoded'
    'PSAvoidUsingConvertToSecureStringWithPlainText'
    'PSAvoidUsingEmptyCatchBlock'
    'PSAvoidUsingInvokeExpression'
    'PSAvoidUsingPlainTextForPassword'
    'PSAvoidUsingPositionalParameters'
    'PSAvoidUsingUsernameAndPasswordParams'
    'PSAvoidUsingWMICmdlet'
    'PSAvoidUsingWriteHost'
    'PSDSCDscExamplesPresent'
    'PSDSCDscTestsPresent'
    'PSDSCReturnCorrectTypesForDSCFunctions'
    'PSDSCStandardDSCFunctionsInResource'
    'PSDSCUseIdenticalMandatoryParametersForDSC'
    'PSDSCUseIdenticalParametersForDSC'
    'PSMissingModuleManifestField'
    'PSProvideCommentHelp'
    'PSReservedCmdletChar'
    'PSReservedParams'
    'PSShouldProcess'
    'PSUseApprovedVerbs'
    'PSUseCmdletCorrectly'
    'PSUseDeclaredVarsMoreThanAssignments'
    'PSUsePSCredentialType'
    'PSUseShouldProcessForStateChangingFunctions'
    'PSUseSingularNouns'
    'PSUseSupportsShouldProcess'
)

function Get-DevConfigVSCodeUserDirectory {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is not set; VS Code user settings cannot be located.'
    }
    Join-Path $env:APPDATA 'Code\User'
}

function Read-DevConfigVSCodeSettings {
    $path = Join-Path (Get-DevConfigVSCodeUserDirectory) 'settings.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{}
    }
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $content = [regex]::Replace($content, '/\*[\s\S]*?\*/', '')
    $content = [regex]::Replace($content, '(?m)^\s*//.*$', '')
    if ([string]::IsNullOrWhiteSpace($content)) {
        return [ordered]@{}
    }
    ConvertFrom-Json -InputObject $content -AsHashtable -ErrorAction Stop
}

function Test-DevConfigPowerShellAnalyzerSettings {
    $userDirectory = Get-DevConfigVSCodeUserDirectory
    $settings = Read-DevConfigVSCodeSettings
    $analyzerSettingsPath = Join-Path $userDirectory 'PSScriptAnalyzerSettings.psd1'
    if ($settings['powershell.scriptAnalysis.enable'] -ne $true -or
        $settings['powershell.scriptAnalysis.settingsPath'] -ne $analyzerSettingsPath -or
        -not (Test-Path -LiteralPath $analyzerSettingsPath)) {
        return $false
    }

    $analyzerSettings = Import-PowerShellDataFile -LiteralPath $analyzerSettingsPath -ErrorAction Stop
    if ($analyzerSettings.IncludeDefaultRules -ne $true) {
        return $false
    }
    foreach ($ruleName in $Script:DevConfigPowerShellAnalyzerRuleNames) {
        if ($ruleName -notin $analyzerSettings.IncludeRules) {
            return $false
        }
    }
    return $true
}

function Set-DevConfigPowerShellAnalyzerSettings {
    $userDirectory = Get-DevConfigVSCodeUserDirectory
    New-Item -ItemType Directory -Path $userDirectory -Force | Out-Null
    $analyzerSettingsPath = Join-Path $userDirectory 'PSScriptAnalyzerSettings.psd1'
    $lines = @(
        '@{'
        '    IncludeDefaultRules = $true'
        '    IncludeRules = @('
        foreach ($ruleName in $Script:DevConfigPowerShellAnalyzerRuleNames) {
            "        '$ruleName'"
        }
        '    )'
        '}'
    )
    Set-Content -LiteralPath $analyzerSettingsPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8 -ErrorAction Stop

    $settings = Read-DevConfigVSCodeSettings
    $settings['powershell.scriptAnalysis.enable'] = $true
    $settings['powershell.scriptAnalysis.settingsPath'] = $analyzerSettingsPath
    ConvertTo-Json -InputObject $settings -Depth 100 |
        Set-Content -LiteralPath (Join-Path $userDirectory 'settings.json') -Encoding utf8 -ErrorAction Stop

    if (-not (Test-DevConfigPowerShellAnalyzerSettings)) {
        throw 'The VS Code PowerShell analyzer settings did not reach the desired state.'
    }
}

function Invoke-PowerShellAnalyzerPhase {
    Show-DevConfigPhaseHeader
    $steps = @(
        New-DevConfigStep -Name 'PowerShellAnalyzerSettings' -Description 'Configure PSScriptAnalyzer in VS Code.' `
            -Check { Test-DevConfigPowerShellAnalyzerSettings } `
            -Apply { Set-DevConfigPowerShellAnalyzerSettings }
    )
    Invoke-DevConfigSteps -Steps $steps
}
