[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\powershell-analyzer.ps1')

$originalAppData = $env:APPDATA
$testRoot = Join-Path $env:TEMP "devconfig-analyzer-checks-$([guid]::NewGuid().ToString('N'))"
try {
    $env:APPDATA = $testRoot
    $userDirectory = Get-DevConfigVSCodeUserDirectory
    New-Item -ItemType Directory -Path $userDirectory -Force | Out-Null
    @'
{
    // Preserve unrelated VS Code settings.
    "files.autoSave": "off"
}
'@ | Set-Content -LiteralPath (Join-Path $userDirectory 'settings.json') -Encoding utf8

    if (Test-DevConfigPowerShellAnalyzerSettings) {
        throw 'Analyzer settings unexpectedly passed before configuration.'
    }

    Set-DevConfigPowerShellAnalyzerSettings
    if (-not (Test-DevConfigPowerShellAnalyzerSettings)) {
        throw 'Analyzer settings did not pass after configuration.'
    }

    $settings = Read-DevConfigVSCodeSettings
    if ($settings['files.autoSave'] -ne 'off') {
        throw 'Configuring analyzer settings removed an unrelated VS Code setting.'
    }
    if ($settings['powershell.scriptAnalysis.enable'] -ne $true) {
        throw 'PowerShell script analysis was not enabled.'
    }

    $analyzerPath = Join-Path $userDirectory 'PSScriptAnalyzerSettings.psd1'
    $analyzerSettings = Import-PowerShellDataFile -LiteralPath $analyzerPath -ErrorAction Stop
    if ($analyzerSettings.IncludeDefaultRules -ne $true -or
        @($analyzerSettings.IncludeRules).Count -ne $Script:DevConfigPowerShellAnalyzerRuleNames.Count) {
        throw 'The generated analyzer settings do not contain the complete expected rule set.'
    }
    foreach ($ruleName in $Script:DevConfigPowerShellAnalyzerRuleNames) {
        if ($ruleName -notin $analyzerSettings.IncludeRules) {
            throw "The generated analyzer settings are missing '$ruleName'."
        }
    }

    $settingsPath = Join-Path $userDirectory 'settings.json'
    Set-Content -LiteralPath $settingsPath -Value '{ invalid JSON' -Encoding utf8
    $invalidSettings = Get-Content -LiteralPath $settingsPath -Raw
    $failedAsExpected = $false
    try {
        Set-DevConfigPowerShellAnalyzerSettings
    } catch {
        $failedAsExpected = $true
    }
    if (-not $failedAsExpected) {
        throw 'Invalid existing VS Code settings were silently accepted.'
    }
    if ((Get-Content -LiteralPath $settingsPath -Raw) -ne $invalidSettings) {
        throw 'Invalid existing VS Code settings were unexpectedly overwritten.'
    }

    Write-Host 'PASS  PowerShell analyzer settings and preservation checks' -ForegroundColor Green
} finally {
    if ($null -eq $originalAppData) {
        Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue
    } else {
        $env:APPDATA = $originalAppData
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
