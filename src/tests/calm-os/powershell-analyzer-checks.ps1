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
    $settingsPath = Join-Path $userDirectory 'settings.json'
    @'
{
    // Preserve unrelated VS Code settings.
    "files.autoSave": "off",
    /* Keep block comments and comment-like text in strings. */
    "example.pattern": "keep/*this*/text // too"
}
'@ | Set-Content -LiteralPath $settingsPath -Encoding utf8 -NoNewline

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
    if ($settings['example.pattern'] -cne 'keep/*this*/text // too') {
        throw 'Configuring analyzer settings corrupted a string value containing comment markers.'
    }
    if ($settings['powershell.scriptAnalysis.enable'] -ne $true) {
        throw 'PowerShell script analysis was not enabled.'
    }
    $configuredContent = Get-Content -LiteralPath $settingsPath -Raw
    foreach ($expectedText in @(
            '// Preserve unrelated VS Code settings.'
            '/* Keep block comments and comment-like text in strings. */'
            '"example.pattern": "keep/*this*/text // too",'
        )) {
        if (-not $configuredContent.Contains($expectedText)) {
            throw "Configuring analyzer settings did not preserve '$expectedText' in settings.json."
        }
    }

    Set-DevConfigPowerShellAnalyzerSettings
    if ((Get-Content -LiteralPath $settingsPath -Raw) -cne $configuredContent) {
        throw 'Reapplying analyzer settings rewrote an already configured settings.json.'
    }

    @'
{
    "powershell.scriptAnalysis.enable": false, // Existing value is updated in place.
    "editor.tabSize": 2, // Trailing comment stays with its property.
}
'@ | Set-Content -LiteralPath $settingsPath -Encoding utf8 -NoNewline
    Set-DevConfigPowerShellAnalyzerSettings
    $updatedContent = Get-Content -LiteralPath $settingsPath -Raw
    foreach ($expectedText in @(
            '"powershell.scriptAnalysis.enable": true, // Existing value is updated in place.'
            '"editor.tabSize": 2, // Trailing comment stays with its property.'
        )) {
        if (-not $updatedContent.Contains($expectedText)) {
            throw "Updating analyzer settings did not preserve '$expectedText' in settings.json."
        }
    }
    if (-not (Test-DevConfigPowerShellAnalyzerSettings)) {
        throw 'Analyzer settings did not pass after updating settings with trailing commas.'
    }

    Set-Content -LiteralPath $settingsPath -Value '// Only a comment.' -Encoding utf8 -NoNewline
    Set-DevConfigPowerShellAnalyzerSettings
    if (-not (Get-Content -LiteralPath $settingsPath -Raw).StartsWith('// Only a comment.') -or
        -not (Test-DevConfigPowerShellAnalyzerSettings)) {
        throw 'Analyzer settings were not added to a comment-only settings.json.'
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
